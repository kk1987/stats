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
        self.recordSwitch = recordSwitch
        self.deleteButton = deleteButton

        self.add(PreferencesRow(localizedString("Record usage history"), component: recordSwitch))
        self.add(PreferencesRow(localizedString("Size on disk"), component: self.readoutView()))
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
        // Another copy of Stats owns those files; this one must not unlink them.
        self.deleteButton?.isEnabled = status != .lockedByAnotherInstance

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
