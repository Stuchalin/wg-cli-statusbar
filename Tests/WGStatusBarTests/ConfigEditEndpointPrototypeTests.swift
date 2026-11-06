import Darwin
import Foundation
import XCTest
@testable import WGStatusBarCore

final class ConfigEditEndpointPrototypeTests: XCTestCase {
    private final class Endpoint {
        let directory: String
        let path: String
        let listener: Int32

init() throws {
            directory = "/private/tmp/wge-" + UUID().uuidString
            path = directory + "/channel"
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false,
                                                     attributes: [.posixPermissions: 0o700])
            listener = socket(AF_UNIX, SOCK_STREAM, 0)
            guard listener >= 0 else {
                try? FileManager.default.removeItem(atPath: directory)
                throw POSIXError(.EIO)
            }
            let bound = withUnixSocketAddress(path: path) { Darwin.bind(listener, $0, $1) }
            guard bound == 0, chmod(path, 0o600) == 0, listen(listener, 2) == 0 else {
                close(listener)
                try? FileManager.default.removeItem(atPath: directory)
                throw POSIXError(.EIO)
            }
        }

        deinit {
            close(listener)
            try? FileManager.default.removeItem(atPath: directory)
        }

        func acceptOne() throws -> Int32 {
            var entry = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&entry, 1, 2000) > 0 else { throw POSIXError(.ETIMEDOUT) }
            let descriptor = accept(listener, nil, nil)
            guard descriptor >= 0 else { throw POSIXError(.EIO) }
            return descriptor
        }
    }

    private func connect(_ path: String, uid: uid_t = geteuid(), pid: pid_t = getpid()) throws
        -> ConfigEditTransportPrototype {
        try ConfigEditTransportPrototype.connect(path: path, expectedUID: uid, expectedPID: pid, timeout: 2)
    }

    func testPrivateEndpointSupportsMutuallyVerifiedRequestAndResponse() throws {
        let endpoint = try Endpoint()
        let client = try connect(endpoint.path)
        let server = try ConfigEditTransportPrototype(descriptor: endpoint.acceptOne(),
            expectedUID: geteuid(), expectedPID: getpid(), timeout: 2)
        try client.send("synthetic request\n")
        XCTAssertEqual(try server.receive(), "synthetic request\n")
        try server.send("synthetic response")
        XCTAssertEqual(try client.receive(), "synthetic response")
    }

    func testRejectsWrongEndpointOwnerAndWrongKernelPeerPID() throws {
        let endpoint = try Endpoint()
        XCTAssertThrowsError(try connect(endpoint.path, uid: geteuid() == 0 ? 1 : 0)) {
            XCTAssertEqual($0 as? ConfigEditTransportPrototype.Failure, .invalidEndpoint)
        }
        XCTAssertThrowsError(try connect(endpoint.path, pid: getpid() + 1)) {
            XCTAssertEqual($0 as? ConfigEditTransportPrototype.Failure, .peerRejected)
        }
    }

    func testRejectsSocketSymlinkAndWritableParent() throws {
        let endpoint = try Endpoint()
        let alias = endpoint.directory + "/alias"
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: endpoint.path)
        XCTAssertThrowsError(try connect(alias)) {
            XCTAssertEqual($0 as? ConfigEditTransportPrototype.Failure, .invalidEndpoint)
        }
        XCTAssertEqual(chmod(endpoint.directory, 0o777), 0)
        XCTAssertThrowsError(try connect(endpoint.path)) {
            XCTAssertEqual($0 as? ConfigEditTransportPrototype.Failure, .invalidEndpoint)
        }
    }

    func testRejectsDirectorySymlinkAndInvalidSocketPathsWithoutTrapping() throws {
        let endpoint = try Endpoint()
        let alias = endpoint.directory + "/linked"
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: endpoint.directory)
        for path in [alias + "/channel", "relative", endpoint.path + "\0suffix",
                     String(repeating: "/long", count: 50), endpoint.directory + "/../channel"] {
            XCTAssertThrowsError(try connect(path)) {
                XCTAssertEqual($0 as? ConfigEditTransportPrototype.Failure, .invalidEndpoint)
            }
        }
    }

    func testKernelReportsTheActualConnectingChildNotTheListenerProcess() throws {
        let endpoint = try Endpoint()
        let child = Process()
        let input = Pipe()
        let exited = expectation(description: "bounded synthetic peer")
        child.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        child.arguments = ["-U", "-w", "1", endpoint.path]
        child.standardInput = input
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        child.terminationHandler = { _ in exited.fulfill() }
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let channel = try ConfigEditTransportPrototype(descriptor: endpoint.acceptOne(),
            expectedUID: geteuid(), expectedPID: child.processIdentifier, timeout: 2)
        try channel.send("synthetic response")
        try input.fileHandleForWriting.close()
        wait(for: [exited], timeout: 3)
    }

    func testRejectsACLWritableDirectoryEvenWhenModeIsPrivate() throws {
        let endpoint = try Endpoint()
        let change = Process()
        let done = expectation(description: "set synthetic directory ACL")
        change.executableURL = URL(fileURLWithPath: "/bin/chmod")
        change.arguments = ["+a", "everyone allow add_file", endpoint.directory]
        change.standardOutput = FileHandle.nullDevice
        change.standardError = FileHandle.nullDevice
        change.terminationHandler = { _ in done.fulfill() }
        try change.run()
        defer { if change.isRunning { change.terminate() } }
        wait(for: [done], timeout: 2)
        guard !change.isRunning else { return }
        XCTAssertEqual(change.terminationStatus, 0)
        XCTAssertThrowsError(try connect(endpoint.path)) {
            XCTAssertEqual($0 as? ConfigEditTransportPrototype.Failure, .invalidEndpoint)
        }
    }

    func testCancellationDuringImmediateConnectDoesNotReturnSuccessfulChannel() throws {
        let endpoint = try Endpoint()
        var checks = 0
        XCTAssertThrowsError(try ConfigEditTransportPrototype.connect(path: endpoint.path,
            expectedUID: geteuid(), expectedPID: getpid(), timeout: 2, cancelled: {
                checks += 1
                return checks > 1
            })) {
            XCTAssertEqual($0 as? ConfigEditTransportPrototype.Failure, .cancelled)
        }
    }
}
