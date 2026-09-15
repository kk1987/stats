//
//  HistoryBenchmarkTests.swift
//  Tests
//
//  Persistent usage history: the per-payload ingest benchmarks §10 asks for.
//  Every case measures one whole `HistoryRecorder.ingest` — the lock, the
//  clock read, the payload's own `emitHistory`, and the fold into the bucket
//  accumulators — because that is what a reader tick actually pays, and §7's
//  budget is written against the tick and not against any one part of it.
//
//  Numbers are recorded in each test's doc comment. They come from one machine
//  (M4 Max, macOS 27.0, Debug configuration — the `test` action's, so they are
//  a pessimistic multiple of what a shipped Release build costs) and they are
//  there to make a regression legible in review, not to be asserted on:
//  `measure` has no baseline committed, so a slow machine makes these tests
//  slow, never red.
//
//  Each quotes two figures because they differ: the average `measure` prints,
//  and the steady state of iterations 2-10. The first iteration runs about
//  2.4x the rest on every one of these — the CPU ramping, not the code — and
//  it is the steady state that the §7 budget should be read against.
//  Design: docs/usage-history-design.md (§2, §7, §10), exelban/stats#1194.
//

import XCTest
import Kit
import Sensors

final class HistoryBenchmarkTests: HistoryTestCase {
    /// The worst payload in the app by an order of magnitude, and the one §7
    /// sizes the container budget from: a Mac Pro's sensor list is 116 keys and
    /// the module walks all of them on every tick. Fans are what is measured
    /// because they are the branch that records unconditionally — a curated
    /// temperature costs the same walk and a non-curated sensor costs less.
    ///
    /// Measured over 1,000 ticks per iteration: average 0.032 s, steady state
    /// 0.0278 s — **27.8 µs per tick** of 120 lanes, or 0.23 µs per lane. §7
    /// budgets 1 % of a core at the 1 s interval, which is 10 ms a tick, so the
    /// whole sensor list costs about a 360th of what it is allowed.
    func testIngestOfASensorsPayloadOfAHundredAndTwentyLanes() throws {
        let probe = try self.probe()
        defer { probe.recorder.stop() }

        let list = Sensors_List()
        list.sensors = (0..<120).map { BenchmarkSensor(index: $0) }
        let reader = HistoryReaderKey(module: .sensors, name: "SensorsReader")

        // Warm, and not part of the measurement: the module caches the integer
        // lane id per SMC key for 600 s, so one tick per launch pays for 120
        // string hashes and every later one reads the cache. It is the steady
        // state the §7 budget is written against, not the first tick.
        for _ in 0..<200 { probe.recorder.ingest(list, reader: reader, interval: 1) }
        XCTAssertEqual(probe.recorder.laneCount, 120)

        self.measure {
            for _ in 0..<1_000 {
                probe.recorder.ingest(list, reader: reader, interval: 1)
            }
        }

        probe.now += HistoryRecorder.commitInterval
        probe.recorder.commitNow()
        XCTAssertEqual(try XCTUnwrap(probe.store.archive(.t0)).laneCount, 120)
    }

    /// The other end of the range, and what every module except Sensors looks
    /// like: a fixed handful of lanes resolved through the registry on every
    /// tick. CPU, RAM, GPU, Net, Disk and Battery all have this shape, so one
    /// scalar lane is the unit the rest of them multiply.
    ///
    /// Measured over 10,000 ticks per iteration: average 0.036 s, steady state
    /// 0.0307 s — **3.07 µs per tick** of one lane. That is mostly the fixed
    /// part of a tick: the lock, the two clock reads and the sink, plus a
    /// descriptor re-hashed here on every tick where the module conformances
    /// cache the integer id and hash once per 600 s. It is why 120 sensor lanes
    /// come to nine times this and not to a hundred and twenty times it.
    func testIngestOfAScalarPayload() throws {
        let probe = try self.probe()
        defer { probe.recorder.stop() }

        for _ in 0..<2_000 { probe.recorder.ingest(Probe.payload(42), reader: Probe.reader, interval: 1) }
        XCTAssertEqual(probe.recorder.laneCount, 1)

        self.measure {
            for _ in 0..<10_000 {
                probe.recorder.ingest(Probe.payload(42), reader: Probe.reader, interval: 1)
            }
        }
    }

    /// The Net shape: one gauge lane plus the #3450 daily byte counter, which
    /// takes a second lock and two integer adds outside the accumulator table.
    /// The counter's cost is the difference between this number and the scalar
    /// one above, which is the only way to read it without a timer inside the
    /// lock.
    ///
    /// Measured over 10,000 ticks per iteration: average 0.036 s, steady state
    /// 0.0315 s — **3.15 µs per tick**, about 0.08 µs over the same payload
    /// without traffic. That is at the resolution this measurement has, so the
    /// honest statement is that the counter does not show up in a tick.
    func testIngestOfAPayloadThatAlsoCarriesTraffic() throws {
        let probe = try self.probe()
        defer { probe.recorder.stop() }

        let traffic = HistoryTraffic(upload: 1_024, download: 8_192)
        for _ in 0..<2_000 {
            probe.recorder.ingest(Probe.payload(42, traffic: traffic), reader: Probe.reader, interval: 1)
        }

        self.measure {
            for _ in 0..<10_000 {
                probe.recorder.ingest(Probe.payload(42, traffic: traffic),
                                      reader: Probe.reader, interval: 1)
            }
        }

        XCTAssertGreaterThan(probe.recorder.dailyTraffic.today.download, 0)
    }
}

// MARK: - benchmark fixtures

/// A sensor with nothing behind it: `Sensors_List` holds `Sensor_p`, and the
/// module's own `Sensor` reads the user's preferences for `state` and
/// `popupState`, which a benchmark has no business doing 120 times a tick.
/// `emitHistory` reads `key`, `name`, `value`, `type` and `isComputed` only, so
/// the rest is answered with constants.
private struct BenchmarkSensor: Sensor_p {
    let key: String
    let name: String
    var value: Double

    let group: SensorGroup = .sensor
    let type: SensorType = .fan
    let isComputed: Bool = false
    let average: Bool = false

    let state: Bool = true
    let popupState: Bool = true
    let notificationThreshold: String = ""

    var localValue: Double { self.value }
    let unit: String = "RPM"
    let miniUnit: String = "RPM"
    var formattedValue: String { "\(Int(self.value))" }
    var formattedMiniValue: String { self.formattedValue }
    var formattedPopupValue: String { self.formattedValue }

    init(index: Int) {
        self.key = "F\(index)Ac"
        self.name = "Fan #\(index)"
        self.value = Double(1_000 + index)
    }
}
