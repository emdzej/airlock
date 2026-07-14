import Foundation

/// One discovered airlock host. Immutable identity (`serviceName`,
/// `hostname`, `port`) with mutable observed state (drives list,
/// last error). Not thread-safe by design — mutations go through the
/// completion handler which we always dispatch to main.
final class HostState {
    let serviceName: String
    let hostname: String
    let port: Int

    private(set) var drives: [Drive] = []
    private(set) var lastError: String?
    private(set) var isReachable: Bool = false

    init(serviceName: String, hostname: String, port: Int) {
        self.serviceName = serviceName
        self.hostname = hostname
        self.port = port
    }

    var baseURL: URL {
        URL(string: "http://\(hostname):\(port)")!
    }

    /// Fetches `/api/drives`. Updates `drives`, `lastError`, and
    /// `isReachable` on the main queue before invoking `completion`.
    func refresh(completion: @escaping () -> Void) {
        let url = baseURL.appendingPathComponent("api/drives")
        var req = URLRequest(url: url)
        req.timeoutInterval = 3.0
        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            guard let self else { return }
            DispatchQueue.main.async {
                defer { completion() }
                if let err {
                    self.isReachable = false
                    self.lastError = err.localizedDescription
                    return
                }
                guard let data else {
                    self.isReachable = false
                    self.lastError = "empty response"
                    return
                }
                do {
                    let list = try JSONDecoder().decode([Drive].self, from: data)
                    self.drives = list
                    self.isReachable = true
                    self.lastError = nil
                } catch {
                    self.isReachable = false
                    self.lastError = "decode: \(error.localizedDescription)"
                }
            }
        }.resume()
    }
}

/// Wire representation of a mounted drive — mirrors the JSON payload
/// airlockd's `internal/api/server.go` returns from `GET /api/drives`.
struct Drive: Codable, Equatable {
    let shareName: String
    let label: String
    let displayName: String
    let fsType: String
    let sizeBytes: Int64
    let sizeHuman: String
    let readOnly: Bool
    let mountPoint: String
    let kernel: String
    let parent: String

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
    }
}
