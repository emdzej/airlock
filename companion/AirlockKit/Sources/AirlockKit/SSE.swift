import Foundation

/// Incremental parser for `text/event-stream` bodies. Feed it chunks as
/// they arrive; it returns the `data:` payload of every frame completed
/// so far and keeps partial frames for the next chunk. Comment lines
/// (`: heartbeat`) and other fields (`event:`, `id:`, `retry:`) are
/// skipped — airlockd uses neither.
public struct SSEParser: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func feed(_ chunk: Data) -> [String] {
        buffer.append(chunk)
        var out: [String] = []
        while let separator = buffer.range(of: Data("\n\n".utf8)) {
            let raw = buffer.subdata(in: buffer.startIndex..<separator.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<separator.upperBound)
            guard let frame = String(data: raw, encoding: .utf8) else { continue }

            var dataLines: [String] = []
            for line in frame.split(separator: "\n", omittingEmptySubsequences: false) {
                guard line.hasPrefix("data:") else { continue }
                var payload = line.dropFirst("data:".count)
                if payload.first == " " { payload = payload.dropFirst() }
                dataLines.append(String(payload))
            }
            if !dataLines.isEmpty { out.append(dataLines.joined(separator: "\n")) }
        }
        return out
    }

    public mutating func reset() { buffer.removeAll(keepingCapacity: true) }
}
