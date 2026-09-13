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

extension CPU_Load: HistoryProvider {
    public func emitHistory(reader: HistoryReaderKey, into sink: inout HistorySink) {
        // Filled in by "feat: history lane extraction in the module targets".
    }
}
