//
//  main.swift
//  Sensors
//
//  Created by Serhiy Mytrovtsiy on 17/06/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

public class Sensors: Module {
    private var sensorsReader: SensorsReader?
    private let popupView: Popup
    private let settingsView: Settings
    private let portalView: Portal
    private let notificationsView: Notifications

    private var fanValueState: FanValue {
        FanValue(rawValue: Store.shared.string(key: "\(self.config.name)_fanValue", defaultValue: "percentage")) ?? .percentage
    }

    private var selectedSensor: String

    // Manual fan mode enforcement: macOS can silently reclaim fan control
    // (on Apple Silicon it re-zeroes Ftst/F%dMd), which used to leave the UI
    // claiming manual mode while the SMC was back to automatic. Re-assert the
    // stored intent when the mismatch persists; give up after a few failed
    // attempts and sync the UI back to reality instead of desyncing silently.
    // The delay must exceed the worst-case Ftst unlock time (~40s), so a
    // user-initiated switch that is still unlocking is never doubled up.
    private static let fanEnforcementDelay: TimeInterval = 45
    private static let fanEnforcementMaxAttempts: Int = 3
    private let fanEnforcementQueue = DispatchQueue(label: "eu.exelban.Stats.Sensors.fanEnforcement")
    private var fanEnforcementFirstMismatch: [Int: Date] = [:]
    private var fanEnforcementAttempts: [Int: Int] = [:]
    private var fanEnforcementSuspendedUntil: Date? = nil
    
    public init() {
        self.settingsView = Settings(.sensors)
        self.popupView = Popup()
        self.portalView = Portal(.sensors)
        self.notificationsView = Notifications(.sensors)
        self.selectedSensor = Store.shared.string(key: "\(ModuleType.sensors.stringValue)_sensor", defaultValue: "Average System Total")
        
        super.init(
            moduleType: .sensors,
            popup: self.popupView,
            settings: self.settingsView,
            portal: self.portalView,
            notifications: self.notificationsView
        )
        guard self.available else { return }
        
        self.sensorsReader = SensorsReader { [weak self] value in
            self?.usageCallback(value)
        }
        
        self.settingsView.setList(self.sensorsReader?.list.sensors)
        self.popupView.setup(self.sensorsReader?.list.sensors)
        self.portalView.setup(self.sensorsReader?.list.sensors)
        self.notificationsView.setup(self.sensorsReader?.list.sensors)
        
        self.settingsView.callback = { [weak self] in
            self?.sensorsReader?.read()
        }
        self.settingsView.setInterval = { [weak self] value in
            self?.sensorsReader?.setInterval(value)
        }
        self.settingsView.HIDcallback = { [weak self] in
            DispatchQueue.global(qos: .background).async {
                self?.sensorsReader?.HIDCallback()
                DispatchQueue.main.async {
                    self?.popupView.setup(self?.sensorsReader?.list.sensors)
                    self?.portalView.setup(self?.sensorsReader?.list.sensors)
                    self?.settingsView.setList(self?.sensorsReader?.list.sensors)
                    self?.notificationsView.setup(self?.sensorsReader?.list.sensors)
                }
            }
        }
        self.settingsView.unknownCallback = { [weak self] in
            DispatchQueue.global(qos: .background).async {
                self?.sensorsReader?.unknownCallback()
                DispatchQueue.main.async {
                    self?.popupView.setup(self?.sensorsReader?.list.sensors)
                    self?.portalView.setup(self?.sensorsReader?.list.sensors)
                    self?.settingsView.setList(self?.sensorsReader?.list.sensors)
                    self?.notificationsView.setup(self?.sensorsReader?.list.sensors)
                }
            }
        }
        self.selectedSensor = Store.shared.string(key: "\(ModuleType.sensors.stringValue)_sensor", defaultValue: self.selectedSensor)
        self.settingsView.selectedHandler = { [weak self] value in
            self?.selectedSensor = value
            self?.sensorsReader?.read()
        }

        self.clearStaleFanIntent()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(self.suspendFanEnforcement),
            name: NSWorkspace.willSleepNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(self.resumeFanEnforcement),
            name: NSWorkspace.didWakeNotification, object: nil
        )

        self.setReaders([self.sensorsReader])
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
    
    public override func willTerminate() {
        guard SMCHelper.shared.isActive(), let reader = self.sensorsReader else { return }

        reader.list.sensors.filter({ $0 is Fan }).forEach { (s: Sensor_p) in
            if let f = s as? Fan, let mode = f.customMode {
                if !mode.isAutomatic {
                    SMCHelper.shared.setFanMode(f.id, mode: FanMode.automatic.rawValue)
                }
            }
        }
    }

    // MARK: - manual fan mode enforcement

    private func clearStaleFanIntent() {
        // Without "Save the fan speed" a manual mode must not survive a restart:
        // the SMC was reverted to automatic on the last quit, so a stored manual
        // intent is stale and would otherwise be re-asserted by the enforcement.
        guard !Store.shared.bool(key: "\(ModuleType.sensors.stringValue)_speed", defaultValue: false) else { return }
        for sensor in self.sensorsReader?.list.sensors ?? [] {
            guard var fan = sensor as? Fan, !fan.isComputed, fan.customMode?.isAutomatic == false else { continue }
            fan.customMode = .automatic
        }
    }

    @objc private func suspendFanEnforcement() {
        self.fanEnforcementQueue.async { [weak self] in
            self?.fanEnforcementSuspendedUntil = Date.distantFuture
            self?.fanEnforcementFirstMismatch = [:]
            self?.fanEnforcementAttempts = [:]
        }
    }

    @objc private func resumeFanEnforcement() {
        self.fanEnforcementQueue.async { [weak self] in
            self?.fanEnforcementSuspendedUntil = Date(timeIntervalSinceNow: 30)
        }
    }

    // Runs on fanEnforcementQueue.
    private func enforceFanIntent(_ sensors: [Sensor_p]) {
        guard Store.shared.bool(key: "Sensors_fanControl", defaultValue: true) else { return }
        if let until = self.fanEnforcementSuspendedUntil {
            guard Date() > until else { return }
            self.fanEnforcementSuspendedUntil = nil
        }

        for sensor in sensors {
            guard let fan = sensor as? Fan, !fan.isComputed else { continue }
            guard let intent = fan.customMode, !intent.isAutomatic, fan.mode.isAutomatic else {
                self.fanEnforcementFirstMismatch[fan.id] = nil
                self.fanEnforcementAttempts[fan.id] = nil
                continue
            }
            guard let since = self.fanEnforcementFirstMismatch[fan.id] else {
                self.fanEnforcementFirstMismatch[fan.id] = Date()
                continue
            }
            guard Date().timeIntervalSince(since) >= Sensors.fanEnforcementDelay else { continue }

            let attempts = self.fanEnforcementAttempts[fan.id] ?? 0
            guard attempts < Sensors.fanEnforcementMaxAttempts else {
                self.abandonFanIntent(fan)
                continue
            }
            self.fanEnforcementAttempts[fan.id] = attempts + 1
            self.fanEnforcementFirstMismatch[fan.id] = Date()

            NSLog("fan \(fan.id): manual mode was reclaimed by the system, re-applying (attempt \(attempts + 1))")
            let speed = fan.customSpeed
            DispatchQueue.global(qos: .utility).async {
                guard SMCHelper.shared.isInstalled else { return }
                SMCHelper.shared.setFanMode(fan.id, mode: intent.rawValue)
                if let speed {
                    SMCHelper.shared.setFanSpeed(fan.id, speed: speed)
                }
            }
        }
    }

    // Runs on fanEnforcementQueue.
    private func abandonFanIntent(_ fan: Fan) {
        var fan = fan
        fan.customMode = .automatic
        self.fanEnforcementFirstMismatch[fan.id] = nil
        self.fanEnforcementAttempts[fan.id] = nil
        NSLog("fan \(fan.id): re-applying manual mode failed \(Sensors.fanEnforcementMaxAttempts) times, reverting to automatic")
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .fanModeReverted, object: nil, userInfo: ["id": fan.id])
        }
    }
    
    private func usageCallback(_ raw: Sensors_List?) {
        guard let value = raw, self.enabled else { return }

        self.fanEnforcementQueue.async { [weak self] in
            self?.enforceFanIntent(value.sensors)
        }

        self.popupView.usageCallback(value.sensors)
        self.portalView.usageCallback(value.sensors)
        self.notificationsView.usageCallback(value.sensors)
        
        let activeWidgets = self.menuBar.widgets.filter{ $0.isActive }
        self.sensorsReader?.sleepMode(state: activeWidgets.contains(where: {$0.item is Label}) && activeWidgets.count == 1)
        
        activeWidgets.forEach { (w: SWidget) in
            switch w.item {
            case let widget as Mini:
                if let active = value.sensors.first(where: { $0.key == self.selectedSensor }) {
                    var value: Double = active.localValue/100
                    var unit: String = active.miniUnit
                    if let fan = active as? Fan, self.fanValueState == .percentage {
                        value = Double(fan.percentage)/100
                        unit = "%"
                    }
                    if value > 999 {
                        unit = ""
                    }
                    widget.setValue(value)
                    widget.setSuffix(unit)
                }
            case let widget as StackWidget:
                var list: [Stack_t] = []
                
                value.sensors.forEach { (s: Sensor_p) in
                    if s.state {
                        var value = s.formattedMiniValue
                        if let f = s as? Fan {
                            if self.fanValueState == .percentage {
                                value = "\(f.percentage)%"
                            }
                        }
                        list.append(Stack_t(key: s.key, value: value))
                    }
                }
                
                widget.setValues(list)
            case let widget as BarChart:
                var flatList: [[ColorValue]] = []
                value.sensors.filter{ $0 is Fan }.forEach { (s: Sensor_p) in
                    if s.state, let f = s as? Fan {
                        flatList.append([ColorValue(Double(f.percentage) / 100)])
                    }
                }
                widget.setValue(flatList)
            default: break
            }
        }
    }
}
