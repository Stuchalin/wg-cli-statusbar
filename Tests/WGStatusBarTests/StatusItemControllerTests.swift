import AppKit
import XCTest
@testable import WGStatusBarCore

final class StatusItemControllerTests: XCTestCase {
    // MARK: - Фикстуры (относительно now, с запасом от порогов 2/10 мин)

    private func peer(_ key: String, handshakeSecondsAgo: Int?) -> WGPeer {
        WGPeer(
            publicKey: key,
            latestHandshake: handshakeSecondsAgo.map { Date(timeIntervalSinceNow: TimeInterval(-$0)) }
        )
    }

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

    // MARK: - Тайтл статус-айтема wg: on/off

    func testStatusTitleOnWhenAnyInterfaceConnected() {
        let oneActive = [WGInterface(name: "utun3", peers: [peer("a", handshakeSecondsAgo: 60)])]
        XCTAssertEqual(StatusItemController.statusTitle(interfaces: oneActive), L10n.string("menu.title.on"))

        let partlyActive = [
            WGInterface(name: "utun3", peers: [peer("a", handshakeSecondsAgo: 60)]),
            WGInterface(name: "utun7", peers: [peer("b", handshakeSecondsAgo: nil)]),
        ]
        XCTAssertEqual(StatusItemController.statusTitle(interfaces: partlyActive), L10n.string("menu.title.on"))
    }

    func testStatusTitleOnForAgingHandshake() {
        let aging = [WGInterface(name: "utun3", peers: [peer("a", handshakeSecondsAgo: 5 * 60)])]
        XCTAssertEqual(StatusItemController.statusTitle(interfaces: aging), L10n.string("menu.title.on"), "хендшейк −5 мин — ещё orange → подключён")
    }

    func testStatusTitleOffWhenNobodyActive() {
        XCTAssertEqual(StatusItemController.statusTitle(interfaces: []), L10n.string("menu.title.off"))
        XCTAssertEqual(StatusItemController.statusTitle(interfaces: [WGInterface(name: "utun3", peers: [])]), L10n.string("menu.title.off"))
        XCTAssertEqual(StatusItemController.statusTitle(interfaces: [WGInterface(name: "utun3", peers: [peer("a", handshakeSecondsAgo: nil)])]), L10n.string("menu.title.off"))
        XCTAssertEqual(StatusItemController.statusTitle(interfaces: [WGInterface(name: "utun3", peers: [peer("a", handshakeSecondsAgo: 15 * 60)])]), L10n.string("menu.title.off"), "хендшейк −15 мин — stale → отключён")
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

        guard case .separator = entries[entries.count - 2] else { return XCTFail("перед выходом — разделитель") }
        guard case .action(.quit, _, _, _, _) = entries[entries.count - 1] else { return XCTFail("последний пункт — выход") }
    }

    func testMenuStructureRefreshDisabledWhileLoading() {
        let entries = StatusMenuStructure.entries(refreshEnabled: false)
        assertAction(actionEntry(.refresh, in: entries), id: .refresh, title: "button.refresh", shortcut: "r", enabled: false)
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

        let quit = items[6]
        XCTAssertEqual(quit.title, L10n.string("button.quit"))
        XCTAssertEqual(quit.keyEquivalent, "q")
        XCTAssertEqual(quit.keyEquivalentModifierMask, .command)
        XCTAssertEqual(quit.tag, StatusMenuAction.quit.rawValue)
    }
}
