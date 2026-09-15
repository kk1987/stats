//
//  HistoryWindow.swift
//  Kit
//
//  Persistent usage history: the history window, its sidebar and readout.
//  The chart it hosts lives in HistoryChart.swift.
//  Design: docs/usage-history-design.md (§5 UI), exelban/stats#1194.
//

import Cocoa
import os

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
    private static let readoutWidth: CGFloat = 300
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
    private let exportButton: NSButton
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
    /// The plan the drawn columns were cut to. Kept so that the export writes
    /// the range on screen rather than one re-planned against the clock while
    /// the save panel was open.
    private var plan: HistoryColumnPlan?
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
        self.exportButton = NSButton(title: localizedString("Export CSV"), target: nil, action: nil)
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

        self.exportButton.target = self
        self.exportButton.action = #selector(self.exportCSV)
        self.exportButton.bezelStyle = .rounded
        // Nothing checked is an empty file with a one-word header line, which
        // is a worse answer than a button that says it has nothing to write.
        self.exportButton.isEnabled = false

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
        topBar.addArrangedSubview(self.exportButton)

        let plot = NSView()
        plot.addSubview(self.chart)
        plot.addSubview(self.gapLabel)
        // The plot has no intrinsic width: it is whatever the window leaves
        // between the two fixed columns. `.fill` makes the stack hand it that
        // slack (the default `.gravityAreas` sizes it to zero and leaves the
        // remainder empty), and the priorities say the plot is the view that
        // stretches and shrinks, never the sidebar or the readout.
        plot.setContentHuggingPriority(.init(1), for: .horizontal)
        plot.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let body = NSStackView()
        body.orientation = .horizontal
        body.alignment = .top
        body.distribution = .fill
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

        self.plan = result.plan
        self.exportButton.isEnabled = !self.drawnLanes.isEmpty
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

    /// §5's Export CSV. The lanes are the checked ones in the order they are
    /// drawn and the plan is the one on screen, so the file is what the window
    /// is showing and not a second, differently-aligned read of the same range.
    @objc private func exportCSV(_ sender: NSButton) {
        guard let plan = self.plan, !self.drawnLanes.isEmpty else { return }
        HistoryCSVExporter().save(lanes: self.drawnLanes.map { $0.columns.lane }, plan: plan,
                                  in: self.window)
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

    /// Rebuilds the rows rather than diffing them. `controlTextDidChange`
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

        // Three value columns wide enough for "1.23 GB/s"; the lane column
        // absorbs whatever the readout has left.
        self.table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        self.table.addTableColumn(HistoryReadoutView.column(.lane, title: localizedString("Lane"), width: 120))
        self.table.addTableColumn(HistoryReadoutView.column(.min, title: localizedString("Min"), width: 56))
        self.table.addTableColumn(HistoryReadoutView.column(.avg, title: localizedString("Avg"), width: 56))
        self.table.addTableColumn(HistoryReadoutView.column(.max, title: localizedString("Max"), width: 56))

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
