//
//  History.swift
//  CPU
//
//  Persistent usage history: lane extraction for the CPU module.
//  The conformance lives here because Kit cannot import the module targets.
//  Design: docs/usage-history-design.md (§2 Sampling), exelban/stats#1194.
//

import Foundation
import Kit

// MARK: - lanes
//
// LoadReader: `total`, `system`, `user` — three fixed gauge lanes, percent.
// Per-core load, frequency, temperature and average load are v1 non-goals.
//
// A `percent` lane stores a fraction of 1, not 0...100: `LoadReader` divides
// tick deltas by the total (Modules/CPU/readers.swift:150-160) and every other
// percent payload in the v1 set does the same (GPU utilization, RAM usage,
// battery level), so the read side scales once for all of them.

// MARK: - lane cache
//
// `HistorySink.lane(for:)` hashes a string, and that is not free: measured at
// 76 µs for 116 lanes, which is §7's entire container budget spent on lane
// resolution alone. The integer id is therefore resolved once and kept, which
// is what §2's "lanes resolve to integer ids at registration" asks for.
//
// The id is re-resolved every `historyLaneCacheTTL` seconds rather than never.
// `HistoryLaneDirectory` refreshes a lane's `lastUsedTs` from the registration
// call, so a lane that never registers again looks idle to the LRU reclaim
// even while it is recording; and a source that goes away for longer than the
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

private var totalLane = HistoryLaneSlot()
private var systemLane = HistoryLaneSlot()
private var userLane = HistoryLaneSlot()

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

extension CPU_Load: HistoryProvider {
    public func emitHistory(reader: HistoryReaderKey, into sink: inout HistorySink) {
        let ts = sink.timestamp

        if let lane = historyLane(&totalLane, at: ts, into: &sink, {
            HistoryLaneDescriptor(key: HistoryLaneKey(module: .cpu, metric: "total"),
                                  unit: .percent, kind: .gauge, label: "CPU — total")
        }) {
            sink.emit(lane: lane, value: self.totalUsage)
        }

        if let lane = historyLane(&systemLane, at: ts, into: &sink, {
            HistoryLaneDescriptor(key: HistoryLaneKey(module: .cpu, metric: "system"),
                                  unit: .percent, kind: .gauge, label: "CPU — system")
        }) {
            sink.emit(lane: lane, value: self.systemLoad)
        }

        if let lane = historyLane(&userLane, at: ts, into: &sink, {
            HistoryLaneDescriptor(key: HistoryLaneKey(module: .cpu, metric: "user"),
                                  unit: .percent, kind: .gauge, label: "CPU — user")
        }) {
            sink.emit(lane: lane, value: self.userLoad)
        }
    }
}
