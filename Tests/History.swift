//
//  History.swift
//  Tests
//
//  Persistent usage history: unit tests. This file is stubbed together with the
//  rest of the skeleton and grows with the code it covers — the archive in
//  commit 2, lanes and accumulators in commit 3, the recorder in commit 4.
//  Design: docs/usage-history-design.md (§10), exelban/stats#1194.
//

import XCTest
import Kit

final class HistoryTests: XCTestCase {
    // MARK: - archive
    //
    // Ring wraparound at a tier boundary; stale-slot rejection after a wrap;
    // firstValidBucket so a fresh archive reads as no-data; header CRC
    // rejection and recreate; truncated-file recreate; directory disagreement
    // between tiers resolved from T0; header rehydration across a simulated
    // launch; a bit-flip fuzz loop; the three-strikes ENOSPC suspend and the
    // low-free-space skip.

    // MARK: - lanes and accumulators
    //
    // Rate conversion across a mid-series interval change; dt <= 0 and
    // non-finite rejection; step-lane hold over a 40-minute idle stretch; lane
    // LRU reclaim; label truncation on a scalar boundary.

    // MARK: - recorder
    //
    // Rollup with partially populated and empty fine buckets; coarse-tier
    // catch-up after a simulated restart; count-weighted resampling; gap-reason
    // derivation at read; a TSAN run with Battery ingest on main.

    // MARK: - layout
    //
    // The slot and directory geometry is a format decision, not an
    // implementation detail: it is asserted from the first commit so that a
    // later change to either width fails here rather than in a user's archive.

    func testSlotAndDirectoryGeometry() throws {
        XCTAssertEqual(HistorySlot.byteWidth, 20)
        XCTAssertEqual(HistoryLaneEntry.byteWidth, 128)
        XCTAssertEqual(HistoryLaneIdentity.byteWidth, 16)
        XCTAssertEqual(HistoryArchiveHeader.byteWidth, 4096)
    }

    func testTierGeometryMatchesTheRetentionTable() throws {
        XCTAssertEqual(HistoryTier.t0.step, 10)
        XCTAssertEqual(HistoryTier.t1.step, 120)
        XCTAssertEqual(HistoryTier.t2.step, 1800)

        // 24 h, 30 d and 365 d of buckets.
        XCTAssertEqual(HistoryTier.t0.buckets, 24 * 3600 / HistoryTier.t0.step)
        XCTAssertEqual(HistoryTier.t1.buckets, 30 * 24 * 3600 / HistoryTier.t1.step)
        XCTAssertEqual(HistoryTier.t2.buckets, 365 * 24 * 3600 / HistoryTier.t2.step)

        XCTAssertEqual(HistoryRetentionPreset.minimal.tiers, [.t0])
        XCTAssertEqual(HistoryRetentionPreset.standard.tiers, [.t0, .t1, .t2])
    }
}
