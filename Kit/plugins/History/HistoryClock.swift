//
//  HistoryClock.swift
//  Kit
//
//  Persistent usage history: bucket indexing, clock-step detection and the
//  sleep/wake spans gaps are derived from.
//  Design: docs/usage-history-design.md (§4 Time handling), exelban/stats#1194.
//

import Cocoa
import os

// MARK: - clock

/// Buckets are indexed by wall clock (`floor(epoch / step)`) so that "03:10
/// last Tuesday" is answerable. `mach_continuous_time()` is read alongside the
/// wall clock inside the bucket computation — not once per commit — so a step
/// cannot land a whole period of samples in the wrong bucket.
public struct HistoryClock {
    /// Wall/monotonic divergence beyond this many seconds means the clock stepped.
    public static let stepThreshold: TimeInterval = 2

    public init() {}

    // MARK: - bucketIndex(ts:step:)

    /// `floor(epoch / step)`. Wall-clock aligned and shared by every reader, so
    /// a 1 s and a 60 s reader land on the same grid and a runtime `setInterval`
    /// is a non-event (§2). Negative timestamps — a clock set before 1970, or an
    /// interval subtracted off a fresh boot clock — floor to bucket 0 rather
    /// than wrapping a `UInt32` around.
    public static func bucketIndex(_ ts: TimeInterval, step: Int) -> UInt32 {
        guard ts > 0, step > 0 else { return 0 }
        let index = (ts / Double(step)).rounded(.down)
        guard index.isFinite, index > 0 else { return 0 }
        return index >= Double(UInt32.max) ? UInt32.max : UInt32(index)
    }

    /// The wall-clock second a bucket starts at: the inverse of `bucketIndex`,
    /// and what the step-lane hold compares against `holdUntil` (§2).
    public static func bucketStart(_ bucket: UInt32, step: Int) -> TimeInterval {
        TimeInterval(bucket) * TimeInterval(step)
    }

    // MARK: - monotonic anchor and divergence check

    /// `mach_continuous_time()` in seconds.
    ///
    /// *Continuous*, not absolute: it keeps counting while the machine is
    /// asleep. That is the whole reason this is the reference clock — a
    /// nine-hour sleep advances the wall clock by nine hours, and with
    /// `mach_absolute_time()` the two would diverge by exactly that much and
    /// every wake would be reported as a clock step. With the continuous clock
    /// the two agree across sleep, and what is left over really is the clock
    /// having been set.
    public static func monotonicNow() -> TimeInterval {
        TimeInterval(mach_continuous_time()) * HistoryClock.tick
    }

    /// Seconds per `mach_continuous_time()` tick. Queried once; the fallback is
    /// the 1 ns/tick that every Apple Silicon and Intel Mac actually reports,
    /// which keeps a failed `mach_timebase_info` from making the clock useless.
    private static let tick: TimeInterval = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0, info.numer != 0 else { return 1e-9 }
        return Double(info.numer) / Double(info.denom) * 1e-9
    }()
}

/// What the wall clock did between two samples, measured against the
/// continuous clock (§4).
public enum HistoryClockStep: Equatable {
    case none
    /// The wall clock jumped ahead. The ring simply advances and the slots it
    /// skipped read as no-data by their stamps, so nothing is written.
    case forward(TimeInterval)
    /// The wall clock jumped back. Slots already stamped with the buckets that
    /// are about to be re-lived belong to the pre-step era and are never
    /// overwritten; a step larger than a tier's window resets that tier.
    case backward(TimeInterval)

    /// The size of the step, always positive. Zero when there was none.
    public var seconds: TimeInterval {
        switch self {
        case .none: return 0
        case .forward(let delta), .backward(let delta): return delta
        }
    }

    public var isStep: Bool { self != .none }
}

/// Pairs the wall clock with the continuous one and reports what the wall clock
/// did between two readings.
///
/// A value type with no clock of its own: both readings are passed in, because
/// the recorder takes them under its lock and a test drives them outright.
public struct HistoryClockTracker {
    public private(set) var wall: TimeInterval = 0
    public private(set) var monotonic: TimeInterval = 0
    public private(set) var isAnchored: Bool = false

    public init() {}

    /// Takes the pair as the new reference without reporting a step. What
    /// `start()` does, and what the first sample of a run does implicitly.
    public mutating func anchor(wall: TimeInterval, monotonic: TimeInterval) {
        guard wall > 0, wall.isFinite, monotonic.isFinite else { return }
        self.wall = wall
        self.monotonic = monotonic
        self.isAnchored = true
    }

    /// The step, if any, between the anchor and this pair — and then this pair
    /// becomes the anchor.
    ///
    /// Re-anchoring on *every* reading rather than on a step is what keeps slew
    /// from being mistaken for a step: `ntpd` disciplines the wall clock by a
    /// few milliseconds a minute, which against a fixed anchor would cross the
    /// 2 s threshold after some hours of uptime and report a clock step that
    /// never happened. Against the previous reading it never accumulates.
    public mutating func observe(wall: TimeInterval, monotonic: TimeInterval) -> HistoryClockStep {
        guard wall > 0, wall.isFinite, monotonic.isFinite else { return .none }
        guard self.isAnchored else {
            self.anchor(wall: wall, monotonic: monotonic)
            return .none
        }

        let elapsed = monotonic - self.monotonic
        let divergence = wall - (self.wall + elapsed)
        self.anchor(wall: wall, monotonic: monotonic)

        // A continuous clock that went backwards is not something the wall
        // clock did, and there is no sound way to measure a step against it.
        guard elapsed >= 0 else { return .none }
        guard Swift.abs(divergence) > HistoryClock.stepThreshold else { return .none }
        return divergence > 0 ? .forward(divergence) : .backward(-divergence)
    }

    /// The bucket a sample belongs to, and what the wall clock did to get
    /// there — one call, because §4 wants the continuous clock read *inside*
    /// the bucket computation. Reading it once per commit instead would let a
    /// whole commit period of accumulators land in the wrong bucket before
    /// anything noticed.
    public mutating func bucket(at wall: TimeInterval, step: Int,
                                monotonic: TimeInterval) -> (bucket: UInt32, step: HistoryClockStep) {
        let stepped = self.observe(wall: wall, monotonic: monotonic)
        return (HistoryClock.bucketIndex(wall, step: step), stepped)
    }
}

// MARK: - sleep spans

/// A span of wall-clock time with no samples and a known reason.
///
/// Half-open, `[from, to)`, so two adjacent spans cannot both claim the second
/// they meet at. `to == from` is a span that was opened and never closed — a
/// sleep the machine never woke from into this process — and covers nothing.
public struct HistoryGapSpan: Equatable {
    public let from: UInt64
    public let to: UInt64
    public let reason: HistoryGapReason

    public init(from: UInt64, to: UInt64, reason: HistoryGapReason) {
        self.from = from
        self.to = to
        self.reason = reason
    }

    public var isOpen: Bool { self.to <= self.from }

    public func covers(_ ts: UInt64) -> Bool {
        ts >= self.from && ts < self.to
    }

    /// Whether the span covers any part of a bucket. A bucket is the wall-clock
    /// interval `[start, start + step)`, and a gap that swallows half of it is
    /// still the answer to "why is this column empty".
    public func covers(bucket: UInt32, step: Int) -> Bool {
        guard step > 0, self.to > self.from else { return false }
        let start = UInt64(bucket) * UInt64(step)
        return start < self.to && start &+ UInt64(step) > self.from
    }
}

/// Records sleep and wake spans into a small sidecar, age-capped to T2
/// retention. There is no app-wide sleep/wake observer today — the only ones
/// live in Sensors and Bluetooth — so the recorder registers its own (§4).
///
/// The observers only *report*: every span the file holds is written by the
/// recorder, which is also what decides that a launch found a gap or that the
/// clock stepped. Keeping the bookkeeping on one side is what lets a test drive
/// the whole path without an `NSWorkspace` notification.
public final class HistorySleepMonitor {
    /// The sidecar. Not a tier file: no ring, no preallocation, no mapping —
    /// records that are read once at open and rewritten whole whenever one
    /// changes.
    ///
    /// Rewriting the whole file is affordable because the file is small, and
    /// §3 carries the arithmetic rather than a promise: one record per
    /// sleep/wake pair plus one per launch, age-capped to T2's 365 days, is a
    /// few thousand records — under 200 KiB — for a laptop that sleeps twenty
    /// times a day, against an archive budget of 244.5 MB.
    public static let fileName: String = "spans.bin"

    /// Spans older than T2's window answer a question no tier can ask. §4 caps
    /// by age and explicitly not by line count: a machine that sleeps twenty
    /// times a day must not lose last month's nine-hour sleep to this month's
    /// naps.
    public static var retention: TimeInterval {
        TimeInterval(HistoryTier.t2.buckets) * TimeInterval(HistoryTier.t2.step)
    }

    /// Hexdumps as "STSP" under the little-endian encoding below.
    private static let magic: UInt32 = 0x5053_5453
    private static let formatVersion: UInt32 = 1
    private static let headerWidth: Int = 16
    private static let recordWidth: Int = 24
    /// Not a retention policy — see `retention` — but a bound on what a damaged
    /// count field can make this allocate before the record count is checked
    /// against the file's actual length.
    private static let decodeCeiling: Int = 1 << 16

    public let url: URL
    private let now: () -> TimeInterval

    /// Guards `stored` and `observers`. The observers fire on main, the gap
    /// derivation reads from the history queue, `start()` runs on the history
    /// queue and `stop()` on whatever thread asked the recorder to stop — so
    /// the observer array is written from two threads too, and an
    /// unsynchronized `Array` write is a data race whatever it holds.
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var stored: [HistoryGapSpan] = []
    private var observers: [NSObjectProtocol] = []

    /// Serializes the sidecar writes, which happen with `lock` released, and
    /// guards `writtenRevision` alongside them.
    private let writeLock: UnsafeMutablePointer<os_unfair_lock>
    private var revision: UInt64 = 0
    private var writtenRevision: UInt64 = 0

    /// Set before `start()`, called on main from the `NSWorkspace` observers.
    public var onSleep: ((TimeInterval) -> Void)?
    public var onWake: ((TimeInterval) -> Void)?

    public init(url: URL, now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        self.url = url
        self.now = now
        self.lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        self.lock.initialize(to: os_unfair_lock())
        self.writeLock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        self.writeLock.initialize(to: os_unfair_lock())
    }

    deinit {
        self.stop()
        self.lock.deinitialize(count: 1)
        self.lock.deallocate()
        self.writeLock.deinitialize(count: 1)
        self.writeLock.deallocate()
    }

    @inline(__always)
    private func locked<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(self.lock)
        defer { os_unfair_lock_unlock(self.lock) }
        return body()
    }

    // MARK: - NSWorkspace willSleep / didWake observers

    /// Loads the sidecar and registers the observers. Idempotent.
    ///
    /// `NSWorkspace.shared.notificationCenter` is the only centre these two
    /// notifications are posted on — `NotificationCenter.default` never sees
    /// them — and the block form is used so the observers can be dropped
    /// individually without an `NSObject` subclass.
    public func start() {
        // Both halves are idempotent, and the load is inside the guard on
        // purpose: a second `start()` must not re-read the file over a sleep
        // this process has open, which `load()` would then discard as one it
        // did not open.
        guard self.locked({ self.observers.isEmpty }) else { return }
        self.load()

        let center = NSWorkspace.shared.notificationCenter
        let registered: [NSObjectProtocol] = [
            center.addObserver(forName: NSWorkspace.willSleepNotification,
                               object: nil, queue: .main) { [weak self] _ in
                guard let self = self else { return }
                self.onSleep?(self.now())
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification,
                               object: nil, queue: .main) { [weak self] _ in
                guard let self = self else { return }
                self.onWake?(self.now())
            }
        ]
        // Registering is done outside the lock — `addObserver` is Foundation's
        // code, not ours — and the array is swapped in under it, so a second
        // `start()` that raced this one takes its own pair straight back off
        // instead of leaking it. A `stop()` that lands in the same window
        // cannot be caught here, because it leaves exactly the empty array
        // this swap expects; `HistoryRecorder.stop()` closes that one by
        // calling `stop()` again once the history queue has drained.
        let unwanted: [NSObjectProtocol] = self.locked { () -> [NSObjectProtocol] in
            guard self.observers.isEmpty else { return registered }
            self.observers = registered
            return []
        }
        for observer in unwanted {
            center.removeObserver(observer)
        }
    }

    public func stop() {
        let registered = self.locked { () -> [NSObjectProtocol] in
            let current = self.observers
            self.observers.removeAll()
            return current
        }
        let center = NSWorkspace.shared.notificationCenter
        for observer in registered {
            center.removeObserver(observer)
        }
    }

    // MARK: - span sidecar (append, age-cap, load at open)

    /// Everything the sidecar holds, oldest first.
    public var spans: [HistoryGapSpan] { self.locked { self.stored } }

    /// Opens a sleep span. Persisted immediately and left open: a machine that
    /// is shut down while asleep never posts `didWake`, and a sleep that is
    /// known to have started is worth more than one that was never recorded.
    public func noteSleep(at ts: TimeInterval) {
        guard ts > 0, ts.isFinite else { return }
        self.change {
            // A second willSleep with no wake between them is the same sleep.
            guard self.openSpanLocked() == nil else { return false }
            self.insertLocked(HistoryGapSpan(from: UInt64(ts), to: UInt64(ts), reason: .asleep))
            return true
        }
    }

    /// Closes the open sleep span. A wake with nothing open — the app launched
    /// while the machine was already awake — records nothing.
    public func noteWake(at ts: TimeInterval) {
        guard ts > 0, ts.isFinite else { return }
        self.change {
            guard let index = self.openSpanLocked() else { return false }
            let open = self.stored[index]
            // A wake in the same whole second the sleep opened is a sleep that
            // did not happen, and it is dropped rather than closed. macOS posts
            // `willSleep` and then `didWake` sub-second on an aborted or vetoed
            // sleep and on a short dark wake, and both timestamps truncate to
            // the same integer second here. Writing `[from, from)` back would
            // leave the span *open* — `isOpen` is `to <= from` — and an open
            // span this process can no longer close would then make `noteSleep`
            // refuse every later sleep for the life of the run: no "Asleep" for
            // the rest of the session, a record that ages out by its start a
            // year later, and nothing to clear it before the next launch's
            // `load()`. Dropping it is also the honest answer, because nothing
            // was asleep for a stretch any bucket could show.
            guard UInt64(ts) > open.from else {
                self.stored.remove(at: index)
                return true
            }
            // Closing a span does not move its `from`, so the sort order the
            // array is kept in survives the write.
            self.stored[index] = HistoryGapSpan(from: open.from, to: UInt64(ts), reason: .asleep)
            return true
        }
    }

    /// The sleep *this process* opened and has not closed, if there is one.
    ///
    /// There is at most one: `noteSleep` refuses to open a second, `noteWake`
    /// always disposes of the one it finds, and `load()` drops the ones this
    /// process did not open. It is not necessarily the last element — the array
    /// is kept sorted by `from`, and a derived span dated after the sleep began
    /// sorts past it — so it is searched for rather than assumed.
    private func openSpanLocked() -> Int? {
        self.stored.lastIndex { $0.isOpen }
    }

    /// Adds a span and restores the order the array is documented to be in.
    ///
    /// Both callers need the sort, not just `note()`: after a backward clock
    /// step the recorder derives a span dated at the *post*-step wall clock, so
    /// a sleep opened later can have the smaller `from` of the two. Nothing
    /// depends on the order inside this type — `decode` sorts, and
    /// `openSpanLocked` searches — but `HistoryRecorder.gapSpans` is public and
    /// says "oldest first", and the sort is a few thousand elements a few times
    /// a day.
    private func insertLocked(_ span: HistoryGapSpan) {
        self.stored.append(span)
        self.stored.sort { $0.from < $1.from }
    }

    /// Records a closed span the recorder derived rather than observed: the
    /// stretch a launch found between the last commit and now, and the stretch
    /// a clock step moved the wall clock across (§4).
    public func note(_ span: HistoryGapSpan) {
        guard span.to > span.from else { return }
        self.change {
            self.insertLocked(span)
            return true
        }
    }

    /// Reads the sidecar. A file that is missing, short, or does not decode is
    /// simply no spans: history degrades, the app does not (§1), and the worst
    /// a lost sidecar costs is a gap that reads "no data" instead of "asleep".
    ///
    /// **A process cannot close a sleep it did not open**, so the open spans in
    /// the file are dropped rather than restored. An open span on disk is a
    /// sleep the previous process never saw the end of — the machine was shut
    /// down, ran the battery flat or was force-rebooted while asleep — and
    /// restoring it would hand the *next* `didWake` a span from another era to
    /// close, turning one night's sleep into an "Asleep" that covers whole days
    /// the machine was awake for, over buckets whose honest answer is no-data.
    /// Next to nothing is lost by dropping it: `HistoryRecorder.noteDownTime`
    /// writes a span across the whole hole between the last commit and this
    /// launch, which is the stretch the open sleep sat in. It is `NOT_RUNNING`
    /// unless the two clocks disagree across the downtime, in which case
    /// `CLOCK_STEP` is the better answer anyway, and there are two holes it
    /// leaves alone: one on an install that never committed, where there is no
    /// last commit to date a span from, and one shorter than two T0 buckets,
    /// which no column can show.
    public func load() {
        let decoded = HistorySleepMonitor.decode(HistorySleepMonitor.read(self.url))
        self.locked {
            self.stored = decoded.filter { !$0.isOpen }
            self.ageCapLocked()
        }
    }

    /// Drops spans that fell out of T2's window. Age, never line count.
    ///
    /// An open span has no end to age out by, so it ages by its start. Without
    /// that it would be immortal: `note()` can sort a newer derived span past
    /// the open one, so "it is always last and always this process's" does not
    /// hold, and an exempt open span would accumulate for the life of the
    /// install.
    private func ageCapLocked() {
        let floor = self.now() - HistorySleepMonitor.retention
        guard floor > 0 else { return }
        let cutoff = UInt64(floor)
        self.stored.removeAll { Swift.max($0.from, $0.to) < cutoff }
    }

    /// Applies a change to `stored` under the lock and writes the sidecar with
    /// the lock *released*, when the change reports that there was one.
    ///
    /// `Data.write(options: .atomic)` is a temporary file, a write and a
    /// rename — a filesystem round trip — and `spans` is read from main through
    /// `HistoryRecorder.gapResolver`. Holding an `os_unfair_lock` across that
    /// would park a UI read behind a disk write for its whole duration, so only
    /// the encode happens under it.
    ///
    /// Two changes can then reach the file out of order, which an ordinary
    /// last-writer-wins would resolve by leaving the *older* image on disk. So
    /// every encode takes a revision, the writes are serialized on their own
    /// lock, and one older than what is already written is dropped: the newer
    /// image is the one both callers wanted there.
    private func change(_ body: () -> Bool) {
        var pending: (revision: UInt64, bytes: [UInt8])?
        self.locked {
            guard body() else { return }
            self.ageCapLocked()
            self.revision &+= 1
            pending = (self.revision, HistorySleepMonitor.encode(self.stored))
        }
        guard let pending = pending else { return }
        self.persist(revision: pending.revision, bytes: pending.bytes)
    }

    private func persist(revision: UInt64, bytes: [UInt8]) {
        os_unfair_lock_lock(self.writeLock)
        defer { os_unfair_lock_unlock(self.writeLock) }
        guard revision > self.writtenRevision else { return }
        self.writtenRevision = revision
        do {
            try Data(bytes).write(to: self.url, options: .atomic)
        } catch let failure {
            // The sidecar is an accessory to the archive, so a failure here
            // downgrades a gap reason and nothing else. It is not a write
            // failure the three-strikes rule should count.
            error("history: the sleep span sidecar could not be written: \(failure)")
        }
    }

    // MARK: - encoding (16 B header, 24 B records, little-endian)

    private static func encode(_ spans: [HistoryGapSpan]) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: headerWidth + spans.count * recordWidth)
        HistoryBytes.put(magic, into: &buffer, at: 0)
        HistoryBytes.put(formatVersion, into: &buffer, at: 4)
        HistoryBytes.put(UInt32(spans.count), into: &buffer, at: 8)
        for (index, span) in spans.enumerated() {
            let offset = headerWidth + index * recordWidth
            HistoryBytes.put(span.from, into: &buffer, at: offset)
            HistoryBytes.put(span.to, into: &buffer, at: offset + 8)
            buffer[offset + 16] = span.reason.rawValue
        }
        return buffer
    }

    /// The bytes to decode, or nothing when the file could not hold a sidecar
    /// this format can describe.
    ///
    /// The size is checked *before* the read, because `decodeCeiling` bounds
    /// the span array and not the read: without this a garbage or hostile
    /// `spans.bin` of any size is materialized whole, and then copied a second
    /// time into `[UInt8]`, before a single field has been looked at. A file
    /// longer than the ceiling is read *up to* it rather than rejected: the
    /// ceiling exists to bound an allocation, and the age cap runs before every
    /// write, so a sidecar that reached it is either damaged — in which case the
    /// header check is what rejects it — or a year of genuinely relentless
    /// sleeping, and losing every span in it is strictly worse than losing the
    /// tail.
    private static func read(_ url: URL) -> Data? {
        let limit = headerWidth + decodeCeiling * recordWidth
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size >= headerWidth else { return nil }
        guard size > limit else { return FileManager.default.contents(atPath: url.path) }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: limit)
    }

    private static func decode(_ data: Data?) -> [HistoryGapSpan] {
        guard let data = data, data.count >= headerWidth else { return [] }
        let bytes = [UInt8](data)
        guard HistoryBytes.get(UInt32.self, from: bytes, at: 0) == magic,
              HistoryBytes.get(UInt32.self, from: bytes, at: 4) == formatVersion else { return [] }

        // The count is trusted only as far as the file is long enough to back
        // it: a flipped byte must not turn into a 4-billion-element array.
        let claimed = Int(HistoryBytes.get(UInt32.self, from: bytes, at: 8))
        let available = (bytes.count - headerWidth) / recordWidth
        let count = Swift.min(Swift.min(claimed, available), decodeCeiling)
        guard count > 0 else { return [] }

        var spans: [HistoryGapSpan] = []
        spans.reserveCapacity(count)
        for index in 0..<count {
            let offset = headerWidth + index * recordWidth
            let reason = HistoryGapReason(rawValue: bytes[offset + 16]) ?? .nodata
            spans.append(HistoryGapSpan(from: HistoryBytes.get(UInt64.self, from: bytes, at: offset),
                                        to: HistoryBytes.get(UInt64.self, from: bytes, at: offset + 8),
                                        reason: reason))
        }
        return spans.sorted { $0.from < $1.from }
    }
}

// MARK: - gap reasons, derived at read

/// Why a bucket holds nothing — worked out at read from the archive's own
/// bookkeeping and the span sidecar, never backfilled at write (§4).
///
/// The taxonomy is what §2 says is derivable and no more: `NODATA`, `ASLEEP`,
/// `NOT_RUNNING`, `CLOCK_STEP`, plus `HELD`, which the slot carries itself
/// because only the accumulator knows a step lane was holding. `GAP_DISABLED`
/// is deliberately absent: `Module.disable()` posts nothing and is used by both
/// the per-module toggle and the global pause, so it is indistinguishable from
/// a reader that stopped answering, and a guess would be worse than a gap.
public struct HistoryGapResolver {
    public let step: Int
    public let firstValidBucket: UInt32
    public let lastCommitBucket: UInt32
    private let spans: [HistoryGapSpan]

    public init(step: Int, firstValidBucket: UInt32, lastCommitBucket: UInt32, spans: [HistoryGapSpan]) {
        // Clamped once, here, so the two derivations cannot drift apart:
        // `covers(bucket:step:)` answers `false` outright for a non-positive
        // step, while the range walk would clamp it to a one-second column and
        // report spans the single-bucket path denied. Every caller takes the
        // step from a tier, so this guards a future one rather than a present
        // bug.
        self.step = Swift.max(step, 1)
        self.firstValidBucket = firstValidBucket
        self.lastCommitBucket = lastCommitBucket
        // The sidecar hands them over sorted already; sorting here is what lets
        // `reasons(for:slots:)` walk them instead of scanning, whoever the
        // caller is. One sort per range change against one scan per column.
        self.spans = spans.sorted { $0.from < $1.from }
    }

    /// The reason for one bucket, given whatever the archive returned for it.
    ///
    /// Order matters and is the whole of the logic:
    ///
    /// 1. A recorded slot answers for itself — `measured`, or `held` for a step
    ///    lane the chart draws dashed.
    /// 2. Before the lane's `firstValidBucket` nothing was ever written, and no
    ///    span makes that more specific: "asleep" is not why a lane that did
    ///    not exist yet has no data.
    /// 3. A span covering the bucket is the specific answer — asleep, or the
    ///    clock having been set.
    /// 4. Past `lastCommitBucket` the archive stops, so Stats was not running.
    /// 5. Otherwise Stats was running and wrote the neighbours but not this
    ///    bucket: a disabled module, a paused app, a reader that stopped
    ///    answering. §2 collapses all three to no-data.
    ///
    /// Step 2 short-circuits *before* the spans, which has one visible
    /// consequence: a tier that `resetTiersStrandedByTheClock` has just wiped
    /// has no valid bucket at all, so the very span that explains the wipe is
    /// not reported for it — every bucket reads no-data until the new era
    /// writes one. That is the right order anyway ("asleep" is not why a lane
    /// that did not exist yet is empty), and the case it costs is empty: a
    /// reset T0 only loses reasons for buckets already past its 24 h window.
    public func reason(for bucket: UInt32, slot: HistorySlot?) -> HistoryGapReason {
        self.reason(for: bucket, slot: slot, span: self.span(covering: bucket))
    }

    /// One pass over a range, for the chart and the CSV export.
    ///
    /// The spans are walked alongside the buckets rather than scanned per
    /// bucket. Both are sorted — the buckets by construction, the spans by
    /// `from` — so a cursor admits each span once as its start comes into view
    /// and an active set retires it as its end passes: O(columns + spans)
    /// against the O(columns × spans) a per-bucket scan would cost. At §7's
    /// 1,440 columns and a year of accumulated spans that is the difference
    /// between thousands of comparisons and millions, once per range change,
    /// inside a 50 ms first-paint budget.
    public func reasons(for range: Range<UInt32>, slots: [HistorySlot?]) -> [HistoryGapReason] {
        guard !range.isEmpty else { return [] }
        let width = UInt64(self.step)
        var cursor = 0
        var active: [HistoryGapSpan] = []
        var reasons: [HistoryGapReason] = []
        reasons.reserveCapacity(range.count)

        for (offset, bucket) in range.enumerated() {
            let start = UInt64(bucket) * width
            let end = start &+ width
            while cursor < self.spans.count, self.spans[cursor].from < end {
                let span = self.spans[cursor]
                cursor += 1
                // Open spans cover nothing, and a span that ended before this
                // column began never becomes active for a later one.
                if span.to > span.from, span.to > start { active.append(span) }
            }
            if !active.isEmpty { active.removeAll { $0.to <= start } }
            reasons.append(self.reason(for: bucket,
                                       slot: offset < slots.count ? slots[offset] : nil,
                                       span: HistoryGapResolver.mostSpecific(active)))
        }
        return reasons
    }

    private func reason(for bucket: UInt32, slot: HistorySlot?, span: HistoryGapSpan?) -> HistoryGapReason {
        if let slot = slot, slot.isRecorded { return slot.reason }
        guard self.firstValidBucket != HistoryLaneEntry.noValidBucket,
              bucket >= self.firstValidBucket else { return .nodata }
        if let span = span { return span.reason }
        if bucket > self.lastCommitBucket { return .notRunning }
        return .nodata
    }

    /// The most specific span covering the bucket. The whole-array scan the
    /// merge walk above exists to avoid — kept for the single-bucket call,
    /// where there is no range to amortize a walk over.
    private func span(covering bucket: UInt32) -> HistoryGapSpan? {
        var best: HistoryGapSpan?
        for span in self.spans where span.covers(bucket: bucket, step: self.step) {
            best = HistoryGapResolver.moreSpecific(best, span)
        }
        return best
    }

    private static func mostSpecific(_ spans: [HistoryGapSpan]) -> HistoryGapSpan? {
        var best: HistoryGapSpan?
        for span in spans {
            best = HistoryGapResolver.moreSpecific(best, span)
        }
        return best
    }

    /// Spans overlap in one real case: the machine is put to sleep, is shut
    /// down while asleep, and Stats relaunches on the next boot — the recorded
    /// sleep sits inside the stretch the launch marked as "not running". Asleep
    /// is the better answer of the two, and a clock step is a better answer
    /// than either, because it is the only one that also explains why the
    /// timestamps around it do not add up.
    private static func moreSpecific(_ current: HistoryGapSpan?, _ candidate: HistoryGapSpan) -> HistoryGapSpan {
        guard let current = current else { return candidate }
        return rank(candidate.reason) > rank(current.reason) ? candidate : current
    }

    private static func rank(_ reason: HistoryGapReason) -> Int {
        switch reason {
        case .clockStep: return 3
        case .asleep: return 2
        case .notRunning: return 1
        default: return 0
        }
    }
}
