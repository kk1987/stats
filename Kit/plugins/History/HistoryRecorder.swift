//
//  HistoryRecorder.swift
//  Kit
//
//  Persistent usage history: the ingest hook, the single commit timer and the
//  tiered rollup.
//  Design: docs/usage-history-design.md (§2, §3, §5), exelban/stats#1194.
//

import Foundation

/// The one object the rest of the app talks to. `ingest` is called from
/// `Reader.callback`, on whatever queue that reader runs on — including the
/// main run loop for Battery's IOPS notification — so it must stay allocation
/// free and must return immediately when recording is off.
public final class HistoryRecorder {
    public static let shared = HistoryRecorder()

    /// Master switch, read as the first statement of `ingest`. ON by default:
    /// a retrospective feature that is off when the anomaly happens is
    /// worthless (§6). The literal below is only the pre-`start()` value; the
    /// real one comes from `Store` with a default of `true` once the settings
    /// switch exists. Every reader queue — including main, for Battery's IOPS
    /// callback — reads this while the settings toggle writes it, so the commit
    /// that gives it a writer also gives it an atomic, or moves the read under
    /// the accumulator lock.
    public private(set) var isRecording: Bool = false

    private init() {}

    // MARK: - lifecycle (start from AppDelegate, flush on terminate)
    // MARK: - ingest(_:reader:interval:) — the hot path
    // MARK: - commit timer (60 s, 5 s leeway, .utility, suspended when clean)
    // MARK: - rollup (T1/T2 always recomputed from T0 at bucket close)
    // MARK: - catch-up at open (coarse buckets that closed while down)
    // MARK: - failure handling (free-space precondition, three strikes)
}

// MARK: - daily traffic

/// #3450's surface: an independent monotonic per-day byte counter written at
/// ingest, in its own small append-only file. Not a tiered lane, and not
/// integrated from averaged buckets. Days roll at local midnight, recomputed
/// from the current calendar on every commit tick so DST produces a 23- or
/// 25-hour day rather than a shifted one (§5).
public final class HistoryDailyTraffic {
    public init() {}

    // MARK: - add(up:down:)
    // MARK: - today and yesterday
    // MARK: - local-midnight roll and persistence
}
