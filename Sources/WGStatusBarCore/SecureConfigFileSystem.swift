import Darwin
import Foundation

/// Detail-free errors: never attach config bytes, paths or names.
enum ConfigEditStoreError: Error, Equatable {
    case invalidName, notFound, unavailable, invalidDocument, conflict
    case unsafeConfiguration
    case activeTunnel, cancelled, busy, unknownCommitOutcome
}

struct SecureConfigFileSystem {
    let ownerUID: uid_t
    let allowTemporaryRoot: Bool

    /// Returns nil only for a missing component; an unsafe ancestor fails closed.
    func openDirectory(_ path: String) throws -> Int32? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix("/"), !path.utf8.contains(0),
              parts.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ConfigEditStoreError.unavailable
        }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ConfigEditStoreError.unavailable }
        var transferred = false
        defer { if !transferred { close(descriptor) } }
        try verifyDirectory(descriptor)
        var prefix = ""
        for part in parts.dropFirst() {
            let next = openat(descriptor, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT { return nil }
            guard next >= 0 else { throw ConfigEditStoreError.unavailable }
            close(descriptor)
            descriptor = next
            prefix += "/" + part
            try verifyDirectory(descriptor, stickyTmp: allowTemporaryRoot && prefix == "/private/tmp")
        }
        try verifyDirectory(descriptor, requireOwner: true)
        transferred = true
        return descriptor
    }

    func verifyDirectory(_ descriptor: Int32, requireOwner: Bool = false, stickyTmp: Bool = false) throws {
        guard !allowUserOwnedGroupWrite || (ownerUID != 0 && geteuid() == ownerUID && getuid() == ownerUID) else {
            throw policyViolation
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw ConfigEditStoreError.unavailable }
        guard status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == ownerUID || (!requireOwner && status.st_uid == 0) else {
            throw policyViolation
        }
        let allowedTmp = stickyTmp && status.st_uid == 0 && status.st_mode & S_ISVTX != 0
        let ownedGroupWrite = allowUserOwnedGroupWrite && status.st_uid == ownerUID && status.st_mode & 0o002 == 0
        guard status.st_mode & 0o022 == 0 || allowedTmp || ownedGroupWrite else { throw policyViolation }
        try rejectExtendedACL(descriptor)
    }

    func fileStatus(_ descriptor: Int32) throws -> stat {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw ConfigEditStoreError.unavailable }
        guard status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == ownerUID, status.st_mode & 0o022 == 0,
              status.st_nlink == 1 else { throw policyViolation }
        try rejectExtendedACL(descriptor)
        return status
    }

    func rejectExtendedACL(_ descriptor: Int32) throws {
        errno = 0
        if let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) {
            acl_free(UnsafeMutableRawPointer(acl))
            throw policyViolation
        }
        guard errno == ENOENT else { throw ConfigEditStoreError.unavailable }
    }

    let allowUserOwnedGroupWrite: Bool
    init(ownerUID: uid_t, allowTemporaryRoot: Bool, allowUserOwnedGroupWrite: Bool = false) {
        self.ownerUID = ownerUID
        self.allowTemporaryRoot = allowTemporaryRoot
        self.allowUserOwnedGroupWrite = allowUserOwnedGroupWrite
    }

    private var policyViolation: ConfigEditStoreError { allowUserOwnedGroupWrite ? .unsafeConfiguration : .unavailable }
}
