import Darwin
import Foundation

enum ConfigEditExchangeResult {
    case reply(ConfigEditMessage), cancelledBeforeRequest, unavailableBeforeRequest, uncertainAfterRequest
}

protocol ConfigEditSessionExchanging {
    func exchange(launch: ConfigEditLaunch, message: ConfigEditMessage,
                  runner: PrivilegedProcessRunning) async -> ConfigEditExchangeResult
}

struct ConfigEditExchange: ConfigEditSessionExchanging {
    private final class State: @unchecked Sendable {
        // Every read and write of mutable state is protected by lock.
        private let lock = NSLock()
        private var cancellation = false
        private var finished = false
        func cancel() { lock.lock(); cancellation = true; lock.unlock() }
        func finish() { lock.lock(); finished = true; lock.unlock() }
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancellation }
        var ended: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    }
static func command(launch: ConfigEditLaunch) -> [String] {
func quoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
let words = [InstalledHelperPaths.binary, launch.saving ? "--write-config-edit" : "--read-config-edit", launch.name, String(launch.clientUID), String(launch.clientPID), launch.session]
let command = words.map(quoted).joined(separator: " ")
let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return ["/usr/bin/osascript", "-e", "do shell script \"" + escaped + "\" with administrator privileges"]

}
func exchange(launch: ConfigEditLaunch, message: ConfigEditMessage,
                  runner: PrivilegedProcessRunning) async -> ConfigEditExchangeResult {
        let state = State()
        let process = Task {
            let outcome = await runner.run(Self.command(launch: launch), timeout: nil, maxCollectedBytes: 4096)
            state.finish()
            return outcome
        }
        return await withTaskCancellationHandler(operation: {
            let result: ConfigEditExchangeResult = await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    var attempted = false
                    do {
                        var pid: pid_t?
                        while pid == nil {
                            if state.cancelled { throw ConfigEditChannel.Failure.cancelled }
                            pid = try ConfigEditSession.serverPID(parent: runtimeParent, session: launch.session, owner: serverOwnerUID)
                            if pid != nil { break }
                            if state.ended { throw ConfigEditChannel.Failure.io }
                            Thread.sleep(forTimeInterval: 0.02)
                        }
                        guard let pid else { throw ConfigEditChannel.Failure.io }
                        let path = runtimeParent + "/wge-session-" + launch.session + "/channel"
                        let channel = try ConfigEditChannel.connect(path: path, expectedUID: serverOwnerUID, expectedPID: pid,
                            timeout: 5, limit: ConfigEditMessage.wireLimit, cancelled: { state.cancelled })
                        let encoded = try message.encoded()
                        if state.cancelled { throw ConfigEditChannel.Failure.cancelled }
                        attempted = true
                        try channel.send(encoded)
                        let reply = try ConfigEditMessage.decode(channel.receive())
                        continuation.resume(returning: .reply(reply))
                    } catch {
                        continuation.resume(returning: attempted ? .uncertainAfterRequest
                            : state.cancelled ? .cancelledBeforeRequest : .unavailableBeforeRequest)
                    }
                }
            }
            if case .reply = result { _ = await process.value; return result }
            process.cancel()
            let outcome = await process.value
            if case .unavailableBeforeRequest = result, case .promptCancelled = outcome { return .cancelledBeforeRequest }
            return result
        }, onCancel: { state.cancel(); process.cancel() })
    }

    private let runtimeParent: String
    private let serverOwnerUID: uid_t
    init(runtimeParent: String = "/private/var/db", serverOwnerUID: uid_t = 0) {
        self.runtimeParent = runtimeParent
        self.serverOwnerUID = serverOwnerUID
    }
}
