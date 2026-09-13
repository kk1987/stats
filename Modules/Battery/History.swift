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
// lane with a bounded 15-minute hold and `power` is a rate that gaps honestly.

extension Battery_Usage: HistoryProvider {
    func emitHistory(reader: HistoryReaderKey, into sink: inout HistorySink) {
        // Filled in by "feat: history lane extraction in the module targets".
    }
}
