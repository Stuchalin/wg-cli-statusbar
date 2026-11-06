import ConfigEditPOSIX
import Darwin
import Foundation

struct ConfigEditWorkerIdentity {
    let uid: uid_t
    let gid: gid_t
    let groups: [gid_t]

init(uid: uid_t) throws {
        guard uid != 0 else { throw ConfigEditStoreError.unsafeConfiguration }
        var storage = [CChar](repeating: 0, count: 16 * 1024)
        let identity: (name: String, gid: gid_t) = try storage.withUnsafeMutableBufferPointer { buffer in
            var record = passwd()
            var result: UnsafeMutablePointer<passwd>?
            guard getpwuid_r(uid, &record, buffer.baseAddress, buffer.count, &result) == 0,
                  result != nil, record.pw_uid == uid, let username = record.pw_name else {
                throw ConfigEditStoreError.unavailable
            }
            return (String(cString: username), record.pw_gid)
        }
        var groupList = [Int32](repeating: 0, count: Int(NGROUPS_MAX))
        var count = Int32(groupList.count)
        let status = identity.name.withCString { getgrouplist($0, Int32(bitPattern: identity.gid), &groupList, &count) }
        guard status == 0, count > 0, count <= NGROUPS_MAX else { throw ConfigEditStoreError.unavailable }
        self.uid = uid
        self.gid = identity.gid
        self.groups = groupList.prefix(Int(count)).map { gid_t(bitPattern: $0) }
    }
}

struct ConfigEditUserWorker {
    let executable: String
    init(executable: String = InstalledHelperPaths.binary) { self.executable = executable }

    func run(request: ConfigEditMessage, named name: String, uid: uid_t, saving: Bool, directoryIndex: Int,
             lease: TunnelOperationLease, activity: (String) throws -> Bool) -> ConfigEditMessage {
        var input: [Int32] = [-1, -1]
        var output: [Int32] = [-1, -1]
        var child: pid_t = -1
        var reaped = false
        defer {
            for fd in input + output where fd >= 0 { close(fd) }
            if child > 0 && !reaped {
                Self.terminateAndReap(child)
            }
        }
        do {
            let identity = try ConfigEditWorkerIdentity(uid: uid)
            let leaseCopy = try lease.duplicateDescriptor()
            defer { close(leaseCopy) }
            guard pipe(&input) == 0, pipe(&output) == 0 else { throw ConfigEditStoreError.unavailable }
            for fd in input + output { guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw ConfigEditStoreError.unavailable } }
            let arguments = [executable, "--user-config-edit", name, saving ? "save" : "read", String(directoryIndex)]
            let strings = arguments.map { strdup($0) }
            defer { strings.forEach { free($0) } }
            guard strings.allSatisfy({ $0 != nil }) else { throw ConfigEditStoreError.unavailable }
            var argv = strings + [nil]
            child = identity.groups.withUnsafeBufferPointer { groups in
                argv.withUnsafeMutableBufferPointer { arguments in
                    executable.withCString {
                        wg_edit_spawn($0, arguments.baseAddress, uid, identity.gid, groups.baseAddress,
                            groups.count, input[0], output[1], leaseCopy)
                    }
                }
            }
            guard child > 0 else { throw ConfigEditStoreError.unavailable }
            close(input[0]); input[0] = -1
            close(output[1]); output[1] = -1
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            let channel = try ConfigEditWorkerPipe(input: output[0], output: input[1])
            let reply = try Self.exchange(request: request, saving: saving, channel: channel, activity: { try activity(name) })
            while true {
                var status: Int32 = 0
                let waited = waitpid(child, &status, WNOHANG)
                if waited == child {
                    reaped = true
                    guard status == 0 else { throw ConfigEditStoreError.unavailable }
                    return reply
                }
                guard waited == 0 || errno == EINTR,
                      ProcessInfo.processInfo.systemUptime < deadline else { throw ConfigEditStoreError.unavailable }
                Thread.sleep(forTimeInterval: 0.002)
            }
        } catch {
            return ConfigEditMessage(kind: saving ? .unknownCommitOutcome : .unavailable)
        }
    }

    static func exchange(request: ConfigEditMessage, saving: Bool, channel: ConfigEditWorkerPipe,
                         activity: () throws -> Bool) throws -> ConfigEditMessage {
        try channel.writeLine(request.encoded())
        var checks = 0
        while true {
            let line = try channel.readLine()
            if line == "activity" {
                guard saving, checks < 2 else { throw ConfigEditStoreError.unavailable }
                checks += 1
                let answer: String
                do { answer = try activity() ? "active" : "inactive" }
                catch ConfigEditStoreError.conflict { answer = "conflict" }
                catch { answer = "unknown" }
                try channel.writeLine(answer)
            } else {
                guard line.hasPrefix("result ") else { throw ConfigEditStoreError.unavailable }
                let reply = try ConfigEditMessage.decode(String(line.dropFirst(7)))
                guard reply.kind != .saved || (saving && checks == 2) else { throw ConfigEditStoreError.unknownCommitOutcome }
                return reply
            }
        }
    }

    private static func terminateAndReap(_ child: pid_t) {
        kill(child, SIGKILL)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.1
        repeat {
            var status: Int32 = 0
            let result = waitpid(child, &status, WNOHANG)
            if result == child || (result < 0 && errno == ECHILD) { return }
            if result < 0 && errno != EINTR { break }
            Thread.sleep(forTimeInterval: 0.002)
        } while ProcessInfo.processInfo.systemUptime < deadline
        // Do not block the socket deadline on an uninterruptible filesystem call.
        // The inherited descriptor keeps the lease until the child actually exits.
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while waitpid(child, &status, 0) < 0 && errno == EINTR {}
        }
    }
}

/// Executed only after permanently dropping credentials in the fork/exec shim.
/// Direct invocation as a user grants no privileges beyond that user's files.

func validInheritedConfigEditLease(_ descriptor: Int32) -> Bool {
    var status = stat()
    let flags = fcntl(descriptor, F_GETFL)
    return flags >= 0 && flags & O_ACCMODE == O_RDONLY && fstat(descriptor, &status) == 0
        && status.st_mode & S_IFMT == S_IFREG && status.st_uid == 0
        && status.st_mode & 0o077 == 0 && status.st_mode & 0o400 != 0
        && status.st_nlink == 1 && status.st_size == 0
}
public func runHelperUserConfigEditWorker(named name: String, saving: Bool, directoryIndex: Int) -> Int32 {
    guard getuid() != 0, geteuid() == getuid(), getgid() == getegid(),
          validInheritedConfigEditLease(STDERR_FILENO), TunnelConfigStore.isNameShapeValid(name), TunnelConfigEditor.searchPaths.indices.contains(directoryIndex) else { return 2 }
    do {
        let channel = try ConfigEditWorkerPipe(input: STDIN_FILENO, output: STDOUT_FILENO)
        try performUserConfigEditTransaction(named: name, saving: saving, channel: channel, searchPaths: [TunnelConfigEditor.searchPaths[directoryIndex]])
        return 0
    } catch { return 1 }
}


func performUserConfigEditTransaction(named name: String, saving: Bool, channel: ConfigEditWorkerPipe,
                                      searchPaths: [String] = TunnelConfigEditor.searchPaths,
                                      allowTemporaryRoot: Bool = false) throws {
    guard getuid() != 0, geteuid() == getuid() else { throw ConfigEditStoreError.unsafeConfiguration }
    let request = try ConfigEditMessage.decode(channel.readLine())
    let editor = TunnelConfigEditor(searchPaths: searchPaths, ownerUID: geteuid(), allowTemporaryRoot: allowTemporaryRoot,
        userScoped: true, locksExternallyHeld: true, tunnelIsActive: { _ in
            try channel.writeLine("activity")
            switch try channel.readLine() {
            case "inactive": return false
            case "active": return true
            case "conflict": throw ConfigEditStoreError.conflict
            default: throw WireGuardRuntimeActivityError.unavailable
            }
        })
    let reply = performConfigEditRequest(request, named: name, saving: saving, editor: editor)
    try channel.writeLine("result " + reply.encoded())
}
func performScopedConfigEditRequest(_ request: ConfigEditMessage, launch: ConfigEditLaunch,
                                   resolver: ConfigEditFileScopeResolver = ConfigEditFileScopeResolver(),
                                   worker: ConfigEditUserWorker = ConfigEditUserWorker()) -> ConfigEditMessage {
    do {
        guard launch.saving ? request.kind == .save : request.kind == .read else { return ConfigEditMessage(kind: .invalidDocument) }
        let scope = try resolver.resolve(named: launch.name, clientUID: launch.clientUID)
        let activity: (String) throws -> Bool = { name in
            guard try resolver.resolve(named: name, clientUID: launch.clientUID) == scope else { throw ConfigEditStoreError.conflict }
            return try WireGuardRuntimeActivityProbe().isActive(named: name)
        }
        let reply: ConfigEditMessage
        switch scope {
        case .rootOwned(let index):
            let editor = TunnelConfigEditor(searchPaths: [resolver.searchPaths[index]], tunnelIsActive: activity)
            reply = performConfigEditRequest(request, named: launch.name, saving: launch.saving, editor: editor)
        case .userOwned(let index):
            let lock = TunnelOperationLock(directoryPath: TunnelOperationLock.directory,
                fileSystem: SecureConfigFileSystem(ownerUID: 0, allowTemporaryRoot: false))
            let lease = try lock.acquire(named: launch.name)
            defer { lease.release() }
            reply = worker.run(request: request, named: launch.name, uid: launch.clientUID, saving: launch.saving,
                directoryIndex: index, lease: lease, activity: activity)
        }
        if reply.kind == .loaded, try resolver.resolve(named: launch.name, clientUID: launch.clientUID) != scope {
            return ConfigEditMessage(kind: .conflict)
        }
        return reply
    } catch ConfigEditStoreError.unsafeConfiguration { return ConfigEditMessage(kind: .unsafeConfiguration) }
    catch ConfigEditStoreError.conflict { return ConfigEditMessage(kind: .conflict) }
    catch ConfigEditStoreError.busy { return ConfigEditMessage(kind: .busy) }
    catch { return ConfigEditMessage(kind: .unavailable) }
}
