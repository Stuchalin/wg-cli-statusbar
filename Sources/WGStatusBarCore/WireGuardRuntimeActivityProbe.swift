import Darwin
import Foundation

enum WireGuardRuntimeActivityError: Error, Equatable { case unavailable }

struct WireGuardRuntimeActivityRecord {
    let interfaceName: String
    let modificationDate: Date
}

protocol WireGuardRuntimeActivityFileSystem {
    func directoryEntries(atPath path: String) throws -> [String]
    func nameRecord(atPath path: String) throws -> WireGuardRuntimeActivityRecord
    func socketModificationDate(atPath path: String) throws -> Date
}

/// Unlike the display reader, this safety gate must distinguish DOWN from UNKNOWN.
/// Only a successful directory scan with no selected .name record proves DOWN.
struct WireGuardRuntimeActivityProbe {
    private let directoryPath: String
    private let fileSystem: WireGuardRuntimeActivityFileSystem

    init(directoryPath: String = "/private/var/run/wireguard",
         fileSystem: WireGuardRuntimeActivityFileSystem = PosixWireGuardRuntimeActivityFileSystem()) {
        self.directoryPath = directoryPath
        self.fileSystem = fileSystem
    }

    func isActive(named name: String) throws -> Bool {
        guard TunnelConfigStore.isNameShapeValid(name) else { throw WireGuardRuntimeActivityError.unavailable }
        let entries = try fileSystem.directoryEntries(atPath: directoryPath)
        guard entries.contains(name + ".name") else { return false }
        let record = try fileSystem.nameRecord(atPath: directoryPath + "/" + name + ".name")
        let interface = record.interfaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard interface.hasPrefix("utun"), interface.utf8.count > 4, interface.utf8.count <= 64,
              interface.utf8.dropFirst(4).allSatisfy({ (48...57).contains($0) }) else {
            throw WireGuardRuntimeActivityError.unavailable
        }
        let socketDate = try fileSystem.socketModificationDate(atPath: directoryPath + "/" + interface + ".sock")
        // A stale/broken pair is ambiguous, not permission to modify its config.
        guard abs(socketDate.timeIntervalSince(record.modificationDate)) < 2 else {
            throw WireGuardRuntimeActivityError.unavailable
        }
        return true
    }
}

struct PosixWireGuardRuntimeActivityFileSystem: WireGuardRuntimeActivityFileSystem {
    func directoryEntries(atPath path: String) throws -> [String] {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw WireGuardRuntimeActivityError.unavailable }
        guard let directory = fdopendir(descriptor) else {
            close(descriptor)
            throw WireGuardRuntimeActivityError.unavailable
        }
        defer { closedir(directory) }
        var entries: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw WireGuardRuntimeActivityError.unavailable }
                return entries
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) {
                String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
            }
            if name != "." && name != ".." { entries.append(name) }
        }
    }

    func nameRecord(atPath path: String) throws -> WireGuardRuntimeActivityRecord {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw WireGuardRuntimeActivityError.unavailable }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0, before.st_size <= 64 else { throw WireGuardRuntimeActivityError.unavailable }
        var bytes = [UInt8](repeating: 0, count: 65)
        var count = 0
        var interrupted = 0
        while count < bytes.count {
            let received = bytes.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress!.advanced(by: count), $0.count - count)
            }
            if received < 0, errno == EINTR, interrupted < 1024 { interrupted += 1; continue }
            guard received >= 0 else { throw WireGuardRuntimeActivityError.unavailable }
            if received == 0 { break }
            interrupted = 0
            count += received
        }
        var after = stat()
        guard count <= 64, fstat(descriptor, &after) == 0, before.st_size == after.st_size,
              count == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              let interface = String(bytes: bytes.prefix(count), encoding: .utf8) else {
            throw WireGuardRuntimeActivityError.unavailable
        }
        return WireGuardRuntimeActivityRecord(interfaceName: interface, modificationDate: modificationDate(after))
    }

    func socketModificationDate(atPath path: String) throws -> Date {
        var metadata = stat()
        guard lstat(path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFSOCK else {
            throw WireGuardRuntimeActivityError.unavailable
        }
        return modificationDate(metadata)
    }

    private func modificationDate(_ metadata: stat) -> Date {
        Date(timeIntervalSince1970: Double(metadata.st_mtimespec.tv_sec) + Double(metadata.st_mtimespec.tv_nsec) / 1_000_000_000)
    }
}
