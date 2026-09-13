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

extension GPUs: HistoryProvider {
    public func emitHistory(reader: HistoryReaderKey, into sink: inout HistorySink) {
        // Filled in by "feat: history lane extraction in the module targets".
    }
}
