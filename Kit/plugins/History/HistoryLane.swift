//
//  HistoryLane.swift
//  Kit
//
//  Persistent usage history: lane identity and the on-disk lane directory.
//  Design: docs/usage-history-design.md (§3 Storage), exelban/stats#1194.
//

import CryptoKit
import Foundation

// MARK: - lane vocabulary

/// The module a lane belongs to. Stored as one byte in the directory entry and
/// used to group the window sidebar.
public enum HistoryLaneModule: UInt8 {
    case cpu = 0
    case ram = 1
    case gpu = 2
    case net = 3
    case disk = 4
    case battery = 5
    case sensors = 6

    /// The app's own module enum, narrowed to the modules that record. The
    /// three that do not — Bluetooth, Clock and Remote — are v1 non-goals (§1),
    /// and `combined` is not a module at all, so they map to `nil` rather than
    /// to a lane module that nothing would ever write to.
    public init?(_ module: ModuleType) {
        switch module {
        case .CPU: self = .cpu
        case .RAM: self = .ram
        case .GPU: self = .gpu
        case .network: self = .net
        case .disk: self = .disk
        case .battery: self = .battery
        case .sensors: self = .sensors
        default: return nil
        }
    }
}

/// The unit of the stored scalar. Drives the y axis and the CSV header.
public enum HistoryLaneUnit: UInt8 {
    case percent = 0
    case bytesPerSec = 1
    case bytes = 2
    case celsius = 3
    case watts = 4
    case volts = 5
    case rpm = 6
}

/// How a lane behaves between samples (§2).
/// - `rate`: per-tick delta divided by elapsed time; gaps honestly.
/// - `gauge`: instantaneous reading.
/// - `step`: holds its last value for a bounded window, written as `.held`.
public enum HistoryLaneKind: UInt8 {
    case rate = 0
    case gauge = 1
    case step = 2
}

public struct HistoryLaneFlags: OptionSet {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// The lane's source has not been seen this launch — an unplugged volume,
    /// an interface that is gone. It keeps its data and its slot, and this is
    /// the flag the sidebar greys on (§3).
    public static let orphan = HistoryLaneFlags(rawValue: 1 << 0)
    /// The id was handed to a new identity and the matrix still holds the cells
    /// the displaced one wrote. Transient: retired as soon as the new occupant
    /// has data of its own, because `firstValidBucket` then says the same thing
    /// more precisely. Never a reason to grey a lane — a reclaimed id is a lane
    /// that is actively recording.
    public static let reclaimed = HistoryLaneFlags(rawValue: 1 << 1)
}

// MARK: - identity

/// What a lane's identity is hashed from: the module, the most stable
/// identifier the hardware offers, and the metric taken off it.
///
/// `source` is the part that has to survive a reboot, a replug and a rename —
/// a volume UUID, an SMC key, a `GPU_Info.id`, a BSD interface name — never a
/// display name (§3, risk 4). It is empty for the lanes a machine has exactly
/// one of (`cpu.total`, `ram.usage`, `battery.level`), where the module and the
/// metric are already the whole identity.
public struct HistoryLaneKey: Hashable {
    public let module: HistoryLaneModule
    public let source: String
    public let metric: String

    public init(module: HistoryLaneModule, source: String = "", metric: String) {
        self.module = module
        self.source = source
        self.metric = metric
    }

    /// The string that is hashed. The separator is a character no identifier in
    /// the v1 set contains, so two different triples cannot spell the same key;
    /// the module goes in as its stored raw value rather than as a name, so a
    /// renamed enum case cannot silently re-identify every lane of a module.
    public var stableKey: String {
        "\(self.module.rawValue)|\(self.source)|\(self.metric)"
    }
}

/// The stable identity of a lane: the first 16 B of the SHA-256 of a key built
/// from the most stable identifiers available (volume UUID, SMC key,
/// `GPU_Info.id`, BSD interface name) — never a display name.
public struct HistoryLaneIdentity: Hashable {
    public static let byteWidth: Int = 16

    /// The 16 bytes as two halves rather than a `[UInt8]`: a fixed-width value
    /// type is free to hash, costs no allocation per identity, and cannot be
    /// constructed at the wrong length.
    public let high: UInt64
    public let low: UInt64

    public init(high: UInt64, low: UInt64) {
        self.high = high
        self.low = low
    }

    // MARK: - derivation from a stable key string

    /// SHA-256 of the key, truncated to its first 16 bytes. A hash rather than
    /// the key itself because the entry is fixed width and "volume UUID plus
    /// metric" does not fit in 16 B; 128 bits is far more than a 256-entry
    /// directory needs to stay collision-free, and truncating a SHA-256 is the
    /// standard way to get a short stable identifier that no one is tempted to
    /// parse back into its parts.
    public init(stableKey: String) {
        var high: UInt64 = 0
        var low: UInt64 = 0
        for (index, byte) in SHA256.hash(data: Data(stableKey.utf8)).enumerated() {
            if index < 8 {
                high = (high << 8) | UInt64(byte)
            } else if index < HistoryLaneIdentity.byteWidth {
                low = (low << 8) | UInt64(byte)
            } else {
                break
            }
        }
        self.init(high: high, low: low)
    }

    public init(key: HistoryLaneKey) {
        self.init(stableKey: key.stableKey)
    }

    // MARK: - encoding (16 B, big-endian halves, first field of the entry)

    internal func encode(into buffer: inout [UInt8], at offset: Int) {
        HistoryBytes.putBigEndian(self.high, into: &buffer, at: offset)
        HistoryBytes.putBigEndian(self.low, into: &buffer, at: offset + 8)
    }

    internal static func decode(_ bytes: [UInt8], at offset: Int) -> HistoryLaneIdentity {
        HistoryLaneIdentity(
            high: HistoryBytes.getBigEndian(UInt64.self, from: bytes, at: offset),
            low: HistoryBytes.getBigEndian(UInt64.self, from: bytes, at: offset + 8)
        )
    }
}

// MARK: - directory entry

/// One 128 B directory entry, written identically into every tier file.
public struct HistoryLaneEntry {
    public static let byteWidth: Int = 128
    public static let labelCapacity: Int = 88
    /// `firstValidBucket` sentinel: the lane exists but nothing has ever been
    /// written for it, so a fresh archive reads as no-data rather than as a
    /// year of flat zeros (§3).
    public static let noValidBucket: UInt32 = .max

    fileprivate static let offsetIdentity: Int = 0
    fileprivate static let offsetModule: Int = 16
    fileprivate static let offsetUnit: Int = 17
    fileprivate static let offsetKind: Int = 18
    fileprivate static let offsetFlags: Int = 19
    fileprivate static let offsetFirstValidBucket: Int = 20
    fileprivate static let offsetLastUsedTs: Int = 24
    fileprivate static let offsetLabelLength: Int = 32
    fileprivate static let offsetLabel: Int = 33

    public var identity: HistoryLaneIdentity
    public var module: HistoryLaneModule
    public var unit: HistoryLaneUnit
    public var kind: HistoryLaneKind
    public var flags: HistoryLaneFlags
    public var firstValidBucket: UInt32
    public var lastUsedTs: UInt64
    /// Human-readable name of what the lane measures ("Wi-Fi (en0)",
    /// "Macintosh HD", "CPU die"). Truncated on a scalar boundary.
    public var label: String

    public init(identity: HistoryLaneIdentity, module: HistoryLaneModule, unit: HistoryLaneUnit,
                kind: HistoryLaneKind, flags: HistoryLaneFlags = [],
                firstValidBucket: UInt32 = HistoryLaneEntry.noValidBucket,
                lastUsedTs: UInt64 = 0, label: String = "") {
        self.identity = identity
        self.module = module
        self.unit = unit
        self.kind = kind
        self.flags = flags
        self.firstValidBucket = firstValidBucket
        self.lastUsedTs = lastUsedTs
        self.label = label
    }

    // MARK: - encoding (fixed 128 B, UTF-8 label truncated on a scalar boundary)

    internal func encode(into buffer: inout [UInt8], at offset: Int) {
        self.identity.encode(into: &buffer, at: offset + HistoryLaneEntry.offsetIdentity)
        buffer[offset + HistoryLaneEntry.offsetModule] = self.module.rawValue
        buffer[offset + HistoryLaneEntry.offsetUnit] = self.unit.rawValue
        buffer[offset + HistoryLaneEntry.offsetKind] = self.kind.rawValue
        buffer[offset + HistoryLaneEntry.offsetFlags] = self.flags.rawValue
        HistoryBytes.put(self.firstValidBucket, into: &buffer, at: offset + HistoryLaneEntry.offsetFirstValidBucket)
        HistoryBytes.put(self.lastUsedTs, into: &buffer, at: offset + HistoryLaneEntry.offsetLastUsedTs)

        let label = HistoryLaneEntry.truncate(self.label)
        buffer[offset + HistoryLaneEntry.offsetLabelLength] = UInt8(label.count)
        for i in 0..<HistoryLaneEntry.labelCapacity {
            buffer[offset + HistoryLaneEntry.offsetLabel + i] = i < label.count ? label[i] : 0
        }
    }

    /// Total: unknown enum bytes and a length or UTF-8 sequence that a bit flip
    /// made nonsense all decode to something rather than trapping. The file's
    /// checksum is what actually rejects a damaged directory (§3).
    internal static func decode(_ bytes: [UInt8], at offset: Int) -> HistoryLaneEntry {
        let length = Swift.min(Int(HistoryBytes.get(UInt8.self, from: bytes, at: offset + offsetLabelLength)), labelCapacity)
        let start = offset + offsetLabel
        let label: String
        if length > 0, start + length <= bytes.count {
            label = String(decoding: bytes[start..<(start + length)], as: UTF8.self)
        } else {
            label = ""
        }

        return HistoryLaneEntry(
            identity: HistoryLaneIdentity.decode(bytes, at: offset + offsetIdentity),
            module: HistoryLaneModule(rawValue: HistoryBytes.get(UInt8.self, from: bytes, at: offset + offsetModule)) ?? .cpu,
            unit: HistoryLaneUnit(rawValue: HistoryBytes.get(UInt8.self, from: bytes, at: offset + offsetUnit)) ?? .percent,
            kind: HistoryLaneKind(rawValue: HistoryBytes.get(UInt8.self, from: bytes, at: offset + offsetKind)) ?? .gauge,
            flags: HistoryLaneFlags(rawValue: HistoryBytes.get(UInt8.self, from: bytes, at: offset + offsetFlags)),
            firstValidBucket: HistoryBytes.get(UInt32.self, from: bytes, at: offset + offsetFirstValidBucket),
            lastUsedTs: HistoryBytes.get(UInt64.self, from: bytes, at: offset + offsetLastUsedTs),
            label: label
        )
    }

    /// UTF-8, cut on a scalar boundary so a truncated label is still a string.
    internal static func truncate(_ label: String) -> [UInt8] {
        let utf8 = Array(label.utf8)
        guard utf8.count > HistoryLaneEntry.labelCapacity else { return utf8 }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(HistoryLaneEntry.labelCapacity)
        for scalar in label.unicodeScalars {
            let width = String(scalar).utf8.count
            if bytes.count + width > HistoryLaneEntry.labelCapacity { break }
            bytes.append(contentsOf: String(scalar).utf8)
        }
        return bytes
    }
}

// MARK: - registration

/// Everything needed to create a lane: its identity and the three bytes that
/// describe what it measures, plus the human label the sidebar shows.
public struct HistoryLaneDescriptor {
    public let key: HistoryLaneKey
    public let unit: HistoryLaneUnit
    public let kind: HistoryLaneKind
    public let label: String

    public init(key: HistoryLaneKey, unit: HistoryLaneUnit, kind: HistoryLaneKind, label: String) {
        self.key = key
        self.unit = unit
        self.kind = kind
        self.label = label
    }

    /// Hashes the key. Only ever called on the registration path — the hot path
    /// carries the integer id the registration returned (§2).
    public var identity: HistoryLaneIdentity { HistoryLaneIdentity(key: self.key) }
}

/// What registering a descriptor did. The caller needs the difference: a lane
/// that is new to this table — `registered` or `reclaimed` — has no accumulator
/// state, and a `reclaimed` one has matrix cells belonging to the identity it
/// displaced, which is why its `firstValidBucket` is reset.
public enum HistoryLaneRegistration: Equatable {
    case existing(Int)
    case registered(Int)
    case reclaimed(lane: Int, from: HistoryLaneIdentity)
    /// The table is full and every lane in it is still warm (§3): the new
    /// identity records nothing, the existing lanes keep recording, and the
    /// settings row says the cap was hit.
    case refused

    public var lane: Int? {
        switch self {
        case .existing(let lane), .registered(let lane), .reclaimed(let lane, _): return lane
        case .refused: return nil
        }
    }

    /// Whether the lane arrived without accumulator state, so that the caller
    /// binds it before the first fold.
    public var isNew: Bool {
        switch self {
        case .registered, .reclaimed: return true
        case .existing, .refused: return false
        }
    }
}

/// The registration seam the sink resolves through. A protocol rather than the
/// directory itself because the recorder has to do more than the directory does
/// on a new lane — bind an accumulator, write the directory into every tier —
/// and the module conformances must not have to know which of the two they are
/// talking to.
public protocol HistoryLaneRegistry: AnyObject {
    /// The integer lane id for this descriptor, registering it if it is new, or
    /// `nil` when the lane cannot be recorded.
    func lane(for descriptor: HistoryLaneDescriptor, at ts: UInt64) -> Int?
}

// MARK: - directory

/// The lane registry: resolves a lane key to the integer id used on the hot
/// path, holds the directory, and reclaims cold lanes by LRU once the cap is hit.
///
/// Not thread safe, and the seam it sits behind hides that: `HistorySink.lane`
/// reaches `HistoryLaneRegistry.lane(for:at:)` on whatever queue the reader
/// runs on — the main run loop, for Battery's IOPS callback — and `register`
/// mutates both `entries` and `index`. Two reader queues meeting a new lane at
/// the same instant would corrupt an array and a dictionary, not merely race a
/// value. The recorder that owns this object is therefore what serializes it
/// (§2, the accumulator lock), and nothing may call `register` directly.
public final class HistoryLaneDirectory {
    /// Structural cap; the size budget allows more, so this is what binds (§3).
    public static let laneCap: Int = 256

    /// How long a lane has to have gone unused before its slot can be handed to
    /// a new identity. LRU alone would let a machine whose lane set genuinely
    /// exceeds the cap evict and re-register the same lanes on every tick,
    /// shredding a day of data per round trip; a floor turns that into an
    /// honest refusal instead (§3, risk 2).
    public static let reclaimIdleFloor: UInt64 = 24 * 3600

    private var entries: [HistoryLaneEntry] = []
    private var index: [HistoryLaneIdentity: Int] = [:]

    /// Bumped by anything that changes the directory as the file stores it.
    /// The recorder writes the directory into all three tiers when this moves,
    /// which is the rare event §3's "written identically into all three tier
    /// files whenever a lane is added" describes — `lastUsedTs` moves on every
    /// sample and deliberately does not count.
    public private(set) var revision: UInt64 = 0

    public init() {}

    // MARK: - lookup (id -> entry, module grouping for the sidebar)

    public var count: Int { self.entries.count }
    public var isFull: Bool { self.entries.count >= HistoryLaneDirectory.laneCap }
    /// The directory as the tier files store it, in lane-id order.
    public var all: [HistoryLaneEntry] { self.entries }

    public func entry(_ lane: Int) -> HistoryLaneEntry? {
        guard lane >= 0, lane < self.entries.count else { return nil }
        return self.entries[lane]
    }

    public func lane(for identity: HistoryLaneIdentity) -> Int? {
        self.index[identity]
    }

    /// Lane ids of one module, in id order: the sidebar groups by the module
    /// byte and this is the grouping (§5).
    public func lanes(in module: HistoryLaneModule) -> [Int] {
        self.entries.indices.filter { self.entries[$0].module == module }
    }

    /// Adopts the directory read back from a tier file. Lane ids are positions
    /// in that array and nothing else, so the order the archive stored is the
    /// order that has to come back — a re-sorted directory would re-point every
    /// lane in the matrix at the wrong series.
    public func adopt(_ entries: [HistoryLaneEntry]) {
        self.entries = Array(entries.prefix(HistoryLaneDirectory.laneCap))
        self.index.removeAll(keepingCapacity: true)
        for (lane, entry) in self.entries.enumerated() {
            self.index[entry.identity] = lane
        }
        self.revision &+= 1
    }

    // MARK: - registration (key -> integer lane id, at registration time only)

    /// Resolves a descriptor to a lane id, creating the lane on first sight.
    ///
    /// A known identity keeps its id, its stored data and its
    /// `firstValidBucket`; only the mutable metadata is refreshed, because a
    /// volume can be renamed and a sensor's label is localized while neither
    /// changes what the lane is.
    @discardableResult
    public func register(_ descriptor: HistoryLaneDescriptor, at ts: UInt64) -> HistoryLaneRegistration {
        let identity = descriptor.identity

        if let lane = self.index[identity] {
            var entry = self.entries[lane]
            let changed = entry.label != descriptor.label || entry.unit != descriptor.unit
                || entry.kind != descriptor.kind || entry.flags.contains(.orphan)
            entry.label = descriptor.label
            entry.unit = descriptor.unit
            entry.kind = descriptor.kind
            entry.flags.remove(.orphan)
            entry.lastUsedTs = Swift.max(entry.lastUsedTs, ts)
            self.entries[lane] = entry
            if changed { self.revision &+= 1 }
            return .existing(lane)
        }

        if !self.isFull {
            let lane = self.entries.count
            self.entries.append(HistoryLaneDirectory.entry(descriptor, identity: identity, at: ts, flags: []))
            self.index[identity] = lane
            self.revision &+= 1
            return .registered(lane)
        }

        // MARK: - LRU reclaim on lastUsedTs

        guard let victim = self.coldestReclaimableLane(at: ts) else { return .refused }
        let displaced = self.entries[victim].identity
        self.index.removeValue(forKey: displaced)
        // `.reclaimed` and the reset `firstValidBucket` say the same thing from
        // two sides: the ring still holds the displaced identity's cells, and
        // none of them is to be read as this lane's data.
        self.entries[victim] = HistoryLaneDirectory.entry(descriptor, identity: identity, at: ts, flags: [.reclaimed])
        self.index[identity] = victim
        self.revision &+= 1
        return .reclaimed(lane: victim, from: displaced)
    }

    /// Records that a lane was written to. Cheap on purpose: it is called for
    /// every lane of every commit and must not move `revision`.
    ///
    /// The cost of that is drift: until something else dirties the directory,
    /// the stored `lastUsedTs` can be arbitrarily far behind the live one, and
    /// both the LRU victim choice and the sidebar's "last seen" date read the
    /// stored value after a relaunch. The recorder therefore has to flush the
    /// directory when the drift crosses a threshold — an hour is the figure —
    /// or fold it into the periodic `fsync`, or a lane that has been recording
    /// all week can look reclaimable at the next launch.
    public func touch(_ lane: Int, at ts: UInt64) {
        guard lane >= 0, lane < self.entries.count, ts > self.entries[lane].lastUsedTs else { return }
        self.entries[lane].lastUsedTs = ts
    }

    /// Marks a lane whose source has not been seen this launch: an unplugged
    /// volume, an interface that is gone. It keeps its data and its slot, and
    /// the sidebar greys it with its stored label and last-seen date (§3).
    public func markOrphan(_ lane: Int) {
        guard lane >= 0, lane < self.entries.count, !self.entries[lane].flags.contains(.orphan) else { return }
        self.entries[lane].flags.insert(.orphan)
        self.revision &+= 1
    }

    /// Carries `firstValidBucket` back from the archive that moved it, so a
    /// directory written from here does not hide data the file already holds.
    ///
    /// Moving it to a real bucket is also what retires `.reclaimed`. The flag
    /// says the cells at this id still belong to the identity this lane
    /// displaced; once the lane has written a bucket of its own,
    /// `firstValidBucket` is the whole of that story. Left set it would follow
    /// the id for the life of the archive and grey a lane that is recording.
    public func setFirstValidBucket(_ bucket: UInt32, lane: Int) {
        guard lane >= 0, lane < self.entries.count else { return }
        var entry = self.entries[lane]
        let retire = bucket != HistoryLaneEntry.noValidBucket && entry.flags.contains(.reclaimed)
        guard entry.firstValidBucket != bucket || retire else { return }
        entry.firstValidBucket = bucket
        if retire { entry.flags.remove(.reclaimed) }
        self.entries[lane] = entry
        self.revision &+= 1
    }

    /// The coldest lane that has been idle for at least `reclaimIdleFloor`, or
    /// `nil` when every lane is still warm.
    private func coldestReclaimableLane(at ts: UInt64) -> Int? {
        guard ts >= HistoryLaneDirectory.reclaimIdleFloor else { return nil }
        let cutoff = ts - HistoryLaneDirectory.reclaimIdleFloor

        var victim: Int?
        for lane in self.entries.indices where self.entries[lane].lastUsedTs <= cutoff {
            if let current = victim, self.entries[current].lastUsedTs <= self.entries[lane].lastUsedTs { continue }
            victim = lane
        }
        return victim
    }

    private static func entry(_ descriptor: HistoryLaneDescriptor, identity: HistoryLaneIdentity,
                              at ts: UInt64, flags: HistoryLaneFlags) -> HistoryLaneEntry {
        HistoryLaneEntry(
            identity: identity, module: descriptor.key.module, unit: descriptor.unit, kind: descriptor.kind,
            flags: flags, firstValidBucket: HistoryLaneEntry.noValidBucket, lastUsedTs: ts, label: descriptor.label
        )
    }

    // MARK: - merge (T0's copy wins when tiers disagree)

    /// The directory a coarse tier should carry, given T0's copy and its own.
    ///
    /// The directory is written into all three files whenever a lane is added,
    /// and a crash between those writes leaves them disagreeing; §3 settles it
    /// by fiat — **T0's copy wins** and the others are rewritten from it. What
    /// the coarse tier keeps is the one field that is genuinely its own:
    /// `firstValidBucket`, which says how much of *this* tier's matrix is
    /// populated. It survives only where the lane id still holds the same
    /// identity; anywhere else the cells at that id belong to another series
    /// and the tier reads as no-data until it fills again.
    public static func reconcile(primary: [HistoryLaneEntry], with secondary: [HistoryLaneEntry]) -> [HistoryLaneEntry] {
        primary.enumerated().map { lane, entry in
            var merged = entry
            if lane < secondary.count, secondary[lane].identity == entry.identity {
                merged.firstValidBucket = secondary[lane].firstValidBucket
            } else {
                merged.firstValidBucket = HistoryLaneEntry.noValidBucket
            }
            return merged
        }
    }
}

extension HistoryLaneDirectory: HistoryLaneRegistry {
    public func lane(for descriptor: HistoryLaneDescriptor, at ts: UInt64) -> Int? {
        self.register(descriptor, at: ts).lane
    }
}
