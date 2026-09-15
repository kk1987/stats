//
//  HistoryTestSupport.swift
//  Tests
//
//  Persistent usage history: the fixtures the history test cases share. The
//  tests themselves sit one file per subsystem — archive, lanes, recorder,
//  clock and output — and every one of those classes subclasses
//  `HistoryTestCase` for the scratch directory and the fixtures below.
//  Design: docs/usage-history-design.md (§10), exelban/stats#1194.
//

import XCTest
import Kit

/// A scratch directory per test, and the archive, lane, recorder, daily-counter,
/// hook and CSV fixtures built on it. A base class rather than free functions
/// because most of the fixtures need `self.folder` or `addTeardownBlock`, both
/// of which belong to `XCTestCase`.
class HistoryTestCase: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        self.folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stats-history-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: self.folder)
    }

    // MARK: - archive fixtures

    /// Deterministic, so a fuzz failure is reproducible from the seed alone.
    struct SplitMix64: RandomNumberGenerator {
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

    func openArchive(_ tier: HistoryTier, lanes: Int) throws -> HistoryArchive {
        let archive = HistoryArchive(tier: tier, url: self.folder.appendingPathComponent(tier.fileName))
        try archive.open()
        try archive.setDirectory(Self.entries(lanes))
        return archive
    }

    static func entries(_ count: Int) -> [HistoryLaneEntry] {
        (0..<count).map { index in
            HistoryLaneEntry(
                identity: HistoryLaneIdentity(high: 0xA1B2_C3D4_E5F6_0718, low: UInt64(index)),
                module: .cpu, unit: .percent, kind: .gauge, label: "lane \(index)"
            )
        }
    }

    static func row(_ bucket: UInt32, lanes: Int, base: Float) -> HistoryRow {
        HistoryRow(bucket: bucket, slots: (0..<lanes).map { lane in
            let value = base + Float(lane)
            return HistorySlot(bucket: bucket, count: 1, reason: .measured, min: value, max: value, sum: value)
        })
    }

    func quarantinedFiles(for name: String) -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: self.folder.path)) ?? []
        return contents.filter { $0.hasPrefix("\(name).corrupt-") }
    }

    /// A byte-for-byte copy of a file that is still open, read back as its own
    /// archive: what a second process — or the next launch after a `kill -9` —
    /// would find at that instant.
    func snapshot(of url: URL, as name: String) throws -> HistoryArchive {
        let copy = self.folder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: url, to: copy)
        return HistoryArchive(tier: .t0, url: copy)
    }

    static func fileSize(at url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    static func flipBit(at url: URL, byte offset: UInt64, bit: UInt8) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        guard let current = try handle.read(upToCount: 1)?.first else { return }
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: Data([current ^ (1 << bit)]))
    }

    // MARK: - lane fixtures

    static func descriptor(_ source: String, metric: String,
                           label: String? = nil) -> HistoryLaneDescriptor {
        HistoryLaneDescriptor(
            key: HistoryLaneKey(module: .net, source: source, metric: metric),
            unit: .bytesPerSec, kind: .rate, label: label ?? "\(source) \(metric)"
        )
    }

    static func entry(_ source: String, metric: String, firstValidBucket: UInt32,
                      label: String) -> HistoryLaneEntry {
        HistoryLaneEntry(
            identity: HistoryLaneIdentity(key: HistoryLaneKey(module: .disk, source: source, metric: metric)),
            module: .disk, unit: .bytes, kind: .gauge, flags: [],
            firstValidBucket: firstValidBucket, lastUsedTs: 1_700_000_000, label: label
        )
    }

    // MARK: - recorder fixtures

    /// A payload that behaves like a module's `HistoryProvider` conformance:
    /// one lane resolved through the registry per tick, then one scalar.
    struct Probe: HistoryProvider {
        static let label = "probe lane"
        static let reader = HistoryReaderKey(module: .CPU, name: "probe")

        let source: String
        let value: Double
        /// What this tick moved, for the daily counter. Empty for every test
        /// that is not about #3450, which is what the Net conformance does for
        /// a payload whose delta cannot be trusted.
        var traffic: HistoryTraffic = .none

        static func payload(_ value: Double, source: String = "",
                            traffic: HistoryTraffic = .none) -> Probe {
            Probe(source: source, value: value, traffic: traffic)
        }

        func emitHistory(reader: HistoryReaderKey, into sink: inout HistorySink) {
            if !self.traffic.isEmpty {
                sink.emitTraffic(upload: self.traffic.upload, download: self.traffic.download)
            }
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
    final class RecorderProbe {
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

        init(directory: URL, preset: HistoryRetentionPreset, now: TimeInterval,
             calendar: @escaping () -> Calendar = { HistoryTestCase.calendar(.utc) }) {
            self.now = now
            self.start = now
            self.freeSpace = HistoryStore.freeSpaceFloor * 100
            self.store = HistoryStore(directory: directory)

            // Boxed so the closures below do not capture a half-built `self`.
            let box = ProbeBox()
            self.recorder = HistoryRecorder(store: self.store, preset: preset,
                                            environment: HistoryRecorder.Environment(
                now: { box.probe?.now ?? now },
                availableSpace: { _ in box.probe?.freeSpace },
                isPowerConstrained: { box.probe?.isPowerConstrained ?? false },
                monotonicNow: { box.probe?.monotonic ?? now }
            ), calendar: calendar)
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
        func ingest(_ value: Double, traffic: HistoryTraffic = .none) {
            self.recorder.ingest(Probe.payload(value, traffic: traffic),
                                 reader: Probe.reader, interval: 1)
            self.advance(HistoryRecorder.commitInterval)
            self.recorder.commitNow()
        }
    }

    /// Weak-by-construction indirection: the recorder outlives the closures'
    /// need for the probe only inside the probe's own lifetime.
    final class ProbeBox {
        weak var probe: RecorderProbe?
    }

    /// A started recorder on a fresh directory. The clock starts five seconds
    /// into a bucket so that a one-second interval's span attribution stays
    /// inside it and the assertions can name single buckets.
    ///
    /// `enabled:` is passed explicitly, and every other `start` in the history
    /// tests does the same. Its default argument is the stored master switch, and the
    /// Tests target is hosted by Stats.app, so `Store` reads the *installed*
    /// app's real preferences: a developer who turns the switch off in Stats
    /// would otherwise find the whole suite red with no code change.
    func probe(directory: URL? = nil, preset: HistoryRetentionPreset = .standard,
               now: TimeInterval? = nil,
               calendar: @escaping () -> Calendar = { HistoryTestCase.calendar(.utc) }) throws -> RecorderProbe {
        let directory = directory ?? self.folder.appendingPathComponent("history")
        let aligned = (1_760_000_000 / TimeInterval(HistoryTier.t2.step)).rounded(.down)
            * TimeInterval(HistoryTier.t2.step) + 5
        let probe = RecorderProbe(directory: directory, preset: preset, now: now ?? aligned,
                                  calendar: calendar)
        probe.recorder.start(enabled: true)
        probe.recorder.waitUntilIdle()
        return probe
    }

    /// The time zones the daily-counter tests pin. A test that let the
    /// machine's own zone decide would pass in Berlin and fail in Auckland, and
    /// the DST cases would only be reachable from one of them.
    enum Zone: String {
        case utc = "UTC"
        case berlin = "Europe/Berlin"
        case newYork = "America/New_York"
    }

    static func calendar(_ zone: Zone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        if let timeZone = TimeZone(identifier: zone.rawValue) { calendar.timeZone = timeZone }
        return calendar
    }

    // MARK: - daily traffic fixtures

    func dailyCounter(_ zone: Zone, name: String = "daily.bin") -> HistoryDailyTraffic {
        HistoryDailyTraffic(url: self.folder.appendingPathComponent(name),
                            calendar: { HistoryTestCase.calendar(zone) })
    }

    /// A wall-clock instant written the way a person reads it, in the zone the
    /// test is pinned to.
    static func instant(_ zone: Zone, _ text: String) -> TimeInterval {
        let calendar = HistoryTestCase.calendar(zone)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: text)?.timeIntervalSince1970 ?? 0
    }

    // MARK: - hook fixtures

    /// Points the hook at this probe's recorder for the rest of the test, with
    /// a clean log and a known interval.
    func hookedReader(_ probe: RecorderProbe, interval: Double) -> HookReader {
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
    func hookLane(_ archive: HistoryArchive) -> Int? {
        (0..<archive.laneCount).first { archive.entry(lane: $0)?.label == HookPayload.label }
    }

    // MARK: - CSV fixtures

    /// A fixed offset, so that a row's timestamp is an assertion and not a
    /// function of where the machine running the tests is.
    static func exporter(offset: Int = 0) -> HistoryCSVExporter {
        HistoryCSVExporter(locale: Locale(identifier: "en_US_POSIX"),
                           timeZone: TimeZone(secondsFromGMT: offset)!)
    }

    /// T0 buckets from 1,700,000,000, two to a column: 20 s columns starting at
    /// 2023-11-14T22:13:20Z.
    static func csvPlan(columns: Int) -> HistoryColumnPlan {
        let first: UInt32 = 170_000_000
        return HistoryColumnPlan(range: .hour, tier: .t0,
                                 buckets: first..<(first + UInt32(columns * 2)), bucketsPerColumn: 2)
    }

    static func laneColumns(_ label: String, unit: HistoryLaneUnit,
                            _ columns: [HistoryColumn?], lane: Int = 0) -> HistoryLaneColumns {
        HistoryLaneColumns(
            lane: lane,
            entry: HistoryLaneEntry(identity: HistoryLaneIdentity(high: 0, low: UInt64(lane)),
                                    module: .cpu, unit: unit, kind: .gauge, label: label),
            columns: columns
        )
    }

    static func measured(_ min: Float, _ avg: Float, _ max: Float) -> HistoryColumn {
        HistoryColumn(min: min, max: max, avg: avg, count: 12, reason: .measured)
    }

    static func held(_ value: Float) -> HistoryColumn {
        HistoryColumn(min: value, max: value, avg: value, count: 1, reason: .held)
    }

    /// What the read path produces for a column it could name a reason for:
    /// no samples, so no values.
    static func gap(_ reason: HistoryGapReason) -> HistoryColumn {
        HistoryColumn(min: 0, max: 0, avg: 0, count: 0, reason: reason)
    }
}

// MARK: - Reader.callback hook fixtures
//
// At file scope, and not nested in the test case, because `Reader.name` is
// `NSStringFromClass` split on "." — which demangles to "Module.Class" only for
// a top-level class. A nested one reports `_TtCC5Tests15HistoryTestCase10HookReader`
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
