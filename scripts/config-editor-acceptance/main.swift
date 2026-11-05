import Darwin
import Foundation

// Explicitly authorized local QA only: a unique synthetic config, never wg-quick.
// Compile with SecureConfigFileSystem.swift and ConfigSecretFixture.swift.
enum QAError: Error { case invalid, unavailable, unsafe, timedOut }
let arguments = Array(CommandLine.arguments.dropFirst())
guard geteuid() == 0, arguments.count >= 2 else { throw QAError.invalid }
let action = arguments[0]
let name = arguments[1]
guard name.hasPrefix("editqa-"), name.utf8.count == 15,
      name.utf8.dropFirst(7).allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw QAError.invalid }
let security = SecureConfigFileSystem(ownerUID: 0, allowTemporaryRoot: false)
let tag = "WGStatusBar isolated editor QA; NEVER CONNECT"
let filename = name + ".conf"
let marker = Data(configSecretCanary.utf8)

func emit(_ value: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}

func writeAll(_ data: Data, descriptor: Int32) throws {
    var offset = 0
    var interrupted = 0
    while offset < data.count {
        let count = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
        if count < 0, errno == EINTR, interrupted < 1024 { interrupted += 1; continue }
        guard count > 0 else { throw QAError.unavailable }
        interrupted = 0
        offset += count
    }
    guard fsync(descriptor) == 0 else { throw QAError.unavailable }
}

func readFixture(directory: Int32) throws -> (Data, stat) {
    let fd = openat(directory, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw QAError.unavailable }
    defer { close(fd) }
    let metadata = try security.fileStatus(fd)
    guard metadata.st_size > 0, metadata.st_size <= 32 * 1024 else { throw QAError.unsafe }
    var result = Data()
    var bytes = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        if count < 0, errno == EINTR { continue }
        guard count >= 0 else { throw QAError.unavailable }
        if count == 0 { break }
        result.append(contentsOf: bytes.prefix(count))
        guard result.count <= 32 * 1024 else { throw QAError.unsafe }
    }
    guard result.range(of: marker) != nil, result.range(of: Data(tag.utf8)) != nil else { throw QAError.unsafe }
    return (result, metadata)
}


func removeFixtureAndLock(directory: Int32) throws {
    var lockDirectory: Int32 = -1
    var lockDescriptor: Int32 = -1
    defer {
        if lockDescriptor >= 0 { flock(lockDescriptor, LOCK_UN); close(lockDescriptor) }
        if lockDirectory >= 0 { close(lockDirectory) }
    }
    if let locks = try security.openDirectory("/private/var/db/wgstatusbar-operation-locks") {
        lockDirectory = locks
        lockDescriptor = openat(locks, name + ".lock", O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if lockDescriptor < 0, errno != ENOENT { throw QAError.unsafe }
        if lockDescriptor >= 0 {
            let status = try security.fileStatus(lockDescriptor)
            guard status.st_size == 0, flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else { throw QAError.unsafe }
        }
    }
    guard unlinkat(directory, filename, 0) == 0 else { throw QAError.unavailable }
    if lockDescriptor >= 0, unlinkat(lockDirectory, name + ".lock", 0) != 0 { throw QAError.unavailable }
}
func scanFile(_ path: String) throws -> Bool {
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw QAError.unavailable }
    defer { close(fd) }
    let metadata = try security.fileStatus(fd)
    guard metadata.st_size <= 64 * 1024 * 1024 else { throw QAError.unsafe }
    var carry = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        if count < 0, errno == EINTR { continue }
        guard count >= 0 else { throw QAError.unavailable }
        if count == 0 { return false }
        carry.append(contentsOf: buffer.prefix(count))
        if carry.range(of: marker) != nil { return true }
        carry = Data(carry.suffix(max(0, marker.count - 1)))
    }
}

func scanUnifiedLog() throws -> Bool {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    process.arguments = ["show", "--last", "20m", "--style", "json", "--predicate", "process == 'WGStatusBar' OR process == 'WGStatusBarHelper' OR process == 'wg-config-editor-acceptance-client' OR process == 'WGEditorAcceptance'"]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    try process.run()
    defer { if process.isRunning { process.terminate() } }
    let fd = output.fileHandleForReading.fileDescriptor
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw QAError.unavailable }
    let deadline = ProcessInfo.processInfo.systemUptime + 20
    var carry = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    var found = false
    var eof = false
    var total = 0
    while !eof || process.isRunning {
        if ProcessInfo.processInfo.systemUptime >= deadline {
            kill(process.processIdentifier, SIGKILL)
            throw QAError.timedOut
        }
        var entry = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&entry, 1, 50)
        if ready < 0 { if errno == EINTR { continue }; throw QAError.unavailable }
        if ready == 0 { continue }
        let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        if count < 0 {
            if errno == EINTR || errno == EAGAIN { continue }
            throw QAError.unavailable
        }
        if count == 0 { eof = true; continue }
        total += count
        guard total <= 64 * 1024 * 1024 else { throw QAError.unsafe }
        carry.append(contentsOf: buffer.prefix(count))
        found = found || carry.range(of: marker) != nil
        carry = Data(carry.suffix(max(0, marker.count - 1)))
    }
    guard process.terminationStatus == 0 else { throw QAError.unavailable }
    return found
}

do {
    if action == "--logs" {
        let helper = try scanFile("/private/var/log/wgstatusbar-helper.log")
        let unified = try scanUnifiedLog()
        try emit(["helperCanaryFound": helper, "unifiedCanaryFound": unified])
    } else {
        guard let parent = try security.openDirectory("/private/etc") else { throw QAError.unavailable }
        defer { close(parent) }
        var created = false
        if action == "--setup" {
            let made = mkdirat(parent, "wireguard", 0o700)
            guard made == 0 || errno == EEXIST else { throw QAError.unavailable }
            created = made == 0
        }
        let directory = openat(parent, "wireguard", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw QAError.unavailable }
        defer { close(directory) }
        try security.verifyDirectory(directory, requireOwner: true)
        if action == "--setup" {
            let fd = openat(directory, filename, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw QAError.unsafe }
            var complete = false
            defer { close(fd); if !complete { unlinkat(directory, filename, 0) } }
            guard fchmod(fd, 0o600) == 0 else { throw QAError.unavailable }
            let document = "[Interface]\nPrivateKey = \(configSecretCanary)\nAddress = 192.0.2.1/32\n# \(tag)\n"
            try writeAll(Data(document.utf8), descriptor: fd)
            complete = true
            try emit(["created": true, "parentCreated": created, "runtimePresent": access("/private/var/run/wireguard", F_OK) == 0])
        } else {
            let (data, metadata) = try readFixture(directory: directory)
            if action == "--external-change" {
                let fd = openat(directory, filename, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0)
                guard fd >= 0 else { throw QAError.unavailable }
                defer { close(fd) }
                _ = try security.fileStatus(fd)
                try writeAll(Data("# External acceptance update\n".utf8), descriptor: fd)
                try emit(["externalChange": true])
            } else if action == "--verify" {
                try emit(["exists": true, "mode": String(metadata.st_mode & 0o777, radix: 8), "owner": metadata.st_uid,
                          "savedMarker": data.range(of: Data("# Saved via editor QA".utf8)) != nil,
                          "externalMarker": data.range(of: Data("# External acceptance update".utf8)) != nil,
                          "guiSavedMarker": data.range(of: Data("# Saved via GUI QA".utf8)) != nil,
                          "cancelDraftFound": data.range(of: Data("# UI cancellation draft".utf8)) != nil,
                          "conflictDraftFound": data.range(of: Data("must not persist".utf8)) != nil])
            } else if action == "--cleanup" {
                try removeFixtureAndLock(directory: directory)
                if arguments.count == 3, arguments[2] == "remove-empty-parent" {
                    if unlinkat(parent, "wireguard", AT_REMOVEDIR) != 0, errno != ENOTEMPTY { throw QAError.unavailable }
                }
                try emit(["removed": true])
            } else { throw QAError.invalid }
        }
    }
} catch {
    FileHandle.standardError.write(Data("QA operation failed\n".utf8))
    exit(1)
}
