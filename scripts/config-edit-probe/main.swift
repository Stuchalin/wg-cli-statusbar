import CryptoKit
import Darwin
import Foundation

// Synthetic-data, one-shot diagnostic. Never reads a WireGuard config or installs
// the service. --privileged shows the normal macOS administrator prompt.
typealias ProbeFailure = ConfigEditChannel.Failure
let requestText = "synthetic-probe-v1\n"
let responseText = "synthetic-response-v1\n"
let rootRuntime = "/private/var/db"



func privilegedArguments(executable: String, uid: uid_t, pid: pid_t, session: String) throws -> [String] {
    try ConfigEditProbeCommand.privilegedArguments(executable: executable, uid: uid, pid: pid, session: session)
}

func expectFailure(_ expected: ProbeFailure, _ operation: () throws -> Void) throws {
    do { try operation() } catch let failure as ProbeFailure {
        guard failure == expected else { throw failure }
        return
    }
    throw ProbeFailure.invalidFrame
}

func serve(parent: String, owner: uid_t, clientUID: uid_t, clientPID: pid_t, session: String) throws {
    let server = try ConfigEditSession(parent: parent, session: session, owner: owner)
    // An actual second UID (root) in privileged mode; a second PID in self-test.
    // It must be rejected before any document is exchanged.
    do {
        let impostor = try ConfigEditChannel.connect(path: server.socketPath,
            expectedUID: owner, expectedPID: getpid(), timeout: 2)
        _ = impostor
        try expectFailure(.peerRejected) {
            _ = try ConfigEditChannel(descriptor: server.acceptOne(timeout: 2),
                expectedUID: clientUID, expectedPID: clientPID, timeout: 2)
        }
    }
    try server.publishReady()
    do {
        let peer = try ConfigEditChannel(descriptor: server.acceptOne(timeout: 10),
            expectedUID: clientUID, expectedPID: clientPID, timeout: 2)
        guard try peer.receive() == requestText else { throw ProbeFailure.invalidFrame }
        try peer.send(responseText)
    }
    do {
        let peer = try ConfigEditChannel(descriptor: server.acceptOne(timeout: 2),
            expectedUID: clientUID, expectedPID: clientPID, timeout: 2)
        try expectFailure(.invalidFrame) { _ = try peer.receive() }
    }
    do {
        let peer = try ConfigEditChannel(descriptor: server.acceptOne(timeout: 2),
            expectedUID: clientUID, expectedPID: clientPID, timeout: 0.15)
        try expectFailure(.timedOut) { _ = try peer.receive() }
    }
    do {
        let started = ProcessInfo.processInfo.systemUptime
        let peer = try ConfigEditChannel(descriptor: server.acceptOne(timeout: 2),
            expectedUID: clientUID, expectedPID: clientPID, timeout: 2, cancelled: {
                ProcessInfo.processInfo.systemUptime - started > 0.06
            })
        try expectFailure(.cancelled) { _ = try peer.receive() }
    }
    print("probe-ok: credentials roundtrip truncation timeout cancellation")
}

func runClient(privileged: Bool) throws {
    guard geteuid() != 0 else { throw ProbeFailure.peerRejected }
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
    let session = UUID().uuidString
    let owner: uid_t = privileged ? 0 : geteuid()
    let parent = privileged ? rootRuntime : "/private/tmp/wgep-" + String(UUID().uuidString.prefix(8))
    if !privileged {
        guard mkdir(parent, 0o700) == 0 else { throw ProbeFailure.io }
    }
    defer { if !privileged { rmdir(parent) } }
    let child = Process()
    let output = Pipe()
    child.standardOutput = output
    child.standardError = FileHandle.nullDevice
    child.standardInput = FileHandle.nullDevice
    if privileged {
        child.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        child.arguments = try privilegedArguments(executable: executable, uid: geteuid(), pid: getpid(), session: session)
    } else {
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = ["--serve-unprivileged", parent, String(geteuid()), String(getpid()), session]
    }
    try child.run()
    defer { if child.isRunning { child.terminate() } }
    let bootstrapDeadline = ProcessInfo.processInfo.systemUptime + 120
    var serverPID: pid_t?
    while child.isRunning {
        serverPID = try ConfigEditSession.serverPID(parent: parent, session: session, owner: owner)
        if serverPID != nil { break }
        guard ProcessInfo.processInfo.systemUptime < bootstrapDeadline else { throw ProbeFailure.timedOut }
        Thread.sleep(forTimeInterval: 0.02)
    }
    guard let serverPID else { throw ProbeFailure.peerRejected }
    let path = parent + "/wge-session-" + session + "/channel"
    func connect() throws -> ConfigEditChannel {
        try ConfigEditChannel.connect(path: path, expectedUID: owner,
            expectedPID: serverPID, timeout: 2)
    }
    do {
        let channel = try connect()
        try channel.send(requestText)
        guard try channel.receive() == responseText else { throw ProbeFailure.invalidFrame }
    }
    do {
        let channel = try connect()
        var partial: UInt8 = 0x57
        guard Darwin.send(channel.descriptor, &partial, 1, 0) == 1,
              shutdown(channel.descriptor, SHUT_WR) == 0 else { throw ProbeFailure.io }
        try expectFailure(.invalidFrame) { _ = try channel.receive() }
    }
    // The server closes both silent sessions only after observing its own
    // timeout/cancellation. EOF rather than the client's timeout is expected.
    for _ in 0..<2 {
        let channel = try connect()
        try expectFailure(.invalidFrame) { _ = try channel.receive() }
    }
    let exitDeadline = ProcessInfo.processInfo.systemUptime + 5
    while child.isRunning {
        guard ProcessInfo.processInfo.systemUptime < exitDeadline else { throw ProbeFailure.timedOut }
        Thread.sleep(forTimeInterval: 0.01)
    }
    let result = output.fileHandleForReading.readDataToEndOfFile()
    let text = String(data: result, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard child.terminationStatus == 0,
          text == "probe-ok: credentials roundtrip truncation timeout cancellation" else { throw ProbeFailure.io }
    let directory = parent + "/wge-session-" + session
    guard access(directory, F_OK) != 0, errno == ENOENT else { throw ProbeFailure.io }
    print(privileged ? "PASS: root-to-user transport; foreign UID rejected; namespace cleaned"
                     : "PASS: separate-process transport; foreign PID rejected; namespace cleaned")
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    switch arguments.first {
    case "--self-test" where arguments.count == 1:
        try runClient(privileged: false)
    case "--privileged" where arguments.count == 1:
        try runClient(privileged: true)
    case "--serve" where arguments.count == 4:
        guard geteuid() == 0, let uid = uid_t(arguments[1]), uid != 0,
              let pid = pid_t(arguments[2]), pid > 0 else { throw ProbeFailure.peerRejected }
        try serve(parent: rootRuntime, owner: 0, clientUID: uid, clientPID: pid, session: arguments[3])
    case "--serve-unprivileged" where arguments.count == 5:
        guard geteuid() != 0, let uid = uid_t(arguments[2]), uid == geteuid(),
              let pid = pid_t(arguments[3]), pid > 0 else { throw ProbeFailure.peerRejected }
        try serve(parent: arguments[1], owner: uid, clientUID: uid, clientPID: pid, session: arguments[4])
    default:
        throw ProbeFailure.invalidFrame
    }
} catch {
    let category = (error as? ProbeFailure).map { String(describing: $0) } ?? "launchFailed"
    FileHandle.standardError.write(Data("probe failed: \(category)\n".utf8))
    exit(1)
}
