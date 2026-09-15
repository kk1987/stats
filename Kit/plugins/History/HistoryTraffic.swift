//
//  HistoryTraffic.swift
//  Kit
//
//  Persistent usage history: the per-day network byte counter behind the
//  Today / Yesterday rows of the network popup (exelban/stats#3450).
//  Design: docs/usage-history-design.md (§5), exelban/stats#1194.
//

import Foundation
import os

// MARK: - daily traffic

/// #3450's surface: an independent monotonic per-day byte counter written at
/// ingest, in its own small append-only file. Not a tiered lane, and not
/// integrated from averaged buckets. Days roll at local midnight, recomputed
/// from the current calendar on every commit tick so DST produces a 23- or
/// 25-hour day rather than a shifted one (§5).
///
/// It is deliberately not `Network_Usage.total` either: that counter is the
/// user's own, with its own reset schedule and a Reset button two rows above
/// the one this feeds, and a "today" that a scheduled reset zeroes at noon is
/// not a daily total.
///
/// Days are keyed by their local calendar date (`YYYYMMDD`), not by the epoch
/// second local midnight falls on. The key is what survives the one event that
/// moves every boundary at once: fly from Berlin to New York and yesterday is
/// still the same Tuesday, even though Tuesday's midnight is now six hours
/// later in UTC.
public final class HistoryDailyTraffic {
    /// The sidecar. Append-only, one fixed-width record per persist, later
    /// records for a day superseding earlier ones; compacted to one record per
    /// day once it has grown past `compactionCeiling`.
    public static let fileName: String = "daily.bin"

    /// How many days the file keeps. Today and yesterday are what the popup
    /// shows; the tail is what makes a "last 30 days" answer possible later
    /// without a format change, and 400 records is under 10 KiB.
    public static let retentionDays: Int = 400

    /// How often a counter that has moved reaches the disk. It rides the
    /// commit tick — there is no second timer — but not every tick: an append
    /// dirties a 4 KiB block whatever it writes, so persisting every minute
    /// would cost ~5 MiB a day on a machine with traffic every minute, which is
    /// the same order as the whole T0 write volume §3 derives for a counter
    /// that is two numbers. At five minutes it is ~1 MiB a day, and what a
    /// `kill -9` costs is the traffic of the last five minutes, on a figure
    /// that already says it undercounts.
    ///
    /// A day roll, a sleep, a flush and a terminate all persist regardless.
    public static let persistInterval: TimeInterval = 300

    /// Records on disk beyond which the next persist rewrites the file with one
    /// record per day instead of appending. At the persist cadence a busy day
    /// appends ~288 records, so this is a rewrite of under 10 KiB about once a
    /// week.
    public static let compactionCeiling: Int = 2_000

    /// Bounds what a damaged or hostile length field can make a load allocate,
    /// before the record count is checked against the file's actual size.
    private static let decodeCeiling: Int = 1 << 16

    /// Hexdumps as "STDY" under the little-endian encoding below.
    private static let magic: UInt32 = 0x5944_5453
    private static let formatVersion: UInt32 = 1
    private static let headerWidth: Int = 16
    private static let recordWidth: Int = 24

    /// What the popup shows: the two days #3450 asks for.
    public struct Totals: Equatable {
        public static let none = Totals(today: .none, yesterday: .none)

        public let today: HistoryTraffic
        public let yesterday: HistoryTraffic

        public init(today: HistoryTraffic, yesterday: HistoryTraffic) {
            self.today = today
            self.yesterday = yesterday
        }
    }

    public let url: URL
    /// The calendar local midnight is computed from, read again on every roll
    /// rather than cached: a cached one would keep answering in the time zone
    /// the app launched in (§5). Injected so a test can pin a zone and change
    /// it underneath the counter.
    private let calendar: () -> Calendar

    /// Guards everything below. Taken by `add` from the recorder's lock — so
    /// the order is recorder, then this, and never the reverse — and on its own
    /// by the popup reading `totals`. It is a leaf: nothing under it calls back
    /// out, and no file is written with it held.
    private let lock: UnsafeMutablePointer<os_unfair_lock>

    /// Every day the file knows about except the one being recorded, which is
    /// `today`. Capped to `retentionDays` by dropping the oldest keys.
    private var past: [UInt32: HistoryTraffic] = [:]
    private var today: HistoryTraffic = .none
    /// Bytes that arrived at or after `dayEnd`, before a roll has attributed
    /// them. They belong to the day that has just started, and the next roll
    /// moves them into it — which is what keeps the roll off the ingest path
    /// without misdating a minute of midnight traffic.
    private var pending: HistoryTraffic = .none

    private var dayKey: UInt32 = 0
    private var yesterdayKey: UInt32 = 0
    /// Where the open day ends: the next local midnight, as the calendar said
    /// it was at the last roll. The only thing `add` compares against, because
    /// a comparison and an integer add is the whole of what the hot path may
    /// do. There is deliberately no matching start — a sample dated before the
    /// day began is a clock that went backwards, and the roll is what sorts
    /// that out, not the fold.
    private var dayEnd: TimeInterval = 0

    private var todayDirty: Bool = false
    /// Days that ended with bytes the file has not seen. Normally empty, and
    /// never longer than one entry unless a persist failed.
    private var parked: [(key: UInt32, traffic: HistoryTraffic)] = []
    private var lastPersistTs: TimeInterval = 0
    private var recordsOnDisk: Int = 0
    /// Set when the file is not a whole number of records, or held a record
    /// that failed its checksum: the next persist rewrites it rather than
    /// appending onto a torn tail.
    private var needsCompaction: Bool = false

    /// Serializes the writes, which happen with `lock` released.
    private let writeLock: UnsafeMutablePointer<os_unfair_lock>

    public init(url: URL, calendar: @escaping () -> Calendar = { Calendar.current }) {
        self.url = url
        self.calendar = calendar
        self.lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        self.lock.initialize(to: os_unfair_lock())
        self.writeLock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        self.writeLock.initialize(to: os_unfair_lock())
    }

    deinit {
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

    // MARK: - add(_:at:)

    /// One tick's bytes. Called from `ingest`, on the reader's own queue, with
    /// the recorder's lock already held.
    ///
    /// Nothing here asks the calendar: the day's window was computed at the
    /// last roll and this is two comparisons and an add. A sample at or past
    /// the window's end is held as `pending` for the next roll to attribute,
    /// and one *before* its start — a wall clock set backwards — is counted
    /// into the open day, because a monotonic counter that goes down would be a
    /// worse answer than one minute of traffic dated to the wrong side of a
    /// step.
    public func add(_ traffic: HistoryTraffic, at ts: TimeInterval) {
        guard !traffic.isEmpty, ts.isFinite else { return }
        self.locked {
            guard self.dayEnd > 0 else {
                self.pending.add(traffic)
                return
            }
            if ts >= self.dayEnd {
                self.pending.add(traffic)
            } else {
                self.today.add(traffic)
                self.todayDirty = true
            }
        }
    }

    // MARK: - today and yesterday

    /// The two counters, rolled to `now` first so that a popup opened at 00:00
    /// does not spend a minute showing yesterday's figure as today's.
    public func totals(at now: TimeInterval) -> Totals {
        self.roll(at: now)
        return self.locked { Totals(today: self.today, yesterday: self.past[self.yesterdayKey] ?? .none) }
    }

    /// Every day the counter has bytes for, oldest first, keyed `YYYYMMDD`. The
    /// tail the file keeps is not shown anywhere yet; this is what a "last 30
    /// days" surface would read and what the tests assert a round trip on.
    ///
    /// A day with nothing in it is not one of them — an open day that has not
    /// seen a byte yet is absence, not a zero somebody measured.
    public var days: [(day: UInt32, traffic: HistoryTraffic)] {
        self.locked { () -> [(day: UInt32, traffic: HistoryTraffic)] in
            var all = self.past
            if self.dayKey != 0, !self.today.isEmpty { all[self.dayKey] = self.today }
            return all.keys.sorted().map { (day: $0, traffic: all[$0] ?? .none) }
        }
    }

    // MARK: - local-midnight roll

    /// Re-anchors the day window on the current calendar.
    ///
    /// Everything the calendar is asked happens here, with the lock released,
    /// and this runs on the commit tick and on a popup read — never on the
    /// ingest path. Asking it every time rather than caching a `+86400` is what
    /// §5 buys with it: a DST transition produces a 23- or 25-hour day because
    /// `date(byAdding: .day)` says so, and a time zone change re-anchors on the
    /// very next call instead of at the next midnight.
    public func roll(at now: TimeInterval) {
        guard now > 0, now.isFinite else { return }
        let calendar = self.calendar()
        let date = Date(timeIntervalSince1970: now)
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let previous = calendar.date(byAdding: .day, value: -1, to: start) ?? start.addingTimeInterval(-86_400)
        let key = HistoryDailyTraffic.key(for: start, calendar: calendar)
        let previousKey = HistoryDailyTraffic.key(for: previous, calendar: calendar)

        self.locked {
            self.dayEnd = end.timeIntervalSince1970
            self.yesterdayKey = previousKey

            guard key != self.dayKey else {
                // Same calendar day, possibly with moved boundaries — a time
                // zone change inside a day, or the first anchor of a run. What
                // `pending` holds was counted against the old end and belongs
                // to this day after all.
                if !self.pending.isEmpty {
                    self.today.add(self.pending)
                    self.pending = .none
                    self.todayDirty = true
                }
                return
            }

            // The day that just ended keeps its bytes, and owes the file a
            // record if any of them arrived since the last persist.
            if self.dayKey != 0 {
                self.past[self.dayKey] = self.today
                if self.todayDirty { self.parked.append((key: self.dayKey, traffic: self.today)) }
            }
            // A day that is already known — a relaunch on the same day, or a
            // clock moved back across midnight — resumes its own total.
            self.today = self.past.removeValue(forKey: key) ?? .none
            self.todayDirty = !self.pending.isEmpty
            self.today.add(self.pending)
            self.pending = .none
            self.dayKey = key
            self.capLocked()
        }
    }

    // MARK: - persistence (append-only, last record per day wins)

    /// Rolls the day and writes, if the cadence or `force` says to. Called from
    /// the recorder's commit, on the history queue.
    public func commit(at now: TimeInterval, force: Bool = false) {
        self.roll(at: now)
        self.persist(at: now, force: force)
    }

    /// Reads the file and anchors the day on it. The archives are open and the
    /// cross-process lock is held by the time this runs, so nothing else is
    /// writing this file.
    public func load(at now: TimeInterval) {
        let decoded = HistoryDailyTraffic.decode(HistoryDailyTraffic.read(self.url))
        self.locked {
            self.past = decoded.days
            self.today = .none
            self.pending = .none
            self.dayKey = 0
            self.yesterdayKey = 0
            self.dayEnd = 0
            self.todayDirty = false
            self.parked.removeAll()
            self.lastPersistTs = now
            self.recordsOnDisk = decoded.records
            self.needsCompaction = decoded.isTorn
            self.capLocked()
        }
        // Outside the lock, and after the state above: this is what picks
        // today's total back up out of the file.
        self.roll(at: now)
    }

    /// Everything is gone — the file with it. What `HistoryRecorder.deleteAll`
    /// calls once the directory has been emptied.
    public func reset(at now: TimeInterval) {
        self.locked {
            self.past.removeAll()
            self.today = .none
            self.pending = .none
            self.dayKey = 0
            self.yesterdayKey = 0
            self.dayEnd = 0
            self.todayDirty = false
            self.parked.removeAll()
            self.lastPersistTs = now
            self.recordsOnDisk = 0
            self.needsCompaction = false
        }
        self.roll(at: now)
    }

    /// Appends what has moved, or rewrites the file when it has grown past the
    /// compaction ceiling or a load found it torn.
    ///
    /// The encode happens under the lock and the write with it released, for
    /// the reason the span sidecar gives: `totals` is read from main, and
    /// holding an `os_unfair_lock` across a filesystem round trip would park
    /// the popup behind it.
    private func persist(at now: TimeInterval, force: Bool) {
        var records: [(key: UInt32, traffic: HistoryTraffic)] = []
        var compact: [(key: UInt32, traffic: HistoryTraffic)]?

        self.locked {
            let due = force || self.lastPersistTs == 0
                || now - self.lastPersistTs >= HistoryDailyTraffic.persistInterval
            guard !self.parked.isEmpty || (self.todayDirty && due) else { return }

            records = self.parked
            self.parked.removeAll()
            if self.todayDirty, self.dayKey != 0 {
                records.append((key: self.dayKey, traffic: self.today))
                self.todayDirty = false
            }
            guard !records.isEmpty else { return }
            self.lastPersistTs = now

            if self.needsCompaction
                || self.recordsOnDisk + records.count > HistoryDailyTraffic.compactionCeiling {
                var all = self.past
                if self.dayKey != 0 { all[self.dayKey] = self.today }
                for record in records where all[record.key] == nil { all[record.key] = record.traffic }
                compact = all.keys.sorted().map { (key: $0, traffic: all[$0] ?? .none) }
            }
        }
        guard !records.isEmpty else { return }

        let written: Int?
        if let compact = compact {
            written = self.rewrite(compact) ? compact.count : nil
        } else {
            written = self.append(records) ? records.count : nil
        }

        self.locked {
            guard let written = written else {
                // Nothing reached the file, so nothing may be forgotten: the
                // days go back on the list and the next cycle tries again.
                // The counter itself is unharmed — this file is an accessory
                // to it, exactly as the span sidecar is to the archive, and a
                // failure here is not a write failure the three-strikes rule
                // counts.
                self.parked.append(contentsOf: records)
                self.lastPersistTs = 0
                return
            }
            if compact != nil {
                self.recordsOnDisk = written
                self.needsCompaction = false
            } else {
                self.recordsOnDisk += written
            }
        }
    }

    /// Drops the oldest days past the retention cap. Keys sort as dates do.
    private func capLocked() {
        let overflow = self.past.count - (HistoryDailyTraffic.retentionDays - 1)
        guard overflow > 0 else { return }
        for key in self.past.keys.sorted().prefix(overflow) {
            self.past.removeValue(forKey: key)
        }
    }

    // MARK: - encoding (16 B header, 24 B records, little-endian, crc32 each)

    /// `YYYYMMDD` in the given calendar. Zero is not a valid date, which is
    /// what makes it usable as "no day anchored yet".
    private static func key(for date: Date, calendar: Calendar) -> UInt32 {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day,
              year > 0, year < 10_000 else { return 0 }
        return UInt32(year * 10_000 + month * 100 + day)
    }

    private static func encodeRecord(_ record: (key: UInt32, traffic: HistoryTraffic), into buffer: inout [UInt8],
                                     at offset: Int) {
        HistoryBytes.put(record.key, into: &buffer, at: offset)
        HistoryBytes.put(record.traffic.upload, into: &buffer, at: offset + 4)
        HistoryBytes.put(record.traffic.download, into: &buffer, at: offset + 12)
        let checksum = HistoryCRC32.checksum(Array(buffer[offset..<(offset + 20)]))
        HistoryBytes.put(checksum, into: &buffer, at: offset + 20)
    }

    private static func encode(_ records: [(key: UInt32, traffic: HistoryTraffic)], header: Bool) -> [UInt8] {
        let base = header ? headerWidth : 0
        var buffer = [UInt8](repeating: 0, count: base + records.count * recordWidth)
        if header {
            HistoryBytes.put(magic, into: &buffer, at: 0)
            HistoryBytes.put(formatVersion, into: &buffer, at: 4)
        }
        for (index, record) in records.enumerated() {
            HistoryDailyTraffic.encodeRecord(record, into: &buffer, at: base + index * recordWidth)
        }
        return buffer
    }

    /// The bytes to decode, capped before the read rather than after it, for the
    /// reason the span sidecar gives: a garbage length must not materialize a
    /// file of any size twice over before a single field has been looked at.
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

    /// Later records for a day supersede earlier ones, which is what makes an
    /// append-only file a set of daily totals.
    ///
    /// `isTorn` is the crash-safety half: a last record the process died in the
    /// middle of is either short — the file is then not a whole number of
    /// records — or damaged, and fails the checksum that every record carries.
    /// Either way it is dropped, and the file is rewritten at the next persist
    /// rather than appended onto at a misaligned offset.
    private static func decode(_ data: Data?) -> (days: [UInt32: HistoryTraffic], records: Int, isTorn: Bool) {
        guard let data = data, data.count >= headerWidth else { return ([:], 0, false) }
        let bytes = [UInt8](data)
        guard HistoryBytes.get(UInt32.self, from: bytes, at: 0) == magic,
              HistoryBytes.get(UInt32.self, from: bytes, at: 4) == formatVersion else { return ([:], 0, true) }

        let available = bytes.count - headerWidth
        let count = Swift.min(available / recordWidth, decodeCeiling)
        var days: [UInt32: HistoryTraffic] = [:]
        var isTorn = available % recordWidth != 0
        var valid = 0

        for index in 0..<count {
            let offset = headerWidth + index * recordWidth
            let stored = HistoryBytes.get(UInt32.self, from: bytes, at: offset + 20)
            guard HistoryCRC32.checksum(Array(bytes[offset..<(offset + 20)])) == stored else {
                isTorn = true
                continue
            }
            let key = HistoryBytes.get(UInt32.self, from: bytes, at: offset)
            guard key > 0 else {
                isTorn = true
                continue
            }
            days[key] = HistoryTraffic(upload: HistoryBytes.get(Int64.self, from: bytes, at: offset + 4),
                                       download: HistoryBytes.get(Int64.self, from: bytes, at: offset + 12))
            valid += 1
        }
        return (days, valid, isTorn)
    }

    // MARK: - io (append, or one atomic rewrite when compacting)

    private func append(_ records: [(key: UInt32, traffic: HistoryTraffic)]) -> Bool {
        os_unfair_lock_lock(self.writeLock)
        defer { os_unfair_lock_unlock(self.writeLock) }

        let fd = open(self.url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else {
            error("history: the daily traffic file could not be opened (errno \(errno))")
            return false
        }
        defer { close(fd) }

        // A file this process has just created owes a header; one that already
        // had records does not. `lseek` on an append descriptor reports the
        // length, which is the question being asked.
        let end = lseek(fd, 0, SEEK_END)
        let bytes = HistoryDailyTraffic.encode(records, header: end < HistoryDailyTraffic.headerWidth)
        return bytes.withUnsafeBytes { buffer -> Bool in
            var written = 0
            while written < bytes.count {
                let n = write(fd, buffer.baseAddress!.advanced(by: written), bytes.count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    error("history: the daily traffic file could not be written (errno \(errno))")
                    return false
                }
                if n == 0 { return false }
                written += n
            }
            return true
        }
    }

    private func rewrite(_ records: [(key: UInt32, traffic: HistoryTraffic)]) -> Bool {
        os_unfair_lock_lock(self.writeLock)
        defer { os_unfair_lock_unlock(self.writeLock) }

        let bytes = HistoryDailyTraffic.encode(records, header: true)
        do {
            try Data(bytes).write(to: self.url, options: .atomic)
            return true
        } catch let failure {
            error("history: the daily traffic file could not be rewritten: \(failure)")
            return false
        }
    }
}
