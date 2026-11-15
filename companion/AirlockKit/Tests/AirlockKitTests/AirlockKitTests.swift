import XCTest
@testable import AirlockKit

final class AirlockKitTests: XCTestCase {
    func testDriveDecodesWithoutEjecting() throws {
        let json = #"""
        {"share_name":"USB_STICK","label":"USB STICK","display_name":"USB STICK","fs_type":"vfat",
         "size_bytes":8000000000,"size_human":"7.5 GiB","read_only":false,
         "mount_point":"/mnt/airlock/USB_STICK","kernel":"sda1","parent":"sda"}
        """#
        let d = try JSONDecoder().decode(Drive.self, from: Data(json.utf8))
        XCTAssertEqual(d.id, "USB_STICK")
        XCTAssertFalse(d.ejecting)
    }

    func testURLEncodesEachSegment() {
        let c = AirlockClient(baseURL: URL(string: "http://airlock.local:80")!)
        let u = c.url(["api/drives", "MY DISK", "eject"])
        XCTAssertEqual(u.absoluteString, "http://airlock.local:80/api/drives/MY%20DISK/eject")
    }

    func testErrorBodyIsSurfaced() {
        let resp = HTTPURLResponse(url: URL(string: "http://x")!, statusCode: 409, httpVersion: nil, headerFields: nil)!
        XCTAssertThrowsError(try AirlockClient.check(resp, Data(#"{"error":"busy"}"#.utf8))) { e in
            XCTAssertEqual((e as? AirlockError)?.errorDescription, "busy (HTTP 409)")
        }
    }

    func testSSEParserHandlesSplitFramesAndComments() {
        var p = SSEParser()
        XCTAssertEqual(p.feed(Data(": heartbeat\n\ndata: {\"a\"".utf8)), [])
        XCTAssertEqual(p.feed(Data(":1}\n\ndata: x\ndata: y\n\n".utf8)), [#"{"a":1}"#, "x\ny"])
    }

    func testDeviceDecodesNullPartitions() throws {
        let json = #"""
        {"name":"sda","path":"/dev/sda","model":"MassStorageClass","vendor":"Generic","serial":"1",
         "size_bytes":0,"size_human":"0 B","transport":"usb","pt_type":"","read_only":false,
         "any_partition_read_only":false,"suggested_fs":"vfat","partitions":null}
        """#
        let d = try JSONDecoder().decode(Device.self, from: Data(json.utf8))
        XCTAssertEqual(d.title, "Generic MassStorageClass")
        XCTAssertTrue(d.isEmpty)
        XCTAssertFalse(d.isWritable)
        XCTAssertEqual(d.confirmWord(fallback: "FORMAT"), "FORMAT")
    }

    func testDeviceHealthIsOptional() throws {
        let base = #"{"name":"sdc","path":"/dev/sdc","size_bytes":1,"size_human":"1 B","read_only":false"#
        let old = try JSONDecoder().decode(Device.self, from: Data((base + "}").utf8))
        XCTAssertNil(old.health)
        let new = try JSONDecoder().decode(Device.self, from: Data((base + #","health":"failing"}"#).utf8))
        XCTAssertEqual(new.health, .failing)
        XCTAssertTrue(new.health!.isAlarming)
        let newer = try JSONDecoder().decode(Device.self, from: Data((base + #","health":"degraded"}"#).utf8))
        XCTAssertEqual(newer.health, .unknown)
    }

    /// `smart.Report` as airlockd marshals it (ATA drive behind a SAT bridge).
    func testSmartReportDecodesATA() throws {
        let json = #"""
        {"status":"warning","summary":"SMART check passed, with warnings: 3 reallocated sectors.",
         "warnings":["3 reallocated sectors"],"protocol":"ATA","model":"KINGSTON SV300S37A120G",
         "serial":"TESTSERIAL","firmware":"600ABBF0","temperature_c":26,"power_on_hours":58192,
         "power_cycles":312,"percentage_used":7,"reallocated_sectors":3,
         "attributes":[
          {"id":5,"name":"Retired_Block_Count","value":100,"worst":100,"thresh":3,"raw":"3","prefailure":true},
          {"id":194,"name":"Temperature_Celsius","value":26,"worst":68,"thresh":0,"raw":"26 (Min/Max 20/68)"},
          {"id":1,"name":"Raw_Read_Error_Rate","value":40,"worst":40,"thresh":50,"raw":"0/0","prefailure":true,"failed":"now"}],
         "checked_at":"2026-11-15T22:10:04.123456789+01:00"}
        """#
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom(AirlockClient.decodeDate)
        let r = try dec.decode(SmartReport.self, from: Data(json.utf8))
        XCTAssertEqual(r.status, .warning)
        XCTAssertTrue(r.hasData)
        XCTAssertEqual(r.powerOnHours, 58192)
        XCTAssertEqual(r.reallocatedSectors, 3)
        XCTAssertNil(r.mediaErrors)
        XCTAssertEqual(r.attributes.first?.threshold, 3)
        XCTAssertTrue(r.attributes[2].isFailing)
        XCTAssertNotNil(r.checkedAt)
    }

    func testSmartReportDecodesUnsupported() throws {
        let json = #"""
        {"status":"unsupported","summary":"This device doesn't report SMART health.",
         "messages":["/dev/sda: Unknown USB bridge [0x05e3:0x0764 (0x2960)]"],
         "checked_at":"0001-01-01T00:00:00Z"}
        """#
        let r = try JSONDecoder().decode(SmartReport.self, from: Data(json.utf8))
        XCTAssertEqual(r.status, .unsupported)
        XCTAssertFalse(r.hasData)
        XCTAssertTrue(r.attributes.isEmpty)
        XCTAssertEqual(r.messages.count, 1)
    }

    func testListingDecodesGoTimestamps() throws {
        let json = #"""
        {"path":"/","entries":[
          {"name":"a.txt","is_dir":false,"size":3,"modified":"2026-10-28T09:12:01.123456789+01:00"},
          {"name":"dir","is_dir":true,"size":0,"modified":"2026-10-28T09:12:01Z"}]}
        """#
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom(AirlockClient.decodeDate)
        let l = try dec.decode(Listing.self, from: Data(json.utf8))
        XCTAssertEqual(l.entries.map(\.name), ["a.txt", "dir"])
        XCTAssertTrue(l.entries[1].isDir)
    }

    func testCompressionFromFileName() {
        XCTAssertEqual(Compression(fileName: "raspios.img.XZ"), .xz)
        XCTAssertEqual(Compression(fileName: "a.img.gz"), .gz)
        XCTAssertEqual(Compression(fileName: "a.iso"), .none)
    }

    func testPulledCardLeavesStalePartitionButCountsAsEmpty() throws {
        let json = #"""
        {"name":"sdb","path":"/dev/sdb","size_bytes":0,"size_human":"0 B","read_only":false,
         "partitions":[{"name":"sdb1","size_bytes":128039518208,"size_human":"128.0 GB","fs_type":"vfat",
           "label":"MALENSTWO","uuid":"3ABE-1C21","mount_point":"/mnt/airlock/malenstwo","is_airlock":true,
           "share_name":"malenstwo","can_relabel":true,"max_label_len":11,"can_mount":false,"can_fsck":true}]}
        """#
        let d = try JSONDecoder().decode(Device.self, from: Data(json.utf8))
        XCTAssertTrue(d.isEmpty)
        XCTAssertFalse(d.isWritable)
        XCTAssertTrue(d.livePartitions.isEmpty)
        XCTAssertEqual(d.confirmWord(fallback: "FORMAT"), "FORMAT")
    }
}
