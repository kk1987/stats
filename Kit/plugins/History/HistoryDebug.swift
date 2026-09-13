//
//  HistoryDebug.swift
//  Kit
//
//  Persistent usage history: debug-only seeding, so that a developer can look
//  at a year of history without waiting a year for it. Never compiled into a
//  release build, and deliberately kept out of Stats/helpers.swift (§9).
//  Design: docs/usage-history-design.md, exelban/stats#1194.
//

#if DEBUG
import Foundation

internal enum HistoryDebugSeeder {
    // MARK: - seed(lanes:range:) — synthetic lanes across every tier
    // MARK: - seed gaps (asleep, not running, clock step, held)
    // MARK: - wipe
}
#endif
