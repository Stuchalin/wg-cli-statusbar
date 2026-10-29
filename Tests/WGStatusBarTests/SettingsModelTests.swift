import XCTest
@testable import WGStatusBarCore

/// Модель окна настроек: маппинг системного статуса и факта о бандле в
/// отображаемое состояние, перечитывание статуса до/после действия, оконная
/// ошибка, одна операция за раз. `SMAppService` здесь не вызывается — только
/// мок границы.
final class SettingsModelTests: XCTestCase {
    // MARK: - Фикстуры

    private struct MockFailure: Error {}

    /// Мок логин-айтема: статус программируется тестом, register/unregister
    /// висят на клапане, пока тест их не отпустит (так проверяется «одна
    /// операция за раз»). По завершении операции мок выставляет статус,
    /// заданный тестом, — как система после действия.
    private final class MockLoginItem: LoginItemManaging {
        enum Call: Equatable { case register, unregister, openSettings }

        private let lock = NSLock()
        private var statusStorage: LoginItemStatus
        private var statusReadsStorage = 0
        private var callsStorage: [Call] = []
        private var gate: DispatchSemaphore?
        private var pendingStorage = 0

        /// Ошибка следующей операции; nil — успех.
        var nextError: Error?
        /// Статус, который «система» покажет после операции.
        var statusAfterOperation: LoginItemStatus?

        init(status: LoginItemStatus, gated: Bool = false) {
            statusStorage = status
            gate = gated ? DispatchSemaphore(value: 0) : nil
        }

        var status: LoginItemStatus {
            lock.withLock {
                statusReadsStorage += 1
                return statusStorage
            }
        }

        func setStatus(_ status: LoginItemStatus) {
            lock.withLock { statusStorage = status }
        }

        var statusReads: Int { lock.withLock { statusReadsStorage } }
        var calls: [Call] { lock.withLock { callsStorage } }
        var pending: Int { lock.withLock { pendingStorage } }

        func register() throws { try perform(.register) }
        func unregister() throws { try perform(.unregister) }

        func openSystemSettingsLoginItems() {
            lock.withLock { callsStorage.append(.openSettings) }
        }

        /// Отпускает висящую операцию.
        func release() { gate?.signal() }

        private func perform(_ call: Call) throws {
            lock.withLock {
                callsStorage.append(call)
                pendingStorage += 1
            }
            gate?.wait()
            let error: Error? = lock.withLock {
                pendingStorage -= 1
                if let after = statusAfterOperation { statusStorage = after }
                return nextError
            }
            if let error { throw error }
        }
    }

    private func makeModel(
        status: LoginItemStatus,
        isAppBundle: Bool = true,
        gated: Bool = false
    ) -> (SettingsModel, MockLoginItem) {
        let mock = MockLoginItem(status: status, gated: gated)
        let model = SettingsModel(loginItem: mock, isAppBundle: isAppBundle)
        return (model, mock)
    }

    /// Крутит run loop, пока условие не выполнится или не истечёт дедлайн —
    /// завершения приезжают через MainActor.run в главную очередь.
    private func waitUntil(_ condition: () -> Bool, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "условие не выполнилось за 2 с", line: line)
    }

    // MARK: - Маппинг состояний

    func testEachSystemStatusAndBareBinaryMapToDistinctDisplayStates() {
        let cases: [(isAppBundle: Bool, status: LoginItemStatus, expected: LaunchAtLoginDisplayState)] = [
            (true, .enabled, .on),
            (true, .notRegistered, .off),
            (true, .requiresApproval, .requiresApproval),
            (true, .unknown, .unavailable(.unknownStatus)),
            (false, .enabled, .unavailable(.notInAppBundle)),
        ]
        var seen: [LaunchAtLoginDisplayState] = []
        for item in cases {
            let (model, _) = makeModel(status: item.status, isAppBundle: item.isAppBundle)
            model.refresh()
            XCTAssertEqual(model.displayState, item.expected, "\(item)")
            XCTAssertFalse(seen.contains(item.expected), "состояние \(item.expected) не уникально")
            seen.append(item.expected)
        }
    }

    /// Полная таблица чистого маппинга: каждый статус (и «ещё не читался») ×
    /// бандл × «register закончился notFound». Флаг влияет только на
    /// `notFound` в бандле.
    func testDeriveFullMatrix() {
        let statuses: [LoginItemStatus?] = [.enabled, .notRegistered, .requiresApproval, .notFound, .unknown, nil]
        for status in statuses {
            for registerEndedNotFound in [false, true] {
                XCTAssertEqual(
                    LaunchAtLoginDisplayState.derive(
                        isAppBundle: false, status: status, registerEndedNotFound: registerEndedNotFound
                    ),
                    .unavailable(.notInAppBundle),
                    "\(String(describing: status)) \(registerEndedNotFound)"
                )
                let expected: LaunchAtLoginDisplayState
                switch status {
                case .enabled: expected = .on
                case .notRegistered: expected = .off
                case .requiresApproval: expected = .requiresApproval
                case .notFound: expected = registerEndedNotFound ? .unavailable(.notFound) : .off
                case .unknown, nil: expected = .unavailable(.unknownStatus)
                }
                XCTAssertEqual(
                    LaunchAtLoginDisplayState.derive(
                        isAppBundle: true, status: status, registerEndedNotFound: registerEndedNotFound
                    ),
                    expected,
                    "\(String(describing: status)) \(registerEndedNotFound)"
                )
            }
        }
    }

    func testBeforeFirstRefreshStateIsUnknownNotOff() {
        let (model, mock) = makeModel(status: .enabled)
        XCTAssertEqual(model.displayState, .unavailable(.unknownStatus))
        XCTAssertFalse(model.isToggleOn)
        XCTAssertEqual(mock.statusReads, 0)
    }

    func testEnabledShowsToggleOnAndClickable() {
        let (model, _) = makeModel(status: .enabled)
        model.refresh()
        XCTAssertTrue(model.isToggleOn)
        XCTAssertTrue(model.isToggleEnabled)
        XCTAssertFalse(model.showsApprovalHint)
        XCTAssertNil(model.unavailableMessage)
    }

    func testNotRegisteredShowsToggleOffAndClickable() {
        let (model, _) = makeModel(status: .notRegistered)
        model.refresh()
        XCTAssertFalse(model.isToggleOn)
        XCTAssertTrue(model.isToggleEnabled)
        XCTAssertFalse(model.showsApprovalHint)
        XCTAssertNil(model.unavailableMessage)
    }

    func testRequiresApprovalShowsHintNotOff() {
        let (model, _) = makeModel(status: .requiresApproval)
        model.refresh()
        XCTAssertTrue(model.showsApprovalHint)
        XCTAssertFalse(model.isToggleOn)
        XCTAssertFalse(model.isToggleEnabled)
        XCTAssertNil(model.unavailableMessage)
    }

    func testUnavailableStatesCarryTheirOwnReason() {
        let cases: [(isAppBundle: Bool, status: LoginItemStatus, key: String)] = [
            (true, .unknown, "settings.launch_at_login.unavailable.unknown"),
            (false, .notRegistered, "settings.launch_at_login.unavailable.not_in_bundle"),
        ]
        for item in cases {
            let (model, _) = makeModel(status: item.status, isAppBundle: item.isAppBundle)
            model.refresh()
            XCTAssertEqual(model.unavailableMessage, L10n.string(item.key), "\(item)")
            XCTAssertFalse(model.isToggleEnabled)
            XCTAssertFalse(model.isToggleOn)
            XCTAssertFalse(model.showsApprovalHint)
        }
    }

    /// Голый бинарь — собственный факт: системе вопросов не задаём, даже
    /// если она сказала бы `enabled`.
    func testBareBinaryNeverQueriesTheSystem() {
        let (model, mock) = makeModel(status: .enabled, isAppBundle: false)
        model.refresh()
        model.setLaunchAtLogin(true)
        model.setLaunchAtLogin(false)
        XCTAssertEqual(mock.statusReads, 0)
        XCTAssertEqual(mock.calls, [])
        XCTAssertEqual(model.displayState, .unavailable(.notInAppBundle))
    }

    func testIsRunningFromAppBundle() {
        XCTAssertTrue(isRunningFromAppBundle(bundleURL: URL(fileURLWithPath: "/Users/x/Applications/WGStatusBar.app")))
        XCTAssertTrue(isRunningFromAppBundle(bundleURL: URL(fileURLWithPath: "/Applications/WGStatusBar.APP/")))
        XCTAssertFalse(isRunningFromAppBundle(bundleURL: URL(fileURLWithPath: "/repo/.build/debug")))
        XCTAssertFalse(isRunningFromAppBundle(bundleURL: URL(fileURLWithPath: "/repo/.build/arm64-apple-macosx/debug/WGStatusBar")))
    }

    // MARK: - Система — источник истины

    func testRefreshFollowsExternalChanges() {
        let (model, mock) = makeModel(status: .enabled)
        model.refresh()
        XCTAssertEqual(model.displayState, .on)

        // Пользователь выключил в System Settings.
        mock.setStatus(.requiresApproval)
        model.refresh()
        XCTAssertEqual(model.displayState, .requiresApproval)

        mock.setStatus(.notRegistered)
        model.refresh()
        XCTAssertEqual(model.displayState, .off)
    }

    /// Статус перечитывается непосредственно перед действием: устаревший
    /// показ «off» при уже включённой системе не ведёт к лишнему register.
    func testStatusIsReReadBeforeAction() {
        let (model, mock) = makeModel(status: .notRegistered)
        model.refresh()
        mock.setStatus(.enabled)

        model.setLaunchAtLogin(true)

        XCTAssertEqual(mock.calls, [], "система уже enabled — действие не нужно")
        XCTAssertEqual(model.displayState, .on)
        XCTAssertFalse(model.isBusy)
    }

    // MARK: - Действия

    func testRegisterSuccessReReadsStatus() {
        let (model, mock) = makeModel(status: .notRegistered)
        mock.statusAfterOperation = .enabled
        model.refresh()

        model.setLaunchAtLogin(true)
        XCTAssertTrue(model.isBusy)
        XCTAssertFalse(model.isToggleEnabled, "во время операции переключатель выключен")
        XCTAssertFalse(model.isToggleOn, "оптимистичного Bool нет — on только от системы")
        let readsBeforeCompletion = mock.statusReads

        waitUntil { !model.isBusy }

        XCTAssertEqual(mock.calls, [.register])
        XCTAssertGreaterThan(mock.statusReads, readsBeforeCompletion, "статус перечитан после успеха")
        XCTAssertEqual(model.displayState, .on)
        XCTAssertNil(model.errorMessage)
    }

    func testUnregisterSuccessReReadsStatus() {
        let (model, mock) = makeModel(status: .enabled)
        mock.statusAfterOperation = .notRegistered
        model.refresh()

        model.setLaunchAtLogin(false)
        waitUntil { !model.isBusy }

        XCTAssertEqual(mock.calls, [.unregister])
        XCTAssertEqual(model.displayState, .off)
        XCTAssertNil(model.errorMessage)
    }

    /// Register может сработать частично: система показывает
    /// `requiresApproval` — модель отражает именно это, а не «on».
    func testRegisterLeadingToRequiresApprovalShowsHint() {
        let (model, mock) = makeModel(status: .notRegistered)
        mock.statusAfterOperation = .requiresApproval
        model.refresh()

        model.setLaunchAtLogin(true)
        waitUntil { !model.isBusy }

        XCTAssertEqual(model.displayState, .requiresApproval)
        XCTAssertTrue(model.showsApprovalHint)
    }

    func testRegisterFailureShowsErrorAndReReadsStatus() {
        let (model, mock) = makeModel(status: .notRegistered)
        mock.nextError = MockFailure()
        model.refresh()

        model.setLaunchAtLogin(true)
        let readsBeforeCompletion = mock.statusReads
        // Система изменилась за время операции — после сбоя показываем её.
        mock.setStatus(.requiresApproval)
        waitUntil { !model.isBusy }

        XCTAssertEqual(model.errorMessage, L10n.string("settings.launch_at_login.error.register_failed"))
        XCTAssertGreaterThan(mock.statusReads, readsBeforeCompletion, "статус перечитан после сбоя")
        XCTAssertEqual(model.displayState, .requiresApproval)
    }

    func testUnregisterFailureShowsFixedCategory() {
        let (model, mock) = makeModel(status: .enabled)
        mock.nextError = NSError(domain: "SMAppServiceErrorDomain", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "raw system text",
        ])
        model.refresh()

        model.setLaunchAtLogin(false)
        waitUntil { !model.isBusy }

        XCTAssertEqual(model.errorMessage, L10n.string("settings.launch_at_login.error.unregister_failed"))
        XCTAssertFalse(model.errorMessage?.contains("raw system text") ?? true, "сырой текст NSError в окно не идёт")
        XCTAssertEqual(model.displayState, .on)
    }

    func testErrorSurvivesRefreshAndIsReplacedByNextAction() {
        let (model, mock) = makeModel(status: .notRegistered)
        mock.nextError = MockFailure()
        model.refresh()
        model.setLaunchAtLogin(true)
        waitUntil { !model.isBusy }
        let error = model.errorMessage
        XCTAssertNotNil(error)

        // Показ окна / активация приложения — ошибка остаётся.
        model.refresh()
        model.refresh()
        XCTAssertEqual(model.errorMessage, error)

        // Новое действие пользователя заменяет ошибку (стирается на старте,
        // успех её не возвращает).
        mock.nextError = nil
        mock.statusAfterOperation = .enabled
        model.setLaunchAtLogin(true)
        XCTAssertNil(model.errorMessage, "новое действие стирает прошлую ошибку сразу")
        waitUntil { !model.isBusy }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.displayState, .on)
    }

    func testFailureOfNextActionReplacesPreviousError() {
        let (model, mock) = makeModel(status: .notRegistered)
        mock.nextError = MockFailure()
        model.refresh()
        model.setLaunchAtLogin(true)
        waitUntil { !model.isBusy }
        XCTAssertEqual(model.errorMessage, L10n.string("settings.launch_at_login.error.register_failed"))

        mock.setStatus(.enabled)
        model.setLaunchAtLogin(false)
        waitUntil { !model.isBusy }
        XCTAssertEqual(model.errorMessage, L10n.string("settings.launch_at_login.error.unregister_failed"))
    }

    // MARK: - requiresApproval: без авто-перерегистрации

    func testToggleInRequiresApprovalIsNoOp() {
        let (model, mock) = makeModel(status: .requiresApproval)
        model.refresh()

        model.setLaunchAtLogin(true)
        model.setLaunchAtLogin(false)

        XCTAssertEqual(mock.calls, [], "никаких register/unregister поверх отказа пользователя")
        XCTAssertFalse(model.isBusy)
    }

    func testOpenLoginItemsSettingsCallsBoundary() {
        let (model, mock) = makeModel(status: .requiresApproval)
        model.openLoginItemsSettings()
        XCTAssertEqual(mock.calls, [.openSettings])
    }

    func testToggleInUnknownStatusIsNoOp() {
        let (model, mock) = makeModel(status: .unknown)
        model.refresh()
        model.setLaunchAtLogin(true)
        model.setLaunchAtLogin(false)
        XCTAssertEqual(mock.calls, [])
    }

    // MARK: - notFound: обычный статус свежей установки

    /// Система ещё не видела сервис — это «выключено», не недоступность.
    func testNotFoundBeforeAttemptReadsOffAndClickable() {
        let (model, _) = makeModel(status: .notFound)
        model.refresh()
        XCTAssertEqual(model.displayState, .off)
        XCTAssertFalse(model.isToggleOn)
        XCTAssertTrue(model.isToggleEnabled)
        XCTAssertFalse(model.showsApprovalHint)
        XCTAssertNil(model.unavailableMessage)
    }

    /// Выключать нечего: unregister из notFound не зовётся.
    func testToggleOffFromNotFoundIsNoOp() {
        let (model, mock) = makeModel(status: .notFound)
        model.refresh()
        model.setLaunchAtLogin(false)
        XCTAssertEqual(mock.calls, [])
        XCTAssertFalse(model.isBusy)
    }

    /// Исход register из notFound × статус после попытки: каждая
    /// комбинация даёт своё отображение.
    func testRegisterFromNotFoundOutcomes() {
        let notFoundReason = L10n.string("settings.launch_at_login.unavailable.not_found")
        let registerFailed = L10n.string("settings.launch_at_login.error.register_failed")
        let cases: [(throws: Bool, after: LoginItemStatus, state: LaunchAtLoginDisplayState, reason: String?, error: String?)] = [
            (false, .enabled, .on, nil, nil),
            (false, .requiresApproval, .requiresApproval, nil, nil),
            (false, .notRegistered, .off, nil, nil),
            (false, .notFound, .unavailable(.notFound), notFoundReason, nil),
            (true, .notFound, .unavailable(.notFound), notFoundReason, registerFailed),
            (true, .notRegistered, .off, nil, registerFailed),
        ]
        for item in cases {
            let (model, mock) = makeModel(status: .notFound)
            mock.statusAfterOperation = item.after
            mock.nextError = item.throws ? MockFailure() : nil
            model.refresh()

            model.setLaunchAtLogin(true)
            waitUntil { !model.isBusy }

            XCTAssertEqual(mock.calls, [.register], "\(item)")
            XCTAssertEqual(model.displayState, item.state, "\(item)")
            XCTAssertEqual(model.unavailableMessage, item.reason, "\(item)")
            XCTAssertEqual(model.errorMessage, item.error, "\(item)")
            XCTAssertEqual(model.isToggleEnabled, item.state == .on || item.state == .off, "\(item)")
        }
    }

    /// После неудачной попытки причина держится на refresh, пока система
    /// говорит notFound, и уходит, как только статус меняется.
    func testNotFoundReasonPersistsUntilSystemStatusChanges() {
        let (model, mock) = makeModel(status: .notFound)
        model.refresh()
        model.setLaunchAtLogin(true)
        waitUntil { !model.isBusy }
        XCTAssertEqual(model.displayState, .unavailable(.notFound))

        model.refresh()
        XCTAssertEqual(model.displayState, .unavailable(.notFound))
        model.setLaunchAtLogin(true)
        XCTAssertEqual(mock.calls, [.register], "недоступное состояние — no-op")

        mock.setStatus(.notRegistered)
        model.refresh()
        XCTAssertEqual(model.displayState, .off)

        // Флаг сброшен: новый notFound снова читается как «выключено».
        mock.setStatus(.notFound)
        model.refresh()
        XCTAssertEqual(model.displayState, .off)
        XCTAssertNil(model.unavailableMessage)
    }

    /// Unregister, оставивший notFound, не ставит причину — её даёт только
    /// попытка register.
    func testUnregisterEndingNotFoundReadsOff() {
        let (model, mock) = makeModel(status: .enabled)
        mock.statusAfterOperation = .notFound
        model.refresh()
        model.setLaunchAtLogin(false)
        waitUntil { !model.isBusy }
        XCTAssertEqual(mock.calls, [.unregister])
        XCTAssertEqual(model.displayState, .off)
        XCTAssertNil(model.unavailableMessage)
    }

    /// Голый бинарь при системном notFound: системе вопросов не задаём.
    func testBareBinaryWithNotFoundMakesNoSystemCalls() {
        let (model, mock) = makeModel(status: .notFound, isAppBundle: false)
        model.refresh()
        model.setLaunchAtLogin(true)
        XCTAssertEqual(mock.statusReads, 0)
        XCTAssertEqual(mock.calls, [])
        XCTAssertEqual(model.displayState, .unavailable(.notInAppBundle))
    }

    // MARK: - Одна операция за раз

    func testSecondToggleWhileInFlightIsNoOp() {
        let (model, mock) = makeModel(status: .notRegistered, gated: true)
        mock.statusAfterOperation = .enabled
        model.refresh()

        model.setLaunchAtLogin(true)
        waitUntil { mock.pending == 1 }
        let readsDuringOperation = mock.statusReads

        model.setLaunchAtLogin(true)
        model.setLaunchAtLogin(false)

        XCTAssertEqual(mock.calls, [.register], "повтор во время операции — no-op")
        XCTAssertEqual(mock.statusReads, readsDuringOperation, "no-op не трогает даже статус")
        XCTAssertTrue(model.isBusy)

        mock.release()
        waitUntil { !model.isBusy }
        XCTAssertEqual(mock.calls, [.register])
        XCTAssertEqual(model.displayState, .on)

        // После завершения действия снова принимаются.
        mock.statusAfterOperation = .notRegistered
        model.setLaunchAtLogin(false)
        waitUntil { mock.pending == 1 }
        mock.release()
        waitUntil { !model.isBusy }
        XCTAssertEqual(mock.calls, [.register, .unregister])
        XCTAssertEqual(model.displayState, .off)
    }

    // MARK: - Локализация

    func testEveryLaunchAtLoginKeyPresentInBothLocalizations() throws {
        let keys = [
            "settings.launch_at_login.error.register_failed",
            "settings.launch_at_login.error.unregister_failed",
            "settings.launch_at_login.unavailable.not_in_bundle",
            "settings.launch_at_login.unavailable.not_found",
            "settings.launch_at_login.unavailable.unknown",
        ]
        for language in ["en", "ru"] {
            let lprojPath = try XCTUnwrap(Bundle.module.path(forResource: language, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: lprojPath))
            for key in keys {
                let value = bundle.localizedString(forKey: key, value: key, table: "Localizable")
                XCTAssertNotEqual(value, key, "ключ \(key) отсутствует в \(language)")
                XCTAssertFalse(value.isEmpty, "значение \(key) в \(language) пустое")
            }
        }
    }
}
