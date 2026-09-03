import LocalAuthentication
import XCTest
@testable import WGStatusBarCore

/// Привилегированный one-shot Reveal: порядок границ fail-closed (сервис →
/// имя → lstat → capability-проба → аутентификация → osascript), фиксация
/// нулевых вызовов за каждой ранней границей, классификация исходов без
/// утечки данных, подавление дублей и продакшн-раннер на реальных процессах
/// (без системных промптов — они не автоматизируются).
final class PrivilegedConfigReaderTests: XCTestCase {
    private let directoryPath = "/Library/PrivilegedHelperTools"
    private let binaryPath = "/Library/PrivilegedHelperTools/com.stuchalin.wgstatusbar.helper"

    // MARK: - Фейки

    private final class FakeProbeFileSystem: PrivilegedHelperProbingFileSystem {
        var entries: [String: PrivilegedHelperStatEntry] = [:]
        private(set) var callCount = 0

        func statEntry(atPath path: String) -> PrivilegedHelperStatEntry? {
            callCount += 1
            return entries[path]
        }
    }

    private struct RecordedCall {
        let argv: [String]
        let timeout: TimeInterval?
        let maxCollectedBytes: Int
    }

    private final class FakeProcessRunner: PrivilegedProcessRunning {
        private(set) var calls: [RecordedCall] = []
        /// Программируемый исход по вызову.
        var handler: (RecordedCall) -> PrivilegedProcessOutcome = { _ in .failure(.exitFailure) }
        /// Искусственная задержка каждого вызова (тест подавления дублей).
        var delayNanoseconds: UInt64 = 0

        func run(_ argv: [String], timeout: TimeInterval?, maxCollectedBytes: Int) async -> PrivilegedProcessOutcome {
            let call = RecordedCall(argv: argv, timeout: timeout, maxCollectedBytes: maxCollectedBytes)
            calls.append(call)
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            return handler(call)
        }
    }

    private final class FakeAuthenticator: ConfigRevealAuthenticating {
        private(set) var callCount = 0
        private(set) var lastReason: String?
        var outcome: ConfigRevealAuthOutcome = .success

        func authenticate(reason: String) async -> ConfigRevealAuthOutcome {
            callCount += 1
            lastReason = reason
            return outcome
        }
    }

    // MARK: - Хелперы фикстур

    private func directoryEntry(
        ownerUID: Int = 0,
        permissions: Int = 0o755,
        symlink: Bool = false
    ) -> PrivilegedHelperStatEntry {
        PrivilegedHelperStatEntry(
            kind: symlink ? .symbolicLink : .directory,
            ownerUID: ownerUID,
            permissions: permissions
        )
    }

    private func binaryEntry(
        ownerUID: Int = 0,
        permissions: Int = 0o755,
        symlink: Bool = false,
        regular: Bool = true
    ) -> PrivilegedHelperStatEntry {
        PrivilegedHelperStatEntry(
            kind: symlink ? .symbolicLink : (regular ? .regularFile : .other),
            ownerUID: ownerUID,
            permissions: permissions
        )
    }

    private func makeFS(
        directory: PrivilegedHelperStatEntry? = nil,
        binary: PrivilegedHelperStatEntry? = nil
    ) -> FakeProbeFileSystem {
        let fs = FakeProbeFileSystem()
        fs.entries[directoryPath] = directory
        fs.entries[binaryPath] = binary
        return fs
    }

    /// Полный happy-path до аутентификации включительно: capability-проба
    /// отвечает собственным валидным ответом, osascript — конвертом текста.
    private func makeHappyRunner(osascriptOutcome: PrivilegedProcessOutcome? = nil) -> FakeProcessRunner {
        let runner = FakeProcessRunner()
        let defaultEnvelope = PrivilegedConfigReaderTests.envelope("[Interface]\nPrivateKey = raw\n")
        runner.handler = { call in
            if call.argv.last == "--capabilities" {
                return .success(stdout: helperCapabilitiesOutput())
            }
            return osascriptOutcome ?? .success(stdout: defaultEnvelope)
        }
        return runner
    }

    /// Конверт `b64:` вокруг текста (внутренний кодек того же модуля).
    private static func envelope(_ text: String) -> String {
        ConfigEnvelope.encode(text)
    }

    private func makeSUT(
        fs: FakeProbeFileSystem,
        runner: FakeProcessRunner,
        auth: FakeAuthenticator = FakeAuthenticator()
    ) -> PrivilegedConfigReader {
        PrivilegedConfigReader(
            fileSystem: fs,
            processRunner: runner,
            authenticator: auth,
            helperDirectoryPath: directoryPath,
            helperBinaryPath: binaryPath
        )
    }

    /// Валидная тройка фейков: FS в порядке, capability ок, auth успех.
    private func makeValidEnvironment(
        osascriptOutcome: PrivilegedProcessOutcome? = nil
    ) -> (fs: FakeProbeFileSystem, runner: FakeProcessRunner, auth: FakeAuthenticator) {
        (
            makeFS(directory: directoryEntry(), binary: binaryEntry()),
            makeHappyRunner(osascriptOutcome: osascriptOutcome),
            FakeAuthenticator()
        )
    }

    /// Валидная среда с переопределениями: `nil`-параметр = валидная запись,
    /// `directoryMissing`/`binaryMissing` = записи нет вовсе.
    private func validFSWith(
        directory: PrivilegedHelperStatEntry? = nil,
        binary: PrivilegedHelperStatEntry? = nil,
        directoryMissing: Bool = false,
        binaryMissing: Bool = false
    ) -> (FakeProbeFileSystem, FakeProcessRunner, FakeAuthenticator) {
        (
            makeFS(
                directory: directoryMissing ? nil : (directory ?? directoryEntry()),
                binary: binaryMissing ? nil : (binary ?? binaryEntry())
            ),
            makeHappyRunner(),
            FakeAuthenticator()
        )
    }

    private func awaitReveal(
        _ sut: PrivilegedConfigReader,
        name: String = "work-vpn",
        serviceState: ServiceState = .installed
    ) async -> ConfigRevealOutcome {
        await sut.reveal(named: name, serviceState: serviceState)
    }

    private func expectFailure(
        _ outcome: ConfigRevealOutcome,
        _ expected: PrivilegedConfigError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .failed(let error) = outcome else {
            XCTFail("ожидалась ошибка \(expected), получено: \(outcome)", file: file, line: line)
            return
        }
        XCTAssertEqual(error, expected, file: file, line: line)
    }

    // MARK: - Состояние сервиса: fail-closed до любых границ

    func testAbsentServiceReturnsInstallGuidanceWithZeroCalls() async {
        let env = makeValidEnvironment()
        let sut = makeSUT(fs: env.fs, runner: env.runner, auth: env.auth)

        let outcome = await awaitReveal(sut, serviceState: .absent)

        expectFailure(outcome, .serviceInstallRequired)
        XCTAssertEqual(env.fs.callCount, 0, "ни одного lstat")
        XCTAssertTrue(env.runner.calls.isEmpty, "ни одного процесса")
        XCTAssertEqual(env.auth.callCount, 0, "ни одного контекста аутентификации")
    }

    func testBrokenServiceReturnsUpdateGuidanceWithZeroCalls() async {
        let env = makeValidEnvironment()
        let sut = makeSUT(fs: env.fs, runner: env.runner, auth: env.auth)

        let outcome = await awaitReveal(sut, serviceState: .broken)

        expectFailure(outcome, .serviceUpdateRequired)
        XCTAssertEqual(env.fs.callCount, 0)
        XCTAssertTrue(env.runner.calls.isEmpty)
        XCTAssertEqual(env.auth.callCount, 0)
    }

    func testOutdatedServiceReturnsUpdateGuidanceWithZeroCalls() async {
        let env = makeValidEnvironment()
        let sut = makeSUT(fs: env.fs, runner: env.runner, auth: env.auth)

        let outcome = await awaitReveal(sut, serviceState: .outdated)

        expectFailure(outcome, .serviceUpdateRequired)
        XCTAssertEqual(env.fs.callCount, 0)
        XCTAssertTrue(env.runner.calls.isEmpty)
        XCTAssertEqual(env.auth.callCount, 0)
    }

    // MARK: - Имя до файловой системы

    func testInvalidNameFailsBeforeAnyBoundary() async {
        let env = makeValidEnvironment()
        let sut = makeSUT(fs: env.fs, runner: env.runner, auth: env.auth)

        expectFailure(await awaitReveal(sut, name: "bad name!"), .invalidName)
        XCTAssertEqual(env.fs.callCount, 0)
        XCTAssertTrue(env.runner.calls.isEmpty)
        XCTAssertEqual(env.auth.callCount, 0)
    }

    func testShellAndAppleScriptInjectionNamesAreRejectedBeforeAnyBoundary() async {
        let injections = [
            "x'; rm -rf /; echo '",
            "$(reboot)",
            "`id`",
            "a\"b",
            "name\\nwith\\nnewlines",
            "; sudo wg-quick up",
            "a b",
            "../../../etc/passwd",
            "way-too-long-name-over-fifteen-characters",
        ]
        for name in injections {
            let env = makeValidEnvironment()
            let sut = makeSUT(fs: env.fs, runner: env.runner, auth: env.auth)
            expectFailure(await awaitReveal(sut, name: name), .invalidName)
            XCTAssertEqual(env.fs.callCount, 0, "инъекция \(name) не доходит до FS")
            XCTAssertTrue(env.runner.calls.isEmpty, "инъекция \(name) не доходит до процесса")
            XCTAssertEqual(env.auth.callCount, 0)
        }
    }

    // MARK: - Префлайт каталога

    func testMissingDirectoryFailsClosed() async {
        let env = validFSWith(directoryMissing: true)
        let sut = makeSUT(fs: env.0, runner: env.1, auth: env.2)
        expectFailure(await awaitReveal(sut), .helperUnavailable)
        XCTAssertTrue(env.1.calls.isEmpty)
        XCTAssertEqual(env.2.callCount, 0)
    }

    func testSymlinkDirectoryFailsClosed() async {
        let env = validFSWith(directory: directoryEntry(symlink: true))
        let sut = makeSUT(fs: env.0, runner: env.1, auth: env.2)
        expectFailure(await awaitReveal(sut), .helperUnavailable)
        XCTAssertTrue(env.1.calls.isEmpty)
        XCTAssertEqual(env.2.callCount, 0)
    }

    func testNonDirectoryHelperPathFailsClosed() async {
        // Файл на месте каталога.
        let env = validFSWith(
            directory: PrivilegedHelperStatEntry(kind: .regularFile, ownerUID: 0, permissions: 0o755)
        )
        let sut = makeSUT(fs: env.0, runner: env.1, auth: env.2)
        expectFailure(await awaitReveal(sut), .helperUnavailable)
        XCTAssertTrue(env.1.calls.isEmpty)
        XCTAssertEqual(env.2.callCount, 0)
    }

    func testNonRootOwnedDirectoryFailsClosed() async {
        let env = validFSWith(directory: directoryEntry(ownerUID: 501))
        let sut = makeSUT(fs: env.0, runner: env.1, auth: env.2)
        expectFailure(await awaitReveal(sut), .helperUnavailable)
        XCTAssertTrue(env.1.calls.isEmpty)
        XCTAssertEqual(env.2.callCount, 0)
    }

    func testGroupWritableDirectoryFailsClosed() async {
        let env = validFSWith(directory: directoryEntry(permissions: 0o775))
        let sut = makeSUT(fs: env.0, runner: env.1, auth: env.2)
        expectFailure(await awaitReveal(sut), .helperUnavailable)
        XCTAssertTrue(env.1.calls.isEmpty)
        XCTAssertEqual(env.2.callCount, 0)
    }

    func testWorldWritableDirectoryFailsClosed() async {
        let env = validFSWith(directory: directoryEntry(permissions: 0o757))
        let sut = makeSUT(fs: env.0, runner: env.1, auth: env.2)
        expectFailure(await awaitReveal(sut), .helperUnavailable)
        XCTAssertTrue(env.1.calls.isEmpty)
        XCTAssertEqual(env.2.callCount, 0)
    }

    // MARK: - Префлайт бинаря

    func testMissingBinaryFailsClosed() async {
        let env = validFSWith(binaryMissing: true)
        let sut = makeSUT(fs: env.0, runner: env.1, auth: env.2)
        expectFailure(await awaitReveal(sut), .helperUnavailable)
        XCTAssertTrue(env.1.calls.isEmpty)
        XCTAssertEqual(env.2.callCount, 0)
    }

    func testSymlinkBinaryFailsClosed() async {
        let env = validFSWith(binary: binaryEntry(symlink: true))
        let sut = makeSUT(fs: env.0, runner: env.1, auth: env.2)
        expectFailure(await awaitReveal(sut), .helperUnavailable)
        XCTAssertTrue(env.1.calls.isEmpty)
        XCTAssertEqual(env.2.callCount, 0)
    }

    func testNonRegularBinaryFailsClosed() async {
        // Каталог на месте бинаря.
        let env = validFSWith(binary: binaryEntry(regular: false))
        let sut = makeSUT(fs: env.0, runner: env.1, auth: env.2)
        expectFailure(await awaitReveal(sut), .helperUnavailable)
        XCTAssertTrue(env.1.calls.isEmpty)
        XCTAssertEqual(env.2.callCount, 0)
    }

    func testNonRootOwnedBinaryFailsClosed() async {
        let env = validFSWith(binary: binaryEntry(ownerUID: 501))
        let sut = makeSUT(fs: env.0, runner: env.1, auth: env.2)
        expectFailure(await awaitReveal(sut), .helperUnavailable)
        XCTAssertTrue(env.1.calls.isEmpty)
        XCTAssertEqual(env.2.callCount, 0)
    }

    func testGroupWritableBinaryFailsClosed() async {
        let env = validFSWith(binary: binaryEntry(permissions: 0o775))
        let sut = makeSUT(fs: env.0, runner: env.1, auth: env.2)
        expectFailure(await awaitReveal(sut), .helperUnavailable)
        XCTAssertTrue(env.1.calls.isEmpty)
        XCTAssertEqual(env.2.callCount, 0)
    }

    func testWorldWritableBinaryFailsClosed() async {
        let env = validFSWith(binary: binaryEntry(permissions: 0o757))
        let sut = makeSUT(fs: env.0, runner: env.1, auth: env.2)
        expectFailure(await awaitReveal(sut), .helperUnavailable)
        XCTAssertTrue(env.1.calls.isEmpty)
        XCTAssertEqual(env.2.callCount, 0)
    }

    func testNonExecutableBinaryFailsClosed() async {
        let env = validFSWith(binary: binaryEntry(permissions: 0o644))
        let sut = makeSUT(fs: env.0, runner: env.1, auth: env.2)
        expectFailure(await awaitReveal(sut), .helperUnavailable)
        XCTAssertTrue(env.1.calls.isEmpty)
        XCTAssertEqual(env.2.callCount, 0)
    }

    // MARK: - Capability-проба

    private func makeCapabilityRunner(_ outcome: PrivilegedProcessOutcome) -> FakeProcessRunner {
        let runner = FakeProcessRunner()
        runner.handler = { call in
            call.argv.last == "--capabilities"
                ? outcome
                : .success(stdout: PrivilegedConfigReaderTests.envelope("should-not-be-reached\n"))
        }
        return runner
    }

    func testCapabilityProbeUsesExactBinaryAndBoundedTimeout() async {
        let env = makeValidEnvironment()
        let sut = makeSUT(fs: env.fs, runner: env.runner, auth: env.auth)

        _ = await awaitReveal(sut)

        XCTAssertEqual(env.runner.calls.first?.argv, [binaryPath, "--capabilities"], "проба — точный установленный бинарь")
        XCTAssertEqual(env.runner.calls.first?.timeout, PrivilegedConfigReader.capabilityProbeTimeout, "проба ограничена таймаутом")
    }

    func testCapabilityLaunchFailureFailsClosedWithoutAuthOrPrivilegedLaunch() async {
        for outcome in [PrivilegedProcessOutcome.failure(.launchFailed), .failure(.timedOut), .failure(.exitFailure), .failure(.outputExceeded)] {
            let fs = makeFS(directory: directoryEntry(), binary: binaryEntry())
            let runner = makeCapabilityRunner(outcome)
            let auth = FakeAuthenticator()
            let sut = makeSUT(fs: fs, runner: runner, auth: auth)

            expectFailure(await awaitReveal(sut), .helperUnavailable)
            XCTAssertEqual(runner.calls.count, 1, "только capability-проба")
            XCTAssertEqual(auth.callCount, 0, "аутентификации нет")
        }
    }

    func testCapabilityMalformedOutputFailsClosed() async {
        let malformed = [
            "",
            "capabilities 1 \(helperBuildNumber) \(helperConfigRawCapabilityToken)",
            "capabilities \(helperProtocolVersion) \(helperBuildNumber) \(helperConfigRawCapabilityToken)\nextra\n",
            "capabilities \(helperProtocolVersion) \(helperBuildNumber) wrong-token\n",
            "capabilities x \(helperBuildNumber) \(helperConfigRawCapabilityToken)\n",
            "capabilities \(helperProtocolVersion) x \(helperConfigRawCapabilityToken)\n",
            String(repeating: "A", count: 5000) + "\n",
            "  capabilities \(helperProtocolVersion) \(helperBuildNumber) \(helperConfigRawCapabilityToken)\n",
            "capabilities  \(helperProtocolVersion) \(helperBuildNumber) \(helperConfigRawCapabilityToken)\n",
        ]
        for output in malformed {
            let fs = makeFS(directory: directoryEntry(), binary: binaryEntry())
            let runner = makeCapabilityRunner(.success(stdout: output))
            let auth = FakeAuthenticator()
            let sut = makeSUT(fs: fs, runner: runner, auth: auth)

            expectFailure(await awaitReveal(sut), .helperUnavailable)
            XCTAssertEqual(runner.calls.count, 1, "osascript-запуска нет")
            XCTAssertEqual(auth.callCount, 0)
        }
    }

    func testCapabilityWrongProtocolMeansOutdatedHelper() async {
        let fs = makeFS(directory: directoryEntry(), binary: binaryEntry())
        let runner = makeCapabilityRunner(
            .success(stdout: "capabilities 99 \(helperBuildNumber) \(helperConfigRawCapabilityToken)\n")
        )
        let auth = FakeAuthenticator()
        let sut = makeSUT(fs: fs, runner: runner, auth: auth)

        expectFailure(await awaitReveal(sut), .helperOutdated)
        XCTAssertEqual(auth.callCount, 0)
    }

    func testCapabilityStaleBuildMeansOutdatedHelper() async {
        let fs = makeFS(directory: directoryEntry(), binary: binaryEntry())
        // Билд 18 не знает one-shot-флагов — его запуск вместо пробы стартовал
        // бы второй демон; префлайт обязан отсечь его до osascript.
        let runner = makeCapabilityRunner(
            .success(stdout: "capabilities \(helperProtocolVersion) 18 \(helperConfigRawCapabilityToken)\n")
        )
        let auth = FakeAuthenticator()
        let sut = makeSUT(fs: fs, runner: runner, auth: auth)

        expectFailure(await awaitReveal(sut), .helperOutdated)
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(auth.callCount, 0)
    }

    func testCapabilityNewerBuildIsAccepted() async {
        let fs = makeFS(directory: directoryEntry(), binary: binaryEntry())
        let runner = FakeProcessRunner()
        runner.handler = { call in
            call.argv.last == "--capabilities"
                ? .success(stdout: "capabilities \(helperProtocolVersion) \(helperBuildNumber + 1) \(helperConfigRawCapabilityToken)\n")
                : .success(stdout: PrivilegedConfigReaderTests.envelope("doc\n"))
        }
        let auth = FakeAuthenticator()
        let sut = makeSUT(fs: fs, runner: runner, auth: auth)

        guard case .revealed(let document) = await awaitReveal(sut) else {
            XCTFail("более новый билд хелпера валиден")
            return
        }
        XCTAssertEqual(document.text, "doc\n")
        XCTAssertEqual(auth.callCount, 1)
    }

    // MARK: - Аутентификация

    func testAuthenticationCancellationIsSilentAndLaunchesNothing() async {
        let env = makeValidEnvironment()
        env.auth.outcome = .userCancelled
        let sut = makeSUT(fs: env.fs, runner: env.runner, auth: env.auth)

        let outcome = await awaitReveal(sut)

        XCTAssertEqual(outcome, .cancelledByUser, "отмена — не ошибка приложения")
        XCTAssertEqual(env.runner.calls.count, 1, "только capability-проба, osascript не запускался")
        XCTAssertEqual(env.auth.callCount, 1)
        XCTAssertNotNil(env.auth.lastReason)
        XCTAssertFalse(env.auth.lastReason?.isEmpty ?? true, "причина — локализованный непустой текст")
    }

    func testAuthenticationUnavailableIsTypedError() async {
        let env = makeValidEnvironment()
        env.auth.outcome = .unavailable
        let sut = makeSUT(fs: env.fs, runner: env.runner, auth: env.auth)

        expectFailure(await awaitReveal(sut), .authenticationUnavailable)
        XCTAssertEqual(env.runner.calls.count, 1)
    }

    func testAuthenticationFailureIsTypedError() async {
        let env = makeValidEnvironment()
        env.auth.outcome = .failed
        let sut = makeSUT(fs: env.fs, runner: env.runner, auth: env.auth)

        expectFailure(await awaitReveal(sut), .authenticationFailed)
        XCTAssertEqual(env.runner.calls.count, 1)
    }

    func testAuthenticationHappensOnlyAfterPreflight() async {
        let env = makeValidEnvironment()
        // Префлайт падает на каталоге — аутентификации быть не должно.
        env.fs.entries[directoryPath] = nil
        let sut = makeSUT(fs: env.fs, runner: env.runner, auth: env.auth)

        expectFailure(await awaitReveal(sut), .helperUnavailable)
        XCTAssertEqual(env.auth.callCount, 0, "контекст LAContext не создаётся до прохождения префлайта")
    }

    /// Табличная классификация LAError-кодов: настоящий промпт не
    /// автоматизируется, но маппинг кодов в исходы — чистая функция, и
    /// перепутанный бакет менял бы текст пользователю (отмена Touch ID
    /// показывалась бы сбоем, Mac без пароля — сбоем вместо «недоступно»).
    func testAuthenticationClassifierBucketsLAErrorCodes() {
        XCTAssertEqual(
            LocalAuthenticationConfigAuthenticator.classify(success: true, error: nil),
            .success
        )
        for code in [LAError.Code.userCancel, .appCancel, .systemCancel] {
            XCTAssertEqual(
                LocalAuthenticationConfigAuthenticator.classify(success: false, error: LAError(code)),
                .userCancelled,
                "код \(code) — тихая отмена"
            )
        }
        for code in [LAError.Code.biometryNotAvailable, .biometryNotEnrolled, .biometryLockout, .passcodeNotSet] {
            XCTAssertEqual(
                LocalAuthenticationConfigAuthenticator.classify(success: false, error: LAError(code)),
                .unavailable,
                "код \(code) — политика недоступна"
            )
        }
        // Прочие LAError-коды, ошибка не-типа LAError и провал без ошибки — сбой.
        XCTAssertEqual(
            LocalAuthenticationConfigAuthenticator.classify(success: false, error: LAError(.invalidContext)),
            .failed
        )
        XCTAssertEqual(
            LocalAuthenticationConfigAuthenticator.classify(success: false, error: URLError(.badURL)),
            .failed
        )
        XCTAssertEqual(
            LocalAuthenticationConfigAuthenticator.classify(success: false, error: nil),
            .failed
        )
    }

    // MARK: - Привилегированный запуск

    func testPrivilegedLaunchUsesOsaScriptWithQuotedExactBinary() async {
        let env = makeValidEnvironment()
        let sut = makeSUT(fs: env.fs, runner: env.runner, auth: env.auth)

        _ = await awaitReveal(sut)

        XCTAssertEqual(env.runner.calls.count, 2, "capability-проба + привилегированный запуск")
        let privileged = env.runner.calls[1]
        XCTAssertEqual(privileged.argv.first, "/usr/bin/osascript")
        XCTAssertEqual(
            privileged.argv,
            PrivilegedConfigReader.osascriptCommand(helperPath: binaryPath, name: "work-vpn"),
            "osascript-argv собирается чистой функцией с точным путём и именем"
        )
        XCTAssertNil(privileged.timeout, "админ-промпт не ограничен таймаутом — пользователь думает")
        XCTAssertEqual(privileged.maxCollectedBytes, PrivilegedConfigReader.rawEnvelopeMaxCollectedBytes)
    }

    func testPrivilegedProcessExitFailureReturnsTypedError() async {
        let env = makeValidEnvironment(osascriptOutcome: .failure(.exitFailure))
        let sut = makeSUT(fs: env.fs, runner: env.runner, auth: env.auth)

        expectFailure(await awaitReveal(sut), .privilegedReadFailed)
    }

    func testPrivilegedProcessLaunchFailureReturnsTypedError() async {
        let env = makeValidEnvironment(osascriptOutcome: .failure(.launchFailed))
        let sut = makeSUT(fs: env.fs, runner: env.runner, auth: env.auth)

        expectFailure(await awaitReveal(sut), .privilegedReadFailed)
    }

    func testPrivilegedProcessCancellationIsSilent() async {
        // Окно закрыли во время привилегированного чтения — промпт снят задачей.
        let env = makeValidEnvironment(osascriptOutcome: .failure(.cancelled))
        let sut = makeSUT(fs: env.fs, runner: env.runner, auth: env.auth)

        let outcome = await awaitReveal(sut)
        XCTAssertEqual(outcome, .cancelledByUser)
    }

    func testAdminPromptCancellationIsSilent() async {
        // Пользователь отменил второй (администраторский) промпт osascript —
        // тот же безопасный исход, что и отмена аутентификации.
        let env = makeValidEnvironment(osascriptOutcome: .promptCancelled)
        let sut = makeSUT(fs: env.fs, runner: env.runner, auth: env.auth)

        let outcome = await awaitReveal(sut)
        XCTAssertEqual(outcome, .cancelledByUser)
    }

    // MARK: - Разбор конверта

    func testEmptyPrivilegedStdoutIsRejected() async {
        let env = makeValidEnvironment(osascriptOutcome: .success(stdout: ""))
        let sut = makeSUT(fs: env.fs, runner: env.runner, auth: env.auth)

        expectFailure(await awaitReveal(sut), .privilegedReadFailed)
    }

    func testTruncatedEnvelopeWithoutTerminatorIsRejected() async {
        let env = makeValidEnvironment(
            osascriptOutcome: .success(stdout: ConfigEnvelope.tag + "QUJD")
        )
        let sut = makeSUT(fs: env.fs, runner: env.runner, auth: env.auth)

        expectFailure(await awaitReveal(sut), .privilegedReadFailed)
    }

    func testMalformedBase64IsRejected() async {
        let env = makeValidEnvironment(
            osascriptOutcome: .success(stdout: ConfigEnvelope.tag + "!!!not-base64!!!\n")
        )
        let sut = makeSUT(fs: env.fs, runner: env.runner, auth: env.auth)

        expectFailure(await awaitReveal(sut), .privilegedReadFailed)
    }

    func testEnvelopeWithExtraLinesIsRejected() async {
        let env = makeValidEnvironment(
            osascriptOutcome: .success(stdout: Self.envelope("a\n") + Self.envelope("b\n"))
        )
        let sut = makeSUT(fs: env.fs, runner: env.runner, auth: env.auth)

        expectFailure(await awaitReveal(sut), .privilegedReadFailed)
    }

    func testOversizedDecodedEnvelopeIsRejected() async {
        // Валидный base64 документа за лимитом ридера — мусор, не документ.
        let oversized = Data(repeating: 0x41, count: TunnelConfigReader.maxSizeBytes + 1).base64EncodedString()
        let env = makeValidEnvironment(
            osascriptOutcome: .success(stdout: ConfigEnvelope.tag + oversized + "\n")
        )
        let sut = makeSUT(fs: env.fs, runner: env.runner, auth: env.auth)

        expectFailure(await awaitReveal(sut), .privilegedReadFailed)
    }

    func testSuccessRevealsExactRawDocumentWithFinalNewline() async {
        let raw = "[Interface]\nPrivateKey = raw-secret-line\n[Peer]\nAllowedIPs = 0.0.0.0/0\n"
        let env = makeValidEnvironment(osascriptOutcome: .success(stdout: Self.envelope(raw)))
        let sut = makeSUT(fs: env.fs, runner: env.runner, auth: env.auth)

        guard case .revealed(let document) = await awaitReveal(sut) else {
            XCTFail("валидный конверт — раскрытие")
            return
        }
        XCTAssertEqual(document.text, raw)
        XCTAssertTrue(document.hasFinalNewline)
    }

    func testSuccessPreservesMissingFinalNewlineOfRawDocument() async {
        let raw = "[Interface]\nListenPort = 51820"
        let env = makeValidEnvironment(osascriptOutcome: .success(stdout: Self.envelope(raw)))
        let sut = makeSUT(fs: env.fs, runner: env.runner, auth: env.auth)

        guard case .revealed(let document) = await awaitReveal(sut) else {
            XCTFail("валидный конверт — раскрытие")
            return
        }
        XCTAssertFalse(document.hasFinalNewline, "обрамление транспорта не добавляет \\n документу")
    }

    func testSuccessRevealsEmptyDocument() async {
        let env = makeValidEnvironment(osascriptOutcome: .success(stdout: Self.envelope("")))
        let sut = makeSUT(fs: env.fs, runner: env.runner, auth: env.auth)

        guard case .revealed(let document) = await awaitReveal(sut) else {
            XCTFail("пустой конверт — валидный пустой документ")
            return
        }
        XCTAssertEqual(document.text, "")
    }

    func testFailureOutcomesCarryNoDocumentData() async {
        // Даже когда raw-текст был в канале, ошибка не несёт ни байта данных.
        let secretTail = "LEAKED-RAW-CONTENT-9876"
        let env = makeValidEnvironment(
            osascriptOutcome: .success(stdout: ConfigEnvelope.tag + "%%%\n" + secretTail)
        )
        let sut = makeSUT(fs: env.fs, runner: env.runner, auth: env.auth)

        let outcome = await awaitReveal(sut)
        XCTAssertFalse(String(describing: outcome).contains(secretTail))
        expectFailure(outcome, .privilegedReadFailed)
    }

    // MARK: - Подавление дублей

    func testSecondRevealWhileFirstIsRunningIsSuppressed() async {
        let fs = makeFS(directory: directoryEntry(), binary: binaryEntry())
        let runner = makeHappyRunner()
        runner.delayNanoseconds = 300_000_000
        let auth = FakeAuthenticator()
        let sut = makeSUT(fs: fs, runner: runner, auth: auth)

        async let first = awaitReveal(sut)
        // Даем первому захватить claim до старта второго.
        try? await Task.sleep(nanoseconds: 50_000_000)
        let second = await awaitReveal(sut)
        let firstOutcome = await first

        XCTAssertEqual(second, .suppressed, "повторный Reveal — тихий no-op")
        XCTAssertEqual(runner.calls.count, 2, "обе границы прошли только один раз")
        XCTAssertEqual(auth.callCount, 1)
        guard case .revealed = firstOutcome else {
            XCTFail("первый Reveal завершается нормально")
            return
        }
    }

    func testRevealAfterCompletionRunsAgain() async {
        let fs = makeFS(directory: directoryEntry(), binary: binaryEntry())
        let runner = makeHappyRunner()
        let auth = FakeAuthenticator()
        let sut = makeSUT(fs: fs, runner: runner, auth: auth)

        guard case .revealed = await awaitReveal(sut) else {
            XCTFail("первый Reveal — успех")
            return
        }
        guard case .revealed = await awaitReveal(sut) else {
            XCTFail("claim освобождён — второй Reveal тоже работает")
            return
        }
        XCTAssertEqual(auth.callCount, 2, "каждый Reveal — свежая аутентификация")
    }

    // MARK: - Чистая сборка osascript-argv

    func testOsaScriptCommandQuotesPathAndName() {
        let argv = PrivilegedConfigReader.osascriptCommand(
            helperPath: "/Library/PrivilegedHelperTools/com.stuchalin.wgstatusbar.helper",
            name: "work.vpn_1+2=3"
        )
        XCTAssertEqual(argv[0], "/usr/bin/osascript")
        XCTAssertEqual(argv[1], "-e")
        XCTAssertEqual(
            argv[2],
            "do shell script \"'/Library/PrivilegedHelperTools/com.stuchalin.wgstatusbar.helper' "
                + "--print-config-raw 'work.vpn_1+2=3'\" with administrator privileges"
        )
    }

    func testOsaScriptCommandEscapesHostileStringsBothLayers() {
        // Даже строки, которые никогда не пройдут shape-проверку имени,
        // обязаны экранироваться обоими слоями — двойная защита чистой функции.
        let hostilePath = "/tmp/evil'\\ \"path"
        let hostileName = "x'; rm -rf /; echo '"
        let argv = PrivilegedConfigReader.osascriptCommand(helperPath: hostilePath, name: hostileName)
        let script = argv[2]
        XCTAssertTrue(script.contains("\\\""), "двойные кавычки экранируются для AppleScript")
        // Апостроф shell-слоем становится '\''; его внутренний бэкслэш затем
        // удваивается AppleScript-слоем — в итоговом литерале это '\\''.
        XCTAssertTrue(script.contains("'\\\\''"), "апострофы переоткрываются для shell")
        XCTAssertTrue(script.hasSuffix(" with administrator privileges"))
    }

    // MARK: - Продакшн процессный раннер (реальные процессы, без промптов)

    func testProcessRunnerEchoSuccessReturnsStdout() async {
        let runner = ProcessPrivilegedRunner()
        let outcome = await runner.run(
            ["/usr/bin/printf", "b64:hello"],
            timeout: 5.0,
            maxCollectedBytes: 4096
        )
        XCTAssertEqual(outcome, .success(stdout: "b64:hello"))
    }

    func testProcessRunnerLaunchFailureOfMissingBinary() async {
        let runner = ProcessPrivilegedRunner()
        let outcome = await runner.run(
            ["/nonexistent/wgstatusbar-test-binary", "--capabilities"],
            timeout: 5.0,
            maxCollectedBytes: 4096
        )
        XCTAssertEqual(outcome, .failure(.launchFailed))
    }

    func testProcessRunnerTimeoutKillsHangingChild() async {
        let runner = ProcessPrivilegedRunner()
        let started = Date()
        let outcome = await runner.run(
            ["/bin/sleep", "30"],
            timeout: 0.3,
            maxCollectedBytes: 4096
        )
        XCTAssertEqual(outcome, .failure(.timedOut))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5.0, "лестница TERM→KILL ограничена")
    }

    func testProcessRunnerNoTimeoutWaitsForSlowChild() async {
        let runner = ProcessPrivilegedRunner()
        // Без таймаута быстрый ребёнок завершается сам (промпт-режим ждёт
        // выхода сколь угодно долго, но exit наступает и раньше дедлайна).
        let outcome = await runner.run(
            ["/bin/sleep", "0.2"],
            timeout: nil,
            maxCollectedBytes: 4096
        )
        XCTAssertEqual(outcome, .success(stdout: ""))
    }

    func testProcessRunnerTaskCancellationTerminatesChild() async {
        let runner = ProcessPrivilegedRunner()
        let task = Task {
            await runner.run(["/bin/sleep", "30"], timeout: nil, maxCollectedBytes: 4096)
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        let started = Date()
        let outcome = await task.value
        XCTAssertEqual(outcome, .failure(.cancelled))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5.0, "отмена завершает ожидание ограниченно")
    }

    func testProcessRunnerCapsOversizedStdout() async {
        let runner = ProcessPrivilegedRunner()
        let big = String(repeating: "A", count: 10_000)
        let outcome = await runner.run(
            ["/bin/echo", big],
            timeout: 5.0,
            maxCollectedBytes: 100
        )
        XCTAssertEqual(outcome, .failure(.outputExceeded), "потолок накопления срабатывает до декодирования")
    }

    func testProcessRunnerDetectsAppleScriptCancellationNumber() async {
        // `error number -128` — тот же номер, что osascript печатает при
        // отмене админ-промпта; реальный промпт не автоматизируется.
        let runner = ProcessPrivilegedRunner()
        let outcome = await runner.run(
            ["/usr/bin/osascript", "-e", "error number -128"],
            timeout: 10.0,
            maxCollectedBytes: 8192
        )
        XCTAssertEqual(outcome, .promptCancelled)
    }

    func testProcessRunnerRejectsNonUTF8Stdout() async {
        let runner = ProcessPrivilegedRunner()
        let outcome = await runner.run(
            ["/usr/bin/printf", "\\377\\376"],
            timeout: 5.0,
            maxCollectedBytes: 4096
        )
        XCTAssertEqual(outcome, .failure(.exitFailure), "не-UTF-8 stdout — мусор без попадания наружу")
    }

    // MARK: - Реальный osascript: выживание терминатора конверта

    /// Продакшн happy-path Reveal прогоняет stdout реального osascript через
    /// `decodeRawEnvelope`; валидность конверта — эмерджентное свойство цепочки
    /// «хелпер печатает `b64:<base64>\n` → `do shell script` снимает один
    /// завершающий `\n` → osascript добавляет свой при печати результата».
    /// Здесь цепочка настоящая (кроме самого хелпера и админ-промпта):
    /// команда без завершающего `\n` в stdout обязана прийти валидным
    /// конвертом — `do shell script` возвращает строку без него, osascript
    /// печатает со своим.
    func testProcessRunnerOsaScriptEnvelopeSurvivesWithoutTrailingNewline() async {
        let runner = ProcessPrivilegedRunner()
        let envelopePayload = ConfigEnvelope.tag + Data("hello\n".utf8).base64EncodedString()
        let outcome = await runner.run(
            [
                "/usr/bin/osascript",
                "-e",
                "do shell script \"/usr/bin/printf \(envelopePayload)\"",
            ],
            timeout: 10.0,
            maxCollectedBytes: 4096
        )

        guard case .success(let stdout) = outcome else {
            XCTFail("osascript должен завершиться успехом: \(outcome)")
            return
        }
        guard case .revealed(let document) = PrivilegedConfigReader.decodeRawEnvelope(stdout) else {
            XCTFail("stdout реального osascript обязан быть валидным конвертом: \(String(describing: stdout.suffix(64)))")
            return
        }
        XCTAssertEqual(document.text, "hello\n")
        XCTAssertTrue(document.hasFinalNewline, "собственный \\n документа живёт внутри base64")
    }

    /// Вторая половина цепочки: stdout shell-команды С завершающим `\n`
    /// (`echo`) — `do shell script` снимает его, osascript возвращает свой:
    /// результирующая форма конверта та же, двойного терминатора не возникает.
    func testProcessRunnerOsaScriptEnvelopeSurvivesWithTrailingNewline() async {
        let runner = ProcessPrivilegedRunner()
        let envelopePayload = ConfigEnvelope.tag + Data("hello".utf8).base64EncodedString()
        let outcome = await runner.run(
            [
                "/usr/bin/osascript",
                "-e",
                "do shell script \"/bin/echo \(envelopePayload)\"",
            ],
            timeout: 10.0,
            maxCollectedBytes: 4096
        )

        guard case .success(let stdout) = outcome else {
            XCTFail("osascript должен завершиться успехом: \(outcome)")
            return
        }
        guard case .revealed(let document) = PrivilegedConfigReader.decodeRawEnvelope(stdout) else {
            XCTFail("stdout реального osascript обязан быть валидным конвертом: \(String(describing: stdout.suffix(64)))")
            return
        }
        XCTAssertEqual(document.text, "hello")
        XCTAssertFalse(document.hasFinalNewline, "снятый echo-терминатор не добавляет документу \\n")
    }

    /// Ребёнок вышел, но переживающий его внук (`sleep 5 &`) унаследовал
    /// stdout: EOF не приходит, ожидание дрейна ограничено grace — раннер
    /// обязан вернуться ограниченно и с накопленным stdout (fail-closed,
    /// не виснуть). Регрессия на неограниченный wait.
    func testProcessRunnerReturnsBoundedWhenGrandchildHoldsPipeOpen() async {
        let runner = ProcessPrivilegedRunner()
        let started = Date()
        let outcome = await runner.run(
            ["/bin/sh", "-c", "/usr/bin/printf b64:aGVsbG8K; /bin/sleep 5 &"],
            timeout: nil,
            maxCollectedBytes: 4096
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(outcome, .success(stdout: "b64:aGVsbG8K"), "накопленный до таймаута дрейна stdout возвращается")
        XCTAssertLessThan(elapsed, 4.0, "внук, держащий пайп, не подвешивает раннер")
    }

    // MARK: - POSIX lstat-слой

    func testPosixProbeReportsRealEntryTypes() throws {
        let probe = PosixPrivilegedHelperProbingFileSystem()
        let missing = probe.statEntry(atPath: "/nonexistent/wgstatusbar-probe")
        XCTAssertNil(missing)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wgstatusbar-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        FileManager.default.createFile(atPath: tmp.path, contents: Data("x".utf8))
        let entry = try XCTUnwrap(probe.statEntry(atPath: tmp.path))
        XCTAssertEqual(entry.kind, .regularFile)
    }

    // MARK: - Локализованные сообщения об ошибках

    func testEveryErrorHasNonEmptyLocalizedUserMessage() {
        let all: [PrivilegedConfigError] = [
            .serviceInstallRequired, .serviceUpdateRequired, .invalidName,
            .helperUnavailable, .helperOutdated, .authenticationUnavailable,
            .authenticationFailed, .privilegedReadFailed,
        ]
        for error in all {
            XCTAssertFalse(error.userMessage.isEmpty, "у \(error) есть локализованный текст")
        }
    }
}
