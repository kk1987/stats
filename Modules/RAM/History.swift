//
//  History.swift
//  RAM
//
//  Persistent usage history: lane extraction for the RAM module.
//  The conformance lives here because Kit cannot import the module targets.
//  Design: docs/usage-history-design.md (§2 Sampling), exelban/stats#1194.
//

import Foundation
import Kit

// MARK: - lanes
//
// UsageReader: `usage`, `pressure`, `swap` — three fixed gauge lanes. `usage`
// is a computed property, which is one of the reasons extraction is typed
// rather than reflective.
//
// `usage` is a fraction of 1, like every other percent lane in the v1 set.
// `swap` is the swap file's used bytes, so it is a `bytes` gauge and not a
// percentage of a total that is itself elastic.
//
// `pressure` has no unit in the v1 enum and never will have a natural one: the
// kernel reports three levels, not a scale. It is stored as the level's
// position on its own scale — normal 0, warning 0.5, critical 1 — under the
// `percent` unit, so the chart draws it against the same 0...1 axis as the
// other percent lanes and the read side needs no special case. The raw sysctl
// value (1, 2, 4) is deliberately not what is stored: it is not ordered on a
// scale, it is a bitmask that happens to sort.

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

private var usageLane = HistoryLaneSlot()
private var pressureLane = HistoryLaneSlot()
private var swapLane = HistoryLaneSlot()

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

extension RAM_Usage: HistoryProvider {
    public func emitHistory(reader: HistoryReaderKey, into sink: inout HistorySink) {
        let ts = sink.timestamp

        if let lane = historyLane(&usageLane, at: ts, into: &sink, {
            HistoryLaneDescriptor(key: HistoryLaneKey(module: .ram, metric: "usage"),
                                  unit: .percent, kind: .gauge, label: "RAM — usage")
        }) {
            // Computed from `total` and `free`, and `total` is a device
            // constant the reader reads once, so a zero here means the reader
            // never initialized rather than that the machine has no memory.
            // The sink drops the resulting non-finite value either way; the
            // guard is here so that the intent is on the page.
            if self.total > 0 {
                sink.emit(lane: lane, value: self.usage)
            }
        }

        if let lane = historyLane(&pressureLane, at: ts, into: &sink, {
            HistoryLaneDescriptor(key: HistoryLaneKey(module: .ram, metric: "pressure"),
                                  unit: .percent, kind: .gauge, label: "RAM — pressure")
        }) {
            sink.emit(lane: lane, value: Double(self.pressure.value.number()) / 2)
        }

        if let lane = historyLane(&swapLane, at: ts, into: &sink, {
            HistoryLaneDescriptor(key: HistoryLaneKey(module: .ram, metric: "swap"),
                                  unit: .bytes, kind: .gauge, label: "RAM — swap")
        }) {
            sink.emit(lane: lane, value: self.swap.used)
        }
    }
}
