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
}

// MARK: - directory entry

/// One 128 B directory entry, written identically into every tier file.
public struct HistoryLaneEntry {
    public static let byteWidth: Int = 128
    public static let labelCapacity: Int = 88

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
                kind: HistoryLaneKind, flags: HistoryLaneFlags = [], firstValidBucket: UInt32 = 0,
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
