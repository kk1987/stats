//
//  History.swift
//  Net
//
//  Persistent usage history: lane extraction for the Net module.
//  The conformance lives here because Kit cannot import the module targets.
//  Design: docs/usage-history-design.md (§2 Sampling), exelban/stats#1194.
//

import Cocoa
import Kit

// MARK: - lanes
//
// UsageReader: `<iface>.up` and `<iface>.down` as rate lanes, keyed by BSD
// name. What is emitted is the per-tick byte delta, not a rate: the recorder
// divides by the time actually elapsed since that lane's previous sample,
// bounded by the reader's interval (§2). The same delta feeds the daily byte
// counter #3450 asks for — `sink.emitTraffic` below — which is the recorder's
// own accumulator and not a lane: it is summed rather than averaged, rolls at
// local midnight and keeps no per-interface breakdown.
//
// Three distinct conditions all reach `callback` as `bandwidth == 0`, and §2
// splits them three ways:
//
// 1. Unreachable (Modules/Net/readers.swift:219-226) — `usage.reset()` (:225) nils
//    `interface`, so it is detectable from the payload and recorded as
//    no-data: nothing is emitted, the bucket keeps `count == 0` and the read
//    side derives the gap.
// 2. Interface change (:264-266) — `usage.bandwidth` is reset and the first
//    post-switch read yields 0. Detectable by diffing the BSD name across
//    samples, and recorded as no-data the same way. The first sample of a
//    launch takes the same path, for the same reason: `setup()` zeroes
//    `usage.bandwidth` (:243) and the first `read()` therefore has no
//    previous counter to subtract from.
// 3. The over-link-rate guard (:299-300) zeroes the delta before `callback`
//    and does not carry the raw value anywhere, so at this hook it is
//    byte-identical to a genuinely idle link. §2 accepts it as an unmarked
//    zero rather than editing `Modules/Net/readers.swift`: it fires on
//    one-shot counter jumps, at a 1 s interval it is one sample in a ten
//    sample bucket, and it moves that bucket's `min` and nothing else.
//
// The VPN halving (:307-310) happens upstream of `callback` and is stored as
// it arrives.

// MARK: - lane cache
//
// `HistorySink.lane(for:)` hashes a string, and that is not free: measured at
// 76 µs for 116 lanes, which is §7's entire container budget spent on lane
// resolution alone. The integer id is therefore resolved once and kept, which
// is what §2's "lanes resolve to integer ids at registration" asks for.
//
// The id is re-resolved every `historyLaneCacheTTL` seconds rather than never.
// `HistoryLaneDirectory` refreshes a lane's `lastUsedTs` from the registration
// call, so a lane that never registers again looks idle to the LRU reclaim
// even while it is recording; and an interface that goes away for longer than
// the TTL — which on this module is the common case, not the rare one —
// re-resolves on its first tick back, so a cached id that was reclaimed in the
// meantime cannot be written to under the old identity.
//
// Every access to these globals happens inside `HistoryRecorder.ingest` with
// the recorder's lock held — the same lock that serializes the directory — so
// they are not racing even though Battery ingests on the main run loop.

private let historyLaneCacheTTL: UInt64 = 600

/// A resolved lane id and the wall clock it was resolved at. `id` is negative
/// for a lane the registry refused (the cap is reached and every lane in the
/// directory is still warm); the refusal is cached like a success so that a
/// full directory does not re-hash every key on every tick.
private struct HistoryLaneSlot {
    var id: Int32 = -1
    var resolvedAt: UInt64 = 0
}

/// Keyed by BSD name directly, so the cached path neither interpolates a
/// string nor allocates: one dictionary of lanes per metric rather than one
/// dictionary keyed by a composed "<iface>.<metric>".
private var uploadLanes: [String: HistoryLaneSlot] = [:]
private var downloadLanes: [String: HistoryLaneSlot] = [:]

/// The BSD name the previous sample carried, which is the whole of how an
/// interface change is detected. `nil` after an unreachable payload, so the
/// first sample on a link that has come back is dropped as well — the reader
/// zeroes `usage.bandwidth` on the way out of `reset()`, so it would be a
/// substituted zero rather than an idle link.
private var lastBSDName: String?

@inline(__always)
private func historyLane(_ cache: inout [String: HistoryLaneSlot], _ key: String, at ts: UInt64,
                         into sink: inout HistorySink,
                         _ descriptor: () -> HistoryLaneDescriptor) -> Int32? {
    if let slot = cache[key], ts < slot.resolvedAt &+ historyLaneCacheTTL {
        return slot.id >= 0 ? slot.id : nil
    }
    let id = sink.lane(for: descriptor()) ?? -1
    cache[key] = HistoryLaneSlot(id: id, resolvedAt: ts)
    return id >= 0 ? id : nil
}

/// "Wi-Fi (en0)" — the name a person recognizes plus the identity the lane is
/// actually keyed on. `displayName` is empty for interfaces
/// SystemConfiguration has no description for, and the BSD name alone is then
/// the whole label.
private func networkLaneLabel(_ displayName: String, _ bsdName: String) -> String {
    displayName.isEmpty ? bsdName : "\(displayName) (\(bsdName))"
}

// MARK: - emitHistory

extension Network_Usage: HistoryProvider {
    public func emitHistory(reader: HistoryReaderKey, into sink: inout HistorySink) {
        guard let interface = self.interface, !interface.BSDName.isEmpty else {
            lastBSDName = nil
            return
        }

        let bsdName = interface.BSDName
        guard lastBSDName == bsdName else {
            lastBSDName = bsdName
            return
        }

        let ts = sink.timestamp
        // #3450's day counter, fed before the lanes and independently of them:
        // it takes this tick's bytes whether or not a lane could be resolved
        // for them, which at the 256-lane cap is the difference between a
        // daily total and nothing. The two guards above are what keep the
        // reader's substituted zeros out of it — an unreachable link and the
        // first sample after an interface change are not measurements of zero
        // traffic — and the link-rate guard's zero costs it that tick's bytes,
        // which §2 accepts here for the same reason it accepts it in the lane.
        sink.emitTraffic(upload: self.bandwidth.upload, download: self.bandwidth.download)

        // The label is built inside the descriptor, which runs only when a
        // lane is actually being resolved. Interpolating it on every tick
        // would put a string allocation on the hot path for a field that is
        // read once and then lives in the directory.
        let display = interface.displayName

        if let lane = historyLane(&uploadLanes, bsdName, at: ts, into: &sink, {
            HistoryLaneDescriptor(key: HistoryLaneKey(module: .net, source: bsdName, metric: "up"),
                                  unit: .bytesPerSec, kind: .rate,
                                  label: "\(networkLaneLabel(display, bsdName)) — up")
        }) {
            sink.emit(lane: lane, value: Double(self.bandwidth.upload))
        }

        if let lane = historyLane(&downloadLanes, bsdName, at: ts, into: &sink, {
            HistoryLaneDescriptor(key: HistoryLaneKey(module: .net, source: bsdName, metric: "down"),
                                  unit: .bytesPerSec, kind: .rate,
                                  label: "\(networkLaneLabel(display, bsdName)) — down")
        }) {
            sink.emit(lane: lane, value: Double(self.bandwidth.download))
        }
    }
}

// MARK: - daily totals in the popup (#3450)

/// The two rows the Net popup shows under its totals: how many bytes went up
/// and down today, and the same for yesterday.
///
/// It lives here rather than in `popup.swift` because it refreshes itself. The
/// popup's own render path would have been the natural place to push a value
/// from, but every line added to that file is a line to re-resolve on the next
/// upstream rebase, and a view that builds its own rows and reads the counter
/// itself costs that file exactly one `addArrangedSubview`.
///
/// Refreshing is gated on the popup actually being open. `.popupVisibilityChanged`
/// fires for *every* module's popup, not just this one, so the notification only
/// starts the timer and the timer stops itself on the first tick that finds no
/// visible window — which is what a CPU popup opening leaves behind here.
internal final class NetworkDailyTrafficView: NSStackView {
    /// Two seconds rather than the popup's own one: these are daily totals, and
    /// the read is two integers under a lock — but it is still a read on main
    /// for a row nobody watches change.
    private static let refreshInterval: TimeInterval = 2
    private static let rowHeight: CGFloat = 22

    private var todayField: ValueField?
    private var yesterdayField: ValueField?
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width,
                                 height: NetworkDailyTrafficView.rowHeight * 2))
        self.orientation = .vertical
        self.spacing = 0
        self.heightAnchor.constraint(equalToConstant: self.frame.height).isActive = true

        let today = popupRow(self, title: "\(localizedString("Today")):", value: "-")
        let yesterday = popupRow(self, title: "\(localizedString("Yesterday")):", value: "-")
        self.todayField = today.1
        self.yesterdayField = yesterday.1

        // The caption the design asks for, on both halves of both rows: these
        // are the bytes Stats itself counted, so they read below the interface
        // totals two rows above and below whatever the ISP says.
        let note = localizedString("Daily traffic note")
        for field in [today.0, yesterday.0] as [NSView] { field.toolTip = note }
        for field in [today.1, yesterday.1] as [NSView] { field.toolTip = note }

        self.observer = NotificationCenter.default.addObserver(
            forName: .popupVisibilityChanged, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            guard (notification.userInfo?["state"] as? Bool) ?? false else {
                self.stopRefreshing()
                return
            }
            self.refresh()
            self.startRefreshing()
        }
        self.refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.stopRefreshing()
        if let observer = self.observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func startRefreshing() {
        guard self.timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: NetworkDailyTrafficView.refreshInterval,
                                         repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard self.window?.isVisible ?? false else {
                self.stopRefreshing()
                return
            }
            self.refresh()
        }
        timer.tolerance = NetworkDailyTrafficView.refreshInterval / 2
        self.timer = timer
    }

    private func stopRefreshing() {
        self.timer?.invalidate()
        self.timer = nil
    }

    /// Reads the recorder's in-memory counter — no file, no queue hop — and
    /// writes the two fields only when the text has actually moved.
    private func refresh() {
        let recorder = HistoryRecorder.shared
        let totals = recorder.dailyTraffic
        let recording = recorder.isRecording
        let today = NetworkDailyTrafficView.value(totals.today, recording: recording)
        let yesterday = NetworkDailyTrafficView.value(totals.yesterday, recording: recording)

        if self.todayField?.stringValue != today { self.todayField?.stringValue = today }
        if self.yesterdayField?.stringValue != yesterday { self.yesterdayField?.stringValue = yesterday }
    }

    /// "↑ 1,2 GB   ↓ 8,4 GB". The arrows carry the direction because the row
    /// has one value field for both of them, and a zero day with recording
    /// switched off is *unknown*, not zero: nothing was counting.
    private static func value(_ traffic: HistoryTraffic, recording: Bool) -> String {
        guard recording || !traffic.isEmpty else { return localizedString("Unavailable") }
        let upload = Units(bytes: traffic.upload).getReadableMemory()
        let download = Units(bytes: traffic.download).getReadableMemory()
        return "↑ \(upload)   ↓ \(download)"
    }
}
