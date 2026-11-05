import Darwin
import Foundation

/// Shared by one-shot saves and production daemon up/down. Only metadata
/// lives here; no config contents. External wg-quick does not honor this lock.
struct TunnelOperationLock {
    static let directory = "/private/var/db/wgstatusbar-operation-locks"
    let directoryPath: String
    let fileSystem: SecureConfigFileSystem

func withLock<T>(named name: String, timeout: TimeInterval = 1,
                     cancelled: () -> Bool = { false }, _ operation: () throws -> T) throws -> T {
        let lease = try acquire(named: name, timeout: timeout, cancelled: cancelled)
        defer { lease.release() }
        return try operation()
    }

func acquire(named name: String, timeout: TimeInterval = 1, cancelled: () -> Bool = { false }) throws -> TunnelOperationLease {
        guard TunnelConfigStore.isNameShapeValid(name) else { throw ConfigEditStoreError.invalidName }
        guard timeout.isFinite, timeout > 0 else { throw ConfigEditStoreError.busy }
        let parent = (directoryPath as NSString).deletingLastPathComponent
        let basename = (directoryPath as NSString).lastPathComponent
        guard !basename.isEmpty, let parentDescriptor = try fileSystem.openDirectory(parent) else {
            throw ConfigEditStoreError.unavailable
        }
        defer { close(parentDescriptor) }
        let made = mkdirat(parentDescriptor, basename, 0o700)
        guard made == 0 || errno == EEXIST else { throw ConfigEditStoreError.unavailable }
        let directory = openat(parentDescriptor, basename, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw ConfigEditStoreError.unavailable }
        defer { close(directory) }
        try fileSystem.verifyDirectory(directory, requireOwner: true)
        let descriptor = openat(directory, name + ".lock", O_RDONLY | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ConfigEditStoreError.unavailable }
        var transferred = false
        defer { if !transferred { close(descriptor) } }
        guard try fileSystem.fileStatus(descriptor).st_size == 0 else { throw ConfigEditStoreError.unavailable }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            if cancelled() { throw ConfigEditStoreError.cancelled }
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { break }
            guard errno == EWOULDBLOCK || errno == EINTR else { throw ConfigEditStoreError.unavailable }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ConfigEditStoreError.busy }
            Thread.sleep(forTimeInterval: 0.005)
        }

        if cancelled() { flock(descriptor, LOCK_UN); throw ConfigEditStoreError.cancelled }
        transferred = true
        return TunnelOperationLease(descriptor: descriptor)
}
func acquireAsync(named name: String) async throws -> TunnelOperationLease {
        let flag = TunnelLockCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async {
                    do { continuation.resume(returning: try acquire(named: name, cancelled: { flag.isCancelled })) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { flag.cancel() })
    }
}

final class TunnelOperationLease {
    private let lock = NSLock()
    private var descriptor: Int32
    init(descriptor: Int32) { self.descriptor = descriptor }
    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
    }
    deinit { release() }

    /// A read-only duplicate may be inherited by the restricted worker. Closing
    /// the parent copy must not unlock a still-running child transaction.
    func duplicateDescriptor() throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { throw ConfigEditStoreError.unavailable }
        let copy = fcntl(descriptor, F_DUPFD_CLOEXEC, 3)
        guard copy >= 0 else { throw ConfigEditStoreError.unavailable }
        return copy
    }
}

private final class TunnelLockCancellation: @unchecked Sendable {
    // This flag crosses GCD/task cancellation boundaries; all access is locked.
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
