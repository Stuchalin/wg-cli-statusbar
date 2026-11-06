import Darwin
import Foundation
import XCTest
@testable import WGStatusBarCore

final class TunnelConfigEditorTests: XCTestCase {
    private final class Fixture {
        let root = "/private/tmp/wgew-" + String(UUID().uuidString.prefix(8))
        var first: String { root + "/first" }
        var second: String { root + "/second" }
        var file: String { first + "/work.conf" }
        init() throws {
            for path in [root, first, second] {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
            }
            try put("[Interface]\nAddress = 10.1.0.2/32\n", at: file)
        }
        deinit { try? FileManager.default.removeItem(atPath: root) }
        func put(_ text: String, at path: String) throws {
            try Data(text.utf8).write(to: URL(fileURLWithPath: path))
            guard chmod(path, 0o600) == 0 else { throw POSIXError(.EIO) }
        }
        func editor(active: @escaping (String) throws -> Bool = { _ in false },
                    operations: ConfigEditWriteOperations = ConfigEditWriteOperations()) -> TunnelConfigEditor {
            TunnelConfigEditor(searchPaths: [first, second], lockDirectory: root + "/locks",
                ownerUID: geteuid(), allowTemporaryRoot: true, tunnelIsActive: active, operations: operations)
        }
    }

    func testExactDocumentRoundTripAndRevisionChangesAfterAtomicReplacement() throws {
        let f = try Fixture()
        let editor = f.editor()
        let before = try editor.readSnapshot(named: "work")
        let text = "[Interface]\r\n# синтетический документ без финального LF"
        try editor.save(named: "work", revision: before.revision, text: text)
        let after = try editor.readSnapshot(named: "work")
        XCTAssertEqual(after.text, text)
        XCTAssertNotEqual(before.revision, after.revision)
        var metadata = stat()
        XCTAssertEqual(lstat(f.file, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & 0o777, 0o600)
        XCTAssertEqual(metadata.st_uid, geteuid())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.first), ["work.conf"])
    }

    func testConcurrentExternalModificationNeverGetsOverwritten() throws {
        let f = try Fixture()
        let editor = f.editor()
        let snapshot = try editor.readSnapshot(named: "work")
        let external = "[Interface]\n# external change\n"
        try f.put(external, at: f.file)
        XCTAssertThrowsError(try editor.save(named: "work", revision: snapshot.revision, text: "new")) {
            XCTAssertEqual($0 as? ConfigEditStoreError, .conflict)
        }
        XCTAssertEqual(try String(contentsOfFile: f.file, encoding: .utf8), external)
    }

    func testNewHigherPriorityConfigIsAConflictNotAWrongTarget() throws {
        let f = try Fixture()
        try FileManager.default.moveItem(atPath: f.file, toPath: f.second + "/work.conf")
        let editor = f.editor()
        let snapshot = try editor.readSnapshot(named: "work")
        try f.put("higher-priority", at: f.file)
        XCTAssertThrowsError(try editor.save(named: "work", revision: snapshot.revision, text: "new")) {
            XCTAssertEqual($0 as? ConfigEditStoreError, .conflict)
        }
        XCTAssertEqual(try String(contentsOfFile: f.file), "higher-priority")
    }

    func testUnsafeFirstMatchNeverFallsThroughToDuplicate() throws {
        let f = try Fixture()
        try f.put("fallback", at: f.second + "/work.conf")
        try FileManager.default.removeItem(atPath: f.file)
        try FileManager.default.createSymbolicLink(atPath: f.file, withDestinationPath: f.second + "/work.conf")
        XCTAssertThrowsError(try f.editor().readSnapshot(named: "work")) {
            XCTAssertEqual($0 as? ConfigEditStoreError, .unavailable)
        }
    }

    func testRejectsHardLinksFIFOAndWritableFilesOrDirectories() throws {
        for kind in ["hardlink", "fifo", "file-permissions", "directory-permissions"] {
            let f = try Fixture()
            switch kind {
            case "hardlink": XCTAssertEqual(link(f.file, f.root + "/alias"), 0)
            case "fifo":
                XCTAssertEqual(unlink(f.file), 0)
                XCTAssertEqual(mkfifo(f.file, 0o600), 0)
            case "file-permissions": XCTAssertEqual(chmod(f.file, 0o666), 0)
            default: XCTAssertEqual(chmod(f.first, 0o777), 0)
            }
            XCTAssertThrowsError(try f.editor().readSnapshot(named: "work")) {
                XCTAssertEqual($0 as? ConfigEditStoreError, .unavailable)
            }
        }
    }

    func testRejectsInvalidNamesBeforeFilesystemAccess() throws {
        let f = try Fixture()
        for name in ["", "../work", "work\n", "work\0", String(repeating: "x", count: 16)] {
            XCTAssertThrowsError(try f.editor().readSnapshot(named: name)) {
                XCTAssertEqual($0 as? ConfigEditStoreError, .invalidName)
            }
        }
    }

    func testLimitsAndInvalidUTF8FailClosed() throws {
        let f = try Fixture()
        let editor = f.editor()
        let snapshot = try editor.readSnapshot(named: "work")
        XCTAssertThrowsError(try editor.save(named: "work", revision: snapshot.revision,
            text: String(repeating: "x", count: 256 * 1024 + 1))) {
            XCTAssertEqual($0 as? ConfigEditStoreError, .invalidDocument)
        }
        try Data([0xff]).write(to: URL(fileURLWithPath: f.file))
        XCTAssertThrowsError(try editor.readSnapshot(named: "work"))
    }

    func testActiveTunnelAndCancellationLeaveOriginalUntouched() throws {
        let f = try Fixture()
        let initial = try String(contentsOfFile: f.file)
        let editor = f.editor(active: { _ in true })
        let snapshot = try editor.readSnapshot(named: "work")
        XCTAssertThrowsError(try editor.save(named: "work", revision: snapshot.revision, text: "new")) {
            XCTAssertEqual($0 as? ConfigEditStoreError, .activeTunnel)
        }
        XCTAssertThrowsError(try f.editor().save(named: "work", revision: snapshot.revision, text: "new", cancelled: { true })) {
            XCTAssertEqual($0 as? ConfigEditStoreError, .cancelled)
        }
        XCTAssertEqual(try String(contentsOfFile: f.file), initial)
    }

    func testShortWritesAreRetriedWithoutLosingBytes() throws {
        let f = try Fixture()
        var operations = ConfigEditWriteOperations()
        operations.write = { Darwin.write($0, $1, min($2, 3)) }
        let editor = f.editor(operations: operations)
        let snapshot = try editor.readSnapshot(named: "work")
        try editor.save(named: "work", revision: snapshot.revision, text: "[Interface]\n# exact bytes\n")
        XCTAssertEqual(try String(contentsOfFile: f.file), "[Interface]\n# exact bytes\n")
    }

    func testWriteSyncAndRenameFailuresPreserveOriginalAndCleanTemporaryFile() throws {
        for point in ["write", "sync", "rename"] {
            let f = try Fixture()
            let original = try String(contentsOfFile: f.file)
            var operations = ConfigEditWriteOperations()
            switch point {
            case "write": operations.write = { _, _, _ in errno = ENOSPC; return -1 }
            case "sync": operations.sync = { _ in errno = EIO; return -1 }
            default: operations.replace = { _, _, _ in errno = EIO; return -1 }
            }
            let editor = f.editor(operations: operations)
            let snapshot = try editor.readSnapshot(named: "work")
            XCTAssertThrowsError(try editor.save(named: "work", revision: snapshot.revision, text: "new"))
            XCTAssertEqual(try String(contentsOfFile: f.file), original)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.first), ["work.conf"])
        }
    }

    func testExternalChangeDuringStagingIsDetectedBeforeCommit() throws {
        let f = try Fixture()
        var operations = ConfigEditWriteOperations()
        var modified = false
        operations.write = { fd, bytes, count in
            if !modified {
                modified = true
                try? f.put("external during staging", at: f.file)
            }
            return Darwin.write(fd, bytes, count)
        }
        let editor = f.editor(operations: operations)
        let snapshot = try editor.readSnapshot(named: "work")
        XCTAssertThrowsError(try editor.save(named: "work", revision: snapshot.revision, text: "new")) {
            XCTAssertEqual($0 as? ConfigEditStoreError, .conflict)
        }
        XCTAssertEqual(try String(contentsOfFile: f.file), "external during staging")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.first), ["work.conf"])
    }

    func testActivationOrCancellationAfterStagingPreventCommit() throws {
        for cancellation in [false, true] {
            let f = try Fixture()
            let original = try String(contentsOfFile: f.file)
            var staged = false
            var operations = ConfigEditWriteOperations()
            operations.write = { fd, bytes, count in
                staged = true
                return Darwin.write(fd, bytes, count)
            }
            let editor = f.editor(active: { _ in staged && !cancellation }, operations: operations)
            let snapshot = try editor.readSnapshot(named: "work")
            XCTAssertThrowsError(try editor.save(named: "work", revision: snapshot.revision, text: "new", cancelled: {
                staged && cancellation
            })) {
                XCTAssertEqual($0 as? ConfigEditStoreError, cancellation ? .cancelled : .activeTunnel)
            }
            XCTAssertEqual(try String(contentsOfFile: f.file), original)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.first), ["work.conf"])
        }
    }

    func testDirectorySyncFailureReportsUnknownCommitNotSafeRetry() throws {
        let f = try Fixture()
        var operations = ConfigEditWriteOperations()
        operations.sync = { fd in
            var status = stat()
            guard fstat(fd, &status) == 0 else { return -1 }
            if status.st_mode & S_IFMT == S_IFDIR { errno = EIO; return -1 }
            return fsync(fd)
        }
        let editor = f.editor(operations: operations)
        let snapshot = try editor.readSnapshot(named: "work")
        XCTAssertThrowsError(try editor.save(named: "work", revision: snapshot.revision, text: "committed")) {
            XCTAssertEqual($0 as? ConfigEditStoreError, .unknownCommitOutcome)
        }
        XCTAssertEqual(try String(contentsOfFile: f.file), "committed")
    }

    func testLockContentionIsBoundedAndCancelledWaitDoesNotEnterOperation() throws {
        let f = try Fixture()
        let lock = TunnelOperationLock(directoryPath: f.root + "/locks",
            fileSystem: SecureConfigFileSystem(ownerUID: geteuid(), allowTemporaryRoot: true))
        try lock.withLock(named: "work") {
            XCTAssertThrowsError(try lock.withLock(named: "work", timeout: 0.03) { XCTFail("Entered contested operation") }) {
                XCTAssertEqual($0 as? ConfigEditStoreError, .busy)
            }
            XCTAssertThrowsError(try lock.withLock(named: "work", cancelled: { true }) { XCTFail("Entered cancelled operation") }) {
                XCTAssertEqual($0 as? ConfigEditStoreError, .cancelled)
            }
        }
        XCTAssertEqual(try lock.withLock(named: "work") { 42 }, 42)
    }

    func testZeroWritesAndPersistentEINTRFailWithoutDamage() throws {
        for interrupted in [false, true] {
            let f = try Fixture()
            let original = try String(contentsOfFile: f.file)
            var operations = ConfigEditWriteOperations()
            operations.write = { _, _, _ in errno = EINTR; return interrupted ? -1 : 0 }
            let editor = f.editor(operations: operations)
            let snapshot = try editor.readSnapshot(named: "work")
            XCTAssertThrowsError(try editor.save(named: "work", revision: snapshot.revision, text: "new"))
            XCTAssertEqual(try String(contentsOfFile: f.file), original)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.first), ["work.conf"])
        }
    }

    func testEmptyAndExactLimitDocumentsAreExplicitlyAllowedButNULIsRejected() throws {
        let f = try Fixture()
        let editor = f.editor()
        for text in ["", String(repeating: "x", count: TunnelConfigReader.maxSizeBytes)] {
            let snapshot = try editor.readSnapshot(named: "work")
            try editor.save(named: "work", revision: snapshot.revision, text: text)
            XCTAssertEqual(try editor.readSnapshot(named: "work").text, text)
        }
        let snapshot = try editor.readSnapshot(named: "work")
        XCTAssertThrowsError(try editor.save(named: "work", revision: snapshot.revision, text: "a\0b")) {
            XCTAssertEqual($0 as? ConfigEditStoreError, .invalidDocument)
        }
    }

func testSymlinkedDirectoryAndUnsafeLockFileFailClosed() throws {
        let f = try Fixture()
        let actual = f.root + "/actual"
        try FileManager.default.moveItem(atPath: f.first, toPath: actual)
        try FileManager.default.createSymbolicLink(atPath: f.first, withDestinationPath: actual)
        XCTAssertThrowsError(try f.editor().readSnapshot(named: "work")) {
            XCTAssertEqual($0 as? ConfigEditStoreError, .unavailable)
        }
        try FileManager.default.removeItem(atPath: f.first)
        try FileManager.default.moveItem(atPath: actual, toPath: f.first)
        // readSnapshot created its lock before rejecting the unsafe target.
        let lockFile = f.root + "/locks/work.lock"
        XCTAssertEqual(unlink(lockFile), 0)
        try FileManager.default.createSymbolicLink(atPath: lockFile, withDestinationPath: f.file)
        XCTAssertThrowsError(try f.editor().readSnapshot(named: "work")) {
            XCTAssertEqual($0 as? ConfigEditStoreError, .unavailable)
        }
    }

    func testDeletedOriginalIsConflictAndNoReplacementIsCreated() throws {
        let f = try Fixture()
        let editor = f.editor()
        let snapshot = try editor.readSnapshot(named: "work")
        XCTAssertEqual(unlink(f.file), 0)
        XCTAssertThrowsError(try editor.save(named: "work", revision: snapshot.revision, text: "new")) {
            XCTAssertEqual($0 as? ConfigEditStoreError, .conflict)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.file))
    }

    func testLeaseCanSpanAsyncOperationsAndReleasesExactlyOnce() throws {
        let f = try Fixture()
        let lock = TunnelOperationLock(directoryPath: f.root + "/locks",
            fileSystem: SecureConfigFileSystem(ownerUID: geteuid(), allowTemporaryRoot: true))
        let lease = try lock.acquire(named: "work")
        XCTAssertThrowsError(try lock.withLock(named: "work", timeout: 0.02) { 1 })
        lease.release()
        lease.release()
        XCTAssertEqual(try lock.withLock(named: "work") { 2 }, 2)
    }

    func testOneShotMessageRoutingLoadsRevisionAndSavesWithoutExposingContentInAck() throws {
        let f = try Fixture()
        let editor = f.editor()
        let loaded = performConfigEditRequest(ConfigEditMessage(kind: .read), named: "work", saving: false, editor: editor)
        XCTAssertEqual(loaded.kind, .loaded)
        let revision = try XCTUnwrap(loaded.revision)
        let request = ConfigEditMessage(kind: .save, text: "[Interface]\n# updated", revision: revision)
        let reply = performConfigEditRequest(request, named: "work", saving: true, editor: editor)
        XCTAssertEqual(reply, ConfigEditMessage(kind: .saved))
        XCTAssertEqual(try String(contentsOfFile: f.file), "[Interface]\n# updated")
        XCTAssertEqual(performConfigEditRequest(request, named: "work", saving: true, editor: editor).kind, .conflict)
        XCTAssertEqual(performConfigEditRequest(request, named: "work", saving: false, editor: editor).kind, .unavailable)
    }

    func testAdvisoryLockIsSharedWithAnotherRealProcess() throws {
        let f = try Fixture()
        let lock = TunnelOperationLock(directoryPath: f.root + "/locks",
            fileSystem: SecureConfigFileSystem(ownerUID: geteuid(), allowTemporaryRoot: true))
        let lease = try lock.acquire(named: "work")
        defer { lease.release() }
        func competingProcessStatus() throws -> Int32 {
            let child = Process()
            let done = expectation(description: "bounded cross-process flock")
            child.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            child.arguments = ["-MFcntl=:flock", "-e", "open(my $f, '+<', $ARGV[0]) or exit 2; exit(flock($f, LOCK_EX | LOCK_NB) ? 0 : 7);", f.root + "/locks/work.lock"]
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            child.terminationHandler = { _ in done.fulfill() }
            try child.run()
            defer { if child.isRunning { child.terminate() } }
            wait(for: [done], timeout: 2)
            guard !child.isRunning else { throw POSIXError(.ETIMEDOUT) }
            return child.terminationStatus
        }
        XCTAssertEqual(try competingProcessStatus(), 7)
        lease.release()
        XCTAssertEqual(try competingProcessStatus(), 0)
    }

    func testUnknownActivityAtEitherSafetyGateLeavesOriginalAndCleansStaging() throws {
        for failingCall in [1, 2] {
            let f = try Fixture()
            let original = try Data(contentsOf: URL(fileURLWithPath: f.file))
            var calls = 0
            let editor = f.editor(active: { _ in
                calls += 1
                if calls == failingCall { throw WireGuardRuntimeActivityError.unavailable }
                return false
            })
            let snapshot = try editor.readSnapshot(named: "work")
            XCTAssertThrowsError(try editor.save(named: "work", revision: snapshot.revision, text: "changed")) {
                XCTAssertEqual($0 as? ConfigEditStoreError, .unavailable)
            }
            XCTAssertEqual(calls, failingCall)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: f.file)), original)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.first), ["work.conf"])
        }
    }

    func testRuntimePermissionLossDuringStagingCannotCommit() throws {
        guard geteuid() != 0 else { throw XCTSkip("Permission regression requires a non-root test process") }
        let f = try Fixture()
        let runtime = f.root + "/runtime"
        try FileManager.default.createDirectory(atPath: runtime, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { chmod(runtime, 0o700) }
        let original = try Data(contentsOf: URL(fileURLWithPath: f.file))
        let probe = WireGuardRuntimeActivityProbe(directoryPath: runtime)
        var operations = ConfigEditWriteOperations()
        operations.write = { descriptor, bytes, count in
            XCTAssertEqual(chmod(runtime, 0o000), 0)
            return Darwin.write(descriptor, bytes, count)
        }
        let editor = f.editor(active: { try probe.isActive(named: $0) }, operations: operations)
        let snapshot = try editor.readSnapshot(named: "work")
        XCTAssertThrowsError(try editor.save(named: "work", revision: snapshot.revision, text: "changed")) {
            XCTAssertEqual($0 as? ConfigEditStoreError, .unavailable)
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: f.file)), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.first), ["work.conf"])
    }

    func testOneShotReportsUnavailableRatherThanSavingUnknownActivity() throws {
        let f = try Fixture()
        let original = try Data(contentsOf: URL(fileURLWithPath: f.file))
        let editor = f.editor(active: { _ in throw WireGuardRuntimeActivityError.unavailable })
        let snapshot = try editor.readSnapshot(named: "work")
        let request = ConfigEditMessage(kind: .save, text: "changed", revision: snapshot.revision)
        let response = performConfigEditRequest(request, named: "work", saving: true, editor: editor)
        XCTAssertEqual(response, ConfigEditMessage(kind: .unavailable))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: f.file)), original)
    }
}
