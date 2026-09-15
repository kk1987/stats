//
//  HistoryExport.swift
//  Kit
//
//  Persistent usage history: CSV export of the visible range. Release 2.
//  Design: docs/usage-history-design.md (§1, §5), exelban/stats#1194.
//

import Cocoa
import UniformTypeIdentifiers

/// Writes the visible range of the selected lanes as CSV, on the read path the
/// chart needs anyway. Gap and held buckets are marked rather than emitted as
/// values, so an exported series never presents a held or missing sample as a
/// measured one.
///
/// The file is a public contract — §5 documents it and #630 wants to feed it to
/// Grafana — so nothing in it is localized and nothing in it is derived from
/// what the window happens to be displaying: values are written in the unit
/// they were recorded in, with a `.` decimal separator and no thousands
/// separator, whatever the app runs in.
public final class HistoryCSVExporter {
    /// RFC 4180's own line ending. Every parser worth the name takes a bare LF
    /// too, but Excel is the reason the RFC says CRLF and Excel is half of what
    /// this file is opened in.
    public static let newline = "\r\n"
    /// The first and last header cells. Fixed English tokens rather than
    /// localized ones: a column a script selects by name cannot be renamed by
    /// the reader's language.
    public static let timestampColumn = "timestamp"
    public static let gapColumn = "gap"

    private let timeZone: TimeZone
    private let formatter: DateFormatter

    /// `locale` is the locale the app runs in, and it is taken here only so
    /// that it can be replaced: see `fileLocale(from:)`.
    public init(locale: Locale = .current, timeZone: TimeZone = .current) {
        self.timeZone = timeZone
        self.formatter = HistoryCSVExporter.formatter(locale: locale, timeZone: timeZone)
    }

    // MARK: - header (lane label and unit, then the gap column)

    /// `timestamp`, three cells per lane, and `gap`.
    ///
    /// There is no preamble naming the range, the tier or the machine, however
    /// useful that would be to a human reading the file: RFC 4180 has no
    /// comment syntax, so a header block above the header line is a parse error
    /// in every tool that would otherwise open this without being told
    /// anything. The range is in the file name and in the first and last
    /// timestamps, which is where a parser can reach it.
    public func header(for lanes: [HistoryLaneColumns]) -> String {
        var cells = [HistoryCSVExporter.timestampColumn]
        cells.reserveCapacity(lanes.count * 3 + 2)
        for lane in lanes {
            let unit = lane.entry.unit.csvSymbol
            for field in ["min", "avg", "max"] {
                cells.append(HistoryCSVExporter.quoted("\(lane.entry.label) \(field) (\(unit))"))
            }
        }
        cells.append(HistoryCSVExporter.gapColumn)
        return cells.joined(separator: ",")
    }

    // MARK: - rows (one per drawn column: timestamp, min/avg/max per lane, gap)

    /// One row. A lane with nothing in this column contributes three empty
    /// cells and never a zero — a measured zero and no measurement at all are
    /// the two things this whole feature exists to keep apart (§3).
    public func row(_ column: Int, plan: HistoryColumnPlan, lanes: [HistoryLaneColumns]) -> String {
        var cells = [self.timestamp(plan.columnStart(column))]
        cells.reserveCapacity(lanes.count * 3 + 2)
        for lane in lanes {
            guard column >= 0, column < lane.columns.count,
                  let value = lane.columns[column], value.count > 0 else {
                cells.append(contentsOf: ["", "", ""])
                continue
            }
            let unit = lane.entry.unit
            cells.append(self.value(value.min, unit: unit))
            cells.append(self.value(value.avg, unit: unit))
            cells.append(self.value(value.max, unit: unit))
        }
        cells.append(HistoryCSVExporter.reason(at: column, lanes: lanes).csvToken)
        return cells.joined(separator: ",")
    }

    /// The whole file.
    public func document(_ result: HistoryQueryResult) -> String {
        var lines = [self.header(for: result.lanes)]
        lines.reserveCapacity(result.plan.columns + 2)
        for column in 0..<result.plan.columns {
            lines.append(self.row(column, plan: result.plan, lanes: result.lanes))
        }
        // Trailing newline: RFC 4180 leaves it optional and every text file on
        // this platform has one.
        return lines.joined(separator: HistoryCSVExporter.newline) + HistoryCSVExporter.newline
    }

    /// What the row's `gap` cell says.
    ///
    /// One cell describes the whole row, so it answers about the row: a row
    /// anything was measured in is measured, a row nothing was measured in but
    /// something was held is held, and otherwise it carries the reason the read
    /// derived. A lane holding its last level while another lane is being
    /// measured is therefore invisible in it — the alternative is a gap cell
    /// per lane, which widens every lane by a third for something that is
    /// empty in all but a handful of rows.
    static func reason(at column: Int, lanes: [HistoryLaneColumns]) -> HistoryGapReason {
        var held = false
        var gap: HistoryGapReason?

        for lane in lanes {
            guard column >= 0, column < lane.columns.count else { continue }
            guard let value = lane.columns[column] else {
                if gap == nil { gap = .nodata }
                continue
            }
            if value.count > 0, value.reason == .measured { return .measured }
            if value.reason == .held {
                held = true
            } else if gap == nil || gap == .nodata {
                gap = value.reason
            }
        }

        if held { return .held }
        return gap ?? .nodata
    }

    // MARK: - cells

    /// One value, in the unit it was recorded in.
    ///
    /// Not `HistoryLaneUnit.format` — that one is for a human reading a chart:
    /// it scales bytes to "1.2 GB", rounds rpm to whole numbers, converts °C to
    /// °F for a user who asked for it, and writes "—" for a value it cannot
    /// show. All four are wrong in a file something else is going to parse, and
    /// the last two would make the same lane export differently on two
    /// machines.
    public func value(_ value: Float, unit: HistoryLaneUnit) -> String {
        guard value.isFinite else { return "" }
        // Percent lanes store a fraction of 1 and are scaled here, exactly as
        // the chart formatter scales them, so the two agree on what "80" means.
        let scaled = unit == .percent ? Double(value) * 100 : Double(value)
        // `String(format:)` with no locale argument is the C locale, which is
        // the point: handed the app's own, `en_IN` — whose decimal separator is
        // already "." — writes 12,345.50, which is one value in two cells, and
        // `ne_NP` writes it in Devanagari digits.
        return String(format: "%.2f", scaled)
    }

    /// The column's start, ISO 8601 with a numeric UTC offset.
    ///
    /// Local time with the offset spelled out, rather than UTC: the question
    /// the feature answers is "what was this machine doing at 03:10 last
    /// Tuesday" (§1), and 03:10 is a wall clock. The offset is what keeps that
    /// unambiguous across the DST boundary the row may well be sitting on.
    public func timestamp(_ ts: TimeInterval) -> String {
        self.formatter.string(from: Date(timeIntervalSince1970: ts))
    }

    /// RFC 4180: a cell holding a comma, a quote or a line break is wrapped in
    /// quotes and its own quotes are doubled. Lane labels are device names —
    /// volume names and sensor labels the user or the vendor chose — so this is
    /// reachable from the header line and not only in theory.
    public static func quoted(_ cell: String) -> String {
        // Scalars, not `contains("\n")`: a CRLF inside a cell is *one* Swift
        // grapheme cluster, and neither `contains("\r")` nor `contains("\n")`
        // matches half of it — so the one cell that would end the row early is
        // precisely the one the obvious check waves through.
        let breaksTheRow = cell.unicodeScalars.contains { $0 == "\n" || $0 == "\r" }
        guard breaksTheRow || cell.contains(",") || cell.contains("\"") else { return cell }
        return "\"\(cell.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// `xxx` and not `ZZZZZ`: both are ISO 8601, but `ZZZZZ` writes UTC as "Z"
    /// and the numeric form is one case fewer for whatever reads this.
    private static func formatter(locale: Locale, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = HistoryCSVExporter.fileLocale(from: locale)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        return formatter
    }

    /// POSIX, whatever the app runs in — and this is the one line where the
    /// app's locale could have reached the file.
    ///
    /// A fixed `dateFormat` is not enough on its own: the locale still picks
    /// the calendar and the digits, so `th_TH` would date these rows in the
    /// Buddhist era, 543 years out, and `ar_SA` would write the year in
    /// Arabic-Indic digits. Neither parses anywhere.
    private static func fileLocale(from locale: Locale) -> Locale {
        locale.identifier == "en_US_POSIX" ? locale : Locale(identifier: "en_US_POSIX")
    }

    // MARK: - save panel and write

    /// Asks for a file, then reads, formats and writes off main.
    ///
    /// The plan is the window's own, not a fresh one: a re-plan against "now"
    /// would export a range shifted by however long the save panel was open,
    /// and the file is supposed to hold the range the user was looking at when
    /// they pressed the button.
    ///
    /// Main thread only.
    public func save(lanes: [Int], plan: HistoryColumnPlan, in window: NSWindow?) {
        let panel = NSSavePanel()
        panel.title = localizedString("Export CSV")
        panel.nameFieldStringValue = HistoryCSVExporter.suggestedName(for: plan.range)
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.showsTagField = false
        panel.isExtensionHidden = false

        let save: (NSApplication.ModalResponse) -> Void = { [weak window] response in
            guard response == .OK, let url = panel.url else { return }
            // Everything below this line is off main: a year of thirty-minute
            // columns across eight lanes is ~1,460 rows of 26 cells to format
            // and a file to write, and §7 budgets main for neither.
            HistoryRecorder.shared.query(lanes: lanes, plan: plan) { result in
                var failure: Error?
                do {
                    try self.write(result, to: url)
                } catch {
                    failure = error
                }
                guard let error = failure else { return }
                DispatchQueue.main.async { HistoryCSVExporter.report(error, in: window) }
            }
        }

        // A sheet when the window is there to hang it on, which it is on every
        // path that reaches this today; `begin` is the fallback rather than a
        // crash in a future caller that has no window.
        if let window = window {
            panel.beginSheetModal(for: window, completionHandler: save)
        } else {
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.modalPanelWindow)))
            panel.begin(completionHandler: save)
        }
    }

    public func write(_ result: HistoryQueryResult, to url: URL) throws {
        // UTF-8 and no byte-order mark. A BOM is what makes Excel read the
        // header's "°C" correctly and what makes every naive parser read the
        // first cell as "\u{FEFF}timestamp"; the parsers are the audience §1
        // names.
        try self.document(result).write(to: url, atomically: true, encoding: .utf8)
    }

    /// "Stats history 24 hours.csv" — the range is what distinguishes two
    /// exports taken minutes apart, and it is the one part of this file that is
    /// written in the user's own language, because it is a file name and not a
    /// cell.
    static func suggestedName(for range: HistoryRange) -> String {
        let name = localizedString("Stats history %0", range.localizedTitle)
        // A translation is free text and "/" is a path separator: Finder shows
        // it back as ":", which is not what anybody meant.
        return "\(name.replacingOccurrences(of: "/", with: "-")).csv"
    }

    private static func report(_ error: Error, in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = localizedString("Export CSV")
        alert.informativeText = "\(localizedString("History could not be exported"))\n\n\(error.localizedDescription)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: localizedString("Close"))

        if let window = window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}

// MARK: - the file's own vocabulary

public extension HistoryLaneUnit {
    /// What a header cell says the lane is measured in.
    ///
    /// The stored unit, never the displayed one: `HistoryLaneUnit.format`
    /// converts °C to °F for a user who set that, and a file whose numbers
    /// change meaning with a display setting is not a contract. Bytes are
    /// bytes and rates are bytes per second, un-prefixed, for the same reason —
    /// "1.2 GB/s" is three cells' worth of ambiguity in one.
    var csvSymbol: String {
        switch self {
        case .percent: return "%"
        case .bytesPerSec: return "B/s"
        case .bytes: return "B"
        case .celsius: return "°C"
        case .watts: return "W"
        case .volts: return "V"
        case .rpm: return "RPM"
        }
    }
}

public extension HistoryGapReason {
    /// The gap cell's vocabulary: lowercase, ASCII, and stable across
    /// languages, because it is what a script filters on. Empty for a measured
    /// row, so the column is blank in the rows nobody is looking for.
    var csvToken: String {
        switch self {
        case .measured: return ""
        case .held: return "held"
        case .asleep: return "asleep"
        case .notRunning: return "not_running"
        case .clockStep: return "clock_step"
        case .nodata: return "no_data"
        }
    }
}
