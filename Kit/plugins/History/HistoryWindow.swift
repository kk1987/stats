//
//  HistoryWindow.swift
//  Kit
//
//  Persistent usage history: the history window and its time-indexed chart.
//  Both are release 2; this file holds their skeleton so that no later commit
//  has to touch project.pbxproj.
//  Design: docs/usage-history-design.md (§5 UI), exelban/stats#1194.
//

import Cocoa

// MARK: - range

/// The ranges the top bar offers. Read-side column counts are integer multiples
/// of the tier step, capped by chart width, so the min/max envelope does not
/// stutter at exactly the ranges users stare at (§3).
public enum HistoryRange: Int, CaseIterable {
    case hour
    case sixHours
    case day
    case week
    case month
    case year

    public var seconds: Int {
        switch self {
        case .hour: return 3_600
        case .sixHours: return 6 * 3_600
        case .day: return 24 * 3_600
        case .week: return 7 * 24 * 3_600
        case .month: return 30 * 24 * 3_600
        case .year: return 365 * 24 * 3_600
        }
    }
}

// MARK: - chart

/// Time-indexed chart: range to pixel columns, a min/max band at 25% alpha
/// under a solid avg line, y axis in the lane's real unit and an x axis with
/// dates on the long ranges.
///
/// `LineChartView` is deliberately not reused (index-based x spacing, an O(n)
/// scan per append, a hardcoded percent ladder and a hardcoded `HH:mm:ss`
/// axis). `ChartView` cannot be subclassed from here either: its designated
/// initializer and its state-queue helpers are `fileprivate` to
/// `Kit/plugins/Charts.swift`.
public final class HistoryChartView: NSView {
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - columns (aggregated on the history queue, never the decoded series)
    // MARK: - draw (min/max band, avg line, gap hatch, held dashes)
    // MARK: - axes (real units, dates on 7 d / 30 d / 1 y)
    // MARK: - crosshair overlay layer
}

// MARK: - window

/// Resizable, min 760×460, frame remembered in `Store`. Lives in Kit because
/// that is the only place every module target reaches.
public final class HistoryWindowController: NSWindowController {
    public convenience init() {
        self.init(window: nil)
    }

    // MARK: - window setup and frame persistence
    // MARK: - sidebar (lanes grouped by module, filter field, default selection)
    // MARK: - top bar (range, min/max band, now/pinned, Export CSV)
    // MARK: - readout table (min/avg/max, or the value under the crosshair)
    // MARK: - keyboard (arrows, 1-6, Home/End, Esc, Tab)
    // MARK: - occlusion-gated refresh timer
}
