import Darwin
import Foundation
import XCTest
@testable import WGStatusBarCore

final class ConfigEditExchangeTests: XCTestCase {
    private final class Runner: PrivilegedProcessRunning {
        let body: () async -> PrivilegedProcessOutcome
        init(_ body: @escaping () async -> PrivilegedProcessOutcome) { self.body = body }
        func run(_ argv: [String], timeout: TimeInterval?, maxCollectedBytes: Int) async -> PrivilegedProcessOutcome { await body() }
    }

    func testRealSocketExchangeVerifiesPeersAndPreservesDocument() async throws {
        let parent = "/private/tmp/wgxt-" + String(UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: parent) }
        let nonce = UUID().uuidString
        let session = try ConfigEditSession(parent: parent, session: nonce, owner: geteuid())
        try session.publishReady()
        let server = Task.detached { () throws -> Void in
            let channel = try ConfigEditChannel(descriptor: session.acceptOne(timeout: 2), expectedUID: geteuid(),
                expectedPID: getpid(), timeout: 2, limit: ConfigEditMessage.wireLimit)
            XCTAssertEqual(try ConfigEditMessage.decode(channel.receive()).kind, .read)
            try channel.send(ConfigEditMessage(kind: .loaded, text: "synthetic\r\n", revision: String(repeating: "a", count: 64)).encoded())
        }
        let runner = Runner {
            do { try await server.value; return .success(stdout: "") }
            catch { return .failure(.exitFailure) }
        }
        let exchange = ConfigEditExchange(runtimeParent: parent, serverOwnerUID: geteuid())
        let launch = ConfigEditLaunch(name: "work", clientUID: geteuid(), clientPID: getpid(), session: nonce, saving: false)
        let result = await exchange.exchange(launch: launch, message: ConfigEditMessage(kind: .read), runner: runner)
        guard case .reply(let reply) = result else { return XCTFail("No authenticated response") }
        XCTAssertEqual(Array(try XCTUnwrap(reply.text).utf8), Array("synthetic\r\n".utf8))
    }

    func testCancelledAdministratorPromptHasNoRequestOutcome() async {
        let launch = ConfigEditLaunch(name: "work", clientUID: geteuid(), clientPID: getpid(), session: UUID().uuidString, saving: true)
        let result = await ConfigEditExchange().exchange(launch: launch, message: ConfigEditMessage(kind: .save), runner: Runner { .promptCancelled })
        guard case .cancelledBeforeRequest = result else { return XCTFail("Cancelled prompt was not silent") }
    }

    func testTaskCancellationStopsWaitingForAnUnansweredPrompt() async throws {
        let launch = ConfigEditLaunch(name: "work", clientUID: geteuid(), clientPID: getpid(), session: UUID().uuidString, saving: false)
        let runner = Runner {
            do { try await Task.sleep(nanoseconds: 30_000_000_000); return .success(stdout: "") }
            catch { return .failure(.cancelled) }
        }
        let task = Task { await ConfigEditExchange().exchange(launch: launch, message: ConfigEditMessage(kind: .read), runner: runner) }
        try await Task.sleep(nanoseconds: 30_000_000)
        task.cancel()
        let result = await task.value
        guard case .cancelledBeforeRequest = result else { return XCTFail("Cancelled wait was not stopped") }
    }
}
