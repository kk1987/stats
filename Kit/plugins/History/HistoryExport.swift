//
//  HistoryExport.swift
//  Kit
//
//  Persistent usage history: CSV export of the visible range. Release 2.
//  Design: docs/usage-history-design.md (§1, §5), exelban/stats#1194.
//

import Foundation

/// Writes the visible range of the selected lanes as CSV, on the read path the
/// chart needs anyway. Gap and held buckets are marked rather than emitted as
/// values, so an exported series never presents a held or missing sample as a
/// measured one.
public final class HistoryCSVExporter {
    public init() {}

    // MARK: - header (lane label, unit, tier, range)
    // MARK: - rows (timestamp, min, avg, max, count, reason)
    // MARK: - save panel and write
}
