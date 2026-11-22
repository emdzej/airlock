import XCTest
@testable import AirlockKit

/// The demo airlock through the real client: same JSON, same streams.
final class DemoAirlockTests: XCTestCase {
    private let client = AirlockClient(baseURL: URL(string: "http://\(DemoAirlock.hostname)")!)

    override func setUp() {
        DemoAirlock.shared.queue.sync { DemoAirlock.shared.reset() }
    }

    func testDrivesDevicesAndFiles() async throws {
        let drives = try await client.drives()
        XCTAssertEqual(drives.map(\.shareName).sorted(), ["BACKUP", "EOS_DIGITAL", "FIRMWARE"])
        let devices = try await client.devices()
        XCTAssertEqual(devices.count, 5)
        XCTAssertEqual(devices.filter(\.optical).map(\.name), ["sr0"])
        XCTAssertFalse(devices.first { $0.name == "sr0" }!.isWritable, "no format or flash on a DVD writer")
        XCTAssertTrue(devices.first { $0.name == "sdd" }!.isEmpty)
        XCTAssertNil(devices.first { $0.name == "sdd" }!.health)
        XCTAssertEqual(devices.first { $0.name == "sdb" }!.health, .passed)
        let ssd = try await client.smart("sdb")
        XCTAssertEqual(ssd.protocol, "NVMe")
        XCTAssertEqual(ssd.attributes.count, 15)
        XCTAssertNotNil(ssd.checkedAt)
        let card = try await client.smart("sda")
        XCTAssertEqual(card.status, .unsupported)

        let photos = try await client.list("EOS_DIGITAL", path: "/DCIM/100CANON")
        XCTAssertEqual(photos.entries.count, 18)
        let (data, _) = try await AirlockNetwork.session.data(
            from: client.downloadURL("EOS_DIGITAL", path: "/DCIM/100CANON/IMG_4127.JPG"))
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8], "a JPEG")
    }

    func testFileChanges() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("demo-upload.txt")
        try Data("hello".utf8).write(to: file)
        try await client.makeDirectory("BACKUP", path: "/New")
        try await client.upload("BACKUP", path: "/New/hello.txt", from: file)
        try await client.move("BACKUP", from: "/New/hello.txt", to: "/hi.txt")
        var root = try await client.list("BACKUP", path: "/").entries.map(\.name)
        XCTAssertTrue(root.contains("hi.txt") && root.contains("New"))
        try await client.remove("BACKUP", path: "/hi.txt")
        root = try await client.list("BACKUP", path: "/").entries.map(\.name)
        XCTAssertFalse(root.contains("hi.txt"))

        do {
            try await client.makeDirectory("FIRMWARE", path: "/Nope")
            XCTFail("read-only drive accepted a change")
        } catch let e as AirlockError {
            XCTAssertEqual(e.status, 403)
        }
    }

    func testEjectAndMount() async throws {
        try await client.ejectDrive("BACKUP")
        var shares = try await client.drives().map(\.shareName)
        XCTAssertFalse(shares.contains("BACKUP"))
        try await client.mountPartition("sdb1")
        shares = try await client.drives().map(\.shareName)
        XCTAssertTrue(shares.contains("BACKUP"))
    }

    func testFormatAndFsckStream() async throws {
        var stages: [String] = []
        for try await update in client.format("sda", fs: .exfat, label: "DEMO") {
            if case let .event(e) = update { stages.append(e.stage) }
        }
        XCTAssertEqual(stages.first, "unmount")
        XCTAssertEqual(stages.last, "done")
        let shares = try await client.drives().map(\.shareName)
        XCTAssertTrue(shares.contains("DEMO"))

        var lines: [String] = []
        for try await update in client.fsck("sda1", repair: false) {
            if case let .event(e) = update, e.stage == "line", let m = e.message { lines.append(m) }
        }
        XCTAssertFalse(lines.isEmpty)
    }

    func testBurnStream() async throws {
        let disc = try await client.disc("sr0")
        XCTAssertTrue(disc.writable)
        XCTAssertEqual(disc.title, "Blank DVD+R")
        XCTAssertGreaterThan(disc.capacityBytes, 4_000_000_000)
        XCTAssertEqual(disc.speeds.map(\.label), ["4x", "8x", "16x"])

        let image = FileManager.default.temporaryDirectory.appendingPathComponent("demo.iso")
        try Data(repeating: 7, count: 64 << 10).write(to: image)
        var stages: [String] = []
        var lastBurn: OpEvent?
        for try await update in client.burn("sr0", image: image, compression: .none, verify: true, eject: false,
                                                  speed: disc.speeds[0].kbps) {
            guard case let .event(e) = update else { continue }
            if e.stage == "burn", let m = e.message { XCTAssertTrue(m.hasSuffix("at 4x"), m) }
            if stages.last != e.stage { stages.append(e.stage) }
            if e.stage == "burn", e.total != nil { lastBurn = e }
        }
        XCTAssertEqual(stages.first, "check")
        XCTAssertTrue(stages.contains("verify"))
        XCTAssertEqual(stages.last, "done")
        XCTAssertEqual(lastBurn?.written, lastBurn?.total)

        // The burned disc is mounted and can't be burned again.
        let shares = try await client.drives().map(\.shareName)
        XCTAssertTrue(shares.contains("DEMO_DISC"))
        let after = try await client.disc("sr0")
        XCTAssertFalse(after.writable)

        do {
            for try await _ in client.flash("sr0", image: image, compression: .none) {}
            XCTFail("flash accepted an optical drive")
        } catch let e as AirlockError {
            XCTAssertEqual(e.status, 400)
        }
    }
}
