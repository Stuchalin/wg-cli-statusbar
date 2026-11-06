import XCTest
@testable import WGStatusBarCore

final class PrivilegedConfigEditorTests: XCTestCase {
    private final class Probe: PrivilegedHelperProbingFileSystem {
        var unsafe = false
        var calls = 0
        func statEntry(atPath path: String) -> PrivilegedHelperStatEntry? {
            calls += 1
            return PrivilegedHelperStatEntry(kind: ["/", "/Library", InstalledHelperPaths.directory].contains(path) ? .directory : .regularFile,
                ownerUID: unsafe ? 501 : 0, permissions: 0o755)
        }
    }
    private final class Runner: PrivilegedProcessRunning {
        var calls: [[String]] = []
        var outdated = false
        func run(_ argv: [String], timeout: TimeInterval?, maxCollectedBytes: Int) async -> PrivilegedProcessOutcome {
            calls.append(argv)
            if outdated { return .success(stdout: "capabilities 1 19 config-raw-v1\n") }
            return .success(stdout: argv.last == "--capabilities" ? helperCapabilitiesOutput() : helperConfigEditCapabilitiesOutput())
        }
    }
    private final class Auth: ConfigRevealAuthenticating {
        var calls = 0
        var outcome: ConfigRevealAuthOutcome = .success
        func authenticate(reason: String) async -> ConfigRevealAuthOutcome { calls += 1; return outcome }
    }
    private final class Exchange: ConfigEditSessionExchanging {
        var calls = 0
        var result: ConfigEditExchangeResult = .reply(ConfigEditMessage(kind: .loaded, text: "raw synthetic", revision: String(repeating: "a", count: 64)))
        func exchange(launch: ConfigEditLaunch, message: ConfigEditMessage, runner: PrivilegedProcessRunning) async -> ConfigEditExchangeResult {
            calls += 1
            return result
        }
    }
    private func make(_ probe: Probe, _ runner: Runner, _ auth: Auth, _ exchange: Exchange) -> PrivilegedConfigEditor {
        PrivilegedConfigEditor(fileSystem: probe, processRunner: runner, authenticator: auth, exchange: exchange)
    }

    func testStateAndUnsafeHelperFailBeforeAuthenticationOrExchange() async {
        let p = Probe(), r = Runner(), a = Auth(), x = Exchange()
        let editor = make(p, r, a, x)
        let absent = await editor.loadForEditing(named: "work", serviceState: .absent)
        XCTAssertEqual(absent, .failed(.privileged(.serviceInstallRequired)))
        XCTAssertEqual(p.calls, 0)
        p.unsafe = true
        let result = await editor.loadForEditing(named: "work", serviceState: .installed)
        XCTAssertEqual(result, .failed(.privileged(.helperUnavailable)))
        XCTAssertEqual(a.calls, 0)
        XCTAssertEqual(x.calls, 0)
    }

    func testOldBuildNeverReceivesNewFlagAndDoesNotPrompt() async {
        let p = Probe(), r = Runner(), a = Auth(), x = Exchange()
        r.outdated = true
        let result = await make(p, r, a, x).loadForEditing(named: "work", serviceState: .installed)
        XCTAssertEqual(result, .failed(.privileged(.helperOutdated)))
        XCTAssertEqual(r.calls.count, 1)
        XCTAssertEqual(a.calls, 0)
    }

    func testEverySaveUsesFreshAuthenticationAndDoesNotReuseLoadedAuthorization() async {
        let p = Probe(), r = Runner(), a = Auth(), x = Exchange()
        let editor = make(p, r, a, x)
        let loaded = await editor.loadForEditing(named: "work", serviceState: .installed)
        guard case .snapshot(let snapshot) = loaded else { return XCTFail("No document") }
        x.result = .reply(ConfigEditMessage(kind: .saved))
        let saved = await editor.save(named: "work", revision: snapshot.revision, text: "new", serviceState: .installed)
        XCTAssertEqual(saved, .saved)
        XCTAssertEqual(a.calls, 2)
        XCTAssertEqual(x.calls, 2)
        a.outcome = .userCancelled
        let cancelled = await editor.save(named: "work", revision: snapshot.revision, text: "new", serviceState: .installed)
        XCTAssertEqual(cancelled, .cancelled)
        XCTAssertEqual(x.calls, 2)
    }

    func testDisconnectAfterRequestIsUnknownCommitAndMalformedLoadedDocumentIsRejected() async {
        let p = Probe(), r = Runner(), a = Auth(), x = Exchange()
        let editor = make(p, r, a, x)
        x.result = .uncertainAfterRequest
        let saved = await editor.save(named: "work", revision: String(repeating: "a", count: 64), text: "new", serviceState: .installed)
        XCTAssertEqual(saved, .failed(.unknownCommitOutcome))
        x.result = .reply(ConfigEditMessage(kind: .loaded, text: "raw", revision: "bad"))
        let loaded = await editor.loadForEditing(named: "work", serviceState: .installed)
        XCTAssertEqual(loaded, .failed(.unavailable))
    }

    func testEditorCapabilityParserAcceptsNewerBuildButRejectsMalformedOrOldResponses() {
        XCTAssertNil(PrivilegedConfigEditor.validateEditorCapabilities("config-edit \(helperProtocolVersion) \(helperBuildNumber + 1) config-edit-v1\n"))
        XCTAssertNotNil(PrivilegedConfigEditor.validateEditorCapabilities("config-edit 1 19 config-edit-v1\n"))
        XCTAssertNotNil(PrivilegedConfigEditor.validateEditorCapabilities("config-edit 1 20 config-edit-v1 extra\n"))
    }

    func testInvalidSaveAcknowledgementRequiresUnknownCommitHandling() async {
        let p = Probe(), r = Runner(), a = Auth(), x = Exchange()
        x.result = .reply(ConfigEditMessage(kind: .loaded, text: "unexpected", revision: String(repeating: "a", count: 64)))
        let result = await make(p, r, a, x).save(named: "work", revision: String(repeating: "a", count: 64), text: "new", serviceState: .installed)
        XCTAssertEqual(result, .failed(.unknownCommitOutcome))
    }

    func testExtendedHelperACLIsRejectedEvenWithSafeModeBits() {
        let directory = PrivilegedHelperStatEntry(kind: .directory, ownerUID: 0, permissions: 0o755, hasExtendedACL: true)
        let binary = PrivilegedHelperStatEntry(kind: .regularFile, ownerUID: 0, permissions: 0o755, hasExtendedACL: true)
        XCTAssertEqual(PrivilegedConfigReader.preflightDirectoryFailure(directory), .helperUnavailable)
        XCTAssertEqual(PrivilegedConfigReader.preflightBinaryFailure(binary), .helperUnavailable)
    }

    func testUnsafeConfigurationReplyIsNotCollapsedIntoGenericUnavailable() async {
        let p = Probe(), r = Runner(), a = Auth(), x = Exchange()
        x.result = .reply(ConfigEditMessage(kind: .unsafeConfiguration))
        let result = await make(p, r, a, x).loadForEditing(named: "work", serviceState: .installed)
        XCTAssertEqual(result, .failed(.unsafeConfiguration))
    }
}
