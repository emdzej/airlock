import Foundation

/// A failed call to airlockd. Non-2xx responses carry `{"error": "..."}`
/// (e.g. 409 when a filesystem is busy); that message is surfaced in
/// preference to the bare status code.
public struct AirlockError: LocalizedError, Sendable {
    public let status: Int?
    public let message: String

    public init(status: Int?, message: String) {
        self.status = status
        self.message = message
    }

    public var errorDescription: String? {
        status.map { "\(message) (HTTP \($0))" } ?? message
    }
}

/// async/await client for one airlockd instance's HTTP API.
public struct AirlockClient: Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = AirlockNetwork.session) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - Drives

    public func drives() async throws -> [Drive] {
        try await get(url(["api/drives"]))
    }

    /// Unmount and withdraw one share on the daemon.
    public func ejectDrive(_ share: String) async throws {
        try await post(url(["api/drives", share, "eject"]))
    }

    /// Eject every drive on the host.
    public func ejectAll() async throws {
        try await post(url(["api/eject-all"]))
    }

    // MARK: - Devices and partitions

    public func devices() async throws -> [Device] {
        try await get(url(["api/devices"]))
    }

    /// Unmount every partition and power the device down for removal.
    public func ejectDevice(_ name: String) async throws {
        try await post(url(["api/devices", name, "eject"]))
    }

    /// Ask airlockd to mount (and share) a partition it isn't serving.
    public func mountPartition(_ name: String) async throws {
        try await post(url(["api/partitions", name, "mount"]))
    }

    public func setLabel(_ partition: String, to label: String) async throws {
        try await post(url(["api/partitions", partition, "label"]), json: ["label": label])
    }

    /// `GET /api/devices/{name}/dump`: a raw image of the whole device,
    /// compressed on the fly. Read-only.
    public func dumpURL(_ device: String, compression: Compression) -> URL {
        url(["api/devices", device, "dump"], query: [URLQueryItem(name: "compression", value: compression.rawValue)])
    }

    // MARK: - Files

    public func list(_ share: String, path: String) async throws -> Listing {
        try await get(url(["api/drives", share, "ls"], query: [URLQueryItem(name: "path", value: path)]))
    }

    public func downloadURL(_ share: String, path: String) -> URL {
        url(["api/drives", share, "dl"], query: [URLQueryItem(name: "path", value: path)])
    }

    public func makeDirectory(_ share: String, path: String) async throws {
        try await post(url(["api/drives", share, "mkdir"]), json: ["path": path])
    }

    public func move(_ share: String, from: String, to: String) async throws {
        try await post(url(["api/drives", share, "mv"]), json: ["from": from, "to": to])
    }

    public func remove(_ share: String, path: String) async throws {
        var req = URLRequest(url: url(["api/drives", share, "rm"], query: [URLQueryItem(name: "path", value: path)]))
        req.httpMethod = "DELETE"
        let (data, resp) = try await session.data(for: req)
        try Self.check(resp, data)
    }

    /// Upload a local file to `path` on the share, replacing any file
    /// there (atomically on the daemon). Streams from disk.
    public func upload(_ share: String, path: String, from file: URL,
                       progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws {
        var req = URLRequest(url: url(["api/drives", share, "upload"], query: [URLQueryItem(name: "path", value: path)]))
        req.httpMethod = "POST"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 600
        let delegate = progress.map(UploadProgress.init)
        let (data, resp) = try await session.upload(for: req, fromFile: file, delegate: delegate)
        try Self.check(resp, data)
    }

    // MARK: - Streamed operations (SSE responses)

    /// Wipe the device and create one partition with `fs`.
    public func format(_ device: String, fs: Filesystem, label: String) -> AsyncThrowingStream<OpUpdate, Error> {
        var req = URLRequest(url: url(["api/devices", device, "format"]))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(["fs": fs.rawValue, "label": label])
        return OperationStream.run(req, uploadFrom: nil)
    }

    public func fsck(_ partition: String, repair: Bool) -> AsyncThrowingStream<OpUpdate, Error> {
        var req = URLRequest(url: url(["api/partitions", partition, "fsck"],
                                      query: [URLQueryItem(name: "mode", value: repair ? "repair" : "check")]))
        req.httpMethod = "POST"
        return OperationStream.run(req, uploadFrom: nil)
    }

    /// Write an image file to the whole device. The body streams from
    /// disk; airlockd decompresses xz/gz itself.
    public func flash(_ device: String, image: URL, compression: Compression) -> AsyncThrowingStream<OpUpdate, Error> {
        var req = URLRequest(url: url(["api/devices", device, "flash"],
                                      query: [URLQueryItem(name: "compression", value: compression.rawValue)]))
        req.httpMethod = "POST"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        return OperationStream.run(req, uploadFrom: image)
    }

    // MARK: - Plumbing

    /// Path components are appended one by one so share names with
    /// spaces or slashes-in-labels are percent-encoded per segment.
    func url(_ components: [String], query: [URLQueryItem] = []) -> URL {
        var u = baseURL
        for c in components { u.appendPathComponent(c) }
        guard !query.isEmpty, var comps = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return u }
        comps.queryItems = query
        return comps.url ?? u
    }

    func get<T: Decodable>(_ url: URL) async throws -> T {
        let (data, resp) = try await session.data(from: url)
        try Self.check(resp, data)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom(Self.decodeDate)
        return try dec.decode(T.self, from: data)
    }

    func post(_ url: URL, json: [String: String]? = nil) async throws {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(json)
        }
        let (data, resp) = try await session.data(for: req)
        try Self.check(resp, data)
    }

    /// Go's time.Time is RFC 3339 with optional fractional seconds,
    /// which ISO8601DateFormatter only parses with the matching option.
    @Sendable static func decodeDate(_ decoder: Decoder) throws -> Date {
        let s = try decoder.singleValueContainer().decode(String.self)
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = frac.date(from: s) ?? ISO8601DateFormatter().date(from: s) { return d }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(s)"))
    }

    static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard !(200...299).contains(http.statusCode) else { return }
        struct ErrorBody: Decodable { let error: String }
        let msg = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
        throw AirlockError(status: http.statusCode,
                           message: msg ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
    }
}

/// Per-task upload progress for `upload(…)`.
private final class UploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    let report: @Sendable (Int64, Int64) -> Void
    init(_ report: @escaping @Sendable (Int64, Int64) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        report(totalBytesSent, totalBytesExpectedToSend)
    }
}

extension HostState {
    public var client: AirlockClient { AirlockClient(baseURL: baseURL) }
}
