import Darwin
import Foundation
import XCTest
@testable import WGStatusBarCore

final class WireGuardRuntimeActivityProbeTests: XCTestCase {
    private final class FileSystem: WireGuardRuntimeActivityFileSystem {
        var entries = ["work.name"]
        var failListing = false
        var failRecord = false
        var failSocket = false
        var record = WireGuardRuntimeActivityRecord(interfaceName: "utun3", modificationDate: Date(timeIntervalSince1970: 100))
        var socketDate = Date(timeIntervalSince1970: 100)
        func directoryEntries(atPath path: String) throws -> [String] {
            if failListing { throw WireGuardRuntimeActivityError.unavailable }
            return entries
        }
        func nameRecord(atPath path: String) throws -> WireGuardRuntimeActivityRecord {
            if failRecord { throw WireGuardRuntimeActivityError.unavailable }
            return record
        }
        func socketModificationDate(atPath path: String) throws -> Date {
            if failSocket { throw WireGuardRuntimeActivityError.unavailable }
            return socketDate
        }
    }

    func testOnlySuccessfulListingWithoutSelectedRecordProvesInactive() throws {
        let fs = FileSystem()
        fs.entries = ["other.name"]
        fs.failRecord = true
        XCTAssertFalse(try WireGuardRuntimeActivityProbe(fileSystem: fs).isActive(named: "work"))
        fs.entries = ["work.name"]
        fs.failRecord = false
        XCTAssertTrue(try WireGuardRuntimeActivityProbe(fileSystem: fs).isActive(named: "work"))
    }

    func testListingReadAndSocketMetadataFailuresRemainUnknown() {
        for point in ["listing", "record", "socket"] {
            let fs = FileSystem()
            fs.failListing = point == "listing"
            fs.failRecord = point == "record"
            fs.failSocket = point == "socket"
            XCTAssertThrowsError(try WireGuardRuntimeActivityProbe(fileSystem: fs).isActive(named: "work")) {
                XCTAssertEqual($0 as? WireGuardRuntimeActivityError, .unavailable)
            }
        }
    }

    func testMalformedAndStaleRecordsAreUnknownNotInactive() {
        for name in ["", "../utun3", "utun", "utun-3", "wg0", "utun３", "utun3\0"] {
            let fs = FileSystem()
            fs.record = WireGuardRuntimeActivityRecord(interfaceName: name, modificationDate: fs.socketDate)
            XCTAssertThrowsError(try WireGuardRuntimeActivityProbe(fileSystem: fs).isActive(named: "work"))
        }
        for offset in [-2.0, 2.0, 5.0] {
            let fs = FileSystem()
            fs.socketDate = fs.record.modificationDate.addingTimeInterval(offset)
            XCTAssertThrowsError(try WireGuardRuntimeActivityProbe(fileSystem: fs).isActive(named: "work"))
        }
    }

    func testRealUnreadableAndMissingDirectoriesFailClosed() throws {
        guard geteuid() != 0 else { throw XCTSkip("Permission regression requires a non-root test process") }
        let path = "/private/tmp/wgap-" + String(UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o000])
        defer { chmod(path, 0o700); try? FileManager.default.removeItem(atPath: path) }
        XCTAssertThrowsError(try WireGuardRuntimeActivityProbe(directoryPath: path).isActive(named: "work"))
        XCTAssertEqual(chmod(path, 0o700), 0)
        XCTAssertThrowsError(try WireGuardRuntimeActivityProbe(directoryPath: path + "/missing").isActive(named: "work"))
    }

    func testRealRuntimeRecordAndSocketAreReadWithoutLossyFallback() throws {
        let path = "/private/tmp/wgap-" + String(UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: path) }
        let probe = WireGuardRuntimeActivityProbe(directoryPath: path)
        XCTAssertFalse(try probe.isActive(named: "work"))
        try Data("utun3\n".utf8).write(to: URL(fileURLWithPath: path + "/work.name"))
        XCTAssertThrowsError(try probe.isActive(named: "work"))
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        XCTAssertEqual(withUnixSocketAddress(path: path + "/utun3.sock") { Darwin.bind(descriptor, $0, $1) }, 0)
        let timestamp = Date(timeIntervalSince1970: 100)
        for file in [path + "/work.name", path + "/utun3.sock"] {
            try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: file)
        }
        XCTAssertTrue(try probe.isActive(named: "work"))
    }

    func testRealUnsafeUnreadableAndOversizedNameRecordsDoNotBecomeDown() throws {
        let path = "/private/tmp/wgap-" + String(UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: path) }
        let record = path + "/work.name"
        let probe = WireGuardRuntimeActivityProbe(directoryPath: path)
        try FileManager.default.createSymbolicLink(atPath: record, withDestinationPath: "/dev/null")
        XCTAssertThrowsError(try probe.isActive(named: "work"))
        XCTAssertEqual(unlink(record), 0)
        XCTAssertEqual(mkfifo(record, 0o600), 0)
        XCTAssertThrowsError(try probe.isActive(named: "work"))
        XCTAssertEqual(unlink(record), 0)
        try Data(repeating: 65, count: 65).write(to: URL(fileURLWithPath: record))
        XCTAssertThrowsError(try probe.isActive(named: "work"))
        if geteuid() != 0 {
            XCTAssertEqual(chmod(record, 0o000), 0)
            defer { chmod(record, 0o600) }
            XCTAssertThrowsError(try probe.isActive(named: "work"))
        }
    }
}
