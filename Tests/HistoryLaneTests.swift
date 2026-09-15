//
//  HistoryLaneTests.swift
//  Tests
//
//  Persistent usage history: lane identity and the registry, the directory,
//  the bucket accumulators, the step-lane hold and the rollup and resampling
//  that read out of them. Fixtures in `HistoryTestSupport.swift`.
//  Design: docs/usage-history-design.md (§2, §3, §10), exelban/stats#1194.
//

import XCTest
import Kit

final class HistoryLaneTests: HistoryTestCase {

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
}
