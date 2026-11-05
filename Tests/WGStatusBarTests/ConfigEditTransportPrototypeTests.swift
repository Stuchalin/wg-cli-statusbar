import Darwin
import Foundation
import XCTest
@testable import WGStatusBarCore

final class ConfigEditTransportPrototypeTests: XCTestCase {
    private func pair() throws -> (Int32, Int32) {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(.EIO)
        }
        return (descriptors[0], descriptors[1])
    }

    private func channel(_ descriptor: Int32, timeout: TimeInterval = 0.5,
                         cancelled: @escaping () -> Bool = { false }) throws -> ConfigEditTransportPrototype {
        try ConfigEditTransportPrototype(descriptor: descriptor, expectedUID: geteuid(),
                                         expectedPID: getpid(), timeout: timeout, cancelled: cancelled)
    }

    private func write(_ bytes: [UInt8], to descriptor: Int32, eof: Bool = true) throws {
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes {
                Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            guard count > 0 else { throw POSIXError(.EIO) }
            offset += count
        }
        if eof { _ = shutdown(descriptor, SHUT_WR) }
    }

    private func frame(_ bytes: [UInt8]) -> [UInt8] {
        let count = UInt32(bytes.count)
        return [0x57, 0x47, 0x45, 0x31,
                UInt8(truncatingIfNeeded: count >> 24), UInt8(truncatingIfNeeded: count >> 16),
                UInt8(truncatingIfNeeded: count >> 8), UInt8(truncatingIfNeeded: count)] + bytes
    }

    func testRealKernelCredentialsAllowOneSyntheticDocument() throws {
        let (first, second) = try pair()
        defer { close(second) }
        let receiver = try channel(first)
        let text = "[Interface]\nAddress = 10.0.0.2/32\n# синтетический документ"
        try write(frame(Array(text.utf8)), to: second)
        XCTAssertEqual(try receiver.receive(), text)
        XCTAssertThrowsError(try receiver.receive()) {
            XCTAssertEqual($0 as? ConfigEditTransportPrototype.Failure, .reused)
        }
    }

    func testRejectsUnexpectedUIDBeforeReading() throws {
        let (first, second) = try pair()
        defer { close(second) }
        XCTAssertThrowsError(try ConfigEditTransportPrototype(
            descriptor: first, expectedUID: geteuid() == 0 ? 1 : 0,
            expectedPID: getpid(), timeout: 0.1
        )) {
            XCTAssertEqual($0 as? ConfigEditTransportPrototype.Failure, .peerRejected)
        }
    }

    func testRejectsUnexpectedPIDBeforeReading() throws {
        let (first, second) = try pair()
        defer { close(second) }
        XCTAssertThrowsError(try ConfigEditTransportPrototype(
            descriptor: first, expectedUID: geteuid(), expectedPID: getpid() + 1, timeout: 0.1
        )) {
            XCTAssertEqual($0 as? ConfigEditTransportPrototype.Failure, .peerRejected)
        }
    }

    func testFrameRejectsWrongVersionTruncationInvalidUTF8AndExtraMessages() throws {
        let invalid: [[UInt8]] = [
            [0x57, 0x47, 0x45, 0x32, 0, 0, 0, 0],
            [0x57, 0x47],
            [0x57, 0x47, 0x45, 0x31, 0, 0, 0, 2, 65],
            frame([0xff]),
            frame([]) + frame([])
        ]
        for bytes in invalid {
            let (first, second) = try pair()
            defer { close(second) }
            let receiver = try channel(first)
            try write(bytes, to: second)
            XCTAssertThrowsError(try receiver.receive()) {
                XCTAssertEqual($0 as? ConfigEditTransportPrototype.Failure, .invalidFrame)
            }
        }
    }

    func testOversizedHeaderIsRejectedWithoutWaitingForBody() throws {
        let (first, second) = try pair()
        defer { close(second) }
        let receiver = try channel(first)
        try write([0x57, 0x47, 0x45, 0x31, 0, 4, 0, 1], to: second, eof: false)
        XCTAssertThrowsError(try receiver.receive()) {
            XCTAssertEqual($0 as? ConfigEditTransportPrototype.Failure, .tooLarge)
        }
    }

    func testSilentPeerAndMissingEOFRespectWholeSessionDeadline() throws {
        for bytes in [[], frame([])] {
            let (first, second) = try pair()
            defer { close(second) }
            let receiver = try channel(first, timeout: 0.05)
            try write(bytes, to: second, eof: false)
            let start = ProcessInfo.processInfo.systemUptime
            XCTAssertThrowsError(try receiver.receive()) {
                XCTAssertEqual($0 as? ConfigEditTransportPrototype.Failure, .timedOut)
            }
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        }
    }

    func testCancellationInterruptsSilentPeer() throws {
        let (first, second) = try pair()
        defer { close(second) }
        let start = ProcessInfo.processInfo.systemUptime
        let receiver = try channel(first, timeout: 2) {
            ProcessInfo.processInfo.systemUptime - start > 0.03
        }
        XCTAssertThrowsError(try receiver.receive()) {
            XCTAssertEqual($0 as? ConfigEditTransportPrototype.Failure, .cancelled)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
    }

    func testEmptyAndMaximumSizeDocumentsRoundTripWithoutNormalization() throws {
        for text in ["", String(repeating: "x", count: 256 * 1024 - 1) + "\n"] {
            let (first, second) = try pair()
            let sender = try channel(first, timeout: 3)
            let receiver = try channel(second, timeout: 3)
            let done = expectation(description: "bounded send")
            DispatchQueue.global().async {
                defer { done.fulfill() }
                do { try sender.send(text) } catch { XCTFail("Synthetic send failed") }
            }
            XCTAssertEqual(try receiver.receive(), text)
            wait(for: [done], timeout: 4)
            XCTAssertThrowsError(try sender.send(text)) {
                XCTAssertEqual($0 as? ConfigEditTransportPrototype.Failure, .reused)
            }
        }
    }

    func testOversizedSendDoesNotWritePayload() throws {
        let (first, second) = try pair()
        defer { close(second) }
        let sender = try channel(first)
        XCTAssertThrowsError(try sender.send(String(repeating: "x", count: 256 * 1024 + 1))) {
            XCTAssertEqual($0 as? ConfigEditTransportPrototype.Failure, .tooLarge)
        }
        var byte: UInt8 = 0
        XCTAssertEqual(recv(second, &byte, 1, MSG_DONTWAIT), -1)
        XCTAssertEqual(errno, EAGAIN)
    }

    func testDescriptorsAreClosedOnRejectionAndMarkedCloseOnExecOnSuccess() throws {
        let (first, second) = try pair()
        defer { close(second) }
        do {
            let connected = try channel(first)
            XCTAssertNotEqual(fcntl(connected.descriptor, F_GETFD) & FD_CLOEXEC, 0)
            XCTAssertNotEqual(fcntl(connected.descriptor, F_GETFL) & O_NONBLOCK, 0)
        }
        XCTAssertEqual(fcntl(first, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
        let (rejected, peer) = try pair()
        defer { close(peer) }
        XCTAssertThrowsError(try ConfigEditTransportPrototype(
            descriptor: rejected, expectedUID: geteuid(), expectedPID: -1, timeout: 0.1))
        XCTAssertEqual(fcntl(rejected, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
    }

    func testPeerDisconnectDoesNotRaiseSIGPIPE() throws {
        let (first, second) = try pair()
        let sender = try channel(first)
        close(second)
        XCTAssertThrowsError(try sender.send("synthetic"))
    }

    func testFragmentedHeaderAndBodyPreserveExactUTF8() throws {
        let (first, second) = try pair()
        let receiver = try channel(first, timeout: 2)
        let text = "synthetic\r\n# тест\n"
        let bytes = frame(Array(text.utf8))
        let done = expectation(description: "fragmented synthetic frame")
        DispatchQueue.global().async {
            defer { close(second); done.fulfill() }
            for byte in bytes {
                var value = byte
                guard Darwin.write(second, &value, 1) == 1 else {
                    XCTFail("Fragment write failed")
                    return
                }
                Thread.sleep(forTimeInterval: 0.001)
            }
            _ = shutdown(second, SHUT_WR)
        }
        XCTAssertEqual(try receiver.receive(), text)
        wait(for: [done], timeout: 3)
    }

    func testBlockedSendTimesOutAndCanBeCancelled() throws {
        for shouldCancel in [false, true] {
            let (first, second) = try pair()
            defer { close(second) }
            var size: Int32 = 4096
            XCTAssertEqual(setsockopt(first, SOL_SOCKET, SO_SNDBUF, &size,
                                     socklen_t(MemoryLayout<Int32>.size)), 0)
            let start = ProcessInfo.processInfo.systemUptime
            let sender = try channel(first, timeout: shouldCancel ? 2 : 0.05) {
                shouldCancel && ProcessInfo.processInfo.systemUptime - start > 0.03
            }
            XCTAssertThrowsError(try sender.send(String(repeating: "x", count: 256 * 1024))) {
                XCTAssertEqual($0 as? ConfigEditTransportPrototype.Failure,
                               shouldCancel ? .cancelled : .timedOut)
            }
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        }
    }

    func testSlowTrickleCannotExtendTheSessionDeadline() throws {
        let (first, second) = try pair()
        let receiver = try channel(first, timeout: 0.08)
        let bytes = frame(Array("synthetic document".utf8))
        let done = expectation(description: "bounded slow synthetic peer")
        DispatchQueue.global().async {
            defer { close(second); done.fulfill() }
            var noSignal: Int32 = 1
            _ = setsockopt(second, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                           socklen_t(MemoryLayout<Int32>.size))
            for byte in bytes {
                var value = byte
                if Darwin.write(second, &value, 1) != 1 { return }
                Thread.sleep(forTimeInterval: 0.01)
            }
            _ = shutdown(second, SHUT_WR)
        }
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try receiver.receive()) {
            XCTAssertEqual($0 as? ConfigEditTransportPrototype.Failure, .timedOut)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        withExtendedLifetime(receiver) { wait(for: [done], timeout: 2) }
    }

    func testAlreadyCancelledAuthenticationConsumesAndClosesDescriptor() throws {
        let (first, second) = try pair()
        defer { close(second) }
        XCTAssertThrowsError(try ConfigEditTransportPrototype(descriptor: first,
            expectedUID: geteuid(), expectedPID: getpid(), timeout: 1, cancelled: { true })) {
            XCTAssertEqual($0 as? ConfigEditTransportPrototype.Failure, .cancelled)
        }
        XCTAssertEqual(fcntl(first, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
    }
}
