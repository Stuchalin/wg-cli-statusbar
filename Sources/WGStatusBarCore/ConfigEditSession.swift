import Darwin
import Foundation

/// Exclusive, root-owned bootstrap namespace for one authenticated operation.
final class ConfigEditSession {
    typealias Failure = ConfigEditChannel.Failure
    let socketPath: String
    private let parentDescriptor: Int32
    private let directoryDescriptor: Int32
    private let listener: Int32
    private let name: String
    private var published = false

    init(parent: String, session: String, owner: uid_t) throws {
        let name = try Self.sessionName(session)
        let parentDescriptor = try Self.openDirectory(parent, owner: owner)
        var directory: Int32 = -1
        var listener: Int32 = -1
        var created = false
        var transferred = false
        defer {
            if !transferred {
                if listener >= 0 { close(listener) }
                if directory >= 0 { unlinkat(directory, "channel", 0); close(directory) }
                if created { unlinkat(parentDescriptor, name, AT_REMOVEDIR) }
                close(parentDescriptor)
            }
        }
        guard owner == geteuid() else { throw Failure.invalidEndpoint }
        // Publish traversable metadata atomically; avoid a cross-UID EACCES window.
        let creationMask = umask(0o022)
        let made = mkdirat(parentDescriptor, name, 0o755)
        umask(creationMask)
        guard made == 0 else { throw Failure.invalidEndpoint }
        created = true
        directory = openat(parentDescriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0, fchmod(directory, 0o755) == 0 else { throw Failure.io }
        try ConfigEditChannel.requireNoExtendedACL(descriptor: directory)
        let path = parent + "/" + name + "/channel"
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw Failure.io }
        let flags = fcntl(listener, F_GETFL)
        guard flags >= 0, fcntl(listener, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(listener, F_SETFD, FD_CLOEXEC) == 0 else { throw Failure.io }
        let previousMask = umask(0o077)
        let bound: Int32
        do {
            bound = try ConfigEditChannel.withSocketAddress(path: path) { Darwin.bind(listener, $0, $1) }
        } catch {
            umask(previousMask)
            throw error
        }
        umask(previousMask)
        guard bound == 0, fchmodat(directory, "channel", 0o666, 0) == 0,
              Darwin.listen(listener, 4) == 0 else { throw Failure.io }
        self.socketPath = path
        self.parentDescriptor = parentDescriptor
        self.directoryDescriptor = directory
        self.listener = listener
        self.name = name
        transferred = true
    }

    deinit {
        close(listener)
        unlinkat(directoryDescriptor, "ready", 0)
        unlinkat(directoryDescriptor, ".ready-pending", 0)
        unlinkat(directoryDescriptor, "channel", 0)
        close(directoryDescriptor)
        unlinkat(parentDescriptor, name, AT_REMOVEDIR)
        close(parentDescriptor)
    }

    func publishReady() throws {
        guard !published else { throw Failure.reused }
        let descriptor = openat(directoryDescriptor, ".ready-pending",
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.io }
        defer { close(descriptor); unlinkat(directoryDescriptor, ".ready-pending", 0) }
        let bytes = Array("\(getpid())\n".utf8)
        var offset = 0
        var interruptions = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes {
                Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if count < 0, errno == EINTR, interruptions < 8 { interruptions += 1; continue }
            guard count > 0 else { throw Failure.io }
            offset += count
        }
        guard fchmod(descriptor, 0o644) == 0, fsync(descriptor) == 0,
              renameatx_np(directoryDescriptor, ".ready-pending", directoryDescriptor,
                           "ready", UInt32(RENAME_EXCL)) == 0 else { throw Failure.io }
        published = true
    }

    func acceptOne(timeout: TimeInterval) throws -> Int32 {
        guard timeout.isFinite, timeout > 0 else { throw Failure.timedOut }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw Failure.timedOut }
            var entry = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let ready = poll(&entry, 1, Int32(max(1, min(50, remaining * 1000))))
            if ready < 0 {
                if errno == EINTR { continue }
                throw Failure.io
            }
            if ready == 0 { continue }
            let peer = Darwin.accept(listener, nil, nil)
            if peer < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw Failure.io
            }
            guard fcntl(peer, F_SETFD, FD_CLOEXEC) == 0 else { close(peer); throw Failure.io }
            return peer
        }
    }

    static func serverPID(parent: String, session: String, owner: uid_t) throws -> pid_t? {
        let name = try sessionName(session)
        let parentDescriptor = try openDirectory(parent, owner: owner)
        defer { close(parentDescriptor) }
        let directory = openat(parentDescriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if directory < 0, errno == ENOENT { return nil }
        guard directory >= 0 else { throw Failure.invalidEndpoint }
        defer { close(directory) }
        try verifyDirectory(directory, owner: owner, allowRoot: false)
        let descriptor = openat(directory, "ready", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw Failure.invalidEndpoint }
        defer { close(descriptor) }
        var entry = stat()
        guard fstat(descriptor, &entry) == 0, entry.st_uid == owner,
              entry.st_mode & S_IFMT == S_IFREG, entry.st_mode & 0o022 == 0,
              entry.st_nlink == 1, entry.st_size > 0, entry.st_size < 32 else { throw Failure.invalidEndpoint }
        try ConfigEditChannel.requireNoExtendedACL(descriptor: descriptor)
        var bytes = [UInt8](repeating: 0, count: 32)
        let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        guard count == entry.st_size, let text = String(bytes: bytes.prefix(count), encoding: .utf8),
              text.hasSuffix("\n"), let pid = pid_t(text.dropLast()), pid > 0 else { throw Failure.invalidFrame }
        return pid
    }

    private static func sessionName(_ session: String) throws -> String {
        guard UUID(uuidString: session)?.uuidString == session else { throw Failure.invalidEndpoint }
        return "wge-session-" + session
    }

    private static func openDirectory(_ path: String, owner: uid_t) throws -> Int32 {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix("/"), !path.utf8.contains(0),
              parts.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw Failure.invalidEndpoint
        }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw Failure.invalidEndpoint }
        var transferred = false
        defer { if !transferred { close(current) } }
        try verifyDirectory(current, owner: owner, allowRoot: true)
        var prefix = ""
        for part in parts.dropFirst() {
            let next = openat(current, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw Failure.invalidEndpoint }
            close(current)
            current = next
            prefix += "/" + part
            try verifyDirectory(current, owner: owner, allowRoot: true, stickyTmp: owner != 0 && prefix == "/private/tmp")
        }
        try verifyDirectory(current, owner: owner, allowRoot: false)
        transferred = true
        return current
    }

    private static func verifyDirectory(_ descriptor: Int32, owner: uid_t,
                                         allowRoot: Bool, stickyTmp: Bool = false) throws {
        var entry = stat()
        guard fstat(descriptor, &entry) == 0, entry.st_mode & S_IFMT == S_IFDIR,
              entry.st_uid == owner || (allowRoot && entry.st_uid == 0) else { throw Failure.invalidEndpoint }
        let trustedTmp = stickyTmp && entry.st_uid == 0 && entry.st_mode & S_ISVTX != 0
        guard entry.st_mode & 0o022 == 0 || trustedTmp else { throw Failure.invalidEndpoint }
        try ConfigEditChannel.requireNoExtendedACL(descriptor: descriptor)
    }
}
