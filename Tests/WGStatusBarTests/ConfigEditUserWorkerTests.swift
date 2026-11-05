import ConfigEditPOSIX
import Darwin
import Foundation
import XCTest
@testable import WGStatusBarCore

final class ConfigEditUserWorkerTests: XCTestCase {
    private final class Pipes {
        var a: [Int32] = [-1, -1]
        var b: [Int32] = [-1, -1]
        init() throws { guard pipe(&a) == 0, pipe(&b) == 0 else { throw POSIXError(.EIO) } }
        deinit { for fd in a + b where fd >= 0 { close(fd) } }
        func parent() throws -> ConfigEditWorkerPipe { try ConfigEditWorkerPipe(input: b[0], output: a[1], timeout: 5) }
        func child() throws -> ConfigEditWorkerPipe { try ConfigEditWorkerPipe(input: a[0], output: b[1], timeout: 5) }
    }
    private func fixture() throws -> (String, String) {
        let root = "/private/tmp/wgwu-" + String(UUID().uuidString.prefix(8))
        let directory = root + "/homebrew/etc/wireguard"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        XCTAssertEqual(chmod(root + "/homebrew/etc", 0o775), 0)
        try Data("[Interface]\n# synthetic\n".utf8).write(to: URL(fileURLWithPath: directory + "/work.conf"))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: root) }
        return (root, directory)
    }
    private func transaction(_ request: ConfigEditMessage, directory: String,
                             activity: () throws -> Bool) async throws -> ConfigEditMessage {
        let pipes = try Pipes()
        let parent = try pipes.parent(), child = try pipes.child()
        let saving = request.kind == .save
        let task = Task.detached {
            try performUserConfigEditTransaction(named: "work", saving: saving, channel: child,
                searchPaths: [directory], allowTemporaryRoot: true)
        }
        let result = try ConfigEditUserWorker.exchange(request: request, saving: saving, channel: parent, activity: activity)
        try await task.value
        return result
    }

    func testUserTransactionLoadsAndSavesWithBothParentActivityChecks() async throws {
        let (_, directory) = try fixture()
        let loaded = try await transaction(ConfigEditMessage(kind: .read), directory: directory) { XCTFail("Read checked activity"); return true }
        XCTAssertEqual(loaded.kind, .loaded)
        let revision = try XCTUnwrap(loaded.revision)
        var checks = 0
        let saved = try await transaction(ConfigEditMessage(kind: .save, text: "[Interface]\n# saved by user", revision: revision), directory: directory) {
            checks += 1
            return false
        }
        XCTAssertEqual(saved.kind, .saved)
        XCTAssertEqual(checks, 2)
        XCTAssertEqual(try String(contentsOfFile: directory + "/work.conf"), "[Interface]\n# saved by user")
    }

    func testParentUnknownAtEitherGatePreventsUserCommit() async throws {
        for failureAt in [1, 2] {
            let (_, directory) = try fixture()
            let original = try Data(contentsOf: URL(fileURLWithPath: directory + "/work.conf"))
            let loaded = try await transaction(ConfigEditMessage(kind: .read), directory: directory) { false }
            var checks = 0
            let reply = try await transaction(ConfigEditMessage(kind: .save, text: "changed", revision: loaded.revision), directory: directory) {
                checks += 1
                if checks == failureAt { throw WireGuardRuntimeActivityError.unavailable }
                return false
            }
            XCTAssertEqual(reply.kind, .unavailable)
            XCTAssertEqual(checks, failureAt)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: directory + "/work.conf")), original)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory), ["work.conf"])
        }
    }

    func testScopeResolutionNeverFallsThroughUnsafeFirstCandidate() throws {
        var lookedUp: [String] = []
        let resolver = ConfigEditFileScopeResolver(searchPaths: ["/first", "/second"], owner: { path in
            lookedUp.append(path)
            return 0
        }, validateRootDirectory: { _ in throw ConfigEditStoreError.unavailable })
        XCTAssertThrowsError(try resolver.resolve(named: "work", clientUID: 501)) {
            XCTAssertEqual($0 as? ConfigEditStoreError, .unsafeConfiguration)
        }
        XCTAssertEqual(lookedUp, ["/first/work.conf"])
        let user = ConfigEditFileScopeResolver(searchPaths: ["/homebrew"], owner: { _ in 501 },
            validateRootDirectory: { _ in XCTFail("Privileged directory access for user file") })
        XCTAssertEqual(try user.resolve(named: "work", clientUID: 501), .userOwned(index: 0))
        XCTAssertThrowsError(try user.resolve(named: "work", clientUID: 502))
    }

    func testPipeRejectsTruncationAndHasABoundedDeadline() throws {
        let pipes = try Pipes()
        let channel = try ConfigEditWorkerPipe(input: pipes.a[0], output: pipes.b[1], timeout: 0.03)
        var byte: UInt8 = 65
        XCTAssertEqual(Darwin.write(pipes.a[1], &byte, 1), 1)
        close(pipes.a[1]); pipes.a[1] = -1
        XCTAssertThrowsError(try channel.readLine())
        let silent = try Pipes()
        let waiting = try ConfigEditWorkerPipe(input: silent.a[0], output: silent.b[1], timeout: 0.03)
        XCTAssertThrowsError(try waiting.readLine())
    }

    func testInheritedReadOnlyLeaseSurvivesParentReleaseUntilChildExit() throws {
        guard geteuid() != 0 else { throw XCTSkip("No privilege-changing unit tests") }
        let (root, _) = try fixture()
        let lock = TunnelOperationLock(directoryPath: root + "/locks",
            fileSystem: SecureConfigFileSystem(ownerUID: geteuid(), allowTemporaryRoot: true))
        let lease = try lock.acquire(named: "work")
        let fd = try lease.duplicateDescriptor()
        XCTAssertEqual(fcntl(fd, F_GETFL) & O_ACCMODE, O_RDONLY)
        let input = open("/dev/null", O_RDONLY), output = open("/dev/null", O_WRONLY)
        defer { close(input); close(output) }
        let identity = try ConfigEditWorkerIdentity(uid: geteuid())
        let words: [String] = ["/bin/sleep", "0.3"]
        let strings = words.map { strdup($0) }
        defer { strings.forEach { free($0) } }
        var arguments = strings + [nil]
        let child = identity.groups.withUnsafeBufferPointer { groups in
            arguments.withUnsafeMutableBufferPointer { argv in
                wg_edit_spawn("/bin/sleep", argv.baseAddress, identity.uid, identity.gid,
                    groups.baseAddress, groups.count, input, output, fd)
            }
        }
        guard child > 0 else { close(fd); throw POSIXError(.EIO) }
        var reaped = false
        defer { if !reaped { kill(child, SIGKILL); var status: Int32 = 0; _ = waitpid(child, &status, WNOHANG) } }
        close(fd)
        lease.release()
        XCTAssertThrowsError(try lock.withLock(named: "work", timeout: 0.03) { 1 })
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var status: Int32 = 0
        while waitpid(child, &status, WNOHANG) == 0 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw POSIXError(.ETIMEDOUT) }
            Thread.sleep(forTimeInterval: 0.005)
        }
        reaped = true
        XCTAssertEqual(status, 0)
        XCTAssertEqual(try lock.withLock(named: "work") { 2 }, 2)
    }

    func testLauncherRefusesRootWorkerIdentity() {
        var argument: UnsafeMutablePointer<CChar>? = nil
        XCTAssertEqual(wg_edit_spawn("/usr/bin/true", &argument, 0, 0, nil, 0, 0, 1, 2), -1)
        XCTAssertEqual(errno, EINVAL)
    }

    func testWorkerArgvIsRestrictedToFixedDirectoryIndexes() {
        XCTAssertEqual(parseHelperArgv(["--user-config-edit", "work", "read", "2"]), .userConfigEdit(name: "work", saving: false, directoryIndex: 2))
        for arguments in [["--user-config-edit", "work", "save", "-1"],
                          ["--user-config-edit", "work", "save", "999"],
                          ["--user-config-edit", "../bad", "read", "2"],
                          ["--user-config-edit", "work", "read", "/tmp"],
                          ["--user-config-edit", "work", "read"]] {
            XCTAssertEqual(parseHelperArgv(arguments), .invalid)
        }
    }

    func testPriorityScopeChangeFromParentRefusesCommitAsConflict() async throws {
        let (_, directory) = try fixture()
        let original = try Data(contentsOf: URL(fileURLWithPath: directory + "/work.conf"))
        let loaded = try await transaction(ConfigEditMessage(kind: .read), directory: directory) { false }
        var checks = 0
        let reply = try await transaction(ConfigEditMessage(kind: .save, text: "changed", revision: loaded.revision), directory: directory) {
            checks += 1
            if checks == 2 { throw ConfigEditStoreError.conflict }
            return false
        }
        XCTAssertEqual(reply.kind, .conflict)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: directory + "/work.conf")), original)
    }

    func testNonemptyLockCannotBeDelegatedToUserWorker() throws {
        let (root, _) = try fixture()
        let directory = root + "/locks"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("not lock metadata".utf8).write(to: URL(fileURLWithPath: directory + "/work.lock"))
        XCTAssertEqual(chmod(directory + "/work.lock", 0o600), 0)
        let lock = TunnelOperationLock(directoryPath: directory,
            fileSystem: SecureConfigFileSystem(ownerUID: geteuid(), allowTemporaryRoot: true))
        XCTAssertThrowsError(try lock.acquire(named: "work"))
    }

    func testDirectWorkerInvocationCannotRunWithoutInheritedRootLease() {
        XCTAssertFalse(validInheritedConfigEditLease(STDERR_FILENO))
        XCTAssertEqual(runHelperUserConfigEditWorker(named: "work", saving: false, directoryIndex: 2), 2)
    }
}
