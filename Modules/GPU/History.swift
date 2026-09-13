//
//  History.swift
//  GPU
//
//  Persistent usage history: lane extraction for the GPU module.
//  The conformance lives here because Kit cannot import the module targets.
//  Design: docs/usage-history-design.md (§2 Sampling), exelban/stats#1194.
//

import Foundation
import Kit

// MARK: - lanes
//
// InfoReader: `<id>.utilization` and `<id>.temperature` for every GPU, not only
// `selectedGPU`. Identity is `GPU_Info.id`, never `model`, which collides on a
// dual identical GPU machine. `GPUs.list` is materialized once per tick.
//
// `GPU_Info.id` is `"<model> #<index>"` when the accelerator matched a PCI
// device and the empty string when it did not, which is the common case on
// Apple Silicon (Modules/GPU/reader.swift:119-131). The empty id is still an
// identity rather than a hole: the reader itself keys its list on it, so at
// most one entry can carry it.
//
// A GPU that is powered off is recorded like any other. `utilization` and
// `temperature` are optional and only set when the accelerator reported them,
// so absence is already expressed as no-data; a zero temperature is treated as
// absence too, because that is what the reader's own fallbacks treat it as
// (`if temperature == nil || temperature == 0`, :154 and :163).

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
// even while it is recording; and a GPU that goes away for longer than the TTL
// — an external enclosure unplugged — re-resolves on its first tick back, so a
// cached id that was reclaimed in the meantime cannot be written to under the
// old identity.
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

/// Keyed by `GPU_Info.id` directly, so the cached path neither interpolates a
/// string nor allocates: one dictionary of lanes per metric rather than one
/// dictionary keyed by a composed "<id>.<metric>".
private var utilizationLanes: [String: HistoryLaneSlot] = [:]
private var temperatureLanes: [String: HistoryLaneSlot] = [:]

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

/// What the sidebar shows for a GPU: the model, which is the only string on
/// `GPU_Info` a person would recognize. The id is the fallback rather than the
/// first choice — it is "<model> #<index>" when it is not empty, so it adds an
/// accelerator index to a name that already reads well.
private func gpuLaneLabel(_ gpu: GPU_Info) -> String {
    if !gpu.model.isEmpty { return gpu.model }
    return gpu.id.isEmpty ? "GPU" : gpu.id
}

// MARK: - emitHistory

extension GPUs: HistoryProvider {
    public func emitHistory(reader: HistoryReaderKey, into sink: inout HistorySink) {
        let ts = sink.timestamp
        // One cross-queue copy of the whole array per tick, then in place (§2).
        // `GPUs.list` is `queue.sync { self._list }`, so an accessor call per
        // lane would be a queue hop per lane.
        let gpus = self.list

        // The label is built inside the descriptor, which runs only when a
        // lane is actually being resolved. Interpolating it on every tick
        // would put a string allocation per GPU on the hot path for a field
        // that is read once and then lives in the directory.
        for gpu in gpus {
            if let utilization = gpu.utilization,
               let lane = historyLane(&utilizationLanes, gpu.id, at: ts, into: &sink, {
                   HistoryLaneDescriptor(key: HistoryLaneKey(module: .gpu, source: gpu.id, metric: "utilization"),
                                         unit: .percent, kind: .gauge,
                                         label: "\(gpuLaneLabel(gpu)) — utilization")
               }) {
                sink.emit(lane: lane, value: utilization)
            }

            if let temperature = gpu.temperature, temperature > 0,
               let lane = historyLane(&temperatureLanes, gpu.id, at: ts, into: &sink, {
                   HistoryLaneDescriptor(key: HistoryLaneKey(module: .gpu, source: gpu.id, metric: "temperature"),
                                         unit: .celsius, kind: .gauge,
                                         label: "\(gpuLaneLabel(gpu)) — temperature")
               }) {
                sink.emit(lane: lane, value: temperature)
            }
        }
    }
}
