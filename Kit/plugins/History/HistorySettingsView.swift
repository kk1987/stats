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
public final class HistorySettingsView: NSStackView {
    public init() {
        super.init(frame: NSRect.zero)
        self.translatesAutoresizingMaskIntoConstraints = false
        self.orientation = .vertical
        self.spacing = Constants.Settings.margin
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - master switch (ON by default; off means zero ingest and zero writes)
    // MARK: - live readout ("N lanes · X MB", path tooltip, Reveal in Finder)
    // MARK: - retention preset picker (R2)
    // MARK: - delete history (quiesce, munmap, unlink, recreate)
    // MARK: - status banner (low disk space, write failures, another instance)
}
