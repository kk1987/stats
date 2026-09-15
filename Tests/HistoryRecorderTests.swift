//
//  HistoryRecorderTests.swift
//  Tests
//
//  Persistent usage history: the recorder — the commit cycle, coarse-tier
//  catch-up, write failures, retention presets, the settings surface and the
//  `Reader.callback` hook. Fixtures in `HistoryTestSupport.swift`.
//  Design: docs/usage-history-design.md (§3, §6, §10), exelban/stats#1194.
//

import XCTest
import Kit

final class HistoryRecorderTests: HistoryTestCase {

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
    func testTheRecordingSwitchOffStopsTheHookBeforeExtraction() throws {
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
}
