//
//  HistoryAccumulator.swift
//  Kit
//
//  Persistent usage history: the typed extraction protocol and the in-memory
//  bucket accumulators the commit thread drains.
//  Design: docs/usage-history-design.md (§2 Sampling), exelban/stats#1194.
//

import Foundation

// MARK: - reader identity

/// Identifies the reader a sample came from. Passed explicitly, never inferred
/// from the payload type: `CapacityReader`, `ActivityReader` and `SMARTReader`
/// are all `Reader<Disks>` with partially filled instances (§2).
public struct HistoryReaderKey: Hashable {
    public let module: ModuleType
    public let name: String

    public init(module: ModuleType, name: String) {
        self.module = module
        self.name = name
    }
}

// MARK: - extraction

/// The pre-sized buffer a payload writes its scalars into. Lanes resolve to
/// integer ids at registration, so the hot path allocates nothing.
public struct HistorySink {
    public init() {}

    // MARK: - lane resolution (key -> integer id, cached per reader)
    // MARK: - emit (value, unit, kind; rejects non-finite before folding)
}

/// Typed extraction, implemented by the payload types in the module targets.
/// Kit cannot import the module targets, so the conformances cannot live here;
/// a rename upstream therefore fails to compile instead of dying silently (§2).
public protocol HistoryProvider {
    func emitHistory(reader: HistoryReaderKey, into sink: inout HistorySink)
}

// MARK: - accumulator

/// Per-lane fold state for the bucket currently open. Snapshotted and reset
/// under the lock by the commit thread, which then writes with it released.
public struct HistoryAccumulator {
    public var bucket: UInt32 = 0
    public var count: UInt16 = 0
    public var min: Float = 0
    public var max: Float = 0
    public var sum: Float = 0

    /// Step lanes only (battery `level`): the value to hold and how long for.
    public var lastValue: Float = 0
    public var lastSampleTs: UInt64 = 0
    public var holdUntil: UInt64 = 0

    public init() {}

    // MARK: - fold (min/max/sum/count, rate conversion by actual elapsed time)
    // MARK: - snapshot and reset
}

/// The fixed-size accumulator table, guarded by a heap-allocated
/// `os_unfair_lock` (macOS 12 rules out `OSAllocatedUnfairLock`).
public final class HistoryAccumulatorTable {
    /// Bounded by the lane cap, so the table is ~16 KiB at the worst case.
    public init(capacity: Int = HistoryLaneDirectory.laneCap) {}

    // MARK: - lock
    // MARK: - fold a sink into the open buckets
    // MARK: - drain closed buckets for the commit thread
    // MARK: - step-lane hold (15 min cap, written as .held)
}
