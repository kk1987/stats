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

/// Everything a non-curated sensor needs on the hot path, precomputed: the lane
/// key, the string its identity hashes from, the unit it stores under, and the
/// last answer `HistoryOptionalLanes` gave for it.
///
/// The cached answer is what makes the hot path a dictionary lookup. Asking
/// `isEnabled(stableKey:)` per sensor hashes a `String` into a `Set` behind an
/// `os_unfair_lock`, so the 116-sensor case is ~110 hashes and ~110 lock round
/// trips per tick, all of it inside the recorder's own lock. `enabledRevision`
/// is the generation the answer was given at; the tick reads the current one
/// once and only a sensor whose answer predates it asks again.
private struct HistoryOptionalSlot {
    let key: HistoryLaneKey
    let stableKey: String
    let unit: HistoryLaneUnit
    /// `HistoryOptionalLanes.enabledGeneration` never hands out 0, so a slot
    /// built here always asks once.
    var enabled: Bool = false
    var enabledRevision: UInt64 = 0
}

/// The non-curated sensors seen this launch, keyed by SMC key. The tick that
/// adds an entry is also the one that offers the lane to `HistoryOptionalLanes`,
/// so the steady state — a hundred sensors, all offered on the first tick, none
/// of them enabled — costs one dictionary lookup and one integer compare each:
/// no `lowercased()`, no `stableKey` interpolation, no `offer` call, no lock
/// and no allocation at all — which is what keeps the 116-sensor Intel Mac
/// inside §7's 50 µs container budget.
private var optionalSensors: [String: HistoryOptionalSlot] = [:]

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
        // One lock round trip for the whole tick rather than one per sensor:
        // every non-curated slot compares against this and only re-asks when
        // the user has touched a checkbox since.
        let enabledGeneration = HistoryOptionalLanes.shared.enabledGeneration

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

            if sensor.type == .temperature, isCuratedTemperature(key) {
                guard sensor.value > 0 else { continue }
                if let lane = historyLane(&sensorLanes, key, at: ts, into: &sink, {
                    HistoryLaneDescriptor(key: HistoryLaneKey(module: .sensors, source: key, metric: "temperature"),
                                          unit: .celsius, kind: .gauge, label: sensor.name)
                }) {
                    // `value` is degrees Celsius; `localValue` is the display
                    // conversion and would store Fahrenheit for half the world.
                    sink.emit(lane: lane, value: sensor.value)
                }
                continue
            }

            // Everything outside the curated set: offered to the history
            // window's sidebar, and recorded only once the user has checked it
            // there (§6 — per-lane opt-in belongs where the lanes are
            // enumerated, not in Modules/Sensors/settings.swift).
            guard let unit = optionalUnit(sensor.type) else { continue }

            var slot: HistoryOptionalSlot
            if let known = optionalSensors[key] {
                slot = known
            } else {
                // Once per SMC key per launch: the only place the metric name
                // is lowercased and the only place the stable key is spelled.
                // Offered before the value is looked at, so that a power or
                // voltage sensor reading exactly 0 — which some do on every
                // tick of a machine that is plugged in — still reaches the
                // catalogue and can be opted into. The catalogue is meant to
                // describe the hardware, not what the hardware happened to read
                // the first time it was asked.
                let laneKey = HistoryLaneKey(module: .sensors, source: key,
                                             metric: sensor.type.rawValue.lowercased())
                slot = HistoryOptionalSlot(key: laneKey, stableKey: laneKey.stableKey, unit: unit)
                HistoryOptionalLanes.shared.offer(HistoryLaneDescriptor(key: laneKey, unit: unit,
                                                                       kind: .gauge, label: sensor.name))
            }
            // A fresh slot carries revision 0 and so always falls in here once;
            // afterwards only a tick that follows a checkbox does.
            if slot.enabledRevision != enabledGeneration {
                slot.enabled = HistoryOptionalLanes.shared.isEnabled(stableKey: slot.stableKey)
                slot.enabledRevision = enabledGeneration
                optionalSensors[key] = slot
            }
            guard slot.enabled else { continue }

            // Zero is "not available" to the reader itself, and a zero folded
            // into a bucket would pin its min to a reading nobody took; a
            // negative one is a real discharge on a power sensor. It gates the
            // sample, not the offer above.
            guard sensor.value != 0 else { continue }
            if let lane = historyLane(&sensorLanes, key, at: ts, into: &sink, {
                HistoryLaneDescriptor(key: slot.key, unit: slot.unit, kind: .gauge, label: sensor.name)
            }) {
                sink.emit(lane: lane, value: sensor.value)
            }
        }
    }
}

/// The unit an opt-in sensor is stored under, or `nil` for a type the slot
/// format has no unit byte for.
///
/// Current (amps) and energy are dropped rather than stored under a wrong
/// unit: `HistoryLaneUnit` is a stored enum in the 128 B directory entry, so
/// adding a case is a format decision and not a UI one. They are the two
/// smallest families on any Mac this runs on, and a lane labelled volts that
/// holds amps would be worse than no lane.
private func optionalUnit(_ type: SensorType) -> HistoryLaneUnit? {
    switch type {
    case .temperature: return .celsius
    case .voltage: return .volts
    case .power: return .watts
    default: return nil
    }
}
