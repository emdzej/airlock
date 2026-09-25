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
///
/// Threading: every mutable property below is only touched on
/// `stateQueue` (which is also the URLSession delegate queue), so
/// start/stop/reconnect/delegate callbacks never race. Owner-facing
/// callbacks are delivered on the main actor, in order, and never
/// after `stop()` has been processed.
final class EventStream: NSObject, @unchecked Sendable {
    typealias DrivesHandler = @MainActor @Sendable ([Drive]) -> Void
    typealias ConnectedHandler = @MainActor @Sendable () -> Void
    typealias DisconnectedHandler = @MainActor @Sendable (Error?) -> Void

    private let url: URL
    private let onDrives: DrivesHandler
    private let onConnected: ConnectedHandler
    private let onDisconnected: DisconnectedHandler

    /// Backoff resets to 1 s only after a connection has delivered at
    /// least one event AND stayed up this long. A server that accepts
    /// and immediately drops us keeps backing off instead of being
    /// hammered every second.
    private let healthyAfter: TimeInterval = 10

    private let stateQueue = DispatchQueue(label: "com.emdzej.airlock.companion.eventstream",
                                           qos: .utility)
    private let delegateQueue: OperationQueue

    // --- stateQueue-only state ---
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var backoff: TimeInterval = 1.0
    private var stopped = true
    private var reconnectWork: DispatchWorkItem?
    private var connectedAt: Date?
    private var receivedEvent = false
    /// Error to report instead of URLSession's generic "cancelled"
    /// when we reject a response ourselves (non-2xx status).
    private var responseError: Error?

    init(url: URL,
         onDrives: @escaping DrivesHandler,
         onConnected: @escaping ConnectedHandler,
         onDisconnected: @escaping DisconnectedHandler) {
        self.url = url
        self.onDrives = onDrives
        self.onConnected = onConnected
        self.onDisconnected = onDisconnected
        self.delegateQueue = OperationQueue()
        self.delegateQueue.maxConcurrentOperationCount = 1
        self.delegateQueue.underlyingQueue = stateQueue
        super.init()
    }

    func start() {
        stateQueue.async {
            guard self.stopped else { return }
            self.stopped = false
            self.backoff = 1.0
            self.openConnection()
        }
    }

    /// Tear down the stream. No further callbacks are delivered once
    /// this has run — in particular not the `cancelled` completion the
    /// teardown itself triggers.
    func stop() {
        stateQueue.async {
            self.stopped = true
            self.reconnectWork?.cancel()
            self.reconnectWork = nil
            self.closeConnection()
        }
    }

    // MARK: - Internal (stateQueue)

    private func openConnection() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        buffer.removeAll(keepingCapacity: true)
        connectedAt = nil
        receivedEvent = false
        responseError = nil

        let config = URLSessionConfiguration.default
        // No caching: SSE responses should never be cached.
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        // A long-lived stream shouldn't get idle-timed-out; heartbeat
        // (30 s) keeps traffic flowing.
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = .infinity

        var req = URLRequest(url: url)
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let s = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        session = s
        let t = s.dataTask(with: req)
        task = t
        t.resume()
    }

    private func closeConnection() {
        task?.cancel()
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }

    /// Schedule a reconnect after `backoff` seconds. Caps at 30 s.
    private func scheduleReconnect() {
        guard !stopped else { return }
        let delay = backoff
        backoff = min(backoff * 2, 30)
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.reconnectWork = nil
            self.openConnection()
        }
        reconnectWork = work
        stateQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Hop to main and deliver `body` unless the stream was stopped in
    /// the meantime. `stopped` is re-checked on stateQueue at send time;
    /// the owner (HostState) additionally drops callbacks from streams
    /// it has replaced, which covers anything already queued on main.
    private func deliver(_ body: @escaping @MainActor @Sendable () -> Void) {
        guard !stopped else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { body() }
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
                receivedEvent = true
                let drives = env.drives ?? []
                let cb = onDrives
                deliver { cb(drives) }
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
        guard dataTask === task, !stopped else {
            completionHandler(.cancel)
            return
        }
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            responseError = NSError(domain: "com.emdzej.airlock.companion.sse", code: code,
                                    userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"])
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
        connectedAt = Date()
        let cb = onConnected
        deliver { cb() }
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        guard dataTask === task, !stopped else { return }
        buffer.append(data)
        drainFrames()
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        // Completions from a stopped stream or a superseded task are
        // our own teardown (URLError.cancelled) — not worth reporting.
        guard task === self.task, !stopped else { return }

        if receivedEvent, let since = connectedAt,
           Date().timeIntervalSince(since) >= healthyAfter {
            backoff = 1.0
        }
        let reported = responseError ?? error
        let cb = onDisconnected
        deliver { cb(reported) }

        // Clean up this session; a new one is created on reconnect.
        closeConnection()
        scheduleReconnect()
    }
}
