import Darwin
import Foundation
import XCTest
@testable import WGStatusBarCore

final class HomebrewConfigEditorTests: XCTestCase {
    private func tree() throws -> (root: String, etc: String, directory: String) {
        let root = "/private/tmp/wghb-" + String(UUID().uuidString.prefix(8))
        let etc = root + "/homebrew/etc"
        let directory = etc + "/wireguard"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        XCTAssertEqual(chmod(etc, 0o775), 0)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: root) }
        return (root, etc, directory)
    }
    private func store(_ directory: String, active: @escaping (String) throws -> Bool = { _ in false }) -> TunnelConfigEditor {
        TunnelConfigEditor(searchPaths: [directory], ownerUID: geteuid(), allowTemporaryRoot: true,
            userScoped: true, locksExternallyHeld: true, tunnelIsActive: active)
    }

    func testActualHomebrewPermissionsCanBeEditedAsTheirUserWithoutChowningDirectories() throws {
        guard geteuid() != 0 else { throw XCTSkip("User worker tests require a non-root process") }
        let paths = try tree()
        let path = paths.directory + "/work.conf"
        try Data("[Interface]\n# synthetic\n".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(chmod(path, 0o644), 0)
        var before = stat()
        XCTAssertEqual(lstat(path, &before), 0)
        let editor = store(paths.directory)
        let snapshot = try editor.readSnapshot(named: "work")
        try editor.save(named: "work", revision: snapshot.revision, text: "[Interface]\n# saved\n")
        var after = stat(), parent = stat()
        XCTAssertEqual(lstat(path, &after), 0)
        XCTAssertEqual(lstat(paths.etc, &parent), 0)
        XCTAssertEqual(after.st_uid, before.st_uid)
        XCTAssertEqual(after.st_gid, before.st_gid)
        XCTAssertEqual(after.st_mode & 0o777, 0o600)
        XCTAssertEqual(parent.st_uid, geteuid())
        XCTAssertEqual(parent.st_mode & 0o777, 0o775)
        XCTAssertEqual(try String(contentsOfFile: path), "[Interface]\n# saved\n")
    }

    func testRootPolicyStillRejectsTheSameGroupWritableTree() throws {
        let paths = try tree()
        let strict = SecureConfigFileSystem(ownerUID: geteuid(), allowTemporaryRoot: true)
        XCTAssertThrowsError(try strict.openDirectory(paths.directory))
    }

    func testUserPolicyRejectsWorldWritableParentsAndUnsafeFiles() throws {
        let paths = try tree()
        let path = paths.directory + "/work.conf"
        try Data("synthetic".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(chmod(path, 0o600), 0)
        XCTAssertEqual(chmod(paths.etc, 0o777), 0)
        XCTAssertThrowsError(try store(paths.directory).readSnapshot(named: "work"))
        XCTAssertEqual(chmod(paths.etc, 0o775), 0)
        XCTAssertEqual(chmod(path, 0o666), 0)
        XCTAssertThrowsError(try store(paths.directory).readSnapshot(named: "work"))
        XCTAssertEqual(chmod(path, 0o600), 0)
        XCTAssertEqual(link(path, paths.root + "/hardlink"), 0)
        XCTAssertThrowsError(try store(paths.directory).readSnapshot(named: "work"))
    }

    func testUserSaveStillRefusesActiveUnknownAndStaleRevision() throws {
        let paths = try tree()
        let path = paths.directory + "/work.conf"
        let original = Data("synthetic".utf8)
        try original.write(to: URL(fileURLWithPath: path))
        let snapshot = try store(paths.directory).readSnapshot(named: "work")
        for unknown in [false, true] {
            let editor = store(paths.directory, active: { _ in
                if unknown { throw WireGuardRuntimeActivityError.unavailable }
                return true
            })
            XCTAssertThrowsError(try editor.save(named: "work", revision: snapshot.revision, text: "changed"))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), original)
        }
        try Data("external".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try store(paths.directory).save(named: "work", revision: snapshot.revision, text: "changed")) {
            XCTAssertEqual($0 as? ConfigEditStoreError, .conflict)
        }
    }

    func testUserScopeCannotBeUsedUnderAnotherIdentity() throws {
        let paths = try tree()
        let editor = TunnelConfigEditor(searchPaths: [paths.directory], ownerUID: geteuid() == 0 ? 501 : 0,
            allowTemporaryRoot: true, userScoped: true, locksExternallyHeld: true, tunnelIsActive: { _ in false })
        XCTAssertThrowsError(try editor.readSnapshot(named: "work"))
    }

    func testAdminGroupOfUserOwnedConfigurationIsPreserved() throws {
        var groups = [gid_t](repeating: 0, count: Int(NGROUPS_MAX))
        let count = getgroups(Int32(groups.count), &groups)
        guard count > 0, groups.prefix(Int(count)).contains(80), geteuid() != 0 else { throw XCTSkip("User is not in admin group") }
        let paths = try tree()
        let path = paths.directory + "/work.conf"
        try Data("synthetic".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(chown(path, uid_t.max, 80), 0)
        let editor = store(paths.directory)
        let before = try editor.readSnapshot(named: "work")
        try editor.save(named: "work", revision: before.revision, text: "changed")
        var metadata = stat()
        XCTAssertEqual(lstat(path, &metadata), 0)
        XCTAssertEqual(metadata.st_uid, geteuid())
        XCTAssertEqual(metadata.st_gid, 80)
        XCTAssertEqual(metadata.st_mode & 0o777, 0o600)
    }
}
