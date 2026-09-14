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
import os

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

    /// Whether the x axis reads in dates rather than in times. §5: times up to
    /// a day, dates on 7 d / 30 d / 1 y — five labels all reading "14:32:05"
    /// on a thirty-day view answer nothing.
    public var usesDateAxis: Bool { self.seconds > 24 * 3_600 }

    /// What the top bar's range control reads. Translated rather than spelled
    /// "24h", because §5 says the range labels are among the strings that get
    /// translated and an abbreviation is not language-neutral.
    public var localizedTitle: String {
        switch self {
        case .hour: return localizedString("1 hour")
        case .sixHours: return localizedString("6 hours")
        case .day: return localizedString("24 hours")
        case .week: return localizedString("7 days")
        case .month: return localizedString("30 days")
        case .year: return localizedString("1 year")
        }
    }

    /// How often a live window re-reads this range. A 10 s column is stale in
    /// ten seconds; a six-hour one is not, and re-reading 40 MB of T2 every ten
    /// seconds to move a year-long chart by nothing is exactly the poll §5
    /// gates on occlusion to avoid.
    public var refreshInterval: TimeInterval {
        switch self {
        case .hour, .sixHours: return 10
        case .day, .week: return 60
        case .month, .year: return 300
        }
    }
}

// MARK: - presentation of a stored value

public extension HistoryLaneUnit {
    /// One stored scalar in the unit it was recorded in.
    ///
    /// Kit's own formatters do the work — `Units` for the two byte units and
    /// `temperature` for °C, which is also what converts to °F for a user who
    /// asked for it. The three sensor units have no Kit formatter because
    /// `Sensor_p.formattedValue` lives in `Modules/Sensors`, which Kit cannot
    /// import (§2); the conventions below are copied from it so that the same
    /// fan reads the same way in the popup and in the history window.
    ///
    /// Percent lanes store a fraction of 1, so they are scaled here and only
    /// here.
    func format(_ value: Float) -> String {
        guard value.isFinite else { return "—" }
        let value = Double(value)

        switch self {
        case .percent:
            return "\(HistoryLaneUnit.intValue((value * 100).rounded()))%"
        case .bytesPerSec:
            return Units(bytes: HistoryLaneUnit.byteCount(value)).getReadableSpeed()
        case .bytes:
            return Units(bytes: HistoryLaneUnit.byteCount(value)).getReadableMemory()
        case .celsius:
            return temperature(value)
        case .watts:
            return value >= 100 ? "\(HistoryLaneUnit.intValue(value)) W" : String(format: "%.2f W", value)
        case .volts:
            return value >= 100 ? "\(HistoryLaneUnit.intValue(value)) V" : String(format: "%.3f V", value)
        case .rpm:
            return "\(HistoryLaneUnit.intValue(value)) RPM"
        }
    }

    /// `Units` takes an `Int64`, and `Int64(_: Double)` traps on anything that
    /// does not fit. A rate is a ratio of two measured numbers and a bit flip
    /// inside the matrix is bounded but not impossible, so the conversion is
    /// clamped rather than trusted.
    private static func byteCount(_ value: Double) -> Int64 {
        guard value > 0 else { return 0 }
        return value >= Double(Int64.max) ? Int64.max : Int64(value)
    }

    /// The same clamp for the four units that print a whole number of their
    /// own, and for the unitless axis tick.
    ///
    /// `isFinite` is not enough on its own: a `Float` reaches 3.4e38 and
    /// `Int.max` is 9.2e18, so a finite value read back from the matrix can
    /// still be an order of magnitude past what an `Int` holds — and
    /// `Int(_: Double)` traps rather than throwing. Nothing upstream of here
    /// stops it, either: a slot is validated by its 4-byte bucket stamp, which
    /// says nothing about the twelve bytes of value behind it, and
    /// `HistoryAggregate.rollup` checks `isFinite` and no magnitude. One
    /// flipped exponent bit — 2,000 rpm is `0x44FA0000`, flip the top exponent
    /// bit and it is a finite 1.04e37 — would otherwise reach an axis label
    /// and take the app down from a formatter.
    fileprivate static func intValue(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        if value >= Double(Int.max) { return Int.max }
        if value <= Double(Int.min) { return Int.min }
        return Int(value)
    }
}

public extension HistoryGapReason {
    /// What a gap says in words — the sentence that turns a hole into an
    /// answer to "when did it start, how long did it last" (§4).
    var localizedTitle: String {
        switch self {
        case .measured: return localizedString("Recorded")
        case .held: return localizedString("Last known value")
        case .asleep: return localizedString("Asleep")
        case .notRunning: return localizedString("Stats not running")
        case .clockStep: return localizedString("Clock changed")
        case .nodata: return localizedString("No data")
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
///
/// Main thread only, and it holds no queue of its own: everything expensive
/// already happened on the history queue, which hands it columns and never the
/// decoded series (§7).
public final class HistoryChartView: NSView {
    /// One drawn lane: the columns the history queue produced, and the colour
    /// the window picked for it — one system colour per module, shaded toward
    /// grey for the second and later lane of the same module. There is no
    /// `<Module>_color` key to take it from; `HistoryLaneModule.accent` carries
    /// the whole argument.
    public struct Lane {
        public let columns: HistoryLaneColumns
        public let color: NSColor

        public init(columns: HistoryLaneColumns, color: NSColor = .controlAccentColor) {
            self.columns = columns
            self.color = color
        }

        public var label: String { self.columns.entry.label }
        public var unit: HistoryLaneUnit { self.columns.entry.unit }
    }

    /// The gutters the axes live in. The y gutter fits "1000 MB/s" at 9 pt.
    private static let yAxisWidth: CGFloat = 56
    private static let xAxisHeight: CGFloat = 14
    /// §5: the min/max band sits under a solid avg line at 25% alpha.
    private static let bandAlpha: CGFloat = 0.25
    private static let yTicks: Int = 5
    private static let axisFont: NSFont = .systemFont(ofSize: 9, weight: .light)
    /// Pixels between the diagonals of the gap hatch.
    private static let hatchSpacing: CGFloat = 5
    /// A held span is drawn dashed, so a held value is never presented as a
    /// measured one (§2).
    private static let heldDash: [CGFloat] = [3, 2]

    /// Called with the column under the pointer, or `nil` when it leaves. The
    /// readout table is what listens (§5); the chart itself only moves the
    /// crosshair.
    public var onHover: ((Int?) -> Void)?

    /// §5's min/max band toggle. The band path is built either way, so turning
    /// it off is a redraw and not a geometry rebuild — which is what lets the
    /// top bar flip it on a 1,460-column year without a visible stall.
    public var showsMinMaxBand: Bool = true {
        didSet {
            guard self.showsMinMaxBand != oldValue else { return }
            self.needsDisplay = true
        }
    }

    private var plan: HistoryColumnPlan?
    private var lanes: [Lane] = []

    // Everything below is derived and cached: rebuilt on a range or selection
    // change and on a resize, never on a mouse move (§5).
    private var geometry: [LaneGeometry] = []
    private var gapRuns: [Range<Int>] = []
    private var scale: ValueScale?
    private var accessibilityCache: [NSAccessibilityElement] = []
    private var geometrySize: NSSize = .zero
    private var geometryValid = false

    private let crosshairLayer = CAShapeLayer()
    private var hovered: Int?
    private var tracking: NSTrackingArea?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        self.wantsLayer = true
        self.layerContentsRedrawPolicy = .onSetNeedsDisplay
        self.crosshairLayer.lineWidth = 1
        self.crosshairLayer.isHidden = true
        // AppKit sets `contentsScale` on the view's own backing layer, never on
        // a sublayer added by hand, and the default is 1: a 1 pt crosshair
        // would rasterize at 1x and read soft on every Retina display.
        self.crosshairLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        self.layer?.addSublayer(self.crosshairLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - columns (aggregated on the history queue, never the decoded series)

    /// Replaces everything the chart draws. The only entry point, because the
    /// cached geometry is only correct for one (plan, lanes) pair and rebuilding
    /// it is the expensive half of a redraw.
    public func setLanes(_ lanes: [Lane], plan: HistoryColumnPlan) {
        self.lanes = lanes
        self.plan = plan
        self.invalidateGeometry()
        // The accessibility elements read the summary numbers and not the
        // pixels, so they are built here rather than waiting for a draw: a
        // VoiceOver query that arrives before the first one — or while the
        // window is occluded, which is exactly when the refresh timer is
        // gated off — would otherwise find the chart an empty group.
        self.accessibilityCache = self.buildAccessibilityElements(plan: plan, plot: self.plotRect)
        self.setHovered(nil)
        self.needsDisplay = true
    }

    public var columnCount: Int { self.plan?.columns ?? 0 }

    /// How many columns are worth asking the history queue for: a column
    /// narrower than a pixel is work nobody can see, so the plot's width in
    /// points is the budget `HistoryColumnPlan.plan` widens columns against.
    public var columnBudget: Int { max(1, Int(self.plotRect.width.rounded(.down))) }

    /// The wall-clock second a column starts at, for the readout's header.
    public func columnStart(_ column: Int) -> TimeInterval? {
        guard let plan = self.plan, column >= 0, column < plan.columns else { return nil }
        return plan.columnStart(column)
    }

    /// Drops the cached paths. The accessibility elements survive on purpose —
    /// a resize moves their frames but not a word of what they say, and an
    /// element whose frame is one redraw out of date is a better answer to a
    /// VoiceOver query than no element at all.
    private func invalidateGeometry() {
        self.geometryValid = false
        self.geometry = []
    }

    // MARK: - layout

    /// The rectangle the series are drawn in: the view minus the two axis
    /// gutters.
    private var plotRect: NSRect {
        NSRect(x: HistoryChartView.yAxisWidth, y: HistoryChartView.xAxisHeight,
               width: max(0, self.bounds.width - HistoryChartView.yAxisWidth),
               height: max(0, self.bounds.height - HistoryChartView.xAxisHeight))
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if newSize != self.geometrySize { self.invalidateGeometry() }
        // The path and not just the frame: the crosshair's x is a fraction of
        // the plot, so a resize with the pointer inside would otherwise leave
        // it standing at its pre-resize column until the next mouse move.
        self.updateCrosshairPath()
        self.needsDisplay = true
    }

    /// The window moved to a display with a different backing scale.
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = self.window?.backingScaleFactor ?? self.layer?.contentsScale ?? 2
        guard self.crosshairLayer.contentsScale != scale else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.crosshairLayer.contentsScale = scale
        CATransaction.commit()
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking = self.tracking { self.removeTrackingArea(tracking) }

        // Deliberately without `.activeAlways` (§5): a chart in a window behind
        // Xcode has no crosshair to move.
        let tracking = NSTrackingArea(rect: self.bounds,
                                      options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
        self.addTrackingArea(tracking)
        self.tracking = tracking
    }

    /// Semantic colours everywhere, so a theme switch is a redraw and not a
    /// rebuild: the cached paths carry geometry, never colour (§5).
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        self.updateCrosshairColor()
        self.needsDisplay = true
    }

    // MARK: - draw (min/max band, avg line, gap hatch, held dashes)

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let plot = self.plotRect
        guard plot.width > 1, plot.height > 1 else { return }
        self.rebuildGeometryIfNeeded()
        guard let plan = self.plan else { return }

        // Gaps first and underneath: a hatch the series are drawn over reads as
        // background, which is what it is.
        let columnWidth = plot.width / CGFloat(max(1, plan.columns))
        self.drawHatch(over: self.gapRuns, columnWidth: columnWidth, in: plot)

        // The x axis is drawn from the plan and from nothing else, so it is
        // drawn before the lanes have a say: a window opened with no lane
        // checked shows the range it is looking at rather than an empty
        // rectangle. The y axis is in the lanes' own unit and there is no unit
        // to label without one, which is why it is the one that waits.
        self.drawXAxis(plan, in: plot)
        guard let scale = self.scale else { return }
        self.drawYAxis(scale, in: plot)

        for lane in self.geometry {
            if self.showsMinMaxBand {
                lane.color.withAlphaComponent(HistoryChartView.bandAlpha).setFill()
                lane.band.fill()
            }

            lane.color.setStroke()
            lane.solid.lineWidth = 1.25
            lane.solid.stroke()

            let dashed = lane.dashed
            dashed.lineWidth = 1.25
            dashed.setLineDash(HistoryChartView.heldDash, count: HistoryChartView.heldDash.count, phase: 0)
            dashed.stroke()
        }
    }

    /// 45°, in `separatorColor`, clipped to the gap columns. The angle is what
    /// says "nothing was measured here" rather than "something was zero here",
    /// and the series is broken across it rather than interpolated (§4).
    ///
    /// One sweep across the whole plot, clipped to the union of the runs,
    /// rather than one sweep per run. A diagonal of height `h` has to start `h`
    /// to the left of the rectangle it fills, so a per-run sweep costs
    /// `(width + height) / spacing` segments however narrow the run is — ~80 of
    /// them for a one-column gap on a 400 pt chart, all but one clipped away.
    /// A sporadically sampled lane alternates gap and data column by column, so
    /// at ~180 runs that is tens of thousands of discarded segments per draw,
    /// on main. Sweeping once also lays every run's hatch on one grid instead
    /// of restarting the phase at each run's own left edge.
    private func drawHatch(over runs: [Range<Int>], columnWidth: CGFloat, in plot: NSRect) {
        guard !runs.isEmpty, plot.width > 0, plot.height > 0 else { return }

        let clip = NSBezierPath()
        for run in runs {
            clip.appendRect(NSRect(x: plot.minX + CGFloat(run.lowerBound) * columnWidth, y: plot.minY,
                                   width: CGFloat(run.count) * columnWidth, height: plot.height))
        }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        clip.setClip()
        NSColor.separatorColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        var x = plot.minX - plot.height
        while x <= plot.maxX {
            path.move(to: CGPoint(x: x, y: plot.minY))
            path.line(to: CGPoint(x: x + plot.height, y: plot.maxY))
            x += HistoryChartView.hatchSpacing
        }
        path.stroke()
    }

    // MARK: - axes (real units, dates on 7 d / 30 d / 1 y)

    private func drawYAxis(_ scale: ValueScale, in plot: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: HistoryChartView.axisFont,
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let grid = NSColor.separatorColor.withAlphaComponent(0.5)
        let height = HistoryChartView.axisFont.ascender - HistoryChartView.axisFont.descender

        for tick in 0..<HistoryChartView.yTicks {
            let fraction = Float(tick) / Float(HistoryChartView.yTicks - 1)
            let value = scale.lower + (scale.upper - scale.lower) * fraction
            let y = plot.minY + plot.height * CGFloat(fraction)

            grid.setStroke()
            let line = NSBezierPath()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.line(to: CGPoint(x: plot.maxX, y: y))
            line.lineWidth = 1 / (self.window?.backingScaleFactor ?? 1)
            line.stroke()

            let text = scale.format(value)
            let width = text.widthOfString(usingFont: HistoryChartView.axisFont)
            let box = NSRect(x: max(0, HistoryChartView.yAxisWidth - 4 - width),
                             y: min(plot.maxY - height, y - height / 2), width: width, height: height)
            NSAttributedString(string: text, attributes: attributes).draw(with: box)
        }
    }

    private func drawXAxis(_ plan: HistoryColumnPlan, in plot: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: HistoryChartView.axisFont,
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let formatter = HistoryChartView.axisFormatter(for: plan.range)
        // One label per ~80 pt, so the axis thins out with the window instead
        // of overprinting itself.
        let count = max(2, min(8, Int(plot.width / 80)))
        var lastMaxX: CGFloat = -.greatestFiniteMagnitude

        for index in 0..<count {
            let fraction = CGFloat(index) / CGFloat(count - 1)
            let column = min(plan.columns - 1, Int(fraction * CGFloat(max(1, plan.columns - 1))))
            let text = formatter.string(from: Date(timeIntervalSince1970: plan.columnStart(column)))
            let width = text.widthOfString(usingFont: HistoryChartView.axisFont)
            var x = plot.minX + plot.width * fraction - width / 2
            x = max(plot.minX, min(x, plot.maxX - width))
            guard x >= lastMaxX else { continue }
            NSAttributedString(string: text, attributes: attributes)
                .draw(with: NSRect(x: x, y: 0, width: width, height: HistoryChartView.xAxisHeight))
            lastMaxX = x + width + 8
        }
    }

    /// Times up to a day, dates beyond it. Built from a localized template
    /// rather than a literal format, so the order and the separators follow the
    /// user's locale.
    private static func axisFormatter(for range: HistoryRange) -> DateFormatter {
        let template: String
        switch range {
        case .hour, .sixHours, .day: template = "jmm"
        case .week, .month: template = "MMMd"
        case .year: template = "yMMM"
        }

        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: template, options: 0, locale: .current)
        return formatter
    }

    // MARK: - crosshair overlay layer

    public override func mouseMoved(with event: NSEvent) {
        let point = self.convert(event.locationInWindow, from: nil)
        self.setHovered(self.column(at: point))
    }

    public override func mouseExited(with event: NSEvent) {
        self.setHovered(nil)
    }

    /// The column under a point in view coordinates, or `nil` outside the plot.
    public func column(at point: NSPoint) -> Int? {
        guard let plan = self.plan, plan.columns > 0 else { return nil }
        let plot = self.plotRect
        guard plot.width > 0, plot.contains(point) else { return nil }
        let fraction = (point.x - plot.minX) / plot.width
        return max(0, min(plan.columns - 1, Int(fraction * CGFloat(plan.columns))))
    }

    /// Moves the crosshair without touching the lanes. The whole point of the
    /// overlay layer: scrubbing a 1,460-column year would otherwise rebuild
    /// every band and every line per mouse event (§5).
    public func setHovered(_ column: Int?) {
        guard column != self.hovered else { return }
        self.hovered = column
        self.updateCrosshairPath()
        self.onHover?(column)
    }

    public var hoveredColumn: Int? { self.hovered }

    private func updateCrosshairPath() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard let plan = self.plan, let column = self.hovered, plan.columns > 0 else {
            self.crosshairLayer.isHidden = true
            return
        }

        let plot = self.plotRect
        let width = plot.width / CGFloat(plan.columns)
        let x = (plot.minX + (CGFloat(column) + 0.5) * width).rounded() + 0.5
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x, y: plot.minY))
        path.addLine(to: CGPoint(x: x, y: plot.maxY))

        self.crosshairLayer.frame = self.bounds
        self.crosshairLayer.path = path
        self.updateCrosshairColor()
        self.crosshairLayer.isHidden = false
    }

    /// A `CGColor` carries no appearance, so a semantic `NSColor` has to be
    /// resolved against this view's own appearance every time it is handed to a
    /// layer — including from `viewDidChangeEffectiveAppearance`.
    private func updateCrosshairColor() {
        self.effectiveAppearance.performAsCurrentDrawingAppearance {
            self.crosshairLayer.strokeColor = NSColor.secondaryLabelColor.cgColor
            self.crosshairLayer.fillColor = NSColor.clear.cgColor
        }
    }

    // MARK: - geometry cache

    private struct LaneGeometry {
        let color: NSColor
        /// The min/max envelope, one closed subpath per run of data.
        let band: NSBezierPath
        /// The average, broken at every gap and never interpolated across one.
        let solid: NSBezierPath
        /// The part of the average that was held rather than measured (§2).
        let dashed: NSBezierPath
    }

    private func rebuildGeometryIfNeeded() {
        guard !self.geometryValid || self.geometrySize != self.bounds.size else { return }
        self.rebuildGeometry()
    }

    private func rebuildGeometry() {
        self.geometrySize = self.bounds.size
        self.geometryValid = true
        self.geometry = []
        self.gapRuns = []
        self.scale = nil

        guard let plan = self.plan, plan.columns > 0 else {
            self.accessibilityCache = []
            return
        }
        // Re-stated rather than kept, so the element frames follow a resize.
        self.accessibilityCache = self.buildAccessibilityElements(plan: plan, plot: self.plotRect)

        guard !self.lanes.isEmpty else { return }
        let plot = self.plotRect
        guard plot.width > 1, plot.height > 1 else { return }

        let scale = ValueScale(lanes: self.lanes)
        self.scale = scale
        let width = plot.width / CGFloat(plan.columns)

        for lane in self.lanes {
            self.geometry.append(self.laneGeometry(for: lane, scale: scale, plot: plot, columnWidth: width))
        }
        self.gapRuns = HistoryChartView.emptyRuns(self.lanes, columns: plan.columns)
    }

    private func laneGeometry(for lane: Lane, scale: ValueScale, plot: NSRect, columnWidth: CGFloat) -> LaneGeometry {
        let band = NSBezierPath()
        let solid = NSBezierPath()
        let dashed = NSBezierPath()
        let x: (Int) -> CGFloat = { plot.minX + (CGFloat($0) + 0.5) * columnWidth }

        // A run is a stretch of consecutive columns that hold a sample. The
        // band and the line are built per run, which is what "never
        // interpolated across a gap" means in practice: a gap ends the run and
        // the next one starts with a fresh `move(to:)`.
        for run in HistoryChartView.dataRuns(lane.columns.columns) {
            let columns = run.compactMap { lane.columns.columns[$0] }
            guard columns.count == run.count else { continue }

            band.move(to: CGPoint(x: x(run.lowerBound), y: scale.y(columns[0].max, in: plot)))
            for (offset, column) in columns.enumerated().dropFirst() {
                band.line(to: CGPoint(x: x(run.lowerBound + offset), y: scale.y(column.max, in: plot)))
            }
            for (offset, column) in columns.enumerated().reversed() {
                band.line(to: CGPoint(x: x(run.lowerBound + offset), y: scale.y(column.min, in: plot)))
            }
            band.close()

            // The average is split again wherever a measured stretch meets a
            // held one, and the two pieces share the boundary point so the line
            // stays connected while changing style.
            var previous: CGPoint?
            var wasHeld = columns[0].reason == .held
            for (offset, column) in columns.enumerated() {
                let point = CGPoint(x: x(run.lowerBound + offset), y: scale.y(column.avg, in: plot))
                let isHeld = column.reason == .held
                let path = isHeld ? dashed : solid
                if let previous = previous {
                    if isHeld != wasHeld {
                        path.move(to: previous)
                    }
                    path.line(to: point)
                } else {
                    path.move(to: point)
                }
                previous = point
                wasHeld = isHeld
            }
            // A one-column run has no segment to stroke; a dot keeps it visible.
            if columns.count == 1, let point = previous {
                let path = wasHeld ? dashed : solid
                path.line(to: CGPoint(x: point.x + 0.5, y: point.y))
            }
        }

        return LaneGeometry(color: lane.color, band: band, solid: solid, dashed: dashed)
    }

    /// The runs of consecutive columns that hold a sample.
    private static func dataRuns(_ columns: [HistoryColumn?]) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        for index in columns.indices {
            let hasData = (columns[index]?.count ?? 0) > 0
            if hasData, start == nil { start = index }
            if !hasData, let from = start {
                runs.append(from..<index)
                start = nil
            }
        }
        if let from = start { runs.append(from..<columns.count) }
        return runs
    }

    /// The runs of columns in which *no* drawn lane has a sample.
    ///
    /// Per-lane gaps are already visible — the line stops — and hatching each
    /// of them separately would lay four overlapping textures over a chart with
    /// four lanes. The hatch therefore marks the gaps the whole chart shares,
    /// which are exactly the ones the feature exists to explain: asleep, not
    /// running, clock changed.
    private static func emptyRuns(_ lanes: [Lane], columns: Int) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        for index in 0..<columns {
            let empty = lanes.allSatisfy { lane in
                index >= lane.columns.columns.count || (lane.columns.columns[index]?.count ?? 0) == 0
            }
            if empty, start == nil { start = index }
            if !empty, let from = start {
                runs.append(from..<index)
                start = nil
            }
        }
        if let from = start { runs.append(from..<columns) }
        return runs
    }

    // MARK: - value scale

    /// One shared y scale in real units, never a normalized overlay: §1 rejects
    /// normalizing because two lines at one pixel height meaning 40 °C and 9 GB
    /// misleads. Lanes that do not share a unit therefore share the scale and
    /// lose the unit suffix on the labels — a °C lane against a bytes lane
    /// really is flat at the bottom, and saying so is the honest answer.
    private struct ValueScale {
        let lower: Float
        let upper: Float
        let unit: HistoryLaneUnit?

        init(lanes: [Lane]) {
            let units = Set(lanes.map { $0.unit })
            let unit = units.count == 1 ? units.first : nil
            self.unit = unit

            if unit == .percent {
                // A percent lane is a fraction of 1 and its axis is the whole
                // of it, so 20% CPU looks like 20% of the chart rather than
                // filling it.
                self.lower = 0
                self.upper = 1
                return
            }

            var low: Float = 0
            var high: Float = 0
            var seen = false
            for summary in lanes.compactMap({ $0.columns.summary }) {
                if !seen {
                    low = summary.min
                    high = summary.max
                    seen = true
                } else {
                    if summary.min < low { low = summary.min }
                    if summary.max > high { high = summary.max }
                }
            }

            guard seen else {
                self.lower = 0
                self.upper = 1
                return
            }
            // Zero-based unless the data is not: a temperature axis starting at
            // 0 °C wastes two thirds of the chart, a rate axis that does not
            // makes an idle link look busy.
            let lower = (unit == .celsius || low < 0) ? ValueScale.nice(low, up: false) : 0
            let upper = ValueScale.nice(high, up: true)
            self.lower = lower
            self.upper = upper > lower ? upper : lower + 1
        }

        func y(_ value: Float, in rect: NSRect) -> CGFloat {
            let span = self.upper - self.lower
            guard span > 0, value.isFinite else { return rect.minY }
            let clamped = Swift.min(Swift.max(value, self.lower), self.upper)
            return rect.minY + rect.height * CGFloat((clamped - self.lower) / span)
        }

        func format(_ value: Float) -> String {
            guard let unit = self.unit else { return ValueScale.plain(value) }
            return unit.format(value)
        }

        /// The tick value when the lanes do not share a unit and no formatter
        /// can be right for all of them.
        private static func plain(_ value: Float) -> String {
            let magnitude = Swift.abs(value)
            if magnitude >= 100 { return "\(HistoryLaneUnit.intValue(Double(value).rounded()))" }
            return String(format: magnitude >= 1 ? "%.1f" : "%.2f", value)
        }

        /// Rounds an axis bound out to 1, 2, 2.5 or 5 × a power of ten, so the
        /// ticks land on numbers a person reads rather than on the extremes of
        /// whatever happened to be recorded.
        private static func nice(_ value: Float, up: Bool) -> Float {
            guard value != 0, value.isFinite else { return 0 }
            let magnitude = Double(Swift.abs(value))
            let exponent = (log10(magnitude)).rounded(.down)
            let power = pow(10, exponent)
            let normalized = magnitude / power
            let steps: [Double] = [1, 2, 2.5, 5, 10]
            let outward = value > 0 ? up : !up
            let step = outward
                ? (steps.first { $0 >= normalized } ?? 10)
                : (steps.last { $0 <= normalized } ?? 1)
            return Float((value > 0 ? 1 : -1) * step * power)
        }
    }

    // MARK: - accessibility

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .group }
    public override func accessibilityLabel() -> String? { localizedString("Usage history chart") }
    public override func accessibilityChildren() -> [Any]? { self.accessibilityCache }

    /// A summary naming the range and the lane count, then one element per
    /// visible lane (§5). Built from the columns and from the plot rectangle,
    /// never from the cached paths, which is what lets `setLanes` have them
    /// ready before anything is drawn.
    private func buildAccessibilityElements(plan: HistoryColumnPlan, plot: NSRect) -> [NSAccessibilityElement] {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .short
        formatter.timeStyle = plan.range.usesDateAxis ? .none : .short

        let from = formatter.string(from: Date(timeIntervalSince1970: plan.start))
        let to = formatter.string(from: Date(timeIntervalSince1970: plan.end))
        let key = self.lanes.count == 1 ? "%0 lane, %1 to %2" : "%0 lanes, %1 to %2"
        var elements = [self.accessibilityElement(
            label: localizedString("Usage history chart"),
            value: localizedString(key, "\(self.lanes.count)", from, to),
            frame: plot
        )]

        let height = self.lanes.isEmpty ? plot.height : plot.height / CGFloat(self.lanes.count)
        for (index, lane) in self.lanes.enumerated() {
            let value: String
            if let summary = lane.columns.summary {
                value = localizedString("Minimum %0, average %1, maximum %2",
                                        lane.unit.format(summary.min),
                                        lane.unit.format(summary.avg),
                                        lane.unit.format(summary.max))
            } else {
                value = HistoryChartView.dominantReason(lane.columns.columns).localizedTitle
            }
            elements.append(self.accessibilityElement(
                label: lane.label, value: value,
                frame: NSRect(x: plot.minX, y: plot.minY + CGFloat(index) * height,
                              width: plot.width, height: height)
            ))
        }
        return elements
    }

    private func accessibilityElement(label: String, value: String, frame: NSRect) -> NSAccessibilityElement {
        let element = NSAccessibilityElement()
        element.setAccessibilityRole(.staticText)
        element.setAccessibilityLabel(label)
        element.setAccessibilityValue(value)
        element.setAccessibilityParent(self)
        element.setAccessibilityFrameInParentSpace(frame)
        return element
    }

    /// Why a lane that drew nothing drew nothing: the reason most of its empty
    /// columns agree on, so VoiceOver says "Asleep" rather than "no data" for a
    /// night the machine was demonstrably asleep.
    private static func dominantReason(_ columns: [HistoryColumn?]) -> HistoryGapReason {
        var counts: [UInt8: Int] = [:]
        for column in columns {
            let reason = column?.reason ?? .nodata
            counts[reason.rawValue, default: 0] += 1
        }
        guard let best = counts.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value })?.key else {
            return .nodata
        }
        return HistoryGapReason(rawValue: best) ?? .nodata
    }
}

// MARK: - per-lane opt-in (the sidebar is where it lives)

/// The lanes a module *could* record but does not by default, and the set of
/// them the user has turned on.
///
/// v1 has exactly one source: Sensors. `sensor_<key>_popup` defaults to `true`
/// for every discovered sensor and fan, so "record what the user pinned" would
/// silently enable 50–150 lanes and multiply the footprint ~5× (§1). v1 records
/// every fan plus a curated temperature list and leaves the rest to a checkbox
/// in this window's sidebar — the one place every lane is already enumerated
/// with its module, its label and its last-seen date, which is why §6 refuses a
/// second copy of the same table in `Modules/Sensors/settings.swift`.
///
/// Two halves that look alike and are not. The *catalogue* is what a module
/// reports the running machine could produce: rebuilt from hardware on every
/// launch and never persisted. The *enabled set* is the user's answer: written
/// to `Store`, and deliberately kept for hardware that is not plugged in today,
/// because a sensor that comes back should come back recording.
public final class HistoryOptionalLanes {
    public static let shared = HistoryOptionalLanes()

    /// A set rather than a toggle, so it is stored as one newline-joined
    /// string: no stable key contains a newline, and `Store`'s string accessors
    /// avoid the `[Any]` round trip its array ones need.
    public static let settingsKey: String = "history_optional_lanes"
    private static let separator: Character = "\n"

    /// Guards both halves. `isEnabled` is read from `emitHistory` — a reader
    /// queue, and main for Battery — while the sidebar writes from main, so an
    /// unsynchronized `Set` here would be a data race whatever it holds.
    ///
    /// **This is the inner lock and has to stay that way.** `emitHistory` runs
    /// inside `HistoryRecorder.ingest`, which holds the recorder's own lock, so
    /// the one ordering that exists today is recorder → this one. Nothing here
    /// calls into the recorder, and nothing outside takes this lock and then
    /// the recorder's: `setEnabled` and the sidebar run on main and take this
    /// one alone.
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var enabled: Set<String>
    private var enabledRevision: UInt64 = 1
    private var catalogue: [String: HistoryLaneDescriptor] = [:]
    private var catalogueRevision: UInt64 = 0

    private init() {
        self.lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        self.lock.initialize(to: os_unfair_lock())
        let stored = Store.shared.string(key: HistoryOptionalLanes.settingsKey, defaultValue: "")
        self.enabled = Set(stored.split(separator: HistoryOptionalLanes.separator).map(String.init))
    }

    deinit {
        self.lock.deinitialize(count: 1)
        self.lock.deallocate()
    }

    @inline(__always)
    private func locked<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(self.lock)
        defer { os_unfair_lock_unlock(self.lock) }
        return body()
    }

    /// Reports a lane the machine can produce and v1 does not record by
    /// default. Called from `emitHistory`, so the caller is expected to keep
    /// its own "already offered" set and to stop calling once it has offered a
    /// key — this does the same check a second time rather than trusting it,
    /// but it does it after hashing a string.
    public func offer(_ descriptor: HistoryLaneDescriptor) {
        let key = descriptor.key.stableKey
        self.locked {
            guard self.catalogue[key] == nil else { return }
            self.catalogue[key] = descriptor
            self.catalogueRevision &+= 1
        }
    }

    public func isEnabled(_ key: HistoryLaneKey) -> Bool {
        self.isEnabled(stableKey: key.stableKey)
    }

    public func isEnabled(stableKey: String) -> Bool {
        self.locked { self.enabled.contains(stableKey) }
    }

    /// Bumped whenever the enabled set changes, so a caller on the ingest path
    /// can read it once per tick and re-ask `isEnabled` only for the sensors
    /// whose cached answer predates it. Starts at 1, so a zero-initialized
    /// cache always asks once. `Modules/Sensors/History.swift` is the caller
    /// this exists for: without it the 116-sensor worst case is ~110 string
    /// hashes and ~110 lock acquisitions per tick, inside the recorder's lock.
    public var enabledGeneration: UInt64 { self.locked { self.enabledRevision } }

    /// Checking the box is the whole mechanism: the next tick of the sensor's
    /// own reader sees it, registers the lane and starts folding samples, so
    /// there is nothing to tell the recorder. Unchecking stops the samples and
    /// leaves what was recorded alone — the lane keeps its slot and its data
    /// until the LRU reclaims it (§3), which is what makes turning a sensor off
    /// and on again cheap.
    public func setEnabled(_ on: Bool, stableKey: String) {
        let snapshot: [String] = self.locked {
            if on {
                self.enabled.insert(stableKey)
            } else {
                self.enabled.remove(stableKey)
            }
            self.enabledRevision &+= 1
            return self.enabled.sorted()
        }
        Store.shared.set(key: HistoryOptionalLanes.settingsKey,
                         value: snapshot.joined(separator: String(HistoryOptionalLanes.separator)))
    }

    /// Everything a module has reported, ordered by label and then by identity
    /// so that two rebuilds of the sidebar cannot shuffle the rows.
    public var offered: [HistoryLaneDescriptor] {
        self.locked {
            self.catalogue.values.sorted {
                ($0.label, $0.key.stableKey) < ($1.label, $1.key.stableKey)
            }
        }
    }

    /// Bumped when the catalogue grows, so the sidebar rebuilds when a sensor
    /// appears rather than on every refresh tick.
    public var revision: UInt64 { self.locked { self.catalogueRevision } }
}

// MARK: - how a module presents itself in the window

public extension HistoryLaneModule {
    /// The order the sidebar groups appear in. `HistoryLaneModule` is a stored
    /// byte and deliberately not `CaseIterable` — the raw values are a file
    /// format — so the display order is stated here rather than inherited from
    /// one.
    static let displayOrder: [HistoryLaneModule] = [.cpu, .ram, .gpu, .net, .disk, .battery, .sensors]

    /// The sidebar group title. Every module name is already a key in all 41
    /// `.lproj`, so grouping costs no new strings.
    var localizedTitle: String {
        switch self {
        case .cpu: return localizedString("CPU")
        case .ram: return localizedString("RAM")
        case .gpu: return localizedString("GPU")
        case .net: return localizedString("Network")
        case .disk: return localizedString("Disk")
        case .battery: return localizedString("Battery")
        case .sensors: return localizedString("Sensors")
        }
    }

    /// The unit the module's headline lanes are recorded in, and the rule the
    /// default selection is derived from.
    ///
    /// The directory entry carries a module, a unit and a label — not the
    /// metric name the lane was registered under — so "the originating module's
    /// primary lanes" (§5) has to be expressed in what is actually stored. The
    /// unit is the honest answer and it picks the right lanes: `cpu.total` /
    /// `system` / `user` over nothing else, RAM's usage and pressure over its
    /// swap byte count, GPU utilization over GPU temperature, both directions
    /// of a network interface over nothing else, disk read and write over the
    /// free-space gauge, battery level over battery power.
    var primaryUnit: HistoryLaneUnit {
        switch self {
        case .cpu, .ram, .gpu, .battery: return .percent
        case .net, .disk: return .bytesPerSec
        case .sensors: return .celsius
        }
    }

    /// The base colour for the module's lanes. §5 asks for "each module's
    /// `<Module>_color`", but there is no such key in this codebase: colours
    /// are stored per *widget* as `<Module>_<widget>_color`, and a lane belongs
    /// to a module and not to a widget. A per-module system colour is the
    /// nearest honest thing and it stays semantic, so a theme switch is a
    /// redraw.
    var accent: NSColor {
        switch self {
        case .cpu: return .systemBlue
        case .ram: return .systemIndigo
        case .gpu: return .systemPurple
        case .net: return .systemTeal
        case .disk: return .systemOrange
        case .battery: return .systemGreen
        case .sensors: return .systemRed
        }
    }

    /// The colour of the n-th drawn lane of this module. Successive lanes fade
    /// toward grey rather than jumping hue, so "CPU — total" and "CPU — user"
    /// still read as the same module.
    ///
    /// The blend is deferred into a dynamic colour rather than computed here.
    /// `blended(withFraction:of:)` resolves both operands against the drawing
    /// appearance in force when it is called, so a shade mixed once at query
    /// time would keep its pre-switch value until the next read — the accent
    /// itself stays semantic, and every lane after the first of a module would
    /// not. Resolving per draw is what makes the comment on `accent` true for
    /// all of them.
    func laneColor(offset: Int) -> NSColor {
        guard offset > 0 else { return self.accent }
        let fraction = Swift.min(0.6, 0.22 * CGFloat(offset))
        let accent = self.accent
        return NSColor(name: nil) { appearance in
            var blended: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                blended = accent.blended(withFraction: fraction, of: .systemGray)
            }
            return blended ?? accent
        }
    }
}

// MARK: - window

/// The history window: resizable, min 760×460, its frame remembered in
/// `Store`. It lives in Kit because that is the only place every module target
/// reaches (§5).
///
/// One instance for the app, kept alive across closes — the sidebar selection
/// and the range are what the user was last looking at, and re-deriving them
/// on every open would throw that away. `isReleasedWhenClosed` is therefore
/// off, as it is for the settings window.
///
/// `shared` builds an `NSWindow`, so the first touch of it must be on main.
/// Every caller is a menu item or a popup button, which is where it is opened
/// from in the commit that adds the entry points.
public final class HistoryWindow: NSWindow, NSWindowDelegate {
    public static let shared = HistoryWindow()

    /// §5: min 760×460. Below that the sidebar, the chart and the readout
    /// table stop being three usable columns.
    public static let minimumSize = NSSize(width: 760, height: 460)
    private static let defaultSize = NSSize(width: 1_020, height: 620)

    /// The frame goes through `Store` rather than through
    /// `setFrameAutosaveName`, so that "Reset settings" — which clears `Store`
    /// — also forgets it, and so that there is one place the app's persisted
    /// state lives.
    public static let frameKey: String = "history_window_frame"

    private let content = HistoryWindowContentView()

    private init() {
        super.init(contentRect: NSRect(origin: .zero, size: HistoryWindow.defaultSize),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                   backing: .buffered, defer: false)

        self.title = localizedString("Usage history")
        self.minSize = HistoryWindow.minimumSize
        self.isReleasedWhenClosed = false
        self.isRestorable = false
        self.contentView = self.content
        self.delegate = self
        self.restoreFrame()
    }

    /// Opens the window on a module's lanes. `module` is the popup or the menu
    /// item the user came from; the sidebar turns it into a default selection
    /// the first time, and leaves the user's own selection alone afterwards.
    public func show(module: ModuleType? = nil) {
        self.makeKeyAndOrderFront(nil)
        // Stats is `LSUIElement`, so without this the window comes up behind
        // whatever the user was in. Every other window path in this app does
        // the same (§5).
        NSApp.activate(ignoringOtherApps: true)
        // Ordered on screen first, so that `prepare`'s own `updateTimer` sees a
        // visible, unoccluded window and arms the refresh timer here rather
        // than leaving it to the occlusion notification AppKit posts as the
        // window comes up.
        self.content.prepare(for: module.flatMap { HistoryLaneModule($0) })
        self.makeFirstResponder(self.content)
    }

    // MARK: - frame persistence

    private func restoreFrame() {
        let stored = Store.shared.string(key: HistoryWindow.frameKey, defaultValue: "")
        let frame = NSRectFromString(stored)
        // A frame from a display that is no longer attached would put the
        // window somewhere the user cannot reach it, and a stored string that
        // never parsed reads back as a zero rect.
        guard frame.width >= HistoryWindow.minimumSize.width,
              frame.height >= HistoryWindow.minimumSize.height,
              NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else {
            self.center()
            return
        }
        self.setFrame(frame, display: false)
    }

    private func saveFrame() {
        Store.shared.set(key: HistoryWindow.frameKey, value: NSStringFromRect(self.frame))
    }

    /// The end of the drag, not every frame of it: `windowDidResize` and
    /// `windowDidMove` both fire per frame of a live drag and each one would be
    /// a `Store` write. There is no `windowDidEndLiveMove`, so a move is saved
    /// on close instead — the frame only has to be right the next time the
    /// window opens.
    public func windowDidEndLiveResize(_ notification: Notification) { self.saveFrame() }

    public func windowWillClose(_ notification: Notification) {
        self.saveFrame()
        // A closed window is not occluded, it is gone — and `occlusionState`
        // does not say so, which is the whole reason the timer is torn down
        // here as well as gated there.
        self.content.suspend()
    }
}

// MARK: - entry points

/// The expand button the module popups hang on their "Usage history"
/// separator (§5). It is built here rather than at each call site so that the
/// upstream popup edit stays the single added argument §9 budgets for it, and
/// so the icon, the tooltip and the action are stated once instead of six
/// times.
///
/// The button is offered whether or not recording is on: the window reads what
/// is already stored, and a user who turned the switch off last week still has
/// last week's history to look at.
public func historyExpandButton(for module: ModuleType) -> NSView {
    let button = PopupButton(
        toolTip: localizedString("Open the usage history window"),
        icon: "arrow.up.left.and.arrow.down.right"
    ) {
        HistoryWindow.shared.show(module: module)
    }
    // Image-only, so VoiceOver would otherwise read the SF Symbol name.
    button.setAccessibilityLabel(localizedString("Open the usage history window"))
    return button
}

// MARK: - content (top bar, sidebar, chart, readout table)

private final class HistoryWindowContentView: NSView {
    private static let sidebarWidth: CGFloat = 220
    private static let readoutWidth: CGFloat = 250
    private static let topBarHeight: CGFloat = 30
    private static let margin: CGFloat = 8

    /// §7 budgets the loaded window at "+< 300 KiB, range-independent",
    /// quoting eight lanes at 1,460 columns. Eight is therefore the cap the
    /// sidebar enforces rather than a number picked for the layout: a user who
    /// checks fifty lanes would be asking for 1.8 MB of columns and a chart
    /// with fifty lines on one shared y scale, which answers nothing.
    static let visibleLaneCap: Int = 8

    private let rangeControl: NSSegmentedControl
    private let bandToggle: NSButton
    private let liveControl: NSSegmentedControl
    private let sidebar = HistoryLaneSidebarView()
    private let chart = HistoryChartView(frame: .zero)
    private let readout = HistoryReadoutView()
    private let gapLabel = LabelField()

    private var range: HistoryRange = .day
    /// `nil` is "now" and follows the clock; a value is the pinned end of the
    /// window and freezes it there (§5's now/pinned toggle).
    private var pinnedEnd: TimeInterval?
    private var module: HistoryLaneModule?
    private var drawnLanes: [HistoryChartView.Lane] = []
    private var spans: [HistoryGapSpan] = []
    private var timer: Timer?
    /// Stamped on every read and compared when the columns come back, so a
    /// slow year-long read cannot land after the one-hour read that replaced
    /// it.
    private var generation: UInt64 = 0
    private var catalogueRevision: UInt64 = 0
    /// The effective budget the last read was planned for, so `layout` can tell
    /// a resize that changed the plan from one that did not.
    private var plannedBudget: Int = 0
    /// The lane-directory revision the sidebar was last built from.
    private var laneRevision: UInt64 = 0

    override init(frame frameRect: NSRect) {
        self.rangeControl = NSSegmentedControl(labels: HistoryRange.allCases.map { $0.localizedTitle },
                                               trackingMode: .selectOne, target: nil, action: nil)
        self.bandToggle = NSButton(checkboxWithTitle: localizedString("Min/max band"), target: nil, action: nil)
        self.liveControl = NSSegmentedControl(
            labels: [localizedString("Live"), localizedString("Pinned")],
            trackingMode: .selectOne, target: nil, action: nil
        )
        super.init(frame: frameRect)

        self.rangeControl.target = self
        self.rangeControl.action = #selector(self.rangeChanged)
        self.rangeControl.selectedSegment = HistoryRange.allCases.firstIndex(of: self.range) ?? 0

        self.bandToggle.target = self
        self.bandToggle.action = #selector(self.bandToggled)
        self.bandToggle.state = .on

        self.liveControl.target = self
        self.liveControl.action = #selector(self.liveChanged)
        self.liveControl.selectedSegment = 0

        self.gapLabel.alignment = .center
        self.gapLabel.font = .systemFont(ofSize: 11, weight: .regular)

        self.sidebar.onSelectionChange = { [weak self] in self?.reload() }
        // Tab moves focus into the filter field; ⇧Tab is the way back, so the
        // crosshair keys are reachable again once the user has typed (§5).
        self.sidebar.onLeaveFilter = { [weak self] in
            guard let self = self else { return }
            self.window?.makeFirstResponder(self)
        }
        self.chart.onHover = { [weak self] column in self?.hover(column) }

        self.build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - layout

    private func build() {
        // Range on the left, toggles on the right, said with priorities rather
        // than left to `.gravityAreas`: a bare spacer hugs at the same 250 the
        // segmented controls do, so which view absorbs the slack would
        // otherwise be a tie the layout engine breaks however it likes.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let topBar = NSStackView()
        topBar.orientation = .horizontal
        topBar.alignment = .centerY
        topBar.distribution = .fill
        topBar.spacing = HistoryWindowContentView.margin
        topBar.addArrangedSubview(self.rangeControl)
        topBar.addArrangedSubview(spacer)
        topBar.addArrangedSubview(self.bandToggle)
        topBar.addArrangedSubview(self.liveControl)

        let plot = NSView()
        plot.addSubview(self.chart)
        plot.addSubview(self.gapLabel)

        let body = NSStackView()
        body.orientation = .horizontal
        body.alignment = .top
        body.spacing = HistoryWindowContentView.margin
        body.addArrangedSubview(self.sidebar)
        body.addArrangedSubview(plot)
        body.addArrangedSubview(self.readout)

        for view in [topBar, body, plot, self.chart, self.gapLabel, self.sidebar, self.readout] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        self.addSubview(topBar)
        self.addSubview(body)

        let margin = HistoryWindowContentView.margin
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: self.topAnchor, constant: margin),
            topBar.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: margin),
            topBar.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -margin),
            topBar.heightAnchor.constraint(equalToConstant: HistoryWindowContentView.topBarHeight),

            body.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: margin),
            body.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: margin),
            body.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -margin),
            body.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -margin),

            self.sidebar.widthAnchor.constraint(equalToConstant: HistoryWindowContentView.sidebarWidth),
            self.sidebar.heightAnchor.constraint(equalTo: body.heightAnchor),
            self.readout.widthAnchor.constraint(equalToConstant: HistoryWindowContentView.readoutWidth),
            self.readout.heightAnchor.constraint(equalTo: body.heightAnchor),
            // The chart has no intrinsic height, so without this the stack's
            // `.top` alignment would size the middle column to the axis label
            // under it and leave the plot a few points tall.
            plot.heightAnchor.constraint(equalTo: body.heightAnchor),

            self.chart.topAnchor.constraint(equalTo: plot.topAnchor),
            self.chart.leadingAnchor.constraint(equalTo: plot.leadingAnchor),
            self.chart.trailingAnchor.constraint(equalTo: plot.trailingAnchor),
            self.gapLabel.topAnchor.constraint(equalTo: self.chart.bottomAnchor, constant: 2),
            self.gapLabel.leadingAnchor.constraint(equalTo: plot.leadingAnchor),
            self.gapLabel.trailingAnchor.constraint(equalTo: plot.trailingAnchor),
            self.gapLabel.bottomAnchor.constraint(equalTo: plot.bottomAnchor),
            self.gapLabel.heightAnchor.constraint(equalToConstant: 15)
        ])
    }

    /// A resize changes how many columns are worth asking for, but only once
    /// the drag is over: re-planning on every intermediate width would issue a
    /// tier read per frame for a column count nobody sees.
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        self.reload(refreshSidebar: false)
    }

    /// The resizes that are not drags. The zoom button, window tiling and a
    /// display change never open a live-resize session, so `viewDidEndLiveResize`
    /// alone would leave the chart stretched at the old column count — a Live
    /// window corrects itself at the next tick, a Pinned one not until the user
    /// touches a control. Compared against the budget the last read was planned
    /// for, so a layout pass that does not change the plan costs nothing.
    override func layout() {
        super.layout()
        guard !self.inLiveResize, self.effectiveBudget != self.plannedBudget else { return }
        self.reload(refreshSidebar: false)
    }

    /// The part of the pixel budget the plan can actually act on.
    ///
    /// `HistoryColumnPlan.plan` clamps to `columnCap` and only ever *widens*
    /// columns — it never splits a bucket to fill a wide window — so every
    /// budget at or above the range's nominal column count produces the
    /// identical plan. One hour is 360 columns and the window opens at 1,020 pt,
    /// so comparing the raw width would issue a full tier read on every zoom,
    /// tile and display change for a plan that cannot move.
    private var effectiveBudget: Int {
        min(self.chart.columnBudget, HistoryColumnPlan.columnCap,
            HistoryColumnPlan.nominalColumns(for: self.range))
    }

    // MARK: - lifecycle and the occlusion-gated refresh timer

    func prepare(for module: HistoryLaneModule?) {
        // Before the first read, because the column budget is the plot's width
        // in points and autolayout has not run yet on a window that has never
        // been shown.
        self.layoutSubtreeIfNeeded()

        // Both revisions before the contents they describe: a lane that
        // registers between the two reads then shows up at the next refresh
        // tick, rather than being hidden behind a revision newer than the rows
        // it was read with.
        self.laneRevision = HistoryRecorder.shared.laneRevision
        self.catalogueRevision = HistoryOptionalLanes.shared.revision
        let entries = HistoryRecorder.shared.lanes
        self.sidebar.setLanes(entries, offers: HistoryOptionalLanes.shared.offered)

        let wanted = module ?? self.module
        if self.sidebar.selection.isEmpty || (module != nil && module != self.module) {
            self.sidebar.select(HistoryWindowContentView.defaultSelection(for: wanted, in: entries))
        }
        self.module = wanted

        self.reload()
        self.updateTimer()
    }

    func suspend() {
        self.timer?.invalidate()
        self.timer = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification,
                                                  object: nil)
        guard let window = self.window else {
            self.suspend()
            return
        }
        NotificationCenter.default.addObserver(self, selector: #selector(self.occlusionChanged),
                                               name: NSWindow.didChangeOcclusionStateNotification,
                                               object: window)
        self.updateTimer()
    }

    @objc private func occlusionChanged() {
        self.updateTimer()
        // Coming back from behind Xcode with a chart that stopped refreshing
        // ten minutes ago: catch up once, rather than waiting a whole interval.
        if self.timer != nil { self.reload() }
    }

    /// §5: gated on `occlusionState`, not on `isVisible`, which is false only
    /// for a miniaturized or ordered-out window — a window sitting behind
    /// another one would otherwise poll forever. Pinned means the end of the
    /// range is frozen, so there is nothing to poll for either.
    private func updateTimer() {
        self.timer?.invalidate()
        self.timer = nil
        guard self.pinnedEnd == nil, let window = self.window, window.isVisible,
              window.occlusionState.contains(.visible) else { return }

        self.timer = Timer.scheduledTimer(withTimeInterval: self.range.refreshInterval, repeats: true) { [weak self] _ in
            self?.reload()
        }
    }

    // MARK: - reading (columns only, so the window's memory is range-independent)

    /// `refreshSidebar` is false on the paths a resize takes: a width change
    /// cannot add a lane or a sensor, and rebuilding the sidebar from inside
    /// `layout()` would add a view and a constraint per row in the middle of a
    /// layout pass.
    private func reload(refreshSidebar: Bool = true) {
        if refreshSidebar { self.refreshSidebarIfNeeded() }
        self.generation &+= 1
        let generation = self.generation
        let lanes = self.sidebar.selection.sorted()
        let budget = self.chart.columnBudget
        self.plannedBudget = self.effectiveBudget

        // The spans are snapshotted with the read rather than per hover: the
        // readout has to name the same sleep the columns were resolved against,
        // and a hover must not reach into the recorder.
        self.spans = HistoryRecorder.shared.gapSpans

        // No lane selected takes the same asynchronous road as every other
        // read, rather than asking the recorder for a plan inline: `plan(for:)`
        // reaches the open tiers through the history queue, which is also where
        // archive creation, the 60 s commit, the 10-minute `fsync` and a
        // 15–40 MB year read run — and §7 budgets main for none of them. The
        // empty query answers with the plan it resolved against the tiers the
        // store actually has open and an empty lane list, so the empty-state
        // axis is the same one and the generation guard below still discards a
        // late answer.
        HistoryRecorder.shared.query(lanes: lanes, range: self.range, maxColumns: budget,
                                     at: self.pinnedEnd) { [weak self] result in
            guard let self = self, generation == self.generation else { return }
            self.apply(result)
        }
    }

    /// A lane the recorder registered since the last read, or a sensor a module
    /// has only just discovered, belongs in the sidebar without reopening the
    /// window — checking an opt-in sensor is worth nothing if the lane it
    /// starts recording never shows up to be drawn.
    ///
    /// Revisions, not counts and not contents. The directory's own revision is
    /// bumped by everything that changes it as the file stores it, so a reclaim
    /// — which swaps one identity for another without moving the lane count,
    /// and at the 256-lane cap is the only thing that can still happen — is seen
    /// here instead of leaving the sidebar naming a series the chart no longer
    /// draws. It is also cheaper than comparing up to 256 directory entries on
    /// every refresh tick, which is what being exact would otherwise cost.
    private func refreshSidebarIfNeeded() {
        let lanes = HistoryRecorder.shared.laneRevision
        let catalogue = HistoryOptionalLanes.shared.revision
        guard lanes != self.laneRevision || catalogue != self.catalogueRevision else { return }
        self.laneRevision = lanes
        self.catalogueRevision = catalogue
        self.sidebar.setLanes(HistoryRecorder.shared.lanes, offers: HistoryOptionalLanes.shared.offered)
    }

    private func apply(_ result: HistoryQueryResult) {
        // The colour is the module's, shaded by the lane's position within its
        // own module, so two CPU lanes differ without pretending to be two
        // different modules.
        var seen: [HistoryLaneModule: Int] = [:]
        self.drawnLanes = result.lanes.map { columns -> HistoryChartView.Lane in
            let module = columns.entry.module
            let offset = seen[module, default: 0]
            seen[module] = offset + 1
            return HistoryChartView.Lane(columns: columns, color: module.laneColor(offset: offset))
        }

        self.chart.setLanes(self.drawnLanes, plan: result.plan)
        self.readout.setLanes(self.drawnLanes, plan: result.plan)
        // `setLanes` clears the crosshair, which is the honest thing on a live
        // refresh: the column under the pointer is not the same column any
        // more. Pinning is what stops that happening mid-read.
        self.hover(nil)
    }

    /// The originating module's primary lanes, and nothing else — required
    /// once 100+ lanes exist (§5). Orphans are skipped: a window opened on
    /// Network should not default to the Wi-Fi interface of a café last month.
    private static func defaultSelection(for module: HistoryLaneModule?,
                                         in entries: [HistoryLaneEntry]) -> Set<Int> {
        guard let module = module ?? entries.first?.module else { return [] }
        let lanes = entries.enumerated().filter {
            $0.element.module == module && !$0.element.flags.contains(.orphan)
        }
        let primary = lanes.filter { $0.element.unit == module.primaryUnit }
        let chosen = primary.isEmpty ? lanes : primary
        return Set(chosen.prefix(HistoryWindowContentView.visibleLaneCap).map { $0.offset })
    }

    // MARK: - hover readout (gap reasons in words)

    private func hover(_ column: Int?) {
        self.readout.setHovered(column)
        self.gapLabel.stringValue = self.sentence(for: column)
    }

    /// "Asleep 02:14–08:31", "Stats not running", "Clock changed", "Last known
    /// value" — the sentence §4 says is what turns a hole into an answer to
    /// "when did it start, how long did it last".
    private func sentence(for column: Int?) -> String {
        guard let column = column, let reason = self.reason(at: column), reason != .measured else { return "" }
        guard let start = self.chart.columnStart(column), start > 0 else { return reason.localizedTitle }

        guard let span = self.spans.first(where: { $0.reason == reason && $0.covers(UInt64(start)) }),
              !span.isOpen else { return reason.localizedTitle }
        let formatter = HistoryWindowContentView.clockFormatter
        return localizedString("%0 %1–%2", reason.localizedTitle,
                               formatter.string(from: Date(timeIntervalSince1970: TimeInterval(span.from))),
                               formatter.string(from: Date(timeIntervalSince1970: TimeInterval(span.to))))
    }

    /// What the drawn lanes agree the column is. A column every lane recorded
    /// is `.measured` and says nothing; one no lane recorded carries the reason
    /// the read derived for it.
    private func reason(at column: Int) -> HistoryGapReason? {
        var answer: HistoryGapReason?
        for lane in self.drawnLanes {
            guard column >= 0, column < lane.columns.columns.count else { continue }
            let reason = lane.columns.columns[column]?.reason ?? .nodata
            if (lane.columns.columns[column]?.count ?? 0) > 0 { return .measured }
            if answer == nil { answer = reason }
        }
        return answer
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: "jmm", options: 0, locale: .current)
        return formatter
    }()

    // MARK: - top bar actions

    @objc private func rangeChanged(_ sender: NSSegmentedControl) {
        let ranges = HistoryRange.allCases
        guard sender.selectedSegment >= 0, sender.selectedSegment < ranges.count else { return }
        self.select(range: ranges[sender.selectedSegment])
    }

    private func select(range: HistoryRange) {
        guard range != self.range else { return }
        self.range = range
        self.rangeControl.selectedSegment = HistoryRange.allCases.firstIndex(of: range) ?? 0
        // A new range means a new refresh cadence, and a crosshair that pointed
        // at a ten-second column has nothing to point at in a six-hour one.
        self.updateTimer()
        self.reload()
    }

    @objc private func bandToggled(_ sender: NSButton) {
        self.chart.showsMinMaxBand = sender.state == .on
    }

    @objc private func liveChanged(_ sender: NSSegmentedControl) {
        // Pinning freezes the end of the range at the moment it is pressed, so
        // the columns under the pointer stay the columns the user was reading.
        self.pinnedEnd = sender.selectedSegment == 0 ? nil : Date().timeIntervalSince1970
        self.updateTimer()
        self.reload()
    }

    // MARK: - keyboard (arrows, 1-6, Home/End, Esc, Tab)

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        switch Int(event.keyCode) {
        case 123: self.step(by: shift ? -10 : -1)
        case 124: self.step(by: shift ? 10 : 1)
        case 115: self.moveCrosshair(to: 0)
        case 119: self.moveCrosshair(to: self.chart.columnCount - 1)
        case 53:
            // Esc drops the crosshair first and closes the window only when
            // there is none — otherwise scrubbing out of a reading costs the
            // whole window.
            if self.chart.hoveredColumn != nil {
                self.chart.setHovered(nil)
            } else {
                self.window?.performClose(nil)
            }
        case 48:
            // Tab and not ⇧Tab. The filter field's own `insertBacktab:` is what
            // brings the keyboard back here, so Tab in and ⇧Tab out are the
            // same door — and a ⇧Tab pressed *here* has to walk the key loop
            // backwards rather than forwards into the field it is the exit of.
            guard !shift else {
                super.keyDown(with: event)
                return
            }
            self.window?.makeFirstResponder(self.sidebar.firstKeyView)
        default:
            if let characters = event.charactersIgnoringModifiers, let digit = Int(characters),
               digit >= 1, digit <= HistoryRange.allCases.count {
                self.select(range: HistoryRange.allCases[digit - 1])
                return
            }
            super.keyDown(with: event)
        }
    }

    private func step(by delta: Int) {
        let count = self.chart.columnCount
        guard count > 0 else { return }
        guard let current = self.chart.hoveredColumn else {
            // The first press lands on the end the user is walking in from,
            // rather than one column past it.
            self.moveCrosshair(to: delta < 0 ? count - 1 : 0)
            return
        }
        self.moveCrosshair(to: current + delta)
    }

    private func moveCrosshair(to column: Int) {
        let count = self.chart.columnCount
        guard count > 0 else { return }
        self.chart.setHovered(max(0, min(count - 1, column)))
    }
}

// MARK: - sidebar (lanes grouped by module, filter field, per-lane opt-in)

private final class HistoryLaneSidebarView: NSView, NSSearchFieldDelegate {
    var onSelectionChange: (() -> Void)?
    /// Called when the filter field gives up first responder on ⇧Tab, so the
    /// content view can take the keyboard back.
    var onLeaveFilter: (() -> Void)?

    private(set) var entries: [HistoryLaneEntry] = []
    private(set) var selection: Set<Int> = []
    private var offers: [HistoryLaneDescriptor] = []

    private let filter = NSSearchField()
    private let list = ScrollableStackView()

    var firstKeyView: NSView { self.filter }

    init() {
        super.init(frame: .zero)

        self.filter.placeholderString = localizedString("Filter lanes")
        self.filter.delegate = self
        self.filter.translatesAutoresizingMaskIntoConstraints = false
        self.filter.sendsSearchStringImmediately = true

        self.list.translatesAutoresizingMaskIntoConstraints = false
        self.list.stackView.orientation = .vertical
        self.list.stackView.alignment = .leading
        self.list.stackView.spacing = 2
        self.list.stackView.edgeInsets = NSEdgeInsets(top: 4, left: 2, bottom: 4, right: 2)

        self.addSubview(self.filter)
        self.addSubview(self.list)
        NSLayoutConstraint.activate([
            self.filter.topAnchor.constraint(equalTo: self.topAnchor),
            self.filter.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            self.filter.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            self.list.topAnchor.constraint(equalTo: self.filter.bottomAnchor, constant: 6),
            self.list.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            self.list.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            self.list.bottomAnchor.constraint(equalTo: self.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func accessibilityLabel() -> String? { localizedString("Usage history lanes") }

    // MARK: - contents

    func setLanes(_ entries: [HistoryLaneEntry], offers: [HistoryLaneDescriptor]) {
        self.entries = entries
        // Every offered sensor is listed, whether or not it is recording. An
        // opted-in one does get two boxes on one device name — the "Record
        // sensors" box here and a "draw this" box in its module group above —
        // and that is the price of the box staying reachable: the moment the
        // lane enters the directory, the group row's box is the only other one
        // on that name and it does not stop the recording. Hiding the row
        // instead would make the opt-in a one-way door, and the sensor
        // cardinality it exists to bound (§1, risk 3) is exactly where a
        // one-way door hurts — fifty sensors on and no way to turn one off
        // short of the master switch. The two section headers are what say
        // which question each box answers.
        self.offers = offers
        // A lane id that no longer exists cannot be drawn and must not be
        // asked for: the directory shrinks on a delete and on a preset change.
        self.selection = self.selection.filter { $0 < entries.count }
        self.rebuild()
    }

    func select(_ lanes: Set<Int>) {
        self.selection = lanes
        self.rebuild()
    }

    func controlTextDidChange(_ obj: Notification) {
        self.rebuild()
    }

    /// ⇧Tab out of the filter field goes back to the chart rather than to
    /// whatever the automatic key loop put before the sidebar: Tab in and
    /// ⇧Tab out are the same door.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertBacktab(_:)) else { return false }
        self.onLeaveFilter?()
        return true
    }

    /// TODO: diff the rows instead of rebuilding them. `controlTextDidChange`
    /// lands here on every keystroke of the filter field, and at the lane cap
    /// plus a sensors-heavy catalogue that is a few hundred `NSButton`s and a
    /// width constraint each, torn down and built again per character. Nothing
    /// expensive is computed here any more — what is left is the views
    /// themselves, and they want a reuse pool keyed by lane id.
    private func rebuild() {
        let stack = self.list.stackView
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let needle = self.filter.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        var rows = 0

        for module in HistoryLaneModule.displayOrder {
            // A module's own name keeps its whole group: CPU and RAM labels
            // happen to carry it ("CPU — total"), but Net, Disk and Sensors
            // labels are device names, so typing "network" would otherwise
            // empty the group it names.
            let named = HistoryLaneSidebarView.matches(module.localizedTitle, needle)
            let lanes = self.entries.enumerated()
                .filter { $0.element.module == module
                    && (named || HistoryLaneSidebarView.matches($0.element.label, needle)) }
            guard !lanes.isEmpty else { continue }
            self.add(self.header(module.localizedTitle))
            for lane in lanes {
                self.add(self.laneRow(lane: lane.offset, entry: lane.element))
                rows += 1
            }
        }

        let offered = self.offers.filter {
            HistoryLaneSidebarView.matches($0.label, needle)
                || HistoryLaneSidebarView.matches($0.key.module.localizedTitle, needle)
        }
        if !offered.isEmpty {
            self.add(self.header(localizedString("Record sensors")))
            for descriptor in offered {
                self.add(self.optInRow(descriptor))
                rows += 1
            }
        }

        if rows == 0 {
            self.add(self.header(localizedString("No recorded lanes")))
        }
    }

    /// The scroll view has no horizontal scroller, and a lane label is a device
    /// name of any length ("Tim's backup drive — write"), so every row is
    /// pinned to the column width and left to truncate. Without the constraint
    /// the row keeps its full intrinsic width and is clipped mid-word instead.
    private func add(_ row: NSView) {
        let stack = self.list.stackView
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -8).isActive = true
    }

    private static func matches(_ label: String, _ needle: String) -> Bool {
        needle.isEmpty || label.lowercased().contains(needle)
    }

    private func header(_ title: String) -> NSView {
        let field = LabelField(frame: .zero, title, size: 11)
        field.font = .systemFont(ofSize: 11, weight: .semibold)
        field.textColor = .secondaryLabelColor
        return field
    }

    /// One drawable lane.
    ///
    /// Greyed on `.orphan` only, and not on `.reclaimed` as §3's sentence
    /// reads. R1's own definition of the flag settles it: `.reclaimed` marks
    /// the id that was *handed to* a new identity, so the lane wearing it is
    /// the one actively recording — greying it would grey the newest lane on
    /// the machine. `.orphan` is the flag that means "the source has not been
    /// seen this launch", which is the lane the design wanted dated.
    private func laneRow(lane: Int, entry: HistoryLaneEntry) -> NSView {
        let stale = entry.flags.contains(.orphan)
        var title = entry.label
        if stale, entry.lastUsedTs > 0 {
            let seen = HistoryLaneSidebarView.dateFormatter
                .string(from: Date(timeIntervalSince1970: TimeInterval(entry.lastUsedTs)))
            title = "\(entry.label) · \(localizedString("Last seen %0", seen))"
        }

        let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(self.toggleLane))
        button.tag = lane
        button.state = self.selection.contains(lane) ? .on : .off
        button.toolTip = title
        button.lineBreakMode = .byTruncatingTail
        if stale {
            // Colour only: a greyed lane is still a lane, and shrinking the
            // type as well would make the sidebar look misaligned.
            button.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: NSColor.tertiaryLabelColor,
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            ])
        }
        return button
    }

    /// One sensor the machine can record and v1 does not record by default. The
    /// checkbox is the opt-in itself (§6), so it says "record this", not "draw
    /// this" — the lane appears in its module's group above, drawable, once it
    /// has samples, and this box stays here to turn the recording off again.
    private func optInRow(_ descriptor: HistoryLaneDescriptor) -> NSView {
        let button = NSButton(checkboxWithTitle: descriptor.label, target: self,
                              action: #selector(self.toggleOptIn))
        button.identifier = NSUserInterfaceItemIdentifier(descriptor.key.stableKey)
        button.state = HistoryOptionalLanes.shared.isEnabled(descriptor.key) ? .on : .off
        button.toolTip = descriptor.label
        button.lineBreakMode = .byTruncatingTail
        return button
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter
    }()

    // MARK: - actions

    @objc private func toggleLane(_ sender: NSButton) {
        if sender.state == .on {
            guard self.selection.count < HistoryWindowContentView.visibleLaneCap else {
                // Refusing beats silently drawing a ninth line: §7's window
                // memory figure is quoted at eight lanes, and nine lines on one
                // shared y scale is not a chart anybody reads.
                sender.state = .off
                NSSound.beep()
                return
            }
            self.selection.insert(sender.tag)
        } else {
            self.selection.remove(sender.tag)
        }
        self.onSelectionChange?()
    }

    @objc private func toggleOptIn(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        HistoryOptionalLanes.shared.setEnabled(sender.state == .on, stableKey: key)
    }
}

// MARK: - readout table (min/avg/max, or the column under the crosshair)

private final class HistoryReadoutView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private enum Column: String {
        case lane
        case min
        case avg
        case max
    }

    private let title = LabelField()
    private let table = NSTableView()
    private let scroll = NSScrollView()

    private var lanes: [HistoryChartView.Lane] = []
    /// One per lane, computed once with the read. `HistoryLaneColumns.summary`
    /// is an O(columns) pass, and the un-hovered table asks for it three times
    /// a row on every `reloadData` — which is every crosshair column change, up
    /// to 1,460 columns a pass.
    private var summaries: [HistoryLaneSummary?] = []
    private var plan: HistoryColumnPlan?
    private var hovered: Int?

    init() {
        super.init(frame: .zero)

        self.title.font = .systemFont(ofSize: 11, weight: .semibold)
        self.title.stringValue = localizedString("Whole range")
        self.title.translatesAutoresizingMaskIntoConstraints = false

        self.table.dataSource = self
        self.table.delegate = self
        self.table.rowSizeStyle = .small
        self.table.usesAlternatingRowBackgroundColors = true
        // A readout, not a picker: a selected row would imply an action there
        // is none of.
        self.table.selectionHighlightStyle = .none
        self.table.allowsColumnSelection = false
        self.table.style = .plain

        self.table.addTableColumn(HistoryReadoutView.column(.lane, title: localizedString("Lane"), width: 110))
        self.table.addTableColumn(HistoryReadoutView.column(.min, title: localizedString("Min"), width: 42))
        self.table.addTableColumn(HistoryReadoutView.column(.avg, title: localizedString("Avg"), width: 42))
        self.table.addTableColumn(HistoryReadoutView.column(.max, title: localizedString("Max"), width: 42))

        self.scroll.documentView = self.table
        self.scroll.hasVerticalScroller = true
        self.scroll.drawsBackground = false
        self.scroll.translatesAutoresizingMaskIntoConstraints = false

        self.addSubview(self.title)
        self.addSubview(self.scroll)
        NSLayoutConstraint.activate([
            self.title.topAnchor.constraint(equalTo: self.topAnchor),
            self.title.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            self.title.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            self.scroll.topAnchor.constraint(equalTo: self.title.bottomAnchor, constant: 6),
            self.scroll.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            self.scroll.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            self.scroll.bottomAnchor.constraint(equalTo: self.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func column(_ id: Column, title: String, width: CGFloat) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id.rawValue))
        column.title = title
        column.width = width
        column.minWidth = 34
        return column
    }

    // MARK: - contents

    func setLanes(_ lanes: [HistoryChartView.Lane], plan: HistoryColumnPlan) {
        self.lanes = lanes
        self.summaries = lanes.map { $0.columns.summary }
        self.plan = plan
        self.hovered = nil
        self.title.stringValue = localizedString("Whole range")
        self.table.reloadData()
    }

    /// §5: the table switches from the range's min/avg/max to the column under
    /// the crosshair. A column is itself a min/avg/max over the buckets it
    /// covers, so the three headings stay true and only what they summarize
    /// changes.
    func setHovered(_ column: Int?) {
        guard column != self.hovered else { return }
        self.hovered = column
        // `HistoryColumnPlan.columnStart` multiplies into a `UInt32` and traps
        // on a column outside the plan. The chart clamps against the same plan
        // before it calls here, but the chart's own accessor guards this and so
        // does this one.
        if let column = column, let plan = self.plan, column >= 0, column < plan.columns {
            self.title.stringValue = HistoryReadoutView.stamp(plan.columnStart(column), range: plan.range)
        } else {
            self.title.stringValue = localizedString("Whole range")
        }
        self.table.reloadData()
    }

    /// Cached formatters rather than one built per hover: scrubbing a
    /// 1,460-column year crosses a column every few pixels, and building a
    /// `DateFormatter` is tens of microseconds of main thread each time.
    ///
    /// Not `usesDateAxis`: that rule is about five x-axis labels sharing a
    /// 30-day chart, and it is the right rule there. The crosshair header names
    /// one column, and a 7 d column is 20 minutes wide — dropping the time
    /// would repaint the same "9/14" for 72 consecutive columns while the table
    /// under it changed. Only the year, at 6 h a column, wants a bare date.
    private static func stamp(_ ts: TimeInterval, range: HistoryRange) -> String {
        let formatter: DateFormatter
        switch range {
        case .hour, .sixHours, .day: formatter = HistoryReadoutView.timeStamp
        case .week, .month: formatter = HistoryReadoutView.dayTimeStamp
        case .year: formatter = HistoryReadoutView.dayStamp
        }
        return formatter.string(from: Date(timeIntervalSince1970: ts))
    }

    private static let timeStamp: DateFormatter = HistoryReadoutView.formatter(date: .none, time: .short)
    private static let dayStamp: DateFormatter = HistoryReadoutView.formatter(date: .short, time: .none)
    private static let dayTimeStamp: DateFormatter = HistoryReadoutView.formatter(date: .short, time: .short)

    private static func formatter(date: DateFormatter.Style, time: DateFormatter.Style) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = date
        formatter.timeStyle = time
        return formatter
    }

    // MARK: - table

    func numberOfRows(in tableView: NSTableView) -> Int { self.lanes.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < self.lanes.count, let column = tableColumn,
              let id = Column(rawValue: column.identifier.rawValue) else { return nil }
        let lane = self.lanes[row]

        // Reused rather than rebuilt: `reloadData` runs on every crosshair
        // column change, and a fresh cell view with three fresh constraints per
        // cell is autolayout work per scrubbed pixel.
        let cell = tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTableCellView
            ?? HistoryReadoutView.cell(identifier: column.identifier, alignment: id == .lane ? .left : .right)
        guard let field = cell.textField else { return cell }

        if id == .lane {
            field.stringValue = lane.label
            field.textColor = lane.color
            field.toolTip = lane.label
        } else {
            field.textColor = .labelColor
            field.toolTip = nil
            field.stringValue = self.value(of: id, for: row).map { lane.unit.format($0) } ?? "—"
        }
        return cell
    }

    /// One cell view, built to be handed back by `makeView(withIdentifier:)`.
    /// The identifier is the column's, so the lane column's left-aligned cells
    /// and the value columns' right-aligned ones never come out of the same
    /// reuse queue.
    private static func cell(identifier: NSUserInterfaceItemIdentifier,
                             alignment: NSTextAlignment) -> NSTableCellView {
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 11, weight: .regular)
        field.lineBreakMode = .byTruncatingTail
        field.alignment = alignment
        field.translatesAutoresizingMaskIntoConstraints = false

        let cell = NSTableCellView()
        cell.identifier = identifier
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private func value(of id: Column, for row: Int) -> Float? {
        let lane = self.lanes[row]
        if let hovered = self.hovered {
            guard hovered >= 0, hovered < lane.columns.columns.count,
                  let column = lane.columns.columns[hovered] else { return nil }
            switch id {
            case .min: return column.min
            case .avg: return column.avg
            case .max: return column.max
            case .lane: return nil
            }
        }
        guard row < self.summaries.count, let summary = self.summaries[row] else { return nil }
        switch id {
        case .min: return summary.min
        case .avg: return summary.avg
        case .max: return summary.max
        case .lane: return nil
        }
    }
}
