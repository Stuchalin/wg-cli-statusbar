import CryptoKit
import Darwin
import Foundation

public struct ConfigEditSnapshot: Equatable {
    public let text: String
    public let revision: String
    public init(text: String, revision: String) { self.text = text; self.revision = revision }
}

struct ConfigEditWriteOperations {
    var write: (Int32, UnsafeRawPointer, Int) -> Int = { Darwin.write($0, $1, $2) }
    var sync: (Int32) -> Int32 = { fsync($0) }
    var replace: (Int32, String, String) -> Int32 = { renameat($0, $1, $0, $2) }
}

/// Secure filesystem core only; not exposed by the daemon socket. Invocation
/// still requires the authenticated privileged one-shot boundary.
struct TunnelConfigEditor {
    static let searchPaths = ["/private/etc/wireguard", "/usr/local/etc/wireguard",
                              "/opt/homebrew/etc/wireguard", "/opt/local/etc/wireguard"]
    private let searchPaths: [String]
    private let fileSystem: SecureConfigFileSystem
    private let lock: TunnelOperationLock
private let tunnelIsActive: (String) throws -> Bool
    private let operations: ConfigEditWriteOperations

    init(searchPaths: [String] = Self.searchPaths,
         lockDirectory: String = TunnelOperationLock.directory,
         ownerUID: uid_t = 0, allowTemporaryRoot: Bool = false,
         userScoped: Bool = false, locksExternallyHeld: Bool = false,
         tunnelIsActive: @escaping (String) throws -> Bool = { name in
             try WireGuardRuntimeActivityProbe().isActive(named: name)
         }, operations: ConfigEditWriteOperations = ConfigEditWriteOperations()) {
        self.userScoped = userScoped
        self.locksExternallyHeld = locksExternallyHeld
        self.searchPaths = searchPaths
        self.fileSystem = SecureConfigFileSystem(ownerUID: ownerUID, allowTemporaryRoot: allowTemporaryRoot, allowUserOwnedGroupWrite: userScoped)
        self.lock = TunnelOperationLock(directoryPath: lockDirectory, fileSystem: self.fileSystem)
        self.tunnelIsActive = tunnelIsActive
        self.operations = operations
    }

    func readSnapshot(named name: String) throws -> ConfigEditSnapshot {
        try verifyFileIdentity()
        guard TunnelConfigStore.isNameShapeValid(name) else { throw ConfigEditStoreError.invalidName }
        return try withOperationLock(named: name) { try openTarget(named: name).snapshot }
    }

    func save(named name: String, revision: String, text: String,
              cancelled: () -> Bool = { false }) throws {
        try verifyFileIdentity()
        guard TunnelConfigStore.isNameShapeValid(name) else { throw ConfigEditStoreError.invalidName }
        guard text.utf8.count <= TunnelConfigReader.maxSizeBytes, !text.utf8.contains(0) else {
            throw ConfigEditStoreError.invalidDocument
        }
        try withOperationLock(named: name, cancelled: cancelled) {
            let target: Target
            do { target = try openTarget(named: name) }
            catch ConfigEditStoreError.notFound { throw ConfigEditStoreError.conflict }
            guard target.snapshot.revision == revision else { throw ConfigEditStoreError.conflict }
            try requireInactive(name)
            if cancelled() { throw ConfigEditStoreError.cancelled }
            let temporary = ".wgstatusbar-edit-" + UUID().uuidString + ".tmp"
            let descriptor = openat(target.directory, temporary,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw ConfigEditStoreError.unavailable }
            defer { close(descriptor); unlinkat(target.directory, temporary, 0) }
            guard fchown(descriptor, uid_t.max, target.groupID) == 0, fchmod(descriptor, 0o600) == 0 else { throw ConfigEditStoreError.unavailable }
            _ = try fileSystem.fileStatus(descriptor)
            try writeAll(Array(text.utf8), to: descriptor, cancelled: cancelled)
            guard operations.sync(descriptor) == 0 else { throw ConfigEditStoreError.unavailable }
            let current: Target
            do { current = try openTarget(named: name) }
            catch ConfigEditStoreError.notFound { throw ConfigEditStoreError.conflict }
            guard current.snapshot.revision == revision else { throw ConfigEditStoreError.conflict }
            try requireInactive(name)
            if cancelled() { throw ConfigEditStoreError.cancelled }
            // Commit point. External root writers can race this final check;
            // POSIX rename is atomic replacement, not filesystem compare-and-swap.
            guard operations.replace(target.directory, temporary, name + ".conf") == 0 else {
                throw ConfigEditStoreError.unavailable
            }
            guard operations.sync(target.directory) == 0 else { throw ConfigEditStoreError.unknownCommitOutcome }
        }
    }

    private final class Target {
        let directory: Int32
        let snapshot: ConfigEditSnapshot
        let groupID: gid_t
        init(directory: Int32, snapshot: ConfigEditSnapshot, groupID: gid_t) {
            self.groupID = groupID
            self.directory = directory
            self.snapshot = snapshot
        }
        deinit { close(directory) }
    }

    private func openTarget(named name: String) throws -> Target {
        for (index, path) in searchPaths.enumerated() {
            guard let directory = try fileSystem.openDirectory(path) else { continue }
            var transferred = false
            defer { if !transferred { close(directory) } }
            let descriptor = openat(directory, name + ".conf", O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            if descriptor < 0, errno == ENOENT { continue }
            guard descriptor >= 0 else { throw ConfigEditStoreError.unavailable }
            defer { close(descriptor) }
            let before = try fileSystem.fileStatus(descriptor)
            guard before.st_size >= 0, before.st_size <= TunnelConfigReader.maxSizeBytes else {
                throw ConfigEditStoreError.invalidDocument
            }
            let bytes = try readAll(descriptor)
            let after = try fileSystem.fileStatus(descriptor)
            guard metadata(before) == metadata(after), bytes.count == after.st_size else {
                throw ConfigEditStoreError.conflict
            }
            guard let text = String(bytes: bytes, encoding: .utf8), !bytes.contains(0) else {
                throw ConfigEditStoreError.invalidDocument
            }
            var directoryStatus = stat()
            guard fstat(directory, &directoryStatus) == 0 else { throw ConfigEditStoreError.unavailable }
            let identity = "v1|\(name)|\(index)|\(directoryStatus.st_dev)|\(directoryStatus.st_ino)|" + metadata(after)
            var revisionData = Data(identity.utf8)
            revisionData.append(contentsOf: bytes)
            let revision = SHA256.hash(data: revisionData).map { String(format: "%02x", $0) }.joined()
            transferred = true
            return Target(directory: directory, snapshot: ConfigEditSnapshot(text: text, revision: revision), groupID: after.st_gid)
        }
        throw ConfigEditStoreError.notFound
    }

    private func metadata(_ status: stat) -> String {
        "\(status.st_dev)|\(status.st_ino)|\(status.st_size)|\(status.st_mtimespec.tv_sec)|"
            + "\(status.st_mtimespec.tv_nsec)|\(status.st_ctimespec.tv_sec)|\(status.st_ctimespec.tv_nsec)"
    }

    private func readAll(_ descriptor: Int32) throws -> [UInt8] {
        var collected: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        var interrupted = 0
        while true {
            let wanted = min(buffer.count, TunnelConfigReader.maxSizeBytes + 1 - collected.count)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, wanted) }
            if count < 0, errno == EINTR, interrupted < 1024 { interrupted += 1; continue }
            guard count >= 0 else { throw ConfigEditStoreError.unavailable }
            if count == 0 { return collected }
            interrupted = 0
            collected.append(contentsOf: buffer.prefix(count))
            guard collected.count <= TunnelConfigReader.maxSizeBytes else { throw ConfigEditStoreError.invalidDocument }
        }
    }

    private func writeAll(_ bytes: [UInt8], to descriptor: Int32, cancelled: () -> Bool) throws {
        var offset = 0
        var interrupted = 0
        while offset < bytes.count {
            if cancelled() { throw ConfigEditStoreError.cancelled }
            let count = bytes.withUnsafeBytes {
                operations.write(descriptor, $0.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if count < 0, errno == EINTR, interrupted < 1024 { interrupted += 1; continue }
            guard count > 0, count <= bytes.count - offset else { throw ConfigEditStoreError.unavailable }
            interrupted = 0
            offset += count
        }
    }

    private func requireInactive(_ name: String) throws {
        let active: Bool
        do { active = try tunnelIsActive(name) }
        catch ConfigEditStoreError.conflict { throw ConfigEditStoreError.conflict }
        catch { throw ConfigEditStoreError.unavailable }
        guard !active else { throw ConfigEditStoreError.activeTunnel }
    }

    private let userScoped: Bool
    private let locksExternallyHeld: Bool

    private func verifyFileIdentity() throws {
        guard !userScoped || (fileSystem.ownerUID != 0 && geteuid() == fileSystem.ownerUID && getuid() == fileSystem.ownerUID) else {
            throw ConfigEditStoreError.unavailable
        }
        guard !locksExternallyHeld || userScoped else { throw ConfigEditStoreError.unavailable }
    }

    private func withOperationLock<T>(named name: String, cancelled: () -> Bool = { false }, _ operation: () throws -> T) throws -> T {
        if locksExternallyHeld {
            if cancelled() { throw ConfigEditStoreError.cancelled }
            return try operation()
        }
        return try lock.withLock(named: name, cancelled: cancelled, operation)
    }
}
