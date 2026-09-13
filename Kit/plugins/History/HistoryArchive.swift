//
//  HistoryArchive.swift
//  Kit
//
//  Persistent usage history: the on-disk round-robin archive.
//  Design: docs/usage-history-design.md (§3 Storage), exelban/stats#1194.
//

import Foundation

// MARK: - tiers and presets

/// One resolution tier. Every tier is a separate file in `history/`.
public enum HistoryTier: Int, CaseIterable {
    case t0
    case t1
    case t2

    /// Bucket width in seconds: 10 s, 2 min, 30 min.
    public var step: Int {
        switch self {
        case .t0: return 10
        case .t1: return 120
        case .t2: return 1800
        }
    }

    /// Retained buckets: 24 h, 30 d, 365 d.
    public var buckets: Int {
        switch self {
        case .t0: return 8_640
        case .t1: return 21_600
        case .t2: return 17_520
        }
    }

    public var fileName: String {
        switch self {
        case .t0: return "t0.rrd"
        case .t1: return "t1.rrd"
        case .t2: return "t2.rrd"
        }
    }
}

/// Retention preset. Two entries only, see §3.
public enum HistoryRetentionPreset: String {
    case minimal
    case standard

    public var tiers: [HistoryTier] {
        switch self {
        case .minimal: return [.t0]
        case .standard: return [.t0, .t1, .t2]
        }
    }
}

// MARK: - slot

/// Why a bucket holds no measured sample, or how it was filled.
public enum HistoryGapReason: UInt8 {
    case measured = 0
    case nodata = 1
    case asleep = 2
    case notRunning = 3
    case clockStep = 4
    case held = 5
}

/// One (bucket, lane) cell of the matrix. 20 B on disk:
/// `bucket:u32 | count:u16 | reason:u8 | pad:u8 | min:f32 | max:f32 | sum:f32`.
public struct HistorySlot {
    public static let byteWidth: Int = 20

    public var bucket: UInt32
    public var count: UInt16
    public var reason: HistoryGapReason
    public var min: Float
    public var max: Float
    public var sum: Float

    public init(bucket: UInt32 = 0, count: UInt16 = 0, reason: HistoryGapReason = .nodata,
                min: Float = 0, max: Float = 0, sum: Float = 0) {
        self.bucket = bucket
        self.count = count
        self.reason = reason
        self.min = min
        self.max = max
        self.sum = sum
    }

    // MARK: - encoding
    // Fixed little-endian encode/decode into the matrix region.
}

// MARK: - header

/// The 4 KiB file header. CRC covers the header only; slots are self-validating
/// through their own bucket stamp.
public struct HistoryArchiveHeader {
    public static let byteWidth: Int = 4_096
    /// Hexdumps as "STHS" under the file's little-endian encoding: the low byte
    /// is written first, so 0x53 0x54 0x48 0x53 has to be spelled backwards
    /// here. Baked into every archive from the first release, so it is fixed
    /// now rather than in the commit that writes it.
    public static let magic: UInt32 = 0x53485453 // "STHS" little-endian
    public static let formatVersion: UInt32 = 1

    public var step: UInt32
    public var buckets: UInt32
    public var lanes: UInt32
    public var lastCommitBucket: UInt32
    public var monotonicAnchor: UInt64
    public var createdTs: UInt64

    // MARK: - encoding
    // MARK: - validation (magic, formatVersion, crc32)
}

// MARK: - archive

/// One tier file: header + lane directory + `buckets × lanes × 20 B` matrix.
/// Written with `pwrite`, read through a read-only `mmap`.
public final class HistoryArchive {
    public let tier: HistoryTier
    public let url: URL

    public init(tier: HistoryTier, url: URL) {
        self.tier = tier
        self.url = url
    }

    // MARK: - lifecycle (create, open, preallocate, close)
    // MARK: - directory (read, write, T0 wins on disagreement)
    // MARK: - commit (pwrite of a changed row range, fsync policy)
    // MARK: - read (mmap, bounds-checked slot access, stale-stamp rejection)
    // MARK: - corruption (rename to .corrupt-<ts> and recreate)
}

// MARK: - store

/// Owns the tier archives, the cross-process lock and the recording status that
/// the settings section renders.
public final class HistoryStore {
    public static let shared = HistoryStore()

    /// Recording is not possible, or is suspended, for one of these reasons.
    public enum Status {
        case recording
        case disabled
        case lowDiskSpace
        case writeFailures
        case lockedByAnotherInstance
    }

    private init() {}

    // MARK: - location (~/Library/Application Support/Stats/history, no backup)
    // MARK: - lock (flock(LOCK_EX|LOCK_NB) on history/.lock)
    // MARK: - open and catch-up
    // MARK: - status and size readout (lane count, bytes on disk)
    // MARK: - deleteAll (quiesce, munmap, unlink, recreate)
}

// MARK: - crc32

/// CRC-32 (IEEE) over a byte buffer. Kept in Swift on purpose: there is no zlib
/// import in the project and Kit's umbrella header must stay untouched (§3).
internal enum HistoryCRC32 {
    // MARK: - lazily built 256-entry table
    // MARK: - checksum(_:)
}
