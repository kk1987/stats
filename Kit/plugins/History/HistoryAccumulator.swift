//
//  HistoryAccumulator.swift
//  Kit
//
//  Persistent usage history: the typed extraction protocol and the in-memory
//  bucket accumulators the commit thread drains.
//  Design: docs/usage-history-design.md (§2 Sampling), exelban/stats#1194.
//

import Foundation
import os

// MARK: - reader identity

/// Identifies the reader a sample came from. Passed explicitly, never inferred
/// from the payload type: `CapacityReader`, `ActivityReader` and `SMARTReader`
/// are all `Reader<Disks>` with partially filled instances (§2).
public struct HistoryReaderKey: Hashable {
    public let module: ModuleType
    public let name: String

    public init(module: ModuleType, name: String) {
        self.module = module
        self.name = name
    }
}

// MARK: - extraction

/// The pre-sized buffer a payload writes its scalars into. Lanes resolve to
/// integer ids at registration, so the hot path allocates nothing.
///
/// One sink is owned by the recorder and handed to `emitHistory` as `inout`, so
/// a tick appends into storage that is already there: `prepare` keeps the
/// capacity and only resets the count. Values are collected here and folded in
/// one pass afterwards, which is what keeps the accumulator lock to a single
/// acquisition per tick rather than one per lane.
public struct HistorySink {
    /// One scalar, already resolved to its integer lane.
    public struct Sample {
        public let lane: Int32
        public let value: Double
    }

    public private(set) var samples: [Sample] = []
    /// Wall clock of the tick, in whole seconds: what a lane registered during
    /// this tick stamps its `lastUsedTs` with.
    public private(set) var timestamp: UInt64 = 0

    /// Strong on purpose. `inout` passing neither copies nor retains, so this
    /// costs one retain per tick rather than one per sample.
    ///
    /// The recorder owns the sink and hands it a registry it also owns, so when
    /// the recorder *is* the registry this is a retain cycle — an intentional
    /// one: `HistoryRecorder` is a process singleton that is never torn down,
    /// and the alternative, an `unowned` reference, would trade a leak that
    /// cannot happen for a trap that could. Anything that is not that singleton
    /// has to outlive the sink by construction.
    private var registry: HistoryLaneRegistry?

    public init(capacity: Int = HistoryLaneDirectory.laneCap) {
        self.samples.reserveCapacity(capacity)
    }

    public var isEmpty: Bool { self.samples.isEmpty }
    public var count: Int { self.samples.count }

    /// Readies the sink for one tick. Capacity is kept: the whole point of a
    /// sink the recorder owns is that steady state allocates nothing.
    public mutating func prepare(registry: HistoryLaneRegistry?, at timestamp: UInt64) {
        self.samples.removeAll(keepingCapacity: true)
        self.registry = registry
        self.timestamp = timestamp
    }

    // MARK: - emit (integer lane, non-finite rejected before it can be folded)

    /// The hot path: an integer lane the caller resolved once and cached.
    ///
    /// Non-finite values are dropped here as well as at the fold. NaN must
    /// never reach min/max, where every comparison against it silently fails
    /// (§2), and a sample that cannot be folded is not worth carrying to the
    /// lock either.
    public mutating func emit(lane: Int32, value: Double) {
        guard lane >= 0, value.isFinite else { return }
        self.samples.append(Sample(lane: lane, value: value))
    }

    // MARK: - lane resolution (key -> integer id, first sight only)

    /// Resolves a descriptor to the integer lane id to cache and pass to
    /// `emit`, registering the lane on first sight. `nil` means the lane cannot
    /// be recorded — the cap is reached and every lane in the directory is
    /// still warm — and the caller stops asking for this tick.
    ///
    /// Hashes a string and may touch the directory, so module code calls it
    /// once per lane and keeps the id, never once per sample.
    public mutating func lane(for descriptor: HistoryLaneDescriptor) -> Int32? {
        guard let registry = self.registry,
              let lane = registry.lane(for: descriptor, at: self.timestamp) else { return nil }
        return Int32(lane)
    }
}

/// Typed extraction, implemented by the payload types in the module targets.
/// Kit cannot import the module targets, so the conformances cannot live here;
/// a rename upstream therefore fails to compile instead of dying silently (§2).
public protocol HistoryProvider {
    func emitHistory(reader: HistoryReaderKey, into sink: inout HistorySink)
}

// MARK: - accumulator

/// Per-lane fold state for the bucket currently open. Snapshotted and reset
/// under the lock by the commit thread, which then writes with it released.
///
/// Fits in 64 B per lane, which is what the idle memory budget is made of:
/// ~16 KiB of accumulators at the 256-lane cap (§7).
public struct HistoryAccumulator {
    /// How long a step lane keeps its last value after the source goes quiet.
    /// Bounded by the event source: Battery's IOPS notification fires on every
    /// 1 % change, on plug/unplug and on sleep/wake, so a genuine 15-minute
    /// silence means the level genuinely did not move (§2).
    public static let holdWindow: TimeInterval = 15 * 60

    public private(set) var bucket: UInt32 = 0
    /// Whether `bucket` is a real open bucket rather than the zero default.
    public private(set) var isOpen: Bool = false
    public private(set) var count: UInt16 = 0
    public private(set) var min: Float = 0
    public private(set) var max: Float = 0
    public private(set) var sum: Float = 0

    /// Set at registration and not changed afterwards: it decides whether a
    /// sample is a rate to convert and whether the lane holds between samples.
    public private(set) var kind: HistoryLaneKind = .gauge

    /// Step lanes only (battery `level`): the value to hold and how long for.
    /// `lastSampleTs` is kept for every kind — a rate divides by the time since
    /// it (§2).
    public private(set) var lastValue: Float = 0
    public private(set) var lastSampleTs: TimeInterval = 0
    public private(set) var holdUntil: TimeInterval = 0

    public init() {}

    public init(kind: HistoryLaneKind) {
        self.kind = kind
    }

    // MARK: - rate conversion (delta / actual dt, dt > 0)

    /// Per-tick byte delta to bytes per second, or `nil` when the sample must
    /// be dropped.
    ///
    /// The divisor is the time actually elapsed since that lane's previous
    /// sample, **bounded by the reader's interval** (§2): after a sleep or a
    /// stalled queue the elapsed time says nothing about the window the delta
    /// was accumulated over, and dividing a tick's worth of bytes by nine hours
    /// would draw a flat zero over the wake. The first sample of a lane has no
    /// previous one and uses the interval outright.
    ///
    /// `dt > 0` is required rather than assumed: a duplicate timestamp or a
    /// backward clock step would otherwise divide by zero or by a negative
    /// number and fold an infinity or a negative rate.
    public static func rate(delta: Double, at now: TimeInterval,
                            previous: TimeInterval, interval: TimeInterval) -> Double? {
        guard delta.isFinite, now.isFinite, interval.isFinite else { return nil }

        let elapsed = previous > 0 ? now - previous : interval
        let dt = interval > 0 ? Swift.min(elapsed, interval) : elapsed
        guard dt > 0, dt.isFinite else { return nil }

        let value = delta / dt
        return value.isFinite ? value : nil
    }

    // MARK: - fold

    /// Opens a bucket, discarding whatever the previous one held. The caller
    /// closes first — `close()` is what hands the previous bucket on.
    public mutating func open(_ bucket: UInt32) {
        self.bucket = bucket
        self.isOpen = true
        self.count = 0
        self.min = 0
        self.max = 0
        self.sum = 0
    }

    /// Folds one finite value into the open bucket.
    ///
    /// `sum` + `count` rather than a running average: bucket population is not
    /// constant, and an unweighted average of averages would disagree with the
    /// live chart exactly around wake and interval changes (§3). The count
    /// saturates rather than wrapping — 65,535 samples in one 10 s bucket is
    /// not reachable at a 1 s floor, and a wrapped count would make `sum/count`
    /// nonsense. Past saturation `sum` stops accumulating too, so the average
    /// stays the average of the samples that were counted rather than climbing
    /// without bound against a frozen divisor. The envelope keeps tracking:
    /// preserving peaks is the point of storing min and max at all.
    public mutating func fold(_ value: Float) {
        guard value.isFinite else { return }
        guard self.count > 0 else {
            self.count = 1
            self.min = value
            self.max = value
            self.sum = value
            return
        }
        if value < self.min { self.min = value }
        if value > self.max { self.max = value }
        guard self.count < UInt16.max else { return }
        self.sum += value
        self.count += 1
    }

    /// Closes the open bucket and hands back what it holds, or `nil` when it
    /// held no sample. Either way the accumulator is no longer open.
    public mutating func close() -> HistorySlot? {
        guard self.isOpen else { return nil }
        self.isOpen = false
        guard self.count > 0 else { return nil }
        return HistorySlot(bucket: self.bucket, count: self.count, reason: .measured,
                           min: self.min, max: self.max, sum: self.sum)
    }

    /// Records the sample itself, after it has been folded: what a rate divides
    /// by next tick, and what a step lane holds.
    public mutating func note(_ value: Float, at ts: TimeInterval) {
        self.lastValue = value
        self.lastSampleTs = ts
        if self.kind == .step {
            self.holdUntil = ts + HistoryAccumulator.holdWindow
        }
    }

    // MARK: - step-lane hold (15 min cap, written as .held)

    /// The `HELD` slot for a bucket this step lane has no sample in, or `nil`
    /// when the hold does not reach it.
    ///
    /// Only buckets *after* the last sample are held, and only while their
    /// start is before `holdUntil`; everything past that is honest no-data. The
    /// chart draws held spans dashed and the CSV marks them, so a held value is
    /// never presented as a measured one (§2).
    public func heldSlot(bucket: UInt32, step: Int) -> HistorySlot? {
        guard self.kind == .step, self.lastSampleTs > 0, self.lastValue.isFinite else { return nil }
        guard bucket > HistoryClock.bucketIndex(self.lastSampleTs, step: step) else { return nil }
        guard HistoryClock.bucketStart(bucket, step: step) < self.holdUntil else { return nil }
        return HistorySlot(bucket: bucket, count: 1, reason: .held,
                           min: self.lastValue, max: self.lastValue, sum: self.lastValue)
    }

    /// Whether the lane is still holding at this instant: the recorder keeps
    /// committing while it is, even though no sample is arriving.
    public func isHolding(at now: TimeInterval) -> Bool {
        self.kind == .step && self.lastSampleTs > 0 && now < self.holdUntil
    }

    // MARK: - clock step

    /// Drops everything that is expressed in pre-step time, keeping only the
    /// lane's `kind`.
    ///
    /// After a backward clock step every one of these fields is a statement
    /// about a wall clock that no longer runs: the open bucket is in the
    /// future, `lastSampleTs` would make the next rate's `dt` negative and the
    /// sample be dropped, and `holdUntil` would hold a step lane's value across
    /// buckets that are about to be re-lived. Keeping the kind is what lets the
    /// lane carry on recording immediately (§4).
    public mutating func discard() {
        self = HistoryAccumulator(kind: self.kind)
    }
}

// MARK: - accumulator table

/// The fixed-size accumulator table, guarded by a heap-allocated
/// `os_unfair_lock` (macOS 12 rules out `OSAllocatedUnfairLock`).
///
/// Two structures, because they answer two questions. `accumulators` is the
/// 64 B per-lane fold state for the bucket each lane currently has open.
/// `pending` is a small row-major ring of buckets that have closed and are
/// waiting for the commit thread — laid out exactly like the archive's matrix,
/// `(bucket % pendingBuckets) * capacity + lane`, so draining it is a copy and
/// not a regrouping. A closed bucket has to live somewhere between the sample
/// that closes it and the 60 s commit that writes it, whatever attribution
/// does; the ring is that somewhere, and it is bounded.
public final class HistoryAccumulatorTable {
    /// Closed T0 buckets the staging ring holds: 16 × 10 s = 160 s, 2.6× the
    /// 60 s commit cadence and its 5 s leeway. A drain that falls further
    /// behind than that loses the oldest buckets rather than growing, which is
    /// the trade a background feature has to make; `droppedBuckets` counts it.
    public static let pendingBuckets: Int = 16

    /// How far back a drain will look for buckets to emit. The staging ring
    /// plus the 15-minute step-lane hold (90 T0 buckets) is the whole of what
    /// can still produce a row; anything older is no-data, which §4 derives at
    /// read rather than backfilling at write.
    public static let maxCatchUpBuckets: UInt32 = 128

    public let capacity: Int
    public let step: Int

    private var accumulators: [HistoryAccumulator]
    private var pending: [HistorySlot]
    /// The bucket each ring row currently holds, or `nil` for a row that has
    /// been drained. Sixteen optionals; the matrix-style stamp-per-slot trick
    /// is not needed for a ring this small.
    private var pendingStamp: [UInt32?]
    /// How many lanes have something staged in each ring row. A stamp alone is
    /// not the same question: rebinding a lane can empty a row, and a row that
    /// holds nothing must not keep the commit timer awake.
    private var pendingCount: [Int]
    private var lanes: Int = 0
    private var lastDrainedBucket: UInt32?

    /// Closed buckets that went nowhere: overwritten in the ring before a drain
    /// reached them, or handed to a row the ring had already moved past. Zero in
    /// every intended schedule; a non-zero value means the commit timer is not
    /// running — a sleep longer than the ring's 160 s is the realistic way to
    /// get one — which is worth seeing rather than guessing at.
    private var _droppedBuckets: Int = 0

    /// Read under the lock the commit thread and every reader queue share: the
    /// counter is mutated from `stageLocked`, so a synthesized getter would be
    /// a plain unsynchronized read of a value another thread is writing.
    public var droppedBuckets: Int { self.locked { self._droppedBuckets } }

    private let lock: UnsafeMutablePointer<os_unfair_lock>

    /// Bounded by the lane cap, so the table is ~16 KiB at the worst case.
    public init(capacity: Int = HistoryLaneDirectory.laneCap, step: Int = HistoryTier.t0.step) {
        self.capacity = Swift.max(1, capacity)
        self.step = Swift.max(1, step)
        self.accumulators = [HistoryAccumulator](repeating: HistoryAccumulator(), count: self.capacity)
        self.pending = [HistorySlot](repeating: HistorySlot(), count: self.capacity * HistoryAccumulatorTable.pendingBuckets)
        self.pendingStamp = [UInt32?](repeating: nil, count: HistoryAccumulatorTable.pendingBuckets)
        self.pendingCount = [Int](repeating: 0, count: HistoryAccumulatorTable.pendingBuckets)
        self.lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        self.lock.initialize(to: os_unfair_lock())
    }

    deinit {
        self.lock.deinitialize(count: 1)
        self.lock.deallocate()
    }

    // MARK: - lock

    @inline(__always)
    private func locked<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(self.lock)
        defer { os_unfair_lock_unlock(self.lock) }
        return body()
    }

    // MARK: - lane binding

    /// Gives a lane its kind and clears whatever state the id held.
    ///
    /// Called for every `registered` and `reclaimed` registration: a reclaimed
    /// id carries the displaced identity's `lastValue` and `holdUntil`, and
    /// holding one series' last known value into another series' buckets is
    /// exactly the kind of quiet lie this feature must not tell.
    public func bind(lane: Int, kind: HistoryLaneKind) {
        self.locked { () -> Void in
            guard lane >= 0, lane < self.capacity else { return }
            self.accumulators[lane] = HistoryAccumulator(kind: kind)
            for row in 0..<HistoryAccumulatorTable.pendingBuckets {
                if self.pending[row * self.capacity + lane].isRecorded {
                    self.pendingCount[row] -= 1
                    self.pending[row * self.capacity + lane] = HistorySlot()
                    // Only a row this lane actually emptied gives its stamp
                    // back. Rows it never occupied are none of its business,
                    // and a stamp dropped out from under another lane's staged
                    // slot would make the drain skip it.
                    if self.pendingCount[row] <= 0 { self.pendingStamp[row] = nil }
                }
            }
            if lane >= self.lanes { self.lanes = lane + 1 }
        }
    }

    // MARK: - discard everything the table holds

    /// Empties every accumulator and every staged row, and forgets which bucket
    /// was drained last.
    ///
    /// Two callers, for two different reasons: a backward clock step, below,
    /// and `HistoryRecorder.deleteAll`, where the archives the staged rows were
    /// bound for are about to be unlinked and a row that outlived them would be
    /// written into the empty file that replaces them.
    public func discardAll() {
        self.locked { () -> Void in
            for lane in 0..<self.capacity {
                self.accumulators[lane].discard()
            }
            for row in 0..<HistoryAccumulatorTable.pendingBuckets {
                // A staged row thrown away here is a closed bucket that went
                // nowhere, which is precisely what `droppedBuckets` counts. A
                // backward clock step is a legitimate way to produce one, and
                // seeing it beats guessing at it.
                if self.pendingCount[row] > 0 { self._droppedBuckets += 1 }
                self.clearRowLocked(row)
                self.pendingStamp[row] = nil
            }
            self.lastDrainedBucket = nil
        }
    }

    // MARK: - clock step

    /// Drops every bucket index the table holds, because a backward clock step
    /// has made all of them future ones.
    ///
    /// Without this the table would refuse to record for the whole length of
    /// the step: `lastDrainedBucket` is a pre-step bucket, `foldLocked` clamps
    /// a sample's span to `lastDrainedBucket + 1`, and the clamp would then sit
    /// past the bucket the sample actually belongs to and reject it. Staged
    /// slots go with it — they are already in the archive's hands or they are
    /// not, and re-offering them under the new clock would stamp pre-step
    /// measurements onto re-lived buckets, which is the interleaving §4 forbids.
    ///
    /// Only the recorder calls this, from `ingest`, with its own lock held: the
    /// step is detected on the same sample that is about to be folded, and the
    /// reset has to happen between the two.
    public func resetForClockStep() {
        self.discardAll()
    }

    /// A copy of one lane's fold state. For the settings readout and the tests;
    /// the commit path takes rows, not accumulators.
    public func accumulator(lane: Int) -> HistoryAccumulator? {
        self.locked { () -> HistoryAccumulator? in
            guard lane >= 0, lane < self.lanes else { return nil }
            return self.accumulators[lane]
        }
    }

    public var laneCount: Int { self.locked { self.lanes } }

    // MARK: - fold a sink into the open buckets

    /// Folds a whole tick under one lock acquisition.
    public func fold(_ sink: HistorySink, at now: TimeInterval, interval: TimeInterval) {
        guard !sink.isEmpty else { return }
        self.locked { () -> Void in
            for sample in sink.samples {
                _ = self.foldLocked(lane: Int(sample.lane), value: sample.value, at: now, interval: interval)
            }
        }
    }

    /// One scalar. Returns whether it was folded — the rejections are the
    /// interesting half: a non-finite value, a rate whose `dt` is not positive,
    /// and a sample that falls entirely inside buckets that have already been
    /// committed.
    @discardableResult
    public func fold(lane: Int, value: Double, at now: TimeInterval, interval: TimeInterval) -> Bool {
        self.locked { self.foldLocked(lane: lane, value: value, at: now, interval: interval) }
    }

    private func foldLocked(lane: Int, value: Double, at now: TimeInterval, interval: TimeInterval) -> Bool {
        guard lane >= 0, lane < self.capacity, value.isFinite, now > 0 else { return false }
        if lane >= self.lanes { self.lanes = lane + 1 }

        var accumulator = self.accumulators[lane]

        let scalar: Double
        if accumulator.kind == .rate {
            guard let rate = HistoryAccumulator.rate(delta: value, at: now,
                                                     previous: accumulator.lastSampleTs,
                                                     interval: interval) else { return false }
            scalar = rate
        } else {
            scalar = value
        }

        // A `Double` beyond `Float`'s range becomes an infinity on the way into
        // the slot, so the finite check is repeated after the conversion.
        let folded = Float(scalar)
        guard folded.isFinite else { return false }

        // MARK: - interval-span attribution
        //
        // The sample stands for the whole window the reader measured, so it is
        // attributed to every bucket overlapping [now - interval, now] (§2): a
        // 60 s CPU interval fills six 10 s buckets instead of leaving five as
        // gaps. The span never reaches into a bucket that has already been
        // drained, nor behind the open one.
        let end = HistoryClock.bucketIndex(now, step: self.step)
        // Clamped to the staging ring: a span wider than the ring could not be
        // held anyway, and an absurd interval must not turn one sample into a
        // loop over thousands of buckets.
        let maxSpan = TimeInterval(HistoryAccumulatorTable.pendingBuckets * self.step)
        let span = interval.isFinite && interval > 0 ? Swift.min(interval, maxSpan) : 0
        var start = HistoryClock.bucketIndex(now - span, step: self.step)
        if let drained = self.lastDrainedBucket, start <= drained { start = drained &+ 1 }
        if accumulator.isOpen, start < accumulator.bucket { start = accumulator.bucket }
        guard start <= end else { return false }

        // The bucket that is still open is staged *before* any held slot is
        // synthesized. `fillHoldLocked` stages up to a whole turn of the
        // staging ring, and the last row it would reach for is the one the open
        // bucket sits in; closing first gives the measurement that row and
        // makes the hold stop short of it. A held value must never displace a
        // measured one (§2), and the staging ring resolves a collision in
        // favour of the newer bucket, so the order here is the whole of what
        // decides it.
        //
        // The accumulator is not necessarily open: a drain closes every bucket
        // older than the one it is committing, so from the first commit tick
        // onwards a step lane between two events has nothing open at all. The
        // bucket to hold *from* is then the one the previous sample landed in,
        // which is exactly what `heldSlot` already compares against. Without
        // this the buckets between a drain and the next event would be staged
        // by neither path — `fillHoldLocked` would bail for want of a previous
        // and the drain's own `heldSlot` fallback rejects them once `note` has
        // moved `lastSampleTs` forward — and the level series would read as
        // no-data for up to a commit period before every event.
        let openBucket: UInt32?
        if accumulator.isOpen {
            openBucket = accumulator.bucket
        } else if accumulator.kind == .step, accumulator.lastSampleTs > 0 {
            openBucket = HistoryClock.bucketIndex(accumulator.lastSampleTs, step: self.step)
        } else {
            openBucket = nil
        }
        if accumulator.isOpen, accumulator.bucket != start {
            self.stageLocked(accumulator.close(), lane: lane)
        }
        self.fillHoldLocked(lane: lane, accumulator: accumulator, from: openBucket, upTo: start)

        var bucket = start
        while true {
            if accumulator.isOpen, accumulator.bucket != bucket {
                self.stageLocked(accumulator.close(), lane: lane)
            }
            if !accumulator.isOpen { accumulator.open(bucket) }
            accumulator.fold(folded)
            if bucket >= end { break }
            bucket &+= 1
        }

        accumulator.note(folded, at: now)
        self.accumulators[lane] = accumulator
        return true
    }

    /// Stages `HELD` slots for the buckets a step lane skipped between the
    /// bucket it had open and the span this sample starts at.
    ///
    /// A step lane's source is an event, not a tick: two battery events twenty
    /// minutes apart leave the buckets between them with no sample at all, and
    /// span attribution cannot reach them because the reader's 1 s interval
    /// covers one bucket. The value held is the one the accumulator still
    /// carries — the *previous* sample's, since `note` runs after this.
    ///
    /// `previous` is the bucket the lane last had a sample in — the one it
    /// still has open, or, once a drain has closed it, the one `lastSampleTs`
    /// falls in. Either way the caller has already staged or drained it. The
    /// fill stops one row short of a whole turn of the ring so that it can
    /// never take that row back: a synthesized hold must not evict the
    /// measurement it is holding from.
    ///
    /// A gap wider than the ring therefore keeps its first `pendingBuckets - 1`
    /// held buckets and nothing after them, until the next drain — which
    /// re-derives held slots for every bucket after `lastSampleTs` and so
    /// covers the after-the-last-event shape completely. Only the
    /// between-two-events shape can lose hold coverage this way, and what it
    /// loses reads as no-data rather than as a wrong value.
    private func fillHoldLocked(lane: Int, accumulator: HistoryAccumulator,
                                from previous: UInt32?, upTo start: UInt32) {
        guard accumulator.kind == .step, let previous = previous, start > previous &+ 1 else { return }

        var bucket = previous &+ 1
        if let drained = self.lastDrainedBucket, bucket <= drained { bucket = drained &+ 1 }
        // The ring cannot hold more than its own length, one row of which
        // belongs to the bucket just staged; a drain has already emitted
        // everything older than that.
        let limit = Swift.min(start, bucket &+ UInt32(HistoryAccumulatorTable.pendingBuckets - 1))
        while bucket < limit {
            self.stageLocked(accumulator.heldSlot(bucket: bucket, step: self.step), lane: lane)
            bucket &+= 1
        }
    }

    /// Puts a closed slot into the staging ring.
    private func stageLocked(_ slot: HistorySlot?, lane: Int) {
        guard let slot = slot, lane >= 0, lane < self.capacity else { return }
        let row = Int(slot.bucket % UInt32(HistoryAccumulatorTable.pendingBuckets))

        if self.pendingStamp[row] != slot.bucket {
            // A row still holding a newer bucket means this slot is late by a
            // whole turn of the ring; there is nowhere truthful to put it. It
            // still counts as dropped — a slot that goes nowhere must never be
            // invisible to the diagnostic, whichever side of the collision it
            // is on.
            if let stamp = self.pendingStamp[row], stamp > slot.bucket {
                if slot.isRecorded { self._droppedBuckets += 1 }
                return
            }
            if self.pendingCount[row] > 0 { self._droppedBuckets += 1 }
            self.clearRowLocked(row)
            self.pendingStamp[row] = slot.bucket
        }
        if !self.pending[row * self.capacity + lane].isRecorded, slot.isRecorded {
            self.pendingCount[row] += 1
        }
        self.pending[row * self.capacity + lane] = slot
    }

    private func clearRowLocked(_ row: Int) {
        let base = row * self.capacity
        for lane in 0..<self.capacity {
            self.pending[base + lane] = HistorySlot()
        }
        self.pendingCount[row] = 0
    }

    // MARK: - drain closed buckets for the commit thread

    /// Whether there is anything to write: an open bucket holding samples, a
    /// staged row, or a step lane still inside its hold. The commit timer is
    /// suspended when this is false (§3).
    public func isDirty(at now: TimeInterval) -> Bool {
        self.locked { () -> Bool in
            if self.pendingCount.contains(where: { $0 > 0 }) { return true }
            for lane in 0..<self.lanes {
                let accumulator = self.accumulators[lane]
                if accumulator.isOpen, accumulator.count > 0 { return true }
                if accumulator.isHolding(at: now) { return true }
            }
            return false
        }
    }

    /// Every bucket older than `currentBucket` that has anything to say, as
    /// full rows in lane order.
    ///
    /// Rows are `width` slots wide — the archive's lane count, which can be
    /// ahead of this table's while a registration is in flight — and a lane
    /// with nothing in a bucket gets a zeroed slot, which reads as no-data
    /// because `nodata` is raw value 0. A bucket no lane has anything for is
    /// not emitted at all: §4 derives gaps at read and never backfills them at
    /// write.
    ///
    /// Buckets are handed out once. `lastDrainedBucket` is what a later sample
    /// is clamped against, so a row can never be written twice with different
    /// contents.
    ///
    /// The rows are built under the lock that ingest — including Battery's, on
    /// the main run loop — contends for. In steady state that is six rows and a
    /// few microseconds; the catch-up path is bounded by `maxCatchUpBuckets` ×
    /// `width`, and if that bound ever shows up against §7's ingest budget the
    /// fix is to snapshot into a preallocated buffer here and materialize the
    /// rows with the lock released.
    public func drain(before currentBucket: UInt32, lanes width: Int) -> [HistoryRow] {
        self.locked { self.drainLocked(before: currentBucket, lanes: width) }
    }

    private func drainLocked(before currentBucket: UInt32, lanes width: Int) -> [HistoryRow] {
        guard width > 0 else { return [] }

        for lane in 0..<self.lanes where self.accumulators[lane].isOpen && self.accumulators[lane].bucket < currentBucket {
            var accumulator = self.accumulators[lane]
            self.stageLocked(accumulator.close(), lane: lane)
            self.accumulators[lane] = accumulator
        }

        var from: UInt32
        if let drained = self.lastDrainedBucket {
            from = drained &+ 1
        } else if let oldest = self.pendingStamp.enumerated()
            .compactMap({ self.pendingCount[$0.offset] > 0 ? $0.element : nil }).min() {
            from = oldest
        } else {
            from = currentBucket
        }
        // Skipping past `earliest` leaves whatever those ring rows still hold
        // in place rather than clearing it, and their drop goes uncounted until
        // some later bucket lands on the same row and `stageLocked` sees the
        // collision. With 16 rows against a 128-bucket clamp that always
        // happens within eight turns of the ring, so this is latency in the
        // diagnostic, not a slot that goes missing from it.
        let earliest = currentBucket > HistoryAccumulatorTable.maxCatchUpBuckets
            ? currentBucket - HistoryAccumulatorTable.maxCatchUpBuckets : 0
        if from < earliest { from = earliest }
        guard from < currentBucket else { return [] }

        var rows: [HistoryRow] = []
        for bucket in from..<currentBucket {
            let row = Int(bucket % UInt32(HistoryAccumulatorTable.pendingBuckets))
            // Stamped for this bucket. Every path that stamps a row also puts
            // a recorded slot into it, and `bind` gives the stamp back when it
            // empties one, so a stamp here means there is something to read.
            let staged = self.pendingStamp[row] == bucket
            var slots = [HistorySlot](repeating: HistorySlot(bucket: bucket), count: width)
            var any = false

            for lane in 0..<Swift.min(self.lanes, width) {
                if staged {
                    let slot = self.pending[row * self.capacity + lane]
                    if slot.bucket == bucket, slot.isRecorded {
                        slots[lane] = slot
                        any = true
                        continue
                    }
                }
                if let held = self.accumulators[lane].heldSlot(bucket: bucket, step: self.step) {
                    slots[lane] = held
                    any = true
                }
            }

            if staged {
                self.clearRowLocked(row)
                self.pendingStamp[row] = nil
            }
            if any { rows.append(HistoryRow(bucket: bucket, slots: slots)) }
        }

        self.lastDrainedBucket = currentBucket &- 1
        return rows
    }
}

// MARK: - aggregation

/// One drawn column: the min/max envelope, the count-weighted average, and why
/// it is empty when it is. 16 B, which is what the window's memory budget is
/// made of — ≤1,440 columns × 16 B × visible lanes (§7).
public struct HistoryColumn {
    public let min: Float
    public let max: Float
    public let avg: Float
    public let count: UInt16
    public let reason: HistoryGapReason

    public init(min: Float, max: Float, avg: Float, count: UInt16, reason: HistoryGapReason) {
        self.min = min
        self.max = max
        self.avg = avg
        self.count = count
        self.reason = reason
    }
}

/// Rolling fine buckets up into a coarse one, and coarse buckets down into
/// drawn columns. Both are the same arithmetic and both are count-weighted,
/// which is the whole reason the slot stores `sum` and `count` rather than an
/// average (§3).
public enum HistoryAggregate {
    /// Min of mins, max of maxes, sums and counts: what a T1 or T2 bucket is
    /// made of. Always recomputed from T0 rather than accumulated in memory, so
    /// a bucket that straddles a relaunch is still correct when it closes (§3).
    ///
    /// Partially populated input is the normal case — sleep, a disabled module
    /// and an interval change all leave fine buckets empty — and empty input is
    /// a no-data slot rather than a measured zero.
    public static func rollup<S: Sequence>(_ slots: S, into bucket: UInt32) -> HistorySlot where S.Element == HistorySlot? {
        var count: UInt32 = 0
        var sum: Float = 0
        var min: Float = 0
        var max: Float = 0
        var sawMeasured = false
        var sawHeld = false
        var gapReason: HistoryGapReason?

        for case let slot? in slots {
            guard slot.count > 0, slot.min.isFinite, slot.max.isFinite, slot.sum.isFinite else {
                if slot.isRecorded, gapReason == nil, slot.reason != .measured { gapReason = slot.reason }
                continue
            }
            if count == 0 {
                min = slot.min
                max = slot.max
            } else {
                if slot.min < min { min = slot.min }
                if slot.max > max { max = slot.max }
            }
            count += UInt32(slot.count)
            sum += slot.sum
            if slot.reason == .held { sawHeld = true } else { sawMeasured = true }
        }

        guard count > 0 else {
            return HistorySlot(bucket: bucket, count: 0, reason: gapReason ?? .nodata)
        }
        // A coarse bucket is held only when nothing in it was measured; one
        // real sample in half an hour makes the bucket a measured one.
        let reason: HistoryGapReason = sawMeasured ? .measured : (sawHeld ? .held : .measured)
        return HistorySlot(bucket: bucket, count: HistoryAggregate.saturating(count), reason: reason,
                           min: min, max: max, sum: sum)
    }

    /// One column from a run of slots, or `nil` when the run holds nothing at
    /// all to draw.
    public static func column<S: Sequence>(_ slots: S) -> HistoryColumn? where S.Element == HistorySlot? {
        let rolled = HistoryAggregate.rollup(slots, into: 0)
        guard rolled.count > 0 else {
            return rolled.reason == .nodata ? nil
                : HistoryColumn(min: 0, max: 0, avg: 0, count: 0, reason: rolled.reason)
        }
        return HistoryColumn(min: rolled.min, max: rolled.max, avg: rolled.sum / Float(rolled.count),
                             count: rolled.count, reason: rolled.reason)
    }

    /// Resamples a bucket range into `columns` drawn columns.
    ///
    /// Count-weighted: the average is `Σsum / Σcount` over the whole column,
    /// never the mean of the per-bucket averages. Bucket population is not
    /// constant — intervals are user-settable 1–60 s and change at runtime,
    /// sleep and toggles leave partial buckets — so an unweighted mean would
    /// let a bucket holding one sample outvote a bucket holding sixty, and
    /// would over-count #3450's daily totals by up to 6× (§3).
    public static func resample(_ slots: [HistorySlot?], columns: Int) -> [HistoryColumn?] {
        guard columns > 0 else { return [] }
        guard !slots.isEmpty else { return [HistoryColumn?](repeating: nil, count: columns) }

        return (0..<columns).map { column in
            let lower = column * slots.count / columns
            let upper = (column + 1) * slots.count / columns
            guard lower < upper else { return nil }
            return HistoryAggregate.column(slots[lower..<upper])
        }
    }

    /// `count` is a `UInt16` in the slot and in the column: 65,535 samples is
    /// unreachable at a 1 s interval floor in any tier's bucket, and saturating
    /// keeps `sum / count` merely imprecise rather than nonsense if it ever is.
    private static func saturating(_ count: UInt32) -> UInt16 {
        count > UInt32(UInt16.max) ? UInt16.max : UInt16(count)
    }
}
