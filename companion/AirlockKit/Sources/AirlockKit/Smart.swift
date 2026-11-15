import Foundation

/// A drive's SMART reading — `GET /api/devices/{name}/smart` (`smart.Report`
/// in airlockd's `internal/smart`). Numbers the drive doesn't report are nil.
public struct SmartReport: Codable, Equatable, Sendable {
    /// The overall verdict; also `Device.health` in the device list.
    public enum Status: String, Codable, Sendable {
        case passed, warning, failing, unsupported, standby, error
        /// A verdict this build doesn't know (a newer daemon).
        case unknown

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .unknown
        }

        /// Worth flagging in a device list.
        public var isAlarming: Bool { self == .warning || self == .failing }
    }

    public let status: Status
    public let summary: String
    public let warnings: [String]
    /// smartctl's own diagnostics ("Unknown USB bridge …").
    public let messages: [String]

    /// "ATA", "NVMe" or "SCSI".
    public let `protocol`: String
    public let model: String
    public let serial: String
    public let firmware: String

    public let temperatureC: Int?
    public let powerOnHours: Int64?
    public let powerCycles: Int64?
    /// Percent of rated write endurance used; may pass 100.
    public let percentageUsed: Int?
    public let availableSpare: Int?
    public let reallocatedSectors: Int64?
    public let pendingSectors: Int64?
    public let uncorrectableSectors: Int64?
    public let mediaErrors: Int64?
    public let unsafeShutdowns: Int64?
    public let dataWrittenBytes: Int64?

    /// The raw table: ATA attributes, or the NVMe health log's fields.
    public let attributes: [SmartAttribute]
    public let checkedAt: Date?

    /// The drive answered with SMART data (not unsupported, asleep or an error).
    public var hasData: Bool { status == .passed || status == .warning || status == .failing }

    enum CodingKeys: String, CodingKey {
        case status, summary, warnings, messages, model, serial, firmware, attributes
        case `protocol`
        case temperatureC = "temperature_c"
        case powerOnHours = "power_on_hours"
        case powerCycles = "power_cycles"
        case percentageUsed = "percentage_used"
        case availableSpare = "available_spare"
        case reallocatedSectors = "reallocated_sectors"
        case pendingSectors = "pending_sectors"
        case uncorrectableSectors = "uncorrectable_sectors"
        case mediaErrors = "media_errors"
        case unsafeShutdowns = "unsafe_shutdowns"
        case dataWrittenBytes = "data_written_bytes"
        case checkedAt = "checked_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .unknown
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
        messages = try c.decodeIfPresent([String].self, forKey: .messages) ?? []
        `protocol` = try c.decodeIfPresent(String.self, forKey: .protocol) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        serial = try c.decodeIfPresent(String.self, forKey: .serial) ?? ""
        firmware = try c.decodeIfPresent(String.self, forKey: .firmware) ?? ""
        temperatureC = try c.decodeIfPresent(Int.self, forKey: .temperatureC)
        powerOnHours = try c.decodeIfPresent(Int64.self, forKey: .powerOnHours)
        powerCycles = try c.decodeIfPresent(Int64.self, forKey: .powerCycles)
        percentageUsed = try c.decodeIfPresent(Int.self, forKey: .percentageUsed)
        availableSpare = try c.decodeIfPresent(Int.self, forKey: .availableSpare)
        reallocatedSectors = try c.decodeIfPresent(Int64.self, forKey: .reallocatedSectors)
        pendingSectors = try c.decodeIfPresent(Int64.self, forKey: .pendingSectors)
        uncorrectableSectors = try c.decodeIfPresent(Int64.self, forKey: .uncorrectableSectors)
        mediaErrors = try c.decodeIfPresent(Int64.self, forKey: .mediaErrors)
        unsafeShutdowns = try c.decodeIfPresent(Int64.self, forKey: .unsafeShutdowns)
        dataWrittenBytes = try c.decodeIfPresent(Int64.self, forKey: .dataWrittenBytes)
        attributes = try c.decodeIfPresent([SmartAttribute].self, forKey: .attributes) ?? []
        // A zero Go time or a format this build can't read shouldn't lose
        // the whole report.
        checkedAt = try? c.decodeIfPresent(Date.self, forKey: .checkedAt)
    }
}

/// One row of the raw SMART table. NVMe log fields carry only name and raw.
public struct SmartAttribute: Codable, Equatable, Hashable, Sendable {
    public let id: Int?
    public let name: String
    /// Normalised value, 1-253; higher is better.
    public let value: Int?
    public let worst: Int?
    public let threshold: Int?
    public let raw: String
    /// Crossing the threshold predicts failure (rather than age).
    public let prefailure: Bool
    /// "now", "past" or "".
    public let failed: String

    public var isFailing: Bool { failed == "now" }

    enum CodingKeys: String, CodingKey {
        case id, name, value, worst, raw, prefailure, failed
        case threshold = "thresh"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        value = try c.decodeIfPresent(Int.self, forKey: .value)
        worst = try c.decodeIfPresent(Int.self, forKey: .worst)
        threshold = try c.decodeIfPresent(Int.self, forKey: .threshold)
        raw = try c.decodeIfPresent(String.self, forKey: .raw) ?? ""
        prefailure = try c.decodeIfPresent(Bool.self, forKey: .prefailure) ?? false
        failed = try c.decodeIfPresent(String.self, forKey: .failed) ?? ""
    }
}
