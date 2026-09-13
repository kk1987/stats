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

extension Sensors_List: HistoryProvider {
    public func emitHistory(reader: HistoryReaderKey, into sink: inout HistorySink) {
        // Filled in by "feat: history lane extraction in the module targets".
    }
}
