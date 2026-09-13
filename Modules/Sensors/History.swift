//
//  History.swift
//  Sensors
//
//  Persistent usage history: lane extraction for the Sensors module.
//  The conformance lives here because Kit cannot import the module targets.
//  Design: docs/usage-history-design.md (§2 Sampling), exelban/stats#1194.
//

import Foundation
import Kit

// MARK: - lanes
//
// SensorsReader: every fan plus a curated list (CPU die, GPU die, battery,
// ambient) — about five lanes on an Apple Silicon laptop and the 116-lane worst
// case on a sensor-rich Intel Mac. Recording "what the user pinned" is not an
// option: sensor_<key>_popup defaults to true for every discovered sensor and
// fan, so it would silently enable 50-150 lanes. Everything outside the curated
// set is opted in from the history window's own sidebar, never from
// Modules/Sensors/settings.swift.
//
// Identity is the SMC key, never the label, which is localized and unstable.
// `Sensors_List.sensors` is a cross-queue copy of the whole array, so it is
// materialized exactly once per tick and iterated in place; `update` takes a
// barrier sync and is strictly worse.
//
// What the four curated entries resolve to, and why:
//
// - CPU die and GPU die are `Average CPU` and `Average GPU`, the two computed
//   sensors `initCalculatedSensors` recomputes on every read from whatever the
//   machine actually exposes (Modules/Sensors/readers.swift:292-305). There is
//   no single SMC key that means "CPU die" across Intel, M1, M2 and M3 — the
//   table carries TC0D, TC0E, Tp01, Tp09, pACC MTR Temp and a dozen more — and
//   picking one per platform would record nothing on the next one. These keys
//   are synthetic rather than SMC keys, and they are as stable as the code that
//   makes them.
// - Battery is TB1T/TB2T, the same pair `Modules/Battery/readers.swift`
//   averages for its own temperature reading.
// - Ambient is the TA%P family as the reader expands it — TA0P, TA1P and so on
//   (Modules/Sensors/readers.swift:69-84).
//
// A curated key the machine does not expose simply never appears in the list
// and never becomes a lane. A temperature of zero is skipped rather than
// folded: the reader itself treats zero as "not available" when it builds the
// list (`s.value == 0` is filtered out at :108-116), and a zero folded into a
// bucket would pin its `min` to a reading that was never taken.

// MARK: - lane cache
//
// `HistorySink.lane(for:)` hashes a string, and that is not free: measured at
// 76 µs for 116 lanes, which is §7's entire container budget spent on lane
// resolution alone — this module is the reason the budget is the shape it is.
// The integer id is therefore resolved once and kept, which is what §2's
// "lanes resolve to integer ids at registration" asks for.
//
// The id is re-resolved every `historyLaneCacheTTL` seconds rather than never.
// `HistoryLaneDirectory` refreshes a lane's `lastUsedTs` from the registration
// call, so a lane that never registers again looks idle to the LRU reclaim
// even while it is recording; and a sensor that goes away for longer than the
// TTL re-resolves on its first tick back, so a cached id that was reclaimed in
// the meantime cannot be written to under the old identity.
//
// Every access to these globals happens inside `HistoryRecorder.ingest` with
// the recorder's lock held — the same lock that serializes the directory — so
// they are not racing even though Battery ingests on the main run loop.

private let historyLaneCacheTTL: UInt64 = 600

/// A resolved lane id and the wall clock it was resolved at. `id` is negative
/// for a lane the registry refused (the cap is reached and every lane in the
/// directory is still warm); the refusal is cached like a success so that a
/// full directory does not re-hash every key on every tick.
private struct HistoryLaneSlot {
    var id: Int32 = -1
    var resolvedAt: UInt64 = 0
}

/// Keyed by SMC key directly, so the cached path neither interpolates a string
/// nor allocates. One dictionary is enough: a sensor contributes exactly one
/// lane.
private var sensorLanes: [String: HistoryLaneSlot] = [:]

@inline(__always)
private func historyLane(_ cache: inout [String: HistoryLaneSlot], _ key: String, at ts: UInt64,
                         into sink: inout HistorySink,
                         _ descriptor: () -> HistoryLaneDescriptor) -> Int32? {
    if let slot = cache[key], ts < slot.resolvedAt &+ historyLaneCacheTTL {
        return slot.id >= 0 ? slot.id : nil
    }
    let id = sink.lane(for: descriptor()) ?? -1
    cache[key] = HistoryLaneSlot(id: id, resolvedAt: ts)
    return id >= 0 ? id : nil
}

/// The curated temperature set: CPU die, GPU die, battery, ambient.
private func isCuratedTemperature(_ key: String) -> Bool {
    switch key {
    case "Average CPU", "Average GPU": return true
    case "TB1T", "TB2T": return true
    default: return isAmbientKey(key)
    }
}

/// The TA%P family, as `SensorsReader.sensors()` expands it: "TA" then one
/// digit then "P". Matched rather than listed because the expansion runs over
/// whatever the machine reports, not over a fixed set.
private func isAmbientKey(_ key: String) -> Bool {
    guard key.count == 4, key.hasPrefix("TA"), key.hasSuffix("P") else { return false }
    let digit = key[key.index(key.startIndex, offsetBy: 2)]
    return digit.isASCII && digit.isNumber
}

// MARK: - emitHistory

extension Sensors_List: HistoryProvider {
    public func emitHistory(reader: HistoryReaderKey, into sink: inout HistorySink) {
        let ts = sink.timestamp
        // One cross-queue copy of the whole array per tick, then in place (§2).
        let sensors = self.sensors

        for sensor in sensors {
            let key = sensor.key

            if sensor.type == .fan {
                // "Fastest fan" is a computed duplicate of whichever real fan
                // is loudest, so it would record a second copy of a lane that
                // is already there under a key that moves between fans.
                guard !sensor.isComputed else { continue }
                if let lane = historyLane(&sensorLanes, key, at: ts, into: &sink, {
                    HistoryLaneDescriptor(key: HistoryLaneKey(module: .sensors, source: key, metric: "rpm"),
                                          unit: .rpm, kind: .gauge, label: sensor.name)
                }) {
                    sink.emit(lane: lane, value: sensor.value)
                }
                continue
            }

            guard sensor.type == .temperature, isCuratedTemperature(key), sensor.value > 0 else { continue }
            if let lane = historyLane(&sensorLanes, key, at: ts, into: &sink, {
                HistoryLaneDescriptor(key: HistoryLaneKey(module: .sensors, source: key, metric: "temperature"),
                                      unit: .celsius, kind: .gauge, label: sensor.name)
            }) {
                // `value` is degrees Celsius; `localValue` is the display
                // conversion and would store Fahrenheit for half the world.
                sink.emit(lane: lane, value: sensor.value)
            }
        }
    }
}
