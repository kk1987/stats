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

    /// The recorder `Reader.callback` feeds. In the app this is `shared` and
    /// nothing ever assigns it; `AppDelegate` starts and flushes `shared`
    /// directly.
    ///
    /// It exists because the hook in `Kit/module/reader.swift` has to name
    /// something, and a singleton names the user's own history directory — so
    /// without a seam here the one line that connects every reader in the app
    /// to this object is the one line no test can execute without writing into
    /// it. A test that drives a real `Reader` points this at a recorder on a
    /// temporary directory and puts it back afterwards.
    ///
    /// Locked rather than a plain stored static, which is what the test it
    /// exists for actually needs: the `Tests` bundle is hosted by the app, so
    /// that test writes this while a dozen real readers are ticking through
    /// `Reader.callback` and reading it. An unsynchronized reference swapped
    /// under concurrent reads is a race whatever the pointer width, and the
    /// cost of not having one — an uncontended `os_unfair_lock` on a path that
    /// runs once per reader per second — does not show up anywhere.
    public static var hook: HistoryRecorder {
        get {
            os_unfair_lock_lock(HistoryRecorder.hookLock)
            let current = HistoryRecorder.hookStorage
            os_unfair_lock_unlock(HistoryRecorder.hookLock)
            // Outside the lock: `shared` builds a whole recorder, and a lazy
            // global initializer is not somewhere to hold one.
            return current ?? HistoryRecorder.shared
        }
        set {
            os_unfair_lock_lock(HistoryRecorder.hookLock)
            HistoryRecorder.hookStorage = newValue
            os_unfair_lock_unlock(HistoryRecorder.hookLock)
        }
    }
    private static var hookStorage: HistoryRecorder?
    private static let hookLock: UnsafeMutablePointer<os_unfair_lock> = {
        let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        return lock
    }()

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

    /// How much of a hole a launch has to find before it writes a
    /// `NOT_RUNNING` span. Two T0 buckets: anything shorter is the ordinary
    /// gap between the last commit of one run and the first of the next.
    public static let downTimeFloor: TimeInterval = 2 * TimeInterval(HistoryTier.t0.step)

    /// How far the wall clock and the continuous clock may disagree about how
    /// long the app was down before the gap is called a clock step rather than
    /// a quit.
    ///
    /// The two ends of that comparison are not taken at the same instant: the
    /// anchor is read at a commit, while the gap is dated from the bucket after
    /// `lastCommitBucket`, which is up to a whole commit period earlier. So the
    /// comparison is good to a commit period plus a bucket plus §4's own 2 s,
    /// and nothing finer is claimed. Every clock change this is meant to catch
    /// — a DST hour, a timezone, an NTP correction worth noticing — is minutes
    /// or hours, not seconds.
    public static let downTimeTolerance: TimeInterval =
        HistoryRecorder.commitInterval + TimeInterval(HistoryTier.t0.step) + HistoryClock.stepThreshold

    // MARK: - environment

    /// Everything the recorder reads from outside itself. A struct of closures
    /// rather than direct calls so that the clock, the volume's free space and
    /// the power state can be driven from a test: a three-strikes suspension
    /// takes an hour of wall clock to lift and a low-disk skip would otherwise
    /// need a full volume to provoke.
    public struct Environment {
        public var now: () -> TimeInterval
        /// `mach_continuous_time()` in seconds. Injected for the same reason as
        /// the wall clock: a clock step is defined as the two disagreeing, so a
        /// test that cannot move them independently cannot produce one at all.
        public var monotonicNow: () -> TimeInterval
        public var availableSpace: (URL) -> Int64?
        public var isPowerConstrained: () -> Bool

        public init(now: @escaping () -> TimeInterval,
                    availableSpace: @escaping (URL) -> Int64?,
                    isPowerConstrained: @escaping () -> Bool,
                    monotonicNow: @escaping () -> TimeInterval = HistoryClock.monotonicNow) {
            self.now = now
            self.monotonicNow = monotonicNow
            self.availableSpace = availableSpace
            self.isPowerConstrained = isPowerConstrained
        }

        public static let live = Environment(
            now: { Date().timeIntervalSince1970 },
            availableSpace: { HistoryStore.availableSpace(at: $0) },
            isPowerConstrained: HistoryRecorder.isPowerConstrained
        )
    }

    // MARK: - the test host

    /// Whether this process is running an XCTest bundle.
    ///
    /// The `Tests` target is hosted by `Stats.app`, so running the suite
    /// launches the real `AppDelegate` — which starts `shared`, and that alone
    /// creates `~/Library/Application Support/Stats/history`, takes the flock
    /// on it and lays down a year's worth of empty archives in the developer's
    /// own Application Support, on a machine where Stats may never have been
    /// installed. Worse, on a machine where it *is* installed and running, the
    /// test host is then a second writer competing for that lock with the copy
    /// in the menu bar.
    ///
    /// Asked here rather than in `AppDelegate` because the invariant belongs to
    /// this object: the hook, the settings section and `Reset settings` all
    /// reach `shared` too, and a guard at the one call site would leave every
    /// other path free to open the user's archive from a test run. §9's budget
    /// for `AppDelegate` also stays at the two lines it names.
    ///
    /// The environment variable is the reliable half: `xctest` sets it before
    /// the host process starts, which is well before
    /// `applicationDidFinishLaunching`. The class lookup is the fallback for a
    /// bundle injected into a process that was already running.
    public static let isRunningUnderTestHost: Bool = {
        let environment = ProcessInfo.processInfo.environment
        for key in ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]
        where environment[key] != nil {
            return true
        }
        return NSClassFromString("XCTestCase") != nil
    }()

    /// Whether `start` has to refuse. The test host suppresses the *shared*
    /// recorder — the one pointed at the user's own archive — and nothing else:
    /// the suite's own recorders are built on a `HistoryStore` of their own at a
    /// temporary directory, and those have to go on starting, opening and
    /// locking exactly as they do in the app, or the tests would stop covering
    /// the code they exist for.
    private var isSuppressedByTheTestHost: Bool {
        HistoryRecorder.isRunningUnderTestHost && self.store === HistoryStore.shared
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
    /// The recorder's own sleep/wake observers and the span sidecar gaps are
    /// derived from. There is no app-wide observer to reuse — the only two in
    /// the app live in Sensors and Bluetooth (§4).
    private let sleepMonitor: HistorySleepMonitor

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
    /// The wall/continuous pair every sample is measured against (§4). Guarded
    /// by `lock` because it is read and advanced from every reader queue.
    private var clock = HistoryClockTracker()

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
        self.sleepMonitor = HistorySleepMonitor(
            url: store.directory.appendingPathComponent(HistorySleepMonitor.fileName),
            now: environment.now
        )
        self.lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        self.lock.initialize(to: os_unfair_lock())

        // The observers only report; everything they lead to — the span, the
        // flush, the tier reconciliation — is this object's, so that the same
        // path runs whether the event came from `NSWorkspace` or from a test.
        self.sleepMonitor.onSleep = { [weak self] ts in self?.noteWillSleep(at: ts) }
        self.sleepMonitor.onWake = { [weak self] ts in self?.noteDidWake(at: ts) }
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

    /// Where the settings master switch is persisted. `*_state` is the app's
    /// own spelling for a stored toggle (`systemWidgetsUpdates_state`).
    public static let settingsKey: String = "history_state"

    /// The master switch as the user last left it. **ON by default**: a
    /// retrospective feature that is off when the anomaly happens is worthless,
    /// and §3's numbers — ~20 MB at first launch, a hard 244.5 MB ceiling — are
    /// what make that defensible (§6).
    ///
    /// This is the *preference*, not the live state: `isRecording` is what the
    /// hot path reads, and it is false until `start` has actually opened the
    /// archives. The two disagree for the milliseconds of a start, and for as
    /// long as a second copy of Stats holds the flock.
    public static var isEnabledInSettings: Bool {
        get { Store.shared.bool(key: HistoryRecorder.settingsKey, defaultValue: true) }
        set { Store.shared.set(key: HistoryRecorder.settingsKey, value: newValue) }
    }

    /// Master switch, read as the first statement of `ingest`. ON by default:
    /// a retrospective feature that is off when the anomaly happens is
    /// worthless (§6). The value the app starts with is `isEnabledInSettings`,
    /// which is this call's default argument.
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

    /// Every lane the registry holds, in lane-id order — index in the array is
    /// the lane id `query(lanes:)` takes. This is what the window sidebar is
    /// built from: it carries the module byte it groups by, the `label` it
    /// shows, the flags it greys on and the `lastUsedTs` it dates an orphan
    /// from, which is the whole reason the directory entry is 128 B (§3).
    ///
    /// Empty until `start` has adopted the stored directory, so a window opened
    /// with the master switch off shows no lanes rather than lanes nothing is
    /// writing to.
    public var lanes: [HistoryLaneEntry] { self.locked { self.directory.all } }

    /// The registry's own revision, bumped by everything that changes the
    /// directory as the file stores it — a lane registered, a lane reclaimed
    /// for a new identity, a label or a flag rewritten — and deliberately not
    /// by the per-commit touch of `lastUsedTs`.
    ///
    /// The window compares it to decide whether to rebuild its sidebar. A lane
    /// count cannot answer that question: a reclaim swaps one identity for
    /// another without moving the count, and at the 256-lane cap the count
    /// never moves again, so a reclaim there would leave the sidebar naming a
    /// series the chart no longer draws.
    public var laneRevision: UInt64 { self.locked { self.directory.revision } }

    /// Opens the archives, takes the cross-process lock and catches the coarse
    /// tiers up on whatever closed while the app was down. Asynchronous on
    /// purpose: this is file I/O and `applicationDidFinishLaunching` is on main.
    ///
    /// Ticks that arrive while the start is still in flight are dropped:
    /// `recording` is turned on only once the archives are open and the
    /// catch-up has run, because folding into a table whose lane ids are about
    /// to be re-pointed by the stored directory would attribute samples to the
    /// wrong series. A reader tick is one second; the start is milliseconds.
    ///
    /// The default argument is the stored master switch, so `AppDelegate` keeps
    /// the one-line call §9 budgets for it and a switch the user turned off
    /// last week means zero ingest and zero writes from launch — not a recorder
    /// that records until the settings panel is first opened.
    public func start(enabled: Bool = HistoryRecorder.isEnabledInSettings) {
        // Nothing has to be undone to stay idle: a recorder that never started
        // is already not recording, already `.disabled`, holds no lock and has
        // no archive open. Returning before the hop is what keeps it that way.
        guard !self.isSuppressedByTheTestHost else {
            debug("history: the recorder stays idle, this process is an XCTest host")
            return
        }
        // Built here rather than where it is first asked a question. The first
        // question comes from `emitHistory`, which runs on a reader queue with
        // this recorder's lock held, and the initializer reads `Store` — cheap
        // and once, but the one piece of lazy, defaults-reading work that could
        // otherwise land inside the ingest lock.
        _ = HistoryOptionalLanes.shared
        self.queue.async { self.performStart(enabled: enabled) }
    }

    /// Commits what is pending, flushes and closes. The cross-process lock goes
    /// back so a second copy of Stats can take over.
    ///
    /// Must not be called from the history queue.
    public func stop() {
        // Unregistered before the queue rather than on it, because
        // `removeObserver` is Foundation's to schedule and a stop that waits
        // for an observer block which is itself waiting for this queue would
        // be a deadlock of our own making.
        self.sleepMonitor.stop()
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
        // Again, and not redundantly: `start` is asynchronous, so a
        // `start(); stop()` in quick succession can have registered the
        // observers on the history queue while the first call was still
        // looking at an empty array. The `queue.sync` above is the barrier
        // that proves `performStart` has run, and this takes off anything it
        // left behind — observers on a recorder whose archives are closed and
        // whose cross-process lock is released.
        self.sleepMonitor.stop()
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

    // MARK: - deleteAll (quiesce, unmap, unlink, recreate)

    /// Deletes every recorded byte and comes back recording into empty
    /// archives. The Delete button in settings and `Reset settings` are the two
    /// callers (§6).
    ///
    /// Synchronous, and that is a requirement rather than a convenience:
    /// `resetSettings` calls `restartApp` on the next line, and a delete still
    /// in flight would race the relaunch — the new process would take the flock
    /// and open the very files this one is unlinking.
    ///
    /// The sequence is the one §3 and risk 5 ask for, in order. Ingest is
    /// quiesced first, so nothing is folding while the table is emptied. The
    /// staged rows go next: they were drained for archives that are about to
    /// stop existing, and writing them into the empty files that replace them
    /// would resurrect a slice of the history the user just deleted. Only then
    /// are the mappings torn down and the files unlinked, on this queue, with
    /// nothing truncated. The archives reopen empty, and the stored directory
    /// they come back with — none — is what re-points the lane registry, so no
    /// lane id survives into a matrix that has no column for it.
    ///
    /// What is deliberately *not* touched is the `flock` on `history/.lock`:
    /// keeping it is what stops a second copy of Stats from slipping in between
    /// the unlink and the reopen. The master switch is not touched either; a
    /// user who deletes the history is not asking to stop recording it.
    ///
    /// Must not be called from the history queue.
    @discardableResult
    public func deleteAll() -> Bool {
        var deleted = true
        self.queue.sync {
            // The files belong to whoever holds the flock. A copy of Stats that
            // lost the race must not unlink the winner's archives: the winner
            // keeps its descriptors, goes on writing into inodes nothing can
            // open any more, and the disk they cost stays spent until it quits.
            //
            // Asked here rather than before the hop, because `HistoryStore` is
            // the history queue's alone: `performStart` assigns the lock and the
            // open-failure path releases it, so reading it from main would race
            // a start still in flight — and drop the last reference to the
            // `HistoryLock` out from under a caller that had just loaded it.
            guard self.store.holdsLock else {
                error("history: nothing was deleted, the archives are not locked by this process")
                deleted = false
                return
            }

            // The recorder lock, not the store, guards these two — safe on this
            // queue, and an ingest already past `guard self.recording` holds it
            // for its whole fold, so the quiesce is complete before the table is
            // emptied below.
            let enabled = self.isRecording
            self.setRecordingFlag(false)

            self.parkTimerForGood()
            self.table.discardAll()
            deleted = self.store.deleteAll()
            // The sidecar went with the archives; this is what drops the spans
            // still held in memory, which would otherwise be written straight
            // back out on the next sleep.
            self.sleepMonitor.load()

            self.commitCount = 0
            self.consecutiveFailures = 0
            self.suspendedUntil = 0
            self.isLowOnSpace = false
            self.needsFreeSpaceCheck = true
            self.lastRolledUp.removeAll()
            self.appliedRevision = 0
            let now = self.environment.now()
            self.lastSyncTs = now
            self.lastDirectoryWriteTs = now

            do {
                try self.store.open(preset: self.preset)
            } catch let failure {
                error("history: the archives could not be reopened after a delete: \(failure)")
                self.setStatus(.writeFailures)
                deleted = false
                return
            }

            self.locked { self.directory.adopt([]) }
            self.setRecordingFlag(enabled)
            self.setStatus(enabled ? .recording : .disabled)
        }
        return deleted
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
        self.locked { self.clock.anchor(wall: now, monotonic: self.environment.monotonicNow()) }
        // Loads the sidecar and registers the willSleep/didWake observers.
        self.sleepMonitor.start()

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

        // What the clock did while the app was down. The span is taken first:
        // it is dated from the stored `lastCommitBucket`, which a reset is
        // about to put back to zero, and a downtime long enough to strand a
        // tier is exactly the one worth naming (§4).
        self.noteDownTime(at: now)
        self.resetTiersStrandedByTheClock(at: now)

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
    ///
    /// `reader` is an `@autoclosure` so that the master switch really does cost
    /// a branch and nothing else. The call site has no key lying around to pass
    /// — `Reader.name` is `NSStringFromClass(type(of: self))` split and rebuilt
    /// on every access — and an eagerly evaluated argument would pay for that
    /// string on every tick of every reader in the app with recording off,
    /// which is exactly what §2 promises it does not do.
    public func ingest<T>(_ value: T, reader: @autoclosure () -> HistoryReaderKey,
                          interval: TimeInterval? = nil) {
        var stepped: (step: HistoryClockStep, at: TimeInterval)?
        var wake = false
        self.locked { () -> Void in
            guard self.recording else { return }
            guard let provider = value as? HistoryProvider else { return }

            // `isFinite` as well as positive: the conversion on the next line
            // traps on an infinity, and the clock is injectable.
            let now = self.environment.now()
            guard now > 0, now.isFinite else { return }

            // §4: the continuous clock is read alongside the wall clock here,
            // inside the bucket computation — not once per commit, which would
            // let a whole commit period of samples land in the wrong bucket
            // before anything noticed. The bucket index itself is recomputed by
            // the accumulator table from the same `now`; what this call is for
            // is the divergence the table cannot see.
            let reading = self.clock.bucket(at: now, step: HistoryTier.t0.step,
                                            monotonic: self.environment.monotonicNow())
            if reading.step.isStep { stepped = (reading.step, now) }
            // A backward step makes every bucket index the table holds a future
            // one, and a table clamped to a future bucket records nothing at
            // all. It has to be dropped between detecting the step and folding
            // the sample that detected it.
            if case .backward = reading.step { self.table.resetForClockStep() }

            self.sink.prepare(registry: self, at: UInt64(now))
            provider.emitHistory(reader: reader(), into: &self.sink)
            guard !self.sink.isEmpty else { return }

            self.table.fold(self.sink, at: now, interval: interval ?? 0)
            guard !self.timerWanted else { return }
            self.timerWanted = true
            wake = true
        }
        if let stepped = stepped {
            self.queue.async { self.handleClockStep(stepped.step, at: stepped.at) }
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

        // Cheap enough to run every cycle — one bucket index and one comparison
        // per tier — and it has to run somewhere the app is not restarting: a
        // machine left asleep for a week reaches this before it reaches a
        // relaunch (§4).
        self.resetTiersStrandedByTheClock(at: now)

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
        let rows = HistoryRecorder.rowsClearOfThePreStepEra(self.table.drain(before: currentBucket, lanes: lanes),
                                                            in: t0)
        guard !rows.isEmpty else { return }
        // The anchor and `lastCommitBucket` are only meaningful as a pair, so
        // it is staged into the header the commit below is about to write
        // rather than written beside it (§4).
        t0.stageMonotonicAnchor(UInt64(Swift.max(0, self.environment.monotonicNow())))
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
        rows = HistoryRecorder.rowsClearOfThePreStepEra(rows, in: archive)
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

    // MARK: - sleep, wake and the clock (§4)

    /// The spans gap reasons are derived from: sleeps the observers saw, the
    /// stretches launches found between a last commit and a first one, and the
    /// stretches a clock step moved the wall clock across.
    public var gapSpans: [HistoryGapSpan] { self.sleepMonitor.spans }

    /// What a read of one lane needs to turn an empty bucket into a sentence:
    /// the lane's `firstValidBucket`, the tier's `lastCommitBucket` and the
    /// spans. Snapshotted together, because a resolver built from a mixture of
    /// two commits' bookkeeping could contradict itself.
    ///
    /// Must not be called from the history queue.
    public func gapResolver(tier: HistoryTier, lane: Int) -> HistoryGapResolver? {
        let spans = self.sleepMonitor.spans
        return self.queue.sync { () -> HistoryGapResolver? in
            guard let archive = self.store.archive(tier), let entry = archive.entry(lane: lane) else { return nil }
            return HistoryGapResolver(step: tier.step, firstValidBucket: entry.firstValidBucket,
                                      lastCommitBucket: archive.lastCommitBucket, spans: spans)
        }
    }

    // MARK: - read-side query (columns for the chart)

    // There is deliberately no synchronous "just the plan" accessor here. The
    // column geometry is the same whether or not a lane has anything in it, so
    // one looked worth having for the empty sidebar selection — but resolving
    // it needs `store.openTiers`, and reaching that means `queue.sync` on the
    // queue that also creates the archives, commits every 60 s, `fsync`s every
    // ten minutes and reads up to 40 MB of T2 for a year. §7 budgets main for
    // none of that. `query(lanes: [], …)` below answers the same question
    // asynchronously: it plans against the same open tiers and returns an
    // empty lane list.

    /// Reads a range for a set of lanes and hands the answer to `completion` on
    /// main.
    ///
    /// Asynchronous on purpose. §7 budgets the first paint at < 50 ms and puts
    /// the aggregation "on the history queue", because a 1-year read is a
    /// 15–40 MB pass over a mapped file and main is where the app draws; the
    /// completion carries ~1,460 columns per lane and never the decoded series.
    /// The queue is the same one the commit timer runs on, so a read waits for
    /// at most one commit rather than contending with it.
    ///
    /// Must not be called from the history queue.
    public func query(lanes: [Int], range: HistoryRange,
                      maxColumns: Int = HistoryColumnPlan.columnCap, at now: TimeInterval? = nil,
                      completion: @escaping (HistoryQueryResult) -> Void) {
        let when = now ?? self.environment.now()
        let spans = self.sleepMonitor.spans
        self.queue.async {
            let plan = HistoryColumnPlan.plan(for: range, endingAt: when, maxColumns: maxColumns,
                                              tiers: self.store.openTiers)
            let result = self.store.query(lanes: lanes, plan: plan, spans: spans)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// The same read, answered inline. For the CSV export and for tests, which
    /// need the answer where they stand; the chart uses the asynchronous form.
    ///
    /// Must not be called from the history queue.
    public func query(lanes: [Int], range: HistoryRange,
                      maxColumns: Int = HistoryColumnPlan.columnCap,
                      at now: TimeInterval? = nil) -> HistoryQueryResult {
        let when = now ?? self.environment.now()
        let spans = self.sleepMonitor.spans
        return self.queue.sync {
            let plan = HistoryColumnPlan.plan(for: range, endingAt: when, maxColumns: maxColumns,
                                              tiers: self.store.openTiers)
            return self.store.query(lanes: lanes, plan: plan, spans: spans)
        }
    }

    /// The machine is going to sleep. Opens the span, commits what the
    /// accumulators hold and flushes — §3's "fsync on sleep" — then gives the
    /// timer up, because nothing will tick until the next sample after wake and
    /// a timer left armed across a nine-hour sleep is a wakeup the feature does
    /// not need.
    ///
    /// Synchronous: a handler that returns before the data is on disk has not
    /// flushed anything, and `NSWorkspace.willSleepNotification` is delivered
    /// with time in hand for exactly this.
    ///
    /// Must not be called from the history queue.
    public func noteWillSleep(at ts: TimeInterval) {
        self.sleepMonitor.noteSleep(at: ts)
        self.queue.sync {
            self.commit(at: ts)
            self.store.sync()
            self.lastSyncTs = ts
            self.parkTimerForGood()
        }
    }

    /// The machine woke. Closes the span and looks at what the sleep did to the
    /// tiers — a sleep longer than T0's 24 h leaves its whole ring stale.
    ///
    /// The clock tracker is deliberately *not* re-anchored: `mach_continuous_time`
    /// counts through sleep, so the two clocks still agree and a wake is not a
    /// step. Re-anchoring here would be the one thing that could hide a genuine
    /// clock change made while the machine was asleep, which is when a timezone
    /// or NTP correction is most likely to land.
    public func noteDidWake(at ts: TimeInterval) {
        self.sleepMonitor.noteWake(at: ts)
        self.queue.async { self.resetTiersStrandedByTheClock(at: ts) }
    }

    /// A clock step, on the history queue.
    ///
    /// A **forward** step needs no action on the archive: the ring advances and
    /// the slots it skipped read as no-data by their stamps. What it does need
    /// is the span, because "Clock changed" is otherwise indistinguishable from
    /// "nothing was recorded" — and a span is a line in a sidecar, not a pass
    /// over a ring.
    ///
    /// A **backward** step resets the tiers it stepped clean past and leaves
    /// the rest to `rowsClearOfThePreStepEra`, which is what keeps the re-lived
    /// buckets' pre-step slots. The accumulator table was already dropped, at
    /// ingest, under the lock.
    private func handleClockStep(_ step: HistoryClockStep, at now: TimeInterval) {
        switch step {
        case .none:
            return
        case .forward(let delta):
            // The stretch the wall clock jumped over: nothing was recorded in
            // it and nothing ever will be.
            self.noteSpan(from: now - delta, to: now, reason: .clockStep)
        case .backward(let delta):
            // The stretch that is about to be re-lived. It already holds
            // pre-step data, so the span is what says why the two eras meet
            // where they do.
            self.noteSpan(from: now, to: now + delta, reason: .clockStep)
            // Coarse-tier scan cursors are bucket indices from the era that
            // just ended.
            self.lastRolledUp.removeAll()
        }
        self.resetTiersStrandedByTheClock(at: now)
    }

    /// Resets any tier the clock has moved at least a whole ring away from.
    ///
    /// This is both of §4's reset rules, which turn out to be one condition: a
    /// backward step larger than a tier's window, and a gap at or beyond that
    /// tier's capacity. Either way every slot in the ring belongs to another
    /// era, and §4 is explicit that the answer is to reset the tier rather than
    /// to iterate the ring writing no-data into 17,520 rows.
    private func resetTiersStrandedByTheClock(at now: TimeInterval) {
        for tier in self.preset.tiers {
            guard let archive = self.store.archive(tier), archive.laneCount > 0 else { continue }
            let last = archive.lastCommitBucket
            guard last > 0 else { continue }
            let current = HistoryClock.bucketIndex(now, step: tier.step)
            let distance = current >= last ? current - last : last - current
            guard distance >= UInt32(tier.buckets) else { continue }

            do {
                try archive.discardAll()
                error("history: \(tier.fileName) reset, the clock moved \(distance) buckets past its \(tier.buckets)-bucket ring")
                self.lastRolledUp[tier] = nil
                // `reconcile` takes `firstValidBucket` from the archive's own
                // copy, so the registry cannot write a stale one back over the
                // reset. What it can do is keep serving one to everything else
                // that reads the registry — the sidebar, the LRU — so the
                // registry is corrected below, and the applied revision is
                // dropped so that the correction reaches all three tier files
                // at the next commit rather than at the next lane change.
                self.appliedRevision = 0
                if tier == .t0 {
                    self.locked {
                        for lane in 0..<archive.laneCount {
                            self.directory.setFirstValidBucket(HistoryLaneEntry.noValidBucket, lane: lane)
                        }
                    }
                }
            } catch let failure {
                self.recordFailure(failure)
                // A reset that throws can leave the tier unusable rather than
                // merely unreset: `discardAll` closes the file before it
                // recreates it, and the directory write at the end of it goes
                // through `rebuild`, whose own failure path resets the archive
                // to no lanes at all. Neither state announces itself — the
                // archive still answers `store.archive(tier)`, `commitT0` and
                // the rollup both return early on an empty lane count, and the
                // guard at the top of this loop skips a laneless tier forever,
                // so the tier would record nothing until the next launch while
                // the status still read "recording". A tier that did not come
                // back from its reset is therefore dropped outright, which is
                // the one outcome every caller already handles, and the status
                // says so instead of waiting for two more strikes.
                guard !archive.isOpen || archive.laneCount == 0 else { continue }
                error("history: \(tier.fileName) did not come back from its reset and is closed")
                self.store.drop(tier)
                self.lastRolledUp[tier] = nil
                self.setStatus(.writeFailures)
            }
        }
    }

    /// The hole a launch finds between the last commit of the previous run and
    /// now, as a span. This is the whole of "Stats was not running": §2 has no
    /// notification to hang it on, and §4 says it follows from
    /// `lastCommitBucket` — which is exactly what this reads.
    ///
    /// It is also the one place the stored monotonic anchor earns its four
    /// bytes. If the continuous clock has not gone backwards since the anchor
    /// was written, the machine did not reboot, and the two clocks can be
    /// compared across the downtime: a wall-clock gap that the continuous clock
    /// does not agree with means the clock was set while Stats was down, and
    /// the span says so rather than blaming the app for being closed.
    private func noteDownTime(at now: TimeInterval) {
        guard let t0 = self.store.archive(.t0), t0.lastCommitBucket > 0 else { return }
        // The last commit closed that bucket, so the run reached at least its
        // end; dating the gap from there rather than from its start keeps the
        // span off a bucket that has data in it.
        let last = HistoryClock.bucketStart(t0.lastCommitBucket &+ 1, step: HistoryTier.t0.step)

        // The clock went backwards while the app was down: the stretch between
        // the two is not downtime at all, it is a region that already holds
        // pre-step data.
        guard now > last else {
            self.noteSpan(from: now, to: last, reason: .clockStep)
            return
        }
        guard now - last > HistoryRecorder.downTimeFloor else { return }

        var reason: HistoryGapReason = .notRunning
        let anchor = TimeInterval(t0.monotonicAnchor)
        let monotonic = self.environment.monotonicNow()
        if anchor > 0, monotonic >= anchor,
           abs((now - last) - (monotonic - anchor)) > HistoryRecorder.downTimeTolerance {
            reason = .clockStep
        }
        self.noteSpan(from: last, to: now, reason: reason)
    }

    private func noteSpan(from: TimeInterval, to: TimeInterval, reason: HistoryGapReason) {
        guard from > 0, from.isFinite, to.isFinite, to > from else { return }
        self.sleepMonitor.note(HistoryGapSpan(from: UInt64(from), to: UInt64(to), reason: reason))
    }

    /// Drops the rows a backward clock step would have overwritten pre-step
    /// slots with (§4).
    ///
    /// `lastCommitBucket` never moves backwards, so it is the high-water mark
    /// of every era the archive has lived through: a row at or below it whose
    /// ring cell already carries that exact bucket stamp is a cell the pre-step
    /// era wrote, and this is where the rule that it is never overwritten
    /// lives — the archive itself has no notion of an era to filter on, and
    /// says so.
    ///
    /// In forward-running time the first comparison settles it: the drain only
    /// ever hands up buckets past the high-water mark, so the common path is
    /// one `UInt32` compare per commit and no stamp reads at all.
    ///
    /// What that costs, stated plainly because it is a behaviour and not an
    /// implementation detail: for the length of a backward step **no tier
    /// records anything at all**. The re-lived buckets are exactly the ones
    /// the pre-step era stamped, so every row the drain hands up is dropped
    /// here, on T0 and on the coarse tiers alike, until the wall clock has
    /// caught back up to the high-water mark. A clock set back an hour is
    /// therefore an hour of no-data, with the `CLOCK_STEP` span the reason
    /// the chart shows for it. §4 takes that trade deliberately: the
    /// alternative is two eras interleaved in one ring with no way to tell
    /// which measurement belongs to which.
    private static func rowsClearOfThePreStepEra(_ rows: [HistoryRow], in archive: HistoryArchive) -> [HistoryRow] {
        let highWater = archive.lastCommitBucket
        guard highWater > 0, rows.contains(where: { $0.bucket <= highWater }) else { return rows }

        let lanes = archive.laneCount
        return rows.filter { row in
            guard row.bucket <= highWater else { return true }
            for lane in 0..<lanes where archive.stamp(bucket: row.bucket, lane: lane) == row.bucket {
                return false
            }
            return true
        }
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
