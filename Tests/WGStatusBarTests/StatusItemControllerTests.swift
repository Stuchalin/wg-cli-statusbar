import AppKit
import XCTest
@testable import WGStatusBarCore

final class StatusItemControllerTests: XCTestCase {
    // MARK: - Фикстуры

    private func actionEntry(
        _ id: StatusMenuAction,
        in entries: [StatusMenuStructure.Entry],
        line: UInt = #line
    ) -> StatusMenuStructure.Entry? {
        let entry = entries.first {
            if case .action(let actionId, _, _, _, _) = $0 { return actionId == id }
            return false
        }
        XCTAssertNotNil(entry, "в структуре меню нет действия \(id)", line: line)
        return entry
    }

    private func assertAction(
        _ entry: StatusMenuStructure.Entry?,
        id: StatusMenuAction,
        title key: String,
        shortcut: String,
        modifiers: NSEvent.ModifierFlags = .command,
        enabled: Bool,
        line: UInt = #line
    ) {
        guard case .action(let actualId, let title, let keyEquivalent, let actualModifiers, let isEnabled)? = entry
        else {
            return XCTFail("ожидалось действие \(id), получено \(String(describing: entry))", line: line)
        }
        XCTAssertEqual(actualId, id, line: line)
        XCTAssertEqual(title, L10n.string(key), line: line)
        XCTAssertEqual(keyEquivalent, shortcut, line: line)
        XCTAssertEqual(actualModifiers, modifiers, line: line)
        XCTAssertEqual(isEnabled, enabled, line: line)
    }

    // MARK: - Действия меню: диспетчеризация (статически, без NSStatusItem)

    private final class SuccessRunner: WGShowCommandRunning {
        func runDump() async throws -> String { "" }
    }

    private final class CountingTunnelNamer: WireGuardTunnelNaming {
        private let lock = NSLock()
        private var rescanCountStorage = 0

        var rescanCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return rescanCountStorage
        }

        func displayName(for interfaceName: String) -> String { interfaceName }

        func rescan() {
            lock.lock()
            defer { lock.unlock() }
            rescanCountStorage += 1
        }
    }

    func testPerformRefreshForcesNameRescan() {
        let namer = CountingTunnelNamer()
        let model = WireGuardStatusModel(commandRunner: SuccessRunner(), tunnelNamer: namer)

        StatusItemController.performStatusAction(.refresh, model: model, quit: {})

        // rescan происходит в detached-задаче refresh — крутим run loop до её завершения
        let deadline = Date().addingTimeInterval(2)
        while namer.rescanCount == 0 && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(namer.rescanCount, 1, "«Обновить» должен звать refresh с forceNameRescan: true")
    }

    func testPerformQuitCallsQuitHandler() {
        var quitCalled = false
        let model = WireGuardStatusModel(commandRunner: SuccessRunner(), tunnelNamer: CountingTunnelNamer())

        StatusItemController.performStatusAction(.quit, model: model) { quitCalled = true }

        XCTAssertTrue(quitCalled)
    }

    private final class CountingInstaller: ServiceInstalling {
        private let lock = NSLock()
        private var installCountStorage = 0
        private var uninstallCountStorage = 0

        var installCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return installCountStorage
        }

        var uninstallCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return uninstallCountStorage
        }

        func install() async {
            lock.withLock { installCountStorage += 1 }
        }

        func uninstall() async {
            lock.withLock { uninstallCountStorage += 1 }
        }
    }

    /// Крутит run loop, пока условие не выполнится или не истечёт дедлайн —
    /// install()/uninstall() уходят в Task из синхронной диспетчеризации.
    private func waitUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    func testPerformInstallServiceCallsInstaller() {
        let installer = CountingInstaller()
        let model = WireGuardStatusModel(commandRunner: SuccessRunner(), tunnelNamer: CountingTunnelNamer())

        StatusItemController.performStatusAction(.installService, model: model, installer: installer, quit: {})

        waitUntil { installer.installCount > 0 }
        XCTAssertEqual(installer.installCount, 1, "«Установить/Обновить сервис» дёргает installer.install()")
        XCTAssertEqual(installer.uninstallCount, 0)
    }

    func testPerformUninstallServiceCallsInstaller() {
        let installer = CountingInstaller()
        let model = WireGuardStatusModel(commandRunner: SuccessRunner(), tunnelNamer: CountingTunnelNamer())

        StatusItemController.performStatusAction(.uninstallService, model: model, installer: installer, quit: {})

        waitUntil { installer.uninstallCount > 0 }
        XCTAssertEqual(installer.uninstallCount, 1, "«Удалить сервис» дёргает installer.uninstall()")
        XCTAssertEqual(installer.installCount, 0)
    }

    func testPerformOtherActionsDoNotTouchInstaller() {
        let installer = CountingInstaller()
        let namer = CountingTunnelNamer()
        let model = WireGuardStatusModel(commandRunner: SuccessRunner(), tunnelNamer: namer)

        StatusItemController.performStatusAction(.refresh, model: model, installer: installer, quit: {})
        StatusItemController.performStatusAction(.quit, model: model, installer: installer) {}

        // Даём асинхронно запланированные вызовы шанс проявиться до проверки.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(installer.installCount, 0, "«Обновить»/«Выход» не дёргают установщик")
        XCTAssertEqual(installer.uninstallCount, 0)
    }

    // MARK: - Структура меню: пункты, шорткаты, разделители, enabled

    func testMenuStructureEntriesOrderAndShortcuts() {
        let entries = StatusMenuStructure.entries()

        guard case .card = entries[0] else { return XCTFail("первый пункт — карточка статуса") }
        guard case .separator = entries[1] else { return XCTFail("после карточки — разделитель") }

        assertAction(actionEntry(.refresh, in: entries), id: .refresh, title: "button.refresh", shortcut: "r", enabled: true)
        assertAction(actionEntry(.openConfigs, in: entries), id: .openConfigs, title: "button.open_configs", shortcut: "o", enabled: true)
        assertAction(
            actionEntry(.manageTunnels, in: entries),
            id: .manageTunnels,
            title: "button.tunnel_management_soon",
            shortcut: "",
            modifiers: [],
            enabled: false,
            line: #line
        )
        assertAction(actionEntry(.quit, in: entries), id: .quit, title: "button.quit", shortcut: "q", enabled: true)

        guard case .separator = entries[entries.count - 3] else { return XCTFail("перед пунктом сервиса — разделитель") }
        guard case .action(.installService, _, _, _, _) = entries[entries.count - 2] else {
            return XCTFail("перед выходом — пункт сервиса (по умолчанию absent — «Установить»)")
        }
        guard case .action(.quit, _, _, _, _) = entries[entries.count - 1] else { return XCTFail("последний пункт — выход") }
    }

    func testMenuStructureRefreshDisabledWhileLoading() {
        let entries = StatusMenuStructure.entries(refreshEnabled: false)
        assertAction(actionEntry(.refresh, in: entries), id: .refresh, title: "button.refresh", shortcut: "r", enabled: false)
    }

    // MARK: - Пункт сервиса: состояние → действие/титул, позиция перед «Выход»

    func testMenuStructureServiceItemReflectsServiceState() {
        let cases: [(state: ServiceState, id: StatusMenuAction, titleKey: String)] = [
            (.absent, .installService, "button.install_service"),
            (.broken, .installService, "button.update_service"),
            (.outdated, .installService, "button.update_service"),
            (.installed, .uninstallService, "button.remove_service"),
        ]

        for testCase in cases {
            let entries = StatusMenuStructure.entries(serviceState: testCase.state)
            assertAction(
                actionEntry(testCase.id, in: entries),
                id: testCase.id,
                title: testCase.titleKey,
                shortcut: "",
                modifiers: [],
                enabled: true,
                line: #line
            )

            // Пункт сервиса один: противоположного действия в меню быть не должно
            let opposite: StatusMenuAction = testCase.id == .installService ? .uninstallService : .installService
            let hasOpposite = entries.contains { entry in
                if case .action(opposite, _, _, _, _) = entry { return true }
                return false
            }
            XCTAssertFalse(hasOpposite, "в состоянии \(testCase.state) пункта \(opposite) быть не должно")

            // Пункт — сразу перед «Выход»
            guard case .action(.quit, _, _, _, _) = entries.last else {
                return XCTFail("последний пункт — выход")
            }
            guard case .action(testCase.id, _, _, _, _) = entries[entries.count - 2] else {
                return XCTFail("пункт сервиса в состоянии \(testCase.state) — сразу перед выходом")
            }
        }
    }

    func testServiceActionMappingMatchesServiceState() {
        // Тот же маппинг питает и сборку меню, и живое обновление пункта при
        // открытом меню (`updateServiceItem`): состояние → действие + титул.
        let cases: [(state: ServiceState, id: StatusMenuAction, titleKey: String)] = [
            (.absent, .installService, "button.install_service"),
            (.broken, .installService, "button.update_service"),
            (.outdated, .installService, "button.update_service"),
            (.installed, .uninstallService, "button.remove_service"),
        ]

        for testCase in cases {
            let action = StatusMenuStructure.serviceAction(for: testCase.state)
            XCTAssertEqual(action.id, testCase.id, "состояние \(testCase.state): действие")
            XCTAssertEqual(action.title, L10n.string(testCase.titleKey), "состояние \(testCase.state): титул")
        }
    }

    // MARK: - Изолированный билдер: NSMenuItem из структуры

    func testFactoryBuildsMenuItemsMatchingStructure() {
        final class ActionTarget: NSObject {
            @objc func handleMenuAction(_ sender: NSMenuItem) {}
        }
        let target = ActionTarget()
        let selector = #selector(ActionTarget.handleMenuAction(_:))
        let cardItem = CardMenuItem()

        let entries = StatusMenuStructure.entries()
        let items = StatusMenuFactory.makeItems(
            from: entries,
            target: target,
            action: selector,
            cardItemProvider: { cardItem }
        )

        XCTAssertEqual(items.count, entries.count)

        XCTAssertTrue(items[0] === cardItem, "пункт-карточка приходит из провайдера как есть")
        XCTAssertTrue(items[1].isSeparatorItem)

        let refresh = items[2]
        XCTAssertEqual(refresh.title, L10n.string("button.refresh"))
        XCTAssertEqual(refresh.keyEquivalent, "r")
        XCTAssertEqual(refresh.keyEquivalentModifierMask, .command)
        XCTAssertTrue(refresh.isEnabled)
        XCTAssertEqual(refresh.tag, StatusMenuAction.refresh.rawValue)
        XCTAssertTrue(refresh.target === target, "target-action идут в контроллер")
        XCTAssertEqual(refresh.action, selector)

        let manageTunnels = items[4]
        XCTAssertEqual(manageTunnels.title, L10n.string("button.tunnel_management_soon"))
        XCTAssertFalse(manageTunnels.isEnabled, "управление тоннелями — disabled placeholder")
        XCTAssertEqual(manageTunnels.keyEquivalent, "", "у placeholder нет шортката")

        XCTAssertTrue(items[5].isSeparatorItem)

        let service = items[6]
        XCTAssertEqual(service.title, L10n.string("button.install_service"), "по умолчанию absent — «Установить сервис»")
        XCTAssertEqual(service.keyEquivalent, "", "у пункта сервиса нет шортката")
        XCTAssertEqual(service.tag, StatusMenuAction.installService.rawValue)

        let quit = items[7]
        XCTAssertEqual(quit.title, L10n.string("button.quit"))
        XCTAssertEqual(quit.keyEquivalent, "q")
        XCTAssertEqual(quit.keyEquivalentModifierMask, .command)
        XCTAssertEqual(quit.tag, StatusMenuAction.quit.rawValue)
    }

    // MARK: - Иконки меню-бара: загрузка из бандла, template, размер

    func testBothIconsLoadFromBundle() {
        XCTAssertNotNil(StatusIcon.image(connected: true), "StatusIconOn.pdf должен лежать в ресурсах бандла")
        XCTAssertNotNil(StatusIcon.image(connected: false), "StatusIconOff.pdf должен лежать в ресурсах бандла")
    }

    func testIconsAreTemplate() {
        // template обязателен: иконки нарисованы белым, без флага они невидимы в светлой теме
        XCTAssertEqual(StatusIcon.on?.isTemplate, true)
        XCTAssertEqual(StatusIcon.off?.isTemplate, true)
    }

    func testIconSizeMatchesMediaBox() {
        // 18×18 из MediaBox PDF — штатный размер иконки меню-бара
        XCTAssertEqual(StatusIcon.on?.size, NSSize(width: 18, height: 18))
        XCTAssertEqual(StatusIcon.off?.size, NSSize(width: 18, height: 18))
    }

    func testImageMappingByConnectionState() {
        XCTAssertTrue(StatusIcon.image(connected: true) === StatusIcon.on)
        XCTAssertTrue(StatusIcon.image(connected: false) === StatusIcon.off)
    }
}
