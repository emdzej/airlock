import Foundation

/// Progress of a streamed operation.
public enum OpUpdate: Sendable, Equatable {
    /// Request-body bytes sent so far (flash uploads).
    case uploaded(sent: Int64, total: Int64)
    /// An event from the daemon's `text/event-stream` response.
    case event(OpEvent)
}

/// Runs one long airlockd operation whose response is a stream of
/// `data: {"stage": …}` frames (format, fsck, flash), optionally
/// streaming a request body from a file.
///
/// The stream finishes after the terminal `done` event and throws on an
/// `error` event, on a non-2xx response or when the response ends
/// without a terminal event. Cancelling the consuming task cancels the
/// request; airlockd still finishes (or cleanly fails) what it started.
final class OperationStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    // Only touched on the session's serial delegate queue.
    private var parser = SSEParser()
    private var status = 0
    private var errorBody = Data()
    private var finished = false
    private let continuation: AsyncThrowingStream<OpUpdate, Error>.Continuation

    private init(_ continuation: AsyncThrowingStream<OpUpdate, Error>.Continuation) {
        self.continuation = continuation
    }

    static func run(_ request: URLRequest, uploadFrom file: URL?) -> AsyncThrowingStream<OpUpdate, Error> {
        AsyncThrowingStream { continuation in
            let op = OperationStream(continuation)
            let config = URLSessionConfiguration.default
            config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            config.urlCache = nil
            // Idle timeout between bytes: mkfs on a big drive or the final
            // sync of a flash can go quiet for a while.
            config.timeoutIntervalForRequest = 900
            config.timeoutIntervalForResource = .infinity
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            // The session retains its delegate until invalidated.
            let session = URLSession(configuration: config, delegate: op, delegateQueue: queue)
            var req = request
            req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            let task = file.map { session.uploadTask(with: req, fromFile: $0) } ?? session.dataTask(with: req)
            continuation.onTermination = { _ in
                task.cancel()
                session.finishTasksAndInvalidate()
            }
            task.resume()
        }
    }

    private func finish(throwing error: Error? = nil) {
        guard !finished else { return }
        finished = true
        continuation.finish(throwing: error)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard !finished else { return }
        continuation.yield(.uploaded(sent: totalBytesSent, total: totalBytesExpectedToSend))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !finished else { return }
        // Errors before the stream starts (404, 409 busy, 403 read-only)
        // are plain JSON bodies.
        guard (200...299).contains(status) else {
            errorBody.append(data)
            return
        }
        for payload in parser.feed(data) {
            guard let ev = try? JSONDecoder().decode(OpEvent.self, from: Data(payload.utf8)) else { continue }
            continuation.yield(.event(ev))
            if ev.stage == "error" {
                finish(throwing: AirlockError(status: nil, message: ev.message ?? "operation failed"))
            } else if ev.stage == "done" {
                finish()
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate() }
        if let error { return finish(throwing: error) }
        if !(200...299).contains(status), let resp = task.response {
            do { try AirlockClient.check(resp, errorBody) } catch { return finish(throwing: error) }
        }
        finish(throwing: AirlockError(status: nil, message: "the operation ended without reporting a result"))
    }
}
