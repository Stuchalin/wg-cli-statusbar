import Darwin
import Foundation

/// Bounded private parent/worker stream. JSON escapes document line breaks;
/// activity controls and final results are separate, strictly delimited lines.
final class ConfigEditWorkerPipe {
    private let input: Int32
    private let output: Int32
    private let deadline: TimeInterval
    private var pending = Data()
    static let lineLimit = ConfigEditMessage.wireLimit + 16

    init(input: Int32, output: Int32, timeout: TimeInterval = 3) throws {
        self.input = input
        self.output = output
        self.deadline = ProcessInfo.processInfo.systemUptime + timeout
        for fd in [input, output] {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw ConfigEditStoreError.unavailable }
        }
        guard fcntl(output, F_SETNOSIGPIPE, 1) == 0 else { throw ConfigEditStoreError.unavailable }
    }

    func readLine() throws -> String {
        while true {
            if let end = pending.firstIndex(of: 10) {
                let bytes = pending.prefix(upTo: end)
                guard bytes.count <= Self.lineLimit, let line = String(data: bytes, encoding: .utf8) else {
                    throw ConfigEditStoreError.unavailable
                }
                pending.removeSubrange(...end)
                return line
            }
            try wait(fd: input, events: Int16(POLLIN))
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = chunk.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count > 0, pending.count + count <= Self.lineLimit + 1 else { throw ConfigEditStoreError.unavailable }
            pending.append(contentsOf: chunk.prefix(count))
        }
    }

    func writeLine(_ line: String) throws {
        guard line.utf8.count <= Self.lineLimit, !line.contains("\n") else { throw ConfigEditStoreError.unavailable }
        let bytes = Array((line + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            try wait(fd: output, events: Int16(POLLOUT))
            let count = bytes.withUnsafeBytes { Darwin.write(output, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count > 0 else { throw ConfigEditStoreError.unavailable }
            offset += count
        }
    }

    private func wait(fd: Int32, events: Int16) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw ConfigEditStoreError.unavailable }
            var poller = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&poller, 1, Int32(max(1, min(50, remaining * 1000))))
            if result < 0 { if errno == EINTR { continue }; throw ConfigEditStoreError.unavailable }
            if result == 0 { continue }
            guard poller.revents & Int16(POLLNVAL) == 0 else { throw ConfigEditStoreError.unavailable }
            return
        }
    }
}
