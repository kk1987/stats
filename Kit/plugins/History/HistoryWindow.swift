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

    /// Whether the x axis reads in dates rather than in times. §5: times up to
    /// a day, dates on 7 d / 30 d / 1 y — five labels all reading "14:32:05"
    /// on a thirty-day view answer nothing.
    public var usesDateAxis: Bool { self.seconds > 24 * 3_600 }
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
    /// the window picked for it (each module's `<Module>_color`, §5).
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
        guard let plan = self.plan, let scale = self.scale else { return }

        // Gaps first and underneath: a hatch the series are drawn over reads as
        // background, which is what it is.
        let columnWidth = plot.width / CGFloat(max(1, plan.columns))
        self.drawHatch(over: self.gapRuns, columnWidth: columnWidth, in: plot)

        self.drawYAxis(scale, in: plot)
        self.drawXAxis(plan, in: plot)

        for lane in self.geometry {
            lane.color.withAlphaComponent(HistoryChartView.bandAlpha).setFill()
            lane.band.fill()

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
