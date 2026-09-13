//
//  HistoryLane.swift
//  Kit
//
//  Persistent usage history: lane identity and the on-disk lane directory.
//  Design: docs/usage-history-design.md (§3 Storage), exelban/stats#1194.
//

import Foundation

// MARK: - lane vocabulary

/// The module a lane belongs to. Stored as one byte in the directory entry and
/// used to group the window sidebar.
public enum HistoryLaneModule: UInt8 {
    case cpu = 0
    case ram = 1
    case gpu = 2
    case net = 3
    case disk = 4
    case battery = 5
    case sensors = 6
}

/// The unit of the stored scalar. Drives the y axis and the CSV header.
public enum HistoryLaneUnit: UInt8 {
    case percent = 0
    case bytesPerSec = 1
    case bytes = 2
    case celsius = 3
    case watts = 4
    case volts = 5
    case rpm = 6
}

/// How a lane behaves between samples (§2).
/// - `rate`: per-tick delta divided by elapsed time; gaps honestly.
/// - `gauge`: instantaneous reading.
/// - `step`: holds its last value for a bounded window, written as `.held`.
public enum HistoryLaneKind: UInt8 {
    case rate = 0
    case gauge = 1
    case step = 2
}

public struct HistoryLaneFlags: OptionSet {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let orphan = HistoryLaneFlags(rawValue: 1 << 0)
    public static let reclaimed = HistoryLaneFlags(rawValue: 1 << 1)
}

// MARK: - identity

/// The stable identity of a lane: the first 16 B of the SHA-256 of a key built
/// from the most stable identifiers available (volume UUID, SMC key,
/// `GPU_Info.id`, BSD interface name) — never a display name.
public struct HistoryLaneIdentity: Hashable {
    public static let byteWidth: Int = 16

    /// The 16 bytes as two halves rather than a `[UInt8]`: a fixed-width value
    /// type is free to hash, costs no allocation per identity, and cannot be
    /// constructed at the wrong length.
    public let high: UInt64
    public let low: UInt64

    public init(high: UInt64, low: UInt64) {
        self.high = high
        self.low = low
    }

    // MARK: - derivation from a stable key string

    // MARK: - encoding (16 B, big-endian halves, first field of the entry)

    internal func encode(into buffer: inout [UInt8], at offset: Int) {
        HistoryBytes.putBigEndian(self.high, into: &buffer, at: offset)
        HistoryBytes.putBigEndian(self.low, into: &buffer, at: offset + 8)
    }

    internal static func decode(_ bytes: [UInt8], at offset: Int) -> HistoryLaneIdentity {
        HistoryLaneIdentity(
            high: HistoryBytes.getBigEndian(UInt64.self, from: bytes, at: offset),
            low: HistoryBytes.getBigEndian(UInt64.self, from: bytes, at: offset + 8)
        )
    }
}

// MARK: - directory entry

/// One 128 B directory entry, written identically into every tier file.
public struct HistoryLaneEntry {
    public static let byteWidth: Int = 128
    public static let labelCapacity: Int = 88
    /// `firstValidBucket` sentinel: the lane exists but nothing has ever been
    /// written for it, so a fresh archive reads as no-data rather than as a
    /// year of flat zeros (§3).
    public static let noValidBucket: UInt32 = .max

    fileprivate static let offsetIdentity: Int = 0
    fileprivate static let offsetModule: Int = 16
    fileprivate static let offsetUnit: Int = 17
    fileprivate static let offsetKind: Int = 18
    fileprivate static let offsetFlags: Int = 19
    fileprivate static let offsetFirstValidBucket: Int = 20
    fileprivate static let offsetLastUsedTs: Int = 24
    fileprivate static let offsetLabelLength: Int = 32
    fileprivate static let offsetLabel: Int = 33

    public var identity: HistoryLaneIdentity
    public var module: HistoryLaneModule
    public var unit: HistoryLaneUnit
    public var kind: HistoryLaneKind
    public var flags: HistoryLaneFlags
    public var firstValidBucket: UInt32
    public var lastUsedTs: UInt64
    /// Human-readable name of what the lane measures ("Wi-Fi (en0)",
    /// "Macintosh HD", "CPU die"). Truncated on a scalar boundary.
    public var label: String

    public init(identity: HistoryLaneIdentity, module: HistoryLaneModule, unit: HistoryLaneUnit,
                kind: HistoryLaneKind, flags: HistoryLaneFlags = [],
                firstValidBucket: UInt32 = HistoryLaneEntry.noValidBucket,
                lastUsedTs: UInt64 = 0, label: String = "") {
        self.identity = identity
        self.module = module
        self.unit = unit
        self.kind = kind
        self.flags = flags
        self.firstValidBucket = firstValidBucket
        self.lastUsedTs = lastUsedTs
        self.label = label
    }

    // MARK: - encoding (fixed 128 B, UTF-8 label truncated on a scalar boundary)

    internal func encode(into buffer: inout [UInt8], at offset: Int) {
        self.identity.encode(into: &buffer, at: offset + HistoryLaneEntry.offsetIdentity)
        buffer[offset + HistoryLaneEntry.offsetModule] = self.module.rawValue
        buffer[offset + HistoryLaneEntry.offsetUnit] = self.unit.rawValue
        buffer[offset + HistoryLaneEntry.offsetKind] = self.kind.rawValue
        buffer[offset + HistoryLaneEntry.offsetFlags] = self.flags.rawValue
        HistoryBytes.put(self.firstValidBucket, into: &buffer, at: offset + HistoryLaneEntry.offsetFirstValidBucket)
        HistoryBytes.put(self.lastUsedTs, into: &buffer, at: offset + HistoryLaneEntry.offsetLastUsedTs)

        let label = HistoryLaneEntry.truncate(self.label)
        buffer[offset + HistoryLaneEntry.offsetLabelLength] = UInt8(label.count)
        for i in 0..<HistoryLaneEntry.labelCapacity {
            buffer[offset + HistoryLaneEntry.offsetLabel + i] = i < label.count ? label[i] : 0
        }
    }

    /// Total: unknown enum bytes and a length or UTF-8 sequence that a bit flip
    /// made nonsense all decode to something rather than trapping. The file's
    /// checksum is what actually rejects a damaged directory (§3).
    internal static func decode(_ bytes: [UInt8], at offset: Int) -> HistoryLaneEntry {
        let length = Swift.min(Int(HistoryBytes.get(UInt8.self, from: bytes, at: offset + offsetLabelLength)), labelCapacity)
        let start = offset + offsetLabel
        let label: String
        if length > 0, start + length <= bytes.count {
            label = String(decoding: bytes[start..<(start + length)], as: UTF8.self)
        } else {
            label = ""
        }

        return HistoryLaneEntry(
            identity: HistoryLaneIdentity.decode(bytes, at: offset + offsetIdentity),
            module: HistoryLaneModule(rawValue: HistoryBytes.get(UInt8.self, from: bytes, at: offset + offsetModule)) ?? .cpu,
            unit: HistoryLaneUnit(rawValue: HistoryBytes.get(UInt8.self, from: bytes, at: offset + offsetUnit)) ?? .percent,
            kind: HistoryLaneKind(rawValue: HistoryBytes.get(UInt8.self, from: bytes, at: offset + offsetKind)) ?? .gauge,
            flags: HistoryLaneFlags(rawValue: HistoryBytes.get(UInt8.self, from: bytes, at: offset + offsetFlags)),
            firstValidBucket: HistoryBytes.get(UInt32.self, from: bytes, at: offset + offsetFirstValidBucket),
            lastUsedTs: HistoryBytes.get(UInt64.self, from: bytes, at: offset + offsetLastUsedTs),
            label: label
        )
    }

    /// UTF-8, cut on a scalar boundary so a truncated label is still a string.
    internal static func truncate(_ label: String) -> [UInt8] {
        let utf8 = Array(label.utf8)
        guard utf8.count > HistoryLaneEntry.labelCapacity else { return utf8 }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(HistoryLaneEntry.labelCapacity)
        for scalar in label.unicodeScalars {
            let width = String(scalar).utf8.count
            if bytes.count + width > HistoryLaneEntry.labelCapacity { break }
            bytes.append(contentsOf: String(scalar).utf8)
        }
        return bytes
    }
}

// MARK: - directory

/// The lane registry: resolves a lane key to the integer id used on the hot
/// path, holds the directory, and reclaims cold lanes by LRU once the cap is hit.
public final class HistoryLaneDirectory {
    /// Structural cap; the size budget allows more, so this is what binds (§3).
    public static let laneCap: Int = 256

    public init() {}

    // MARK: - registration (key -> integer lane id, at registration time only)
    // MARK: - lookup (id -> entry, module grouping for the sidebar)
    // MARK: - LRU reclaim on lastUsedTs
    // MARK: - merge (T0's copy wins when tiers disagree)
}
