//
//  HistoryRecorder.swift
//  Kit
//
//  Persistent usage history: the ingest hook, the single commit timer and the
//  tiered rollup.
//  Design: docs/usage-history-design.md (§2, §3, §5), exelban/stats#1194.
//

import Foundation
import IOKit.ps
import os

/// The one object the rest of the app talks to. `ingest` is called from
/// `Reader.callback`, on whatever queue that reader runs on — including the
/// main run loop for Battery's IOPS notification — so it must stay allocation
/// free and must return immediately when recording is off.
///
/// Two things the recorder owes the pieces below it, because neither can
/// enforce them itself: its `HistoryLaneRegistry` conformance has to serialize
/// `HistoryLaneDirectory.register` — that object is not thread safe and every
/// reader queue reaches it through `HistorySink.lane` — and it has to write the
/// directory out when `lastUsedTs` drifts far enough from the stored copy that
/// LRU reclaim would read a hot lane as cold at the next launch.
///
/// Both are done here: every reader queue meets the registry under `lock`, and
/// `directoryFlushInterval` bounds the drift.
public final class HistoryRecorder {
    public static let shared = HistoryRecorder()

    // MARK: - cadences and thresholds (§3)

    /// One `DispatchSourceTimer` for the whole feature, 60 s with 5 s leeway.
    /// 60 s rather than 30 s halves the write volume at the cost of losing at
    /// most 60 s of unflushed accumulator on `kill -9`.
    public static let commitInterval: TimeInterval = 60
    public static let commitLeeway: TimeInterval = 5

    /// The free-space precondition is read every tenth commit — ~10 min — and
    /// after any failure, not on every tick: it is a `stat`-class call on the
    /// volume and the thing it guards against does not arrive in one minute.
    public static let freeSpaceEveryNthCommit: Int = 10

    /// Three consecutive write failures suspend recording for an hour, and the
    /// next cycle after that retries rather than waiting for a relaunch (§3).
    public static let failureStrikes: Int = 3
    public static let suspensionWindow: TimeInterval = 3_600

    /// `fsync` every 10 min, stretched to 30 on battery, in Low Power Mode or
    /// at `thermalState >= .serious`.
    public static let syncInterval: TimeInterval = 600
    public static let relaxedSyncInterval: TimeInterval = 1_800

    /// How far the stored `lastUsedTs` may drift behind the live one before the
    /// directory is written out anyway. `HistoryLaneDirectory.touch` is
    /// deliberately cheap and does not move `revision`, so without this a lane
    /// that has been recording all week could look reclaimable at the next
    /// launch and lose its data to LRU.
    public static let directoryFlushInterval: TimeInterval = 3_600

    // MARK: - environment

    /// Everything the recorder reads from outside itself. A struct of closures
    /// rather than direct calls so that the clock, the volume's free space and
    /// the power state can be driven from a test: a three-strikes suspension
    /// takes an hour of wall clock to lift and a low-disk skip would otherwise
    /// need a full volume to provoke.
    public struct Environment {
        public var now: () -> TimeInterval
        public var availableSpace: (URL) -> Int64?
        public var isPowerConstrained: () -> Bool

        public init(now: @escaping () -> TimeInterval,
                    availableSpace: @escaping (URL) -> Int64?,
                    isPowerConstrained: @escaping () -> Bool) {
            self.now = now
            self.availableSpace = availableSpace
            self.isPowerConstrained = isPowerConstrained
        }

        public static let live = Environment(
            now: { Date().timeIntervalSince1970 },
            availableSpace: { HistoryStore.availableSpace(at: $0) },
            isPowerConstrained: HistoryRecorder.isPowerConstrained
        )
    }

    // MARK: - state

    public let store: HistoryStore
    /// Standard or Minimal, and nothing else (§3). Minimal keeps T0 only, so
    /// the rollup below simply has no coarse tier to write.
    public let preset: HistoryRetentionPreset
    private let environment: Environment

    /// The one private serial queue the feature owns. Everything that touches a
    /// file runs here.
    private let queue = DispatchQueue(label: "eu.exelban.history", qos: .utility)
    private let table: HistoryAccumulatorTable
    private let directory = HistoryLaneDirectory()
    private var sink = HistorySink()

    /// Heap allocated because macOS 12 rules out `OSAllocatedUnfairLock` and an
    /// `os_unfair_lock` stored inline in a class would be moved by the compiler.
    /// Guards `sink`, `directory`, `recording`, `statusValue` and `timerWanted`
    /// — everything a reader queue and the commit thread both touch that is not
    /// already guarded by the accumulator table's own lock.
    ///
    /// Lock order is recorder then table, never the other way round: `ingest`
    /// and the timer-parking check take this one and then reach into the table,
    /// while `drain` takes the table's alone.
    private let lock: UnsafeMutablePointer<os_unfair_lock>

    // Guarded by `lock`.
    private var recording: Bool = false
    private var statusValue: HistoryStore.Status = .disabled
    /// Whether the commit timer is wanted. Flipped to `true` by the ingest that
    /// first dirties a clean table and back to `false` by a commit that leaves
    /// it clean — both under `lock`, which is what makes the hand-off race
    /// free: a fold and the flag it sets are one atomic step against the
    /// commit's "is it clean" check and the clear that follows it.
    private var timerWanted: Bool = false

    // History queue only.
    private var timer: DispatchSourceTimer?
    private var timerRunning: Bool = false
    private var appliedRevision: UInt64 = 0
    /// The newest coarse bucket each tier has already been scanned for, whether
    /// or not the scan found anything to write.
    private var lastRolledUp: [HistoryTier: UInt32] = [:]
    private var commitCount: Int = 0
    private var consecutiveFailures: Int = 0
    private var suspendedUntil: TimeInterval = 0
    private var needsFreeSpaceCheck: Bool = false
    private var isLowOnSpace: Bool = false
    private var lastSyncTs: TimeInterval = 0
    private var lastDirectoryWriteTs: TimeInterval = 0

    public convenience init() {
        self.init(store: HistoryStore.shared)
    }

    /// The store, the preset and the environment are injected so that a test
    /// can point a whole recorder at a temporary directory with a clock it
    /// drives. The app uses `shared`, which is the no-argument form.
    public init(store: HistoryStore, preset: HistoryRetentionPreset = .standard,
                environment: Environment = .live) {
        self.store = store
        self.preset = preset
        self.environment = environment
        self.table = HistoryAccumulatorTable(step: HistoryTier.t0.step)
        self.lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        self.lock.initialize(to: os_unfair_lock())
    }

    deinit {
        // Releasing a suspended dispatch source traps in libdispatch, and the
        // timer spends most of its life suspended. Cancel first — that is what
        // stops the handler from running — then balance the suspend count.
        if let timer = self.timer {
            timer.setEventHandler {}
            timer.cancel()
            if !self.timerRunning { timer.resume() }
        }
        self.lock.deinitialize(count: 1)
        self.lock.deallocate()
    }

    @inline(__always)
    private func locked<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(self.lock)
        defer { os_unfair_lock_unlock(self.lock) }
        return body()
    }

    // MARK: - lifecycle (start from AppDelegate, flush on terminate)

    /// Master switch, read as the first statement of `ingest`. ON by default:
    /// a retrospective feature that is off when the anomaly happens is
    /// worthless (§6). The value the app starts with comes from `Store`, with a
    /// default of `true`, in the commit that adds the settings switch.
    ///
    /// Read under `lock` rather than as a plain load. Every reader queue —
    /// including main, for Battery's IOPS callback — reads it while the
    /// settings toggle and `start`/`stop` write it, and an unsynchronized
    /// `Bool` shared across queues is a data race whatever its width. §2's
    /// "costs a predicated branch" is therefore an uncontended lock acquisition
    /// and a branch, which is tens of nanoseconds against a per-reader cadence
    /// of one second.
    public var isRecording: Bool { self.locked { self.recording } }

    /// What the settings section renders. Written from the history queue, read
    /// from main.
    public var status: HistoryStore.Status { self.locked { self.statusValue } }

    /// Lanes the registry currently holds, for the "N lanes · X MB" readout.
    public var laneCount: Int { self.locked { self.directory.count } }

    /// Opens the archives, takes the cross-process lock and catches the coarse
    /// tiers up on whatever closed while the app was down. Asynchronous on
    /// purpose: this is file I/O and `applicationDidFinishLaunching` is on main.
    ///
    /// Ticks that arrive while the start is still in flight are dropped:
    /// `recording` is turned on only once the archives are open and the
    /// catch-up has run, because folding into a table whose lane ids are about
    /// to be re-pointed by the stored directory would attribute samples to the
    /// wrong series. A reader tick is one second; the start is milliseconds.
    public func start(enabled: Bool = true) {
        self.queue.async { self.performStart(enabled: enabled) }
    }

    /// Commits what is pending, flushes and closes. The cross-process lock goes
    /// back so a second copy of Stats can take over.
    ///
    /// Must not be called from the history queue.
    public func stop() {
        self.queue.sync {
            self.setRecordingFlag(false)
            self.commit(at: self.environment.now())
            self.store.sync()
            self.parkTimerForGood()
            self.store.closeAll()
            self.store.releaseLock()
            self.setStatus(.disabled)
            // The sink holds the registry — which is this object — strongly, on
            // purpose (§2). Dropping it here is what lets a recorder that is not
            // the process singleton be deallocated.
            self.locked { self.sink.prepare(registry: nil, at: 0) }
        }
    }

    /// The settings master switch. Turning it off stops ingest immediately;
    /// what is already in the accumulators is still committed, because throwing
    /// away a minute of measured data is not what "stop recording" means.
    ///
    /// Turning it on opens nothing: until `start` has taken the cross-process
    /// lock and opened the archives, samples fold into a table no commit can
    /// drain and the staging ring drops them. That is why the settings toggle
    /// this is written for reads `status` as well — a recorder that lost the
    /// flock or failed to open says so rather than pretending to record.
    public func setRecording(_ enabled: Bool) {
        let changed = self.locked { () -> Bool in
            guard self.recording != enabled else { return false }
            self.recording = enabled
            if enabled {
                if self.statusValue == .disabled { self.statusValue = .recording }
            } else if self.statusValue == .recording {
                self.statusValue = .disabled
            }
            return true
        }
        guard changed, !enabled else { return }
        self.queue.async { self.commit(at: self.environment.now()) }
    }

    /// `fsync` now, whatever the cadence says: sleep and
    /// `applicationWillTerminate` are the two moments the periodic policy
    /// cannot cover. Synchronous, because a terminate handler that returns
    /// before the data is on disk has not flushed anything.
    ///
    /// Must not be called from the history queue.
    public func flush() {
        self.queue.sync {
            let now = self.environment.now()
            self.commit(at: now)
            self.store.sync()
            self.lastSyncTs = now
        }
    }

    /// Runs one commit cycle synchronously. The timer path for tests, and what
    /// `flush` is built on.
    ///
    /// Must not be called from the history queue.
    public func commitNow() {
        self.queue.sync { self.commit(at: self.environment.now()) }
    }

    /// Whether the commit timer is currently scheduled. The hand-off between an
    /// ingest that dirties a clean table and the commit that parks the timer
    /// again has no other observable effect inside a cadence, so this is what a
    /// test asserts on rather than waiting 60 s for a tick.
    ///
    /// Must not be called from the history queue.
    public var isCommitTimerRunning: Bool { self.queue.sync { self.timerRunning } }

    /// Blocks until everything already queued on the history queue has run.
    /// `start` is asynchronous, so a test that wants to assert on its result
    /// needs a barrier.
    public func waitUntilIdle() {
        self.queue.sync {}
    }

    private func performStart(enabled: Bool) {
        switch self.store.acquireLock() {
        case .acquired:
            break
        case .heldByAnotherProcess:
            // Normal in this fork — a locally signed build beside the released
            // one — so it is a status the settings section renders, not an
            // error the user has to act on (§3).
            error("history: another copy of Stats is recording, this one will not")
            self.setRecordingFlag(false)
            self.setStatus(.lockedByAnotherInstance)
            return
        case .unavailable(let code):
            // Not a second instance: an unwritable directory or an exhausted
            // descriptor table. There is no separate banner for it, and
            // `writeFailures` is the one of the five states that does not claim
            // something untrue about another process.
            error("history: the lock file could not be opened (errno \(code))")
            self.setRecordingFlag(false)
            self.setStatus(.writeFailures)
            return
        }

        do {
            try self.store.open(preset: self.preset)
        } catch let failure {
            error("history: the archives could not be opened: \(failure)")
            self.setRecordingFlag(false)
            self.setStatus(.writeFailures)
            self.store.releaseLock()
            return
        }

        let now = self.environment.now()
        self.lastSyncTs = now
        self.lastDirectoryWriteTs = now

        // Lane ids are positions in the stored directory, so the directory the
        // archive came back with *is* the registry: rebuilding it from scratch
        // would re-point every lane in the matrix at a different series.
        if let t0 = self.store.archive(.t0) {
            let stored = t0.directory
            self.appliedRevision = self.locked { () -> UInt64 in
                self.directory.adopt(stored)
                for (lane, entry) in stored.enumerated() {
                    self.table.bind(lane: lane, kind: entry.kind)
                }
                return self.directory.revision
            }
        }

        // Every coarse bucket that closed while the app was down, before the
        // first live commit (§3).
        do {
            try self.rollUpCoarseTiers(upTo: now)
            self.consecutiveFailures = 0
        } catch {
            self.recordFailure(error)
        }

        self.setRecordingFlag(enabled)
        if self.status != .writeFailures {
            self.setStatus(enabled ? .recording : .disabled)
        }
        // The timer stays suspended: nothing is dirty yet, and the first ingest
        // that folds a value is what starts it.
    }

    // MARK: - ingest(_:reader:interval:) — the hot path

    /// One reader tick. Called from `Reader.callback`, on the reader's own
    /// queue — the main run loop for Battery's IOPS notification and
    /// Bluetooth's delegate.
    ///
    /// `isRecording` is read first, before the cast, so a payload from a reader
    /// that emits nothing (Clock's `Reader<Date>`, every `ProcessReader`) costs
    /// a lock and a branch and never reaches the dynamic cast. `interval` is
    /// the reader's own, used for span attribution: a sample stands for the
    /// whole window the reader measured, so it fills every bucket overlapping
    /// `[now − interval, now]` rather than leaving five of six as gaps (§2).
    /// A reader with no interval attributes to the current bucket only.
    ///
    /// `emitHistory` runs with `lock` held. That is what serializes the
    /// registry, and it is safe because the only thing a conformance may do is
    /// materialize its own payload array — never call back into the recorder.
    public func ingest<T>(_ value: T, reader: HistoryReaderKey, interval: TimeInterval? = nil) {
        let wake = self.locked { () -> Bool in
            guard self.recording else { return false }
            guard let provider = value as? HistoryProvider else { return false }

            // `isFinite` as well as positive: the conversion on the next line
            // traps on an infinity, and the clock is injectable.
            let now = self.environment.now()
            guard now > 0, now.isFinite else { return false }
            self.sink.prepare(registry: self, at: UInt64(now))
            provider.emitHistory(reader: reader, into: &self.sink)
            guard !self.sink.isEmpty else { return false }

            self.table.fold(self.sink, at: now, interval: interval ?? 0)
            guard !self.timerWanted else { return false }
            self.timerWanted = true
            return true
        }
        guard wake else { return }
        self.queue.async { self.startTimer() }
    }

    // MARK: - commit timer (60 s, 5 s leeway, .utility, suspended when clean)

    private func startTimer() {
        guard !self.timerRunning else { return }
        let timer: DispatchSourceTimer
        if let existing = self.timer {
            timer = existing
        } else {
            timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.setEventHandler { [weak self] in
                guard let self = self else { return }
                self.commit(at: self.environment.now())
            }
            self.timer = timer
        }
        timer.schedule(deadline: .now() + HistoryRecorder.commitInterval,
                       repeating: HistoryRecorder.commitInterval,
                       leeway: .seconds(Int(HistoryRecorder.commitLeeway)))
        timer.resume()
        self.timerRunning = true
    }

    /// Suspends the timer when the accumulators hold nothing. The clean check
    /// and the `timerWanted` clear happen under the same `lock` acquisition an
    /// `ingest` fold takes, so a sample that arrives between the two cannot be
    /// left with a suspended timer and nobody to start it.
    private func parkTimerIfClean(at now: TimeInterval) {
        // A suspension has to keep ticking, or nothing would ever retry it.
        guard self.suspendedUntil == 0 else { return }
        let clean = self.locked { () -> Bool in
            guard !self.table.isDirty(at: now) else { return false }
            self.timerWanted = false
            return true
        }
        guard clean else { return }
        self.parkTimer()
    }

    private func parkTimer() {
        guard self.timerRunning, let timer = self.timer else { return }
        timer.suspend()
        self.timerRunning = false
    }

    /// Parks the timer *and* gives up the intent to run it, for the paths that
    /// stop it regardless of what the accumulators still hold.
    ///
    /// `parkTimerIfClean` clears `timerWanted` only when the table is clean,
    /// which is right for a commit that left nothing behind and wrong here: the
    /// bucket open at `stop()` normally still holds samples, so the flag would
    /// survive the stop, and the first `ingest` after the next `start()` would
    /// see it already set, skip `startTimer` and leave a suspended timer with
    /// nobody to resume it — nothing committed again except through an explicit
    /// `flush`, with the staging ring silently dropping everything older than
    /// its 160 s.
    private func parkTimerForGood() {
        self.locked { self.timerWanted = false }
        self.parkTimer()
    }

    // MARK: - commit

    /// One commit cycle, on the history queue.
    ///
    /// Closed T0 buckets are drained out of the accumulator table — snapshot
    /// and reset under the table's lock — and written with the lock released;
    /// then every coarse bucket that closed since the last cycle is rolled up
    /// out of T0 and written to its own tier.
    private func commit(at now: TimeInterval) {
        guard now > 0, now.isFinite else { return }
        // Nothing is open: `setRecording(true)` ahead of `start()`, a start that
        // could not take the flock or could not open the archives, or a cycle
        // that raced `stop()`. There is nothing to write and nothing this path
        // retries, so the timer is parked rather than left waking once a minute
        // for a store that is not there; the next ingest after a successful
        // open starts it again.
        guard self.store.archive(.t0) != nil else {
            self.parkTimerForGood()
            return
        }

        // Three strikes: suspended for an hour, and the cycle after that
        // retries rather than waiting for a relaunch (§3).
        if self.suspendedUntil > 0 {
            guard now >= self.suspendedUntil else { return }
            self.suspendedUntil = 0
            self.consecutiveFailures = 0
            self.needsFreeSpaceCheck = true
            self.setStatus(self.isRecording ? .recording : .disabled)
        }

        self.commitCount += 1
        if (self.commitCount - 1) % HistoryRecorder.freeSpaceEveryNthCommit == 0
            || self.needsFreeSpaceCheck || self.isLowOnSpace {
            self.checkFreeSpace()
        }
        // The store degrades before the volume does: the commit is skipped, the
        // accumulators keep folding, and the staging ring drops what it cannot
        // hold. Nothing is written until there is room again.
        guard !self.isLowOnSpace else { return }

        do {
            try self.applyDirectoryIfNeeded(at: now)
            try self.commitT0(at: now)
            try self.rollUpCoarseTiers(upTo: now)
            self.recordSuccess()
        } catch {
            self.recordFailure(error)
        }

        self.syncIfDue(at: now)
        self.parkTimerIfClean(at: now)
    }

    private func commitT0(at now: TimeInterval) throws {
        guard let t0 = self.store.archive(.t0) else { return }
        let lanes = t0.laneCount
        guard lanes > 0 else { return }

        // The drain's width is the archive's lane count, taken after
        // `applyDirectoryIfNeeded` has written whatever the registry gained, so
        // a lane registered in an earlier cycle is always inside it. A lane
        // registered by a reader queue *between* those two statements is not,
        // and the drain clears the whole ring row, so anything it had already
        // closed is dropped. That needs the lane's very first sample to carry
        // an interval spanning more than one bucket — the sample that opens a
        // lane otherwise only opens the current bucket, which this drain does
        // not touch — and it costs one repeated sample of one new lane. Written
        // down because the ordering is what makes it harmless, and the ordering
        // is not obvious from either side.
        let currentBucket = HistoryClock.bucketIndex(now, step: HistoryTier.t0.step)
        let rows = self.table.drain(before: currentBucket, lanes: lanes)
        guard !rows.isEmpty else { return }
        try t0.commit(rows)

        // `commit` is what moves a lane's `firstValidBucket`, and the registry
        // is what the sidebar and LRU read. Carrying it back is also what
        // retires `.reclaimed`: once a lane has written a bucket of its own,
        // `firstValidBucket` says the same thing more precisely.
        self.locked {
            for lane in 0..<lanes {
                guard let entry = t0.entry(lane: lane) else { continue }
                self.directory.setFirstValidBucket(entry.firstValidBucket, lane: lane)
            }
        }
    }

    /// Writes the lane directory into every tier when the registry has moved,
    /// and once an hour regardless so that `lastUsedTs` on disk cannot fall far
    /// enough behind for LRU to read a hot lane as cold.
    ///
    /// `reconcile` is what keeps each tier's own `firstValidBucket`: the
    /// registry knows which lanes exist, but only the archive knows how much of
    /// *its* matrix is populated.
    private func applyDirectoryIfNeeded(at now: TimeInterval) throws {
        let snapshot: (entries: [HistoryLaneEntry], revision: UInt64) = self.locked {
            (self.directory.all, self.directory.revision)
        }
        guard !snapshot.entries.isEmpty else { return }
        let drifted = now - self.lastDirectoryWriteTs >= HistoryRecorder.directoryFlushInterval
        guard snapshot.revision != self.appliedRevision || drifted else { return }

        for tier in self.preset.tiers {
            guard let archive = self.store.archive(tier) else { continue }
            try archive.setDirectory(HistoryLaneDirectory.reconcile(primary: snapshot.entries,
                                                                    with: archive.directory))
        }
        self.appliedRevision = snapshot.revision
        self.lastDirectoryWriteTs = now
    }

    // MARK: - rollup (T1/T2 always recomputed from T0 at bucket close)
    // MARK: - catch-up at open (coarse buckets that closed while down)

    /// Every coarse bucket that has closed and has not been written yet.
    ///
    /// This is one routine, not two: the steady-state close and the catch-up
    /// after a restart differ only in how many buckets `lastCommitBucket`
    /// leaves outstanding. That is the whole reason T1 and T2 are recomputed
    /// from T0 rather than accumulated in memory — a bucket that straddles a
    /// relaunch is still correct when it closes, and the ones that closed while
    /// the app was down are recoverable for as long as T0 retains their source
    /// rows (§3).
    private func rollUpCoarseTiers(upTo now: TimeInterval) throws {
        guard let t0 = self.store.archive(.t0), t0.laneCount > 0 else { return }
        for tier in self.preset.tiers where tier != .t0 {
            guard let archive = self.store.archive(tier) else { continue }
            try self.rollUp(tier: tier, into: archive, from: t0, upTo: now)
        }
    }

    private func rollUp(tier: HistoryTier, into archive: HistoryArchive,
                        from t0: HistoryArchive, upTo now: TimeInterval) throws {
        let lanes = archive.laneCount
        guard lanes > 0 else { return }
        let current = HistoryClock.bucketIndex(now, step: tier.step)
        guard current > 0 else { return }

        // Anything older than what T0 still holds is unrecoverable and stays
        // honest no-data: downtime longer than T0's 24 h is a hole, not a
        // fabricated flat line (§3).
        let coverage = UInt32(Swift.max(1, HistoryTier.t0.buckets * HistoryTier.t0.step / tier.step))
        // `lastCommitBucket == 0` is a tier that has never been written: only
        // the bucket that just closed is worth looking at, and even that is
        // no-data unless T0 happens to hold something for it.
        var from = archive.lastCommitBucket == 0 ? current &- 1 : archive.lastCommitBucket &+ 1
        // A span that rolled up to nothing writes nothing, so `lastCommitBucket`
        // does not move and the next tick would scan it again — for as long as
        // the machine stays idle, which after a day of downtime is 720 T1 or 48
        // T2 buckets re-read every minute. A closed coarse bucket cannot gain
        // T0 rows after the fact (the T0 commit for its span runs first, in the
        // same cycle), so scanning it once is enough.
        if let scanned = self.lastRolledUp[tier], scanned &+ 1 > from { from = scanned &+ 1 }
        let earliest = current > coverage ? current - coverage : 0
        if from < earliest { from = earliest }
        guard from < current else { return }

        var rows: [HistoryRow] = []
        for bucket in from..<current {
            if let row = HistoryRecorder.rollUpRow(bucket: bucket, step: tier.step, lanes: lanes, from: t0) {
                rows.append(row)
            }
        }
        guard !rows.isEmpty else {
            self.lastRolledUp[tier] = current &- 1
            return
        }
        try archive.commit(rows)
        // Only after the write: a failed commit has to leave the span for the
        // retry, not mark it done.
        self.lastRolledUp[tier] = current &- 1
    }

    /// One coarse row out of the T0 rows it spans: min of mins, max of maxes,
    /// sums and counts, per lane. `nil` when no lane has anything in the whole
    /// span — gaps are derived at read and never backfilled at write (§4).
    ///
    /// T0 is read a whole row at a time rather than a lane at a time: the
    /// layout is row-major, so one pass produces every lane's contribution at
    /// once instead of striding the file once per lane.
    private static func rollUpRow(bucket: UInt32, step: Int, lanes: Int, from t0: HistoryArchive) -> HistoryRow? {
        let fineStep = HistoryTier.t0.step
        let start = HistoryClock.bucketIndex(HistoryClock.bucketStart(bucket, step: step), step: fineStep)
        let end = HistoryClock.bucketIndex(HistoryClock.bucketStart(bucket &+ 1, step: step), step: fineStep)
        guard end > start else { return nil }

        // The fine rows are read once and every lane's rollup takes its own
        // column out of them lazily, so the pass costs one array per fine bucket
        // and not one per lane as well — 180 at T2 rather than 180 + 116 at the
        // sensors-heavy lane count, and no second copy of every slot.
        var fine: [[HistorySlot?]] = []
        fine.reserveCapacity(Int(end - start))
        for index in start..<end {
            fine.append(t0.row(bucket: index))
        }

        var slots: [HistorySlot] = []
        slots.reserveCapacity(lanes)
        var any = false
        for lane in 0..<lanes {
            let rolled = HistoryAggregate.rollup(fine.lazy.map { lane < $0.count ? $0[lane] : nil },
                                                 into: bucket)
            if rolled.isRecorded { any = true }
            slots.append(rolled)
        }
        return any ? HistoryRow(bucket: bucket, slots: slots) : nil
    }

    // MARK: - failure handling (free-space precondition, three strikes)

    /// `volumeAvailableCapacityForImportantUsage` below 50 MB pauses recording
    /// and the settings section says so. A volume that cannot be queried is
    /// "unknown", never "full": refusing to record because a `stat` failed
    /// would be the store harming the feature it exists for.
    private func checkFreeSpace() {
        self.needsFreeSpaceCheck = false
        let wasLow = self.isLowOnSpace
        if let available = self.environment.availableSpace(self.store.directory) {
            self.isLowOnSpace = !HistoryStore.hasEnoughFreeSpace(available: available)
        } else {
            self.isLowOnSpace = false
        }
        guard wasLow != self.isLowOnSpace else { return }
        if self.isLowOnSpace {
            error("history: paused, less than \(HistoryStore.freeSpaceFloor / 1_000_000) MB free")
            self.setStatus(.lowDiskSpace)
        } else if self.status == .lowDiskSpace {
            self.setStatus(self.isRecording ? .recording : .disabled)
        }
    }

    private func recordSuccess() {
        self.consecutiveFailures = 0
        guard self.status == .writeFailures else { return }
        self.setStatus(self.isRecording ? .recording : .disabled)
    }

    private func recordFailure(_ failure: Error) {
        self.consecutiveFailures += 1
        // A failed write is the most likely symptom of a volume that filled up
        // between two of the periodic checks.
        self.needsFreeSpaceCheck = true
        error("history: commit failed (\(self.consecutiveFailures) of \(HistoryRecorder.failureStrikes)): \(failure)")
        guard self.consecutiveFailures >= HistoryRecorder.failureStrikes else { return }
        self.suspendedUntil = self.environment.now() + HistoryRecorder.suspensionWindow
        self.setStatus(.writeFailures)
    }

    /// `fsync` every 10 min, stretched to 30 on battery, in Low Power Mode or
    /// at `thermalState >= .serious`. Everything between two of those is at the
    /// mercy of a panic, which is the trade a background feature makes for not
    /// forcing the disk awake every minute.
    ///
    /// The elapsed test comes first and the power state is consulted only to
    /// decide whether a sync that is already due stretches to 30 min: the live
    /// implementation is an IOKit round trip — `IOPSCopyPowerSourcesInfo`,
    /// `IOPSCopyPowerSourcesList` and a walk of the descriptions — and paying
    /// for it every 60 s to answer a question that matters once every ten
    /// minutes is the kind of idle cost this feature exists to avoid.
    private func syncIfDue(at now: TimeInterval) {
        let elapsed = now - self.lastSyncTs
        guard elapsed >= HistoryRecorder.syncInterval else { return }
        if elapsed < HistoryRecorder.relaxedSyncInterval, self.environment.isPowerConstrained() { return }
        self.lastSyncTs = now
        self.store.sync()
    }

    private func setStatus(_ status: HistoryStore.Status) {
        self.locked { self.statusValue = status }
    }

    private func setRecordingFlag(_ enabled: Bool) {
        self.locked { self.recording = enabled }
    }

    /// Whether the `fsync` cadence should stretch from 10 min to 30: running on
    /// battery, in Low Power Mode, or at `thermalState >= .serious`.
    ///
    /// `isLowPowerModeEnabled` and `thermalState` both exist at the macOS 12
    /// deployment target and appear nowhere else in the codebase today (§3).
    /// `ThermalState` is not `Comparable`, so ">= .serious" is spelled on the
    /// raw values.
    public static func isPowerConstrained() -> Bool {
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled { return true }
        if info.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue { return true }
        return HistoryRecorder.isOnBatteryPower()
    }

    /// A desktop has no power source in the list at all, which reads as "not on
    /// battery" — which is what it is.
    private static func isOnBatteryPower() -> Bool {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as [CFTypeRef]
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)
                .takeUnretainedValue() as? [String: Any] else { continue }
            if description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue { return true }
        }
        return false
    }
}

// MARK: - lane registration

/// The registry every reader queue reaches through `HistorySink.lane`.
///
/// `HistoryLaneDirectory` is not thread safe and says so: two reader queues
/// meeting a new lane at the same instant would corrupt an array and a
/// dictionary, not merely race a value. This conformance is only ever entered
/// from `ingest`, with the recorder's lock already held, which is the
/// serialization the directory's own documentation asks the recorder for.
extension HistoryRecorder: HistoryLaneRegistry {
    public func lane(for descriptor: HistoryLaneDescriptor, at ts: UInt64) -> Int? {
        let registration = self.directory.register(descriptor, at: ts)
        // A lane that is new to this table has no accumulator state, and a
        // reclaimed one carries the displaced identity's `lastValue` and
        // `holdUntil` — holding one series' last known value into another
        // series' buckets is exactly the quiet lie this feature must not tell.
        if registration.isNew, let lane = registration.lane {
            self.table.bind(lane: lane, kind: descriptor.kind)
        }
        return registration.lane
    }
}

// MARK: - daily traffic

/// #3450's surface: an independent monotonic per-day byte counter written at
/// ingest, in its own small append-only file. Not a tiered lane, and not
/// integrated from averaged buckets. Days roll at local midnight, recomputed
/// from the current calendar on every commit tick so DST produces a 23- or
/// 25-hour day rather than a shifted one (§5).
public final class HistoryDailyTraffic {
    public init() {}

    // MARK: - add(up:down:)
    // MARK: - today and yesterday
    // MARK: - local-midnight roll and persistence
}
