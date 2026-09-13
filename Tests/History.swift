//
//  History.swift
//  Tests
//
//  Persistent usage history: unit tests. This file is stubbed together with the
//  rest of the skeleton and grows with the code it covers — the archive in
//  commit 2, lanes and accumulators in commit 3, the recorder in commit 4.
//  Design: docs/usage-history-design.md (§10), exelban/stats#1194.
//

import XCTest
import Kit

final class HistoryTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        self.folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stats-history-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: self.folder)
    }

    // MARK: - archive
    //
    // Ring wraparound at a tier boundary; stale-slot rejection after a wrap;
    // firstValidBucket so a fresh archive reads as no-data; header CRC
    // rejection and recreate; truncated-file recreate; header rehydration
    // across a simulated launch; a failed write leaving the directory owing; a
    // bit-flip fuzz loop; the copy-forward rebuild
    // on lane growth. Directory disagreement between tiers arrives with the
    // registry that resolves it, and the three-strikes ENOSPC suspend with the
    // recorder that counts the strikes.

    func testFreshArchiveReadsAsNoData() throws {
        let archive = try self.openArchive(.t0, lanes: 2)

        XCTAssertEqual(archive.laneCount, 2)
        XCTAssertEqual(archive.entry(lane: 0)?.firstValidBucket, HistoryLaneEntry.noValidBucket)
        XCTAssertNil(archive.slot(bucket: 0, lane: 0))
        XCTAssertNil(archive.slot(bucket: 12_345, lane: 1))
        XCTAssertEqual(archive.row(bucket: 12_345).compactMap { $0 }.count, 0)

        // The first commit is what makes a lane readable, and only from there on.
        try archive.commit([Self.row(1_000, lanes: 2, base: 5)])
        XCTAssertEqual(archive.entry(lane: 0)?.firstValidBucket, 1_000)
        XCTAssertNil(archive.slot(bucket: 999, lane: 0))
        XCTAssertEqual(archive.slot(bucket: 1_000, lane: 0)?.max, 5)
        XCTAssertEqual(archive.slot(bucket: 1_000, lane: 1)?.max, 6)
    }

    func testRingWraparoundAtATierBoundary() throws {
        let archive = try self.openArchive(.t0, lanes: 2)
        let buckets = UInt32(HistoryTier.t0.buckets)
        let base: UInt32 = 100_000

        try archive.commit([Self.row(base, lanes: 2, base: 1), Self.row(base + 1, lanes: 2, base: 2)])
        try archive.commit([Self.row(base + buckets, lanes: 2, base: 9)])

        // Same ring index, one full turn later: the new bucket is what is there.
        XCTAssertEqual(archive.slot(bucket: base + buckets, lane: 0)?.max, 9)
        XCTAssertEqual(archive.slot(bucket: base + buckets, lane: 1)?.max, 10)
        XCTAssertNil(archive.slot(bucket: base, lane: 0))
        XCTAssertNil(archive.slot(bucket: base, lane: 1))
        // The neighbouring ring index is untouched by the wrap.
        XCTAssertEqual(archive.slot(bucket: base + 1, lane: 0)?.max, 2)
        XCTAssertEqual(archive.lastCommitBucket, base + buckets)
    }

    func testStaleSlotRejectionAfterAWrap() throws {
        let archive = try self.openArchive(.t0, lanes: 3)
        let buckets = UInt32(HistoryTier.t0.buckets)
        let written: UInt32 = 4_242

        try archive.commit([Self.row(written, lanes: 3, base: 4)])

        // Bytes exist at that ring index, but they are stamped for another wrap.
        XCTAssertNil(archive.slot(bucket: written + buckets, lane: 0))
        XCTAssertNil(archive.slot(bucket: written + buckets * 2, lane: 2))
        XCTAssertEqual(archive.row(bucket: written + buckets).compactMap { $0 }.count, 0)
        XCTAssertEqual(archive.slot(bucket: written, lane: 0)?.bucket, written)

        // The stamp is readable exactly where `slot` refuses: §4's rule that a
        // backward clock step must not overwrite a pre-step era is the caller's,
        // and this is what lets it see which era a ring cell holds.
        XCTAssertEqual(archive.stamp(bucket: written + buckets, lane: 0), written)
        XCTAssertEqual(archive.stamp(bucket: written, lane: 2), written)
        XCTAssertNil(archive.stamp(bucket: written, lane: 3))
    }

    func testChecksumRejectionQuarantinesAndRecreates() throws {
        let url = self.folder.appendingPathComponent(HistoryTier.t0.fileName)
        let archive = HistoryArchive(tier: .t0, url: url)
        XCTAssertEqual(try archive.open(), .created)
        try archive.setDirectory(Self.entries(2))
        try archive.commit([Self.row(500, lanes: 2, base: 3)])
        archive.close()

        // A flip in the mutable cursor: the geometry still reads fine, so only
        // the checksum can catch it.
        try Self.flipBit(at: url, byte: 20, bit: 0)

        let reopened = HistoryArchive(tier: .t0, url: url)
        XCTAssertEqual(try reopened.open(), .recreated(.badChecksum))
        XCTAssertEqual(reopened.laneCount, 0)
        XCTAssertNil(reopened.slot(bucket: 500, lane: 0))
        XCTAssertEqual(self.quarantinedFiles(for: HistoryTier.t0.fileName).count, 1)

        // A flip inside the lane directory is caught by the same checksum: lane
        // identity is what must not rot silently.
        try reopened.setDirectory(Self.entries(2))
        reopened.close()
        try Self.flipBit(at: url, byte: UInt64(HistoryArchiveHeader.byteWidth + 17), bit: 3)

        let again = HistoryArchive(tier: .t0, url: url)
        XCTAssertEqual(try again.open(), .recreated(.badChecksum))
        // Exactly one quarantined copy is kept.
        XCTAssertEqual(self.quarantinedFiles(for: HistoryTier.t0.fileName).count, 1)

        // And a wrecked magic is rejected before anything is sized from it.
        again.close()
        try Self.flipBit(at: url, byte: 1, bit: 2)
        let third = HistoryArchive(tier: .t0, url: url)
        XCTAssertEqual(try third.open(), .recreated(.badMagic))
        XCTAssertEqual(self.quarantinedFiles(for: HistoryTier.t0.fileName).count, 1)
    }

    /// A failure to *examine* the file is not damage: the archive is left
    /// exactly where it is, so a transient `errno` cannot cost a year of
    /// history. `EISDIR` stands in for the `EMFILE`/`EACCES`/`EIO` family
    /// because it is the one this test can produce deterministically.
    func testAnUnreadableFileIsNotQuarantined() throws {
        let url = self.folder.appendingPathComponent(HistoryTier.t0.fileName)
        let archive = HistoryArchive(tier: .t0, url: url)
        try archive.open()
        try archive.setDirectory(Self.entries(2))
        try archive.commit([Self.row(400, lanes: 2, base: 1)])
        archive.close()
        let before = try Self.fileSize(at: url)

        let blocked = self.folder.appendingPathComponent(HistoryTier.t1.fileName)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let failing = HistoryArchive(tier: .t1, url: blocked)
        XCTAssertThrowsError(try failing.open()) { thrown in
            XCTAssertEqual(thrown as? HistoryArchiveError, .io(EISDIR))
        }
        XCTAssertFalse(failing.isOpen)
        XCTAssertEqual(failing.laneCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: blocked.path))
        XCTAssertEqual(self.quarantinedFiles(for: HistoryTier.t1.fileName).count, 0)

        // And the archive that was never touched still reads as it did.
        XCTAssertEqual(try HistoryArchive(tier: .t0, url: url).open(), .existing)
        XCTAssertEqual(try Self.fileSize(at: url), before)
    }

    /// A `kill -9` between claiming a rebuild's extent and its rename leaves a
    /// full-size orphan nothing ever reads again; open sweeps it so `history/`
    /// stays inside the ceiling §3 declares.
    func testOpenSweepsAnOrphanedRebuildFile() throws {
        let url = self.folder.appendingPathComponent(HistoryTier.t0.fileName)
        let orphan = self.folder.appendingPathComponent("\(HistoryTier.t0.fileName).rebuild")
        try Data(repeating: 0, count: 64).write(to: orphan)

        let archive = HistoryArchive(tier: .t0, url: url)
        XCTAssertEqual(try archive.open(), .created)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testTruncatedFileIsRecreated() throws {
        let url = self.folder.appendingPathComponent(HistoryTier.t0.fileName)
        let archive = HistoryArchive(tier: .t0, url: url)
        try archive.open()
        try archive.setDirectory(Self.entries(2))
        try archive.commit([Self.row(600, lanes: 2, base: 1)])
        let full = archive.expectedFileSize
        archive.close()

        let handle = try FileHandle(forUpdating: url)
        try handle.truncate(atOffset: UInt64(HistoryArchiveHeader.byteWidth + 2 * HistoryLaneEntry.byteWidth + 100))
        try handle.close()

        let reopened = HistoryArchive(tier: .t0, url: url)
        XCTAssertEqual(try reopened.open(), .recreated(.truncated))
        XCTAssertEqual(reopened.laneCount, 0)
        XCTAssertEqual(reopened.expectedFileSize, HistoryArchiveHeader.byteWidth)
        XCTAssertNil(reopened.slot(bucket: 600, lane: 0))
        XCTAssertEqual(full, HistoryArchive.fileSize(buckets: HistoryTier.t0.buckets, lanes: 2))
    }

    /// The header and the lane directory are covered by one chained checksum,
    /// so they have to reach the file together. Both halves are asserted: the
    /// two paths that move the directory issue exactly one write at offset 0,
    /// of exactly `4096 + lanes × 128` bytes, and a snapshot taken right after
    /// either of them opens as a valid archive. Two separate `pwrite`s would
    /// leave a header whose CRC covers a directory the file does not have yet.
    func testHeaderAndDirectoryStayConsistentOnDisk() throws {
        let url = self.folder.appendingPathComponent(HistoryTier.t0.fileName)
        let archive = HistoryArchive(tier: .t0, url: url)
        try archive.open()

        var writes: [(offset: Int, count: Int)] = []
        HistoryArchive.writeObserver = { offset, count in writes.append((offset, count)) }
        defer { HistoryArchive.writeObserver = nil }

        let headerAndDirectory = HistoryArchiveHeader.byteWidth + 2 * HistoryLaneEntry.byteWidth
        try archive.setDirectory(Self.entries(2))
        XCTAssertEqual(writes.map { $0.offset }, [0])
        XCTAssertEqual(writes.map { $0.count }, [headerAndDirectory])

        let afterRegistration = try self.snapshot(of: url, as: "after-registration.rrd")
        XCTAssertEqual(try afterRegistration.open(), .existing)
        XCTAssertEqual(afterRegistration.laneCount, 2)
        XCTAssertEqual(afterRegistration.entry(lane: 1)?.firstValidBucket, HistoryLaneEntry.noValidBucket)

        writes.removeAll()
        try archive.commit([Self.row(800, lanes: 2, base: 1)])
        // The first commit on a lane moves `firstValidBucket`, so this one
        // carries the directory too — again as a single write.
        XCTAssertEqual(writes.filter { $0.offset == 0 }.map { $0.count }, [headerAndDirectory])

        let afterFirstCommit = try self.snapshot(of: url, as: "after-commit.rrd")
        XCTAssertEqual(try afterFirstCommit.open(), .existing)
        XCTAssertEqual(afterFirstCommit.entry(lane: 0)?.firstValidBucket, 800)
        XCTAssertEqual(afterFirstCommit.slot(bucket: 800, lane: 1)?.max, 2)

        // Every commit after that leaves the directory alone, and then the
        // header goes out on its own: one 4 KiB write per commit tick.
        writes.removeAll()
        try archive.commit([Self.row(801, lanes: 2, base: 2)])
        XCTAssertEqual(writes.filter { $0.offset == 0 }.map { $0.count }, [HistoryArchiveHeader.byteWidth])
    }

    /// A `pwrite` that fails mid-commit — which §3 says can happen at any time,
    /// `ENOSPC` on a copy-on-write volume — leaves the in-memory directory ahead
    /// of the file's. Every later header write must then carry the directory
    /// with it: a 4 KiB header whose chained CRC covers a directory the file
    /// does not hold reads as `.badChecksum` at the next launch, so a *failed*
    /// write followed by a *successful* one would cost a year of history. Damage
    /// and failure are different things, and only damage may throw a file away.
    func testAFailedWriteDoesNotStrandTheHeaderAheadOfTheDirectory() throws {
        let url = self.folder.appendingPathComponent(HistoryTier.t0.fileName)
        let archive = HistoryArchive(tier: .t0, url: url)
        try archive.open()
        try archive.setDirectory(Self.entries(2))

        // Two runs, because the buckets are not adjacent. The first lands and
        // moves `firstValidBucket` to 100; the second fails, so the commit never
        // reaches its header write at all.
        let matrixOffset = HistoryArchiveHeader.byteWidth + 2 * HistoryLaneEntry.byteWidth
        var rowWrites = 0
        HistoryArchive.writeObserver = { offset, _ in
            guard offset >= matrixOffset else { return }
            rowWrites += 1
            if rowWrites == 2 { throw HistoryArchiveError.io(ENOSPC) }
        }
        XCTAssertThrowsError(try archive.commit([Self.row(100, lanes: 2, base: 1),
                                                 Self.row(5_000, lanes: 2, base: 2)])) { thrown in
            XCTAssertEqual(thrown as? HistoryArchiveError, .io(ENOSPC))
        }
        HistoryArchive.writeObserver = nil
        XCTAssertEqual(rowWrites, 2)

        // The retry a cycle later succeeds and moves nothing in the directory,
        // which is exactly the case a header-only write would get wrong.
        try archive.commit([Self.row(5_060, lanes: 2, base: 3)])
        archive.close()

        let reopened = HistoryArchive(tier: .t0, url: url)
        XCTAssertEqual(try reopened.open(), .existing)
        XCTAssertEqual(self.quarantinedFiles(for: HistoryTier.t0.fileName).count, 0)
        XCTAssertEqual(reopened.entry(lane: 0)?.firstValidBucket, 100)
        XCTAssertEqual(reopened.slot(bucket: 100, lane: 0)?.max, 1)
        XCTAssertEqual(reopened.slot(bucket: 5_060, lane: 1)?.max, 4)
        // The row the failure dropped is simply not there; nothing else is lost.
        XCTAssertNil(reopened.slot(bucket: 5_000, lane: 0))
        XCTAssertEqual(reopened.lastCommitBucket, 5_060)
    }

    func testHeaderRehydratesAcrossALaunch() throws {
        let url = self.folder.appendingPathComponent(HistoryTier.t1.fileName)
        let archive = HistoryArchive(tier: .t1, url: url)
        try archive.open()
        try archive.setDirectory(Self.entries(3))
        try archive.commit([Self.row(7_000, lanes: 3, base: 2)])
        try archive.setMonotonicAnchor(123_456_789)
        let created = archive.createdTs
        archive.sync()
        archive.close()

        let relaunched = HistoryArchive(tier: .t1, url: url)
        XCTAssertEqual(try relaunched.open(), .existing)
        XCTAssertEqual(relaunched.lastCommitBucket, 7_000)
        XCTAssertEqual(relaunched.monotonicAnchor, 123_456_789)
        XCTAssertEqual(relaunched.createdTs, created)
        XCTAssertEqual(relaunched.laneCount, 3)
        XCTAssertEqual(relaunched.directory[2].label, "lane 2")
        XCTAssertEqual(relaunched.entry(lane: 1)?.firstValidBucket, 7_000)
        XCTAssertEqual(relaunched.slot(bucket: 7_000, lane: 1)?.sum, 3)
    }

    func testCopyForwardRebuildOnLaneGrowth() throws {
        let url = self.folder.appendingPathComponent(HistoryTier.t1.fileName)
        let archive = HistoryArchive(tier: .t1, url: url)
        try archive.open()
        try archive.setDirectory(Self.entries(2))

        let written: [UInt32] = [10, 11, 12, 5_000]
        for bucket in written {
            try archive.commit([Self.row(bucket, lanes: 2, base: Float(bucket))])
        }

        var grown = Self.entries(4)
        grown[0] = try XCTUnwrap(archive.entry(lane: 0))
        grown[1] = try XCTUnwrap(archive.entry(lane: 1))
        try archive.setDirectory(grown)

        XCTAssertEqual(archive.laneCount, 4)
        XCTAssertEqual(archive.expectedFileSize, HistoryArchive.fileSize(buckets: HistoryTier.t1.buckets, lanes: 4))
        for bucket in written {
            XCTAssertEqual(archive.slot(bucket: bucket, lane: 0)?.max, Float(bucket))
            XCTAssertEqual(archive.slot(bucket: bucket, lane: 1)?.max, Float(bucket) + 1)
            XCTAssertNil(archive.slot(bucket: bucket, lane: 2))
            XCTAssertNil(archive.slot(bucket: bucket, lane: 3))
        }
        XCTAssertEqual(archive.lastCommitBucket, 5_000)
        archive.close()

        let reopened = HistoryArchive(tier: .t1, url: url)
        XCTAssertEqual(try reopened.open(), .existing)
        XCTAssertEqual(reopened.laneCount, 4)
        XCTAssertEqual(reopened.directory[3].label, "lane 3")
        XCTAssertEqual(reopened.slot(bucket: 5_000, lane: 0)?.max, 5_000)
        XCTAssertEqual(reopened.slot(bucket: 12, lane: 1)?.max, 13)

        // The lanes the rebuild added record from their own first bucket on.
        try reopened.commit([Self.row(6_000, lanes: 4, base: 7)])
        XCTAssertEqual(reopened.slot(bucket: 6_000, lane: 3)?.max, 10)
        XCTAssertEqual(reopened.entry(lane: 3)?.firstValidBucket, 6_000)
        XCTAssertNil(reopened.slot(bucket: 5_000, lane: 3))
    }

    func testBitFlipFuzzNeverTrapsOrReadsOutOfBounds() throws {
        var random = SplitMix64(seed: 0x5748_4953_544F_5259)
        let lanes = 3
        let rows = 8
        let matrixOffset = HistoryArchiveHeader.byteWidth + lanes * HistoryLaneEntry.byteWidth
        let rowBytes = lanes * HistorySlot.byteWidth

        var recreated = 0
        var survived = 0
        var readSlots = 0

        for iteration in 0..<40 {
            let url = self.folder.appendingPathComponent("fuzz-\(iteration).rrd")
            let archive = HistoryArchive(tier: .t0, url: url)
            try archive.open()
            try archive.setDirectory(Self.entries(lanes))
            // Kept below the ring size so the written rows stay contiguous and
            // the fuzzer can aim at them.
            let first = UInt32(random.next() % UInt64(HistoryTier.t0.buckets - rows))
            for offset in 0..<rows {
                try archive.commit([Self.row(first + UInt32(offset), lanes: lanes, base: Float(offset))])
            }
            archive.close()

            let size = try Self.fileSize(at: url)
            for _ in 0..<4 {
                // Aimed in turn at the checksummed region, at the rows that
                // actually hold data, and anywhere at all.
                let target: UInt64
                switch random.next() % 3 {
                case 0: target = random.next() % UInt64(matrixOffset)
                case 1: target = UInt64(matrixOffset + Int(first) * rowBytes) + random.next() % UInt64(rows * rowBytes)
                default: target = random.next() % size
                }
                try Self.flipBit(at: url, byte: target, bit: UInt8(random.next() % 8))
            }

            let damaged = HistoryArchive(tier: .t0, url: url)
            switch try damaged.open() {
            case .existing: survived += 1
            case .recreated: recreated += 1
            case .created: XCTFail("the fuzzed file exists, so it cannot be created fresh")
            }

            for _ in 0..<60 {
                let bucket = UInt32(truncatingIfNeeded: random.next())
                let lane = Int(random.next() % 8) - 2 // deliberately out of range some of the time
                if let slot = damaged.slot(bucket: bucket, lane: lane) {
                    XCTAssertEqual(slot.bucket, bucket)
                    XCTAssertTrue(lane >= 0 && lane < damaged.laneCount)
                }
            }
            for offset in 0..<rows {
                let bucket = first + UInt32(offset)
                for lane in 0..<lanes where damaged.slot(bucket: bucket, lane: lane) != nil {
                    readSlots += 1
                }
                _ = damaged.row(bucket: bucket)
            }
            _ = damaged.series(lane: 0, buckets: first..<(first + 16))
            _ = damaged.series(lane: 99, buckets: 0..<4)
            damaged.close()
            try FileManager.default.removeItem(at: url)
        }

        // The loop is only worth anything if it reached both paths: files the
        // checksum threw away, and files that opened with damaged slots in them.
        XCTAssertGreaterThan(recreated, 0)
        XCTAssertGreaterThan(survived, 0)
        XCTAssertGreaterThan(readSlots, 0)
    }

    func testLockKeepsASecondWriterOut() throws {
        let url = self.folder.appendingPathComponent(".lock")
        let first = HistoryLock(url: url)
        let second = HistoryLock(url: url)

        XCTAssertEqual(first.acquire(), .acquired)
        XCTAssertTrue(first.isHeld)
        XCTAssertEqual(second.acquire(), .heldByAnotherProcess)
        XCTAssertFalse(second.isHeld)

        first.release()
        XCTAssertEqual(second.acquire(), .acquired)
        second.release()
    }

    /// A lock file that cannot be opened at all is not a second copy of Stats,
    /// and the banner that says it is would be a lie on a first launch.
    func testLockSeparatesAnotherInstanceFromAnUnusablePath() throws {
        let missing = self.folder.appendingPathComponent("no-such-directory").appendingPathComponent(".lock")
        XCTAssertEqual(HistoryLock(url: missing).acquire(), .unavailable(ENOENT))

        // And the store creates the directory before it tries, so the same
        // first-launch path acquires cleanly.
        let directory = self.folder.appendingPathComponent("history-lock")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(HistoryStore.shared.acquireLock(in: directory), .acquired)
        HistoryStore.shared.releaseLock()
    }

    func testFreeSpacePrecondition() throws {
        // Decimal MB, the unit §3 quotes every size in.
        XCTAssertEqual(HistoryStore.freeSpaceFloor, 50 * 1_000 * 1_000)
        XCTAssertFalse(HistoryStore.hasEnoughFreeSpace(available: HistoryStore.freeSpaceFloor - 1))
        XCTAssertTrue(HistoryStore.hasEnoughFreeSpace(available: HistoryStore.freeSpaceFloor))
        XCTAssertFalse(HistoryStore.hasEnoughFreeSpace(available: 0))

        let directory = try HistoryStore.prepareDirectory(self.folder.appendingPathComponent("history"))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertTrue(HistoryStore.isExcludedFromBackup(directory))
        XCTAssertNotNil(HistoryStore.availableSpace(at: directory))
    }

    // MARK: - archive fixtures

    /// Deterministic, so a fuzz failure is reproducible from the seed alone.
    private struct SplitMix64: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed }
        mutating func next() -> UInt64 {
            self.state &+= 0x9E37_79B9_7F4A_7C15
            var z = self.state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private func openArchive(_ tier: HistoryTier, lanes: Int) throws -> HistoryArchive {
        let archive = HistoryArchive(tier: tier, url: self.folder.appendingPathComponent(tier.fileName))
        try archive.open()
        try archive.setDirectory(Self.entries(lanes))
        return archive
    }

    private static func entries(_ count: Int) -> [HistoryLaneEntry] {
        (0..<count).map { index in
            HistoryLaneEntry(
                identity: HistoryLaneIdentity(high: 0xA1B2_C3D4_E5F6_0718, low: UInt64(index)),
                module: .cpu, unit: .percent, kind: .gauge, label: "lane \(index)"
            )
        }
    }

    private static func row(_ bucket: UInt32, lanes: Int, base: Float) -> HistoryRow {
        HistoryRow(bucket: bucket, slots: (0..<lanes).map { lane in
            let value = base + Float(lane)
            return HistorySlot(bucket: bucket, count: 1, reason: .measured, min: value, max: value, sum: value)
        })
    }

    private func quarantinedFiles(for name: String) -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: self.folder.path)) ?? []
        return contents.filter { $0.hasPrefix("\(name).corrupt-") }
    }

    /// A byte-for-byte copy of a file that is still open, read back as its own
    /// archive: what a second process — or the next launch after a `kill -9` —
    /// would find at that instant.
    private func snapshot(of url: URL, as name: String) throws -> HistoryArchive {
        let copy = self.folder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: url, to: copy)
        return HistoryArchive(tier: .t0, url: copy)
    }

    private static func fileSize(at url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private static func flipBit(at url: URL, byte offset: UInt64, bit: UInt8) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        guard let current = try handle.read(upToCount: 1)?.first else { return }
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: Data([current ^ (1 << bit)]))
    }

    // MARK: - lanes and accumulators
    //
    // Rate conversion across a mid-series interval change; dt <= 0 and
    // non-finite rejection; step-lane hold over a 40-minute idle stretch; lane
    // LRU reclaim; label truncation on a scalar boundary.

    // MARK: - recorder
    //
    // Rollup with partially populated and empty fine buckets; coarse-tier
    // catch-up after a simulated restart; count-weighted resampling; gap-reason
    // derivation at read; a TSAN run with Battery ingest on main.

    // MARK: - layout
    //
    // The slot and directory geometry is a format decision, not an
    // implementation detail: it is asserted from the first commit so that a
    // later change to either width fails here rather than in a user's archive.

    func testSlotAndDirectoryGeometry() throws {
        XCTAssertEqual(HistorySlot.byteWidth, 20)
        XCTAssertEqual(HistoryLaneEntry.byteWidth, 128)
        XCTAssertEqual(HistoryLaneIdentity.byteWidth, 16)
        XCTAssertEqual(HistoryArchiveHeader.byteWidth, 4096)
    }

    func testTierGeometryMatchesTheRetentionTable() throws {
        XCTAssertEqual(HistoryTier.t0.step, 10)
        XCTAssertEqual(HistoryTier.t1.step, 120)
        XCTAssertEqual(HistoryTier.t2.step, 1800)

        // 24 h, 30 d and 365 d of buckets.
        XCTAssertEqual(HistoryTier.t0.buckets, 24 * 3600 / HistoryTier.t0.step)
        XCTAssertEqual(HistoryTier.t1.buckets, 30 * 24 * 3600 / HistoryTier.t1.step)
        XCTAssertEqual(HistoryTier.t2.buckets, 365 * 24 * 3600 / HistoryTier.t2.step)

        XCTAssertEqual(HistoryRetentionPreset.minimal.tiers, [.t0])
        XCTAssertEqual(HistoryRetentionPreset.standard.tiers, [.t0, .t1, .t2])
    }
}
