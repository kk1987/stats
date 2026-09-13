//
//  History.swift
//  Net
//
//  Persistent usage history: lane extraction for the Net module.
//  The conformance lives here because Kit cannot import the module targets.
//  Design: docs/usage-history-design.md (§2 Sampling), exelban/stats#1194.
//

import Foundation
import Kit

// MARK: - lanes
//
// UsageReader: `<iface>.up` and `<iface>.down` as rate lanes, plus the daily
// byte counter. An unreachable payload and the first read after an interface
// change are detected here and recorded as no-data; the over-link-rate guard's
// zero is accepted unmarked (§2).

extension Network_Usage: HistoryProvider {
    public func emitHistory(reader: HistoryReaderKey, into sink: inout HistorySink) {
        // Filled in by "feat: history lane extraction in the module targets".
    }
}
