import Darwin
import Foundation
import XCTest
@testable import WGStatusBarCore

final class ConfigEditProbeSessionTests: XCTestCase {
private func parent() throws -> String {
        let path = "/private/tmp/wgep-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    func testBootstrapPublishesOnlyVerifiedPIDAndCleansItsOwnNamespace() throws {
        let parent = try parent()
        let id = UUID().uuidString
        let path = parent + "/wge-session-" + id
        do {
            let server = try ConfigEditProbeSession(parent: parent, session: id, owner: geteuid())
            XCTAssertNil(try ConfigEditProbeSession.serverPID(parent: parent, session: id, owner: geteuid()))
            try server.publishReady()
            XCTAssertEqual(try ConfigEditProbeSession.serverPID(parent: parent, session: id, owner: geteuid()), getpid())
            let client = try ConfigEditTransportPrototype.connect(path: server.socketPath,
                expectedUID: geteuid(), expectedPID: getpid(), timeout: 1)
            let peer = try ConfigEditTransportPrototype(descriptor: server.acceptOne(timeout: 1),
                expectedUID: geteuid(), expectedPID: getpid(), timeout: 1)
            try client.send("synthetic")
            XCTAssertEqual(try peer.receive(), "synthetic")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testRejectsInvalidSessionAndNeverRemovesAnExistingNamespace() throws {
        let parent = try parent()
        for invalid in ["../escape", "", "not-a-uuid"] {
            XCTAssertThrowsError(try ConfigEditProbeSession(parent: parent, session: invalid, owner: geteuid()))
        }
        let id = UUID().uuidString
        let first = try ConfigEditProbeSession(parent: parent, session: id, owner: geteuid())
        XCTAssertThrowsError(try ConfigEditProbeSession(parent: parent, session: id, owner: geteuid()))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.socketPath))
    }

    func testRejectsWrongOwnerWritableReadyAndSymlinkedReady() throws {
        let parent = try parent()
        let id = UUID().uuidString
        let server = try ConfigEditProbeSession(parent: parent, session: id, owner: geteuid())
        try server.publishReady()
        XCTAssertThrowsError(try ConfigEditProbeSession.serverPID(parent: parent, session: id,
            owner: geteuid() == 0 ? 1 : 0))
        let ready = parent + "/wge-session-" + id + "/ready"
        XCTAssertEqual(chmod(ready, 0o666), 0)
        XCTAssertThrowsError(try ConfigEditProbeSession.serverPID(parent: parent, session: id, owner: geteuid()))
        XCTAssertEqual(unlink(ready), 0)
        try FileManager.default.createSymbolicLink(atPath: ready, withDestinationPath: "/dev/null")
        XCTAssertThrowsError(try ConfigEditProbeSession.serverPID(parent: parent, session: id, owner: geteuid()))
    }

    func testAcceptDeadlineAndDoublePublicationAreBoundedFailures() throws {
        let parent = try parent()
        let server = try ConfigEditProbeSession(parent: parent, session: UUID().uuidString, owner: geteuid())
        XCTAssertThrowsError(try server.acceptOne(timeout: 0.03)) {
            XCTAssertEqual($0 as? ConfigEditTransportPrototype.Failure, .timedOut)
        }
        try server.publishReady()
        XCTAssertThrowsError(try server.publishReady())
    }
}
