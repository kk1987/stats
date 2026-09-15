//
//  HistoryClockTests.swift
//  Tests
//
//  Persistent usage history: sleep and wake, clock steps forward and back, the
//  gap-span sidecar and the order gap reasons are derived in.
//  Fixtures in `HistoryTestSupport.swift`.
//  Design: docs/usage-history-design.md (§4, §10), exelban/stats#1194.
//

import XCTest
import Kit

final class HistoryClockTests: HistoryTestCase {

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

        // And the new era records again the moment it is past the
        // high-water mark: the rule drops rows, it does not stop recording.
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
}
