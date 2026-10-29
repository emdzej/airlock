import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Every session that talks to an airlock is configured here, so the
/// demo airlock can answer its requests in-process.
public enum AirlockNetwork {
    /// `.default`, with the demo airlock's protocol first. It only
    /// claims requests for `DemoAirlock.hostname`.
    public static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.protocolClasses = [DemoURLProtocol.self] + (config.protocolClasses ?? [])
        return config
    }

    /// For one-off requests (`AirlockClient`'s default).
    public static let session = URLSession(configuration: configuration())
}

/// An airlock that exists only inside the app: drives, devices and
/// files in memory, served through `DemoURLProtocol` with the same JSON
/// and event streams as airlockd. For trying the app (and App Review)
/// without a Raspberry Pi. Nothing it does reaches the network.
public final class DemoAirlock: @unchecked Sendable {
    /// Reserved name (RFC 6761 `.invalid`): never resolves, so a demo
    /// request can't leave the device even if the protocol were missing.
    public static let hostname = "demo.airlock.invalid"
    public static let serviceName = "Demo Airlock"

    static let shared = DemoAirlock()

    /// All state and every protocol callback run on this queue.
    let queue = DispatchQueue(label: "pl.emdzej.airlock.demo")

    private var devices: [DemoDevice] = []
    /// Partition name → file tree root.
    private var files: [String: DemoNode] = [:]
    private var subscribers: [ObjectIdentifier: DemoURLProtocol] = [:]

    private init() { reset() }

    /// Back to the starting set of drives and files.
    func reset() {
        devices = DemoDevice.seed()
        files = [:]
        for device in devices {
            for p in device.partitions { files[p.name] = DemoNode.seed(for: p.name) }
        }
    }

    // MARK: - Events

    func subscribe(_ p: DemoURLProtocol) {
        subscribers[ObjectIdentifier(p)] = p
        p.sendEvent(["type": "drives", "drives": drivesJSON()])
    }

    func unsubscribe(_ p: DemoURLProtocol) {
        subscribers[ObjectIdentifier(p)] = nil
    }

    private func changed() {
        let frame: [String: Any] = ["type": "drives", "drives": drivesJSON()]
        for p in subscribers.values { p.sendEvent(frame) }
    }

    // MARK: - JSON

    private func drivesJSON() -> [[String: Any]] {
        devices.flatMap { device in
            device.partitions.filter(\.shared).map { p in
                [
                    "share_name": p.shareName, "label": p.label, "display_name": p.shareName,
                    "fs_type": p.fs, "size_bytes": p.size, "size_human": human(p.size),
                    "read_only": device.readOnly, "mount_point": "/mnt/airlock/\(p.shareName)",
                    "kernel": p.name, "parent": device.name, "ejecting": false,
                ] as [String: Any]
            }
        }
    }

    private func devicesJSON() -> [[String: Any]] {
        devices.map { d in
            [
                "name": d.name, "path": "/dev/\(d.name)", "model": d.model, "vendor": d.vendor,
                "serial": d.serial, "size_bytes": d.size, "size_human": human(d.size),
                "transport": "usb", "pt_type": d.ptType, "read_only": d.readOnly,
                "any_partition_read_only": d.readOnly, "suggested_fs": d.suggestedFS,
                "partitions": d.partitions.map { p in
                    [
                        "name": p.name, "size_bytes": p.size, "size_human": human(p.size),
                        "fs_type": p.fs, "label": p.label, "uuid": p.uuid,
                        "mount_point": p.shared ? "/mnt/airlock/\(p.shareName)" : "",
                        "is_airlock": p.shared, "share_name": p.shared ? p.shareName as Any : NSNull(),
                        "can_relabel": !d.readOnly, "max_label_len": p.fs == "ntfs" ? 32 : 11,
                        "can_mount": !p.shared, "can_fsck": true,
                    ] as [String: Any]
                },
            ] as [String: Any]
        }
    }

    // MARK: - Routing

    /// Handles one request. Errors are airlockd's `{"error": …}` bodies.
    func handle(_ p: DemoURLProtocol, method: String, path: [String], query: [String: String], body: Data) {
        guard path.first == "api", path.count >= 2 else { return p.fail(404, "not found") }
        let route = Array(path.dropFirst())
        switch (method, route.count, route[0]) {
        case ("GET", 1, "drives"):
            p.respondJSON(drivesJSON())
        case ("GET", 1, "devices"):
            p.respondJSON(devicesJSON())
        case ("GET", 1, "events"):
            p.startStream()
            subscribe(p)
        case ("POST", 1, "eject-all"):
            for i in devices.indices {
                for j in devices[i].partitions.indices { devices[i].partitions[j].shared = false }
            }
            changed()
            p.respondJSON(["ok": true])
        case (_, 3, "drives"):
            guard let (di, pi) = locate(share: route[1]) else { return p.fail(404, "no such share") }
            driveAction(p, method: method, action: route[2], di: di, pi: pi, query: query, body: body)
        case (_, 3, "devices"):
            deviceAction(p, method: method, name: route[1], action: route[2], query: query, body: body)
        case ("POST", 3, "partitions"):
            guard let (di, pi) = locate(partition: route[1]) else { return p.fail(404, "no such partition") }
            partitionAction(p, action: route[2], di: di, pi: pi, query: query, body: body)
        default:
            p.fail(404, "not found")
        }
    }

    private func deviceAction(_ p: DemoURLProtocol, method: String, name: String, action: String,
                              query: [String: String], body: Data) {
        guard let di = devices.firstIndex(where: { $0.name == name }) else { return p.fail(404, "no such device") }
        let d = devices[di]
        switch (method, action) {
        case ("POST", "eject"):
            devices[di].size = 0
            devices[di].partitions = []
            devices[di].ptType = ""
            changed()
            p.respondJSON(["ok": true])
        case ("GET", "dump"):
            guard d.size > 0 else { return p.fail(404, "no medium") }
            let ext = ["xz": ".img.xz", "gz": ".img.gz"][query["compression"] ?? ""] ?? ".img"
            p.respond(Data(repeating: 0, count: 2 << 20), type: "application/octet-stream",
                      filename: "\(d.vendor)-\(d.model)\(ext)".replacingOccurrences(of: " ", with: "-"))
        case ("POST", "format"), ("POST", "flash"):
            guard d.size > 0 else { return p.fail(404, "no medium") }
            guard !d.readOnly else { return p.fail(403, "the device is write-protected") }
            if action == "flash" { return flash(p, di: di, bytes: Int64(body.count)) }
            let req = (try? JSONSerialization.jsonObject(with: body)) as? [String: String] ?? [:]
            format(p, di: di, fs: req["fs"] ?? "vfat", label: req["label"] ?? "")
        default:
            p.fail(404, "not found")
        }
    }

    private func locate(share: String) -> (Int, Int)? {
        for (di, d) in devices.enumerated() {
            if let pi = d.partitions.firstIndex(where: { $0.shared && $0.shareName == share }) { return (di, pi) }
        }
        return nil
    }

    private func locate(partition: String) -> (Int, Int)? {
        for (di, d) in devices.enumerated() {
            if let pi = d.partitions.firstIndex(where: { $0.name == partition }) { return (di, pi) }
        }
        return nil
    }

    // MARK: - Drives and files

    private func driveAction(_ p: DemoURLProtocol, method: String, action: String, di: Int, pi: Int,
                             query: [String: String], body: Data) {
        let part = devices[di].partitions[pi]
        let root = files[part.name] ?? DemoNode(name: "", isDir: true)
        files[part.name] = root
        let readOnly = devices[di].readOnly
        let path = query["path"] ?? "/"

        switch (method, action) {
        case ("POST", "eject"):
            devices[di].partitions[pi].shared = false
            changed()
            p.respondJSON(["ok": true])
        case ("GET", "ls"):
            guard let dir = root.find(path), dir.isDir else { return p.fail(404, "no such folder") }
            let entries = dir.children.values.sorted { $0.name < $1.name }.map { n in
                [
                    "name": n.name, "is_dir": n.isDir, "size": n.isDir ? 0 : n.size,
                    "modified": ISO8601DateFormatter().string(from: n.modified),
                ] as [String: Any]
            }
            p.respondJSON(["path": path, "entries": entries])
        case ("GET", "dl"):
            guard let file = root.find(path), !file.isDir else { return p.fail(404, "no such file") }
            p.respond(file.contents(), type: "application/octet-stream", filename: file.name)
        case ("POST", "mkdir"), ("POST", "mv"), ("DELETE", "rm"), ("POST", "upload"):
            guard !readOnly else { return p.fail(403, "the drive is read-only") }
            let req = (try? JSONSerialization.jsonObject(with: body)) as? [String: String] ?? [:]
            switch action {
            case "mkdir":
                guard let target = req["path"], root.insert(DemoNode(name: "", isDir: true), at: target) else {
                    return p.fail(409, "already exists")
                }
            case "mv":
                guard let from = req["from"], let to = req["to"], let node = root.remove(from) else {
                    return p.fail(404, "no such file")
                }
                guard root.insert(node, at: to) else {
                    _ = root.insert(node, at: from)
                    return p.fail(409, "already exists")
                }
            case "rm":
                guard root.remove(path) != nil else { return p.fail(404, "no such file") }
            default: // upload: replaces what's there, like airlockd
                _ = root.remove(path)
                let node = DemoNode(name: "", isDir: false)
                node.data = body
                node.size = Int64(body.count)
                guard root.insert(node, at: path) else { return p.fail(404, "no such folder") }
            }
            p.respondJSON(["ok": true])
        default:
            p.fail(404, "not found")
        }
    }

    // MARK: - Partitions

    private func partitionAction(_ p: DemoURLProtocol, action: String, di: Int, pi: Int,
                                 query: [String: String], body: Data) {
        switch action {
        case "mount":
            devices[di].partitions[pi].shared = true
            changed()
            p.respondJSON(["ok": true])
        case "label":
            guard !devices[di].readOnly else { return p.fail(403, "the device is write-protected") }
            let req = (try? JSONSerialization.jsonObject(with: body)) as? [String: String] ?? [:]
            devices[di].partitions[pi].label = req["label"] ?? ""
            changed()
            p.respondJSON(["ok": true])
        case "fsck":
            let part = devices[di].partitions[pi]
            let repair = query["mode"] == "repair"
            let tool = ["vfat": "fsck.fat", "exfat": "fsck.exfat", "ntfs": "ntfsfix", "ext4": "e2fsck"][part.fs] ?? "fsck"
            let files = self.files[part.name]?.count() ?? (dirs: 0, files: 0)
            p.startStream()
            run(p, [
                (0.3, ["stage": "unmount", "message": "Unmounting \(part.shareName)…"]),
                (0.5, ["stage": "line", "message": "\(tool) (demo)"]),
                (0.6, ["stage": "line", "message": "/dev/\(part.name): checking the volume…"]),
                (0.8, ["stage": "line", "message": "/dev/\(part.name): \(repair ? "repaired, " : "")clean. directories \(files.dirs), files \(files.files)"]),
                (0.3, ["stage": "done", "message": "No errors found", "exit_code": 0]),
            ])
        default:
            p.fail(404, "not found")
        }
    }

    // MARK: - Long operations

    private func format(_ p: DemoURLProtocol, di: Int, fs: String, label: String) {
        let name = devices[di].name
        let dev = "/dev/\(name)"
        p.startStream()
        run(p, [
            (0.4, ["stage": "unmount", "message": "unmounting existing partitions on \(dev)"]),
            (0.6, ["stage": "wipe", "message": "wiping filesystem signatures"]),
            (0.6, ["stage": "partition", "message": "creating partition table"]),
            (0.5, ["stage": "rescan", "message": "waiting for kernel + udev to catch up"]),
            (1.2, ["stage": "mkfs", "message": "creating \(fs) filesystem on \(dev)1"]),
            (0.4, ["stage": "rescan", "message": "triggering udev re-scan"]),
        ]) { [self] in
            let part = DemoPartition(name: "\(name)1", size: devices[di].size - 1 << 20, fs: fs,
                                     label: label.isEmpty ? "UNTITLED" : label, uuid: DemoPartition.newUUID())
            devices[di].partitions = [part]
            devices[di].ptType = "dos"
            files[part.name] = DemoNode(name: "", isDir: true)
            changed()
            return ["stage": "done", "message": "format complete — new share should appear shortly"]
        }
    }

    private func flash(_ p: DemoURLProtocol, di: Int, bytes: Int64) {
        let name = devices[di].name
        let total = max(bytes, 1)
        p.startStream()
        var steps: [(TimeInterval, [String: Any])] = [
            (0.4, ["stage": "unmount", "message": "unmounting existing partitions on /dev/\(name)"]),
            (0.3, ["stage": "write", "message": "writing to /dev/\(name)"]),
        ]
        for i in 1...10 { steps.append((0.25, ["stage": "write", "written": total * Int64(i) / 10])) }
        steps.append((0.6, ["stage": "sync", "message": "flushing kernel buffers"]))
        steps.append((0.4, ["stage": "rescan", "message": "re-reading partition table"]))
        run(p, steps) { [self] in
            // What a Raspberry Pi OS image leaves on a card.
            devices[di].partitions = [
                DemoPartition(name: "\(name)1", size: 512 << 20, fs: "vfat", label: "bootfs", uuid: "4B2D-7E10"),
                DemoPartition(name: "\(name)2", size: 5 << 30, fs: "ext4", label: "rootfs",
                              uuid: DemoPartition.newUUID()),
            ]
            for part in devices[di].partitions { files[part.name] = DemoNode.seed(for: part.label) }
            devices[di].ptType = "dos"
            changed()
            return ["stage": "done", "message": "flash complete — wrote \(bytes) bytes"]
        }
    }

    /// Sends events with delays, then the final one (which may change
    /// state), unless the request was cancelled.
    private func run(_ p: DemoURLProtocol, _ steps: [(TimeInterval, [String: Any])],
                     final: (() -> [String: Any])? = nil) {
        var remaining = steps
        func next() {
            guard !p.stopped else { return }
            if remaining.isEmpty {
                if let final { p.sendEvent(final()) }
                p.finish()
                return
            }
            let (delay, event) = remaining.removeFirst()
            queue.asyncAfter(deadline: .now() + delay) {
                guard !p.stopped else { return }
                p.sendEvent(event)
                next()
            }
        }
        next()
    }
}

func human(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
}

// MARK: - Model

struct DemoPartition {
    var name: String
    var size: Int64
    var fs: String
    var label: String
    var uuid: String
    var shared = true

    var shareName: String { label.isEmpty ? name : label }

    static func newUUID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))
    }
}

struct DemoDevice {
    var name: String
    var vendor: String
    var model: String
    var serial: String
    var size: Int64
    var ptType: String
    var readOnly: Bool
    var suggestedFS: String
    var partitions: [DemoPartition]

    static func seed() -> [DemoDevice] {
        [
            DemoDevice(name: "sda", vendor: "SanDisk", model: "Extreme PRO", serial: "AA0123456789",
                       size: 128_043_712_512, ptType: "dos", readOnly: false, suggestedFS: "exfat",
                       partitions: [DemoPartition(name: "sda1", size: 127_865_454_592, fs: "exfat",
                                                  label: "EOS_DIGITAL", uuid: "6A1F-22C0")]),
            DemoDevice(name: "sdb", vendor: "Samsung", model: "Portable SSD T7", serial: "S5SXNG0R401234",
                       size: 1_000_204_886_016, ptType: "gpt", readOnly: false, suggestedFS: "ntfs",
                       partitions: [DemoPartition(name: "sdb1", size: 1_000_202_043_392, fs: "ntfs",
                                                  label: "BACKUP", uuid: "4E21C7A93B8D1F05")]),
            DemoDevice(name: "sdc", vendor: "Kingston", model: "DataTraveler 3.0", serial: "60A44C3FAE1234",
                       size: 7_998_537_728, ptType: "dos", readOnly: true, suggestedFS: "vfat",
                       partitions: [DemoPartition(name: "sdc1", size: 7_985_954_816, fs: "vfat",
                                                  label: "FIRMWARE", uuid: "1B2C-3D4E")]),
            DemoDevice(name: "sdd", vendor: "Generic", model: "SD/MMC Reader", serial: "000000002960",
                       size: 0, ptType: "", readOnly: false, suggestedFS: "vfat", partitions: []),
        ]
    }
}

/// A file or folder. Seeded files make their contents on first read:
/// photos are rendered, text is text.
final class DemoNode {
    var name: String
    let isDir: Bool
    var children: [String: DemoNode] = [:]
    var data: Data?
    var size: Int64 = 0
    var modified = Date()
    var hue: Double = 0.4

    init(name: String, isDir: Bool) {
        self.name = name
        self.isDir = isDir
    }

    func find(_ path: String) -> DemoNode? {
        var node: DemoNode? = self
        for part in path.split(separator: "/") { node = node?.children[String(part)] }
        return node
    }

    /// Puts node at path (its name becomes the last component). False
    /// if the parent is missing or the name is taken.
    func insert(_ node: DemoNode, at path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        guard let last = parts.last, let parent = find(parts.dropLast().joined(separator: "/")), parent.isDir,
              parent.children[last] == nil else { return false }
        node.name = last
        node.modified = Date()
        parent.children[last] = node
        return true
    }

    func remove(_ path: String) -> DemoNode? {
        let parts = path.split(separator: "/").map(String.init)
        guard let last = parts.last, let parent = find(parts.dropLast().joined(separator: "/")) else { return nil }
        return parent.children.removeValue(forKey: last)
    }

    func count() -> (dirs: Int, files: Int) {
        children.values.reduce((0, 0)) { acc, n in
            let sub = n.isDir ? n.count() : (0, 0)
            return (acc.0 + sub.0 + (n.isDir ? 1 : 0), acc.1 + sub.1 + (n.isDir ? 0 : 1))
        }
    }

    func contents() -> Data {
        if let data { return data }
        let ext = (name as NSString).pathExtension.lowercased()
        let made = ["jpg", "jpeg"].contains(ext) ? DemoNode.photo(hue: hue) : Data(DemoNode.text(name).utf8)
        data = made
        size = Int64(made.count)
        return made
    }

    private func add(_ child: DemoNode) {
        children[child.name] = child
    }

    private static func dir(_ name: String, _ children: [DemoNode], daysAgo: Double) -> DemoNode {
        let d = DemoNode(name: name, isDir: true)
        for c in children { d.add(c) }
        d.modified = Date(timeIntervalSinceNow: -daysAgo * 86_400)
        return d
    }

    private static func file(_ name: String, size: Int64, minutesAgo: Double, hue: Double = 0.4) -> DemoNode {
        let f = DemoNode(name: name, isDir: false)
        f.size = size
        f.hue = hue
        f.modified = Date(timeIntervalSinceNow: -minutesAgo * 60)
        return f
    }

    static func seed(for partition: String) -> DemoNode {
        let root = DemoNode(name: "", isDir: true)
        switch partition {
        case "sda1", "EOS_DIGITAL":
            var photos: [DemoNode] = []
            for i in 0..<18 {
                let name = String(format: "IMG_%04d.JPG", 4127 + i)
                let size: Int64 = 6_200_000 + Int64(i * 173_421 % 900_000)
                let hue = 0.28 + Double(i % 6) * 0.06
                photos.append(file(name, size: size, minutesAgo: Double(190 - i * 9), hue: hue))
            }
            root.add(dir("DCIM", [dir("100CANON", photos, daysAgo: 0.1)], daysAgo: 0.1))
            root.add(dir("MISC", [], daysAgo: 6))
        case "sdb1", "BACKUP":
            root.add(dir("Clients", [file("Invoice 2026-10.pdf", size: 184_220, minutesAgo: 2_900)], daysAgo: 2))
            root.add(dir("Photos 2026", [], daysAgo: 0.5))
            root.add(file("restore.md", size: 4_210, minutesAgo: 52_000))
        case "sdc1", "FIRMWARE":
            root.add(file("printer-fw-4.2.1.bin", size: 18_874_368, minutesAgo: 300_000))
            root.add(file("README.txt", size: 1_204, minutesAgo: 300_000))
        case "bootfs":
            root.add(file("config.txt", size: 1_220, minutesAgo: 1))
            root.add(file("cmdline.txt", size: 160, minutesAgo: 1))
        default:
            break
        }
        return root
    }

    static func text(_ name: String) -> String {
        switch name {
        case "README.txt":
            return "Printer firmware 4.2.1\n\nCopy printer-fw-4.2.1.bin to the printer's USB port and hold Reset for 5 seconds.\n"
        case "restore.md":
            return "# Restore\n\nThis is the demo airlock: every file here lives in the app's memory.\n"
        case "config.txt":
            return "# Raspberry Pi config (demo)\narm_64bit=1\ndtoverlay=vc4-kms-v3d\n"
        default:
            return "Demo file \(name) on the demo airlock.\n"
        }
    }

    /// A small JPEG: a soft gradient in the photo's hue, with a hatch.
    static func photo(hue: Double) -> Data {
        let w = 1200, h = 800
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return Data() }
        func color(_ s: Double, _ b: Double) -> CGColor {
            // HSB → RGB, enough for a gradient.
            let i = Int(hue * 6) % 6
            let f = hue * 6 - Double(Int(hue * 6))
            let p = b * (1 - s)
            let q = b * (1 - s * f)
            let t = b * (1 - s * (1 - f))
            let rgb: (Double, Double, Double)
            switch i {
            case 0: rgb = (b, t, p)
            case 1: rgb = (q, b, p)
            case 2: rgb = (p, b, t)
            case 3: rgb = (p, q, b)
            case 4: rgb = (t, p, b)
            default: rgb = (b, p, q)
            }
            return CGColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        }
        let gradient = CGGradient(colorsSpace: nil, colors: [color(0.55, 0.35), color(0.35, 0.85)] as CFArray,
                                  locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: w, y: h), options: [])
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.35))
        ctx.setLineWidth(18)
        let c = CGPoint(x: w / 2, y: h / 2)
        ctx.strokeEllipse(in: CGRect(x: c.x - 220, y: c.y - 220, width: 440, height: 440))
        ctx.strokeEllipse(in: CGRect(x: c.x - 150, y: c.y - 150, width: 300, height: 300))
        for a in stride(from: 0.0, to: Double.pi * 2, by: Double.pi / 2) {
            ctx.move(to: c)
            ctx.addLine(to: CGPoint(x: c.x + cos(a + .pi / 4) * 150, y: c.y + sin(a + .pi / 4) * 150))
        }
        ctx.strokePath()
        guard let image = ctx.makeImage() else { return Data() }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            return Data()
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}

// MARK: - URL protocol

/// Answers requests for `DemoAirlock.hostname` from `DemoAirlock`.
/// URLSession expects client callbacks on the thread that started the
/// load, so each one is hopped back there.
final class DemoURLProtocol: URLProtocol, @unchecked Sendable {
    private var clientThread: Thread?
    private(set) var stopped = false
    private var keepalive: DispatchSourceTimer?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == DemoAirlock.hostname
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        clientThread = Thread.current
        let request = self.request
        let body = Self.body(of: request)
        let demo = DemoAirlock.shared
        demo.queue.async { [self] in
            guard let url = request.url, let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return fail(400, "bad request")
            }
            let path = url.pathComponents.filter { $0 != "/" }
            var query: [String: String] = [:]
            for item in comps.queryItems ?? [] { query[item.name] = item.value ?? "" }
            demo.handle(self, method: request.httpMethod ?? "GET", path: path, query: query, body: body)
        }
    }

    override func stopLoading() {
        let demo = DemoAirlock.shared
        demo.queue.async { [self] in
            stopped = true
            keepalive?.cancel()
            demo.unsubscribe(self)
        }
    }

    /// Request bodies arrive as a stream for uploads.
    private static func body(of request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    // MARK: Responses (called on DemoAirlock.queue)

    func respondJSON(_ object: Any) {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        respond(data, type: "application/json")
    }

    func respond(_ data: Data, type: String, filename: String? = nil, status: Int = 200) {
        var headers = ["Content-Type": type, "Content-Length": "\(data.count)"]
        if let filename { headers["Content-Disposition"] = "attachment; filename=\"\(filename)\"" }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: headers)!
        onClient { [self] in
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    func fail(_ status: Int, _ message: String) {
        let data = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data()
        respond(data, type: "application/json", status: status)
    }

    /// Opens a `text/event-stream` response, kept alive until finished or
    /// cancelled.
    func startStream() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        onClient { [self] in client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
        let timer = DispatchSource.makeTimerSource(queue: DemoAirlock.shared.queue)
        timer.schedule(deadline: .now() + 20, repeating: 20)
        timer.setEventHandler { [weak self] in self?.send(Data(": keepalive\n\n".utf8)) }
        timer.resume()
        keepalive = timer
    }

    func sendEvent(_ object: [String: Any]) {
        guard let json = try? JSONSerialization.data(withJSONObject: object) else { return }
        send(Data("data: ".utf8) + json + Data("\n\n".utf8))
    }

    func finish() {
        keepalive?.cancel()
        onClient { [self] in client?.urlProtocolDidFinishLoading(self) }
    }

    private func send(_ data: Data) {
        guard !stopped else { return }
        onClient { [self] in client?.urlProtocol(self, didLoad: data) }
    }

    private func onClient(_ block: @escaping () -> Void) {
        guard let thread = clientThread else { return block() }
        perform(#selector(runBlock(_:)), on: thread, with: BlockBox(block), waitUntilDone: false,
                modes: [RunLoop.Mode.default.rawValue])
    }

    @objc private func runBlock(_ box: BlockBox) { box.block() }
}

private final class BlockBox: NSObject {
    let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
}
