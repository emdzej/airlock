import Foundation

/// Consumes an airlock daemon's `/api/events` server-sent event
/// stream. Frame format is per SSE spec — `data: <json>\n\n` — with
/// occasional `: heartbeat\n\n` comment lines to keep the connection
/// alive through NATs. Reconnects with exponential backoff on any
/// disconnect.
///
/// The stream delivers `{"type":"drives", "drives":[...]}` payloads.
/// Other types may appear in the future; unknown types are ignored
/// so an older client keeps working against a newer daemon.
final class EventStream {
    private let url: URL
    private let onDrives: ([Drive]) -> Void
    private let onConnected: () -> Void
    private let onDisconnected: (Error?) -> Void
    private var task: Task<Void, Never>?

    init(url: URL,
         onDrives: @escaping ([Drive]) -> Void,
         onConnected: @escaping () -> Void,
         onDisconnected: @escaping (Error?) -> Void) {
        self.url = url
        self.onDrives = onDrives
        self.onConnected = onConnected
        self.onDisconnected = onDisconnected
    }

    /// Start (or restart) the stream. Idempotent — cancels any prior
    /// task first.
    func start() {
        task?.cancel()
        task = Task { [weak self] in
            await self?.loop()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func loop() async {
        // Exponential backoff caps at 30 s. Reset to 1 s after a
        // clean read that produced at least one event (i.e. the
        // server is really reachable, not just accepting sockets).
        var backoff: TimeInterval = 1.0
        while !Task.isCancelled {
            let readOne: Bool
            do {
                readOne = try await streamOnce()
                if readOne { backoff = 1.0 }
            } catch {
                await MainActor.run { self.onDisconnected(error) }
            }
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            backoff = min(backoff * 2, 30)
        }
    }

    /// Runs one connect-and-consume cycle. Returns whether at least
    /// one data event was received (used to reset backoff).
    /// Throws on transport error or non-2xx response.
    private func streamOnce() async throws -> Bool {
        var req = URLRequest(url: url)
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 60 // heartbeat cadence is 30s; give it slack
        let session = URLSession(configuration: .ephemeral)
        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            throw NSError(domain: "sse",
                          code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        await MainActor.run { self.onConnected() }

        // SSE frame boundary is a blank line. Each frame may contain
        // multiple `data:` lines (concatenated with newlines) plus
        // comment lines starting with `:` we ignore.
        var received = false
        var dataBuffer = ""
        for try await line in bytes.lines {
            if Task.isCancelled { break }
            if line.isEmpty {
                if !dataBuffer.isEmpty {
                    handleEvent(dataBuffer)
                    dataBuffer = ""
                    received = true
                }
                continue
            }
            if line.hasPrefix(":") {
                continue // comment (heartbeat)
            }
            if line.hasPrefix("data:") {
                var payload = String(line.dropFirst("data:".count))
                if payload.first == " " { payload = String(payload.dropFirst()) }
                if !dataBuffer.isEmpty { dataBuffer.append("\n") }
                dataBuffer.append(payload)
            }
            // Other SSE fields (event:, id:, retry:) — none used here.
        }
        return received
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
                Task { @MainActor in self.onDrives(drives) }
            default:
                break // forward-compat: ignore unknown types
            }
        } catch {
            // Malformed event — daemon shouldn't send these. Log to
            // stderr; keep the connection alive.
            FileHandle.standardError.write(Data("sse: decode error: \(error)\n".utf8))
        }
    }
}
