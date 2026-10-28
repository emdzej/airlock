import Foundation

/// Identity of one shared drive as a File Provider domain. Encoded into
/// the domain identifier, so the extension can reach the drive without
/// any state shared with the app: `v1|<host>|<port>|<share>`.
public struct DriveDomainID: Hashable, Sendable {
    public let hostname: String
    public let port: Int
    public let share: String

    public init(hostname: String, port: Int, share: String) {
        self.hostname = hostname
        self.port = port
        self.share = share
    }

    public init?(_ raw: String) {
        let parts = raw.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[0] == "v1", let port = Int(parts[2]) else { return nil }
        self.init(hostname: parts[1], port: port, share: parts[3])
    }

    public var rawValue: String { "v1|\(hostname)|\(port)|\(share)" }

    public var baseURL: URL { URL(string: "http://\(hostname):\(port)")! }
}
