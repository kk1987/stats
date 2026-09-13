//
//  History.swift
//  Battery
//
//  Persistent usage history: lane extraction for the Battery module.
//  The conformance lives here because Kit cannot import the module targets.
//  Design: docs/usage-history-design.md (§2 Sampling), exelban/stats#1194.
//

import Foundation
import Kit

// MARK: - lanes
//
// UsageReader is an IOPS run loop source with no Repeater, so `level` is a step
// lane with a bounded 15-minute hold and `power` is a gauge that gaps honestly.
//
// `level` is a fraction of 1, like every other percent lane in the v1 set:
// `read()` divides the reported capacity by 100 (Modules/Battery/readers.swift:75).
//
// `power` is the only place this file departs from §2, which calls it a rate.
// A `rate` lane is not "a lane that gaps" — it is a lane whose samples are
// per-tick deltas that `HistoryAccumulatorTable.foldLocked` divides by the
// elapsed time since the previous sample, bounded by the reader's interval.
// `batteryPower` is already an instantaneous wattage, and dividing it would be
// wrong wherever the divisor is not exactly 1 s. That is not hypothetical: the
// reader has no update-interval setting, so `interval` is the 1 s default, and
// two IOPS notifications inside the same second — which is what plugging or
// unplugging the charger produces — would give `dt = 0.3` and store three
// times the real wattage at exactly the moment a user opens the chart to look
// at it. A `gauge` keeps every behaviour §2 asks for: it is not held between
// samples, so it gaps honestly, and it is stored as measured.

// MARK: - lane cache
//
// `HistorySink.lane(for:)` hashes a string, and that is not free: measured at
// 76 µs for 116 lanes, which is §7's entire container budget spent on lane
// resolution alone. The integer id is therefore resolved once and kept, which
// is what §2's "lanes resolve to integer ids at registration" asks for. It
// matters most here: this is the ingest that runs on the main run loop.
//
// The id is re-resolved every `historyLaneCacheTTL` seconds rather than never.
// `HistoryLaneDirectory` refreshes a lane's `lastUsedTs` from the registration
// call, so a lane that never registers again looks idle to the LRU reclaim
// even while it is recording.
//
// Every access to these globals happens inside `HistoryRecorder.ingest` with
// the recorder's lock held — the same lock that serializes the directory — so
// they are not racing the reader queues the other modules ingest from.

private let historyLaneCacheTTL: UInt64 = 600

/// A resolved lane id and the wall clock it was resolved at. `id` is negative
/// for a lane the registry refused (the cap is reached and every lane in the
/// directory is still warm); the refusal is cached like a success so that a
/// full directory does not re-hash every key on every tick.
private struct HistoryLaneSlot {
    var id: Int32 = -1
    var resolvedAt: UInt64 = 0
}

private var levelLane = HistoryLaneSlot()
private var powerLane = HistoryLaneSlot()

@inline(__always)
private func historyLane(_ slot: inout HistoryLaneSlot, at ts: UInt64, into sink: inout HistorySink,
                         _ descriptor: () -> HistoryLaneDescriptor) -> Int32? {
    if ts < slot.resolvedAt &+ historyLaneCacheTTL {
        return slot.id >= 0 ? slot.id : nil
    }
    slot = HistoryLaneSlot(id: sink.lane(for: descriptor()) ?? -1, resolvedAt: ts)
    return slot.id >= 0 ? slot.id : nil
}

// MARK: - emitHistory

extension Battery_Usage: HistoryProvider {
    func emitHistory(reader: HistoryReaderKey, into sink: inout HistorySink) {
        let ts = sink.timestamp

        if let lane = historyLane(&levelLane, at: ts, into: &sink, {
            HistoryLaneDescriptor(key: HistoryLaneKey(module: .battery, metric: "level"),
                                  unit: .percent, kind: .step, label: "Battery — level")
        }) {
            sink.emit(lane: lane, value: self.level)
        }

        if let lane = historyLane(&powerLane, at: ts, into: &sink, {
            HistoryLaneDescriptor(key: HistoryLaneKey(module: .battery, metric: "power"),
                                  unit: .watts, kind: .gauge, label: "Battery — power")
        }) {
            sink.emit(lane: lane, value: self.batteryPower)
        }
    }
}
