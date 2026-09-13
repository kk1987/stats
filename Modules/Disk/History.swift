//
//  History.swift
//  Disk
//
//  Persistent usage history: lane extraction for the Disk module.
//  The conformance lives here because Kit cannot import the module targets.
//  Design: docs/usage-history-design.md (§2 Sampling), exelban/stats#1194.
//

import Foundation
import Kit

// MARK: - lanes
//
// CapacityReader, ActivityReader and SMARTReader are all Reader<Disks> with
// partially filled instances, so each lane binds to exactly one reader key:
// `<uuid>.free` from capacity, `<uuid>.read` and `<uuid>.write` from activity.
// Identity is the volume UUID; the label keeps the volume name.

extension Disks: HistoryProvider {
    public func emitHistory(reader: HistoryReaderKey, into sink: inout HistorySink) {
        // Filled in by "feat: history lane extraction in the module targets".
    }
}
