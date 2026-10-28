import AirlockKit
import SwiftUI

/// Drives one streamed airlockd operation (format, flash, fsck) for a
/// sheet: stage text, byte counters, the tool's output lines and the
/// outcome. Keeps the screen on while it runs, and asks iOS for
/// background time so a quick app switch doesn't cut the request off.
@MainActor
final class OpRunner: ObservableObject {
    enum Phase: Equatable { case idle, running, done, failed(String) }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var stage = ""
    @Published private(set) var log: [String] = []
    @Published private(set) var uploaded: Int64 = 0
    @Published private(set) var uploadTotal: Int64 = 0
    @Published private(set) var written: Int64 = 0
    @Published private(set) var exitCode: Int?

    private var task: Task<Void, Never>?

    var isRunning: Bool { phase == .running }

    func start(_ stream: @escaping () -> AsyncThrowingStream<OpUpdate, Error>,
               onFinish: @escaping @MainActor () -> Void = {}) {
        guard !isRunning else { return }
        phase = .running
        stage = "Starting…"
        log = []
        uploaded = 0; uploadTotal = 0; written = 0; exitCode = nil

        let awake = KeepAwake("airlock-operation")

        task = Task {
            do {
                for try await update in stream() {
                    apply(update)
                }
                phase = .done
            } catch is CancellationError {
                phase = .failed("Cancelled")
            } catch {
                phase = .failed(error.localizedDescription)
            }
            awake.end()
            onFinish()
        }
    }

    func cancel() { task?.cancel() }

    private func apply(_ update: OpUpdate) {
        switch update {
        case let .uploaded(sent, total):
            uploaded = sent
            uploadTotal = total
        case let .event(ev):
            if let w = ev.written { written = w }
            if let c = ev.exitCode { exitCode = c }
            switch ev.stage {
            case "line":
                if let m = ev.message { log.append(m) }
            case "done":
                stage = ev.message ?? "Done"
            default:
                stage = ev.message ?? ev.stage.capitalized
            }
        }
    }
}

/// Downloads a URL to a temporary file with progress, keeping the
/// server's suggested file name (Content-Disposition).
@MainActor
final class Downloader: NSObject, ObservableObject {
    @Published private(set) var received: Int64 = 0
    @Published private(set) var expected: Int64 = 0
    @Published private(set) var isRunning = false

    private var task: Task<URL, Error>?

    func download(_ url: URL) async throws -> URL {
        isRunning = true
        received = 0; expected = 0
        defer { isRunning = false }
        let delegate = DownloadDelegate { [weak self] got, total in
            Task { @MainActor in
                self?.received = got
                self?.expected = total
            }
        }
        let t = Task { () throws -> URL in
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 900
            config.timeoutIntervalForResource = .infinity
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            let (tmp, resp) = try await session.download(from: url)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let body = (try? Data(contentsOf: tmp)) ?? Data()
                struct ErrorBody: Decodable { let error: String }
                let msg = (try? JSONDecoder().decode(ErrorBody.self, from: body))?.error
                throw AirlockError(status: http.statusCode, message: msg ?? "download failed")
            }
            let name = resp.suggestedFilename ?? url.lastPathComponent
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dst = dir.appendingPathComponent(name)
            try FileManager.default.moveItem(at: tmp, to: dst)
            return dst
        }
        task = t
        return try await withTaskCancellationHandler {
            try await t.value
        } onCancel: {
            t.cancel()
        }
    }

    func cancel() { task?.cancel() }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    let progress: @Sendable (Int64, Int64) -> Void
    init(_ progress: @escaping @Sendable (Int64, Int64) -> Void) { self.progress = progress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, max(totalBytesExpectedToWrite, 0))
    }

    // Required by the protocol; the async download(from:) call returns the file.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}

/// The "type the word to confirm" guard the web UI puts on format and flash.
struct ConfirmWordField: View {
    let word: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("To confirm, type **\(word)**")
                .font(.footnote)
            TextField(word, text: $text)
                .plainInput()
                .font(.body.monospaced())
        }
    }
}

/// Progress section shared by the operation sheets.
struct OpProgressSection: View {
    @ObservedObject var runner: OpRunner
    /// Bytes the operation should end up writing, for a determinate bar.
    var expectedBytes: Int64 = 0

    var body: some View {
        if runner.phase != .idle {
            Section("Progress") {
                HStack {
                    switch runner.phase {
                    case .running: ProgressView().padding(.trailing, 4)
                    case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            .transition(.symbolEffect(.automatic))
                    case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    case .idle: EmptyView()
                    }
                    Text(statusText)
                        .foregroundStyle(isFailure ? .red : .primary)
                }
                if let fraction {
                    ProgressView(value: fraction)
                }
                if !stats.isEmpty {
                    Text(stats).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.default, value: stats)
                }
                if !runner.log.isEmpty {
                    ScrollView {
                        Text(runner.log.joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 240)
                }
            }
        }
    }

    private var isFailure: Bool {
        if case .failed = runner.phase { return true }
        return false
    }

    private var statusText: String {
        if case let .failed(msg) = runner.phase { return msg }
        return runner.stage
    }

    /// Upload or write progress, whichever is further along (compressed
    /// images write more than they upload), as the web UI does.
    private var fraction: Double? {
        if runner.phase == .done, runner.uploadTotal > 0 || runner.written > 0 { return 1 }
        let up = runner.uploadTotal > 0 ? Double(runner.uploaded) / Double(runner.uploadTotal) : 0
        let wr = expectedBytes > 0 ? Double(runner.written) / Double(expectedBytes) : 0
        let f = max(up, wr)
        return f > 0 ? min(f, 0.99) : nil
    }

    private var stats: String {
        var parts: [String] = []
        if runner.written > 0 { parts.append("written \(bytes(runner.written))") }
        if runner.uploadTotal > 0 { parts.append("uploaded \(bytes(runner.uploaded)) / \(bytes(runner.uploadTotal))") }
        if let c = runner.exitCode { parts.append("exit code \(c)") }
        return parts.joined(separator: " · ")
    }
}

func bytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}
