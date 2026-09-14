//
//  HistorySettingsView.swift
//  Kit
//
//  Persistent usage history: the "Stored history" section in App settings.
//  Design: docs/usage-history-design.md (§6 Settings), exelban/stats#1194.
//

import Cocoa

/// One section in App settings, and the only in-app control over what the
/// recorder writes. There is deliberately no per-module and no per-sensor
/// checkbox: per-lane opt-in belongs in the window sidebar, where the lanes are
/// enumerated (§6).
///
/// A `PreferencesSection` rather than a view that builds one, because the
/// section header's subtitle is exactly the status banner §6 asks for — three
/// states that are not "recording" — and `setSubtitle` already makes it live.
public final class HistorySettingsView: PreferencesSection {
    private var recordSwitch: NSSwitch?
    private var deleteButton: NSButton?
    private var presetSelect: NSPopUpButton?
    private let readout: NSTextField

    /// Reading the directory is filesystem work and this is main, so the bytes
    /// are fetched off it. §7's rule is that nothing blocks main on I/O, and a
    /// settings panel is not an exception to it.
    private let sizeQueue = DispatchQueue(label: "eu.exelban.history.settings", qos: .utility)

    /// Stamped on every `refresh` and compared when the byte count comes back.
    /// Two refreshes in quick succession — the toggle, then the panel appearing
    /// — hop through two queues, and without this the older sum can land last
    /// and leave a stale figure on screen.
    private var generation: UInt64 = 0

    public init() {
        self.readout = LabelField()
        super.init(title: localizedString("Stored history"))

        let recordSwitch = self.switchView(
            action: #selector(self.toggleRecording),
            state: HistoryRecorder.isEnabledInSettings
        )
        let deleteButton = self.buttonView(#selector(self.deleteHistory), text: localizedString("Delete"))
        let presetSelect = HistorySettingsView.presetView(target: self, action: #selector(self.changePreset))
        self.recordSwitch = recordSwitch
        self.deleteButton = deleteButton
        self.presetSelect = presetSelect

        self.add(PreferencesRow(localizedString("Record usage history"), component: recordSwitch))
        self.add(PreferencesRow(localizedString("Size on disk"), component: self.readoutView()))
        self.add(PreferencesRow(localizedString("Retention"), component: presetSelect))
        self.add(PreferencesRow(localizedString("Delete history"), component: deleteButton))

        self.refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - live readout ("N lanes · X MB", path tooltip, Reveal in Finder)

    /// Lane count next to bytes, because the lane count is the variable that
    /// moves: a fixed number in a settings string cannot stay true when every
    /// interface switch and every mounted volume adds lanes (§6, risk 2).
    private func readoutView() -> NSView {
        let view = NSStackView()
        view.orientation = .horizontal
        view.alignment = .centerY
        view.spacing = Constants.Settings.margin

        view.addArrangedSubview(self.readout)
        view.addArrangedSubview(self.buttonView(
            #selector(self.revealInFinder),
            text: localizedString("Reveal in Finder")
        ))
        return view
    }

    /// Re-reads everything the section shows. Called when the settings panel is
    /// about to appear and after any action that could change one of them.
    public func refresh() {
        let recorder = HistoryRecorder.shared
        let status = recorder.status
        let lanes = recorder.laneCount
        let store = recorder.store

        self.recordSwitch?.state = HistoryRecorder.isEnabledInSettings ? .on : .off
        self.setSubtitle(HistorySettingsView.banner(for: status))
        // Another copy of Stats owns those files; this one must not unlink them
        // and must not reorganize them either.
        self.deleteButton?.isEnabled = status != .lockedByAnotherInstance
        self.presetSelect?.isEnabled = status != .lockedByAnotherInstance
        self.refreshPresetTitles(lanes: lanes)

        self.generation &+= 1
        let generation = self.generation
        self.sizeQueue.async { [weak self] in
            let bytes = store.bytesOnDisk
            let path = store.directory.path
            DispatchQueue.main.async {
                guard let self = self, generation == self.generation else { return }
                // Two keys rather than one, because a format string cannot
                // pluralize and a fresh install with a single lane would read
                // "1 lanes". Both are spelled out at the call site so that
                // `Kit/scripts/i18n.py scan` still sees them as used.
                let size = Units(bytes: bytes).getReadableMemory()
                self.readout.stringValue = lanes == 1
                    ? localizedString("%0 lane · %1", "\(lanes)", size)
                    : localizedString("%0 lanes · %1", "\(lanes)", size)
                // The real path, so the readout is checkable against `du` (§6).
                self.readout.toolTip = path
            }
        }
    }

    // MARK: - retention preset (Minimal 24 h, Standard 24 h + 30 d + 1 y)

    /// The two entries §6 names, and nothing else. Built empty of titles: the
    /// title carries the projected size, which is a function of the live lane
    /// count, so it is written in `refresh` rather than here.
    private static func presetView(target: AnyObject, action: Selector) -> NSPopUpButton {
        let select = NSPopUpButton()
        select.target = target
        select.action = action

        let menu = NSMenu()
        for preset in HistoryRetentionPreset.allCases {
            let item = NSMenuItem(title: HistorySettingsView.name(of: preset), action: nil, keyEquivalent: "")
            item.representedObject = preset.rawValue
            menu.addItem(item)
        }
        select.menu = menu
        return select
    }

    /// Spelled out per case rather than derived from the enum, so that
    /// `Kit/scripts/i18n.py scan` still sees both keys as used — the same
    /// reason the two lane-count keys above are written out at their call site.
    ///
    /// The retention window is part of the name because "Minimal" on its own
    /// says nothing about what is kept, and this picker is the one place the
    /// user decides how far back their history goes.
    private static func name(of preset: HistoryRetentionPreset) -> String {
        switch preset {
        case .minimal: return localizedString("Minimal (24 hours)")
        case .standard: return localizedString("Standard (24 hours, 30 days, 1 year)")
        }
    }

    /// §6: the picker shows the projected size **from the current lane count**,
    /// not from a ceiling — so both entries carry their own figure and the user
    /// compares them before choosing rather than after.
    ///
    /// With no lanes registered there is nothing to project from — the switch
    /// is off, or the recorder never opened — and the entries are left as bare
    /// names. A projection of two file headers would be a true number that
    /// answers the wrong question.
    private func refreshPresetTitles(lanes: Int) {
        let selected = HistoryRecorder.retentionPreset
        for item in self.presetSelect?.menu?.items ?? [] {
            guard let raw = item.representedObject as? String,
                  let preset = HistoryRetentionPreset(rawValue: raw) else { continue }
            let name = HistorySettingsView.name(of: preset)
            item.title = lanes > 0
                ? "\(name) · \(Units(bytes: preset.projectedBytes(lanes: lanes)).getReadableMemory())"
                : name
            if preset == selected { self.presetSelect?.select(item) }
        }
    }

    /// Growing is silent; shrinking asks first, because a year of history is
    /// what goes (§3, §6).
    @objc private func changePreset(_ sender: NSPopUpButton) {
        let stored = HistoryRecorder.retentionPreset
        guard let raw = sender.selectedItem?.representedObject as? String,
              let preset = HistoryRetentionPreset(rawValue: raw), preset != stored else { return }

        // The confirmation is decided against what the recorder actually has
        // open, not against the stored preference: the two diverge after an
        // apply that declined, and it is the live tiers that are about to be
        // unlinked. And "shrink" is which tiers go, not how many — a third
        // preset of the same length but a different shape would otherwise slip
        // past the question silently.
        let live = HistoryRecorder.shared.preset
        if !live.tiers.allSatisfy(preset.tiers.contains) {
            let alert = NSAlert()
            alert.messageText = localizedString("Reduce stored history")
            alert.informativeText = localizedString("Reduce stored history text")
            alert.alertStyle = .warning
            alert.addButton(withTitle: localizedString("Delete"))
            alert.addButton(withTitle: localizedString("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else {
                // The popup has already moved to the entry the user clicked.
                self.refresh()
                return
            }
        }

        // Stored first, and unconditionally: this is the preference, and it is
        // what `start` opens at the next launch. `setPreset` is the live half,
        // and it can legitimately decline — another copy of Stats holding the
        // flock is a normal state in this fork — without that making the user's
        // choice any less their choice.
        HistoryRecorder.retentionPreset = preset
        // Blocks main for a hop onto the history queue plus, on a grow, one
        // pass over the 24 h T0 retains. That is the same trade the Delete
        // button makes: the archives have to be in their new shape before
        // anything can read them again.
        let outcome = HistoryRecorder.shared.setPreset(preset)
        self.refresh()

        let text: String
        switch outcome {
        case .applied: return
        case .declined: text = localizedString("History retention could not be changed")
        // Nothing was lost on a grow that failed, so that one keeps the wording
        // above; this branch is a shrink whose tiers are already unlinked, and
        // saying "could not be changed" about it would be the opposite of true.
        case .partial: text = localizedString("History retention was only partly changed")
        }

        let failure = NSAlert()
        failure.messageText = localizedString("Retention")
        failure.informativeText = text
        failure.alertStyle = .warning
        failure.addButton(withTitle: localizedString("Close"))
        failure.runModal()
    }

    // MARK: - status banner (low disk space, write failures, another instance)

    /// The three states that are not "recording" (§6). Recording and disabled
    /// both say nothing: the switch above already shows which one it is.
    private static func banner(for status: HistoryStore.Status) -> String {
        switch status {
        case .recording, .disabled:
            return ""
        case .lowDiskSpace:
            return localizedString("History paused — low disk space")
        case .writeFailures:
            return localizedString("History suspended — write errors")
        case .lockedByAnotherInstance:
            return localizedString("History is being recorded by another copy of Stats")
        }
    }

    // MARK: - actions

    /// The master switch. The preference is stored as well as applied, because
    /// it is what `start()` reads at the next launch — a switch that only
    /// stopped the running recorder would come back on after a restart.
    @objc private func toggleRecording(_ sender: NSSwitch) {
        let enabled = sender.state == .on
        HistoryRecorder.isEnabledInSettings = enabled
        HistoryRecorder.shared.setRecording(enabled)
        self.refresh()
    }

    @objc private func revealInFinder() {
        let url = HistoryRecorder.shared.store.directory
        // On a launch that never got as far as creating it, show the parent
        // rather than a Finder window pointed at nothing.
        let target = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    // MARK: - delete history (quiesce, unmap, unlink, recreate)

    @objc private func deleteHistory() {
        let alert = NSAlert()
        alert.messageText = localizedString("Delete history")
        alert.informativeText = localizedString("Delete history text")
        alert.alertStyle = .warning
        alert.addButton(withTitle: localizedString("Delete"))
        alert.addButton(withTitle: localizedString("Cancel"))

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Blocks main for the length of one hop onto the history queue plus a
        // handful of `unlink`s. That is the trade §6 names: the delete has to be
        // finished before anything can look at the directory again.
        let deleted = HistoryRecorder.shared.deleteAll()
        self.refresh()

        // The button is disabled only for `.lockedByAnotherInstance`, and the
        // real gate is the flock — a directory that could not be locked at all
        // leaves the button live and the delete refusing. Saying so beats a
        // destructive confirmation that silently does nothing.
        guard !deleted else { return }
        let failure = NSAlert()
        failure.messageText = localizedString("Delete history")
        failure.informativeText = localizedString("History could not be deleted")
        failure.alertStyle = .warning
        failure.addButton(withTitle: localizedString("Close"))
        failure.runModal()
    }
}
