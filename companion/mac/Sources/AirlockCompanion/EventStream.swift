import Foundation

/// Consumes an airlock daemon's `/api/events` server-sent event
/// stream. Uses URLSessionDataDelegate rather than
/// `URLSession.bytes(for:).lines` because the latter buffers small
/// text/event-stream responses on macOS 13/14 (~8 KB coalesce window)
/// and delays delivery of tiny frames until either the buffer fills
/// or the daemon sends a heartbeat — user-visible as "app connected
/// but never sees any drives."
///
/// Delegate callbacks fire as soon as bytes arrive over the wire.
/// Frames are `data: <json>\n\n` per SSE spec; `: heartbeat\n\n`
/// comment lines keep NAT / proxy timers happy.
final class EventStream: NSObject {
    private let url: URL
    private let onDrives: ([Drive]) -> Void
    private let onConnected: () -> Void
    private let onDisconnected: (Error?) -> Void

    /// Delegate lives on this queue; UI callbacks bounce back to main.
    private let queue: OperationQueue

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var backoff: TimeInterval = 1.0
    private var stopped = false
    private var didFireConnected = false

    init(url: URL,
         onDrives: @escaping ([Drive]) -> Void,
         onConnected: @escaping () -> Void,
         onDisconnected: @escaping (Error?) -> Void) {
        self.url = url
        self.onDrives = onDrives
        self.onConnected = onConnected
        self.onDisconnected = onDisconnected
        self.queue = OperationQueue()
        self.queue.maxConcurrentOperationCount = 1
        self.queue.qualityOfService = .utility
        super.init()
    }

    func start() {
        stopped = false
        openConnection()
    }

    func stop() {
        stopped = true
        task?.cancel()
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }

    // MARK: - Internal

    private func openConnection() {
        buffer.removeAll(keepingCapacity: true)
        didFireConnected = false

        let config = URLSessionConfiguration.default
        // No caching: SSE responses should never be cached.
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        // A long-lived stream shouldn't get idle-timed-out; heartbeat
        // (30 s) keeps traffic flowing.
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = .infinity
        // Immediate data delivery — no coalescing on the client side.
        if #available(macOS 13.4, *) {
            config.httpAdditionalHeaders = ["Accept": "text/event-stream"]
        }

        var req = URLRequest(url: url)
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let s = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        session = s
        let t = s.dataTask(with: req)
        task = t
        t.resume()
    }

    /// Schedule a reconnect after `backoff` seconds. Caps at 30 s.
    private func scheduleReconnect() {
        guard !stopped else { return }
        let delay = backoff
        backoff = min(backoff * 2, 30)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped else { return }
            self.openConnection()
        }
    }

    /// Parse whatever complete `data: ...\n\n` frames are in `buffer`
    /// and drop them from the buffer. Partial frames stay for next chunk.
    private func drainFrames() {
        while let separator = buffer.range(of: Data("\n\n".utf8)) {
            let raw = buffer.subdata(in: 0..<separator.lowerBound)
            buffer.removeSubrange(0..<separator.upperBound)
            guard let frame = String(data: raw, encoding: .utf8) else { continue }

            var dataLines: [String] = []
            for line in frame.split(separator: "\n", omittingEmptySubsequences: false) {
                let s = String(line)
                if s.hasPrefix(":") { continue }
                if s.hasPrefix("data:") {
                    var payload = String(s.dropFirst("data:".count))
                    if payload.first == " " { payload = String(payload.dropFirst()) }
                    dataLines.append(payload)
                }
                // Other SSE fields (event:, id:, retry:) — none used here.
            }
            if dataLines.isEmpty { continue }
            handleEvent(dataLines.joined(separator: "\n"))
        }
    }

    private func handleEvent(_ json: String) {
        guard let data = json.data(using: .utf8) else { return }
        struct Envelope: Decodable {
            let type: String
            let drives: [Drive]?
        }
        do {
            let env = try JSONDecoder().decode(Envelope.self, from: data)
            switch env.type {
            case "drives":
                let drives = env.drives ?? []
                DispatchQueue.main.async { self.onDrives(drives) }
            default:
                break // forward-compat: ignore unknown types
            }
        } catch {
            FileHandle.standardError.write(Data(
                "sse: decode error: \(error) — frame: \(json.prefix(200))\n".utf8
            ))
        }
    }
}

extension EventStream: URLSessionDataDelegate {
    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
        DispatchQueue.main.async { [weak self] in
            self?.onConnected()
        }
        didFireConnected = true
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        buffer.append(data)
        // Reset backoff once we're actually receiving payload — not
        // just a TCP handshake.
        backoff = 1.0
        drainFrames()
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        DispatchQueue.main.async { [weak self] in
            self?.onDisconnected(error)
        }
        // Clean up this session; a new one is created on reconnect.
        self.task = nil
        self.session?.invalidateAndCancel()
        self.session = nil
        scheduleReconnect()
    }
}
