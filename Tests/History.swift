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

    /// The identity is the archive's key for a series, so it has to be the same
    /// value in every release: a changed hash orphans every lane a user has.
    /// The two vectors are `shasum -a 256` of the stable key.
    func testLaneIdentityIsAStableHashOfTheKey() throws {
        let disk = HistoryLaneKey(module: .disk, source: "UUID-1", metric: "read")
        XCTAssertEqual(disk.stableKey, "4|UUID-1|read")
        XCTAssertEqual(HistoryLaneIdentity(key: disk),
                       HistoryLaneIdentity(high: 0xE9FE_A4DD_EA67_5342, low: 0xA4D1_CCF0_86C8_7FE9))

        let cpu = HistoryLaneKey(module: .cpu, metric: "total")
        XCTAssertEqual(cpu.stableKey, "0||total")
        XCTAssertEqual(HistoryLaneIdentity(key: cpu),
                       HistoryLaneIdentity(high: 0x5433_D806_C560_500A, low: 0x5F41_FD48_018B_5815))

        // Every component participates, and the display name does not exist as
        // far as identity is concerned.
        XCTAssertNotEqual(HistoryLaneIdentity(key: disk),
                          HistoryLaneIdentity(key: HistoryLaneKey(module: .disk, source: "UUID-1", metric: "write")))
        XCTAssertNotEqual(HistoryLaneIdentity(key: disk),
                          HistoryLaneIdentity(key: HistoryLaneKey(module: .disk, source: "UUID-2", metric: "read")))
        XCTAssertNotEqual(HistoryLaneIdentity(key: cpu),
                          HistoryLaneIdentity(key: HistoryLaneKey(module: .ram, metric: "total")))
    }

    func testRegistrationResolvesToStableIntegerLanes() throws {
        let directory = HistoryLaneDirectory()
        let now: UInt64 = 1_700_000_000

        XCTAssertEqual(directory.register(Self.descriptor("en0", metric: "up"), at: now), .registered(0))
        XCTAssertEqual(directory.register(Self.descriptor("en0", metric: "down"), at: now), .registered(1))
        // Same identity, a renamed source and a later timestamp: the id, the
        // stored data and the slot all stay where they are.
        XCTAssertEqual(directory.register(Self.descriptor("en0", metric: "up", label: "Ethernet (en0)"), at: now + 60),
                       .existing(0))
        XCTAssertEqual(directory.count, 2)
        XCTAssertEqual(directory.entry(0)?.label, "Ethernet (en0)")
        XCTAssertEqual(directory.entry(0)?.lastUsedTs, now + 60)
        XCTAssertEqual(directory.lanes(in: .net), [0, 1])
        XCTAssertEqual(directory.lanes(in: .cpu), [])

        // `lastUsedTs` moves on every commit and must not make the recorder
        // rewrite three tier directories for it.
        let revision = directory.revision
        directory.touch(0, at: now + 600)
        XCTAssertEqual(directory.entry(0)?.lastUsedTs, now + 600)
        XCTAssertEqual(directory.revision, revision)
    }

    func testLaneLRUReclaimAtTheCap() throws {
        let directory = HistoryLaneDirectory()
        let now: UInt64 = 1_700_000_000
        let cold = now - 200_000 // well past the 24 h idle floor

        for lane in 0..<HistoryLaneDirectory.laneCap {
            XCTAssertEqual(directory.register(Self.descriptor("vol-\(lane)", metric: "free"), at: cold + UInt64(lane)),
                           .registered(lane))
        }
        XCTAssertTrue(directory.isFull)

        // Lane 0 is the coldest, so the new identity takes its slot — and the
        // displaced one is gone from the index, not merely shadowed.
        let displaced = Self.descriptor("vol-0", metric: "free").identity
        let fresh = Self.descriptor("vol-new", metric: "free")
        XCTAssertEqual(directory.register(fresh, at: now), .reclaimed(lane: 0, from: displaced))
        XCTAssertEqual(directory.count, HistoryLaneDirectory.laneCap)
        XCTAssertNil(directory.lane(for: displaced))
        XCTAssertEqual(directory.lane(for: fresh.identity), 0)
        XCTAssertEqual(directory.entry(0)?.label, fresh.label)
        // The matrix cells at that id still belong to the displaced identity,
        // and both halves of saying so are asserted.
        XCTAssertTrue(directory.entry(0)?.flags.contains(.reclaimed) ?? false)
        XCTAssertEqual(directory.entry(0)?.firstValidBucket, HistoryLaneEntry.noValidBucket)

        // Once the lane has written a bucket of its own the flag is retired:
        // left set it would follow the id for the life of the archive and grey
        // a lane that is recording.
        directory.setFirstValidBucket(4_200, lane: 0)
        XCTAssertEqual(directory.entry(0)?.firstValidBucket, 4_200)
        XCTAssertFalse(directory.entry(0)?.flags.contains(.reclaimed) ?? true)

        // Warm table: refusing is the answer, not evicting a lane that is still
        // recording. Existing lanes keep their ids and keep going.
        for lane in 0..<HistoryLaneDirectory.laneCap {
            directory.touch(lane, at: now)
        }
        XCTAssertEqual(directory.register(Self.descriptor("vol-newer", metric: "free"), at: now), .refused)
        XCTAssertEqual(directory.count, HistoryLaneDirectory.laneCap)
        XCTAssertEqual(directory.lane(for: fresh.identity), 0)
    }

    /// A crash between the three per-tier directory writes leaves them
    /// disagreeing; §3 settles it by fiat and this is the fiat.
    func testDirectoryDisagreementBetweenTiersIsResolvedFromT0() throws {
        let a = Self.entry("vol-a", metric: "free", firstValidBucket: 10, label: "Macintosh HD")
        let b = Self.entry("vol-b", metric: "free", firstValidBucket: 20, label: "Tim's backup drive")
        let x = Self.entry("vol-x", metric: "free", firstValidBucket: 77, label: "stale")

        // T2 never learned about lane 1 being `b`: it still holds `x` there.
        let merged = HistoryLaneDirectory.reconcile(primary: [a, b], with: [Self.entry("vol-a", metric: "free",
                                                                                       firstValidBucket: 55,
                                                                                       label: "Macintosh HD"), x])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].identity, a.identity)
        XCTAssertEqual(merged[1].identity, b.identity)
        XCTAssertEqual(merged[1].label, "Tim's backup drive")
        // `firstValidBucket` is the one field the coarse tier owns: kept where
        // the identity matches, reset where the cells belong to someone else.
        XCTAssertEqual(merged[0].firstValidBucket, 55)
        XCTAssertEqual(merged[1].firstValidBucket, HistoryLaneEntry.noValidBucket)

        // A lane T2 has never heard of simply has no T2 data yet.
        let shorter = HistoryLaneDirectory.reconcile(primary: [a, b], with: [])
        XCTAssertEqual(shorter.map { $0.identity }, [a.identity, b.identity])
        XCTAssertEqual(shorter[0].firstValidBucket, HistoryLaneEntry.noValidBucket)
    }

    /// The label is the only thing that can make an unplugged drive
    /// recognisable a month later, and it is stored in a fixed 88 B field.
    func testLabelIsTruncatedOnAScalarBoundary() throws {
        let url = self.folder.appendingPathComponent(HistoryTier.t0.fileName)
        let archive = HistoryArchive(tier: .t0, url: url)
        XCTAssertEqual(try archive.open(), .created)

        // 30 four-byte scalars: 120 B into an 88 B field, which is 22 scalars
        // and a boundary that falls inside the 23rd.
        let label = String(repeating: "🌡", count: 30)
        try archive.setDirectory([HistoryLaneEntry(identity: HistoryLaneIdentity(key: HistoryLaneKey(module: .sensors,
                                                                                                    source: "TC0P",
                                                                                                    metric: "temperature")),
                                                  module: .sensors, unit: .celsius, kind: .gauge, label: label)])
        archive.close()

        let reopened = HistoryArchive(tier: .t0, url: url)
        XCTAssertEqual(try reopened.open(), .existing)
        let stored = try XCTUnwrap(reopened.entry(lane: 0)?.label)
        XCTAssertEqual(stored, String(repeating: "🌡", count: 22))
        XCTAssertEqual(stored.utf8.count, 88)
    }

    func testRateConversionAcrossAMidSeriesIntervalChange() throws {
        let table = HistoryAccumulatorTable(capacity: 2, step: 10)
        table.bind(lane: 0, kind: .rate)
        let start: TimeInterval = 1_700_000_000

        // First sample of a lane has no previous one: the interval is the
        // window the delta was accumulated over.
        XCTAssertTrue(table.fold(lane: 0, value: 1_000, at: start, interval: 1))
        XCTAssertEqual(table.accumulator(lane: 0)?.lastValue, 1_000)

        XCTAssertTrue(table.fold(lane: 0, value: 1_500, at: start + 1, interval: 1))
        XCTAssertEqual(table.accumulator(lane: 0)?.lastValue, 1_500)

        // The user moves the interval to 5 s mid-series. Five times the bytes
        // over five times the time is the same rate — an interval-independent
        // divisor is the whole point.
        XCTAssertTrue(table.fold(lane: 0, value: 7_500, at: start + 6, interval: 5))
        XCTAssertEqual(table.accumulator(lane: 0)?.lastValue, 1_500)

        // A tick that arrives early divides by the time that actually passed,
        // not by the nominal interval.
        XCTAssertTrue(table.fold(lane: 0, value: 3_000, at: start + 8, interval: 5))
        XCTAssertEqual(table.accumulator(lane: 0)?.lastValue, 1_500)

        // And one that arrives late is bounded by the interval instead: the
        // delta covers one tick, whatever the queue did with the other four.
        XCTAssertTrue(table.fold(lane: 0, value: 7_500, at: start + 108, interval: 5))
        XCTAssertEqual(table.accumulator(lane: 0)?.lastValue, 1_500)
    }

    func testNonPositiveDtAndNonFiniteValuesAreRejected() throws {
        let table = HistoryAccumulatorTable(capacity: 4, step: 10)
        table.bind(lane: 0, kind: .rate)
        table.bind(lane: 1, kind: .gauge)
        let start: TimeInterval = 1_700_000_000

        XCTAssertTrue(table.fold(lane: 0, value: 1_000, at: start, interval: 1))
        // A duplicate timestamp and a backward step are both dt <= 0.
        XCTAssertFalse(table.fold(lane: 0, value: 1_000, at: start, interval: 1))
        XCTAssertFalse(table.fold(lane: 0, value: 1_000, at: start - 5, interval: 1))
        XCTAssertNil(HistoryAccumulator.rate(delta: 1_000, at: start, previous: start, interval: 1))
        XCTAssertNil(HistoryAccumulator.rate(delta: 1_000, at: start, previous: 0, interval: 0))
        XCTAssertNil(HistoryAccumulator.rate(delta: .nan, at: start, previous: start - 1, interval: 1))
        XCTAssertEqual(HistoryAccumulator.rate(delta: 1_000, at: start, previous: start - 2, interval: 5), 500)

        // NaN must never reach min/max, where every comparison against it
        // silently fails.
        XCTAssertFalse(table.fold(lane: 1, value: .nan, at: start, interval: 1))
        XCTAssertFalse(table.fold(lane: 1, value: .infinity, at: start, interval: 1))
        XCTAssertFalse(table.fold(lane: 1, value: -.infinity, at: start, interval: 1))
        // A Double beyond Float's range becomes an infinity on the way into the
        // slot, so it is rejected for the same reason.
        XCTAssertFalse(table.fold(lane: 1, value: 1e300, at: start, interval: 1))
        XCTAssertEqual(table.accumulator(lane: 1)?.count, 0)

        XCTAssertTrue(table.fold(lane: 1, value: 42, at: start, interval: 1))
        XCTAssertEqual(table.accumulator(lane: 1)?.count, 1)
        XCTAssertTrue(table.isDirty(at: start))

        // The sink drops them a step earlier, before they can reach the lock.
        var sink = HistorySink(capacity: 4)
        sink.prepare(registry: nil, at: UInt64(start))
        sink.emit(lane: 0, value: .nan)
        sink.emit(lane: 0, value: 7)
        sink.emit(lane: -1, value: 7)
        XCTAssertEqual(sink.count, 1)
    }

    /// A 60 s reader must not leave five of every six buckets as gaps, and must
    /// not write the bucket its previous sample already closed twice either.
    func testIntervalSpanAttributionFillsEveryOverlappingBucket() throws {
        let table = HistoryAccumulatorTable(capacity: 1, step: 10)
        table.bind(lane: 0, kind: .gauge)
        let start: TimeInterval = 1_700_000_000 // bucket-aligned
        let first = HistoryClock.bucketIndex(start, step: 10)

        XCTAssertTrue(table.fold(lane: 0, value: 10, at: start, interval: 60))
        XCTAssertTrue(table.fold(lane: 0, value: 20, at: start + 60, interval: 60))

        let rows = table.drain(before: first + 7, lanes: 1)
        XCTAssertEqual(rows.map { $0.bucket }, Array((first - 6)...(first + 6)))

        // The cold start fills its own span; the second sample fills exactly the
        // six buckets since the first one.
        for row in rows where row.bucket < first {
            XCTAssertEqual(row.slots[0].count, 1)
            XCTAssertEqual(row.slots[0].max, 10)
            XCTAssertEqual(row.slots[0].reason, .measured)
        }
        for row in rows where row.bucket > first {
            XCTAssertEqual(row.slots[0].count, 1)
            XCTAssertEqual(row.slots[0].max, 20)
        }

        // The shared boundary bucket holds both samples rather than one of them
        // overwriting the other.
        let boundary = try XCTUnwrap(rows.first { $0.bucket == first })
        XCTAssertEqual(boundary.slots[0].count, 2)
        XCTAssertEqual(boundary.slots[0].min, 10)
        XCTAssertEqual(boundary.slots[0].max, 20)
        XCTAssertEqual(boundary.slots[0].sum, 30)

        // Buckets are handed out once: a drain of the same range again is empty,
        // and a late sample into them is refused rather than rewriting a row.
        XCTAssertEqual(table.drain(before: first + 7, lanes: 1).count, 0)
        XCTAssertFalse(table.fold(lane: 0, value: 99, at: start + 10, interval: 1))
    }

    /// Battery's `UsageReader` is an IOPS notification with no repeater, so a
    /// level that does not change produces no samples at all. The lane holds
    /// its last value for fifteen minutes and then stops — drawn dashed, never
    /// presented as measured (§2).
    func testStepLaneHoldsForFifteenMinutesThenGoesQuiet() throws {
        let table = HistoryAccumulatorTable(capacity: 1, step: 10)
        table.bind(lane: 0, kind: .step)
        // Mid-bucket, so the 1 s span of a single sample stays inside one
        // bucket and the hold is the only thing filling the rest.
        let start: TimeInterval = 1_700_000_005
        let first = HistoryClock.bucketIndex(start, step: 10)

        XCTAssertTrue(table.fold(lane: 0, value: 82, at: start, interval: 1))

        // Forty minutes of silence, drained the way the recorder drains: once a
        // minute. Nothing else arrives.
        var rows: [HistoryRow] = []
        for minute in 1...40 {
            rows += table.drain(before: HistoryClock.bucketIndex(start + TimeInterval(minute * 60), step: 10), lanes: 1)
        }

        // The sample's own bucket is measured; the hold covers every bucket
        // that starts inside the next fifteen minutes, and nothing after it.
        let measured = try XCTUnwrap(rows.first)
        XCTAssertEqual(measured.bucket, first)
        XCTAssertEqual(measured.slots[0].reason, .measured)
        XCTAssertEqual(measured.slots[0].max, 82)

        let held = rows.dropFirst()
        XCTAssertEqual(held.count, 90) // every bucket starting inside the next 15 min
        XCTAssertEqual(held.first?.bucket, first + 1)
        XCTAssertEqual(held.last?.bucket, first + 90)
        XCTAssertEqual(HistoryClock.bucketStart(first + 90, step: 10), start + 895)
        for row in held {
            XCTAssertEqual(row.slots[0].reason, .held)
            XCTAssertEqual(row.slots[0].count, 1)
            XCTAssertEqual(row.slots[0].min, 82)
            XCTAssertEqual(row.slots[0].max, 82)
            XCTAssertEqual(row.slots[0].sum, 82)
        }

        // Past the hold the lane is no-data, which is an absence of rows: §4
        // derives gaps at read and never backfills them at write.
        XCTAssertEqual(rows.count, 91)
        XCTAssertFalse(table.isDirty(at: start + 40 * 60))

        // A sample after the silence resumes measuring where it lands, and
        // backfills nothing behind it.
        let resumed = start + 40 * 60
        XCTAssertTrue(table.fold(lane: 0, value: 74, at: resumed, interval: 1))
        let after = table.drain(before: HistoryClock.bucketIndex(resumed + 60, step: 10), lanes: 1)
        XCTAssertEqual(after.first?.bucket, HistoryClock.bucketIndex(resumed, step: 10))
        XCTAssertEqual(after.first?.slots[0].reason, .measured)
        XCTAssertEqual(after.first?.slots[0].max, 74)
        XCTAssertTrue(after.dropFirst().allSatisfy { $0.slots[0].reason == .held && $0.slots[0].max == 74 })
    }

    /// A gap between two events, rather than after the last one: the buckets
    /// the reader skipped are held from the value that was current at the time.
    func testStepLaneHoldsBetweenTwoEvents() throws {
        let table = HistoryAccumulatorTable(capacity: 1, step: 10)
        table.bind(lane: 0, kind: .step)
        let start: TimeInterval = 1_700_000_005
        let first = HistoryClock.bucketIndex(start, step: 10)

        XCTAssertTrue(table.fold(lane: 0, value: 82, at: start, interval: 1))
        XCTAssertTrue(table.fold(lane: 0, value: 81, at: start + 50, interval: 1))

        let rows = table.drain(before: first + 6, lanes: 1)
        XCTAssertEqual(rows.map { $0.bucket }, Array(first...(first + 5)))
        XCTAssertEqual(rows[0].slots[0].reason, .measured)
        XCTAssertEqual(rows[0].slots[0].max, 82)
        for row in rows[1...4] {
            XCTAssertEqual(row.slots[0].reason, .held)
            XCTAssertEqual(row.slots[0].max, 82) // the value that was current, not the new one
        }
        XCTAssertEqual(rows[5].slots[0].reason, .measured)
        XCTAssertEqual(rows[5].slots[0].max, 81)
    }

    /// The same two events, with a commit in between — which is the ordinary
    /// recorder schedule, not an edge case: the timer fires once a minute and a
    /// battery event lands wherever it lands.
    ///
    /// A drain closes every bucket older than the one it commits, so the lane
    /// has nothing open when the second event arrives. The buckets between the
    /// drain and that event still have to be held: they are past the drain's
    /// reach and past the first event's own bucket, and if the fill skips them
    /// nothing else will — the drain's `heldSlot` fallback only looks forward
    /// from the *latest* sample. Without the closed-lane case they were simply
    /// absent, which reads as no-data for up to a commit period before every
    /// event, and `droppedBuckets` stayed zero while it happened.
    func testStepLaneHoldsAcrossACommitBetweenTwoEvents() throws {
        let table = HistoryAccumulatorTable(capacity: 1, step: 10)
        table.bind(lane: 0, kind: .step)
        let start: TimeInterval = 1_700_000_005
        let first = HistoryClock.bucketIndex(start, step: 10)

        XCTAssertTrue(table.fold(lane: 0, value: 82, at: start, interval: 1))

        // The commit timer fires: the measured bucket and two held ones go out,
        // and the accumulator is left closed.
        let committed = table.drain(before: first + 3, lanes: 1)
        XCTAssertEqual(committed.map { $0.bucket }, Array(first...(first + 2)))
        XCTAssertEqual(committed[0].slots[0].reason, .measured)
        XCTAssertEqual(table.accumulator(lane: 0)?.isOpen, false)

        XCTAssertTrue(table.fold(lane: 0, value: 81, at: start + 50, interval: 1))

        let rows = table.drain(before: first + 7, lanes: 1)
        XCTAssertEqual(rows.map { $0.bucket }, Array((first + 3)...(first + 6)))
        for row in rows.prefix(2) {
            XCTAssertEqual(row.slots[0].reason, .held)
            XCTAssertEqual(row.slots[0].max, 82) // the value that was current, not the new one
        }
        XCTAssertEqual(rows[2].slots[0].reason, .measured)
        XCTAssertEqual(rows[2].slots[0].max, 81)
        XCTAssertEqual(rows[3].slots[0].reason, .held)
        XCTAssertEqual(rows[3].slots[0].max, 81)

        // Nothing was dropped on the way: the gap was staged, not lost.
        XCTAssertEqual(table.droppedBuckets, 0)
    }

    /// The same shape as above, but with the two events further apart than the
    /// 16-row staging ring is long. This is the wake path: the commit timer does
    /// not fire while the machine sleeps and Battery's IOPS notification does
    /// fire on wake, so a sleep of more than 160 s puts two events on either
    /// side of a gap the ring cannot hold, with no drain in between.
    ///
    /// The measured bucket the hold is held *from* must survive it. A held slot
    /// displacing it would cost the level lane its last pre-sleep reading, and
    /// would read as no-data rather than as anything visibly wrong.
    func testStepLaneHoldDoesNotEvictItsOwnMeasuredBucket() throws {
        let table = HistoryAccumulatorTable(capacity: 1, step: 10)
        table.bind(lane: 0, kind: .step)
        let start: TimeInterval = 1_700_000_005
        let first = HistoryClock.bucketIndex(start, step: 10)

        XCTAssertTrue(table.fold(lane: 0, value: 82, at: start, interval: 1))
        XCTAssertTrue(table.fold(lane: 0, value: 81, at: start + 200, interval: 1))

        let rows = table.drain(before: first + 21, lanes: 1)

        // Both measurements are there, at their own buckets, unheld.
        let measured = try XCTUnwrap(rows.first { $0.bucket == first })
        XCTAssertEqual(measured.slots[0].reason, .measured)
        XCTAssertEqual(measured.slots[0].max, 82)
        let latest = try XCTUnwrap(rows.first { $0.bucket == first + 20 })
        XCTAssertEqual(latest.slots[0].reason, .measured)
        XCTAssertEqual(latest.slots[0].max, 81)

        // The hold covers what the ring can keep and stops: fifteen rows, minus
        // the one the newer measurement takes back when it closes. What it
        // cannot keep is an absence of rows, never a wrong value.
        XCTAssertEqual(rows.map { $0.bucket },
                       [first] + Array((first + 1)...(first + 3)) + Array((first + 5)...(first + 15)) + [first + 20])
        for row in rows where row.bucket != first && row.bucket != first + 20 {
            XCTAssertEqual(row.slots[0].reason, .held)
            XCTAssertEqual(row.slots[0].max, 82) // the value that was current
        }

        // And the one bucket the ring did drop is counted rather than silent.
        XCTAssertEqual(table.droppedBuckets, 1)
    }

    func testRollupOfPartiallyPopulatedAndEmptyFineBuckets() throws {
        // Three of six fine buckets hold samples: sleep, a disabled module and
        // an interval change all produce exactly this shape.
        let partial: [HistorySlot?] = [
            HistorySlot(bucket: 1, count: 3, reason: .measured, min: 1, max: 9, sum: 15),
            nil,
            HistorySlot(bucket: 3, count: 0, reason: .nodata),
            HistorySlot(bucket: 4, count: 2, reason: .measured, min: 4, max: 6, sum: 10),
            nil,
            HistorySlot(bucket: 6, count: 1, reason: .held, min: 5, max: 5, sum: 5)
        ]
        let rolled = HistoryAggregate.rollup(partial, into: 42)
        XCTAssertEqual(rolled.bucket, 42)
        XCTAssertEqual(rolled.count, 6)
        XCTAssertEqual(rolled.min, 1)
        XCTAssertEqual(rolled.max, 9)
        XCTAssertEqual(rolled.sum, 30)
        // One measured sample in the span makes the coarse bucket measured.
        XCTAssertEqual(rolled.reason, .measured)

        // Empty input is a no-data slot, never a measured zero — which is what
        // `nodata == 0` is for.
        let empty = HistoryAggregate.rollup([HistorySlot?](repeating: nil, count: 6), into: 42)
        XCTAssertEqual(empty.count, 0)
        XCTAssertEqual(empty.reason, .nodata)
        XCTAssertEqual(empty.min, 0)
        XCTAssertEqual(empty.max, 0)
        XCTAssertEqual(empty.sum, 0)
        XCTAssertFalse(empty.isRecorded)

        // All-held rolls up as held, so a dashed span stays dashed at T1 and T2.
        let allHeld = HistoryAggregate.rollup([
            HistorySlot(bucket: 1, count: 1, reason: .held, min: 5, max: 5, sum: 5),
            HistorySlot(bucket: 2, count: 1, reason: .held, min: 5, max: 5, sum: 5)
        ], into: 7)
        XCTAssertEqual(allHeld.reason, .held)
        XCTAssertEqual(allHeld.count, 2)

        // A reason with no samples behind it survives the rollup: that is how
        // "asleep 02:14–08:31" reaches the 30-day view.
        let asleep = HistoryAggregate.rollup([nil, HistorySlot(bucket: 2, count: 0, reason: .asleep)], into: 7)
        XCTAssertEqual(asleep.count, 0)
        XCTAssertEqual(asleep.reason, .asleep)
        XCTAssertTrue(asleep.isRecorded)
    }

    func testCountWeightedResampling() throws {
        // One bucket holds a single sample at 100, the next holds nine at 10.
        // Count-weighted that is 19; the mean of the two averages is 55, and
        // over a day of #3450 totals that error compounds.
        let slots: [HistorySlot?] = [
            HistorySlot(bucket: 1, count: 1, reason: .measured, min: 100, max: 100, sum: 100),
            HistorySlot(bucket: 2, count: 9, reason: .measured, min: 10, max: 10, sum: 90)
        ]

        let single = try XCTUnwrap(HistoryAggregate.resample(slots, columns: 1).first ?? nil)
        XCTAssertEqual(single.avg, 19)
        XCTAssertEqual(single.min, 10)
        XCTAssertEqual(single.max, 100)
        XCTAssertEqual(single.count, 10)
        XCTAssertEqual(single.reason, .measured)

        // Split one per column, each column is its own bucket.
        let split = HistoryAggregate.resample(slots, columns: 2)
        XCTAssertEqual(split.count, 2)
        XCTAssertEqual(split[0]?.avg, 100)
        XCTAssertEqual(split[1]?.avg, 10)

        // More columns than buckets: the extra columns are empty rather than
        // interpolated, and an empty range is no column at all.
        let wide = HistoryAggregate.resample(slots, columns: 5)
        XCTAssertEqual(wide.count, 5)
        XCTAssertEqual(wide.compactMap { $0 }.count, 2)
        XCTAssertEqual(HistoryAggregate.resample([nil, nil], columns: 1).compactMap { $0 }.count, 0)
        XCTAssertEqual(HistoryAggregate.resample([], columns: 3).count, 3)
    }

    func testSinkResolvesLanesThroughTheRegistry() throws {
        let directory = HistoryLaneDirectory()
        var sink = HistorySink(capacity: 8)
        sink.prepare(registry: directory, at: 1_700_000_000)

        let up = try XCTUnwrap(sink.lane(for: Self.descriptor("en0", metric: "up")))
        let down = try XCTUnwrap(sink.lane(for: Self.descriptor("en0", metric: "down")))
        XCTAssertEqual(up, 0)
        XCTAssertEqual(down, 1)
        // Resolving again is the same id: module code caches it, and the
        // directory has to agree with the cache.
        XCTAssertEqual(sink.lane(for: Self.descriptor("en0", metric: "up")), 0)
        XCTAssertEqual(directory.count, 2)

        sink.emit(lane: up, value: 1_024)
        sink.emit(lane: down, value: 2_048)
        XCTAssertEqual(sink.count, 2)

        let table = HistoryAccumulatorTable(capacity: 4, step: 10)
        table.bind(lane: Int(up), kind: .rate)
        table.bind(lane: Int(down), kind: .rate)
        table.fold(sink, at: 1_700_000_000, interval: 1)
        XCTAssertEqual(table.accumulator(lane: Int(up))?.lastValue, 1_024)
        XCTAssertEqual(table.accumulator(lane: Int(down))?.lastValue, 2_048)

        // A new tick reuses the buffer rather than allocating a new one.
        sink.prepare(registry: directory, at: 1_700_000_060)
        XCTAssertTrue(sink.isEmpty)
    }

    /// Reclaiming a lane id hands the accumulator to another series; holding
    /// the displaced identity's last known value into it would be exactly the
    /// quiet lie this feature exists to avoid.
    func testBindingALaneClearsTheStateOfTheIdentityItDisplaced() throws {
        let table = HistoryAccumulatorTable(capacity: 2, step: 10)
        table.bind(lane: 0, kind: .step)
        let start: TimeInterval = 1_700_000_000

        XCTAssertTrue(table.fold(lane: 0, value: 82, at: start, interval: 1))
        XCTAssertTrue(table.isDirty(at: start + 60))

        table.bind(lane: 0, kind: .gauge)
        XCTAssertEqual(table.accumulator(lane: 0)?.count, 0)
        XCTAssertEqual(table.accumulator(lane: 0)?.lastValue, 0)
        XCTAssertEqual(table.accumulator(lane: 0)?.kind, .gauge)
        XCTAssertFalse(table.isDirty(at: start + 60))
        XCTAssertEqual(table.drain(before: HistoryClock.bucketIndex(start + 60, step: 10), lanes: 1).count, 0)
    }

    // MARK: - lane fixtures

    private static func descriptor(_ source: String, metric: String,
                                   label: String? = nil) -> HistoryLaneDescriptor {
        HistoryLaneDescriptor(
            key: HistoryLaneKey(module: .net, source: source, metric: metric),
            unit: .bytesPerSec, kind: .rate, label: label ?? "\(source) \(metric)"
        )
    }

    private static func entry(_ source: String, metric: String, firstValidBucket: UInt32,
                              label: String) -> HistoryLaneEntry {
        HistoryLaneEntry(
            identity: HistoryLaneIdentity(key: HistoryLaneKey(module: .disk, source: source, metric: metric)),
            module: .disk, unit: .bytes, kind: .gauge, flags: [],
            firstValidBucket: firstValidBucket, lastUsedTs: 1_700_000_000, label: label
        )
    }

    // MARK: - recorder
    //
    // Coarse-tier catch-up after a simulated restart, including a gap longer
    // than T0 retention; header rehydration across a launch; the three-strikes
    // suspend and retry; the low-free-space skip; a TSAN run with ingest on
    // main racing the commit thread. Gap-reason derivation at read arrives with
    // the read path in release 2.

    /// The ordinary cycle: a reader tick folds, the commit writes the T0
    /// buckets that closed, and the coarse tiers are recomputed from those T0
    /// rows rather than from anything held in memory (§3).
    func testCommitWritesT0AndRollsTheCoarseTiersUpFromIt() throws {
        let probe = try self.probe()
        defer { probe.recorder.stop() }

        // Four T0 buckets of one lane, two samples each: the rollup has
        // something to take a min, a max and a count-weighted sum of.
        let first = HistoryClock.bucketIndex(probe.now, step: HistoryTier.t0.step)
        for step in 0..<4 {
            probe.now = probe.start + TimeInterval(step * HistoryTier.t0.step)
            probe.recorder.ingest(Probe.payload(1 + Double(step)), reader: Probe.reader, interval: 1)
            probe.now += 1
            probe.recorder.ingest(Probe.payload(10 + Double(step)), reader: Probe.reader, interval: 1)
        }
        probe.now = probe.start + HistoryRecorder.commitInterval
        probe.recorder.commitNow()

        let t0 = try XCTUnwrap(probe.store.archive(.t0))
        XCTAssertEqual(probe.recorder.status, .recording)
        XCTAssertEqual(probe.recorder.laneCount, 1)
        XCTAssertEqual(t0.laneCount, 1)
        for step in 0..<4 {
            let slot = try XCTUnwrap(t0.slot(bucket: first + UInt32(step), lane: 0))
            XCTAssertEqual(slot.count, 2)
            XCTAssertEqual(slot.min, Float(1 + step))
            XCTAssertEqual(slot.max, Float(10 + step))
            XCTAssertEqual(slot.reason, .measured)
        }

        // The T1 bucket those four fall in has not closed yet, so nothing is
        // written for it: a coarse row is produced at close and never before.
        let t1 = try XCTUnwrap(probe.store.archive(.t1))
        let openT1 = HistoryClock.bucketIndex(probe.start, step: HistoryTier.t1.step)
        XCTAssertNil(t1.slot(bucket: openT1, lane: 0))

        // One T1 step later it has, and it is the min of the mins, the max of
        // the maxes and the sum of the sums.
        probe.now = probe.start + TimeInterval(HistoryTier.t1.step)
        probe.recorder.commitNow()
        let rolled = try XCTUnwrap(t1.slot(bucket: openT1, lane: 0))
        XCTAssertEqual(rolled.count, 8)
        XCTAssertEqual(rolled.min, 1)
        XCTAssertEqual(rolled.max, 13)
        XCTAssertEqual(rolled.sum, (1 + 2 + 3 + 4) + (10 + 11 + 12 + 13))
        XCTAssertEqual(rolled.reason, .measured)
        XCTAssertEqual(t1.lastCommitBucket, openT1)
    }

    /// Stats quits on every update and every reboot, so without this the 30-day
    /// and 1-year views would develop a hole at every restart (§3). The rule is
    /// exactly "every coarse bucket newer than that tier's `lastCommitBucket`
    /// and older than the current one", bounded by what T0 still retains:
    /// downtime longer than 24 h leaves honest no-data, not a fabricated line.
    func testCoarseTiersCatchUpAtOpenAcrossAGapLongerThanT0Retention() throws {
        let directory = self.folder.appendingPathComponent("history")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Aligned to a T2 boundary so every bucket index below is exact.
        let step = TimeInterval(HistoryTier.t2.step)
        let now = (1_760_000_000 / step).rounded(.down) * step
        let currentT0 = HistoryClock.bucketIndex(now, step: HistoryTier.t0.step)
        let currentT1 = HistoryClock.bucketIndex(now, step: HistoryTier.t1.step)
        let currentT2 = HistoryClock.bucketIndex(now, step: HistoryTier.t2.step)

        // Two hours of T0 immediately before the relaunch — the part of the
        // downtime the archive can still account for.
        let seeded: UInt32 = 2 * 3_600 / UInt32(HistoryTier.t0.step)
        let t0 = HistoryArchive(tier: .t0, url: directory.appendingPathComponent(HistoryTier.t0.fileName))
        try t0.open()
        try t0.setDirectory(Self.entries(2))
        try t0.commit(((currentT0 - seeded)..<currentT0).map {
            Self.row($0, lanes: 2, base: Float($0 % 5))
        })
        t0.close()

        // T1 last wrote 26 hours ago: everything between that and the start of
        // what T0 retains is unrecoverable.
        let stale = HistoryClock.bucketIndex(now - 26 * 3_600, step: HistoryTier.t1.step)
        let t1 = HistoryArchive(tier: .t1, url: directory.appendingPathComponent(HistoryTier.t1.fileName))
        try t1.open()
        try t1.setDirectory(Self.entries(2))
        try t1.commit([Self.row(stale, lanes: 2, base: 99)])
        t1.close()

        let probe = try self.probe(directory: directory, now: now)
        defer { probe.recorder.stop() }

        let reopenedT1 = try XCTUnwrap(probe.store.archive(.t1))
        XCTAssertEqual(reopenedT1.lastCommitBucket, currentT1 - 1)

        // The last closed T1 bucket, rolled up out of the twelve T0 rows it
        // spans. Recomputed here the way the seed was written.
        let last = currentT1 - 1
        let fine = (last * 12)..<((last + 1) * 12)
        let values = fine.map { Float($0 % 5) }
        let rolled = try XCTUnwrap(reopenedT1.slot(bucket: last, lane: 0))
        XCTAssertEqual(rolled.count, 12)
        XCTAssertEqual(rolled.min, values.min())
        XCTAssertEqual(rolled.max, values.max())
        XCTAssertEqual(rolled.sum, values.reduce(0, +))

        // The gap: T0 never held these buckets, so the catch-up writes nothing
        // for them and they read as no-data rather than as zeroes.
        XCTAssertNil(reopenedT1.slot(bucket: stale + 1, lane: 0))
        XCTAssertNil(reopenedT1.slot(bucket: currentT1 - 720, lane: 0))
        XCTAssertNil(reopenedT1.slot(bucket: currentT1 - (seeded / 12) - 1, lane: 0))
        // The still-open bucket is not written either.
        XCTAssertNil(reopenedT1.slot(bucket: currentT1, lane: 0))
        // And what the tier already held is untouched by the catch-up.
        XCTAssertEqual(reopenedT1.slot(bucket: stale, lane: 1)?.max, 100)

        // T2 catches up the same way, out of the same T0 rows.
        let t2 = try XCTUnwrap(probe.store.archive(.t2))
        let rolledT2 = try XCTUnwrap(t2.slot(bucket: currentT2 - 1, lane: 0))
        XCTAssertEqual(rolledT2.count, UInt16(HistoryTier.t2.step / HistoryTier.t0.step))
        XCTAssertEqual(t2.lastCommitBucket, currentT2 - 1)
    }

    /// `lastCommitBucket` is what the catch-up above starts from and
    /// `monotonicAnchor` is what §4's clock-step check compares against, so both
    /// have to survive a quit. The anchor is written here through the archive
    /// because the commit that gives the clock a writer is the next one; what is
    /// under test is that a recorder launch — open, reconcile, catch up, commit
    /// — carries them through rather than resetting them.
    func testTheHeaderRehydratesAcrossARecorderLaunch() throws {
        let directory = self.folder.appendingPathComponent("history")
        let first = try self.probe(directory: directory)

        first.now = first.start
        first.recorder.ingest(Probe.payload(42), reader: Probe.reader, interval: 1)
        first.now = first.start + HistoryRecorder.commitInterval
        first.recorder.commitNow()

        let written = try XCTUnwrap(first.store.archive(.t0))
        let lastCommitBucket = written.lastCommitBucket
        let createdTs = written.createdTs
        XCTAssertEqual(lastCommitBucket, HistoryClock.bucketIndex(first.start, step: HistoryTier.t0.step))
        try written.setMonotonicAnchor(987_654_321)
        first.recorder.stop()

        let second = try self.probe(directory: directory, now: first.start + 2 * HistoryRecorder.commitInterval)
        defer { second.recorder.stop() }

        let reopened = try XCTUnwrap(second.store.archive(.t0))
        XCTAssertEqual(reopened.lastCommitBucket, lastCommitBucket)
        XCTAssertEqual(reopened.monotonicAnchor, 987_654_321)
        XCTAssertEqual(reopened.createdTs, createdTs)
        // Lane ids are positions in the stored directory, so a launch that
        // rebuilt the registry from scratch would re-point the matrix.
        XCTAssertEqual(second.recorder.laneCount, 1)
        XCTAssertEqual(reopened.directory[0].label, Probe.label)
        XCTAssertEqual(reopened.slot(bucket: lastCommitBucket, lane: 0)?.max, 42)
    }

    /// Three consecutive write failures suspend recording for an hour, surface
    /// the banner, and retry on the next cycle rather than waiting for a
    /// relaunch (§3).
    func testThreeWriteFailuresSuspendRecordingAndTheNextCycleRetries() throws {
        let probe = try self.probe()
        defer { probe.recorder.stop() }

        // One clean cycle first: the failure under test is a failing commit on
        // an archive that is already set up, not a failing registration.
        probe.ingest(1)
        XCTAssertEqual(probe.recorder.status, .recording)

        var attempts = 0
        HistoryArchive.writeObserver = { _, _ in
            attempts += 1
            throw HistoryArchiveError.io(ENOSPC)
        }
        defer { HistoryArchive.writeObserver = nil }
        for strike in 1...HistoryRecorder.failureStrikes {
            probe.ingest(Double(strike))
            XCTAssertGreaterThan(attempts, 0)
        }
        XCTAssertEqual(probe.recorder.status, .writeFailures)

        // Suspended: the cycles inside the hour do not even reach the file.
        let suspendedAt = attempts
        probe.ingest(9)
        probe.ingest(9)
        XCTAssertEqual(attempts, suspendedAt)
        XCTAssertEqual(probe.recorder.status, .writeFailures)

        // An hour later the volume has room again and the recorder retries on
        // its own.
        HistoryArchive.writeObserver = nil
        probe.now += HistoryRecorder.suspensionWindow
        let recovered = probe.now
        probe.ingest(7)
        XCTAssertEqual(probe.recorder.status, .recording)

        let t0 = try XCTUnwrap(probe.store.archive(.t0))
        let bucket = HistoryClock.bucketIndex(recovered, step: HistoryTier.t0.step)
        XCTAssertEqual(t0.slot(bucket: bucket, lane: 0)?.max, 7)
    }

    /// Below 50 MB free the commit is skipped and the settings row says so: the
    /// store degrades before the volume does (§3). Skipped is not lost — the
    /// accumulators keep folding and the next commit with room writes them.
    func testALowFreeSpaceVolumeSkipsTheCommitAndSaysSo() throws {
        let probe = try self.probe()
        defer { probe.recorder.stop() }

        probe.freeSpace = HistoryStore.freeSpaceFloor - 1
        let first = probe.now

        var writes = 0
        HistoryArchive.writeObserver = { _, _ in writes += 1 }
        defer { HistoryArchive.writeObserver = nil }
        probe.ingest(3)
        HistoryArchive.writeObserver = nil

        XCTAssertEqual(writes, 0)
        XCTAssertEqual(probe.recorder.status, .lowDiskSpace)
        XCTAssertEqual(probe.store.archive(.t0)?.laneCount, 0)

        // Room again: the same commit path writes, including the bucket the
        // skipped cycle was holding.
        probe.freeSpace = HistoryStore.freeSpaceFloor
        probe.ingest(4)
        XCTAssertEqual(probe.recorder.status, .recording)

        let t0 = try XCTUnwrap(probe.store.archive(.t0))
        XCTAssertEqual(t0.slot(bucket: HistoryClock.bucketIndex(first, step: HistoryTier.t0.step), lane: 0)?.max, 3)
        XCTAssertEqual(t0.laneCount, 1)
    }

    /// Minimal is "the live window and nothing retained", not a different
    /// retention policy to reason about: T0 only, and the rollup simply has no
    /// coarse tier to write (§3).
    func testTheMinimalPresetKeepsT0Alone() throws {
        let probe = try self.probe(preset: .minimal)
        defer { probe.recorder.stop() }

        probe.ingest(5)
        XCTAssertNotNil(probe.store.archive(.t0))
        XCTAssertNil(probe.store.archive(.t1))
        XCTAssertNil(probe.store.archive(.t2))
        XCTAssertEqual(probe.store.openTiers, [.t0])

        let contents = try FileManager.default.contentsOfDirectory(atPath: probe.store.directory.path)
        XCTAssertTrue(contents.contains(HistoryTier.t0.fileName))
        XCTAssertFalse(contents.contains(HistoryTier.t1.fileName))
        XCTAssertFalse(contents.contains(HistoryTier.t2.fileName))
    }

    /// Growing Minimal → Standard copies T0 forward — its file is not touched
    /// at all — and then runs the catch-up rollup over everything T0 still
    /// retains, so T1 and T2 start with 24 h of data and honest no-data before
    /// it (§3).
    ///
    /// The rollup this exercises is the one the catch-up at open uses, with the
    /// one difference the grow needs: a tier created a moment ago has no
    /// `lastCommitBucket` to carry on from, so without the rebuild flag both
    /// new tiers would start with the single bucket that just closed.
    func testGrowingToStandardRebuildsTheCoarseTiersFromT0() throws {
        let probe = try self.probe(preset: .minimal)
        defer { probe.recorder.stop() }

        // Two hours of samples, one a minute: enough to close sixty T1 buckets
        // and four T2 ones, so the rebuild has something to find at both.
        for i in 0..<120 { probe.ingest(Double(i % 10)) }
        XCTAssertNil(probe.store.archive(.t1))

        XCTAssertEqual(probe.recorder.setPreset(.standard), .applied)
        XCTAssertEqual(probe.recorder.preset, .standard)
        XCTAssertEqual(probe.store.openTiers, [.t0, .t1, .t2])

        let contents = try FileManager.default.contentsOfDirectory(atPath: probe.store.directory.path)
        XCTAssertTrue(contents.contains(HistoryTier.t1.fileName))
        XCTAssertTrue(contents.contains(HistoryTier.t2.fileName))

        // T0 is carried forward untouched: the same sample is still where it
        // was written, at the same bucket, with the same count.
        let t0 = try XCTUnwrap(probe.store.archive(.t0))
        let sampled = probe.start + 600
        XCTAssertEqual(t0.slot(bucket: HistoryClock.bucketIndex(sampled, step: HistoryTier.t0.step),
                               lane: 0)?.count, 1)

        // The new tiers carry T0's lanes — that is what `reconcileDirectories`
        // is for — and hold the whole two hours rather than the one bucket that
        // closed while the preset was being changed.
        let t1 = try XCTUnwrap(probe.store.archive(.t1))
        let t2 = try XCTUnwrap(probe.store.archive(.t2))
        XCTAssertEqual(t1.laneCount, t0.laneCount)
        XCTAssertEqual(t2.laneCount, t0.laneCount)

        let t1Bucket = HistoryClock.bucketIndex(sampled, step: HistoryTier.t1.step)
        let t2Bucket = HistoryClock.bucketIndex(sampled, step: HistoryTier.t2.step)
        XCTAssertGreaterThan(try XCTUnwrap(t1.slot(bucket: t1Bucket, lane: 0)).count, 0)
        XCTAssertGreaterThan(try XCTUnwrap(t2.slot(bucket: t2Bucket, lane: 0)).count, 0)

        // And nothing was invented before the data starts: a bucket ten minutes
        // earlier than the first sample reads as no-data rather than as a zero.
        XCTAssertNil(t1.slot(bucket: HistoryClock.bucketIndex(probe.start - 600, step: HistoryTier.t1.step),
                             lane: 0))

        // The recorder comes back recording into its new shape.
        XCTAssertEqual(probe.recorder.status, .recording)
        let next = HistoryClock.bucketIndex(probe.now, step: HistoryTier.t0.step)
        probe.ingest(42)
        XCTAssertEqual(t0.slot(bucket: next, lane: 0)?.max, 42)
    }

    /// Shrinking Standard → Minimal discards T1 and T2 — the settings picker
    /// puts a Delete-weight confirmation in front of it for exactly that reason
    /// (§6) — and keeps T0, which is the whole of what Minimal retains.
    ///
    /// The files are unlinked rather than left behind: a `t2.rrd` nothing ever
    /// reads again would cost the user the disk the smaller preset was chosen
    /// to save. Nothing is truncated, and the mappings come down first.
    func testShrinkingToMinimalDropsTheCoarseTiersAndKeepsT0() throws {
        let probe = try self.probe(preset: .standard)
        defer { probe.recorder.stop() }

        for i in 0..<120 { probe.ingest(Double(i % 10)) }
        XCTAssertGreaterThan(try XCTUnwrap(probe.store.archive(.t1)).lastCommitBucket, 0)

        var contents = try FileManager.default.contentsOfDirectory(atPath: probe.store.directory.path)
        XCTAssertTrue(contents.contains(HistoryTier.t1.fileName))
        XCTAssertTrue(contents.contains(HistoryTier.t2.fileName))

        // What a `kill -9` during a lane-growth rebuild leaves behind. It is
        // full-size and it is swept only when its tier is next opened, which a
        // preset that dropped the tier never does — so the shrink has to take
        // it, or the disk the user asked for back is still spent.
        let orphan = probe.store.directory.appendingPathComponent("\(HistoryTier.t1.fileName).rebuild")
        try Data([0]).write(to: orphan)

        XCTAssertEqual(probe.recorder.setPreset(.minimal), .applied)
        XCTAssertEqual(probe.recorder.preset, .minimal)
        XCTAssertEqual(probe.store.openTiers, [.t0])
        XCTAssertNil(probe.store.archive(.t1))
        XCTAssertNil(probe.store.archive(.t2))

        contents = try FileManager.default.contentsOfDirectory(atPath: probe.store.directory.path)
        XCTAssertTrue(contents.contains(HistoryTier.t0.fileName))
        XCTAssertFalse(contents.contains(HistoryTier.t1.fileName))
        XCTAssertFalse(contents.contains(HistoryTier.t2.fileName))
        XCTAssertFalse(contents.contains(orphan.lastPathComponent))

        // T0 survives with its lanes and its data, and goes on recording.
        let t0 = try XCTUnwrap(probe.store.archive(.t0))
        XCTAssertEqual(probe.recorder.laneCount, 1)
        XCTAssertEqual(t0.slot(bucket: HistoryClock.bucketIndex(probe.start + 600, step: HistoryTier.t0.step),
                               lane: 0)?.count, 1)
        XCTAssertEqual(probe.recorder.status, .recording)

        let next = HistoryClock.bucketIndex(probe.now, step: HistoryTier.t0.step)
        probe.ingest(42)
        XCTAssertEqual(t0.slot(bucket: next, lane: 0)?.max, 42)
    }

    /// A full volume is the state the user is likeliest to reach for the picker
    /// in — shrinking is the obvious thing to try when the section says Stats
    /// is out of room — and the picker stays enabled there, so the switch has
    /// to leave the banner alone.
    ///
    /// Nothing else would ever put it back. `commit` returns early for as long
    /// as `isLowOnSpace` holds, and `checkFreeSpace` touches the status only
    /// when the low/not-low state flips, so a status overwritten here would
    /// read "recording" for the rest of the launch while not a byte was
    /// written. The shrink itself is not a free-space event: it gives back the
    /// coarse tiers, which on a volume this full is not necessarily enough.
    func testAPresetChangeOnAFullVolumeKeepsTheLowDiskSpaceBanner() throws {
        let probe = try self.probe(preset: .standard)
        defer { probe.recorder.stop() }

        probe.ingest(5)
        probe.freeSpace = HistoryStore.freeSpaceFloor - 1
        // The precondition is read every tenth commit; this is the cycle that
        // reads it and finds the volume full.
        for _ in 0..<HistoryRecorder.freeSpaceEveryNthCommit { probe.ingest(6) }
        XCTAssertEqual(probe.recorder.status, .lowDiskSpace)

        // The shrink goes through — that is what leaving the picker enabled is
        // for — and the volume is still full afterwards.
        XCTAssertEqual(probe.recorder.setPreset(.minimal), .applied)
        XCTAssertEqual(probe.recorder.preset, .minimal)
        XCTAssertEqual(probe.recorder.status, .lowDiskSpace)

        probe.advance(HistoryRecorder.commitInterval)
        probe.recorder.commitNow()
        XCTAssertEqual(probe.recorder.status, .lowDiskSpace)

        // And the banner still clears itself the moment there is room again,
        // which is the flip `checkFreeSpace` is waiting for.
        probe.freeSpace = HistoryStore.freeSpaceFloor
        let recovered = probe.now
        probe.ingest(7)
        XCTAssertEqual(probe.recorder.status, .recording)

        let t0 = try XCTUnwrap(probe.store.archive(.t0))
        XCTAssertEqual(t0.slot(bucket: HistoryClock.bucketIndex(recovered, step: HistoryTier.t0.step),
                               lane: 0)?.max, 7)
    }

    /// The picker's figures come from the live lane count, not from a ceiling
    /// (§6), and they are the whole tier file rather than its matrix: §3's
    /// per-lane and MB tables count only the matrix, so every figure here sits
    /// a little above the doc's — one 4 KiB header and one 128 B directory
    /// entry per lane per tier — and that gap is what the readout beside it
    /// measures for real.
    func testTheProjectedSizeIsTheWholeArchiveAtTheGivenLaneCount() {
        // 8,640 slots a lane at Minimal; 47,760 at Standard (§3).
        XCTAssertEqual(HistoryRetentionPreset.minimal.projectedBytes(lanes: 1), 4_096 + 128 + 8_640 * 20)
        XCTAssertEqual(HistoryRetentionPreset.standard.projectedBytes(lanes: 1),
                       3 * (4_096 + 128) + 47_760 * 20)

        // §3's MB table, which is what the settings row is checked against by
        // hand: ~20 MB at first launch, 43 MB a month in, 244.5 MB at the cap.
        let mb = 1_000_000.0
        XCTAssertEqual(Double(HistoryRetentionPreset.standard.projectedBytes(lanes: 21)) / mb, 20.1, accuracy: 0.1)
        XCTAssertEqual(Double(HistoryRetentionPreset.standard.projectedBytes(lanes: 45)) / mb, 43.0, accuracy: 0.1)
        XCTAssertEqual(
            Double(HistoryRetentionPreset.standard.projectedBytes(lanes: HistoryLaneDirectory.laneCap)) / mb,
            244.5, accuracy: 0.2
        )
        // The worst case anyone can reach stays inside §3's 256 MiB budget.
        XCTAssertLessThan(HistoryRetentionPreset.standard.projectedBytes(lanes: HistoryLaneDirectory.laneCap),
                          256 * 1_024 * 1_024)

        // Minimal is the cheaper of the two at every lane count, which is the
        // one thing about the pair the user has to be able to rely on.
        for lanes in [0, 1, 21, 45, 116, HistoryLaneDirectory.laneCap] {
            XCTAssertLessThan(HistoryRetentionPreset.minimal.projectedBytes(lanes: lanes),
                              HistoryRetentionPreset.standard.projectedBytes(lanes: lanes))
        }
    }

    /// A stop/start cycle has to leave a recorder that still commits on its own.
    ///
    /// The timer is wanted by the ingest that dirties a clean table and given up
    /// by the commit that leaves it clean, so a `stop` that parks the timer
    /// while the open bucket still holds samples has to give the intent up too.
    /// Without that the recorder comes back from the next `start` with a
    /// suspended timer nothing will ever resume, and the loss is silent: the
    /// accumulators keep folding and the staging ring drops everything older
    /// than its 160 s.
    func testStopAndStartLeavesTheCommitTimerAlive() throws {
        let probe = try self.probe()
        defer { probe.recorder.stop() }

        probe.recorder.ingest(Probe.payload(1), reader: Probe.reader, interval: 1)
        XCTAssertTrue(probe.recorder.isCommitTimerRunning)

        // Stopped mid-bucket, which is the ordinary case: what was folded a
        // moment ago is still open and the table is anything but clean.
        probe.now += 1
        probe.recorder.ingest(Probe.payload(2), reader: Probe.reader, interval: 1)
        probe.recorder.stop()
        XCTAssertFalse(probe.recorder.isCommitTimerRunning)
        XCTAssertEqual(probe.recorder.status, .disabled)

        probe.now += TimeInterval(HistoryTier.t0.step)
        probe.recorder.start(enabled: true)
        probe.recorder.waitUntilIdle()
        XCTAssertEqual(probe.recorder.status, .recording)
        XCTAssertFalse(probe.recorder.isCommitTimerRunning)

        // The ingest after the restart is the one that has to arrange a commit.
        probe.recorder.ingest(Probe.payload(3), reader: Probe.reader, interval: 1)
        XCTAssertTrue(probe.recorder.isCommitTimerRunning)

        // And the commit it arranged writes: the bucket this sample landed in
        // is on disk one cadence later, without anyone calling `flush`.
        let bucket = HistoryClock.bucketIndex(probe.now, step: HistoryTier.t0.step)
        probe.now += HistoryRecorder.commitInterval
        probe.recorder.commitNow()
        let t0 = try XCTUnwrap(probe.store.archive(.t0))
        let slot = try XCTUnwrap(t0.slot(bucket: bucket, lane: 0))
        XCTAssertEqual(slot.count, 1)
        XCTAssertEqual(slot.max, 3)
        XCTAssertEqual(probe.recorder.laneCount, 1)
    }

    /// The suite is hosted by Stats.app, so the real `AppDelegate` has already
    /// run by the time this executes and has already called
    /// `HistoryRecorder.shared.start()`. That must have done nothing: the
    /// shared recorder is pointed at the developer's own
    /// `~/Library/Application Support/Stats/history`, and a test run has no
    /// business creating it, taking its `flock` — against a Stats in the menu
    /// bar that already holds it — or writing a sample into it.
    ///
    /// Nothing is asserted about the filesystem, deliberately: that directory
    /// legitimately exists on a machine where Stats is installed, so the
    /// evidence is the recorder's own state and the lock it never took.
    func testTheSharedRecorderStaysIdleUnderTheTestHost() throws {
        XCTAssertTrue(HistoryRecorder.isRunningUnderTestHost)

        // Called again here rather than trusting the launch: the guard is in
        // `start` itself, so this is the same path `AppDelegate` took.
        HistoryRecorder.shared.start()
        HistoryRecorder.shared.waitUntilIdle()

        XCTAssertFalse(HistoryRecorder.shared.isRecording)
        XCTAssertEqual(HistoryRecorder.shared.status, .disabled)
        XCTAssertEqual(HistoryRecorder.shared.laneCount, 0)
        XCTAssertFalse(HistoryStore.shared.holdsLock)

        // And the seam the guard is cut at: a recorder the test owns, on a
        // temporary directory, starts exactly as it does in the app.
        let probe = try self.probe()
        defer { probe.recorder.stop() }
        XCTAssertTrue(probe.recorder.isRecording)
        XCTAssertEqual(probe.recorder.status, .recording)
        XCTAssertTrue(probe.store.holdsLock)
    }

    // MARK: - settings (master switch, size readout, delete)

    /// The Delete button's whole contract in one pass (§6): what was recorded
    /// is gone, the lane registry that named it is gone with it, the archives
    /// are back and empty, and the recorder keeps recording into them.
    ///
    /// The `.lock` file is asserted to survive on purpose. It is the one thing
    /// in the directory this process still holds a `flock` on, and deleting it
    /// would let a second copy of Stats create a fresh inode and take a lock
    /// that excludes nobody.
    func testDeleteAllEmptiesTheArchivesAndGoesOnRecording() throws {
        let probe = try self.probe()
        defer { probe.recorder.stop() }

        probe.recorder.ingest(Probe.payload(42), reader: Probe.reader, interval: 1)
        let bucket = HistoryClock.bucketIndex(probe.now, step: HistoryTier.t0.step)
        probe.now += HistoryRecorder.commitInterval
        probe.recorder.commitNow()

        let recorded = try XCTUnwrap(probe.store.archive(.t0))
        XCTAssertEqual(recorded.slot(bucket: bucket, lane: 0)?.max, 42)
        XCTAssertEqual(probe.recorder.laneCount, 1)
        // The readout the settings row shows: preallocated, so it is the whole
        // Standard geometry rather than the handful of bytes just written.
        XCTAssertGreaterThan(probe.store.bytesOnDisk, 0)

        XCTAssertTrue(probe.recorder.deleteAll())

        XCTAssertEqual(probe.recorder.laneCount, 0)
        XCTAssertEqual(probe.recorder.status, .recording)
        XCTAssertTrue(probe.store.holdsLock)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: probe.store.directory.appendingPathComponent(".lock").path
        ))

        let emptied = try XCTUnwrap(probe.store.archive(.t0))
        XCTAssertEqual(emptied.laneCount, 0)
        XCTAssertEqual(emptied.lastCommitBucket, 0)
        XCTAssertNil(emptied.slot(bucket: bucket, lane: 0))

        // And the lane comes back at id 0 in the new file, rather than the
        // staged row of a deleted archive landing in the one that replaced it.
        probe.now += TimeInterval(HistoryTier.t0.step)
        probe.recorder.ingest(Probe.payload(7), reader: Probe.reader, interval: 1)
        let next = HistoryClock.bucketIndex(probe.now, step: HistoryTier.t0.step)
        probe.now += HistoryRecorder.commitInterval
        probe.recorder.commitNow()

        XCTAssertEqual(probe.recorder.laneCount, 1)
        let reopened = try XCTUnwrap(probe.store.archive(.t0))
        XCTAssertEqual(reopened.slot(bucket: next, lane: 0)?.max, 7)
        XCTAssertNil(reopened.slot(bucket: bucket, lane: 0))
    }

    /// §2's whole concurrency story in one test: ingest on the main run loop —
    /// where Battery's IOPS notification lands — and on a second reader queue,
    /// racing the commit thread that snapshots and resets the same accumulators.
    ///
    /// Run it under Thread Sanitizer with
    ///
    ///     xcodebuild -project Stats.xcodeproj -scheme Stats \
    ///       -derivedDataPath <dd> test -enableThreadSanitizer YES \
    ///       -only-testing:Tests/HistoryTests/testIngestOnTwoQueuesRacesTheCommitThread \
    ///       CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=""
    ///
    /// The shared scheme deliberately does not turn TSAN on: it is an upstream
    /// file this fork tries not to touch (§9), and a sanitized run of the whole
    /// suite costs about ten times the wall clock for one test's benefit.
    ///
    /// The clock here is the real one. A test-driven clock would be mutable
    /// state shared between these threads, and the race the sanitizer found
    /// would be the harness's own.
    func testIngestOnTwoQueuesRacesTheCommitThread() throws {
        let directory = self.folder.appendingPathComponent("history")
        let store = HistoryStore(directory: directory)
        let recorder = HistoryRecorder(store: store, preset: .standard, environment: HistoryRecorder.Environment(
            now: { Date().timeIntervalSince1970 },
            availableSpace: { _ in Int64.max },
            isPowerConstrained: { false }
        ))
        recorder.start(enabled: true)
        recorder.waitUntilIdle()
        defer { recorder.stop() }

        let ticks = 2_000
        let finished = self.expectation(description: "ingest and commit finished")
        finished.expectedFulfillmentCount = 2

        DispatchQueue(label: "history-tests.reader").async {
            for i in 0..<ticks {
                recorder.ingest(Probe.payload(Double(i % 97), source: "reader"),
                                reader: Probe.reader, interval: 1)
            }
            finished.fulfill()
        }
        DispatchQueue(label: "history-tests.commit").async {
            for _ in 0..<(ticks / 10) {
                recorder.commitNow()
            }
            finished.fulfill()
        }
        // The test method itself runs on main, which is where Battery ingests.
        for i in 0..<ticks {
            recorder.ingest(Probe.payload(Double(i % 89), source: "battery"),
                            reader: Probe.reader, interval: 1)
        }

        self.wait(for: [finished], timeout: 120)
        recorder.commitNow()
        XCTAssertEqual(recorder.laneCount, 2)
        XCTAssertEqual(recorder.status, .recording)
    }

    // MARK: - sleep, wake and the clock
    //
    // A simulated nine-hour sleep; a backward clock jump inside a tier's window
    // and one past it; a gap at least a tier's capacity resetting it rather
    // than iterating its ring; the forward step that needs no action; the span
    // sidecar and the order gap reasons are derived in.

    /// The machine sleeps for nine hours. The continuous clock counts through
    /// it, so nothing reads as a clock step; the span the observers record is
    /// what turns the hole in the series into "Asleep 02:14–08:31" (§4).
    func testASimulatedNineHourSleepReadsAsAsleep() throws {
        let probe = try self.probe()
        defer { probe.recorder.stop() }

        let first = HistoryClock.bucketIndex(probe.now, step: HistoryTier.t0.step)
        probe.ingest(40)

        let sleepAt = probe.now
        probe.recorder.noteWillSleep(at: sleepAt)
        probe.advance(9 * 3600)
        let wakeAt = probe.now
        probe.recorder.noteDidWake(at: wakeAt)
        probe.recorder.waitUntilIdle()

        XCTAssertEqual(probe.recorder.gapSpans,
                       [HistoryGapSpan(from: UInt64(sleepAt), to: UInt64(wakeAt), reason: .asleep)])

        // Recording carries on after the wake, and the wake itself is not a
        // clock step: nine hours of wall clock are nine hours of continuous
        // clock too, which is the whole reason `mach_continuous_time` is the
        // reference rather than `mach_absolute_time`.
        probe.ingest(50)
        XCTAssertEqual(probe.recorder.gapSpans.count, 1)
        XCTAssertLessThan(probe.recorder.gapSpans[0].to, UInt64(probe.now))

        let t0 = try XCTUnwrap(probe.store.archive(.t0))
        let resolver = try XCTUnwrap(probe.recorder.gapResolver(tier: .t0, lane: 0))

        // What was measured before the sleep still reads as measured,
        XCTAssertEqual(resolver.reason(for: first, slot: t0.slot(bucket: first, lane: 0)), .measured)
        // the middle of the sleep says so in words,
        let asleep = HistoryClock.bucketIndex(sleepAt + 4.5 * 3600, step: HistoryTier.t0.step)
        XCTAssertNil(t0.slot(bucket: asleep, lane: 0))
        XCTAssertEqual(resolver.reason(for: asleep, slot: nil), .asleep)
        // and a bucket from before the lane existed is no-data, sleep or not.
        XCTAssertEqual(resolver.reason(for: first &- 100, slot: nil), .nodata)
    }

    /// The clock is set back by less than a tier's window. §4: the slots whose
    /// stamps belong to the pre-step era are never overwritten, and the tier is
    /// not reset — two eras meet, and the older one keeps the buckets it wrote.
    func testABackwardClockJumpInsideTheWindowKeepsThePreStepSlots() throws {
        let probe = try self.probe()
        defer { probe.recorder.stop() }

        // Four T0 buckets of a measured 42.
        let first = HistoryClock.bucketIndex(probe.now, step: HistoryTier.t0.step)
        for offset in 0..<4 {
            probe.now = probe.start + TimeInterval(offset * HistoryTier.t0.step)
            probe.recorder.ingest(Probe.payload(42), reader: Probe.reader, interval: 1)
        }
        probe.now = probe.start + HistoryRecorder.commitInterval
        probe.recorder.commitNow()

        let t0 = try XCTUnwrap(probe.store.archive(.t0))
        XCTAssertEqual(t0.lastCommitBucket, first + 3)

        // Fifty seconds back — five T0 buckets, well past the 2 s threshold and
        // nowhere near T0's 24 h ring.
        probe.stepClock(by: -50)
        probe.recorder.ingest(Probe.payload(99), reader: Probe.reader, interval: 1)
        probe.recorder.waitUntilIdle()
        probe.advance(HistoryRecorder.commitInterval)
        probe.recorder.commitNow()

        // The re-lived buckets still hold what the pre-step era measured.
        for offset in 0..<4 {
            let slot = try XCTUnwrap(t0.slot(bucket: first + UInt32(offset), lane: 0))
            XCTAssertEqual(slot.min, 42)
            XCTAssertEqual(slot.max, 42)
            XCTAssertEqual(slot.reason, .measured)
        }
        XCTAssertEqual(t0.lastCommitBucket, first + 3)
        XCTAssertEqual(t0.entry(lane: 0)?.firstValidBucket, first)
        XCTAssertEqual(probe.recorder.gapSpans.map { $0.reason }, [.clockStep])

        // And the new era records again the moment it is past the high-water
        // mark: the rule drops rows, it does not stop recording.
        let resumed = HistoryClock.bucketIndex(probe.now, step: HistoryTier.t0.step)
        XCTAssertGreaterThan(resumed, first + 3)
        probe.recorder.ingest(Probe.payload(99), reader: Probe.reader, interval: 1)
        probe.advance(HistoryRecorder.commitInterval)
        probe.recorder.commitNow()
        XCTAssertEqual(try XCTUnwrap(t0.slot(bucket: resumed, lane: 0)).min, 99)
    }

    /// The clock is set back by more than a tier's window. §4: that tier is
    /// reset rather than interleaving two eras — and only that tier, because
    /// the wider ones still have room for both.
    func testABackwardClockJumpPastATierWindowResetsOnlyThatTier() throws {
        let probe = try self.probe()
        defer { probe.recorder.stop() }

        // Five minutes of samples, committed as they go, so that T1 has closed
        // buckets of its own and not just T0.
        let first = HistoryClock.bucketIndex(probe.now, step: HistoryTier.t0.step)
        for _ in 0..<5 { probe.ingest(42) }

        let t0 = try XCTUnwrap(probe.store.archive(.t0))
        let t1 = try XCTUnwrap(probe.store.archive(.t1))
        XCTAssertNotNil(t0.slot(bucket: first, lane: 0))
        let t1Cursor = t1.lastCommitBucket
        XCTAssertGreaterThan(t1Cursor, 0)

        // Twenty-five hours back: past T0's 24 h ring, nowhere near T1's 30 days.
        probe.stepClock(by: -25 * 3600)
        probe.recorder.ingest(Probe.payload(7), reader: Probe.reader, interval: 1)
        probe.recorder.waitUntilIdle()

        XCTAssertEqual(t0.lastCommitBucket, 0)
        XCTAssertNil(t0.slot(bucket: first, lane: 0))
        XCTAssertEqual(t0.entry(lane: 0)?.firstValidBucket, HistoryLaneEntry.noValidBucket)
        // The lanes survive the reset: a reset tier is the same set of series.
        XCTAssertEqual(t0.laneCount, 1)
        XCTAssertEqual(t0.entry(lane: 0)?.label, Probe.label)

        // T1 is thirty days wide and keeps everything it had.
        XCTAssertEqual(t1.lastCommitBucket, t1Cursor)
        XCTAssertNotNil(t1.slot(bucket: t1Cursor, lane: 0))

        // The new era records into the reset tier immediately.
        let resumed = HistoryClock.bucketIndex(probe.now, step: HistoryTier.t0.step)
        probe.advance(HistoryRecorder.commitInterval)
        probe.recorder.commitNow()
        XCTAssertEqual(try XCTUnwrap(t0.slot(bucket: resumed, lane: 0)).min, 7)
    }

    /// A gap at or beyond a tier's capacity resets it "instead of iterating a
    /// full ring" (§4) — the write count is what that sentence means, so it is
    /// what this asserts.
    func testAGapAtLeastATierCapacityResetsItWithoutIteratingTheRing() throws {
        let directory = self.folder.appendingPathComponent("history")
        let probe = try self.probe(directory: directory)
        let first = HistoryClock.bucketIndex(probe.now, step: HistoryTier.t0.step)
        probe.ingest(42)
        XCTAssertNotNil(try XCTUnwrap(probe.store.archive(.t0)).slot(bucket: first, lane: 0))
        probe.recorder.stop()

        var written = 0
        HistoryArchive.writeObserver = { _, count in written += count }
        defer { HistoryArchive.writeObserver = nil }

        // A second launch twenty-five hours on: every slot in T0's 24 h ring
        // belongs to a window that has closed.
        let second = RecorderProbe(directory: directory, preset: .standard, now: probe.now + 25 * 3600)
        second.recorder.start(enabled: true)
        second.recorder.waitUntilIdle()
        defer { second.recorder.stop() }

        let t0 = try XCTUnwrap(second.store.archive(.t0))
        XCTAssertEqual(t0.lastCommitBucket, 0)
        XCTAssertNil(t0.slot(bucket: first, lane: 0))
        XCTAssertEqual(t0.laneCount, 1)

        // The whole launch — three tiers opened, one of them reset — writes
        // headers and directories and not one matrix row. A ring's worth would
        // be 8,640 rows.
        XCTAssertGreaterThan(written, 0)
        XCTAssertLessThan(written, 10 * HistoryArchiveHeader.byteWidth)
        XCTAssertLessThan(written, HistoryTier.t0.buckets * HistorySlot.byteWidth)

        // And the hole itself is named: "Stats was not running" follows from
        // `lastCommitBucket` and nothing else (§4).
        XCTAssertEqual(second.recorder.gapSpans.map { $0.reason }, [.notRunning])
    }

    /// "A forward step needs no action: the ring advances and skipped slots
    /// read as no-data by their stamps" (§4). The one thing it does leave is
    /// the span, because otherwise "Clock changed" and "nothing was recorded"
    /// are the same answer.
    func testAForwardClockStepLeavesTheArchiveAloneAndRecordsASpan() throws {
        let probe = try self.probe()
        defer { probe.recorder.stop() }

        let first = HistoryClock.bucketIndex(probe.now, step: HistoryTier.t0.step)
        probe.ingest(42)
        let t0 = try XCTUnwrap(probe.store.archive(.t0))
        let cursor = t0.lastCommitBucket

        let steppedAt = probe.now
        probe.stepClock(by: 3600)
        probe.recorder.ingest(Probe.payload(7), reader: Probe.reader, interval: 1)
        probe.recorder.waitUntilIdle()

        XCTAssertEqual(t0.lastCommitBucket, cursor)
        XCTAssertNotNil(t0.slot(bucket: first, lane: 0))
        XCTAssertEqual(probe.recorder.gapSpans,
                       [HistoryGapSpan(from: UInt64(steppedAt), to: UInt64(steppedAt + 3600),
                                       reason: .clockStep)])

        probe.advance(HistoryRecorder.commitInterval)
        probe.recorder.commitNow()
        let resolver = try XCTUnwrap(probe.recorder.gapResolver(tier: .t0, lane: 0))
        let skipped = HistoryClock.bucketIndex(steppedAt + 1800, step: HistoryTier.t0.step)
        XCTAssertNil(t0.slot(bucket: skipped, lane: 0))
        XCTAssertEqual(resolver.reason(for: skipped, slot: nil), .clockStep)
    }

    /// The sidecar: written on every change, read back at the next launch,
    /// capped by age and not by line count (§4), and garbage in it costs a gap
    /// reason rather than the archive.
    func testTheSpanSidecarIsPersistedAndAgeCappedToT2Retention() throws {
        let url = self.folder.appendingPathComponent(HistorySleepMonitor.fileName)
        var clock: TimeInterval = 1_760_000_000
        let monitor = HistorySleepMonitor(url: url, now: { clock })

        monitor.noteSleep(at: clock)
        // A second willSleep with no wake between them is the same sleep.
        monitor.noteSleep(at: clock + 1)
        clock += 9 * 3600
        monitor.noteWake(at: clock)
        monitor.note(HistoryGapSpan(from: UInt64(clock + 60), to: UInt64(clock + 120), reason: .notRunning))
        XCTAssertEqual(monitor.spans.count, 2)
        XCTAssertEqual(monitor.spans[0].reason, .asleep)
        XCTAssertEqual(monitor.spans[0].to - monitor.spans[0].from, 9 * 3600)

        let reopened = HistorySleepMonitor(url: url, now: { clock })
        reopened.load()
        XCTAssertEqual(reopened.spans, monitor.spans)

        // A year and a day on they are outside T2's window.
        clock += HistorySleepMonitor.retention + 86_400
        let aged = HistorySleepMonitor(url: url, now: { clock })
        aged.load()
        XCTAssertTrue(aged.spans.isEmpty)

        try Data(repeating: 0xAB, count: 512).write(to: url)
        let damaged = HistorySleepMonitor(url: url, now: { clock })
        damaged.load()
        XCTAssertTrue(damaged.spans.isEmpty)
    }

    /// A process closes only the sleep it opened itself (§4).
    ///
    /// The machine is put to sleep and never wakes into that process — powered
    /// off, battery flat, force-rebooted. The span is on disk, open. If the
    /// next launch restored it, the next wake — a night later — would close it
    /// and produce an "Asleep" covering a day the machine was demonstrably
    /// awake, over every bucket a disabled module or a paused app left empty,
    /// and that night's own sleep would have been refused as "already asleep".
    func testASleepLeftOpenByADeadProcessIsNotClosedByTheNextOne() throws {
        let url = self.folder.appendingPathComponent(HistorySleepMonitor.fileName)
        var clock: TimeInterval = 1_760_000_000

        // Day 1, 23:00. Sleep, then the process dies without a wake.
        let died = HistorySleepMonitor(url: url, now: { clock })
        died.noteSleep(at: clock)
        XCTAssertEqual(died.spans.count, 1)
        XCTAssertTrue(died.spans[0].isOpen)

        // Day 2, 09:00. The next launch reads the sidecar and drops it.
        let sleptAt = clock
        clock += 10 * 3600
        let relaunched = HistorySleepMonitor(url: url, now: { clock })
        relaunched.load()
        XCTAssertTrue(relaunched.spans.isEmpty)

        // The stretch is not lost — it is what the launch's own downtime span
        // covers, and `note()` sorts it before anything this run opens.
        relaunched.note(HistoryGapSpan(from: UInt64(sleptAt) - 60, to: UInt64(clock), reason: .notRunning))

        // Day 2, 23:30. This night's sleep is recorded rather than swallowed by
        // a guard that thinks the machine is already asleep.
        clock += 14.5 * 3600
        let sleptAgainAt = clock
        relaunched.noteSleep(at: clock)
        XCTAssertEqual(relaunched.spans.count, 2)

        // Day 3, 07:00. The wake closes this run's sleep, and only that.
        clock += 7.5 * 3600
        relaunched.noteWake(at: clock)
        let asleep = relaunched.spans.filter { $0.reason == .asleep }
        XCTAssertEqual(asleep.count, 1)
        XCTAssertEqual(asleep[0].from, UInt64(sleptAgainAt))
        XCTAssertEqual(asleep[0].to - asleep[0].from, UInt64(7.5 * 3600))
        XCTAssertEqual(relaunched.spans.filter { $0.isOpen }.count, 0)

        // And an open span is not exempt from the age cap: it has no end to age
        // out by, so it ages by its start, or it would never be evicted at all.
        let ancient = HistorySleepMonitor(url: url, now: { clock })
        ancient.noteSleep(at: clock)
        XCTAssertEqual(ancient.spans.count, 1)
        clock += HistorySleepMonitor.retention + 86_400
        ancient.note(HistoryGapSpan(from: UInt64(clock) - 120, to: UInt64(clock) - 60, reason: .notRunning))
        XCTAssertEqual(ancient.spans.count, 1)
        XCTAssertEqual(ancient.spans[0].reason, .notRunning)
    }

    /// A sleep that is aborted inside the same second it began leaves nothing
    /// behind, and above all does not leave a span open.
    ///
    /// macOS posts `willSleep` and then `didWake` sub-second on a vetoed sleep
    /// and on a short dark wake, and both handlers read the wall clock in
    /// seconds — so the wake cannot close the span by moving `to` past `from`.
    /// A span left open there is not a cosmetic loss: `noteSleep` refuses to
    /// open a second one while one is open, so every later sleep in the process
    /// would be dropped and every gap after it would derive as no-data instead
    /// of "Asleep".
    func testASleepAbortedInsideItsOwnSecondLeavesNothingOpen() throws {
        let url = self.folder.appendingPathComponent(HistorySleepMonitor.fileName)
        var clock: TimeInterval = 1_760_000_000
        let monitor = HistorySleepMonitor(url: url, now: { clock })

        // 23:00:00.1 — the sleep is vetoed and the machine wakes 200 ms later.
        monitor.noteSleep(at: clock + 0.1)
        XCTAssertEqual(monitor.spans.count, 1)
        monitor.noteWake(at: clock + 0.3)
        XCTAssertTrue(monitor.spans.isEmpty)
        XCTAssertEqual(monitor.spans.filter { $0.isOpen }.count, 0)

        // An hour later the machine really does sleep, and it is recorded.
        clock += 3600
        let sleptAt = clock
        monitor.noteSleep(at: clock)
        clock += 8 * 3600
        monitor.noteWake(at: clock)
        XCTAssertEqual(monitor.spans.count, 1)
        XCTAssertEqual(monitor.spans[0].reason, .asleep)
        XCTAssertEqual(monitor.spans[0].from, UInt64(sleptAt))
        XCTAssertEqual(monitor.spans[0].to - monitor.spans[0].from, UInt64(8 * 3600))

        // And the aborted one is not on disk either: the drop is persisted, not
        // only applied in memory.
        let reopened = HistorySleepMonitor(url: url, now: { clock })
        reopened.load()
        XCTAssertEqual(reopened.spans, monitor.spans)
    }

    /// `reasons(for:slots:)` walks the spans alongside the buckets instead of
    /// scanning them per column. Same answers as the per-bucket derivation, for
    /// spans that overlap, that are handed over unsorted, that sit entirely
    /// outside the range, and for one left open.
    func testTheRangeWalkAgreesWithThePerBucketDerivation() throws {
        let step = HistoryTier.t0.step
        let base = UInt32(1_760_000_000 / step)
        let at: (UInt32) -> UInt64 = { UInt64($0) * UInt64(step) }
        let resolver = HistoryGapResolver(
            step: step, firstValidBucket: base, lastCommitBucket: base + 60,
            spans: [
                HistoryGapSpan(from: at(base + 40), to: at(base + 44), reason: .clockStep),
                HistoryGapSpan(from: at(base + 5), to: at(base + 30), reason: .notRunning),
                HistoryGapSpan(from: at(base + 10), to: at(base + 20), reason: .asleep),
                HistoryGapSpan(from: at(base + 12), to: at(base + 12), reason: .asleep),
                HistoryGapSpan(from: at(base + 200), to: at(base + 300), reason: .asleep)
            ]
        )

        let range = base..<(base + 70)
        let slots: [HistorySlot?] = range.map { bucket in
            bucket == base + 15 ? HistorySlot(bucket: bucket, count: 3, reason: .measured) : nil
        }
        XCTAssertEqual(resolver.reasons(for: range, slots: slots),
                       range.enumerated().map { resolver.reason(for: $1, slot: slots[$0]) })

        // And the answers themselves, so the walk is not merely agreeing with a
        // scan that is also wrong.
        XCTAssertEqual(resolver.reasons(for: range, slots: slots)[15], .measured)
        XCTAssertEqual(resolver.reasons(for: range, slots: slots)[7], .notRunning)
        XCTAssertEqual(resolver.reasons(for: range, slots: slots)[16], .asleep)
        XCTAssertEqual(resolver.reasons(for: range, slots: slots)[42], .clockStep)
        XCTAssertEqual(resolver.reasons(for: range, slots: slots)[65], .notRunning)
    }

    /// The order §4's taxonomy is derived in, which is the whole of the logic:
    /// the slot, then the lane's own beginning, then the most specific span,
    /// then the archive's cursor.
    func testGapReasonsAreDerivedInOrderOfSpecificity() throws {
        let step = HistoryTier.t0.step
        let base = UInt32(1_760_000_000 / step)
        let at: (UInt32) -> UInt64 = { UInt64($0) * UInt64(step) }
        let resolver = HistoryGapResolver(
            step: step, firstValidBucket: base + 5, lastCommitBucket: base + 30,
            spans: [
                HistoryGapSpan(from: at(base + 10), to: at(base + 20), reason: .notRunning),
                HistoryGapSpan(from: at(base + 12), to: at(base + 16), reason: .asleep)
            ]
        )

        // Nothing was ever written this far back, whatever the spans say.
        XCTAssertEqual(resolver.reason(for: base, slot: nil), .nodata)
        // A recorded slot answers for itself, held included.
        XCTAssertEqual(resolver.reason(for: base + 6,
                                       slot: HistorySlot(bucket: base + 6, count: 2, reason: .measured)), .measured)
        XCTAssertEqual(resolver.reason(for: base + 7,
                                       slot: HistorySlot(bucket: base + 7, count: 1, reason: .held)), .held)
        // Stats was running and wrote the neighbours: a disabled module or a
        // paused app, which §2 collapses to no-data rather than guessing.
        XCTAssertEqual(resolver.reason(for: base + 8, slot: nil), .nodata)
        // The app was down, and inside that stretch the machine was asleep.
        XCTAssertEqual(resolver.reason(for: base + 11, slot: nil), .notRunning)
        XCTAssertEqual(resolver.reason(for: base + 13, slot: nil), .asleep)
        // Past the last commit the archive simply stops.
        XCTAssertEqual(resolver.reason(for: base + 31, slot: nil), .notRunning)

        XCTAssertEqual(resolver.reasons(for: (base + 11)..<(base + 14), slots: [nil, nil, nil]),
                       [.notRunning, .asleep, .asleep])
    }

    // MARK: - the Reader.callback hook
    //
    // The one line in `Kit/module/reader.swift` that connects every reader in
    // the app to the recorder. These drive a real `Reader` subclass through its
    // real `callback` rather than calling `ingest` directly, because everything
    // worth getting wrong there — which identity is passed, whose interval is
    // passed, and whether the master switch is consulted before any of it — is
    // invisible to a test that does the call itself.
    //
    // The `Tests` bundle is hosted by Stats itself, so while these run the real
    // app has launched, mounted its modules and is ticking a dozen real readers
    // through the very line under test. Those samples land in the probe for as
    // long as the hook points at it, so nothing here asserts a lane count or a
    // lane index: the hook's own lane is found by its label, and everything
    // else in the archive belongs to whatever the machine was doing.

    func testReaderCallbackFeedsTheRecorder() throws {
        let probe = try self.probe(preset: .minimal)
        defer { probe.recorder.stop() }
        let reader = self.hookedReader(probe, interval: 1)

        let first = HistoryClock.bucketIndex(probe.now, step: HistoryTier.t0.step)
        reader.callback(HookPayload(value: 42))

        // The reader's own identity, not the payload's type: `CapacityReader`,
        // `ActivityReader` and `SMARTReader` are all `Reader<Disks>` (§2).
        XCTAssertEqual(HookPayload.log.keys, [HistoryReaderKey(module: .CPU, name: "HookReader")])

        probe.advance(HistoryRecorder.commitInterval)
        probe.recorder.commitNow()

        let t0 = try XCTUnwrap(probe.store.archive(.t0))
        let lane = try XCTUnwrap(self.hookLane(t0))
        let slot = try XCTUnwrap(t0.slot(bucket: first, lane: lane))
        XCTAssertEqual(slot.count, 1)
        XCTAssertEqual(slot.max, 42)
        XCTAssertEqual(slot.reason, .measured)
        // A one-second interval stands for one second, so nothing is attributed
        // behind the bucket the sample landed in.
        XCTAssertNil(t0.slot(bucket: first &- 1, lane: lane))
    }

    /// The hook passes `self.interval`, which is what turns a 60 s reader into
    /// six filled 10 s buckets instead of one filled and five gaps (§2). A hook
    /// that passed `nil` would look identical in the test above and wrong here.
    func testReaderCallbackForwardsTheReaderInterval() throws {
        let probe = try self.probe(preset: .minimal)
        defer { probe.recorder.stop() }
        let reader = self.hookedReader(probe, interval: 60)

        let first = HistoryClock.bucketIndex(probe.now, step: HistoryTier.t0.step)
        reader.callback(HookPayload(value: 42))
        probe.advance(HistoryRecorder.commitInterval)
        probe.recorder.commitNow()

        let t0 = try XCTUnwrap(probe.store.archive(.t0))
        let lane = try XCTUnwrap(self.hookLane(t0))
        for offset in 0...6 {
            let slot = try XCTUnwrap(t0.slot(bucket: first &- UInt32(offset), lane: lane),
                                     "bucket \(first) - \(offset) was left as a gap")
            XCTAssertEqual(slot.max, 42)
        }
        XCTAssertNil(t0.slot(bucket: first &- 7, lane: lane))
    }

    /// §2: the master switch off costs a predicated branch. The payload is
    /// never asked for its lanes, so a reader that emits nothing — Clock's
    /// `Reader<Date>`, every `ProcessReader` — pays nothing either.
    func testTheMasterSwitchOffStopsTheHookBeforeExtraction() throws {
        let probe = try self.probe(preset: .minimal)
        defer { probe.recorder.stop() }
        let reader = self.hookedReader(probe, interval: 1)

        probe.recorder.setRecording(false)
        probe.recorder.waitUntilIdle()
        reader.callback(HookPayload(value: 42))

        XCTAssertTrue(HookPayload.log.keys.isEmpty)
        probe.advance(HistoryRecorder.commitInterval)
        probe.recorder.commitNow()
        XCTAssertNil(self.hookLane(try XCTUnwrap(probe.store.archive(.t0))))

        // And back on, through the same reader, to prove the switch is the only
        // thing that stopped it.
        probe.recorder.setRecording(true)
        let resumed = HistoryClock.bucketIndex(probe.now, step: HistoryTier.t0.step)
        reader.callback(HookPayload(value: 7))
        XCTAssertEqual(HookPayload.log.keys.count, 1)
        probe.advance(HistoryRecorder.commitInterval)
        probe.recorder.commitNow()

        let t0 = try XCTUnwrap(probe.store.archive(.t0))
        let lane = try XCTUnwrap(self.hookLane(t0))
        XCTAssertEqual(t0.slot(bucket: resumed, lane: lane)?.max, 7)
    }

    /// The other half of "costs a predicated branch": the call site builds its
    /// `HistoryReaderKey` from `Reader.name`, which is `NSStringFromClass`
    /// split and rebuilt on every access, so an eagerly evaluated argument
    /// would cost that string on every tick of every reader with recording off.
    /// `ingest` takes the key as an `@autoclosure` precisely so it does not.
    func testTheReaderKeyIsNotBuiltWhileRecordingIsOff() throws {
        let probe = try self.probe()
        defer { probe.recorder.stop() }

        var built = 0
        probe.recorder.setRecording(false)
        probe.recorder.waitUntilIdle()
        probe.recorder.ingest(Probe.payload(42),
                              reader: { built += 1; return Probe.reader }(), interval: 1)
        XCTAssertEqual(built, 0)

        probe.recorder.setRecording(true)
        probe.recorder.ingest(Probe.payload(42),
                              reader: { built += 1; return Probe.reader }(), interval: 1)
        XCTAssertEqual(built, 1)
    }

    // MARK: - hook fixtures

    /// Points the hook at this probe's recorder for the rest of the test, with
    /// a clean log and a known interval.
    private func hookedReader(_ probe: RecorderProbe, interval: Double) -> HookReader {
        let previous = HistoryRecorder.hook
        HistoryRecorder.hook = probe.recorder
        self.addTeardownBlock { HistoryRecorder.hook = previous }

        HookPayload.log.keys.removeAll()
        let reader = hookReader
        reader.interval = interval
        return reader
    }

    /// Where the hook's own lane ended up. Not zero in general: the host app's
    /// readers register lanes of their own in whatever order they tick.
    private func hookLane(_ archive: HistoryArchive) -> Int? {
        (0..<archive.laneCount).first { archive.entry(lane: $0)?.label == HookPayload.label }
    }

    // MARK: - recorder fixtures

    /// A payload that behaves like a module's `HistoryProvider` conformance:
    /// one lane resolved through the registry per tick, then one scalar.
    private struct Probe: HistoryProvider {
        static let label = "probe lane"
        static let reader = HistoryReaderKey(module: .CPU, name: "probe")

        let source: String
        let value: Double

        static func payload(_ value: Double, source: String = "") -> Probe {
            Probe(source: source, value: value)
        }

        func emitHistory(reader: HistoryReaderKey, into sink: inout HistorySink) {
            let descriptor = HistoryLaneDescriptor(
                key: HistoryLaneKey(module: .cpu, source: self.source, metric: "total"),
                unit: .percent, kind: .gauge, label: Probe.label
            )
            guard let lane = sink.lane(for: descriptor) else { return }
            sink.emit(lane: lane, value: self.value)
        }
    }

    /// A whole recorder pointed at a temporary directory, with a clock, a free
    /// space figure and a power state the test drives.
    private final class RecorderProbe {
        let store: HistoryStore
        let recorder: HistoryRecorder
        /// The wall clock the recorder reads. Mutated only from the test thread.
        var now: TimeInterval
        /// How far the continuous clock sits from the wall clock. Zero until a
        /// test sets the wall clock, which is the only thing that moves them
        /// apart — `mach_continuous_time` counts through sleep, so sleeping is
        /// not one of those things (§4).
        var monotonicOffset: TimeInterval = 0
        var monotonic: TimeInterval { self.now + self.monotonicOffset }
        var freeSpace: Int64?
        var isPowerConstrained = false
        let start: TimeInterval

        init(directory: URL, preset: HistoryRetentionPreset, now: TimeInterval) {
            self.now = now
            self.start = now
            self.freeSpace = HistoryStore.freeSpaceFloor * 100
            self.store = HistoryStore(directory: directory)

            // Boxed so the closures below do not capture a half-built `self`.
            let box = Box()
            self.recorder = HistoryRecorder(store: self.store, preset: preset,
                                            environment: HistoryRecorder.Environment(
                now: { box.probe?.now ?? now },
                availableSpace: { _ in box.probe?.freeSpace },
                isPowerConstrained: { box.probe?.isPowerConstrained ?? false },
                monotonicNow: { box.probe?.monotonic ?? now }
            ))
            box.probe = self
        }

        /// Ordinary time passing: both clocks move together.
        func advance(_ seconds: TimeInterval) {
            self.now += seconds
        }

        /// The wall clock being set, forwards or backwards, with the continuous
        /// clock staying exactly where it was. That difference is the whole of
        /// what §4 calls a clock step.
        func stepClock(by seconds: TimeInterval) {
            self.now += seconds
            self.monotonicOffset -= seconds
        }

        /// One reader tick followed by the commit cycle that closes its bucket,
        /// which is the shape every recorder test needs: a bucket the commit
        /// thread has not seen close yet is still open and writes nothing.
        func ingest(_ value: Double) {
            self.recorder.ingest(Probe.payload(value), reader: Probe.reader, interval: 1)
            self.advance(HistoryRecorder.commitInterval)
            self.recorder.commitNow()
        }

        /// Weak-by-construction indirection: the recorder outlives the closures'
        /// need for the probe only inside this class's own lifetime.
        final class Box {
            weak var probe: RecorderProbe?
        }
    }

    /// A started recorder on a fresh directory. The clock starts five seconds
    /// into a bucket so that a one-second interval's span attribution stays
    /// inside it and the assertions can name single buckets.
    ///
    /// `enabled:` is passed explicitly, and every other `start` in this file
    /// does the same. Its default argument is the stored master switch, and the
    /// Tests target is hosted by Stats.app, so `Store` reads the *installed*
    /// app's real preferences: a developer who turns the switch off in Stats
    /// would otherwise find the whole suite red with no code change.
    private func probe(directory: URL? = nil, preset: HistoryRetentionPreset = .standard,
                      now: TimeInterval? = nil) throws -> RecorderProbe {
        let directory = directory ?? self.folder.appendingPathComponent("history")
        let aligned = (1_760_000_000 / TimeInterval(HistoryTier.t2.step)).rounded(.down)
            * TimeInterval(HistoryTier.t2.step) + 5
        let probe = RecorderProbe(directory: directory, preset: preset, now: now ?? aligned)
        probe.recorder.start(enabled: true)
        probe.recorder.waitUntilIdle()
        return probe
    }

    // MARK: - column plan and the read-side query
    //
    // Range to tier and to drawn columns; the count-weighted resampling the
    // slot's `sum` + `count` exists for; and the gap columns the chart hatches
    // instead of interpolating across.

    /// §3 fixes the column counts — 360 at 10 s for 1 h, 720 at 30 s for 6 h,
    /// 720 at 2 min for 24 h, 504 at 20 min for 7 d, 1,440 at 30 min for 30 d,
    /// 1,460 at 6 h for 1 y — and the reason: a column that is a whole number
    /// of buckets wide keeps the min/max envelope from stuttering at exactly
    /// the ranges users stare at. Both halves are asserted, for every range.
    func testEachRangeReadsFromTheTierAndColumnCountTheDesignStates() throws {
        let now: TimeInterval = 1_700_000_000
        let expected: [(range: HistoryRange, tier: HistoryTier, columns: Int, seconds: Int)] = [
            (.hour, .t0, 360, 10),
            (.sixHours, .t0, 720, 30),
            (.day, .t1, 720, 120),
            (.week, .t1, 504, 1_200),
            (.month, .t2, 1_440, 1_800),
            (.year, .t2, 1_460, 21_600)
        ]

        for row in expected {
            let plan = HistoryColumnPlan.plan(for: row.range, endingAt: now)
            XCTAssertEqual(plan.tier, row.tier, "\(row.range)")
            XCTAssertEqual(plan.columns, row.columns, "\(row.range)")
            XCTAssertEqual(plan.columnSeconds, row.seconds, "\(row.range)")

            // The coarsest tier is finer than one column, every column is a
            // whole number of buckets, and the columns cover the range exactly.
            XCTAssertLessThanOrEqual(plan.tier.step, plan.columnSeconds, "\(row.range)")
            XCTAssertEqual(plan.buckets.count % plan.bucketsPerColumn, 0, "\(row.range)")
            XCTAssertEqual(plan.columns * plan.columnSeconds, row.range.seconds, "\(row.range)")
            // And the tier retains every bucket the range asks it for.
            XCTAssertLessThanOrEqual(plan.buckets.count, plan.tier.buckets, "\(row.range)")
            XCTAssertEqual(plan.retainedColumns, plan.columns, "\(row.range)")

            // Time-indexed: a column's position is its timestamp.
            XCTAssertEqual(plan.columnStart(0), plan.start, "\(row.range)")
            XCTAssertEqual(plan.column(at: plan.start), 0, "\(row.range)")
            XCTAssertEqual(plan.column(at: plan.end - 1), plan.columns - 1, "\(row.range)")
            XCTAssertNil(plan.column(at: plan.end), "\(row.range)")
        }
    }

    /// A column narrower than a pixel is work nobody can see, so the chart's
    /// width caps the count — by widening the column a whole factor, never a
    /// fraction, so it stays a whole number of buckets.
    func testANarrowChartWidensTheColumnByAWholeNumberOfBuckets() throws {
        let now: TimeInterval = 1_700_000_000

        let narrow = HistoryColumnPlan.plan(for: .month, endingAt: now, maxColumns: 400)
        XCTAssertEqual(narrow.tier, .t2)
        XCTAssertEqual(narrow.bucketsPerColumn, 4)
        XCTAssertEqual(narrow.columns, 360)
        XCTAssertLessThanOrEqual(narrow.columns, 400)
        XCTAssertEqual(narrow.buckets.count % narrow.bucketsPerColumn, 0)
        XCTAssertEqual(narrow.columns * narrow.columnSeconds, HistoryRange.month.seconds)

        // The degenerate width still produces a plan rather than a division by
        // zero: one column holding the whole range.
        let sliver = HistoryColumnPlan.plan(for: .month, endingAt: now, maxColumns: 1)
        XCTAssertEqual(sliver.columns, 1)
        XCTAssertEqual(sliver.columnSeconds, HistoryRange.month.seconds)
    }

    /// The Minimal preset has only T0 open. A day still reads — twelve 10 s
    /// buckets per 2-minute column — and a month reads what T0's ring can still
    /// hold, saying so rather than striding a quarter of a million cells to
    /// discover that the rest is gone.
    func testTheMinimalPresetFallsBackToT0AndSaysWhatItCannotHold() throws {
        let now: TimeInterval = 1_700_000_000

        let day = HistoryColumnPlan.plan(for: .day, endingAt: now, tiers: [.t0])
        XCTAssertEqual(day.tier, .t0)
        XCTAssertEqual(day.bucketsPerColumn, 12)
        XCTAssertEqual(day.columns, 720)
        XCTAssertEqual(day.retainedColumns, 720)

        let month = HistoryColumnPlan.plan(for: .month, endingAt: now, tiers: [.t0])
        XCTAssertEqual(month.tier, .t0)
        XCTAssertEqual(month.bucketsPerColumn, 180)
        XCTAssertEqual(month.columns, 1_440)
        // 24 h of a 30-day range: 8,640 T0 buckets, 48 columns, ending where
        // the range ends.
        XCTAssertEqual(month.retainedColumns, 48)
        XCTAssertEqual(month.retainedBuckets.count, HistoryTier.t0.buckets)
        XCTAssertEqual(month.retainedBuckets.upperBound, month.buckets.upperBound)
    }

    /// Count-weighted, like the rollup and for the same reason: bucket
    /// population is not constant, so one sample at 100 must not outvote nine
    /// at 10. A held bucket keeps its own reason so the chart can dash it.
    func testColumnsAreCountWeightedAndKeepHeldSpansApart() throws {
        let first: UInt32 = 1_000
        let slots: [HistorySlot?] = [
            HistorySlot(bucket: first, count: 1, reason: .measured, min: 100, max: 100, sum: 100),
            HistorySlot(bucket: first + 1, count: 9, reason: .measured, min: 10, max: 10, sum: 90),
            nil,
            nil,
            HistorySlot(bucket: first + 4, count: 1, reason: .held, min: 50, max: 50, sum: 50),
            nil
        ]
        let resolver = HistoryGapResolver(step: HistoryTier.t0.step, firstValidBucket: first,
                                          lastCommitBucket: first + 5, spans: [])

        let columns = HistoryAggregate.columns(slots, from: first, bucketsPerColumn: 2, resolver: resolver)
        XCTAssertEqual(columns.count, 3)

        let measured = try XCTUnwrap(columns[0])
        XCTAssertEqual(measured.avg, 19)
        XCTAssertEqual(measured.min, 10)
        XCTAssertEqual(measured.max, 100)
        XCTAssertEqual(measured.count, 10)
        XCTAssertEqual(measured.reason, .measured)

        // Nothing at all to say: not a measured zero, and not a hatch either.
        XCTAssertNil(columns[1])

        let held = try XCTUnwrap(columns[2])
        XCTAssertEqual(held.reason, .held)
        XCTAssertEqual(held.avg, 50)
        XCTAssertEqual(held.count, 1)

        // A trailing partial column is not drawn: the plan always hands over a
        // whole number of columns, and half a column of buckets would be a
        // column an eleventh as wide as its neighbours.
        XCTAssertEqual(HistoryAggregate.columns(slots, from: first, bucketsPerColumn: 4,
                                                resolver: resolver).count, 1)
        XCTAssertEqual(HistoryAggregate.columns([], from: first, bucketsPerColumn: 2, resolver: nil).count, 0)
    }

    /// A gap column carries the reason and no value. That is what the chart
    /// hatches at 45° and the readout turns into "Asleep 02:14-08:31"; a value
    /// interpolated across it would be the one thing §4 forbids.
    func testGapColumnsCarryTheirReasonAndNeverAValue() throws {
        let step = HistoryTier.t0.step
        let first: UInt32 = 1_000
        let slots: [HistorySlot?] = [
            HistorySlot(bucket: first, count: 4, reason: .measured, min: 1, max: 9, sum: 20),
            HistorySlot(bucket: first + 1, count: 4, reason: .measured, min: 2, max: 8, sum: 20),
            nil, nil,   // asleep
            nil, nil,   // running, but nothing recorded
            nil, nil    // past the last commit
        ]
        let asleep = HistoryGapSpan(from: UInt64(first + 2) * UInt64(step),
                                    to: UInt64(first + 4) * UInt64(step), reason: .asleep)
        let resolver = HistoryGapResolver(step: step, firstValidBucket: first,
                                          lastCommitBucket: first + 5, spans: [asleep])

        let columns = HistoryAggregate.columns(slots, from: first, bucketsPerColumn: 2, resolver: resolver)
        XCTAssertEqual(columns.count, 4)

        let data = try XCTUnwrap(columns[0])
        XCTAssertEqual(data.min, 1)
        XCTAssertEqual(data.max, 9)
        XCTAssertEqual(data.count, 8)

        let sleeping = try XCTUnwrap(columns[1])
        XCTAssertEqual(sleeping.reason, .asleep)
        XCTAssertEqual(sleeping.count, 0)
        XCTAssertEqual(sleeping.min, 0)
        XCTAssertEqual(sleeping.max, 0)

        // Running and recording, with nothing to show for those twenty seconds:
        // §2 collapses a disabled module, a paused app and a reader that
        // stopped answering to no-data rather than guessing between them.
        XCTAssertNil(columns[2])

        let down = try XCTUnwrap(columns[3])
        XCTAssertEqual(down.reason, .notRunning)
        XCTAssertEqual(down.count, 0)

        // Before the lane existed, no span makes the emptiness more specific.
        let fresh = HistoryGapResolver(step: step, firstValidBucket: HistoryLaneEntry.noValidBucket,
                                       lastCommitBucket: first + 5, spans: [asleep])
        let nothing = HistoryAggregate.columns([HistorySlot?](repeating: nil, count: 8), from: first,
                                               bucketsPerColumn: 2, resolver: fresh)
        XCTAssertEqual(nothing.compactMap { $0 }.count, 0)
    }

    /// The read path end to end: a plan, a mapped tier file and the columns the
    /// chart is handed — never the decoded series (§7).
    func testTheStoreReadsARangeAsColumns() throws {
        let now: TimeInterval = 1_700_000_000
        let store = HistoryStore(directory: self.folder)
        defer { store.closeAll() }
        _ = try store.open(preset: .standard)

        let archive = try XCTUnwrap(store.archive(.t0))
        try archive.setDirectory(Self.entries(2))

        let plan = HistoryColumnPlan.plan(for: .hour, endingAt: now)
        XCTAssertEqual(plan.columns, 360)

        // The last ten buckets of the range, one column each.
        let firstWritten = plan.buckets.upperBound - 10
        try archive.commit((0..<10).map { Self.row(firstWritten + UInt32($0), lanes: 2, base: Float($0)) })

        let lane = try XCTUnwrap(store.columns(lane: 0, plan: plan, spans: []))
        XCTAssertEqual(lane.lane, 0)
        XCTAssertEqual(lane.entry.label, "lane 0")
        XCTAssertEqual(lane.columns.count, plan.columns)
        XCTAssertEqual(lane.columns.compactMap { $0 }.count, 10)
        XCTAssertNil(lane.columns[0])
        XCTAssertEqual(lane.columns[plan.columns - 10]?.avg, 0)
        XCTAssertEqual(lane.columns[plan.columns - 1]?.avg, 9)

        let summary = try XCTUnwrap(lane.summary)
        XCTAssertEqual(summary.min, 0)
        XCTAssertEqual(summary.max, 9)
        XCTAssertEqual(summary.count, 10)

        // The second lane is its own series, offset by one, and a lane the
        // directory does not hold is not invented.
        let second = try XCTUnwrap(store.columns(lane: 1, plan: plan, spans: []))
        XCTAssertEqual(second.summary?.max, 10)
        XCTAssertNil(store.columns(lane: 7, plan: plan, spans: []))

        let result = store.query(lanes: [0, 1, 7], plan: plan, spans: [])
        XCTAssertEqual(result.lanes.count, 2)
        XCTAssertEqual(result.plan, plan)
    }

    /// Every unit reads the way its module reads, and none of them trap on a
    /// value the read path is willing to hand them.
    ///
    /// `Int(_: Double)` is a trap rather than an exception, a `Float` reaches
    /// 3.4e38 and `Int.max` is 9.2e18, so `isFinite` alone is not a guard.
    /// Nothing upstream narrows it either: a slot is validated by its 4-byte
    /// bucket stamp, which says nothing about the value behind it, and
    /// `HistoryAggregate.rollup` checks `isFinite` and no magnitude. 2,000 rpm
    /// is `0x44FA0000`; flipping the top exponent bit makes it a finite
    /// 1.04e37, which the archive accepts and the axis then has to label — the
    /// same input class the bit-flip fuzz loop asserts no trap for.
    func testEveryUnitFormatsAHugeFiniteValueWithoutTrapping() throws {
        let flipped = Float(bitPattern: 0x7CFA_0000)
        XCTAssertTrue(flipped.isFinite)

        let units: [HistoryLaneUnit] = [.percent, .bytesPerSec, .bytes, .celsius, .watts, .volts, .rpm]
        for unit in units {
            for value: Float in [flipped, -flipped, .greatestFiniteMagnitude, -.greatestFiniteMagnitude] {
                XCTAssertFalse(unit.format(value).isEmpty, "\(unit) \(value)")
            }
            XCTAssertEqual(unit.format(.nan), "—", "\(unit)")
            XCTAssertEqual(unit.format(.infinity), "—", "\(unit)")
        }

        // Percent lanes store a fraction of 1 and are scaled in the formatter
        // and only there; the three sensor units follow `Sensor_p`.
        XCTAssertEqual(HistoryLaneUnit.percent.format(0.2), "20%")
        XCTAssertEqual(HistoryLaneUnit.rpm.format(2_000), "2000 RPM")
        XCTAssertEqual(HistoryLaneUnit.watts.format(12.5), "12.50 W")
        XCTAssertEqual(HistoryLaneUnit.watts.format(120), "120 W")
        XCTAssertEqual(HistoryLaneUnit.volts.format(11.25), "11.250 V")
    }

    // MARK: - CSV export
    //
    // The file is a public contract (§5): fixed English header tokens, one row
    // per drawn column, values in the unit they were recorded in with a "."
    // decimal separator whatever the app runs in, and a gap column that keeps a
    // held or missing sample from reading as a measured one. Every assertion
    // below is on the exact text, because "the format changed" is not
    // something a user's script finds out gently.

    /// `timestamp`, three cells per lane naming the lane, the statistic and the
    /// stored unit, then `gap`.
    func testTheHeaderLineNamesEveryLaneItsStatisticAndItsUnit() throws {
        let lanes = [
            Self.laneColumns("CPU total", unit: .percent, [nil]),
            Self.laneColumns("Wi-Fi (en0) download", unit: .bytesPerSec, [nil], lane: 1)
        ]

        XCTAssertEqual(HistoryCSVExporter().header(for: lanes), """
        timestamp,CPU total min (%),CPU total avg (%),CPU total max (%),\
        Wi-Fi (en0) download min (B/s),Wi-Fi (en0) download avg (B/s),Wi-Fi (en0) download max (B/s),gap
        """)

        // No lane checked is still a well-formed file rather than a bare
        // timestamp column.
        XCTAssertEqual(HistoryCSVExporter().header(for: []), "timestamp,gap")
    }

    /// A measured row: the column's start in ISO 8601 with a numeric offset,
    /// min/avg/max per lane in the unit the lane was recorded in, and an empty
    /// gap cell.
    func testAMeasuredRowCarriesMinAvgMaxInTheStoredUnit() throws {
        let lanes = [
            Self.laneColumns("CPU total", unit: .percent, [Self.measured(0.105, 0.2, 0.81)]),
            Self.laneColumns("CPU die", unit: .celsius, [Self.measured(41, 45.5, 52.25)], lane: 1)
        ]

        // Percent is stored as a fraction of 1 and exported as 0–100; °C is
        // exported as °C whatever the app displays, because a file whose
        // numbers change meaning with a display setting is not a contract.
        XCTAssertEqual(Self.exporter(offset: 2 * 3_600).row(0, plan: Self.csvPlan(columns: 1), lanes: lanes),
                       "2023-11-15T00:13:20+02:00,10.50,20.00,81.00,41.00,45.50,52.25,")
    }

    /// One gap reason per row, and no values with it: a hatched column has
    /// nothing to say about the series, and a zero there would be the one
    /// mistake the whole feature exists to avoid.
    func testEveryGapReasonHasItsOwnTokenAndNoValues() throws {
        let plan = Self.csvPlan(columns: 1)
        let exporter = Self.exporter()
        let stamp = "2023-11-14T22:13:20+00:00"

        let reasons: [(HistoryGapReason, String)] = [
            (.asleep, "asleep"), (.notRunning, "not_running"),
            (.clockStep, "clock_step"), (.nodata, "no_data")
        ]
        for (reason, token) in reasons {
            let lanes = [Self.laneColumns("CPU total", unit: .percent, [Self.gap(reason)])]
            XCTAssertEqual(exporter.row(0, plan: plan, lanes: lanes), "\(stamp),,,,\(token)", token)
        }

        // A lane the read had nothing at all for is the same three empty cells,
        // and the row says so.
        let missing = [Self.laneColumns("CPU total", unit: .percent, [nil])]
        XCTAssertEqual(exporter.row(0, plan: plan, lanes: missing), "\(stamp),,,,no_data")

        // A lane that ran out of columns — a plan wider than the answer — is
        // the same, rather than an index out of range.
        XCTAssertEqual(exporter.row(3, plan: Self.csvPlan(columns: 4), lanes: missing),
                       "2023-11-14T22:14:20+00:00,,,,no_data")
    }

    /// A held bucket keeps its value: a step lane holds its last level for a
    /// bounded window and that level is real. The token is what stops it
    /// reading as a fresh measurement (§2).
    func testAHeldRowKeepsItsValueAndSaysItIsHeld() throws {
        let plan = Self.csvPlan(columns: 1)
        let exporter = Self.exporter()
        let battery = Self.laneColumns("Battery level", unit: .percent, [Self.held(0.42)])

        XCTAssertEqual(exporter.row(0, plan: plan, lanes: [battery]),
                       "2023-11-14T22:13:20+00:00,42.00,42.00,42.00,held")

        // Held outranks a gap — the row has a value — and a measured lane
        // outranks held, because one cell describes the whole row and a row
        // something was measured in is a measured row.
        let asleep = Self.laneColumns("CPU total", unit: .percent, [Self.gap(.asleep)], lane: 1)
        XCTAssertEqual(exporter.row(0, plan: plan, lanes: [asleep, battery]),
                       "2023-11-14T22:13:20+00:00,,,,42.00,42.00,42.00,held")

        let cpu = Self.laneColumns("CPU total", unit: .percent, [Self.measured(0.1, 0.1, 0.1)], lane: 1)
        XCTAssertEqual(exporter.row(0, plan: plan, lanes: [battery, cpu]),
                       "2023-11-14T22:13:20+00:00,42.00,42.00,42.00,10.00,10.00,10.00,")
    }

    /// RFC 4180: a cell holding a comma, a quote or a line break is wrapped in
    /// quotes with its own quotes doubled. Lane labels are volume and sensor
    /// names the user or the vendor chose, so this is reachable and not theory.
    func testCellsThatCouldSplitARowAreQuoted() throws {
        XCTAssertEqual(HistoryCSVExporter.quoted("CPU die"), "CPU die")
        XCTAssertEqual(HistoryCSVExporter.quoted("Macintosh HD, backup"), "\"Macintosh HD, backup\"")
        XCTAssertEqual(HistoryCSVExporter.quoted("Tim\"s disk"), "\"Tim\"\"s disk\"")
        XCTAssertEqual(HistoryCSVExporter.quoted("two\nlines"), "\"two\nlines\"")
        // A CRLF inside a cell is one Swift grapheme cluster, so neither
        // `contains("\r")` nor `contains("\n")` sees it: the cell that would
        // end the row early is the one the obvious check waves through.
        XCTAssertEqual(HistoryCSVExporter.quoted("two\r\nlines"), "\"two\r\nlines\"")

        // And the header line is where a label reaches the file.
        let lanes = [Self.laneColumns("Volume, \"spare\"", unit: .bytes, [nil])]
        XCTAssertEqual(HistoryCSVExporter().header(for: lanes), """
        timestamp,"Volume, ""spare"" min (B)","Volume, ""spare"" avg (B)","Volume, ""spare"" max (B)",gap
        """)
    }

    /// The file is written in the C locale whatever the app runs in — and the
    /// hazard is not hypothetical: `en_IN`'s decimal separator is already ".",
    /// and it still writes 12,345.50, which is one value in two cells. The
    /// timestamp has the same problem one level down: a fixed `dateFormat` is
    /// not enough, because the locale still picks the calendar and the digits.
    func testTheFileReadsInDotsAndGregorianYearsWhateverTheAppRunsIn() throws {
        let plan = Self.csvPlan(columns: 1)
        let lanes = [Self.laneColumns("Macintosh HD free", unit: .bytes,
                                      [Self.measured(12_345.5, 12_345.5, 12_345.5)])]

        for identifier in ["de_DE", "fr_CA", "ar_SA", "th_TH", "ne_NP", "en_IN"] {
            let exporter = HistoryCSVExporter(locale: Locale(identifier: identifier),
                                              timeZone: TimeZone(secondsFromGMT: 0)!)
            XCTAssertEqual(exporter.row(0, plan: plan, lanes: lanes),
                           "2023-11-14T22:13:20+00:00,12345.50,12345.50,12345.50,", identifier)
        }

        // What those locales do to the same number when they are allowed to
        // reach the formatter, so that the pin above is not folklore.
        XCTAssertEqual(String(format: "%.2f", locale: Locale(identifier: "de_DE"), 12_345.5), "12.345,50")
        XCTAssertEqual(String(format: "%.2f", locale: Locale(identifier: "en_IN"), 12_345.5), "12,345.50")
    }

    /// The whole file: a header line, one row per drawn column in time order,
    /// CRLF line endings and a trailing one.
    func testTheDocumentIsAHeaderLineAndOneRowPerColumn() throws {
        let plan = Self.csvPlan(columns: 3)
        let lanes = [Self.laneColumns("CPU total", unit: .percent,
                                      [Self.measured(0.1, 0.1, 0.1), nil, Self.gap(.asleep)])]
        let exporter = Self.exporter()

        let document = exporter.document(HistoryQueryResult(plan: plan, lanes: lanes))
        XCTAssertTrue(document.hasSuffix("\r\n"))

        let lines = document.components(separatedBy: "\r\n").dropLast()
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines.first, exporter.header(for: lanes))

        // Time-indexed: a row's position is its timestamp, one column width
        // apart, and a column with nothing in it is empty rather than absent.
        XCTAssertEqual(Array(lines)[1], "2023-11-14T22:13:20+00:00,10.00,10.00,10.00,")
        XCTAssertEqual(Array(lines)[2], "2023-11-14T22:13:40+00:00,,,,no_data")
        XCTAssertEqual(Array(lines)[3], "2023-11-14T22:14:00+00:00,,,,asleep")
    }

    /// A value the read path is willing to hand the exporter but no parser
    /// could use: an empty cell, like any other column with nothing in it.
    func testANonFiniteValueExportsAsAnEmptyCell() throws {
        let exporter = Self.exporter()
        XCTAssertEqual(exporter.value(.nan, unit: .watts), "")
        XCTAssertEqual(exporter.value(.infinity, unit: .percent), "")
        XCTAssertEqual(exporter.value(2_000, unit: .rpm), "2000.00")
        XCTAssertEqual(exporter.value(-0.5, unit: .watts), "-0.50")
    }

    // MARK: - CSV fixtures

    /// A fixed offset, so that a row's timestamp is an assertion and not a
    /// function of where the machine running the tests is.
    private static func exporter(offset: Int = 0) -> HistoryCSVExporter {
        HistoryCSVExporter(locale: Locale(identifier: "en_US_POSIX"),
                           timeZone: TimeZone(secondsFromGMT: offset)!)
    }

    /// T0 buckets from 1,700,000,000, two to a column: 20 s columns starting at
    /// 2023-11-14T22:13:20Z.
    private static func csvPlan(columns: Int) -> HistoryColumnPlan {
        let first: UInt32 = 170_000_000
        return HistoryColumnPlan(range: .hour, tier: .t0,
                                 buckets: first..<(first + UInt32(columns * 2)), bucketsPerColumn: 2)
    }

    private static func laneColumns(_ label: String, unit: HistoryLaneUnit,
                                    _ columns: [HistoryColumn?], lane: Int = 0) -> HistoryLaneColumns {
        HistoryLaneColumns(
            lane: lane,
            entry: HistoryLaneEntry(identity: HistoryLaneIdentity(high: 0, low: UInt64(lane)),
                                    module: .cpu, unit: unit, kind: .gauge, label: label),
            columns: columns
        )
    }

    private static func measured(_ min: Float, _ avg: Float, _ max: Float) -> HistoryColumn {
        HistoryColumn(min: min, max: max, avg: avg, count: 12, reason: .measured)
    }

    private static func held(_ value: Float) -> HistoryColumn {
        HistoryColumn(min: value, max: value, avg: value, count: 1, reason: .held)
    }

    /// What the read path produces for a column it could name a reason for:
    /// no samples, so no values.
    private static func gap(_ reason: HistoryGapReason) -> HistoryColumn {
        HistoryColumn(min: 0, max: 0, avg: 0, count: 0, reason: reason)
    }

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

    /// The two in-memory widths the budget in §7 is made of: 64 B per lane of
    /// accumulator (~16 KiB at the cap) and 16 B per drawn column (≤1,440
    /// columns per visible lane).
    func testInMemoryGeometryMatchesTheBudget() throws {
        XCTAssertLessThanOrEqual(MemoryLayout<HistoryAccumulator>.stride, 64)
        XCTAssertLessThanOrEqual(MemoryLayout<HistoryColumn>.stride, 16)
        XCTAssertEqual(HistoryLaneDirectory.laneCap, 256)
        XCTAssertEqual(HistoryAccumulator.holdWindow, 15 * 60)
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

// MARK: - Reader.callback hook fixtures
//
// At file scope, and not nested in the test case, because `Reader.name` is
// `NSStringFromClass` split on "." — which demangles to "Module.Class" only for
// a top-level class. A nested one reports `_TtCC5Tests12HistoryTests10HookReader`
// and the identity the hook passes would be unreadable rather than wrong, which
// is worse: it would still be a stable key and nothing would fail.

/// A payload with a module conformance's shape on a type a `Reader` can carry —
/// `Reader<T>` needs `Codable`, which the real payloads all are.
struct HookPayload: Codable, HistoryProvider {
    static let label = "hook lane"

    /// What the hook handed the recorder. Written from the thread that drove
    /// `Reader.callback` — the test's own, since `ingest` folds synchronously —
    /// and read after that call returns. The app's own readers go through other
    /// payload types, so they never reach this.
    final class Log {
        var keys: [HistoryReaderKey] = []
    }
    static let log = Log()

    let value: Double

    func emitHistory(reader: HistoryReaderKey, into sink: inout HistorySink) {
        HookPayload.log.keys.append(reader)
        let descriptor = HistoryLaneDescriptor(
            key: HistoryLaneKey(module: .cpu, source: "hook", metric: "total"),
            unit: .percent, kind: .gauge, label: HookPayload.label
        )
        guard let lane = sink.lane(for: descriptor) else { return }
        sink.emit(lane: lane, value: self.value)
    }
}

/// A real `Reader`, so that `callback` is the upstream one and not a copy of it
/// that could drift. The class name is what the hook passes as the reader
/// identity, so it is asserted rather than assumed.
final class HookReader: Reader<HookPayload> {}

/// Kept for the life of the test process on purpose: `Reader.deinit` writes its
/// last value into the app's LevelDB, and a unit test has no business leaving a
/// key behind in the user's own `~/Library/Application Support/Stats`.
let hookReader = HookReader(.CPU)
