import Darwin
import Foundation

/// Authenticated one-shot channel. Never used by the shared daemon socket.
/// One owner uses a channel serially; each direction carries exactly one frame.
final class ConfigEditChannel {
enum Failure: Error, Equatable {
        case peerRejected, invalidEndpoint, invalidFrame, tooLarge, timedOut, cancelled, io, reused
    }

    static let maximumBytes = 256 * 1024
    private static let magic: [UInt8] = [0x57, 0x47, 0x45, 0x31]
    let descriptor: Int32
    private let deadline: TimeInterval
    private let payloadLimit: Int
    private let cancelled: () -> Bool
    private var hasSent = false
    private var hasReceived = false

    /// Consumes the descriptor even if authentication fails. Credentials are
    /// obtained from the kernel, never decoded from a message or argv.
init(descriptor: Int32, expectedUID: uid_t, expectedPID: pid_t,
         timeout: TimeInterval, limit: Int = ConfigEditChannel.maximumBytes, cancelled: @escaping () -> Bool = { false }) throws {
        var transferred = false
        defer { if !transferred { close(descriptor) } }
        guard timeout.isFinite, timeout > 0 else { throw Failure.timedOut }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        if cancelled() { throw Failure.cancelled }
        guard limit > 0, limit <= 2 * 1024 * 1024 else { throw Failure.tooLarge }
        guard expectedPID > 0 else { throw Failure.peerRejected }
        var uid: uid_t = 0
        var gid: gid_t = 0
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getpeereid(descriptor, &uid, &gid) == 0,
              getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0,
              length == MemoryLayout<pid_t>.size,
              uid == expectedUID, pid == expectedPID else { throw Failure.peerRejected }
        let flags = fcntl(descriptor, F_GETFL)
        let descriptorFlags = fcntl(descriptor, F_GETFD)
        var noSignal: Int32 = 1
        guard flags >= 0, descriptorFlags >= 0,
              fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                         socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw Failure.io }
        // Immediate connect can skip polling; cancellation must still win setup.
        if cancelled() { throw Failure.cancelled }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.timedOut }
        self.descriptor = descriptor
        self.deadline = deadline
        self.payloadLimit = limit
        self.cancelled = cancelled
        transferred = true
    }

    deinit { close(descriptor) }

    func send(_ text: String) throws {
        guard !hasSent else { throw Failure.reused }
        hasSent = true
        guard text.utf8.count <= payloadLimit else { throw Failure.tooLarge }
        let payload = Array(text.utf8)
        let length = UInt32(payload.count)
        let header = Self.magic + [UInt8(truncatingIfNeeded: length >> 24),
                                   UInt8(truncatingIfNeeded: length >> 16),
                                   UInt8(truncatingIfNeeded: length >> 8),
                                   UInt8(truncatingIfNeeded: length)]
        try writeAll(header)
        try writeAll(payload)
        try checkDeadline()
        guard shutdown(descriptor, SHUT_WR) == 0 else { throw Failure.io }
    }

    func receive() throws -> String {
        guard !hasReceived else { throw Failure.reused }
        hasReceived = true
        let header = try readExactly(8)
        guard Array(header.prefix(4)) == Self.magic else { throw Failure.invalidFrame }
        let length = header.suffix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length <= payloadLimit else { throw Failure.tooLarge }
        let bytes = try readExactly(Int(length))
        try requireEOF()
        guard let text = String(bytes: bytes, encoding: .utf8) else { throw Failure.invalidFrame }
        return text
    }

    private func checkDeadline() throws {
        if cancelled() { throw Failure.cancelled }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.timedOut }
    }

    private func waitFor(_ events: Int16) throws {
        while true {
            try checkDeadline()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            let milliseconds = Int32(max(1, min(20, remaining * 1000)))
            var entry = pollfd(fd: descriptor, events: events, revents: 0)
            let count = poll(&entry, 1, milliseconds)
            if count < 0 {
                if errno == EINTR { continue }
                throw Failure.io
            }
            if count == 0 { continue }
            guard entry.revents & Int16(POLLNVAL) == 0 else { throw Failure.io }
            try checkDeadline()
            return
        }
    }

    private func writeAll(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            try waitFor(Int16(POLLOUT))
            let count = bytes.withUnsafeBytes {
                Darwin.send(descriptor, $0.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
            }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw Failure.io
            }
            guard count > 0 else { throw Failure.io }
            offset += count
        }
    }

    private func readExactly(_ count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            try waitFor(Int16(POLLIN))
            let received = bytes.withUnsafeMutableBytes {
                recv(descriptor, $0.baseAddress!.advanced(by: offset), count - offset, 0)
            }
            if received < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw Failure.io
            }
            guard received > 0 else { throw Failure.invalidFrame }
            offset += received
        }
        return bytes
    }

    private func requireEOF() throws {
        while true {
            try waitFor(Int16(POLLIN))
            var byte: UInt8 = 0
            let received = recv(descriptor, &byte, 1, 0)
            if received < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw Failure.io
            }
            guard received == 0 else { throw Failure.invalidFrame }
            return
        }
    }

    /// The sticky tmp exception is for this unprivileged test spike only. A
    /// production root helper must use a fixed, protected runtime namespace.
    static func connect(path: String, expectedUID: uid_t, expectedPID: pid_t,
                        timeout: TimeInterval, limit: Int = ConfigEditChannel.maximumBytes, cancelled: @escaping () -> Bool = { false }) throws
        -> ConfigEditChannel {
        guard timeout.isFinite, timeout > 0 else { throw Failure.timedOut }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        if cancelled() { throw Failure.cancelled }
        try validateEndpoint(path: path, expectedUID: expectedUID)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.io }
        var transferred = false
        defer { if !transferred { close(descriptor) } }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { throw Failure.io }
        let connected = try withSocketAddress(path: path) { Darwin.connect(descriptor, $0, $1) }
        if connected != 0 {
            guard errno == EINPROGRESS else { throw Failure.io }
            try finishConnect(descriptor: descriptor, deadline: deadline, cancelled: cancelled)
        }
        // The initializer consumes the fd on both success and failure.
        transferred = true
        return try ConfigEditChannel(descriptor: descriptor, expectedUID: expectedUID,
            expectedPID: expectedPID, timeout: deadline - ProcessInfo.processInfo.systemUptime, limit: limit,
            cancelled: cancelled)
    }

private static func validateEndpoint(path: String, expectedUID: uid_t) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix("/"), !path.utf8.contains(0),
              path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path),
              components.count >= 3,
              components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw Failure.invalidEndpoint }
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw Failure.invalidEndpoint }
        defer { close(directory) }
        try requireNoExtendedACL(descriptor: directory)
        var prefix = ""
        for component in components.dropFirst().dropLast() {
            prefix += "/" + component
            let next = openat(directory, String(component),
                              O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard next >= 0 else { throw Failure.invalidEndpoint }
            close(directory)
            directory = next
            var entry = stat()
            guard fstat(directory, &entry) == 0,
                  entry.st_uid == 0 || entry.st_uid == expectedUID else { throw Failure.invalidEndpoint }
            try requireNoExtendedACL(descriptor: directory)
            let trustedStickyTmp = expectedUID != 0 && prefix == "/private/tmp" && entry.st_uid == 0
                && entry.st_mode & S_ISVTX != 0
            guard entry.st_mode & 0o022 == 0 || trustedStickyTmp else { throw Failure.invalidEndpoint }
        }
        var parent = stat()
        guard fstat(directory, &parent) == 0, parent.st_uid == expectedUID,
              parent.st_mode & 0o022 == 0 else { throw Failure.invalidEndpoint }
        var entry = stat()
        guard fstatat(directory, String(components.last!), &entry, AT_SYMLINK_NOFOLLOW) == 0,
              entry.st_mode & S_IFMT == S_IFSOCK, entry.st_uid == expectedUID
        else { throw Failure.invalidEndpoint }
    }

    private static func finishConnect(descriptor: Int32, deadline: TimeInterval,
                                      cancelled: () -> Bool) throws {
        while true {
            if cancelled() { throw Failure.cancelled }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw Failure.timedOut }
            var entry = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&entry, 1, Int32(max(1, min(20, remaining * 1000))))
            if ready < 0 {
                if errno == EINTR { continue }
                throw Failure.io
            }
            if ready == 0 { continue }
            var failure: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &length) == 0,
                  failure == 0 else { throw Failure.io }
            return
        }
    }

    /// Fail closed rather than treating mode bits as an ACL permission check.
    /// This spike conservatively rejects even harmless extended ACLs.
    static func requireNoExtendedACL(descriptor: Int32) throws {
        errno = 0
        if let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) {
            acl_free(UnsafeMutableRawPointer(acl))
            throw Failure.invalidEndpoint
        }
        guard errno == ENOENT else { throw Failure.invalidEndpoint }
    }

    static func withSocketAddress<R>(path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) -> R) throws -> R {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard !bytes.contains(0), bytes.count < MemoryLayout.size(ofValue: address.sun_path)
        else { throw Failure.invalidEndpoint }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            for (index, byte) in bytes.enumerated() { destination[index] = byte }
        }
        return withUnsafePointer(to: address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}
