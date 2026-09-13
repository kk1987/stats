//
//  History.swift
//  Disk
//
//  Persistent usage history: lane extraction for the Disk module.
//  The conformance lives here because Kit cannot import the module targets.
//  Design: docs/usage-history-design.md (§2 Sampling), exelban/stats#1194.
//

import Foundation
import Kit

// MARK: - lanes
//
// CapacityReader, ActivityReader and SMARTReader are all Reader<Disks> with
// partially filled instances, so each lane binds to exactly one reader key:
// `<uuid>.free` from capacity, `<uuid>.read` and `<uuid>.write` from activity.
// Identity is the volume UUID; the label keeps the volume name.
//
// This is the module the "reader identity is passed, not inferred from the
// payload type" rule in §2 exists for, and it is the only conformance that
// switches on `reader.name`. Dispatching on the payload type would write a
// `0 B/s` on every capacity tick (10 s by default) and a `free = 0` on every
// activity tick (1 s), because each reader owns its own `Disks` and fills only
// the fields it reads. SMARTReader has no v1 lane and emits nothing.
//
// `read` and `write` are per-tick byte deltas, not rates: the recorder divides
// by the time actually elapsed since that lane's previous sample, bounded by
// the reader's interval (§2). `driveStats` leaves the delta at zero until it
// has a previous counter to subtract from (Modules/Disk/readers.swift:247-252),
// so the first activity sample of a newly mounted volume is a substituted zero
// — one sample, in one bucket, moving that bucket's `min` and nothing else,
// which is the same trade §2 makes for Net's link-rate guard.

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
// even while it is recording; and a volume that goes away for longer than the
// TTL — an unplugged drive, an ejected disk image — re-resolves on its first
// tick back, so a cached id that was reclaimed in the meantime cannot be
// written to under the old identity.
//
// Every access to these globals happens inside `HistoryRecorder.ingest` with
// the recorder's lock held — the same lock that serializes the directory — so
// they are not racing even though Battery ingests on the main run loop.

private let historyLaneCacheTTL: UInt64 = 600

/// The reader names this module records from. `Reader.name` is the class name
/// (`Kit/module/reader.swift:52-54`), so a rename upstream turns a lane off
/// silently — which is why only the module that genuinely needs the
/// distinction makes it.
private let capacityReaderName = "CapacityReader"
private let activityReaderName = "ActivityReader"

/// A resolved lane id and the wall clock it was resolved at. `id` is negative
/// for a lane the registry refused (the cap is reached and every lane in the
/// directory is still warm); the refusal is cached like a success so that a
/// full directory does not re-hash every key on every tick.
private struct HistoryLaneSlot {
    var id: Int32 = -1
    var resolvedAt: UInt64 = 0
}

/// Keyed by volume UUID directly, so the cached path neither interpolates a
/// string nor allocates: one dictionary of lanes per metric rather than one
/// dictionary keyed by a composed "<uuid>.<metric>".
private var readLanes: [String: HistoryLaneSlot] = [:]
private var writeLanes: [String: HistoryLaneSlot] = [:]
private var freeLanes: [String: HistoryLaneSlot] = [:]

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

/// The volume name exactly as macOS reports it — "Macintosh HD", "Tim's backup
/// drive" — because a lane whose drive was unplugged last month has to stay
/// recognisable in the sidebar, and the UUID that is the actual identity is
/// not (§3, §8). Falls back to the BSD name, then to the UUID, for a volume
/// Disk Arbitration gave no name at all.
private func diskLaneLabel(_ d: drive) -> String {
    if !d.mediaName.isEmpty { return d.mediaName }
    return d.BSDName.isEmpty ? d.uuid : d.BSDName
}

// MARK: - emitHistory

extension Disks: HistoryProvider {
    public func emitHistory(reader: HistoryReaderKey, into sink: inout HistorySink) {
        let capacity: Bool
        switch reader.name {
        case capacityReaderName: capacity = true
        case activityReaderName: capacity = false
        default: return
        }

        let ts = sink.timestamp
        // One cross-queue copy of the whole array per tick, then in place (§2).
        // `Disks.array` is `queue.sync { self._array }` and `first(where:)` is
        // another hop per call, so this is the accessor that must not be
        // reached once per lane.
        let drives = self.array

        for d in drives {
            // Volume UUID is the identity (§3, risk 4). Disk Arbitration has
            // no media UUID for some volumes — network mounts, a few disk
            // images — and there is no second candidate that survives a
            // replug, so those are not recorded rather than recorded under a
            // key that means something else next week.
            guard !d.uuid.isEmpty else { continue }
            let uuid = d.uuid

            if capacity {
                if let lane = historyLane(&freeLanes, uuid, at: ts, into: &sink, {
                    HistoryLaneDescriptor(key: HistoryLaneKey(module: .disk, source: uuid, metric: "free"),
                                          unit: .bytes, kind: .gauge,
                                          label: "\(diskLaneLabel(d)) — free")
                }) {
                    sink.emit(lane: lane, value: Double(d.free))
                }
                continue
            }

            if let lane = historyLane(&readLanes, uuid, at: ts, into: &sink, {
                HistoryLaneDescriptor(key: HistoryLaneKey(module: .disk, source: uuid, metric: "read"),
                                      unit: .bytesPerSec, kind: .rate,
                                      label: "\(diskLaneLabel(d)) — read")
            }) {
                sink.emit(lane: lane, value: Double(d.activity.read))
            }

            if let lane = historyLane(&writeLanes, uuid, at: ts, into: &sink, {
                HistoryLaneDescriptor(key: HistoryLaneKey(module: .disk, source: uuid, metric: "write"),
                                      unit: .bytesPerSec, kind: .rate,
                                      label: "\(diskLaneLabel(d)) — write")
            }) {
                sink.emit(lane: lane, value: Double(d.activity.write))
            }
        }
    }
}
