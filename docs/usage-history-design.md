# Persistent usage history

Design for exelban/stats#1194, with #3401 (battery trend) and #3450 (network over time). Fork-only (kk1987/stats); upstream takes no contributions, so this ships as an atomic patch stack rebased onto each upstream tag.

Status: approved 2026-09-12 (owner decisions folded in). Target: fork releases 3.0.15.2 (storage + recorder + settings + battery chart) and 3.0.15.3 (window, presets, export).

## 1. Goals and non-goals

Answer "what was this machine doing at 03:10 last Tuesday, when did it start, how long did it last" across sleep, quit, reboot and app updates, for up to a year. Preserve peaks — iStat Menus averages and admits "it is common for peaks to drop"; the 2026 GPU comment on #1194 is a question about a peak. A disk footprint with a hard, pre-declared ceiling that the user can read off a settings row at any time. Never harm the live app: a full disk, `kill -9`, a panic, a clock step, a second Stats instance or a garbage file degrades history and nothing else. Survive `git rebase --onto vNEW vOLD`.

**v1 lanes.** A *lane* is one recorded scalar series. The v1 set is:

| Module | Lanes | Cardinality |
|---|---|---|
| CPU | `total`, `system`, `user` | 3, fixed |
| RAM | `usage`, `pressure`, `swap` | 3, fixed |
| GPU | `<id>.utilization`, `<id>.temperature` for *every* GPU, not just `selectedGPU` | 2 per GPU |
| Net | `<iface>.up`, `<iface>.down` | 2 per interface ever seen |
| Disk | `<uuid>.read`, `<uuid>.write`, `<uuid>.free` | 3 per volume ever seen |
| Battery | `level`, `power` | 2, fixed |
| Sensors | every fan, plus a curated list (CPU die, GPU die, battery, ambient) | ~5 on an Apple Silicon laptop |

Plus a **daily network byte counter** (§5), which is *not* a tiered lane — it is a small separate append-only file and is excluded from every lane count and size figure below.

**Lane count is not constant, and the design says so everywhere.** A fresh install on a typical Apple Silicon laptop registers **20–22 lanes**. Lanes then *accrue*: every Wi-Fi → Ethernet → utun → `awdl0` → `bridge0` switch and every USB volume or disk image mounted adds lanes that are kept (LRU-reclaimed, §3, not deleted on unmount — the whole point is that yesterday's data survives today's unplug). A month-old install is realistically **25–45 lanes**. Every size, write-volume and read-cost number in this document is quoted at three points: first launch (~21), a month in (45), and the sensors-heavy worst case (116). The settings row shows **live lane count next to live bytes**, so the user never has to trust a number from a design doc.

**Sensors: curated default, not "what's pinned."** `sensor_<key>_popup` defaults to **true** for every discovered Sensor and Fan (`Modules/Sensors/values.swift:234`, `:295`, verified), so "record what the user pinned" silently enables 50–150 lanes and multiplies the footprint ~5×. v1 records fans plus the short curated list above; everything else is a checkbox in the history window's own sidebar, with no new UI in `Modules/Sensors/settings.swift`.

**Non-goals for v1.** Per-core CPU. CPU frequency/temperature/average-load and every `ProcessReader` — all `popup: true`/`preview: true`, so no continuous source; un-gating costs idle power and is its own patch with a measured number. Process attribution in tooltips (#1207). Bluetooth, Clock, Remote. Widgets access (sandboxed; not worth a second copy). Drag-to-zoom, per-day bars, multi-series normalized overlay (two lines at one pixel height meaning 40 °C and 9 GB misleads). Connectivity shading on the traffic chart (victor-marino) — deferred, named so it is not silently dropped.

**CSV export is in v1.** ~150 LOC on the read path the chart needs anyway; it answers #1125/#1899/#1952/#2048/#3255 and artstorm's Grafana ask on #630, and it is the only thing that makes a bespoke binary format defensible. Ships with the window, format documented in the same release.

## 2. Sampling

**Hook — one line at `Kit/module/reader.swift:118`**, next to `SystemStats.shared.send`: `HistoryRecorder.shared.ingest(value, reader: moduleKey)`. `moduleKey` is already computed on line 114, and the whole block is already inside `if let value`.

**Reader identity is passed, not inferred from payload type.** `CapacityReader`, `ActivityReader` and `SMARTReader` are all `Reader<Disks>` (`Modules/Disk/readers.swift:48/173/480`) with independent, partially-filled instances. Type dispatch would write a fake `0 B/s` on every capacity tick and `free = 0` on every 1 s activity tick. Each lane binds to exactly one reader key.

**Extraction is typed, not reflective.** `HistoryProvider` is a Kit protocol: `func emitHistory(reader: HistoryReaderKey, into sink: inout HistorySink)`. Mirror is rejected on three counts: `RAM_Usage.usage` and `drive.percentage` are computed properties it cannot see; `GPUs._list`, `Disks._array` and `Sensors_List.list` are private and queue-guarded (a barrier write from the Sensors HID callback on main against a walk on the Repeater queue is a race, not a sample); and a measured 435–542 µs/tick for Sensors is ~10× any sane budget. A typed protocol also fails to **compile** on an upstream rename — for a one-person fork that beats a string path dying silently and getting pruned a year later.

**Conformances live in the module targets — because Kit cannot import them.** Kit imports only system frameworks (verified: `Cocoa`, `Foundation`, `IOKit.pwr_mgt`, `Metal`, `ServiceManagement`, `SystemConfiguration`, …, and no module target); the dependency runs modules → Kit, never the reverse. So a conformance for `CPU_Load`, `Disks` or `Sensors_List` *must* live in the module target that defines the type, whatever the access level. (Access level reinforces it for most payloads — `Battery_Usage` is an internal struct, `CPU_Load.systemLoad/.userLoad`, every stored `RAM_Usage` field, `Network_Usage.bandwidth/.total` and `drive.uuid/.size/.free/.activity` are all internal, verified. `GPU_Info` is the exception: fully public, `public let id`, `public let model`. The import direction is what actually decides it.) Each module gets **one new file**, `Modules/<X>/History.swift` — still zero edits to any existing `Modules/*` source. No upstream property is made public.

**Ingest allocates nothing on the scalar path.** `guard isRecording` is the first statement, before the cast, so the master switch off costs a predicated branch — including for readers that emit nothing (Clock's `Reader<Date>`, every `ProcessReader`). Lanes resolve to **integer ids at registration**; the sink is a pre-sized buffer. No `String` interpolation, no array allocation, no dictionary hashing on the hot path. That is what makes the hook safe on Battery's `IOPSNotification` callback, which runs on the **main run loop** (`Modules/Battery/readers.swift:30-57`), and on Bluetooth's main-queue delegate. Ingest takes a heap-allocated `os_unfair_lock` (macOS 12 rules out `OSAllocatedUnfairLock`) and folds. The commit thread snapshots and resets accumulators **under** the lock, then writes with it **released**.

**Container payloads cost more than a scalar, and the budget says so.** `Sensors_List.sensors`, `Disks.array` and `GPUs.list` are all `queue.sync { self._backing }` returning a **copy** of the whole array (`Modules/Sensors/values.swift:57-60`, `Modules/Disk/main.swift:96-99`, `Modules/GPU/main.swift:71-74`); `Disks.first(where:)` (`:121`) is another cross-queue `sync` per call. `emitHistory` therefore **materializes the array exactly once per tick** into a local `let` and iterates it in place — never one accessor call per lane, and never `Sensors_List.update`, which takes a *barrier* sync and would be strictly worse. The realistic budget is **< 1 µs for scalar payloads (CPU, RAM, Battery, Net), < 50 µs for the container payloads (Sensors, Disk, GPU)**, dominated by the one array copy; §7 carries a benchmark for it rather than an assertion.

**Cadence and attribution.** Buckets are wall-clock aligned (`floor(epoch / step)`), so readers at 1 s and 60 s share a grid and a runtime `setInterval` is a non-event. A sample is attributed to **every bucket overlapping `[now − interval, now]`** using the reader's own `interval` (in scope at the hook as `Double?`), so a 60 s CPU interval fills six 10 s buckets instead of leaving five as gaps. No EWMA — it is wrong precisely at the transients (interface switch, reconnect, wake) users open the window for.

**Step lanes and the bounded hold.** Interval-span attribution assumes the reader ticks on its interval. Battery's `UsageReader` does not: it is an `IOPSNotificationCreateRunLoopSource` with no `Repeater` (verified, `Modules/Battery/readers.swift:29-56`), yet `Module.mount()` calls `initStoreValues` on every reader unconditionally (`Kit/module/module.swift:177-184`), which sets `interval = Double(Store.int("Battery_updateInterval", defaultValue: defaultInterval))` = **1 s** (`Kit/module/reader.swift:107-111`). Span attribution would therefore fill exactly *one* 10 s bucket per IOPS event and leave the other minutes as no-data.

So each lane declares a `kind`: **rate**, **gauge**, or **step**. A *step* lane (battery `level`; nothing else in v1) carries `lastValue` and `holdUntil = lastSampleTs + 15 min` in its accumulator. At bucket close, if the bucket has `count == 0` and its start is before `holdUntil`, it is written as `count = 1, min = max = sum = lastValue, reason = HELD`. **No slot-layout change is needed** — `reason:u8` already exists in the 20 B slot and `HELD` is one more enum case, not a format bump. The 15-minute cap is bounded by physics and by the event source: IOPS fires on every 1 % change, on plug/unplug and on sleep/wake, so a genuine 15-minute silence means the level genuinely did not move. The chart draws `HELD` spans dashed and the CSV marks them, so a held value is never presented as a measured one. `battery.power` is a **rate** and therefore gaps honestly; it is not held.

**Rates.** Net `bandwidth` and Disk `activity` are per-tick byte deltas. The recorder divides by the **actual elapsed time since that lane's previous sample** (bounded by `interval`), requires `dt > 0`, and rejects non-finite values *before* folding — NaN must never reach min/max, where every comparison against it silently fails. Stored rates are bytes/second.

**Net's substituted zeros: two of three are recoverable, and the third is documented, not faked.** `Modules/Net/readers.swift` hands `callback` a payload in which several distinct conditions all look like `bandwidth == 0`:

1. **Unreachable** (`:221-228`) — `usage.reset()` nils `interface`, so the recorder detects it from the payload and records **no-data**.
2. **Interface change** (`:264-267`) — `usage.bandwidth` is reset and the first post-switch read yields 0. Detectable by diffing `usage.interface?.BSDName` across samples; records **no-data**.
3. **The over-link-rate guard** (`:299-300`) — `usage.bandwidth.upload/download` are set to `0` *before* `callback` at `:312`, and the raw delta is discarded: `usage.total` is incremented at `:302-303` **after** the clamp, so the bytes are unrecoverable from `total` too. At the hook this payload is **byte-identical to a genuinely idle link**, and there is no way to tell them apart without a new field in `Network_Usage` (`Modules/Net/main.swift:75-109`) or a line in `readers.swift` — both of which §9's zero-edit invariant for `Modules/*/main.swift` and `Modules/*/readers.swift` forbids, in the fork's highest-churn module.

   **Decision: accept it as an unmarked zero.** The damage is bounded: the guard fires on one-shot counter jumps (reconnect), Net's default interval is 1 s, so one clamped sample lands in a 10 s bucket alongside nine good ones — it pins that bucket's `min` to 0 and pulls `sum` down by one sample. It does not create a visible trough at any tier, because T1/T2 roll up from T0 and a single zeroed sample in a 12-sample T1 bucket moves nothing but the min. The escape hatch, if a user ever reports a false zero trough: add `var bandwidthClamped: Bool = false` to `Network_Usage` and set it next to the guard — two lines, two upstream files, listed here so the trade is a decision and not an oversight.

The VPN `/= 2` (`:308-310`) happens upstream of `callback` and is baked in: documented, not corrected.

**Disabled modules and pause.** `Module.disable()` stops the readers; history stops with them — polling hardware the user turned off contradicts the efficiency promise and #3292. But `disable()` is called by both the per-module toggle and the global pause path and posts nothing, making it indistinguishable from a failed reader. The gap taxonomy is therefore collapsed to what is derivable: **`NODATA`, `ASLEEP`, `NOT_RUNNING`, `CLOCK_STEP`**, plus **`HELD`** for step lanes. `GAP_DISABLED` is dropped rather than faked.

## 3. Storage

**Decision: a pre-allocated, row-major, bucket-stamped round-robin archive, committed with `pwrite`, read through a read-only `mmap`.** Not LevelDB — measured, 16 live keys / 92 KB generate ~4.2 MiB of L0 tables every 30–50 min (that is #3292), and an LSM's size is a function of write volume and compaction timing, exactly the property a background feature must not have. Not SQLite — VACUUM, unbounded growth, a second engine.

**Location.** `~/Library/Application Support/Stats/history/`, with `NSURLIsExcludedFromBackupKey` set — continuously rewritten, disposable blocks must not reach Time Machine or be pinned by hourly APFS snapshots. **No `$TMPDIR` fallback** (unlike `DB.swift:33-64`): writing a year of history where macOS purges it is worse than not writing it.

**Layout — row-major, one file per tier.** This is the decision all three candidate designs got wrong. A slab-per-lane layout dirties one page *per lane* per flush; at 21 lanes that is ~8 MiB/hour, no better than the churn it claims to beat. Row-major puts all lanes for one bucket contiguous:

```
header    4 KiB   magic "STHS" | formatVersion | step | buckets | lanes
                  | lastCommitBucket | monotonicAnchor | createdTs | crc32(header)
directory lanes × 128 B
          seriesId     16 B   SHA-256 prefix, the stable identity
          module        1 B   enum: cpu|ram|gpu|net|disk|battery|sensors
          unit          1 B   enum: percent|bytesPerSec|bytes|celsius|watts|volts|rpm
          kind          1 B   enum: rate|gauge|step
          flags         1 B   orphan, reclaimed, …
          firstValidBucket 4 B
          lastUsedTs    8 B
          labelLen      1 B
          label        88 B   UTF-8, truncated on a scalar boundary
          reserved      7 B
matrix    buckets × lanes × 20 B
slot 20 B  bucket:u32 | count:u16 | reason:u8 | pad:u8 | min:f32 | max:f32 | sum:f32
```

Index is `(bucketIndex % buckets) * lanes + lane`. **Every slot stores its own bucket index**, so a stale slot from a previous wrap or a torn write is detectable at read with no header bookkeeping — the "torn write lands beyond `lastCommitBucket`" argument is false in a modular ring (every slot is congruent to some in-window index), and the stamp is what replaces it. Per-lane `firstValidBucket` means a fresh archive reads as no-data rather than a year of flat zeros, without pre-writing NaN.

**The directory carries a name, not just a hash.** A 16 B hash prefix cannot render "Macintosh HD — free" in a sidebar, cannot group by module, and cannot say what an orphan lane *was*. The entry is therefore 128 B, not 64: `module` drives the sidebar grouping and the filter field, and `label` holds the human string ("Wi-Fi (en0)", "Macintosh HD", "CPU die", the GPU model). A sidecar `directory.json` was considered and rejected — it would need its own crash-safety story and could drift from the archive it describes; 256 lanes × 128 B = 32 KiB per tier file is not worth a second consistency problem. The directory is written identically into all three tier files whenever a lane is added (a rare event), which keeps each file self-describing; if a crash between those three writes leaves them disagreeing at open, **T0's copy wins** and the others are rewritten from it — a lane present in T0 but absent in T2 simply has no T2 data yet, which `firstValidBucket` already expresses. §8 inventories `label` as stored identifying text.

**`sum` + `count`, not `avg`.** Bucket population is not constant — intervals are user-settable 1–60 s and change at runtime, sleep and toggles leave partial buckets, read-side resampling is fractional. Unweighted avg-of-avgs would disagree with the live chart and Activity Monitor exactly around wake and interval changes, and would over-count #3450's daily totals by up to 6×. It is a slot-layout decision, so deferring it costs every user their history; it is made now. `f32` sum carries ~6e-8 relative error — irrelevant.

**Tiers and size.** Per-lane cost is `Σ(buckets) × 20 B`.

| Preset | T0 | T1 | T2 | Slots | Per lane |
|---|---|---|---|---|---|
| Minimal | 10 s / 24 h (8,640) | — | — | 8,640 | 168.75 KiB (0.173 MB) |
| **Standard** (default) | 10 s / 24 h (8,640) | 2 min / 30 d (21,600) | 30 min / 365 d (17,520) | 47,760 | 932.81 KiB (0.955 MB) |

**Two presets, and one of them is the answer.** Standard is the design: a year of history at a resolution that is 10 s for the last day, 2 min for the last month and 30 min beyond that. Minimal exists for the user who wants the live window and nothing retained, not as a different retention policy to reason about. Every number below is quoted for both.

**Sizes at the three reference lane counts (MB, what Finder shows):**

| Preset | ~21 lanes (first launch) | 45 lanes (a month in) | 116 lanes (sensors-heavy) | Ceiling at the lane cap |
|---|---|---|---|---|
| Minimal | 3.6 | 7.8 | 20.0 | 44.2 (256 lanes) |
| **Standard** | **20.1** | **43.0** | 110.8 | **244.5 (256 lanes)** |

Day 1 = day 365 at a given lane count; the only thing that grows is the lane count, and it is capped.

**The lane cap is 256, and the budget is what says so.** `laneCap = min(256, floor(256 MiB / bytesPerLane))` — Standard's 0.955 MB/lane would allow 281 and Minimal's 0.173 MB/lane 1,553, so the 256-lane structural cap binds first and **both presets get 256**. The worst case any user can reach is therefore Standard at the cap: **244.5 MB**, under the budget with room to spare. At the cap the recorder stops *adding* lanes (existing ones keep recording) and the settings row says so; LRU reclaim (below) frees slots as identities go cold.

**The 256 MiB budget is an on-disk budget**: it bounds the archive files in `history/`, not the process's footprint — the write path is `pwrite`, so nothing is held dirty in memory, and the query path maps the tier files read-only, so those are clean file-backed pages the kernel may evict at any time. Resident memory is budgeted separately in §7 (< 1 MiB idle, +< 300 KiB with the window open).

Read-side column counts are integer multiples of the tier step (360 at 10 s for 1 h, 720 at 30 s for 6 h, 720 at 2 min for 24 h, 504 at 20 min for 7 d, 1,440 at 30 min for 30 d, 1,460 at 6 h for 1 y), capped by chart width, so the min/max envelope does not stutter at exactly the ranges users stare at. The 1 y figure is what the integer-multiple rule costs at that range: 17,520 T2 buckets divide by 12 and not by 12.17, so the year is 1,460 six-hour columns rather than 1,440 of uneven width.

**Write cadence.** One `DispatchSourceTimer` for the whole feature: **60 s**, 5 s leeway, `.utility`, private serial queue `eu.exelban.history`, **suspended when no accumulator is dirty**. Each tick closes completed T0 buckets and `pwrite`s the changed row range; T1/T2 rows are written only when their buckets close and are **always rolled up from T0** (min of mins, max of maxes, sums, counts), never accumulated in memory. `fsync` on sleep, on `applicationWillTerminate`, and every 10 min — stretched to 30 min on battery, in Low Power Mode, or at `thermalState >= .serious` (both APIs exist at the macOS 12 target and appear nowhere in the codebase today). 60 s rather than 30 s halves the write volume at the cost of losing at most 60 s of unflushed accumulator on `kill -9`; for a background feature that is the right side of the trade.

**Write volume, derived.** The number is floored by the filesystem block, not by the row size. At 60 s cadence there are **60 commits/hour**; each commit writes 6 closed T0 rows (60 s ÷ 10 s), and APFS allocates in **4 KiB blocks** under copy-on-write, so every commit dirties at least one block regardless of how few bytes changed:

| Lanes | T0 row | 6 rows | Blocks/commit | T0/hour | T1 closes (30/h) + T2 (2/h) | **Total** |
|---|---|---|---|---|---|---|
| 21 | 420 B | 2.5 KiB | 1 (4 KiB) | 240 KiB | 128 KiB | **~0.36 MiB/h ≈ 8.5 MiB/day** |
| 45 | 900 B | 5.3 KiB | 2 (8 KiB) | 480 KiB | 128 KiB | **~0.6 MiB/h ≈ 14 MiB/day** |
| 116 | 2,320 B | 13.6 KiB | 4 (16 KiB) | 960 KiB | 128 KiB | **~1.1 MiB/h ≈ 26 MiB/day** |

**The span sidecar is in that budget too, and it is not free.** `spans.bin` (§4) is rewritten whole, atomically, on every change — one change per sleep, one per wake, one per launch, one per clock step. At 24 B a record, age-capped to T2's 365 days and not line-capped, a laptop that sleeps twenty times a day accumulates ~8,000 records ≈ 190 KiB, and rewriting that on ~40 changes a day costs **~4–8 MiB/day at the tail of the year**, most of it on the last day and close to nothing on the first. That is the same order as the whole T0 write volume above, for a file that exists to answer one question per gap. It is accepted rather than optimized: an append-only sidecar would need its own compaction and its own torn-record story, and the alternative — capping by line count — is the thing §4 refuses, because last month's nine-hour sleep must not be evicted by this month's naps. The number is stated here so it is a decision and not a surprise in a write-volume audit.

(The page-density figure — a 16 KiB page holds 39 T0 rows at 21 lanes, i.e. 390 s of data — describes how *little* is logically written; the block floor is what actually reaches the SSD, and it is the honest number.) The existing LevelDB churn (~6 MiB/hour, dominated by `Sensors@SensorsReader`) is **unchanged** — this store is additive and total process write volume goes up. That goes in the release notes; #3292 is not fixed here.

**Read cost, and why row-major still pays.** Row-major is chosen for write amplification, but it has a real read cost: drawing one lane strides across every row. The bound depends entirely on the range, because only the requested bucket range is touched:

| View | Tier | Rows read | Bytes at 45 lanes | at 116 lanes |
|---|---|---|---|---|
| 1 h | T0 | 360 | 324 KiB | 835 KiB |
| 24 h | T1 | 720 | 648 KiB | 1.7 MB |
| 30 d | T2 | 1,440 | 1.3 MB | 3.3 MB |
| **1 y** | T2 | **17,520 (the whole file)** | **15.8 MB** | **40.6 MB** |

Only the 1-year view reads a whole tier file. Through a read-only `mmap` with sequential page touch that is **~6 ms warm / ~20 ms cold at 45 lanes, ~15 ms / ~40 ms at 116** — inside the 50 ms first-paint budget, and it happens once per range change on the history queue, not per frame. And this is exactly where row-major pays off: that single pass produces the downsampled columns for **every visible lane at once**, plus the min/avg/max table, rather than one strided pass per lane. A column-major layout would read less for one lane and more for the eight the window actually draws, while dirtying 45 pages per commit instead of two.

**Why `pwrite`, not an mmap store.** `F_PREALLOCATE` does not guarantee in-place overwrite on copy-on-write APFS (snapshot-pinned blocks), so a failed writeback through a writable mapping surfaces as `SIGBUS` — uncatchable in Swift, violating goal 3. A few KiB every 60 s costs nothing and returns `errno`; `mmap` stays read-only for queries.

**ENOSPC is mitigated, not eliminated.** Space is claimed once per tier with `F_PREALLOCATE(F_ALLOCATEALL)` + `ftruncate`, which reserves the extent — but the same copy-on-write behaviour that breaks in-place overwrite means an overwrite can still need a fresh block, so **`pwrite` can return `ENOSPC` (or `EDQUOT`) at any time**. Claiming preallocation makes steady-state writes "near-immune" while also arguing CoW breaks in-place overwrite is incoherent; it is dropped. The actual mitigations are two:

- **A free-space precondition.** `volumeAvailableCapacityForImportantUsage` is read every tenth commit (~10 min) and after any failure. Below **50 MB free** the commit is skipped, recording is marked paused and settings shows "History paused — low disk space". The store degrades before the volume does.
- **Three strikes.** Three consecutive write failures suspend recording for an hour, surface the same banner, and retry on the next cycle rather than waiting for relaunch.

**Corruption.** Bad magic, bad header CRC or unknown `formatVersion` → rename to `t0.rrd.corrupt-<ts>` (one kept) and recreate empty. Inside a valid file a garbage slot is bounded by its stamp and reads as no-data; every read is bounds-checked and a truncated file reads short rather than trapping. Lane identity and geometry are CRC'd once, while the mutable cursor is self-validating from slot stamps, so a torn header write cannot discard a year. **CRC-32 is ~25 lines of Swift in the archive file** (lazily built 256-entry table) — there is no zlib import anywhere in the project and Kit's umbrella header (`Kit/Supporting Files/Kit.h`) carries only `lldb.h`; adding `#include <zlib.h>` there would be an unlisted upstream edit to buy an algorithm that fits on one screen.

**Cross-process exclusion.** `flock(LOCK_EX|LOCK_NB)` on `history/.lock` at startup; the loser records nothing, logs once, **and shows "History is being recorded by another copy of Stats" in the settings section** — this fork routinely runs a locally signed build beside the released one, so two writers is normal here and a log line nobody reads is not an answer.

**Crash and restart continuity — coarse tiers catch up at open.** Because T1/T2 are computed from T0 at close rather than accumulated in memory, a bucket that straddles a relaunch is still correct when it closes: the closing rollup reads the whole T1 span out of T0, including the part written before the quit. What remains is buckets that closed *while the app was down*. Stats quits on every update and every reboot, so without a fix the 30-day and 1-year views — the entire point of #1194 — would develop a hole at every restart.

**On open, for each coarse tier, every bucket newer than that tier's `lastCommitBucket` and older than the current one is rolled up from T0 and written.** T0 retains 24 h, so any downtime shorter than that is fully recoverable; the work is bounded by one pass over ≤8,640 T0 rows producing ≤720 T1 and ≤48 T2 rows — single-digit milliseconds, on the history queue, before the first live commit. Downtime longer than 24 h leaves the unrecoverable span as honest no-data. Unit-tested, and on the manual matrix ("quit mid-bucket, relaunch, 30-day view has no hole").

**Versioning.** No in-place migrations, ever: a `formatVersion` bump renames archives to `.old` (deleted after 7 days) and starts fresh. **Adding a lane never bumps the version** — a lane is a directory entry, and lane growth is a copy-forward rebuild (slots carry their bucket index, so copy-forward is trivial), so per-core CPU, more sensors and per-volume Disk land later as purely additive patches.

**Preset changes.** With two presets there is exactly one transition each way. *Growing* Minimal → Standard copies T0 verbatim and then runs the same catch-up rollup over the retained 24 h to populate T1 and T2 — so the new tiers start with **24 h of data and nothing before that**, which the chart shows as no-data rather than as zeros. *Shrinking* Standard → Minimal discards T1 and T2, behind a Delete-weight confirmation that names what goes.

**Lane lifecycle.** Lane cap as derived above, reclaimed by **LRU on `lastUsedTs`**, not a 365-day TTL — `utun*`, `awdl0`, `bridge0`, disk images and replugged volumes churn identities fast enough to exhaust a TTL-only directory. Identity keys are the most stable available: volume **UUID** (not `BSDName`), SMC **key** (not label), `GPU_Info.id` (not `model`, which collides on dual identical GPUs; `GPUs` has no `name` field). An **orphan** lane — one whose source has not been seen this launch — shows greyed in the sidebar with its stored `label` and a last-seen date from `lastUsedTs`, which is what the 128 B directory entry is for. The `reclaimed` flag is deliberately *not* a reason to grey: it marks the id that was handed to a *new* identity, so the lane wearing it is the one actively recording, and greying it would grey the newest lane on the machine. **Disk lane labels store the volume name exactly as macOS reports it** ("Macintosh HD", "Tim's backup drive") — not anonymized, not shortened to the UUID that is the actual identity: a lane whose drive was unplugged last month has to stay recognisable in that sidebar, and a 16 B hash is not. §8 inventories it as stored identifying text.

**Updates and rebase.** `updater.sh` replaces only the bundle, so `history/` survives; `uninstall.sh:37` already removes the parent. The archive is entirely new files, so a rebase cannot touch the format.

## 4. Time handling

Buckets are indexed by **wall clock** (UTC epoch seconds) — the point is answering "at 03:10 yesterday". Time zones and DST are rendering concerns; every real UTC offset is a multiple of 15 min, so the 2-min and 30-min tiers stay aligned to local wall clock (Nepal's +5:45 puts local midnight mid-bucket at T2; accepted).

`mach_continuous_time()` is read alongside the wall clock **at ingest, inside the bucket-index computation** — not once per commit, which would let accumulators land in the wrong bucket for up to a full period. Divergence over 2 s means the clock stepped. A forward step needs no action: the ring advances and skipped slots read as no-data by their stamps. A **backward** step never overwrites a slot whose stamp belongs to the pre-step era; a step larger than a tier's window **resets** that tier rather than interleaving two eras.

**What that costs, said out loud: a backward step stops recording — on every tier — for its own length.** The re-lived buckets are precisely the ones the pre-step era stamped, so every row a commit produces while the wall clock is walking back over them is dropped, T0 included, until the clock passes the high-water mark again. A clock set back an hour is an hour of no-data with "Clock changed" as the reason, not an hour of data written twice. The alternative is two eras interleaved in one ring with nothing in a slot saying which era it belongs to, which is worse than a labelled gap — and the case is rare enough (a DST transition does not move the UTC clock at all; this is someone setting the clock, or NTP correcting a badly-drifted one) that a more elaborate answer would be paying for something nobody sees.

**Gaps are derived at read, never backfilled at write.** With stamped slots, "Stats was not running" and "asleep for nine hours" follow from `lastCommitBucket`, `firstValidBucket` and the `NSWorkspace.willSleep/didWake` spans the recorder keeps in a small sidecar (age-capped to T2 retention, not line-capped; §3 carries its write cost). **A process closes only the sleep it opened itself**: a span left open on disk is one the previous process never saw the end of — powered off, battery flat or force-rebooted while asleep — and it is dropped at load rather than restored, because a later wake closing it would produce an "Asleep" spanning days the machine was demonstrably awake. Next to nothing is lost: the launch's own span already covers the whole stretch — `NOT_RUNNING`, or `CLOCK_STEP` when the two clocks disagree across the downtime, which is the better answer of the two anyway. The exceptions are an install that never committed, where there is no last commit to date a span from, and a hole shorter than two T0 buckets, which no column can show. There is no app-wide sleep/wake observer today — the only ones live in `Modules/Sensors` and `Modules/Bluetooth` (verified) — so the recorder registers its own, in its own new file. Backfilling at launch would dirty multiple MiB in one burst at the worst moment for battery; a gap at or beyond a tier's capacity resets the tier instead of iterating a full ring.

Gaps are **not interpolated across**: a 45° hatch in `separatorColor`, and the hover readout says it in words — "Asleep 02:14–08:31", "Stats not running", "Clock changed". `HELD` spans (§2) are drawn dashed with "Last known level" in the readout. That sentence is what turns a hole into an answer to "when did it start, how long did it last".

## 5. UI

**Entry points.** Primary: an **expand button on the existing "Usage history" separator**. Net and Disk already use `SeparatorView(label:button:)` + `PopupButton` for other sections (`Modules/Net/popup.swift:256`), but the *usage-history* separators in CPU, RAM, GPU and Net all come from the free function `separatorView(_:origin:width:rightInset:)` in `Kit/helpers.swift:402`, and those call sites are not interchangeable: CPU's `initChart()` is an `NSStackView` using `addArrangedSubview` (`popup.swift:231-256`), while RAM's (`:185-201`) and GPU's (`:103-118`) are frame-positioned `NSView`s that `addSubview(separator)` at an explicit origin. `SeparatorView` is an `NSStackView` with `translatesAutoresizingMaskIntoConstraints = false` and no width constraint, so dropping it into RAM's or GPU's frame-based layout lays it out at **zero width**.

So instead of restructuring two module popups into stack views (~20 lines each, in files upstream actively edits), **the free function gains a `button: NSView? = nil` parameter** — `rightInset` already carves out exactly the space it needs (`Kit/helpers.swift:445`, `rightLine.trailingAnchor …, constant: -rightInset`), so the button is `addSubview`d, pinned to `view.trailingAnchor`, and `rightLine` pins to its leading edge. That is ~10 lines in one stable function, and each popup call site then takes **one added argument**, not a structural swap. A new optional parameter with a default is about the most rebase-friendly upstream edit available; both costs are listed in §9.

Secondary: a "History" row in the Settings sidebar. **No popup-header button**: `HeaderView` pins the title width as `frame.width − activity.intrinsicContentSize.width − settings.intrinsicContentSize.width` (`Kit/module/popup.swift:423-427`), so a third button edits that constraint rather than appending, conditional visibility makes title centering differ per module, and it would appear in all ten modules while working in six. The shortcut is **⌃⌥H** (⌥⌘H is Hide Others), needing a new branch in `Stats/helpers.swift:361-380` — listed in §9, not hidden.

**Window.** `HistoryWindow` in Kit (the only place every module target reaches), resizable, min 760×460, frame in `Store`, opened with `NSApp.activate(ignoringOtherApps: true)` — the app is `LSUIElement` and every other window path does this. Left sidebar of lane checkboxes **grouped by the directory's `module` byte and labelled from its `label` field**, with a filter field and a default selection (the originating module's primary lanes only — required once 100+ lanes exist). Top bar: range control (1 h / 6 h / 24 h / 7 d / 30 d / 1 y), min/max band toggle, now/pinned toggle, **Export CSV**. Then the chart, a time axis, and a right-hand table of each visible lane's min/avg/max that switches to the value under the crosshair.

**Chart.** A new `HistoryChartView` subclassing the existing `ChartView` base (inheriting the concurrent state queue, `displayIfVisible()`, `write{}`/`onMain{}`) and reusing Kit-internal `scaleValue`. `LineChartView` is deliberately not reused: index-based with uniform x spacing, an O(n) scan-and-sort in `intervalStatsLocked()` on **every** append, 600 points max, a hardcoded `0/25/50/75/100` percent ladder against a per-draw rolling max, and a hardcoded `HH:mm:ss` axis with no setter — six of the v1 lanes are not 0…1, and a 30-day view whose five x labels all read "14:32:05" answers nothing. `HistoryChartView` is **time-indexed**: range → pixel columns, coarsest tier finer than one column, a min/max band at 25% alpha under a solid avg line, **y axis in real units per lane** (bytes/s, °C, W, %) and **x axis with dates** on 7 d / 30 d / 1 y.

**Interaction and cost.** Crosshair on hover; ←/→ one column, ⇧←/→ ten, `1`–`6` ranges, Home/End, Esc, Tab into the sidebar. Lane geometry is cached in a layer rebuilt only on range or selection change, and the crosshair draws in an overlay so scrubbing does not redraw every lane per mouse event. Tracking areas **drop `.activeAlways`**; the live-refresh timer is gated on `NSWindow.occlusionState` (the precedent is `Kit/module/module.swift:309`), since `isVisible` is false only for miniaturized or ordered-out windows and a window behind Xcode would otherwise poll forever. A range switch or teardown clears `LineChartView`-style `mouseDown` freeze state.

**Battery gets a popup line chart.** `Modules/Battery/popup.swift` has only a `BarChartView`. A ~45-line `LineChartView` fed from `battery.level` is the highest value-per-line item in the feature and the only thing that makes a #3401 user see any change in the surface the issue names.

**#3450 gets a real surface.** The Network section shows today's and yesterday's upload/download totals from an **independent monotonic per-day byte accumulator written at ingest** — not integrated from averaged buckets, and not `Network_Usage.total` (which the user's own reset schedule zeroes). Days roll at **local midnight**, recomputed from the current calendar on every commit tick rather than from a cached `+86400`, so a DST boundary produces a 23- or 25-hour day rather than a shifted one and a timezone change re-anchors immediately. Labelled as excluding sleep, app-off time and guard-dropped samples, so it reads slightly below both the ISP figure and the Net popup's own counter two inches away.

**Popup restore is deferred, not faked.** `setPoints` is `public func setPoints(_ newPoints: [DoubleValue])` (`Kit/plugins/Charts.swift:671`) — non-optional, so it cannot express a gap; and the first live `addValue` derives `typical` from the restored 10 s spacing and nils out up to `n−1` slots, erasing the restore within one tick. If it ships it ships as a `setPoints([DoubleValue?])` overload (one additive `Charts.swift` line, listed in §9), a freshness guard (`now − lastBucket < 2 × step`), and resampling to the live cadence with explicit nils for the pre-launch portion. Trading a blank chart for a wrong chart is not a win.

**Theme, localization, accessibility.** Semantic `NSColor`s plus `controlAccentColor`; lane colors are one system colour per module, shaded toward grey for the second and later lane of the same module — there is no `<Module>_color` key in this codebase, colours are stored per *widget* as `<Module>_<widget>_color` and a lane belongs to a module, not to a widget; `viewDidChangeEffectiveAppearance` redraws. ~40 new strings: Stats is fully localized (**41 `.lproj`**, 464 identical keys each; `"Chart history"` is already translated), so an English-only flagship window would be the app's only such surface — sidebar titles, section headers, range labels and gap reasons are **translated** for the top locales, the rest fall back to the key. Lane `label` strings are device identifiers and are not localized. New controls are named **"Stored history"**, never "Chart history", which already means 60–600 points of live ring two rows away. Sidebar and readout table are natively accessible; the chart exposes one element per visible lane plus a summary naming range and lane count.

## 6. Settings

One "Stored history" section in App settings — **no per-module checkbox in the ten `Modules/*/popup.swift` settings and no per-sensor checkbox in `Modules/Sensors/settings.swift`**. The argument is not "that would be 11 extra upstream files" — §9 already adds one line to five of those popups for the expand button, so the file count is not the objection. The objection is that **per-lane opt-in belongs where the lanes are enumerated**: the window sidebar already lists every lane with its module, label and last-seen date, and a per-sensor mirror in `Modules/Sensors/settings.swift` would be a 100+ row table duplicating it, in the layout code upstream churns most.

- **Master switch — ON by default.** A retrospective feature that is off when the anomaly happens is worthless; the #1194 GPU comment is someone who wanted data he did not have. Defensible only because of §3's numbers: ~20 MB at first launch, 43 MB at a realistic month-old lane count, a hard 244.5 MB ceiling, ~8.5 MiB/day. Off means zero ingest and zero writes. **This switch ships in R1, in the same release as the recorder** (§10) — shipping the hook without it would leave R1 users with a growing directory and no in-app way to see, stop or delete it.
- **Live readout: "N lanes · X MB"**, with the real path as tooltip and **Reveal in Finder**. Lane count next to bytes, because lane count is the variable that moves and no fixed number in a settings string can stay true.
- **Retention preset** — two entries: Minimal (24 h) and Standard (default; 24 h + 30 d + 1 y). The picker shows the projected size **from the current lane count**, not from a ceiling. Growing copies forward and rebuilds what it can (§3); shrinking discards behind a Delete-weight confirmation. **R2** — a preset picker is not a kill switch and can wait.
- **Delete history** — quiesces ingest, munmaps and closes every read mapping on the history queue, unlinks, recreates empty. Never truncates a mapped file. **R1.**
- **Status banner** for the three states that are not "recording": paused for low disk space, suspended after three write failures, and "History is being recorded by another copy of Stats".
- `AppSettings.resetSettings()` (`Stats/Views/AppSettings.swift:438-450`) calls `Store.shared.reset()` then `restartApp(self)`; the new `HistoryStore.shared.deleteAll()` goes **between** them and must complete synchronously before `restartApp`, or the delete races the relaunch. Its confirmation text says history is deleted too.

## 7. Performance and battery budget

| Path | Thread | Budget | How |
|---|---|---|---|
| `ingest`, scalar payloads (CPU, RAM, Battery, Net) | reader queue, incl. **main** for Battery/Bluetooth | < 1 µs | predicated `isRecording`, integer lanes, lock + arithmetic, no allocation, no I/O |
| `ingest`, container payloads (Sensors, Disk, GPU) | reader queue | < 50 µs | **one** `queue.sync` array materialization per tick, then in-place iteration |
| commit | private serial, `.utility` | < 2 ms/tick | snapshot under lock, `pwrite` with lock released |
| catch-up rollup at open | private serial, `.utility` | < 10 ms, once | ≤8,640 T0 rows → ≤768 coarse rows |
| wakeups | — | 1/min, 5 s leeway, suspended when idle | one timer for the feature |
| disk | — | ~0.36 MiB/h (21 lanes), ~0.6 (45), ~1.1 (116) | block-floor derivation in §3; `fsync` 10 min, 30 on battery/LPM/thermal |
| memory, idle | — | < 1 MiB | 64 B/lane accumulators (< 16 KiB at the cap) + header and directory pages |
| memory, window open | — | **+< 300 KiB, range-independent** | ≤1,460 columns × 16 B × visible lanes (8 lanes ≈ 182 KiB); the decoded tier read is streamed into columns, never retained |
| window first paint | main + read queue | < 50 ms | aggregate to pixel columns **on the history queue** (read cost table, §3); hand main ≤1,460 columns × visible lanes, never the decoded series |

The loaded-window memory figure is the same for a 1-hour and a 1-year view — that is the point of aggregating to columns on the read queue. Only the *transient* read buffer differs, and it is consumed page by page rather than materialized (40.6 MB of T2 at 116 lanes is mapped, not copied).

Every number above except the two ingest budgets is derived in §3. The ingest budgets are **benchmarked, not asserted** — `Tests/History.swift` measures `emitHistory` for each payload type on a synthetic list of 120 sensors, because the Mirror alternative was rejected on a *measured* 435–542 µs and a typed path deserves the same standard.

No new sampling timers — every sample rides a reader tick that already fires. Chart redraw stays on main but reads an off-main snapshot, matching the `Charts.swift` convention. Nothing blocks main on I/O.

## 8. Privacy

Stored: numeric series plus identifiers — SMC keys, GPU ids and models, volume UUIDs, BSD interface names (`en0`), and the directory's **`label` field**, which holds the human-readable name of whatever the lane measures: volume names ("Macintosh HD", "Tim's backup drive"), interface descriptions ("Wi-Fi (en0)"), sensor labels and GPU models. That is the same class of text already written to `~/Library/Application Support/Stats/` by the existing store, and it is what makes the sidebar and orphan display possible (§3). **Not** stored: SSIDs (`wifiDetails` excluded outright), IP addresses (`laddr`/`raddr` excluded), DNS servers, hostnames, process names, user accounts, Bluetooth device names. Nothing is transmitted — `SystemStats.send` and Remote are untouched and never fed from the store. Deletion: the Delete button, "Reset settings", `rm -rf ~/Library/Application Support/Stats/history`, or the existing uninstaller. The directory is excluded from Time Machine.

## 9. Rebase robustness

| File | Edit | Size |
|---|---|---|
| `Kit/module/reader.swift` | `ingest` in `callback(_:)`, at `:118` | 1 line |
| `Kit/helpers.swift` | `button: NSView? = nil` on `separatorView` at `:402` | ~10 lines |
| `Kit/plugins/Charts.swift` | `setPoints([DoubleValue?])` — **only if popup restore ships** | 1 line |
| `Stats/AppDelegate.swift` | `start()`, `flush()` | 2 lines |
| `Stats/Views/Settings.swift` | "History" sidebar entry — **4 sites**: stored view property (`:29`), `MenuItem` (`:333`), `menuCallback` routing branch (`:196-207`), `MenuItem` tooltip branch (`:493-500`) | ~12 lines |
| `Stats/Views/AppSettings.swift` | settings section + `deleteAll()` before `restartApp` (`:438-450`) | ~10 lines |
| `Stats/helpers.swift` | ⌃⌥H branch in `handleKeyEvent` (`:361-380`) | ~6 lines |
| `Modules/{CPU,RAM,GPU,Net,Sensors}/popup.swift` | `button:` argument on the existing "Usage history" separator call | 1 line each |
| `Modules/Battery/popup.swift` | new History section + `LineChartView` | ~45 lines |
| `Stats/Supporting Files/*.lproj/Localizable.strings` | ~40 new keys, appended at EOF in all 41 files via `Kit/scripts/i18n.py fix` | ~40 lines × 41 |
| `Stats.xcodeproj/project.pbxproj` | 17 new files × 4 entries, **all in commit 1** | ~68 mechanical |

~155 lines of logic across 12 upstream files, every one a single hunk; the strings files are 41 more, but they are pure EOF appends and the lowest-risk hunk in the stack. Everything else is new files: 9 under `Kit/plugins/History/`, 7 `Modules/<X>/History.swift`, `Tests/History.swift`, and `docs/usage-history-design.md`.

**Zero** edits to `Kit/plugins/DB.swift`, `Kit/lldb/*`, and — the invariant that §2's Net decision is bought with — any `Modules/*/main.swift` or `Modules/*/readers.swift`. Debug seeding lives in a new `#if DEBUG` file, never in `Stats/helpers.swift`. No zlib import and no edit to `Kit/Supporting Files/Kit.h` (CRC-32 is Swift, §3).

**`project.pbxproj` is the real conflict surface, and it is resolved exactly once.** Commit 1 registers **all 17 new files** — as compiling stubs (empty types, `// MARK:` placeholders) with their target memberships already set — so every later commit changes Swift file *contents* only and touches zero pbxproj hunks. Spreading file additions across nine commits, as an earlier draft of this plan did, would mean nine pbxproj conflict points per rebase while claiming one.

## 10. Implementation plan

**Release 1 (3.0.15.2) — record, and give the user control over it.**

1. `feat: history file skeleton and design doc` (~130) — all 17 new files as stubs, every pbxproj entry, `docs/usage-history-design.md`, and a stubbed `Tests/History.swift` that the next three commits grow
2. `feat: fixed-size round-robin history archive` (~880, incl. ~25-line CRC-32, the free-space precondition and ~180 lines of archive tests)
3. `feat: history lane registry, directory and bucket accumulators` (~450, incl. ~110 lines of registry and accumulator tests)
4. `feat: history recorder with tiered commit and catch-up rollup` (~570, incl. ~140 lines of recorder, rollup and catch-up tests)
5. `feat: sleep, wake and clock-step handling for history` (~130)
6. `feat: history lane extraction in the module targets` (~330, seven module-target files: CPU, RAM, GPU, Net, Disk, Battery and Sensors)
7. `feat: record history samples from Reader.callback` (~3, upstream)
8. `feat: stored-history settings with switch, size and delete` (~110, upstream)
9. `feat: battery history chart in the battery popup` (~60) — **end of release 1**

**Release 2 (3.0.15.3) — read it.**

10. `feat: time-indexed history chart with min/max band` (~700)
11. `feat: history window with range picker, sidebar and crosshair` (~700)
12. `feat: open the history window from popups and settings` (~70, upstream: `separatorView` button parameter, five popup call sites, the Settings sidebar entry, ⌃⌥H)
13. `feat: retention presets with copy-forward rebuild` (~140, incl. the grow and shrink tests — they cover this commit's code, so they ship with it rather than in 15)
14. `feat: CSV export of the visible range` (~150)
15. `test: sleep, clock-step, preset, export and benchmark tests` (~200) — **end of release 2**

**Unit tests ship with the code they cover, not at the end.** `Tests/History.swift` is stubbed in commit 1 and grows in commits 2, 3 and 4, so no storage or recorder logic reaches a release without its own coverage, and a rebase that breaks the archive fails at the commit that introduced it rather than eleven commits later:

- **Commit 2 — archive.** Ring wraparound at a tier boundary; stale-slot rejection after a wrap; `firstValidBucket` so a fresh archive reads as no-data; header CRC rejection and recreate; truncated-file recreate; **directory disagreement between tiers resolved from T0**; **header rehydration of `lastCommitBucket` and `monotonicAnchor` across a simulated launch**; a bit-flip fuzz loop asserting no trap and no out-of-bounds read; **the three-strikes ENOSPC suspend and retry, and the low-free-space skip**.
- **Commit 3 — lanes and accumulators.** Rate conversion across a mid-series interval change; `dt <= 0` and non-finite rejection; **step-lane hold over a 40-minute idle stretch, asserting `HELD` for 15 min then `NODATA`**; lane LRU reclaim; `label` truncation on a scalar boundary.
- **Commit 4 — recorder.** Rollup with partially-populated and empty fine buckets; **coarse-tier catch-up rollup after a simulated restart, including a gap longer than T0 retention**; count-weighted resampling; gap-reason derivation at read; **a TSAN run with Battery ingest on main racing the commit thread**.
- **Commit 15 — what is left.** Simulated 9-hour sleep; backward clock jump inside and outside the window; gap ≥ tier capacity resets rather than iterating; **lane-growth copy-forward rebuild**; **the daily network accumulator rolling over local midnight, across a DST boundary, and across a timezone change**; `emitHistory` benchmarks per payload type; CSV formatting including gap and `HELD` rows.

Split this way the suite costs ~100 lines more than one lump commit (~630 against ~520) because each part carries its own fixtures; that is the price of R1 shipping tested rather than trusted. The `Tests/` XCTest target already exists (`Kit.swift`, `RAM.swift`), so no new target — `Tests/History.swift` is registered in commit 1 with every other new file.

**Manual matrix.** Fresh install; update over an existing install; **quit mid-bucket, relaunch, confirm the 30-day and 1-year views have no hole**; 8 h sleep and lid close/wake; timezone change and a DST boundary; clock set back 1 h; CPU disabled 10 min; global pause; interval 1 s → 60 s → 1 s mid-series; Wi-Fi → Ethernet switch (no spike, no false zero); external display GPU switch; USB volume mount/unmount/replug; `kill -9` during a commit; force-quit during a write; disk filled to zero free; Delete while the window is open; two Stats instances (loser shows the banner); 116-sensor opt-in on an Intel Mac; `du` and the settings lane count before/after a 24 h soak, asserted as a **range in MB at the observed lane count**, not against a fixed number; dark/light toggle with the window open; VoiceOver pass.

**Rollout.** No hidden flag — the visible master switch is the kill switch, and it ships in the **same release as the recorder** (commit 8, R1), together with the size readout and Delete. R1 therefore has both a user-visible reason to exist (the Battery popup chart) and full user control over what it writes; it also lets the archive accumulate real data for a cycle before anything reads it in anger. R2 adds the window, presets and export.

## 11. Risks

1. **The format is wrong and we find out after users have data.** Accept. No-migration policy costs history once; R1-before-R2 surfaces it early, and lane growth is already a copy-forward rebuild.
2. **Lane count, not preset, is what drives footprint** — and it grows with the user's habits, not with time. Mitigated by the 256-lane cap (244.5 MB at Standard, the worst case anyone can reach), LRU reclaim, and a settings readout that shows live lanes and live bytes rather than a number from this document.
3. **Sensors cardinality.** Curated default, per-lane checkboxes in the window, lane cap at creation, live size readout quoting the 111 MB figure before the user commits.
4. **Lane identity drift.** Volume UUID, SMC key, `GPU_Info.id`; LRU reclaim on `lastUsedTs`; orphans greyed with their stored label and a last-seen date.
5. **`SIGBUS`.** Eliminated on the write path by `pwrite`; read mappings hold their descriptor for the process lifetime, are never truncated, and tear down on the history queue before any unlink.
6. **`ENOSPC` is not eliminated**, only mitigated — preallocation reserves the extent but APFS copy-on-write can still need a block. The free-space precondition and the three-strikes suspend are the real answer; a user on a genuinely full volume gets a paused banner, not a corrupt archive.
7. **`f32` precision on large byte counts.** Accept; ~6e-8 relative error beyond 2²⁴.
8. **Typed `emitHistory` means 7 new module-target files.** Accept — Kit cannot import module targets, so there is no alternative that compiles, and a compile error on an upstream rename is the feature, not the cost.
9. **Total process write volume goes up**, because the LevelDB churn is untouched. Stated in settings copy and release notes; #3292 remains open.
10. **Battery sampling stays event-driven.** No dedicated timer: interval-span attribution plus the 15-minute `HELD` hold on the `level` step lane (§2) turns irregular IOPS events into a continuous series, drawn dashed so a held value is never mistaken for a measured one; `battery.power` is a rate and correctly gaps.
11. **Net's link-rate guard is an unmarked zero** (§2). Bounded to one sample per firing and invisible at T1/T2, but it is a known small lie in the data. The two-line upstream fix is specified in §2 and deliberately not taken: the zero-edit invariant for `Modules/*/readers.swift` is worth more to this fork than marking a zero that moves only a bucket's `min`.
12. **CPU temperature and frequency have no history at all** and will be the first thing asked for. The window labels their absence explicitly rather than hiding it; un-gating is a v2 patch with a measured idle-power number.
