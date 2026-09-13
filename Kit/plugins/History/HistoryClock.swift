//
//  HistoryClock.swift
//  Kit
//
//  Persistent usage history: bucket indexing, clock-step detection and the
//  sleep/wake spans gaps are derived from.
//  Design: docs/usage-history-design.md (§4 Time handling), exelban/stats#1194.
//

import Cocoa

// MARK: - clock

/// Buckets are indexed by wall clock (`floor(epoch / step)`) so that "03:10
/// last Tuesday" is answerable. `mach_continuous_time()` is read alongside the
/// wall clock inside the bucket computation — not once per commit — so a step
/// cannot land a whole period of samples in the wrong bucket.
public struct HistoryClock {
    /// Wall/monotonic divergence beyond this many seconds means the clock stepped.
    public static let stepThreshold: TimeInterval = 2

    public init() {}

    // MARK: - bucketIndex(ts:step:)

    /// `floor(epoch / step)`. Wall-clock aligned and shared by every reader, so
    /// a 1 s and a 60 s reader land on the same grid and a runtime `setInterval`
    /// is a non-event (§2). Negative timestamps — a clock set before 1970, or an
    /// interval subtracted off a fresh boot clock — floor to bucket 0 rather
    /// than wrapping a `UInt32` around.
    public static func bucketIndex(_ ts: TimeInterval, step: Int) -> UInt32 {
        guard ts > 0, step > 0 else { return 0 }
        let index = (ts / Double(step)).rounded(.down)
        guard index.isFinite, index > 0 else { return 0 }
        return index >= Double(UInt32.max) ? UInt32.max : UInt32(index)
    }

    /// The wall-clock second a bucket starts at: the inverse of `bucketIndex`,
    /// and what the step-lane hold compares against `holdUntil` (§2).
    public static func bucketStart(_ bucket: UInt32, step: Int) -> TimeInterval {
        TimeInterval(bucket) * TimeInterval(step)
    }

    // MARK: - monotonic anchor and divergence check
    // MARK: - forward step (ring advances, skipped slots read as no-data)
    // MARK: - backward step (never overwrite a pre-step stamp; reset past a tier window)
}

// MARK: - sleep spans

/// A span of wall-clock time with no samples and a known reason.
public struct HistoryGapSpan {
    public let from: UInt64
    public let to: UInt64
    public let reason: HistoryGapReason

    public init(from: UInt64, to: UInt64, reason: HistoryGapReason) {
        self.from = from
        self.to = to
        self.reason = reason
    }
}

/// Records sleep and wake spans into a small sidecar, age-capped to T2
/// retention. There is no app-wide sleep/wake observer today — the only ones
/// live in Sensors and Bluetooth — so the recorder registers its own (§4).
public final class HistorySleepMonitor {
    public init() {}

    // MARK: - NSWorkspace willSleep / didWake observers
    // MARK: - span sidecar (append, age-cap, load at open)
    // MARK: - suspend and resume the commit timer across sleep
}
