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

    // MARK: - Вьювер конфига: открытие из строки туннеля

    /// Кнопка деталей: сначала закрывается трекинг меню, только затем вьювер
    /// получает имя — окно активируется и забирает фокус, меню ему мешает.
    func testPresentConfigViewerCancelsMenuTrackingBeforeShowing() {
        var order: [String] = []
        final class OrderRecordingViewer: ConfigViewing {
            let onShow: (String) -> Void
            init(onShow: @escaping (String) -> Void) { self.onShow = onShow }
            func showConfig(named name: String) { onShow(name) }
        }
        let viewer = OrderRecordingViewer { name in order.append("show:\(name)") }

        StatusItemController.presentConfigViewer(named: "kvmka-ai", viewer: viewer) {
            order.append("cancel")
        }

        XCTAssertEqual(order, ["cancel", "show:kvmka-ai"], "трекинг меню закрывается до показа")
    }

    /// Без вьювера (nil) клик по деталям — тихий no-op: ни закрытия меню,
    /// ни вызова.
    func testPresentConfigViewerWithoutViewerIsSilentNoOp() {
        var cancelCount = 0

        StatusItemController.presentConfigViewer(named: "kvmka-ai", viewer: nil) {
            cancelCount += 1
        }

        XCTAssertEqual(cancelCount, 0, "без вьювера меню не закрывается")
    }

    /// Туннельный клиент с клапаном: up/down висит, пока клапан не отпущен, —
    /// `inFlightTunnels` держится непустым, как реальная операция на 2–9 с.
    private final class GatedTunnelClient: TunnelCommandRunning {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?

        func state() async throws -> [TunnelState] { [] }

        func up(_ name: String) async throws {
            await withCheckedContinuation { continuation in
                lock.withLock { self.continuation = continuation }
            }
        }

        func down(_ name: String) async throws {
            await withCheckedContinuation { continuation in
                lock.withLock { self.continuation = continuation }
            }
        }

        func releaseGate() {
            lock.withLock {
                continuation?.resume()
                continuation = nil
            }
        }
    }

    /// Установка/удаление сервиса во время туннельной операции — молчаливый
    /// no-op, как вторая линия за disabled-пунктом (ре-рендер асинхронен):
    /// скрипт стартует с `launchctl bootout` → SIGTERM демону посреди
    /// wg-quick up — полуприменённый туннель.
    func testPerformServiceActionsAreNoOpDuringTunnelOperation() {
        let client = GatedTunnelClient()
        let model = WireGuardStatusModel(
            commandRunner: SuccessRunner(),
            tunnelNamer: CountingTunnelNamer(),
            socketExists: { false },
            socketPath: helperSocketPath,
            tunnelCommandRunner: client
        )
        model.toggleTunnel(named: "kvmka-ai")
        XCTAssertFalse(model.inFlightTunnels.isEmpty, "предусловие: операция в полёте")

        let installer = CountingInstaller()
        StatusItemController.performStatusAction(.installService, model: model, installer: installer, quit: {})
        StatusItemController.performStatusAction(.uninstallService, model: model, installer: installer, quit: {})

        // Даём асинхронно запланированные вызовы шанс проявиться до проверки.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(installer.installCount, 0, "установка во время операции — no-op")
        XCTAssertEqual(installer.uninstallCount, 0, "удаление во время операции — no-op")

        client.releaseGate()
        waitUntil { model.inFlightTunnels.isEmpty }
    }

    // MARK: - Структура меню: пункты, шорткаты, разделители, enabled

    func testMenuStructureEntriesOrderAndShortcuts() {
        let entries = StatusMenuStructure.entries()

        guard case .card = entries[0] else { return XCTFail("первый пункт — карточка статуса") }
        guard case .separator = entries[1] else { return XCTFail("после карточки — разделитель") }

        assertAction(actionEntry(.refresh, in: entries), id: .refresh, title: "button.refresh", shortcut: "r", enabled: true)
        assertAction(actionEntry(.openConfigs, in: entries), id: .openConfigs, title: "button.open_configs", shortcut: "o", enabled: true)
        assertAction(actionEntry(.quit, in: entries), id: .quit, title: "button.quit", shortcut: "q", enabled: true)

        // Дефолт: демона нет, список пуст — секции Tunnels нет, между
        // Конфигами и сервисом один разделитель.
        XCTAssertEqual(entries.count, 7, "карточка, разделитель, Обновить, Конфиги, разделитель, сервис, Выход")
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

    // MARK: - Секция Tunnels: позиция, видимость, блокировка строк

    private func makeTunnels() -> [TunnelInfo] {
        [TunnelInfo(name: "kvmka-ai", isUp: true), TunnelInfo(name: "kvmka-full", isUp: false)]
    }

    /// Секция целиком — между «Открыть конфиги» и сервисным пунктом:
    /// разделитель + заголовок + по строке на туннель.
    func testMenuStructureTunnelsSectionPositionAndRows() {
        let entries = StatusMenuStructure.entries(serviceState: .installed, tunnels: makeTunnels())

        XCTAssertEqual(entries.count, 11, "карточка, разделитель, Обновить, Конфиги, разделитель, заголовок, 2 строки, разделитель, сервис, Выход")

        guard case .action(.openConfigs, _, _, _, _) = entries[3] else { return XCTFail("до секции — «Открыть конфиги»") }
        guard case .separator = entries[4] else { return XCTFail("перед секцией — разделитель") }
        guard case .tunnelsHeader(let title) = entries[5] else { return XCTFail("заголовок секции Tunnels") }
        XCTAssertEqual(title, L10n.string("menu.tunnels_section"))
        XCTAssertEqual(entries[6], .tunnelRow(TunnelInfo(name: "kvmka-ai", isUp: true), isEnabled: true))
        XCTAssertEqual(entries[7], .tunnelRow(TunnelInfo(name: "kvmka-full", isUp: false), isEnabled: true))
        guard case .separator = entries[8] else { return XCTFail("после секции — разделитель") }
        guard case .action(.uninstallService, _, _, _, _) = entries[9] else { return XCTFail("installed — пункт «Удалить сервис»") }
        guard case .action(.quit, _, _, _, _) = entries[10] else { return XCTFail("последний пункт — выход") }
    }

    /// Секция скрыта при любом состоянии, кроме живого демона — включая
    /// заголовок и разделители (структура вырождается в базовую).
    func testMenuStructureHidesTunnelsSectionUnlessInstalled() {
        for state in [ServiceState.absent, .broken, .outdated] {
            let entries = StatusMenuStructure.entries(serviceState: state, tunnels: makeTunnels())
            XCTAssertFalse(
                entries.contains { if case .tunnelsHeader = $0 { return true }; return false },
                "в состоянии \(state) заголовка секции быть не должно"
            )
            XCTAssertFalse(
                entries.contains { if case .tunnelRow = $0 { return true }; return false },
                "в состоянии \(state) строк туннелей быть не должно"
            )
            XCTAssertEqual(entries.count, 7, "состояние \(state): базовая структура без секции")
        }
    }

    /// Пустой список туннелей — секции нет целиком.
    func testMenuStructureHidesTunnelsSectionWhenListIsEmpty() {
        let entries = StatusMenuStructure.entries(serviceState: .installed, tunnels: [])

        XCTAssertEqual(entries.count, 7)
        XCTAssertFalse(entries.contains { if case .tunnelsHeader = $0 { return true }; return false })
    }

    /// Операция в полёте: все строки, «Обновить» и пункт сервиса некликабельны
    /// (одна операция за раз; подавленный ⌘R — молчаливый no-op; bootout
    /// демона из скрипта установки/удаления посреди операции — SIGTERM
    /// wg-quick и полуприменённый туннель).
    func testMenuStructureDisablesRowsRefreshAndServiceDuringOperation() {
        let entries = StatusMenuStructure.entries(
            refreshEnabled: true,
            serviceState: .installed,
            tunnels: makeTunnels(),
            hasInFlightTunnelOperation: true
        )

        XCTAssertEqual(entries[6], .tunnelRow(TunnelInfo(name: "kvmka-ai", isUp: true), isEnabled: false))
        XCTAssertEqual(entries[7], .tunnelRow(TunnelInfo(name: "kvmka-full", isUp: false), isEnabled: false))
        assertAction(actionEntry(.refresh, in: entries), id: .refresh, title: "button.refresh", shortcut: "r", enabled: false)
        assertAction(
            actionEntry(.uninstallService, in: entries),
            id: .uninstallService,
            title: "button.remove_service",
            shortcut: "",
            modifiers: [],
            enabled: false
        )
    }

    /// Ключ удалённого disabled-плейсхолдера «Управление тоннелями» не
    /// должен возвращаться в таблицы.
    func testRemovedTunnelManagementKeyIsGoneFromBothLocalizations() throws {
        for language in ["en", "ru"] {
            let lprojPath = try XCTUnwrap(
                Bundle.module.path(forResource: language, ofType: "lproj"),
                "нет \(language).lproj в бандле модуля"
            )
            let bundle = Bundle(path: lprojPath)
            // localizedString(forKey:value:) при отсутствии ключа возвращает value
            let raw = bundle?.localizedString(
                forKey: "button.tunnel_management_soon",
                value: "button.tunnel_management_soon",
                table: "Localizable"
            )
            XCTAssertEqual(raw, "button.tunnel_management_soon", "мёртвый ключ должен быть удалён из \(language)")
        }
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

    func testServiceStateChangeReactionRequiresChangeAndOpenMenu() {
        // Живая реакция на состояние сервиса (`serviceStateDidChange`): дозагрузка
        // списка + пересборка нужны только при СМЕНЕ состояния И открытом меню —
        // умерший при открытом меню демон оставил бы кликабельные строки (клик —
        // гарантированный connectionRefused), закрывшееся меню соберётся свежим
        // при следующем открытии, отсутствие смены — не событие вовсе.
        let cases: [
            (previous: ServiceState, current: ServiceState, isMenuOpen: Bool, expected: Bool)
        ] = [
            (.installed, .broken, true, true),
            (.absent, .installed, true, true),
            (.installed, .installed, true, false),
            (.installed, .broken, false, false),
            (.absent, .absent, false, false),
        ]

        for testCase in cases {
            XCTAssertEqual(
                StatusItemController.shouldReloadTunnelsAndRebuildMenu(
                    previousServiceState: testCase.previous,
                    currentServiceState: testCase.current,
                    isMenuOpen: testCase.isMenuOpen
                ),
                testCase.expected,
                "\(testCase.previous) → \(testCase.current), меню \(testCase.isMenuOpen ? "открыто" : "закрыто")"
            )
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
            cardItemProvider: { cardItem },
            tunnelItemProvider: { _, _ in NSMenuItem() }
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

        let openConfigs = items[3]
        XCTAssertEqual(openConfigs.title, L10n.string("button.open_configs"))
        XCTAssertEqual(openConfigs.tag, StatusMenuAction.openConfigs.rawValue)

        XCTAssertTrue(items[4].isSeparatorItem)

        let service = items[5]
        XCTAssertEqual(service.title, L10n.string("button.install_service"), "по умолчанию absent — «Установить сервис»")
        XCTAssertEqual(service.keyEquivalent, "", "у пункта сервиса нет шортката")
        XCTAssertEqual(service.tag, StatusMenuAction.installService.rawValue)

        let quit = items[6]
        XCTAssertEqual(quit.title, L10n.string("button.quit"))
        XCTAssertEqual(quit.keyEquivalent, "q")
        XCTAssertEqual(quit.keyEquivalentModifierMask, .command)
        XCTAssertEqual(quit.tag, StatusMenuAction.quit.rawValue)
    }

    /// Заголовок секции и строки: заголовок — неактивный нативный пункт,
    /// строки приходят из провайдера с данными каждой.
    func testFactoryBuildsHeaderAndTunnelRowsFromProviders() {
        final class ActionTarget: NSObject {
            @objc func handleMenuAction(_ sender: NSMenuItem) {}
        }
        let target = ActionTarget()
        let selector = #selector(ActionTarget.handleMenuAction(_:))
        let rowItem = TunnelMenuItem()
        var providedTunnels: [TunnelInfo] = []
        var providedEnabledFlags: [Bool] = []

        let entries = StatusMenuStructure.entries(serviceState: .installed, tunnels: makeTunnels())
        let items = StatusMenuFactory.makeItems(
            from: entries,
            target: target,
            action: selector,
            cardItemProvider: { CardMenuItem() },
            tunnelItemProvider: { tunnel, isEnabled in
                providedTunnels.append(tunnel)
                providedEnabledFlags.append(isEnabled)
                return rowItem
            }
        )

        XCTAssertEqual(items.count, entries.count)

        let header = items[5]
        XCTAssertEqual(header.title, L10n.string("menu.tunnels_section"), "title остаётся для VoiceOver")
        XCTAssertFalse(header.isEnabled, "заголовок секции — не действие")

        XCTAssertTrue(items[6] === rowItem, "строки приходят из провайдера как есть")
        XCTAssertTrue(items[7] === rowItem)
        XCTAssertEqual(providedTunnels, makeTunnels(), "провайдер получает каждую строку секции")
        XCTAssertEqual(providedEnabledFlags, [true, true])
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
