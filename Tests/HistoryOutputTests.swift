//
//  HistoryOutputTests.swift
//  Tests
//
//  Persistent usage history: everything the stored series is read out as — the
//  column plan behind the chart, the CSV export, and the daily network totals
//  in the Net popup. Fixtures in `HistoryTestSupport.swift`.
//  Design: docs/usage-history-design.md (§3, §5, §10), exelban/stats#1194.
//

import XCTest
import Kit

final class HistoryOutputTests: HistoryTestCase {

    // MARK: - column plan and the read-side query
    //
    // Range to tier and to drawn columns; the count-weighted resampling the
    // slot's `sum` + `count` exists for; and the gap columns the chart hatches
    // instead of interpolating across.

    /// §3 fixes the column counts — 360 at 10 s for 1 h, 720 at 30 s for 6 h,
    /// 720 at 2 min for 24 h, 504 at 20 min for 7 d, 1,440 at 30 min for 30 d,
    /// 1,460 at 6 h for 1 y — and the reason: a column that is a whole number
    /// of buckets wide keeps the min/max envelope from stuttering at exactly
    /// the ranges users stare at. Both halves are asserted, for every range.
    func testEachRangeReadsFromTheTierAndColumnCountTheDesignStates() throws {
        let now: TimeInterval = 1_700_000_000
        let expected: [(range: HistoryRange, tier: HistoryTier, columns: Int, seconds: Int)] = [
            (.hour, .t0, 360, 10),
            (.sixHours, .t0, 720, 30),
            (.day, .t1, 720, 120),
            (.week, .t1, 504, 1_200),
            (.month, .t2, 1_440, 1_800),
            (.year, .t2, 1_460, 21_600)
        ]

        for row in expected {
            let plan = HistoryColumnPlan.plan(for: row.range, endingAt: now)
            XCTAssertEqual(plan.tier, row.tier, "\(row.range)")
            XCTAssertEqual(plan.columns, row.columns, "\(row.range)")
            XCTAssertEqual(plan.columnSeconds, row.seconds, "\(row.range)")

            // The coarsest tier is finer than one column, every column is a
            // whole number of buckets, and the columns cover the range exactly.
            XCTAssertLessThanOrEqual(plan.tier.step, plan.columnSeconds, "\(row.range)")
            XCTAssertEqual(plan.buckets.count % plan.bucketsPerColumn, 0, "\(row.range)")
            XCTAssertEqual(plan.columns * plan.columnSeconds, row.range.seconds, "\(row.range)")
            // And the tier retains every bucket the range asks it for.
            XCTAssertLessThanOrEqual(plan.buckets.count, plan.tier.buckets, "\(row.range)")
            XCTAssertEqual(plan.retainedColumns, plan.columns, "\(row.range)")

            // Time-indexed: a column's position is its timestamp.
            XCTAssertEqual(plan.columnStart(0), plan.start, "\(row.range)")
            XCTAssertEqual(plan.column(at: plan.start), 0, "\(row.range)")
            XCTAssertEqual(plan.column(at: plan.end - 1), plan.columns - 1, "\(row.range)")
            XCTAssertNil(plan.column(at: plan.end), "\(row.range)")
        }
    }

    /// A column narrower than a pixel is work nobody can see, so the chart's
    /// width caps the count — by widening the column a whole factor, never a
    /// fraction, so it stays a whole number of buckets.
    func testANarrowChartWidensTheColumnByAWholeNumberOfBuckets() throws {
        let now: TimeInterval = 1_700_000_000

        let narrow = HistoryColumnPlan.plan(for: .month, endingAt: now, maxColumns: 400)
        XCTAssertEqual(narrow.tier, .t2)
        XCTAssertEqual(narrow.bucketsPerColumn, 4)
        XCTAssertEqual(narrow.columns, 360)
        XCTAssertLessThanOrEqual(narrow.columns, 400)
        XCTAssertEqual(narrow.buckets.count % narrow.bucketsPerColumn, 0)
        XCTAssertEqual(narrow.columns * narrow.columnSeconds, HistoryRange.month.seconds)

        // The degenerate width still produces a plan rather than a division by
        // zero: one column holding the whole range.
        let sliver = HistoryColumnPlan.plan(for: .month, endingAt: now, maxColumns: 1)
        XCTAssertEqual(sliver.columns, 1)
        XCTAssertEqual(sliver.columnSeconds, HistoryRange.month.seconds)
    }

    /// The Minimal preset has only T0 open. A day still reads — twelve 10 s
    /// buckets per 2-minute column — and a month reads what T0's ring can still
    /// hold, saying so rather than striding a quarter of a million cells to
    /// discover that the rest is gone.
    func testTheMinimalPresetFallsBackToT0AndSaysWhatItCannotHold() throws {
        let now: TimeInterval = 1_700_000_000

        let day = HistoryColumnPlan.plan(for: .day, endingAt: now, tiers: [.t0])
        XCTAssertEqual(day.tier, .t0)
        XCTAssertEqual(day.bucketsPerColumn, 12)
        XCTAssertEqual(day.columns, 720)
        XCTAssertEqual(day.retainedColumns, 720)

        let month = HistoryColumnPlan.plan(for: .month, endingAt: now, tiers: [.t0])
        XCTAssertEqual(month.tier, .t0)
        XCTAssertEqual(month.bucketsPerColumn, 180)
        XCTAssertEqual(month.columns, 1_440)
        // 24 h of a 30-day range: 8,640 T0 buckets, 48 columns, ending where
        // the range ends.
        XCTAssertEqual(month.retainedColumns, 48)
        XCTAssertEqual(month.retainedBuckets.count, HistoryTier.t0.buckets)
        XCTAssertEqual(month.retainedBuckets.upperBound, month.buckets.upperBound)
    }

    /// Count-weighted, like the rollup and for the same reason: bucket
    /// population is not constant, so one sample at 100 must not outvote nine
    /// at 10. A held bucket keeps its own reason so the chart can dash it.
    func testColumnsAreCountWeightedAndKeepHeldSpansApart() throws {
        let first: UInt32 = 1_000
        let slots: [HistorySlot?] = [
            HistorySlot(bucket: first, count: 1, reason: .measured, min: 100, max: 100, sum: 100),
            HistorySlot(bucket: first + 1, count: 9, reason: .measured, min: 10, max: 10, sum: 90),
            nil,
            nil,
            HistorySlot(bucket: first + 4, count: 1, reason: .held, min: 50, max: 50, sum: 50),
            nil
        ]
        let resolver = HistoryGapResolver(step: HistoryTier.t0.step, firstValidBucket: first,
                                          lastCommitBucket: first + 5, spans: [])

        let columns = HistoryAggregate.columns(slots, from: first, bucketsPerColumn: 2, resolver: resolver)
        XCTAssertEqual(columns.count, 3)

        let measured = try XCTUnwrap(columns[0])
        XCTAssertEqual(measured.avg, 19)
        XCTAssertEqual(measured.min, 10)
        XCTAssertEqual(measured.max, 100)
        XCTAssertEqual(measured.count, 10)
        XCTAssertEqual(measured.reason, .measured)

        // Nothing at all to say: not a measured zero, and not a hatch either.
        XCTAssertNil(columns[1])

        let held = try XCTUnwrap(columns[2])
        XCTAssertEqual(held.reason, .held)
        XCTAssertEqual(held.avg, 50)
        XCTAssertEqual(held.count, 1)

        // A trailing partial column is not drawn: the plan always hands over a
        // whole number of columns, and half a column of buckets would be a
        // column an eleventh as wide as its neighbours.
        XCTAssertEqual(HistoryAggregate.columns(slots, from: first, bucketsPerColumn: 4,
                                                resolver: resolver).count, 1)
        XCTAssertEqual(HistoryAggregate.columns([], from: first, bucketsPerColumn: 2, resolver: nil).count, 0)
    }

    /// A gap column carries the reason and no value. That is what the chart
    /// hatches at 45° and the readout turns into "Asleep 02:14-08:31"; a value
    /// interpolated across it would be the one thing §4 forbids.
    func testGapColumnsCarryTheirReasonAndNeverAValue() throws {
        let step = HistoryTier.t0.step
        let first: UInt32 = 1_000
        let slots: [HistorySlot?] = [
            HistorySlot(bucket: first, count: 4, reason: .measured, min: 1, max: 9, sum: 20),
            HistorySlot(bucket: first + 1, count: 4, reason: .measured, min: 2, max: 8, sum: 20),
            nil, nil,   // asleep
            nil, nil,   // running, but nothing recorded
            nil, nil    // past the last commit
        ]
        let asleep = HistoryGapSpan(from: UInt64(first + 2) * UInt64(step),
                                    to: UInt64(first + 4) * UInt64(step), reason: .asleep)
        let resolver = HistoryGapResolver(step: step, firstValidBucket: first,
                                          lastCommitBucket: first + 5, spans: [asleep])

        let columns = HistoryAggregate.columns(slots, from: first, bucketsPerColumn: 2, resolver: resolver)
        XCTAssertEqual(columns.count, 4)

        let data = try XCTUnwrap(columns[0])
        XCTAssertEqual(data.min, 1)
        XCTAssertEqual(data.max, 9)
        XCTAssertEqual(data.count, 8)

        let sleeping = try XCTUnwrap(columns[1])
        XCTAssertEqual(sleeping.reason, .asleep)
        XCTAssertEqual(sleeping.count, 0)
        XCTAssertEqual(sleeping.min, 0)
        XCTAssertEqual(sleeping.max, 0)

        // Running and recording, with nothing to show for those twenty seconds:
        // §2 collapses a disabled module, a paused app and a reader that
        // stopped answering to no-data rather than guessing between them.
        XCTAssertNil(columns[2])

        let down = try XCTUnwrap(columns[3])
        XCTAssertEqual(down.reason, .notRunning)
        XCTAssertEqual(down.count, 0)

        // Before the lane existed, no span makes the emptiness more specific.
        let fresh = HistoryGapResolver(step: step, firstValidBucket: HistoryLaneEntry.noValidBucket,
                                       lastCommitBucket: first + 5, spans: [asleep])
        let nothing = HistoryAggregate.columns([HistorySlot?](repeating: nil, count: 8), from: first,
                                               bucketsPerColumn: 2, resolver: fresh)
        XCTAssertEqual(nothing.compactMap { $0 }.count, 0)
    }

    /// The read path end to end: a plan, a mapped tier file and the columns the
    /// chart is handed — never the decoded series (§7).
    func testTheStoreReadsARangeAsColumns() throws {
        let now: TimeInterval = 1_700_000_000
        let store = HistoryStore(directory: self.folder)
        defer { store.closeAll() }
        _ = try store.open(preset: .standard)

        let archive = try XCTUnwrap(store.archive(.t0))
        try archive.setDirectory(Self.entries(2))

        let plan = HistoryColumnPlan.plan(for: .hour, endingAt: now)
        XCTAssertEqual(plan.columns, 360)

        // The last ten buckets of the range, one column each.
        let firstWritten = plan.buckets.upperBound - 10
        try archive.commit((0..<10).map { Self.row(firstWritten + UInt32($0), lanes: 2, base: Float($0)) })

        let lane = try XCTUnwrap(store.columns(lane: 0, plan: plan, spans: []))
        XCTAssertEqual(lane.lane, 0)
        XCTAssertEqual(lane.entry.label, "lane 0")
        XCTAssertEqual(lane.columns.count, plan.columns)
        XCTAssertEqual(lane.columns.compactMap { $0 }.count, 10)
        XCTAssertNil(lane.columns[0])
        XCTAssertEqual(lane.columns[plan.columns - 10]?.avg, 0)
        XCTAssertEqual(lane.columns[plan.columns - 1]?.avg, 9)

        let summary = try XCTUnwrap(lane.summary)
        XCTAssertEqual(summary.min, 0)
        XCTAssertEqual(summary.max, 9)
        XCTAssertEqual(summary.count, 10)

        // The second lane is its own series, offset by one, and a lane the
        // directory does not hold is not invented.
        let second = try XCTUnwrap(store.columns(lane: 1, plan: plan, spans: []))
        XCTAssertEqual(second.summary?.max, 10)
        XCTAssertNil(store.columns(lane: 7, plan: plan, spans: []))

        let result = store.query(lanes: [0, 1, 7], plan: plan, spans: [])
        XCTAssertEqual(result.lanes.count, 2)
        XCTAssertEqual(result.plan, plan)
    }

    /// Every unit reads the way its module reads, and none of them trap on a
    /// value the read path is willing to hand them.
    ///
    /// `Int(_: Double)` is a trap rather than an exception, a `Float` reaches
    /// 3.4e38 and `Int.max` is 9.2e18, so `isFinite` alone is not a guard.
    /// Nothing upstream narrows it either: a slot is validated by its 4-byte
    /// bucket stamp, which says nothing about the value behind it, and
    /// `HistoryAggregate.rollup` checks `isFinite` and no magnitude. 2,000 rpm
    /// is `0x44FA0000`; flipping the top exponent bit makes it a finite
    /// 1.04e37, which the archive accepts and the axis then has to label — the
    /// same input class the bit-flip fuzz loop asserts no trap for.
    func testEveryUnitFormatsAHugeFiniteValueWithoutTrapping() throws {
        let flipped = Float(bitPattern: 0x7CFA_0000)
        XCTAssertTrue(flipped.isFinite)

        let units: [HistoryLaneUnit] = [.percent, .bytesPerSec, .bytes, .celsius, .watts, .volts, .rpm]
        for unit in units {
            for value: Float in [flipped, -flipped, .greatestFiniteMagnitude, -.greatestFiniteMagnitude] {
                XCTAssertFalse(unit.format(value).isEmpty, "\(unit) \(value)")
            }
            XCTAssertEqual(unit.format(.nan), "—", "\(unit)")
            XCTAssertEqual(unit.format(.infinity), "—", "\(unit)")
        }

        // Percent lanes store a fraction of 1 and are scaled in the formatter
        // and only there; the three sensor units follow `Sensor_p`.
        XCTAssertEqual(HistoryLaneUnit.percent.format(0.2), "20%")
        XCTAssertEqual(HistoryLaneUnit.rpm.format(2_000), "2000 RPM")
        XCTAssertEqual(HistoryLaneUnit.watts.format(12.5), "12.50 W")
        XCTAssertEqual(HistoryLaneUnit.watts.format(120), "120 W")
        XCTAssertEqual(HistoryLaneUnit.volts.format(11.25), "11.250 V")
    }

    // MARK: - CSV export
    //
    // The file is a public contract (§5): fixed English header tokens, one row
    // per drawn column, values in the unit they were recorded in with a "."
    // decimal separator whatever the app runs in, and a gap column that keeps a
    // held or missing sample from reading as a measured one. Every assertion
    // below is on the exact text, because "the format changed" is not
    // something a user's script finds out gently.

    /// `timestamp`, three cells per lane naming the lane, the statistic and the
    /// stored unit, then `gap`.
    func testTheHeaderLineNamesEveryLaneItsStatisticAndItsUnit() throws {
        let lanes = [
            Self.laneColumns("CPU total", unit: .percent, [nil]),
            Self.laneColumns("Wi-Fi (en0) download", unit: .bytesPerSec, [nil], lane: 1)
        ]

        XCTAssertEqual(HistoryCSVExporter().header(for: lanes), """
        timestamp,CPU total min (%),CPU total avg (%),CPU total max (%),\
        Wi-Fi (en0) download min (B/s),Wi-Fi (en0) download avg (B/s),Wi-Fi (en0) download max (B/s),gap
        """)

        // No lane checked is still a well-formed file rather than a bare
        // timestamp column.
        XCTAssertEqual(HistoryCSVExporter().header(for: []), "timestamp,gap")
    }

    /// A measured row: the column's start in ISO 8601 with a numeric offset,
    /// min/avg/max per lane in the unit the lane was recorded in, and an empty
    /// gap cell.
    func testAMeasuredRowCarriesMinAvgMaxInTheStoredUnit() throws {
        let lanes = [
            Self.laneColumns("CPU total", unit: .percent, [Self.measured(0.105, 0.2, 0.81)]),
            Self.laneColumns("CPU die", unit: .celsius, [Self.measured(41, 45.5, 52.25)], lane: 1)
        ]

        // Percent is stored as a fraction of 1 and exported as 0–100; °C is
        // exported as °C whatever the app displays, because a file whose
        // numbers change meaning with a display setting is not a contract.
        XCTAssertEqual(Self.exporter(offset: 2 * 3_600).row(0, plan: Self.csvPlan(columns: 1), lanes: lanes),
                       "2023-11-15T00:13:20+02:00,10.50,20.00,81.00,41.00,45.50,52.25,")
    }

    /// One gap reason per row, and no values with it: a hatched column has
    /// nothing to say about the series, and a zero there would be the one
    /// mistake the whole feature exists to avoid.
    func testEveryGapReasonHasItsOwnTokenAndNoValues() throws {
        let plan = Self.csvPlan(columns: 1)
        let exporter = Self.exporter()
        let stamp = "2023-11-14T22:13:20+00:00"

        let reasons: [(HistoryGapReason, String)] = [
            (.asleep, "asleep"), (.notRunning, "not_running"),
            (.clockStep, "clock_step"), (.nodata, "no_data")
        ]
        for (reason, token) in reasons {
            let lanes = [Self.laneColumns("CPU total", unit: .percent, [Self.gap(reason)])]
            XCTAssertEqual(exporter.row(0, plan: plan, lanes: lanes), "\(stamp),,,,\(token)", token)
        }

        // A lane the read had nothing at all for is the same three empty cells,
        // and the row says so.
        let missing = [Self.laneColumns("CPU total", unit: .percent, [nil])]
        XCTAssertEqual(exporter.row(0, plan: plan, lanes: missing), "\(stamp),,,,no_data")

        // A lane that ran out of columns — a plan wider than the answer — is
        // the same, rather than an index out of range.
        XCTAssertEqual(exporter.row(3, plan: Self.csvPlan(columns: 4), lanes: missing),
                       "2023-11-14T22:14:20+00:00,,,,no_data")
    }

    /// A held bucket keeps its value: a step lane holds its last level for a
    /// bounded window and that level is real. The token is what stops it
    /// reading as a fresh measurement (§2).
    func testAHeldRowKeepsItsValueAndSaysItIsHeld() throws {
        let plan = Self.csvPlan(columns: 1)
        let exporter = Self.exporter()
        let battery = Self.laneColumns("Battery level", unit: .percent, [Self.held(0.42)])

        XCTAssertEqual(exporter.row(0, plan: plan, lanes: [battery]),
                       "2023-11-14T22:13:20+00:00,42.00,42.00,42.00,held")

        // Held outranks a gap — the row has a value — and a measured lane
        // outranks held, because one cell describes the whole row and a row
        // something was measured in is a measured row.
        let asleep = Self.laneColumns("CPU total", unit: .percent, [Self.gap(.asleep)], lane: 1)
        XCTAssertEqual(exporter.row(0, plan: plan, lanes: [asleep, battery]),
                       "2023-11-14T22:13:20+00:00,,,,42.00,42.00,42.00,held")

        let cpu = Self.laneColumns("CPU total", unit: .percent, [Self.measured(0.1, 0.1, 0.1)], lane: 1)
        XCTAssertEqual(exporter.row(0, plan: plan, lanes: [battery, cpu]),
                       "2023-11-14T22:13:20+00:00,42.00,42.00,42.00,10.00,10.00,10.00,")
    }

    /// RFC 4180: a cell holding a comma, a quote or a line break is wrapped in
    /// quotes with its own quotes doubled. Lane labels are volume and sensor
    /// names the user or the vendor chose, so this is reachable and not theory.
    func testCellsThatCouldSplitARowAreQuoted() throws {
        XCTAssertEqual(HistoryCSVExporter.quoted("CPU die"), "CPU die")
        XCTAssertEqual(HistoryCSVExporter.quoted("Macintosh HD, backup"), "\"Macintosh HD, backup\"")
        XCTAssertEqual(HistoryCSVExporter.quoted("Tim\"s disk"), "\"Tim\"\"s disk\"")
        XCTAssertEqual(HistoryCSVExporter.quoted("two\nlines"), "\"two\nlines\"")
        // A CRLF inside a cell is one Swift grapheme cluster, so neither
        // `contains("\r")` nor `contains("\n")` sees it: the cell that would
        // end the row early is the one the obvious check waves through.
        XCTAssertEqual(HistoryCSVExporter.quoted("two\r\nlines"), "\"two\r\nlines\"")

        // And the header line is where a label reaches the file.
        let lanes = [Self.laneColumns("Volume, \"spare\"", unit: .bytes, [nil])]
        XCTAssertEqual(HistoryCSVExporter().header(for: lanes), """
        timestamp,"Volume, ""spare"" min (B)","Volume, ""spare"" avg (B)","Volume, ""spare"" max (B)",gap
        """)
    }

    /// The file is written in the C locale whatever the app runs in — and the
    /// hazard is not hypothetical: `en_IN`'s decimal separator is already ".",
    /// and it still writes 12,345.50, which is one value in two cells. The
    /// timestamp has the same problem one level down: a fixed `dateFormat` is
    /// not enough, because the locale still picks the calendar and the digits.
    func testTheFileReadsInDotsAndGregorianYearsWhateverTheAppRunsIn() throws {
        let plan = Self.csvPlan(columns: 1)
        let lanes = [Self.laneColumns("Macintosh HD free", unit: .bytes,
                                      [Self.measured(12_345.5, 12_345.5, 12_345.5)])]

        for identifier in ["de_DE", "fr_CA", "ar_SA", "th_TH", "ne_NP", "en_IN"] {
            let exporter = HistoryCSVExporter(locale: Locale(identifier: identifier),
                                              timeZone: TimeZone(secondsFromGMT: 0)!)
            XCTAssertEqual(exporter.row(0, plan: plan, lanes: lanes),
                           "2023-11-14T22:13:20+00:00,12345.50,12345.50,12345.50,", identifier)
        }

        // What those locales do to the same number when they are allowed to
        // reach the formatter, so that the pin above is not folklore.
        XCTAssertEqual(String(format: "%.2f", locale: Locale(identifier: "de_DE"), 12_345.5), "12.345,50")
        XCTAssertEqual(String(format: "%.2f", locale: Locale(identifier: "en_IN"), 12_345.5), "12,345.50")
    }

    /// The whole file: a header line, one row per drawn column in time order,
    /// CRLF line endings and a trailing one.
    func testTheDocumentIsAHeaderLineAndOneRowPerColumn() throws {
        let plan = Self.csvPlan(columns: 3)
        let lanes = [Self.laneColumns("CPU total", unit: .percent,
                                      [Self.measured(0.1, 0.1, 0.1), nil, Self.gap(.asleep)])]
        let exporter = Self.exporter()

        let document = exporter.document(HistoryQueryResult(plan: plan, lanes: lanes))
        XCTAssertTrue(document.hasSuffix("\r\n"))

        let lines = document.components(separatedBy: "\r\n").dropLast()
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines.first, exporter.header(for: lanes))

        // Time-indexed: a row's position is its timestamp, one column width
        // apart, and a column with nothing in it is empty rather than absent.
        XCTAssertEqual(Array(lines)[1], "2023-11-14T22:13:20+00:00,10.00,10.00,10.00,")
        XCTAssertEqual(Array(lines)[2], "2023-11-14T22:13:40+00:00,,,,no_data")
        XCTAssertEqual(Array(lines)[3], "2023-11-14T22:14:00+00:00,,,,asleep")
    }

    /// A value the read path is willing to hand the exporter but no parser
    /// could use: an empty cell, like any other column with nothing in it.
    func testANonFiniteValueExportsAsAnEmptyCell() throws {
        let exporter = Self.exporter()
        XCTAssertEqual(exporter.value(.nan, unit: .watts), "")
        XCTAssertEqual(exporter.value(.infinity, unit: .percent), "")
        XCTAssertEqual(exporter.value(2_000, unit: .rpm), "2000.00")
        XCTAssertEqual(exporter.value(-0.5, unit: .watts), "-0.50")
    }

    // MARK: - daily network traffic (#3450)
    //
    // The counter #3450 asks for is not a lane: it is summed, not averaged,
    // rolls at local midnight computed from the current calendar, and lives in
    // its own append-only file. What these cover is what §5 promises about it —
    // the arithmetic, the two boundary cases a cached `+86400` gets wrong (a
    // DST day and a flight), and the file surviving both a relaunch and a crash
    // in the middle of a write.

    /// The bytes come from the payload's own per-tick delta, and the ticks the
    /// Net conformance drops — an unreachable link, the first sample after an
    /// interface change — never reach it at all.
    func testDailyTrafficAccumulatesAcrossTicks() throws {
        let probe = try self.probe()
        defer { probe.recorder.stop() }

        probe.ingest(10, traffic: HistoryTraffic(upload: 1_000, download: 4_000))
        probe.ingest(20, traffic: HistoryTraffic(upload: 500, download: 1_500))
        // A payload the conformance emitted no traffic for, and the link-rate
        // guard's zero, which at this hook is an idle link.
        probe.ingest(30)
        probe.ingest(40, traffic: .none)

        let totals = probe.recorder.dailyTraffic
        XCTAssertEqual(totals.today, HistoryTraffic(upload: 1_500, download: 5_500))
        XCTAssertEqual(totals.yesterday, .none)
        // Not a lane, and it costs none: the lane count is the one lane the
        // probe registers, and the archive has no column for the counter.
        XCTAssertEqual(probe.recorder.laneCount, 1)
    }

    /// A relaunch at noon continues the morning's figure. The file is inside the
    /// directory the settings readout sums, and it is not a lane.
    func testDailyTrafficSurvivesARelaunch() throws {
        let directory = self.folder.appendingPathComponent("history")
        let first = try self.probe(directory: directory)
        first.ingest(1, traffic: HistoryTraffic(upload: 700, download: 300))
        first.recorder.stop()

        let file = directory.appendingPathComponent(HistoryDailyTraffic.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertGreaterThan(first.store.bytesOnDisk, 0)

        let second = try self.probe(directory: directory, now: first.now + 120)
        defer { second.recorder.stop() }
        XCTAssertEqual(second.recorder.dailyTraffic.today, HistoryTraffic(upload: 700, download: 300))

        second.ingest(2, traffic: HistoryTraffic(upload: 1, download: 2))
        XCTAssertEqual(second.recorder.dailyTraffic.today, HistoryTraffic(upload: 701, download: 302))

        // Deleting the history deletes the counter with it: its file was in the
        // directory that was just emptied.
        XCTAssertTrue(second.recorder.deleteAll())
        XCTAssertEqual(second.recorder.dailyTraffic.today, .none)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// Midnight, in the zone the machine is actually in. A sample that arrives
    /// after it but before the next commit tick belongs to the day that has just
    /// started, which is what `pending` exists for.
    func testDailyTrafficRollsOverAtLocalMidnight() throws {
        let counter = self.dailyCounter(.berlin)
        let evening = HistoryTestCase.instant(.berlin, "2026-05-11 23:59:00")
        counter.load(at: evening)

        counter.add(HistoryTraffic(upload: 100, download: 900), at: evening)
        XCTAssertEqual(counter.totals(at: evening).today, HistoryTraffic(upload: 100, download: 900))

        let night = HistoryTestCase.instant(.berlin, "2026-05-12 00:00:30")
        counter.add(HistoryTraffic(upload: 7, download: 3), at: night)
        let totals = counter.totals(at: night)
        XCTAssertEqual(totals.today, HistoryTraffic(upload: 7, download: 3))
        XCTAssertEqual(totals.yesterday, HistoryTraffic(upload: 100, download: 900))
        XCTAssertEqual(counter.days.map { $0.day }, [20_260_511, 20_260_512])
    }

    /// The day the clocks go forward is 23 hours long and the day they go back
    /// is 25, because the day after local midnight is what the calendar says it
    /// is — not midnight plus 86,400.
    func testDailyTrafficDayLengthFollowsDST() throws {
        // Central European Summer Time starts on 2026-03-29 and ends on
        // 2026-10-25, both at 02:00 local.
        let spring = HistoryTestCase.instant(.berlin, "2026-03-29 00:00:00")
        XCTAssertEqual(HistoryTestCase.instant(.berlin, "2026-03-30 00:00:00") - spring, 23 * 3_600)
        let autumn = HistoryTestCase.instant(.berlin, "2026-10-25 00:00:00")
        XCTAssertEqual(HistoryTestCase.instant(.berlin, "2026-10-26 00:00:00") - autumn, 25 * 3_600)

        let short = self.dailyCounter(.berlin, name: "spring.bin")
        short.load(at: spring + 1_800)
        short.add(HistoryTraffic(upload: 1, download: 2), at: spring + 1_800)
        // 23 hours in, the short day is over and a cached +86400 would still be
        // an hour away from admitting it.
        short.add(HistoryTraffic(upload: 5, download: 6), at: spring + 23 * 3_600)
        let rolled = short.totals(at: spring + 23 * 3_600)
        XCTAssertEqual(rolled.today, HistoryTraffic(upload: 5, download: 6))
        XCTAssertEqual(rolled.yesterday, HistoryTraffic(upload: 1, download: 2))

        let long = self.dailyCounter(.berlin, name: "autumn.bin")
        long.load(at: autumn + 60)
        long.add(HistoryTraffic(upload: 3, download: 4), at: autumn + 60)
        // 24 hours in, the long day is still going, and the two samples are the
        // same day's.
        long.add(HistoryTraffic(upload: 10, download: 20), at: autumn + 24 * 3_600)
        let held = long.totals(at: autumn + 24 * 3_600)
        XCTAssertEqual(held.today, HistoryTraffic(upload: 13, download: 24))
        XCTAssertEqual(held.yesterday, .none)
    }

    /// A flight, not a clock change: the wall clock never moves, the zone does,
    /// and the counter re-anchors on the next roll rather than at the next
    /// midnight of the zone it left.
    func testDailyTrafficReanchorsOnATimeZoneChange() throws {
        var zone: Zone = .berlin
        let counter = HistoryDailyTraffic(url: self.folder.appendingPathComponent("daily.bin"),
                                          calendar: { HistoryTestCase.calendar(zone) })

        // 01:30 on the 11th in Berlin is 19:30 on the 10th in New York.
        let ts = HistoryTestCase.instant(.berlin, "2026-05-11 01:30:00")
        counter.load(at: ts)
        counter.add(HistoryTraffic(upload: 40, download: 60), at: ts)
        XCTAssertEqual(counter.totals(at: ts).today, HistoryTraffic(upload: 40, download: 60))

        zone = .newYork
        let totals = counter.totals(at: ts)
        // The same instant is now a day earlier, and that day has nothing in it.
        XCTAssertEqual(totals.today, .none)
        XCTAssertEqual(totals.yesterday, .none)
        // Nothing was lost: the bytes are still the 11th's.
        XCTAssertEqual(counter.days.map { $0.day }, [20_260_511])

        counter.add(HistoryTraffic(upload: 1, download: 2), at: ts)
        XCTAssertEqual(counter.totals(at: ts).today, HistoryTraffic(upload: 1, download: 2))
        XCTAssertEqual(counter.days.map { $0.day }, [20_260_510, 20_260_511])
    }

    /// The file is append-only and a later record for a day supersedes an
    /// earlier one, which is what a round trip has to come back with.
    func testDailyTrafficRoundTripsThroughItsFile() throws {
        let url = self.folder.appendingPathComponent("daily.bin")
        let first = HistoryTestCase.instant(.utc, "2026-05-10 12:00:00")
        let second = HistoryTestCase.instant(.utc, "2026-05-11 12:00:00")

        let counter = self.dailyCounter(.utc)
        counter.load(at: first)
        counter.add(HistoryTraffic(upload: 10, download: 20), at: first)
        counter.commit(at: first, force: true)
        counter.add(HistoryTraffic(upload: 5, download: 5), at: first + 60)
        counter.commit(at: first + 60, force: true)
        counter.add(HistoryTraffic(upload: 1, download: 2), at: second)
        counter.commit(at: second, force: true)

        // Three records for two days: 16 B of header and 24 B each.
        XCTAssertEqual(try Self.fileSize(at: url), 16 + 3 * 24)

        let reopened = self.dailyCounter(.utc)
        reopened.load(at: second)
        let totals = reopened.totals(at: second)
        XCTAssertEqual(totals.today, HistoryTraffic(upload: 1, download: 2))
        XCTAssertEqual(totals.yesterday, HistoryTraffic(upload: 15, download: 25))
        XCTAssertEqual(reopened.days.map { $0.day }, [20_260_510, 20_260_511])
    }

    /// A `kill -9` in the middle of an append leaves half a record at the tail.
    /// It is dropped, everything before it survives, and the next write rewrites
    /// the file rather than appending onto a misaligned tail.
    func testATornLastDailyRecordIsDropped() throws {
        let url = self.folder.appendingPathComponent("daily.bin")
        let first = HistoryTestCase.instant(.utc, "2026-05-10 12:00:00")
        let second = HistoryTestCase.instant(.utc, "2026-05-11 12:00:00")

        let counter = self.dailyCounter(.utc)
        counter.load(at: first)
        counter.add(HistoryTraffic(upload: 10, download: 20), at: first)
        counter.commit(at: first, force: true)
        counter.add(HistoryTraffic(upload: 1, download: 2), at: second)
        counter.commit(at: second, force: true)

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x20, 0x26, 0x05, 0x12, 0xFF]))
        try handle.close()

        let torn = self.dailyCounter(.utc)
        torn.load(at: second)
        let totals = torn.totals(at: second)
        XCTAssertEqual(totals.today, HistoryTraffic(upload: 1, download: 2))
        XCTAssertEqual(totals.yesterday, HistoryTraffic(upload: 10, download: 20))

        // The next persist compacts rather than appending, so the file is a
        // whole number of records again: one per day.
        torn.add(HistoryTraffic(upload: 4, download: 4), at: second)
        torn.commit(at: second, force: true)
        XCTAssertEqual(try Self.fileSize(at: url), 16 + 2 * 24)

        let reopened = self.dailyCounter(.utc)
        reopened.load(at: second)
        XCTAssertEqual(reopened.totals(at: second).today, HistoryTraffic(upload: 5, download: 6))
        XCTAssertEqual(reopened.days.map { $0.day }, [20_260_510, 20_260_511])
    }

    /// A record whose bytes rotted is not a record: the day falls back to the
    /// last one that still checksums, rather than to a number nothing wrote.
    func testADamagedDailyRecordFallsBackToTheLastGoodOne() throws {
        let url = self.folder.appendingPathComponent("daily.bin")
        let day = HistoryTestCase.instant(.utc, "2026-05-10 12:00:00")

        let counter = self.dailyCounter(.utc)
        counter.load(at: day)
        counter.add(HistoryTraffic(upload: 10, download: 20), at: day)
        counter.commit(at: day, force: true)
        counter.add(HistoryTraffic(upload: 5, download: 5), at: day + 60)
        counter.commit(at: day + 60, force: true)

        // A bit inside the second record's upload field. The header is 16 B and
        // records are 24 B, so the second one starts at 40.
        try Self.flipBit(at: url, byte: 40 + 4, bit: 2)

        let reopened = self.dailyCounter(.utc)
        reopened.load(at: day)
        XCTAssertEqual(reopened.totals(at: day).today, HistoryTraffic(upload: 10, download: 20))
    }
}
