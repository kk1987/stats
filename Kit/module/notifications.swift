//
//  notifications.swift
//  Kit
//
//  Created by Serhiy Mytrovtsiy on 04/12/2023
//  Using Swift 5.0
//  Running on macOS 14.1
//
//  Copyright © 2023 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import UserNotifications

open class NotificationsWrapper: NSStackView {
    public let module: String
    
    private var ids: [String: Bool?] = [:]
    private var streak: [String: Int] = [:]

    /// Per notification state used when a minimum duration is configured.
    private struct SustainedState {
        var startedAt: TimeInterval? = nil
        var threshold: Double = 0
        var less: Bool = false
        var lastSampleAt: TimeInterval? = nil
        var lastGap: TimeInterval? = nil
    }
    /// A gap bigger than `max(minSampleGap, lastGap*sampleGapTolerance)` means the value was not observed
    /// continuously, so the pending window restarts instead of claiming an unobserved period.
    private static let minSampleGap: TimeInterval = 5
    private static let sampleGapTolerance: Double = 2.5
    /// Some modules check several values under the same id inside one reader update. Those back to back
    /// calls are not a sampling cadence, so they must not shrink the tolerance above.
    private static let minMeasurableGap: TimeInterval = 0.5

    private var sustained: [String: SustainedState] = [:]
    private var duration: Int = 0
    private var durationSection: PreferencesSection? = nil

    public init(_ module: ModuleType, _ ids: [String] = [], withDuration: Bool = true) {
        self.module = module.stringValue
        super.init(frame: NSRect.zero)
        self.initIDs(ids)

        self.orientation = .vertical
        self.distribution = .gravityAreas
        self.translatesAutoresizingMaskIntoConstraints = false
        self.spacing = Constants.Settings.margin

        if withDuration {
            self.duration = Store.shared.int(key: "\(self.module)_notifications_duration", defaultValue: self.duration)
            let section = PreferencesSection([
                PreferencesRow(
                    localizedString("Minimum duration"),
                    localizedString("How long the value must stay past the threshold"),
                    component: selectView(
                        action: #selector(self.changeDuration),
                        items: notificationDurations,
                        selected: "\(self.duration)"
                    )
                )
            ])
            self.durationSection = section
            self.addArrangedSubview(section)
        }
    }

    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public func willTerminate() {
        for id in self.ids {
            removeNotification(id.key)
        }
    }
    
    public func initIDs(_ ids: [String]) {
        for id in ids {
            let notificationID = "Stats_\(self.module)_\(id)"
            self.ids[notificationID] = nil
            self.streak[notificationID] = 0
            self.sustained[notificationID] = nil
            removeNotification(notificationID)
        }
    }

    /// Drops every section built by the module, keeping the shared duration row in place.
    public func resetSections() {
        self.subviews.forEach({ $0.removeFromSuperview() })
        if let section = self.durationSection {
            self.addArrangedSubview(section)
        }
    }

    public func checkDouble(id rid: String, value: Double, threshold: Double, title: String, subtitle: String, less: Bool = false, consecutive: Int = 2) {
        let id = "Stats_\(self.module)_\(rid)"
        let first = less ? value > threshold : value < threshold
        let second = less ? value <= threshold : value >= threshold

        if self.ids[id] != nil, first {
            removeNotification(id)
            self.ids[id] = nil
        }

        if first {
            self.streak[id] = 0
        }

        let duration = TimeInterval(self.duration)
        if duration > 0 {
            if self.isSustained(id, duration: duration, threshold: threshold, less: less, violated: second), self.ids[id] == nil {
                self.showNotification(id: id, title: title, subtitle: subtitle)
                self.ids[id] = true
            }
            return
        }

        if self.ids[id] == nil && second {
            let count = (self.streak[id] ?? 0) + 1
            self.streak[id] = count
            if count >= max(1, consecutive) {
                self.showNotification(id: id, title: title, subtitle: subtitle)
                self.ids[id] = true
                self.streak[id] = 0
            }
        }
    }
    
    public func newNotification(id rid: String, title: String, subtitle: String? = nil) {
        let id = "Stats_\(self.module)_\(rid)"
        
        if self.ids[id] != nil {
            removeNotification(id)
            self.ids[id] = nil
        }
        
        self.showNotification(id: id, title: title, subtitle: subtitle)
        self.ids[id] = true
    }
    
    public func hideNotification(_ rid: String) {
        let id = "Stats_\(self.module)_\(rid)"
        if self.ids[id] != nil {
            removeNotification(id)
            self.ids[id] = nil
        }
    }
    
    /// Tracks how long the value has been past the threshold without interruption. Returns true only on the
    /// first observation that is at least `duration` seconds away from the start of the current window.
    private func isSustained(_ id: String, duration: TimeInterval, threshold: Double, less: Bool, violated: Bool) -> Bool {
        // monotonic and frozen while the machine sleeps, so only awake time counts towards the window
        let now = ProcessInfo.processInfo.systemUptime
        var state = self.sustained[id] ?? SustainedState()
        defer { self.sustained[id] = state }

        var interrupted: Bool = false
        if let last = state.lastSampleAt {
            let gap = now - last
            if gap < 0 {
                interrupted = true
            } else {
                if let previous = state.lastGap, gap > max(NotificationsWrapper.minSampleGap, previous * NotificationsWrapper.sampleGapTolerance) {
                    interrupted = true
                }
                if gap >= NotificationsWrapper.minMeasurableGap {
                    state.lastGap = gap
                }
            }
        }
        state.lastSampleAt = now

        guard violated else {
            state.startedAt = nil
            return false
        }

        // a window starts over when the value just crossed the threshold, when the observations were
        // interrupted, or when the settings it was opened with are no longer the current ones
        guard let startedAt = state.startedAt, !interrupted, state.threshold == threshold, state.less == less else {
            state.startedAt = now
            state.threshold = threshold
            state.less = less
            return false
        }

        guard now - startedAt >= duration else { return false }
        state.startedAt = nil
        return true
    }

    @objc private func changeDuration(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let value = Int(key) else { return }
        self.duration = value
        Store.shared.set(key: "\(self.module)_notifications_duration", value: value)
        self.sustained = [:]
        self.streak = [:]
    }

    private func showNotification(id: String, title: String, subtitle: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        if let value = subtitle {
            content.subtitle = value
        }
        content.sound = UNNotificationSound.default
        
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        center.add(request) { (error: Error?) in
            if let err = error {
                print(err)
            }
        }
    }
}
