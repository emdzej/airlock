import Foundation

/// Wire representation of a mounted drive — mirrors the JSON payload
/// airlockd's `internal/api/server.go` returns from `GET /api/drives`
/// and in `/api/events` `drives` events.
public struct Drive: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let shareName: String
    public let label: String
    public let displayName: String
    public let fsType: String
    public let sizeBytes: Int64
    public let sizeHuman: String
    public let readOnly: Bool
    public let mountPoint: String
    public let kernel: String
    public let parent: String
    /// True while the daemon has withdrawn the SMB share and is
    /// unmounting. Absent from older daemons (and from drive lists
    /// cached by older companion builds) — defaults to false.
    public let ejecting: Bool

    public var id: String { shareName }

    enum CodingKeys: String, CodingKey {
        case shareName   = "share_name"
        case label
        case displayName = "display_name"
        case fsType      = "fs_type"
        case sizeBytes   = "size_bytes"
        case sizeHuman   = "size_human"
        case readOnly    = "read_only"
        case mountPoint  = "mount_point"
        case kernel
        case parent
        case ejecting
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shareName   = try c.decode(String.self, forKey: .shareName)
        label       = try c.decode(String.self, forKey: .label)
        displayName = try c.decode(String.self, forKey: .displayName)
        fsType      = try c.decode(String.self, forKey: .fsType)
        sizeBytes   = try c.decode(Int64.self, forKey: .sizeBytes)
        sizeHuman   = try c.decode(String.self, forKey: .sizeHuman)
        readOnly    = try c.decode(Bool.self, forKey: .readOnly)
        mountPoint  = try c.decode(String.self, forKey: .mountPoint)
        kernel      = try c.decode(String.self, forKey: .kernel)
        parent      = try c.decode(String.self, forKey: .parent)
        ejecting    = try c.decodeIfPresent(Bool.self, forKey: .ejecting) ?? false
    }
}

/// A whole USB block device — `GET /api/devices` (`devicePayload` in
/// airlockd's `internal/api/format.go`).
public struct Device: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let name: String
    public let path: String
    public let model: String
    public let vendor: String
    public let serial: String
    public let sizeBytes: Int64
    public let sizeHuman: String
    public let transport: String
    public let ptType: String
    public let readOnly: Bool
    public let anyPartitionReadOnly: Bool
    public let suggestedFS: String
    public let partitions: [Partition]

    public var id: String { name }

    /// "Generic MassStorageClass", falling back to the kernel name.
    public var title: String {
        let t = [vendor, model].filter { !$0.isEmpty }.joined(separator: " ")
        return t.isEmpty ? name : t
    }

    /// No medium in the slot: card readers report a 0-byte disk. A card
    /// pulled out without ejecting can leave stale partition nodes behind
    /// (sdb1 with its old size), so size alone decides.
    public var isEmpty: Bool { sizeBytes == 0 }

    /// Partitions on the medium; none for an empty slot, even if the
    /// kernel still lists the pulled card's.
    public var livePartitions: [Partition] { isEmpty ? [] : partitions }

    /// Whole-disk writes (format, flash) are refused for read-only media.
    public var isWritable: Bool { !readOnly && !anyPartitionReadOnly && !isEmpty }

    /// What the web UI asks the user to type before a destructive
    /// operation: the first partition label, else a fixed word.
    public func confirmWord(fallback: String) -> String {
        livePartitions.first(where: { !$0.label.isEmpty })?.label ?? fallback
    }

    enum CodingKeys: String, CodingKey {
        case name, path, model, vendor, serial, transport, partitions
        case sizeBytes = "size_bytes"
        case sizeHuman = "size_human"
        case ptType = "pt_type"
        case readOnly = "read_only"
        case anyPartitionReadOnly = "any_partition_read_only"
        case suggestedFS = "suggested_fs"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        vendor = try c.decodeIfPresent(String.self, forKey: .vendor) ?? ""
        serial = try c.decodeIfPresent(String.self, forKey: .serial) ?? ""
        sizeBytes = try c.decode(Int64.self, forKey: .sizeBytes)
        sizeHuman = try c.decode(String.self, forKey: .sizeHuman)
        transport = try c.decodeIfPresent(String.self, forKey: .transport) ?? ""
        ptType = try c.decodeIfPresent(String.self, forKey: .ptType) ?? ""
        readOnly = try c.decode(Bool.self, forKey: .readOnly)
        anyPartitionReadOnly = try c.decodeIfPresent(Bool.self, forKey: .anyPartitionReadOnly) ?? false
        suggestedFS = try c.decodeIfPresent(String.self, forKey: .suggestedFS) ?? "vfat"
        // Go encodes an empty slice as null when it was never allocated.
        partitions = try c.decodeIfPresent([Partition].self, forKey: .partitions) ?? []
    }
}

public struct Partition: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let name: String
    public let sizeBytes: Int64
    public let sizeHuman: String
    public let fsType: String
    public let label: String
    public let uuid: String
    public let mountPoint: String
    public let isAirlock: Bool
    /// The airlock share, when airlockd mounted it.
    public let shareName: String?
    public let canRelabel: Bool
    public let maxLabelLen: Int
    public let canMount: Bool
    public let canFsck: Bool

    public var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, label, uuid
        case sizeBytes = "size_bytes"
        case sizeHuman = "size_human"
        case fsType = "fs_type"
        case mountPoint = "mount_point"
        case isAirlock = "is_airlock"
        case shareName = "share_name"
        case canRelabel = "can_relabel"
        case maxLabelLen = "max_label_len"
        case canMount = "can_mount"
        case canFsck = "can_fsck"
    }
}

/// One directory entry from `GET /api/drives/{share}/ls`.
public struct FileEntry: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let name: String
    public let isDir: Bool
    public let size: Int64
    public let modified: Date

    public var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, size, modified
        case isDir = "is_dir"
    }
}

public struct Listing: Codable, Sendable {
    public let path: String
    public let entries: [FileEntry]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        entries = try c.decodeIfPresent([FileEntry].self, forKey: .entries) ?? []
    }

    enum CodingKeys: String, CodingKey { case path, entries }
}

/// Filesystems airlockd can format (`internal/format`).
public enum Filesystem: String, CaseIterable, Sendable, Identifiable {
    case vfat, exfat, ntfs, ext4

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .vfat: "FAT32"
        case .exfat: "exFAT"
        case .ntfs: "NTFS"
        case .ext4: "ext4"
        }
    }

    /// Longest label each tool accepts.
    public var maxLabelLength: Int {
        switch self {
        case .vfat: 11
        case .exfat: 15
        case .ntfs: 32
        case .ext4: 16
        }
    }
}

/// Image compression for flash and dump (`internal/flash`).
public enum Compression: String, CaseIterable, Sendable, Identifiable {
    case none, xz, gz

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: "None (.img)"
        case .xz: "xz (.img.xz)"
        case .gz: "gzip (.img.gz)"
        }
    }

    /// Guess from a file name, as the web UI does.
    public init(fileName: String) {
        let n = fileName.lowercased()
        if n.hasSuffix(".xz") { self = .xz }
        else if n.hasSuffix(".gz") { self = .gz }
        else { self = .none }
    }
}

/// One progress event from a streamed operation (format, flash, fsck).
/// The terminal event has `stage` "done" or "error".
public struct OpEvent: Codable, Equatable, Sendable {
    public let stage: String
    public let message: String?
    /// Bytes written to the device so far (flash).
    public let written: Int64?
    /// Tool exit status (fsck).
    public let exitCode: Int?

    public var isTerminal: Bool { stage == "done" || stage == "error" }

    enum CodingKeys: String, CodingKey {
        case stage, message, written
        case exitCode = "exit_code"
    }
}
