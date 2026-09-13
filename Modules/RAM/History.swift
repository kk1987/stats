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

extension RAM_Usage: HistoryProvider {
    public func emitHistory(reader: HistoryReaderKey, into sink: inout HistorySink) {
        // Filled in by "feat: history lane extraction in the module targets".
    }
}
