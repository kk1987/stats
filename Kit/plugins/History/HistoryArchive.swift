//
//  HistoryArchive.swift
//  Kit
//
//  Persistent usage history: the on-disk round-robin archive.
//  Design: docs/usage-history-design.md (§3 Storage), exelban/stats#1194.
//

import Foundation

// MARK: - tiers and presets

/// One resolution tier. Every tier is a separate file in `history/`.
public enum HistoryTier: Int, CaseIterable {
    case t0
    case t1
    case t2

    /// Bucket width in seconds: 10 s, 2 min, 30 min.
    public var step: Int {
        switch self {
        case .t0: return 10
        case .t1: return 120
        case .t2: return 1800
        }
    }

    /// Retained buckets: 24 h, 30 d, 365 d.
    public var buckets: Int {
        switch self {
        case .t0: return 8_640
        case .t1: return 21_600
        case .t2: return 17_520
        }
    }

    public var fileName: String {
        switch self {
        case .t0: return "t0.rrd"
        case .t1: return "t1.rrd"
        case .t2: return "t2.rrd"
        }
    }
}

/// Retention preset. Two entries only, see §3.
public enum HistoryRetentionPreset: String {
    case minimal
    case standard

    public var tiers: [HistoryTier] {
        switch self {
        case .minimal: return [.t0]
        case .standard: return [.t0, .t1, .t2]
        }
    }
}

// MARK: - slot

/// Why a bucket holds no measured sample, or how it was filled.
///
/// `nodata` is raw value 0 on purpose: the matrix is zero-filled at creation
/// and every slot a wrap has not reached yet reads as all zeroes, so zero has
/// to mean "nothing here" rather than "a measured zero". The raw values are a
/// one-way format door once an archive exists in the field (§11, risk 1), so
/// they are fixed here rather than in the commit that first reads a slot back.
public enum HistoryGapReason: UInt8 {
    case nodata = 0
    case measured = 1
    case asleep = 2
    case notRunning = 3
    case clockStep = 4
    case held = 5
}

/// One (bucket, lane) cell of the matrix. 20 B on disk:
/// `bucket:u32 | count:u16 | reason:u8 | pad:u8 | min:f32 | max:f32 | sum:f32`.
public struct HistorySlot {
    public static let byteWidth: Int = 20

    public var bucket: UInt32
    public var count: UInt16
    public var reason: HistoryGapReason
    public var min: Float
    public var max: Float
    public var sum: Float

    public init(bucket: UInt32 = 0, count: UInt16 = 0, reason: HistoryGapReason = .nodata,
                min: Float = 0, max: Float = 0, sum: Float = 0) {
        self.bucket = bucket
        self.count = count
        self.reason = reason
        self.min = min
        self.max = max
        self.sum = sum
    }

    /// A slot the recorder actually wrote, measured or not: it is what moves a
    /// lane's `firstValidBucket` forward. A zeroed cell is not one — that is
    /// what `nodata == 0` buys.
    public var isRecorded: Bool {
        self.count > 0 || self.reason != .nodata
    }

    // MARK: - encoding
    // Fixed little-endian encode/decode into the matrix region.

    internal func encode(into buffer: inout [UInt8], at offset: Int) {
        HistoryBytes.put(self.bucket, into: &buffer, at: offset)
        HistoryBytes.put(self.count, into: &buffer, at: offset + 4)
        buffer[offset + 6] = self.reason.rawValue
        buffer[offset + 7] = 0
        HistoryBytes.put(self.min.bitPattern, into: &buffer, at: offset + 8)
        HistoryBytes.put(self.max.bitPattern, into: &buffer, at: offset + 12)
        HistoryBytes.put(self.sum.bitPattern, into: &buffer, at: offset + 16)
    }

    /// Total by construction: every field is fixed width and the only enum byte
    /// falls back, so a bit flip inside the matrix yields a nonsense slot rather
    /// than a trap. The caller still rejects it on its bucket stamp.
    internal static func decode(_ pointer: UnsafeRawPointer, at offset: Int) -> HistorySlot {
        HistorySlot(
            bucket: HistoryBytes.get(UInt32.self, from: pointer, at: offset),
            count: HistoryBytes.get(UInt16.self, from: pointer, at: offset + 4),
            reason: HistoryGapReason(rawValue: HistoryBytes.get(UInt8.self, from: pointer, at: offset + 6)) ?? .nodata,
            min: Float(bitPattern: HistoryBytes.get(UInt32.self, from: pointer, at: offset + 8)),
            max: Float(bitPattern: HistoryBytes.get(UInt32.self, from: pointer, at: offset + 12)),
            sum: Float(bitPattern: HistoryBytes.get(UInt32.self, from: pointer, at: offset + 16))
        )
    }
}

/// One fully materialized bucket row: exactly `lanes` slots, in lane order.
/// The commit path takes rows because the layout is row-major — a commit that
/// touches n consecutive buckets is one `pwrite`, whatever the lane count.
public struct HistoryRow {
    public let bucket: UInt32
    public var slots: [HistorySlot]

    public init(bucket: UInt32, slots: [HistorySlot]) {
        self.bucket = bucket
        self.slots = slots
    }
}

// MARK: - errors

public enum HistoryArchiveError: Error, Equatable {
    /// `errno` from an `open`/`pwrite`/`ftruncate`/`mmap` call.
    case io(Int32)
    case notOpen
    case geometry(String)
}

/// What was wrong with a file that had to be thrown away.
public enum HistoryArchiveDamage: String, Error, Equatable {
    case shortHeader
    case badMagic
    case badVersion
    case badChecksum
    case geometryMismatch
    case truncated
}

public enum HistoryArchiveOpenOutcome: Equatable {
    case created
    case existing
    case recreated(HistoryArchiveDamage)
}

// MARK: - header

/// The 4 KiB file header. The checksum covers the header and the lane
/// directory — lane identity and geometry are what must not rot silently,
/// while the mutable cursor below is self-validating through the per-slot
/// bucket stamp (§3). Slots are therefore not checksummed.
public struct HistoryArchiveHeader {
    public static let byteWidth: Int = 4_096
    /// Hexdumps as "STHS" under the file's little-endian encoding: the low byte
    /// is written first, so 0x53 0x54 0x48 0x53 has to be spelled backwards
    /// here. Baked into every archive from the first release, so it is fixed
    /// now rather than in the commit that writes it.
    public static let magic: UInt32 = 0x53485453 // "STHS" little-endian
    public static let formatVersion: UInt32 = 1

    fileprivate static let offsetMagic: Int = 0
    fileprivate static let offsetFormatVersion: Int = 4
    fileprivate static let offsetStep: Int = 8
    fileprivate static let offsetBuckets: Int = 12
    fileprivate static let offsetLanes: Int = 16
    fileprivate static let offsetLastCommitBucket: Int = 20
    fileprivate static let offsetMonotonicAnchor: Int = 24
    fileprivate static let offsetCreatedTs: Int = 32
    fileprivate static let offsetChecksum: Int = 40

    public var step: UInt32
    public var buckets: UInt32
    public var lanes: UInt32
    public var lastCommitBucket: UInt32
    public var monotonicAnchor: UInt64
    public var createdTs: UInt64

    public init(step: UInt32, buckets: UInt32, lanes: UInt32, lastCommitBucket: UInt32 = 0,
                monotonicAnchor: UInt64 = 0, createdTs: UInt64 = 0) {
        self.step = step
        self.buckets = buckets
        self.lanes = lanes
        self.lastCommitBucket = lastCommitBucket
        self.monotonicAnchor = monotonicAnchor
        self.createdTs = createdTs
    }

    // MARK: - encoding

    /// The 4 KiB image, checksum included. `directoryChecksum` is the CRC of the
    /// encoded lane directory that follows the header in the file: one chained
    /// checksum covers both regions, and it is chained directory-first so that
    /// the directory's own CRC does not depend on the header and can be cached
    /// across the commits that leave the directory alone.
    internal func encoded(directoryChecksum: UInt32) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: HistoryArchiveHeader.byteWidth)
        HistoryBytes.put(HistoryArchiveHeader.magic, into: &buffer, at: HistoryArchiveHeader.offsetMagic)
        HistoryBytes.put(HistoryArchiveHeader.formatVersion, into: &buffer, at: HistoryArchiveHeader.offsetFormatVersion)
        HistoryBytes.put(self.step, into: &buffer, at: HistoryArchiveHeader.offsetStep)
        HistoryBytes.put(self.buckets, into: &buffer, at: HistoryArchiveHeader.offsetBuckets)
        HistoryBytes.put(self.lanes, into: &buffer, at: HistoryArchiveHeader.offsetLanes)
        HistoryBytes.put(self.lastCommitBucket, into: &buffer, at: HistoryArchiveHeader.offsetLastCommitBucket)
        HistoryBytes.put(self.monotonicAnchor, into: &buffer, at: HistoryArchiveHeader.offsetMonotonicAnchor)
        HistoryBytes.put(self.createdTs, into: &buffer, at: HistoryArchiveHeader.offsetCreatedTs)

        // The checksum field itself is still zero here, which is what the
        // validation side reconstructs.
        let crc = HistoryCRC32.checksum(buffer, seed: directoryChecksum)
        HistoryBytes.put(crc, into: &buffer, at: HistoryArchiveHeader.offsetChecksum)
        return buffer
    }

    // MARK: - validation (magic, formatVersion, crc32)

    /// Decodes and validates the header alone. The directory checksum needs the
    /// lane count this returns, so it is verified separately by the caller.
    internal static func decode(_ bytes: [UInt8]) -> Result<HistoryArchiveHeader, HistoryArchiveDamage> {
        guard bytes.count >= HistoryArchiveHeader.byteWidth else { return .failure(.shortHeader) }
        return bytes.withUnsafeBytes { raw -> Result<HistoryArchiveHeader, HistoryArchiveDamage> in
            guard let base = raw.baseAddress else { return .failure(.shortHeader) }
            guard HistoryBytes.get(UInt32.self, from: base, at: offsetMagic) == HistoryArchiveHeader.magic else {
                return .failure(.badMagic)
            }
            guard HistoryBytes.get(UInt32.self, from: base, at: offsetFormatVersion) == HistoryArchiveHeader.formatVersion else {
                return .failure(.badVersion)
            }
            return .success(HistoryArchiveHeader(
                step: HistoryBytes.get(UInt32.self, from: base, at: offsetStep),
                buckets: HistoryBytes.get(UInt32.self, from: base, at: offsetBuckets),
                lanes: HistoryBytes.get(UInt32.self, from: base, at: offsetLanes),
                lastCommitBucket: HistoryBytes.get(UInt32.self, from: base, at: offsetLastCommitBucket),
                monotonicAnchor: HistoryBytes.get(UInt64.self, from: base, at: offsetMonotonicAnchor),
                createdTs: HistoryBytes.get(UInt64.self, from: base, at: offsetCreatedTs)
            ))
        }
    }

    /// The checksum the file carries, and the one it should carry for this
    /// header image chained onto a directory whose own CRC is
    /// `directoryChecksum`. The stored field is taken as zero while the header
    /// is checksummed, exactly as `encoded` wrote it.
    internal static func checksums(_ bytes: [UInt8], directoryChecksum: UInt32) -> (stored: UInt32, expected: UInt32) {
        var image = Array(bytes[0..<HistoryArchiveHeader.byteWidth])
        let stored = image.withUnsafeBytes { HistoryBytes.get(UInt32.self, from: $0.baseAddress!, at: offsetChecksum) }
        for i in 0..<4 { image[offsetChecksum + i] = 0 }
        return (stored, HistoryCRC32.checksum(image, seed: directoryChecksum))
    }
}

// MARK: - archive

/// One tier file: header + lane directory + `buckets × lanes × 20 B` matrix.
/// Written with `pwrite`, read through a read-only `mmap`.
///
/// Not thread safe by itself: the recorder owns one instance per tier and
/// touches it only from the history queue.
public final class HistoryArchive {
    public let tier: HistoryTier
    public let url: URL

    private var fd: Int32 = -1
    private var mapBase: UnsafeRawPointer?
    private var mapLength: Int = 0
    private var header: HistoryArchiveHeader
    private var entries: [HistoryLaneEntry] = []

    /// Whether `entries` has moved ahead of the directory bytes in the file.
    ///
    /// The file's one checksum is chained over the directory and the header, so
    /// writing the header alone is only correct while the two agree — and a
    /// `pwrite` can fail at any time (§3), which is exactly how they come to
    /// disagree: a `commit` whose second row range hits `ENOSPC` has already
    /// moved a lane's `firstValidBucket` in memory and never reached the header
    /// write. Stamping a header checksummed over that directory onto the old
    /// directory bytes would make the next `open()` read `.badChecksum` and
    /// throw a year of history away over a write that succeeded. So the flag is
    /// set wherever `entries` changes and on any failed write, and cleared only
    /// once the header and the directory have gone out together.
    private var directoryDirty = false
    /// CRC of the encoded directory, cached against `entries`. The common commit
    /// path rewrites only the 4 KiB header, and re-encoding up to 32 KiB of
    /// directory to recompute a checksum that has not changed would be the most
    /// expensive thing on it. `nil` means "not computed yet", never "stale":
    /// every write to `entries` clears it.
    private var cachedDirectoryChecksum: UInt32?

    public init(tier: HistoryTier, url: URL) {
        self.tier = tier
        self.url = url
        self.header = HistoryArchiveHeader(step: UInt32(tier.step), buckets: UInt32(tier.buckets), lanes: 0)
    }

    deinit {
        self.close()
    }

    // MARK: - geometry

    public var laneCount: Int { self.entries.count }
    public var directory: [HistoryLaneEntry] { self.entries }
    public var lastCommitBucket: UInt32 { self.header.lastCommitBucket }
    public var monotonicAnchor: UInt64 { self.header.monotonicAnchor }
    public var createdTs: UInt64 { self.header.createdTs }
    public var isOpen: Bool { self.fd >= 0 }

    private var directoryOffset: Int { HistoryArchiveHeader.byteWidth }
    private var matrixOffset: Int { self.directoryOffset + self.entries.count * HistoryLaneEntry.byteWidth }
    private var rowBytes: Int { self.entries.count * HistorySlot.byteWidth }

    /// Where `rebuild` stages a grown archive before the rename.
    private var rebuildURL: URL {
        self.url.deletingLastPathComponent().appendingPathComponent("\(self.url.lastPathComponent).rebuild")
    }

    /// The size the file must have for the current geometry.
    public var expectedFileSize: Int {
        Self.fileSize(buckets: Int(self.header.buckets), lanes: self.entries.count)
    }

    public static func fileSize(buckets: Int, lanes: Int) -> Int {
        HistoryArchiveHeader.byteWidth + lanes * HistoryLaneEntry.byteWidth + buckets * lanes * HistorySlot.byteWidth
    }

    // MARK: - lifecycle (create, open, preallocate, close)

    /// Opens the tier file, creating it when it is missing and replacing it
    /// when it is damaged. Never throws for damage — that is the whole point of
    /// the outcome: history degrades, the app does not (§1).
    ///
    /// It does throw when the file could not be *examined*: a transient `errno`
    /// says nothing about the contents, so the file is left exactly as it is
    /// and the caller decides whether to retry or to record nothing this
    /// launch. Quarantining on an `EMFILE` would destroy a year of history over
    /// a descriptor leak somewhere else in the app.
    @discardableResult
    public func open() throws -> HistoryArchiveOpenOutcome {
        self.close()
        // A `kill -9` between claiming a rebuild's extent and its rename leaves
        // a full-size orphan that nothing ever reads again; sweeping it here is
        // what keeps `history/` inside the ceiling §3 declares.
        try? FileManager.default.removeItem(at: self.rebuildURL)

        if !FileManager.default.fileExists(atPath: self.url.path) {
            try self.create()
            return .created
        }

        let damage: HistoryArchiveDamage?
        do {
            damage = try self.load()
        } catch let failure as HistoryArchiveError {
            self.reset()
            // Removed between the existence check and the open: there is
            // nothing to quarantine, and a fresh archive is the right answer.
            if case .io(let code) = failure, code == ENOENT {
                try self.create()
                return .created
            }
            throw failure
        } catch {
            self.reset()
            throw error
        }

        guard let found = damage else { return .existing }
        self.reset()
        self.quarantine()
        try self.create()
        return .recreated(found)
    }

    public func close() {
        if let base = self.mapBase {
            munmap(UnsafeMutableRawPointer(mutating: base), self.mapLength)
        }
        self.mapBase = nil
        self.mapLength = 0
        if self.fd >= 0 {
            _ = Darwin.close(self.fd)
        }
        self.fd = -1
    }

    /// `close`, plus the in-memory directory: a half-read archive must not keep
    /// lanes that nothing on disk backs any more.
    private func reset() {
        self.close()
        self.setEntries([], dirty: false)
    }

    /// The only place `entries` is replaced. `dirty` says whether the file still
    /// carries the previous directory; `checksum` seeds the CRC cache when the
    /// caller has just computed it from the very bytes it installed.
    private func setEntries(_ newEntries: [HistoryLaneEntry], dirty: Bool, checksum: UInt32? = nil) {
        self.entries = newEntries
        self.cachedDirectoryChecksum = checksum
        self.directoryDirty = dirty
    }

    /// Flushes the file's dirty blocks. The cadence is the recorder's call (§3);
    /// the archive only exposes the operation.
    public func sync() {
        guard self.fd >= 0 else { return }
        if fcntl(self.fd, F_FULLFSYNC) == -1 {
            _ = fsync(self.fd)
        }
    }

    /// Reads and validates the file. Returns the damage that makes it unusable
    /// — the caller quarantines and recreates on that — or `nil` when the
    /// archive is now open and mapped.
    ///
    /// The damage cases are exactly §3's list: bad magic, a bad header CRC, an
    /// unknown `formatVersion`, a geometry that is not this tier's, and a file
    /// too short to hold what its own header claims. An `errno` from `open`,
    /// `pread`, `fstat` or `mmap` is none of those — it describes the attempt,
    /// not the bytes — so it is thrown and the file is left untouched.
    private func load() throws -> HistoryArchiveDamage? {
        let fd = Darwin.open(self.url.path, O_RDWR)
        guard fd >= 0 else { throw HistoryArchiveError.io(errno) }
        self.fd = fd

        var headerBytes = [UInt8](repeating: 0, count: HistoryArchiveHeader.byteWidth)
        guard try self.read(into: &headerBytes, at: 0) else { return .shortHeader }

        let decoded: HistoryArchiveHeader
        switch HistoryArchiveHeader.decode(headerBytes) {
        case .success(let value): decoded = value
        case .failure(let damage): return damage
        }
        // Geometry first: the lane count drives every offset below, so it has
        // to be sane before anything is sized from it.
        guard decoded.step == UInt32(self.tier.step), decoded.buckets == UInt32(self.tier.buckets),
              decoded.lanes <= UInt32(HistoryLaneDirectory.laneCap) else {
            return .geometryMismatch
        }

        let lanes = Int(decoded.lanes)
        var directoryBytes = [UInt8](repeating: 0, count: lanes * HistoryLaneEntry.byteWidth)
        if lanes > 0, try !self.read(into: &directoryBytes, at: self.directoryOffset) {
            return .truncated
        }

        let directoryChecksum = HistoryCRC32.checksum(directoryBytes)
        let sums = HistoryArchiveHeader.checksums(headerBytes, directoryChecksum: directoryChecksum)
        guard sums.stored == sums.expected else {
            return .badChecksum
        }

        var loaded: [HistoryLaneEntry] = []
        loaded.reserveCapacity(lanes)
        for i in 0..<lanes {
            loaded.append(HistoryLaneEntry.decode(directoryBytes, at: i * HistoryLaneEntry.byteWidth))
        }

        self.header = decoded
        // Straight off the file, so the two agree by construction and the CRC
        // cache starts warm.
        self.setEntries(loaded, dirty: false, checksum: directoryChecksum)

        var info = stat()
        guard fstat(self.fd, &info) == 0 else {
            self.setEntries([], dirty: false)
            throw HistoryArchiveError.io(errno)
        }
        guard Int(info.st_size) >= self.expectedFileSize else {
            self.setEntries([], dirty: false)
            return .truncated
        }
        do {
            try self.map(length: Int(info.st_size))
        } catch {
            self.setEntries([], dirty: false)
            throw error
        }
        return nil
    }

    /// Creates an empty archive: header, no lanes, no matrix. Lanes are added
    /// later by `setDirectory`, which rebuilds the file around them.
    private func create() throws {
        try? FileManager.default.removeItem(at: self.url)
        let fd = Darwin.open(self.url.path, O_RDWR | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw HistoryArchiveError.io(errno) }
        self.fd = fd

        self.header = HistoryArchiveHeader(
            step: UInt32(self.tier.step), buckets: UInt32(self.tier.buckets), lanes: 0,
            lastCommitBucket: 0, monotonicAnchor: 0, createdTs: UInt64(Date().timeIntervalSince1970)
        )
        self.setEntries([], dirty: false)

        do {
            try Self.claim(fd: fd, size: self.expectedFileSize)
            try self.writeHeaderAndDirectory()
            try self.map(length: self.expectedFileSize)
        } catch {
            // A half-created archive must not look open: the descriptor would
            // leak and `isOpen` would report true with nothing mapped.
            self.reset()
            throw error
        }
    }

    /// Claims the extent up front: `F_PREALLOCATE` reserves it, `ftruncate`
    /// makes it the file's size. Preallocation is a mitigation and not a
    /// guarantee — copy-on-write can still need a fresh block, which is why
    /// `pwrite` errors are handled rather than assumed away (§3).
    private static func claim(fd: Int32, size: Int) throws {
        if size > 0 {
            var store = fstore_t(fst_flags: UInt32(F_ALLOCATECONTIG), fst_posmode: F_PEOFPOSMODE,
                                 fst_offset: 0, fst_length: off_t(size), fst_bytesalloc: 0)
            if fcntl(fd, F_PREALLOCATE, &store) == -1 {
                store.fst_flags = UInt32(F_ALLOCATEALL)
                _ = fcntl(fd, F_PREALLOCATE, &store) // best effort: a short file is not a failure
            }
        }
        guard ftruncate(fd, off_t(size)) == 0 else { throw HistoryArchiveError.io(errno) }
    }

    /// Read-only mapping: a failed writeback through a writable mapping would
    /// arrive as an uncatchable `SIGBUS` (§3, risk 5).
    private func map(length: Int) throws {
        if let base = self.mapBase {
            munmap(UnsafeMutableRawPointer(mutating: base), self.mapLength)
            self.mapBase = nil
            self.mapLength = 0
        }
        guard length > 0 else { return }
        guard let pointer = mmap(nil, length, PROT_READ, MAP_SHARED, self.fd, 0), pointer != MAP_FAILED else {
            throw HistoryArchiveError.io(errno)
        }
        self.mapBase = UnsafeRawPointer(pointer)
        self.mapLength = length
    }

    // MARK: - corruption (rename to .corrupt-<ts> and recreate)

    /// Keeps exactly one quarantined copy: a file that corrupts once tends to
    /// corrupt again, and this directory has a declared size ceiling.
    private func quarantine() {
        let manager = FileManager.default
        let folder = self.url.deletingLastPathComponent()
        let prefix = "\(self.url.lastPathComponent).corrupt-"

        var target = folder.appendingPathComponent("\(prefix)\(UInt64(Date().timeIntervalSince1970))")
        var attempt = 1
        while manager.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(prefix)\(UInt64(Date().timeIntervalSince1970))-\(attempt)")
            attempt += 1
        }
        do {
            try manager.moveItem(at: self.url, to: target)
        } catch {
            try? manager.removeItem(at: self.url)
            return
        }

        let siblings = (try? manager.contentsOfDirectory(atPath: folder.path))?
            .filter { $0.hasPrefix(prefix) && $0 != target.lastPathComponent } ?? []
        for name in siblings {
            try? manager.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    // MARK: - directory (read, write, T0 wins on disagreement)

    /// Installs the lane directory. Lanes only ever grow or are reused in
    /// place: a longer directory rebuilds the file copy-forward, an equal-length
    /// one is a directory rewrite, and a shorter one is a programming error.
    ///
    /// The entries given here **replace** the stored ones wholesale, mutable
    /// fields included. `firstValidBucket` and `lastUsedTs` belong to the
    /// archive's own bookkeeping, so a caller that rebuilds entries from its
    /// registry has to carry the stored values forward (`entry(lane:)`) — a
    /// freshly built entry would reset `firstValidBucket` to `noValidBucket` and
    /// hide data that is still on disk.
    public func setDirectory(_ newEntries: [HistoryLaneEntry]) throws {
        guard self.fd >= 0 else { throw HistoryArchiveError.notOpen }
        guard newEntries.count <= HistoryLaneDirectory.laneCap else {
            throw HistoryArchiveError.geometry("lane cap is \(HistoryLaneDirectory.laneCap)")
        }
        guard newEntries.count >= self.entries.count else {
            throw HistoryArchiveError.geometry("lane count cannot shrink in place")
        }

        if newEntries.count == self.entries.count {
            // Dirty from the assignment on: the file still carries the previous
            // directory until the write below returns, and if it throws the
            // next header write has to restate both regions.
            self.setEntries(newEntries, dirty: true)
            try self.writeHeaderAndDirectory()
            return
        }
        try self.rebuild(with: newEntries)
    }

    /// Copy-forward rebuild for lane growth. The row stride changes, so every
    /// row moves; slots carry their own bucket index, so the copy is a straight
    /// row-for-row transfer with the new lanes left zeroed (§3, "adding a lane
    /// never bumps the version").
    private func rebuild(with newEntries: [HistoryLaneEntry]) throws {
        let oldLanes = self.entries.count
        let newLanes = newEntries.count
        let buckets = Int(self.header.buckets)
        let oldRowBytes = oldLanes * HistorySlot.byteWidth
        let newRowBytes = newLanes * HistorySlot.byteWidth
        let oldMatrixOffset = self.matrixOffset

        let temporary = self.rebuildURL
        try? FileManager.default.removeItem(at: temporary)

        let fd = Darwin.open(temporary.path, O_RDWR | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw HistoryArchiveError.io(errno) }
        var completed = false
        defer {
            _ = Darwin.close(fd)
            if !completed { try? FileManager.default.removeItem(at: temporary) }
        }

        var newHeader = self.header
        newHeader.lanes = UInt32(newLanes)
        let directoryBytes = Self.encodeDirectory(newEntries)
        let directoryChecksum = HistoryCRC32.checksum(directoryBytes)
        let size = Self.fileSize(buckets: buckets, lanes: newLanes)

        try Self.claim(fd: fd, size: size)
        // One write, because one checksum covers both: see writeHeaderAndDirectory.
        try Self.write(Self.headerImage(newHeader, directory: directoryBytes, checksum: directoryChecksum),
                       at: 0, fd: fd)

        if oldLanes > 0 {
            // An open archive with lanes is always mapped, so this is a
            // programming error rather than a state to recover from — and
            // skipping the copy silently would be "drop all history" with no
            // error at all.
            guard let base = self.mapBase else { throw HistoryArchiveError.notOpen }
            let newMatrixOffset = HistoryArchiveHeader.byteWidth + newLanes * HistoryLaneEntry.byteWidth
            let rowsPerChunk = Swift.max(1, 262_144 / Swift.max(newRowBytes, 1))
            var buffer = [UInt8](repeating: 0, count: rowsPerChunk * newRowBytes)
            var row = 0
            while row < buckets {
                let rows = Swift.min(rowsPerChunk, buckets - row)
                buffer.withUnsafeMutableBytes { destination in
                    guard let start = destination.baseAddress else { return }
                    // The lanes the rebuild adds start zeroed, which decodes as
                    // no-data; one memset beats a bounds-checked byte loop over
                    // a quarter of a megabyte per chunk.
                    memset(start, 0, rows * newRowBytes)
                    for i in 0..<rows {
                        let from = oldMatrixOffset + (row + i) * oldRowBytes
                        guard from + oldRowBytes <= self.mapLength else { continue }
                        start.advanced(by: i * newRowBytes)
                            .copyMemory(from: base.advanced(by: from), byteCount: oldRowBytes)
                    }
                }
                try Self.write(buffer, count: rows * newRowBytes, at: newMatrixOffset + row * newRowBytes, fd: fd)
                row += rows
            }
        }

        if fcntl(fd, F_FULLFSYNC) == -1 { _ = fsync(fd) }
        self.close()
        // `rename(2)` replaces in one step. An unlink-then-move would leave a
        // window with no archive at all, and would have already deleted the
        // original by the time a failing move could be reported.
        guard rename(temporary.path, self.url.path) == 0 else {
            // Read before `reset`, whose `munmap`/`close` would clobber it.
            let code = errno
            // `close()` has already run, so the archive is not open any more;
            // leaving the lanes behind would have `laneCount` and `directory`
            // describing an archive nothing can read.
            self.reset()
            throw HistoryArchiveError.io(code)
        }
        completed = true

        self.header = newHeader
        self.setEntries(newEntries, dirty: false, checksum: directoryChecksum)
        let reloaded: HistoryArchiveDamage?
        do {
            reloaded = try self.load()
        } catch {
            self.reset()
            throw error
        }
        if reloaded != nil {
            self.reset()
            throw HistoryArchiveError.io(EIO)
        }
    }

    // MARK: - commit (pwrite of a changed row range, fsync policy)

    /// Writes whole bucket rows. Rows that land on consecutive ring indices are
    /// coalesced into one `pwrite`; the header follows, so `lastCommitBucket`
    /// and any moved `firstValidBucket` are durable in the same commit.
    ///
    /// A ring cell is overwritten unconditionally: the archive stamps and stores
    /// what it is given. §4's rule that a backward clock step must never
    /// overwrite a slot whose stamp belongs to the pre-step era is therefore the
    /// **caller's**, and lives in the clock and recorder path — the archive has
    /// no notion of an era to filter on. `stamp(bucket:lane:)` is the primitive
    /// that rule needs: `slot` returns `nil` for exactly the cells it has to
    /// look at.
    public func commit(_ rows: [HistoryRow]) throws {
        guard self.fd >= 0 else { throw HistoryArchiveError.notOpen }
        // Before the first lane is registered there is no matrix to write into;
        // that is the state of a fresh archive, not a failure.
        let lanes = self.entries.count
        guard lanes > 0, !rows.isEmpty else { return }

        for row in rows where row.slots.count != lanes {
            throw HistoryArchiveError.geometry("row for bucket \(row.bucket) has \(row.slots.count) slots, expected \(lanes)")
        }

        let sorted = rows.sorted { $0.bucket < $1.bucket }
        let buckets = self.header.buckets
        var newest = self.header.lastCommitBucket

        // `firstValidBucket` is only moved once the rows behind it are on disk:
        // an in-memory directory that claims data a failed `pwrite` never wrote
        // would disagree with the file it describes.
        var pending: [(lane: Int, bucket: UInt32)] = []

        do {
            var index = 0
            while index < sorted.count {
                // One run of rows that is contiguous in both bucket and ring index.
                var end = index + 1
                while end < sorted.count,
                      sorted[end].bucket == sorted[end - 1].bucket &+ 1,
                      sorted[end].bucket % buckets == (sorted[end - 1].bucket % buckets) + 1 {
                    end += 1
                }

                var buffer = [UInt8](repeating: 0, count: (end - index) * self.rowBytes)
                for (offset, row) in sorted[index..<end].enumerated() {
                    for lane in 0..<lanes {
                        var slot = row.slots[lane]
                        slot.bucket = row.bucket // the stamp is the archive's, never the caller's
                        slot.encode(into: &buffer, at: offset * self.rowBytes + lane * HistorySlot.byteWidth)

                        if slot.isRecorded, self.entries[lane].firstValidBucket > row.bucket {
                            pending.append((lane, row.bucket))
                        }
                    }
                    if row.bucket > newest { newest = row.bucket }
                }

                let ring = Int(sorted[index].bucket % buckets)
                try self.write(buffer, at: self.matrixOffset + ring * self.rowBytes)

                for update in pending where self.entries[update.lane].firstValidBucket > update.bucket {
                    self.entries[update.lane].firstValidBucket = update.bucket
                    self.cachedDirectoryChecksum = nil
                    self.directoryDirty = true
                }
                pending.removeAll(keepingCapacity: true)
                index = end
            }
        } catch {
            // A later run failed after an earlier one landed and moved a
            // `firstValidBucket`: from here on only a header *and* directory
            // write is safe, whatever the next commit does.
            self.directoryDirty = true
            throw error
        }

        self.header.lastCommitBucket = newest
        try self.persistHeader()
    }

    /// Persists the monotonic anchor the clock code compares against after a
    /// relaunch (§4). Cheap: one 4 KiB header write, unless a previous failure
    /// left the directory owing.
    public func setMonotonicAnchor(_ value: UInt64) throws {
        guard self.fd >= 0 else { throw HistoryArchiveError.notOpen }
        self.header.monotonicAnchor = value
        try self.persistHeader()
    }

    /// Puts the anchor in the header without a write of its own.
    ///
    /// The anchor is only meaningful paired with the wall-clock time it was
    /// taken at, and the only wall-clock time the header stores is
    /// `lastCommitBucket` — so the pair has to be written by the same `commit`
    /// that moves the cursor, not by a second `pwrite` beside it. Staging is
    /// what lets the commit path stay at one 4 KiB write per cycle (§3).
    public func stageMonotonicAnchor(_ value: UInt64) {
        self.header.monotonicAnchor = value
    }

    // MARK: - reset (a clock step or a gap past the ring's own capacity)

    /// Throws the tier's contents away and starts it again, keeping its lanes.
    ///
    /// §4 resets a tier rather than interleaving two eras — after a backward
    /// clock step larger than the tier's window, or a gap at or beyond its
    /// capacity — and is explicit that the reset must *not* iterate the ring:
    /// backfilling a whole matrix would dirty multiple MiB in one burst at
    /// exactly the worst moment for battery. So the file is recreated instead.
    /// `ftruncate` gives a sparse, all-zero matrix for free, which is the same
    /// state a first launch starts in, and the only bytes that actually reach
    /// the disk are the header and the lane directory.
    ///
    /// The lanes survive with their identity, unit, kind and label — a reset
    /// tier is still the same set of series — but `firstValidBucket` goes back
    /// to `noValidBucket`, which is what makes every cell read as no-data until
    /// the new era writes one of its own.
    public func discardAll() throws {
        guard self.fd >= 0 else { throw HistoryArchiveError.notOpen }
        var carried = self.entries
        for index in carried.indices {
            carried[index].firstValidBucket = HistoryLaneEntry.noValidBucket
            // The flag says the cells at this id belong to a displaced
            // identity; after the reset no cell belongs to anyone. It is
            // cleared here only in the tier's own copy — the registry still
            // holds the flag, and `reconcile` carries the registry's flags
            // forward — so it reappears until the registry retires it. That
            // costs a lane staying greyed in the sidebar for a while and
            // nothing in the data, which is why it is not worth a second
            // path from here back into the registry.
            carried[index].flags.remove(.reclaimed)
        }

        self.close()
        try self.create()
        guard !carried.isEmpty else { return }
        try self.setDirectory(carried)
    }

    // MARK: - read (mmap, bounds-checked slot access, stale-stamp rejection)

    /// One cell, or `nil` when there is nothing to show: lane out of range,
    /// bucket older than the lane's first valid one, a slot whose stamp belongs
    /// to another wrap, or a file too short to hold the cell at all. Every
    /// one of those is a read of a fresh, wrapped or truncated archive, not an
    /// error condition.
    public func slot(bucket: UInt32, lane: Int) -> HistorySlot? {
        guard let base = self.mapBase, lane >= 0, lane < self.entries.count else { return nil }
        let entry = self.entries[lane]
        guard entry.firstValidBucket != HistoryLaneEntry.noValidBucket, bucket >= entry.firstValidBucket else {
            return nil
        }
        let ring = Int(bucket % self.header.buckets)
        let offset = self.matrixOffset + (ring * self.entries.count + lane) * HistorySlot.byteWidth
        guard offset >= 0, offset + HistorySlot.byteWidth <= self.mapLength else { return nil }

        let slot = HistorySlot.decode(base, at: offset)
        guard slot.bucket == bucket else { return nil } // stale: an earlier wrap, or a torn write
        return slot
    }

    /// The bucket stamp physically present in a ring cell, whatever era it
    /// belongs to, or `nil` when the cell is not there to read at all.
    ///
    /// `slot` deliberately hides this: a cell whose stamp is not the bucket
    /// asked for reads as no-data, which is what makes a wrapped ring safe. But
    /// §4's rule — a backward clock step must never overwrite a slot whose stamp
    /// belongs to the pre-step era — is the caller's to enforce, and it cannot
    /// enforce what it cannot see. `firstValidBucket` is not consulted: the
    /// question is what the bytes hold, not what is worth showing.
    public func stamp(bucket: UInt32, lane: Int) -> UInt32? {
        guard let base = self.mapBase, lane >= 0, lane < self.entries.count else { return nil }
        let ring = Int(bucket % self.header.buckets)
        let offset = self.matrixOffset + (ring * self.entries.count + lane) * HistorySlot.byteWidth
        guard offset >= 0, offset + HistorySlot.byteWidth <= self.mapLength else { return nil }
        return HistoryBytes.get(UInt32.self, from: base, at: offset)
    }

    /// A whole row, in lane order, with the same per-slot rules as `slot`.
    public func row(bucket: UInt32) -> [HistorySlot?] {
        (0..<self.entries.count).map { self.slot(bucket: bucket, lane: $0) }
    }

    /// One lane across a bucket range, oldest first.
    public func series(lane: Int, buckets range: Range<UInt32>) -> [HistorySlot?] {
        range.map { self.slot(bucket: $0, lane: lane) }
    }

    public func entry(lane: Int) -> HistoryLaneEntry? {
        guard lane >= 0, lane < self.entries.count else { return nil }
        return self.entries[lane]
    }

    // MARK: - raw io

    /// Test seam, called once per `pwrite` with the file offset and the byte
    /// count. Two properties of this file have no other way to be asserted from
    /// outside: that the header and the directory leave as a single write, and
    /// what the archive does when a write fails the way a full volume makes it
    /// fail (§3) — throwing from here is how a test produces an `ENOSPC`.
    /// Nothing in the app sets it. `public` only because the test target links
    /// Kit as a plain framework (`import Kit`, not `@testable`), so that a test
    /// run stays possible in any configuration.
    public static var writeObserver: ((_ offset: Int, _ count: Int) throws -> Void)?

    private static func encodeDirectory(_ entries: [HistoryLaneEntry]) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: entries.count * HistoryLaneEntry.byteWidth)
        for (index, entry) in entries.enumerated() {
            entry.encode(into: &buffer, at: index * HistoryLaneEntry.byteWidth)
        }
        return buffer
    }

    /// The encoded directory's CRC, computed once per change of `entries`.
    private func directoryChecksum() -> UInt32 {
        if let cached = self.cachedDirectoryChecksum { return cached }
        let value = HistoryCRC32.checksum(Self.encodeDirectory(self.entries))
        self.cachedDirectoryChecksum = value
        return value
    }

    /// The 4 KiB header followed by the directory it is checksummed with, as one
    /// buffer. The two regions are physically adjacent and covered by one
    /// chained CRC, so they are written together or not at all.
    private static func headerImage(_ header: HistoryArchiveHeader, directory: [UInt8], checksum: UInt32) -> [UInt8] {
        var image = header.encoded(directoryChecksum: checksum)
        image.append(contentsOf: directory)
        return image
    }

    /// The header, plus the directory when the file does not already carry this
    /// one. A write that throws leaves the directory owing: a `pwrite` can stop
    /// part way, so the next successful write has to restate both regions rather
    /// than chain a checksum over bytes it did not put there.
    private func persistHeader() throws {
        do {
            if self.directoryDirty {
                try self.writeHeaderAndDirectory()
            } else {
                try self.writeHeader()
            }
        } catch {
            self.directoryDirty = true
            throw error
        }
    }

    /// The file already carries this directory — `directoryDirty` is what says
    /// so — and the checksum is chained directory-first, so the directory's
    /// cached CRC still describes the bytes on disk and only the 4 KiB header
    /// needs rewriting. This is the common commit path: one 4 KiB `pwrite`, no
    /// directory encode and no pass over up to 32 KiB of it.
    private func writeHeader() throws {
        try self.write(self.header.encoded(directoryChecksum: self.directoryChecksum()), at: 0)
    }

    /// One `pwrite` of `4096 + lanes × 128` bytes, not two. Two calls would open
    /// a window in which a `kill -9` leaves a header whose CRC covers the new
    /// directory sitting next to the old directory bytes — the next `open()`
    /// would read `.badChecksum` and throw away the whole tier. The window is
    /// hit on every lane registration and on the first commit of every lane, so
    /// it is a fresh install's normal path, and §3's "a torn header write cannot
    /// discard a year" has to survive it.
    ///
    /// This does not make the update atomic against a kernel panic or a power
    /// loss, which can still drop some of the blocks the single call dirtied;
    /// it removes the process-death window, which is the one users hit.
    private func writeHeaderAndDirectory() throws {
        let directoryBytes = Self.encodeDirectory(self.entries)
        let checksum = HistoryCRC32.checksum(directoryBytes)
        self.cachedDirectoryChecksum = checksum
        self.header.lanes = UInt32(self.entries.count)
        try self.write(Self.headerImage(self.header, directory: directoryBytes, checksum: checksum), at: 0)
        // Only here: the two regions are on disk together, so the header alone
        // is enough again.
        self.directoryDirty = false
    }

    private func write(_ bytes: [UInt8], count: Int? = nil, at offset: Int) throws {
        try Self.write(bytes, count: count, at: offset, fd: self.fd)
    }

    private static func write(_ bytes: [UInt8], count: Int? = nil, at offset: Int, fd: Int32) throws {
        let total = count ?? bytes.count
        guard total > 0 else { return }
        precondition(total <= bytes.count, "write of \(total) B from a \(bytes.count) B buffer")
        try HistoryArchive.writeObserver?(offset, total)
        try bytes.withUnsafeBytes { buffer in
            var written = 0
            while written < total {
                let n = pwrite(fd, buffer.baseAddress!.advanced(by: written), total - written, off_t(offset + written))
                if n < 0 {
                    if errno == EINTR { continue }
                    throw HistoryArchiveError.io(errno) // ENOSPC and EDQUOT arrive here (§3)
                }
                if n == 0 { throw HistoryArchiveError.io(EIO) }
                written += n
            }
        }
    }

    /// Fills `bytes` entirely. `false` means the file genuinely ended early —
    /// that is damage, and the caller recreates. A failing `pread` throws
    /// instead: the bytes may be perfectly good and only the read went wrong.
    private func read(into bytes: inout [UInt8], at offset: Int) throws -> Bool {
        let total = bytes.count
        guard total > 0 else { return true }
        return try bytes.withUnsafeMutableBytes { buffer in
            var got = 0
            while got < total {
                let n = pread(self.fd, buffer.baseAddress!.advanced(by: got), total - got, off_t(offset + got))
                if n < 0 {
                    if errno == EINTR { continue }
                    throw HistoryArchiveError.io(errno)
                }
                if n == 0 { return false }
                got += n
            }
            return true
        }
    }
}

// MARK: - cross-process lock

/// The result of one `acquire()`. An enum rather than a `Bool` because the
/// caller renders one of these as a user-visible banner and the other as
/// nothing at all.
public enum HistoryLockOutcome: Equatable {
    case acquired
    /// Another copy of Stats holds the lock: the settings banner is true.
    case heldByAnotherProcess
    /// The lock could not even be attempted — a missing or unwritable
    /// directory, an exhausted descriptor table. Carries `errno` where there is
    /// one, and `0` when the failure came from `FileManager` instead.
    case unavailable(Int32)
}

/// `flock(LOCK_EX|LOCK_NB)` on `history/.lock`. The loser of the race records
/// nothing and says so in settings — this fork routinely runs a locally signed
/// build beside the released one, so two writers is normal here (§3).
public final class HistoryLock {
    public let url: URL
    private var fd: Int32 = -1

    public init(url: URL) {
        self.url = url
    }

    deinit {
        self.release()
    }

    public var isHeld: Bool { self.fd >= 0 }

    /// Acquires the lock, or says why it could not. The two failures are not the
    /// same thing and the settings banner depends on the difference: only
    /// `heldByAnotherProcess` means a second Stats is recording, while a missing
    /// `history/` directory or an exhausted descriptor table is our own problem
    /// and must not be reported as somebody else's copy (§3, §6).
    @discardableResult
    public func acquire() -> HistoryLockOutcome {
        if self.fd >= 0 { return .acquired }
        let fd = Darwin.open(self.url.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return .unavailable(errno) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            _ = Darwin.close(fd)
            // `EWOULDBLOCK` is the only errno that means "somebody else has it";
            // anything else is a broken lock file, not a second instance.
            return code == EWOULDBLOCK ? .heldByAnotherProcess : .unavailable(code)
        }
        self.fd = fd
        return .acquired
    }

    public func release() {
        guard self.fd >= 0 else { return }
        _ = flock(self.fd, LOCK_UN)
        _ = Darwin.close(self.fd)
        self.fd = -1
    }
}

// MARK: - store

/// Owns the tier archives and the cross-process lock, and names the states the
/// settings section renders. The live status value belongs to the recorder,
/// which is the only thing that knows which of them is current.
///
/// Not thread safe: the recorder touches it only from the history queue.
public final class HistoryStore {
    public static let shared = HistoryStore()

    /// Recording is not possible, or is suspended, for one of these reasons.
    public enum Status: Equatable {
        case recording
        /// The master switch is off. Zero ingest and zero writes (§6).
        case disabled
        case lowDiskSpace
        case writeFailures
        case lockedByAnotherInstance
    }

    /// Below this much free space the commit is skipped and recording is marked
    /// paused: the store degrades before the volume does (§3). Decimal, because
    /// §3 says "below 50 MB free" and its size table means by MB what Finder
    /// shows — the settings copy and the doc have to agree on one number.
    public static let freeSpaceFloor: Int64 = 50 * 1_000 * 1_000

    private var lock: HistoryLock?
    private var archives: [HistoryTier: HistoryArchive] = [:]

    /// Where this store's files live. An instance property rather than only the
    /// static below so that a test — or a second store, if one is ever needed —
    /// can be pointed at a directory of its own.
    public let directory: URL

    public init(directory: URL = HistoryStore.directoryURL) {
        self.directory = directory
    }

    // MARK: - location (~/Library/Application Support/Stats/history, no backup)

    /// `~/Library/Application Support/Stats/history`. No `$TMPDIR` fallback,
    /// unlike `DB.swift`: writing a year of history where macOS purges it is
    /// worse than not writing it (§3).
    public static var directoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Stats")
            .appendingPathComponent("history")
    }

    /// Creates the directory and marks it excluded from Time Machine: these are
    /// continuously rewritten, disposable blocks (§3).
    ///
    /// The exclusion is read back rather than assumed. §3 and §8 both promise
    /// it, and a volume that quietly refuses `NSURLIsExcludedFromBackupKey`
    /// would otherwise look exactly like one that honoured it; failing to
    /// exclude is not a reason to stop recording, but it is a reason to say so.
    @discardableResult
    public static func prepareDirectory(_ url: URL = HistoryStore.directoryURL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)

        if !HistoryStore.isExcludedFromBackup(url), !HistoryStore.reportedBackupExclusionFailure {
            HistoryStore.reportedBackupExclusionFailure = true
            error("history directory is not excluded from Time Machine: \(url.path)")
        }
        return url
    }

    /// Whether the directory is actually excluded from Time Machine backups.
    public static func isExcludedFromBackup(_ url: URL) -> Bool {
        ((try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup) ?? false
    }

    /// Logged once per launch: the directory is prepared on every open and a
    /// line per commit cycle would be its own problem.
    ///
    /// Unsynchronised, which is only safe because `prepareDirectory` is called
    /// from the history queue and from nowhere else. A caller that reaches it
    /// from main — a settings action, say — has to give this flag a lock or an
    /// atomic first; the worst it can cost today is a duplicate log line, but
    /// the precondition is worth naming rather than rediscovering.
    private static var reportedBackupExclusionFailure = false

    // MARK: - lock (flock(LOCK_EX|LOCK_NB) on history/.lock)

    /// The directory is prepared first: on a first launch it does not exist yet,
    /// and an unopenable lock file there would otherwise be reported as a second
    /// copy of Stats recording.
    @discardableResult
    public func acquireLock(in directory: URL? = nil) -> HistoryLockOutcome {
        if let lock = self.lock, lock.isHeld { return .acquired }
        let directory = directory ?? self.directory
        guard (try? HistoryStore.prepareDirectory(directory)) != nil else { return .unavailable(0) }

        let lock = HistoryLock(url: directory.appendingPathComponent(".lock"))
        let outcome = lock.acquire()
        guard outcome == .acquired else { return outcome }
        self.lock = lock
        return .acquired
    }

    public func releaseLock() {
        self.lock?.release()
        self.lock = nil
    }

    /// Whether this process is the one recording. The delete path asks, because
    /// unlinking archives another copy of Stats still has open would spend its
    /// disk without freeing it (§3).
    public var holdsLock: Bool { self.lock?.isHeld ?? false }

    // MARK: - free-space precondition

    /// The free-space precondition, split so the threshold itself is testable
    /// without filling a volume. Read every tenth commit and after any failure.
    public static func hasEnoughFreeSpace(available: Int64) -> Bool {
        available >= HistoryStore.freeSpaceFloor
    }

    /// `nil` when the volume cannot be queried — the caller treats that as
    /// "unknown", not as "full".
    public static func availableSpace(at url: URL = HistoryStore.directoryURL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return Int64(capacity)
    }

    // MARK: - open

    /// Opens one archive per tier the preset asks for, and drops any file the
    /// preset no longer covers from the open set.
    ///
    /// Damage is not an error here — `open()` quarantines and recreates, and the
    /// outcome says which tier that happened to — so this throws only when a
    /// file could not be examined at all (§3).
    @discardableResult
    public func open(preset: HistoryRetentionPreset) throws -> [HistoryTier: HistoryArchiveOpenOutcome] {
        try HistoryStore.prepareDirectory(self.directory)

        var opened: [HistoryTier: HistoryArchive] = [:]
        var outcomes: [HistoryTier: HistoryArchiveOpenOutcome] = [:]
        for tier in preset.tiers {
            let archive = self.archives[tier]
                ?? HistoryArchive(tier: tier, url: self.directory.appendingPathComponent(tier.fileName))
            outcomes[tier] = try archive.open()
            opened[tier] = archive
        }
        for (tier, archive) in self.archives where opened[tier] == nil {
            archive.close()
        }
        self.archives = opened

        try self.reconcileDirectories()
        return outcomes
    }

    public func archive(_ tier: HistoryTier) -> HistoryArchive? {
        self.archives[tier]
    }

    public var openTiers: [HistoryTier] {
        self.archives.keys.sorted { $0.rawValue < $1.rawValue }
    }

    /// Forgets a tier whose file did not survive an operation on it, closing
    /// whatever is left of it.
    ///
    /// The alternative is worse than losing the tier: an archive that is closed
    /// or has lost its lanes still answers `archive(_:)`, and every writer past
    /// that point returns early on an empty lane count — silently, for the life
    /// of the process. Handing back `nil` is the one thing every caller already
    /// handles.
    public func drop(_ tier: HistoryTier) {
        guard let archive = self.archives.removeValue(forKey: tier) else { return }
        archive.close()
    }

    public func closeAll() {
        for archive in self.archives.values {
            archive.close()
        }
        self.archives.removeAll()
    }

    public func sync() {
        for archive in self.archives.values {
            archive.sync()
        }
    }

    /// The directory is written into all three files whenever a lane is added,
    /// and a crash between those writes leaves them disagreeing. §3 settles it
    /// by fiat: **T0's copy wins** and the others are rewritten from it, keeping
    /// only their own `firstValidBucket` — a lane present in T0 but absent in T2
    /// simply has no T2 data yet, which `firstValidBucket` already expresses.
    private func reconcileDirectories() throws {
        guard let t0 = self.archives[.t0] else { return }
        let primary = t0.directory

        for tier in self.openTiers where tier != .t0 {
            guard let archive = self.archives[tier] else { continue }
            if primary.count < archive.laneCount {
                // T0 was quarantined and recreated, so the lane ids in this
                // tier's matrix no longer describe anything T0 can name. The
                // file cannot shrink in place and its contents are unreadable
                // either way, so it starts again.
                error("history: \(tier.fileName) has lanes T0 does not, recreating it")
                archive.close()
                try? FileManager.default.removeItem(at: archive.url)
                _ = try archive.open()
            }
            guard !primary.isEmpty else { continue }
            try archive.setDirectory(HistoryLaneDirectory.reconcile(primary: primary, with: archive.directory))
        }
    }

    // MARK: - status and size readout (lane count, bytes on disk)

    /// What the settings row puts next to the lane count (§6). Blocks on the
    /// filesystem, so the caller keeps it off main.
    ///
    /// Allocated size rather than logical size, because that is the number
    /// Finder shows and the number §3's ceiling is quoted in — and because the
    /// tier files are preallocated, which is exactly the difference. Files the
    /// store does not own are counted too: a quarantined `.corrupt-<ts>` still
    /// costs the user disk, and a readout that hid it would understate the
    /// directory it claims to measure.
    ///
    /// Safe from any thread. It touches only `directory`, which is a `let`, and
    /// the filesystem; it reads none of the mutable state the rest of this
    /// class keeps for the history queue.
    public var bytesOnDisk: Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: self.directory, includingPropertiesForKeys: Array(keys)
        ) else { return 0 }

        var total: Int64 = 0
        for url in contents {
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            guard let bytes = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize else {
                continue
            }
            total += Int64(bytes)
        }
        return total
    }

    // MARK: - deleteAll (quiesce, munmap, unlink, recreate)

    /// Throws every byte of recorded history away and leaves an empty directory
    /// behind. The Delete button in settings and `Reset settings` are the two
    /// callers (§6).
    ///
    /// History queue only, and with ingest already quiesced: the mappings are
    /// torn down here, and a commit racing that would be writing into a
    /// descriptor this method is closing.
    ///
    /// Order matters and is the whole reason this is not a `removeItem` loop at
    /// the call site. `closeAll()` runs first so every `mmap` is gone before the
    /// file it maps is unlinked — §3's `SIGBUS` answer is that read mappings
    /// "tear down on the history queue before any unlink", and nothing is ever
    /// truncated. The `.lock` file is deliberately kept: this process still
    /// holds a `flock` on that inode, and unlinking it would let a second copy
    /// of Stats create a fresh one and take a lock that does not exclude ours.
    @discardableResult
    public func deleteAll() -> Bool {
        self.closeAll()

        let manager = FileManager.default
        var ok = true
        var contents: [URL] = []
        do {
            contents = try manager.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil)
        } catch let failure {
            // An unreadable directory is the one failure that hides every
            // other: the list comes back empty, the loop unlinks nothing and
            // every single-file error it would have reported never happens.
            ok = false
            error("history: the directory could not be listed for a delete: \(failure)")
        }
        for url in contents where url.lastPathComponent != ".lock" {
            do {
                try manager.removeItem(at: url)
            } catch let failure {
                ok = false
                error("history: \(url.lastPathComponent) could not be deleted: \(failure)")
            }
        }

        // The directory itself survives a delete — it carries the Time Machine
        // exclusion, and the caller is about to reopen into it.
        if (try? HistoryStore.prepareDirectory(self.directory)) == nil { ok = false }
        return ok
    }
}

// MARK: - bytes

/// Fixed-width little-endian access, done by copy rather than by a typed store,
/// so nothing depends on the alignment of an offset inside the file.
internal enum HistoryBytes {
    @inline(__always)
    static func put<T: FixedWidthInteger>(_ value: T, into buffer: inout [UInt8], at offset: Int) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { source in
            for i in 0..<source.count { buffer[offset + i] = source[i] }
        }
    }

    @inline(__always)
    static func putBigEndian<T: FixedWidthInteger>(_ value: T, into buffer: inout [UInt8], at offset: Int) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { source in
            for i in 0..<source.count { buffer[offset + i] = source[i] }
        }
    }

    @inline(__always)
    static func get<T: FixedWidthInteger>(_ type: T.Type, from pointer: UnsafeRawPointer, at offset: Int) -> T {
        var value = T.zero
        withUnsafeMutableBytes(of: &value) { destination in
            destination.baseAddress!.copyMemory(from: pointer.advanced(by: offset), byteCount: MemoryLayout<T>.size)
        }
        return T(littleEndian: value)
    }

    @inline(__always)
    static func getBigEndian<T: FixedWidthInteger>(_ type: T.Type, from pointer: UnsafeRawPointer, at offset: Int) -> T {
        var value = T.zero
        withUnsafeMutableBytes(of: &value) { destination in
            destination.baseAddress!.copyMemory(from: pointer.advanced(by: offset), byteCount: MemoryLayout<T>.size)
        }
        return T(bigEndian: value)
    }

    @inline(__always)
    static func get<T: FixedWidthInteger>(_ type: T.Type, from bytes: [UInt8], at offset: Int) -> T {
        guard offset >= 0, offset + MemoryLayout<T>.size <= bytes.count else { return T.zero }
        return bytes.withUnsafeBytes { get(type, from: $0.baseAddress!, at: offset) }
    }

    @inline(__always)
    static func getBigEndian<T: FixedWidthInteger>(_ type: T.Type, from bytes: [UInt8], at offset: Int) -> T {
        guard offset >= 0, offset + MemoryLayout<T>.size <= bytes.count else { return T.zero }
        return bytes.withUnsafeBytes { getBigEndian(type, from: $0.baseAddress!, at: offset) }
    }
}

// MARK: - crc32

/// CRC-32 (IEEE) over a byte buffer. Kept in Swift on purpose: there is no zlib
/// import in the project and Kit's umbrella header must stay untouched (§3).
internal enum HistoryCRC32 {
    // MARK: - lazily built 256-entry table

    private static let table: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
            }
            return value
        }
    }()

    // MARK: - checksum(_:)

    /// `seed` chains two buffers without concatenating them: the header image
    /// and the lane directory are checksummed as one stream.
    static func checksum(_ bytes: [UInt8], seed: UInt32 = 0) -> UInt32 {
        var crc = ~seed
        for byte in bytes {
            crc = (crc >> 8) ^ HistoryCRC32.table[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        return ~crc
    }
}
