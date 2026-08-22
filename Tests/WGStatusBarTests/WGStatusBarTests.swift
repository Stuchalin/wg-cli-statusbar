import XCTest
@testable import WGStatusBarCore

final class WGStatusBarTests: XCTestCase {
    // MARK: - Фикстуры

    /// Хендшейк 60 с назад — свежий (порог green 120 с), с запасом от границы.
    func makeActiveHandshake() -> Date {
        Date(timeIntervalSinceNow: -60)
    }

    /// Хендшейк 5 мин назад — стареющий (между порогами 2 и 10 мин), с запасом от границ.
    func makeAgingHandshake() -> Date {
        Date(timeIntervalSinceNow: -5 * 60)
    }

    /// Хендшейк 15 мин назад — несвежий (порог orange 10 мин), с запасом от границы.
    func makeStaleHandshake() -> Date {
        Date(timeIntervalSinceNow: -15 * 60)
    }

    func makeActivePeer(_ key: String) -> WGPeer {
        WGPeer(publicKey: key, latestHandshake: makeActiveHandshake())
    }

    func makeNeverPeer(_ key: String) -> WGPeer {
        WGPeer(publicKey: key)
    }

    func makeInterface(_ name: String, peers: [WGPeer]) -> WGInterface {
        WGInterface(name: name, peers: peers)
    }

    /// Реалистичный дамп `wg show all dump`: 2 интерфейса, у первого два пира.
    /// Секретные поля помечены SECRET_, чтобы проверить отсутствие утечек.
    func makeFullDump() -> String {
        [
            "utun3\tSECRET_IFACE_PRIVATE_KEY\tiface-pub-key=\t(none)\t(none)",
            "utun3\tpeer-a-pub-key=\tSECRET_PEER_A_PSK\t203.0.113.10:51820\t0.0.0.0/0, ::/0\t1755800000\t897500\t123456\t25",
            "utun3\tpeer-b-pub-key=\t(none)\t(none)\t(none)\t0\t0\t0\toff",
            "utun7\tSECRET_IFACE2_PRIVATE_KEY\tiface2-pub-key=\t4242\toff",
            "utun7\tpeer-c-pub-key=\t(none)\t198.51.100.7:51820\t10.0.0.0/24,192.168.1.0/24\t1755800060\t1024\t2048\toff",
        ].joined(separator: "\n")
    }

    // MARK: - Парсер: полный дамп

    func testParseFullDumpWithTwoInterfacesAndMultiplePeers() {
        let interfaces = parseWGShowDump(makeFullDump())

        XCTAssertEqual(interfaces.count, 2)

        XCTAssertEqual(interfaces[0].name, "utun3")
        XCTAssertEqual(interfaces[0].displayName, "utun3")
        XCTAssertEqual(interfaces[0].peers.count, 2)

        let peerA = interfaces[0].peers[0]
        XCTAssertEqual(peerA.publicKey, "peer-a-pub-key=")
        XCTAssertEqual(peerA.endpoint, "203.0.113.10:51820")
        XCTAssertEqual(peerA.allowedIps, "0.0.0.0/0, ::/0")
        XCTAssertEqual(peerA.latestHandshake?.timeIntervalSince1970, 1_755_800_000)
        XCTAssertEqual(peerA.rxBytes, 897_500)
        XCTAssertEqual(peerA.txBytes, 123_456)

        let peerB = interfaces[0].peers[1]
        XCTAssertEqual(peerB.publicKey, "peer-b-pub-key=")
        XCTAssertNil(peerB.latestHandshake, "handshake 0 (never) должен давать nil")
        XCTAssertEqual(peerB.rxBytes, 0)
        XCTAssertEqual(peerB.txBytes, 0)

        XCTAssertEqual(interfaces[1].name, "utun7")
        XCTAssertEqual(interfaces[1].peers.count, 1)

        let peerC = interfaces[1].peers[0]
        XCTAssertEqual(peerC.endpoint, "198.51.100.7:51820")
        XCTAssertEqual(peerC.allowedIps, "10.0.0.0/24,192.168.1.0/24")
        XCTAssertEqual(peerC.latestHandshake?.timeIntervalSince1970, 1_755_800_060)
        XCTAssertEqual(peerC.rxBytes, 1_024)
        XCTAssertEqual(peerC.txBytes, 2_048)
    }

    func testDisplayNameOverride() {
        let interface = WGInterface(name: "utun3", peers: [], displayName: "work-vpn")

        XCTAssertEqual(interface.displayName, "work-vpn")
        XCTAssertEqual(interface.name, "utun3")
    }

    // MARK: - Парсер: placeholder'ы и мусор

    func testParsePlaceholdersNoneAndOff() {
        let dump = [
            "wg0\tSECRET_KEY\tiface-pub-key=\t(none)\t(none)",
            "wg0\tpeer-a-pub-key=\t(none)\t(none)\t(none)\t0\t0\t0\toff",
        ].joined(separator: "\n")

        let interfaces = parseWGShowDump(dump)

        XCTAssertEqual(interfaces.count, 1)
        let peer = interfaces[0].peers[0]
        XCTAssertNil(peer.endpoint, "(none) endpoint должен давать nil")
        XCTAssertNil(peer.allowedIps, "(none) allowed ips должен давать nil")
        XCTAssertNil(peer.latestHandshake)
        XCTAssertEqual(peer.rxBytes, 0)
        XCTAssertEqual(peer.txBytes, 0)
    }

    func testParseEmptyOutput() {
        XCTAssertEqual(parseWGShowDump(""), [])
    }

    func testParseGarbageOutput() {
        let dump = """
        some random text
        without dump structure
        """
        XCTAssertEqual(parseWGShowDump(dump), [])
    }

    func testParseSkipsGarbageLinesBetweenValid() {
        let dump = [
            "orphan-peer-pub-key=\t(none)\t(none)\t(none)\t(none)\t0\t0\t0\toff",
            "wg0\tSECRET_KEY\tiface-pub-key=\t(none)\t(none)",
            "!!! garbage line !!!",
            "wg0\tpeer-a-pub-key=\t(none)\t203.0.113.10:51820\t10.0.0.2/32\t1755800000\t512\t64\toff",
            "тоже мусор",
        ].joined(separator: "\n")

        let interfaces = parseWGShowDump(dump)

        XCTAssertEqual(interfaces.count, 1)
        XCTAssertEqual(interfaces[0].name, "wg0")
        XCTAssertEqual(interfaces[0].peers.count, 1, "пир после мусорной строки должен распарситься")
        XCTAssertEqual(interfaces[0].peers[0].publicKey, "peer-a-pub-key=")
        XCTAssertEqual(interfaces[0].peers[0].rxBytes, 512)
    }

    func testParseMalformedNumericFieldsFallback() {
        let dump = [
            "wg0\tSECRET_KEY\tiface-pub-key=\t(none)\t(none)",
            "wg0\tpeer-a-pub-key=\t(none)\t1.2.3.4:51820\t10.0.0.2/32\tNaN\tNaN\tNaN\toff",
        ].joined(separator: "\n")

        let interfaces = parseWGShowDump(dump)

        XCTAssertEqual(interfaces.count, 1)
        let peer = interfaces[0].peers[0]
        XCTAssertNil(peer.latestHandshake, "нечисловой epoch должен давать nil")
        XCTAssertEqual(peer.rxBytes, 0)
        XCTAssertEqual(peer.txBytes, 0)
    }

    // MARK: - Парсер: секреты не утекают

    func testSecretsDoNotLeakIntoModel() {
        let interfaces = parseWGShowDump(makeFullDump())

        let allStrings = interfaces.flatMap { interface -> [String] in
            [interface.name, interface.displayName]
                + interface.peers.flatMap { [$0.publicKey, $0.endpoint ?? "", $0.allowedIps ?? ""] }
        }.joined(separator: "\n")

        XCTAssertFalse(allStrings.contains("SECRET_IFACE_PRIVATE_KEY"), "приватный ключ интерфейса не должен попадать в модель")
        XCTAssertFalse(allStrings.contains("SECRET_IFACE2_PRIVATE_KEY"), "приватный ключ второго интерфейса не должен попадать в модель")
        XCTAssertFalse(allStrings.contains("SECRET_PEER_A_PSK"), "preshared key пира не должен попадать в модель")
    }

    // MARK: - Модель: активность через HandshakeFreshness

    func testPeerActivityUsesHandshakeFreshness() {
        XCTAssertTrue(makeActivePeer("active").isActive, "хендшейк 60 с назад — fresh → активен")
        XCTAssertFalse(WGPeer(publicKey: "stale", latestHandshake: makeStaleHandshake()).isActive, "хендшейк 15 мин назад — stale → не активен")
        XCTAssertFalse(makeNeverPeer("never").isActive, "nil (never) → не активен")
    }

    func testInterfaceConnectedWhenAnyPeerActive() {
        XCTAssertTrue(makeInterface("wg0", peers: [makeNeverPeer("a"), makeActivePeer("b")]).isConnected)
        XCTAssertFalse(makeInterface("wg1", peers: [makeNeverPeer("a")]).isConnected)
        XCTAssertFalse(makeInterface("wg2", peers: []).isConnected)
    }

    // MARK: - Модель: menuTitle и isAnyConnected

    func testMenuTitleWhenActiveAndInactive() {
        let connectedModel = WireGuardStatusModel(testing: [makeInterface("wg0", peers: [makeActivePeer("peer-a")])])
        let disconnectedModel = WireGuardStatusModel(testing: [makeInterface("wg0", peers: [makeNeverPeer("peer-b")])])
        let emptyModel = WireGuardStatusModel(testing: [])

        XCTAssertEqual(connectedModel.menuTitle, L10n.string("menu.title.on"))
        XCTAssertEqual(disconnectedModel.menuTitle, L10n.string("menu.title.off"))
        XCTAssertEqual(emptyModel.menuTitle, L10n.string("menu.title.off"))

        XCTAssertTrue(connectedModel.isAnyConnected)
        XCTAssertFalse(disconnectedModel.isAnyConnected)
        XCTAssertFalse(emptyModel.isAnyConnected)
    }

    /// Aging-хендшейк (−5 мин) — всё ещё «подключён»: green|orange дают active.
    func testAgingHandshakeStillCountsAsConnected() {
        let allAging = WireGuardStatusModel(
            testing: [makeInterface("wg0", peers: [WGPeer(publicKey: "peer-a", latestHandshake: makeAgingHandshake())])]
        )

        XCTAssertEqual(allAging.menuTitle, L10n.string("menu.title.on"))

        let partlyAging = WireGuardStatusModel(
            testing: [
                makeInterface("wg0", peers: [WGPeer(publicKey: "peer-a", latestHandshake: makeAgingHandshake())]),
                makeInterface("wg1", peers: [makeNeverPeer("peer-b")]),
            ]
        )

        XCTAssertEqual(partlyAging.menuTitle, L10n.string("menu.title.on"))
    }

    // MARK: - Модель: refresh — dump-команда и displayName из namer

    func makeInterfaceDumpLine(_ name: String) -> String {
        "\(name)\tSECRET_IFACE_PRIVATE_KEY\tiface-pub-key=\t(none)\t(none)"
    }

    func makePeerDumpLine(interfaceName: String, key: String = "peer-a-pub-key=", handshakeSecondsAgo: Int?) -> String {
        let epoch = handshakeSecondsAgo.map { Int(Date().timeIntervalSince1970) - $0 } ?? 0
        return "\(interfaceName)\t\(key)\t(none)\t203.0.113.10:51820\t0.0.0.0/0\t\(epoch)\t897500\t123456\toff"
    }

    func makeDump(_ lines: [String]) -> String {
        lines.joined(separator: "\n")
    }

    /// Прокручивает main run loop, пока условие не станет true (MainActor-апдейты модели).
    func waitUntil(_ condition: () -> Bool, _ message: String, timeout: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), message)
    }

    func testRefreshParsesDumpAndResolvesKnownName() {
        let namer = MockTunnelNamer(knownNames: ["utun3": "work-vpn"])
        let model = WireGuardStatusModel(
            commandRunner: StubCommandRunner(results: [
                .success(makeDump([
                    makeInterfaceDumpLine("utun3"),
                    makePeerDumpLine(interfaceName: "utun3", handshakeSecondsAgo: 60),
                ])),
            ]),
            tunnelNamer: namer
        )

        model.refresh()
        waitUntil({ !model.isLoading }, "refresh должен завершиться")

        XCTAssertEqual(model.interfaces.count, 1)
        XCTAssertEqual(model.interfaces[0].name, "utun3")
        XCTAssertEqual(model.interfaces[0].displayName, "work-vpn", "displayName должен прийти из namer")
        XCTAssertEqual(model.interfaces[0].peers[0].rxBytes, 897_500)
        XCTAssertEqual(model.interfaces[0].peers[0].txBytes, 123_456)
        XCTAssertEqual(model.menuTitle, L10n.string("menu.title.on"), "хендшейк 60 с назад — fresh → подключён")
        XCTAssertEqual(namer.rescanCount, 0, "знакомый utun не должен вызывать rescan")
    }

    func testRefreshRescansExactlyOnceForUnknownTunnel() {
        let namer = MockTunnelNamer(namesDiscoveredOnRescan: ["utun9": "home-vpn"])
        let model = WireGuardStatusModel(
            commandRunner: StubCommandRunner(results: [
                .success(makeDump([
                    makeInterfaceDumpLine("utun9"),
                    makePeerDumpLine(interfaceName: "utun9", handshakeSecondsAgo: 60),
                ])),
            ]),
            tunnelNamer: namer
        )

        model.refresh()
        waitUntil({ !model.isLoading }, "refresh должен завершиться")

        XCTAssertEqual(model.interfaces[0].displayName, "home-vpn", "после rescan имя должно резолвиться")
        XCTAssertEqual(namer.rescanCount, 1, "для неизвестного utun — ровно один rescan")
    }

    func testRefreshSingleRescanForMultipleUnknownTunnels() {
        let namer = MockTunnelNamer(namesDiscoveredOnRescan: ["utun9": "home-vpn", "utun10": "office-vpn"])
        let model = WireGuardStatusModel(
            commandRunner: StubCommandRunner(results: [
                .success(makeDump([
                    makeInterfaceDumpLine("utun9"),
                    makePeerDumpLine(interfaceName: "utun9", handshakeSecondsAgo: 60),
                    makeInterfaceDumpLine("utun10"),
                    makePeerDumpLine(interfaceName: "utun10", key: "peer-b-pub-key=", handshakeSecondsAgo: nil),
                ])),
            ]),
            tunnelNamer: namer
        )

        model.refresh()
        waitUntil({ !model.isLoading }, "refresh должен завершиться")

        let displayNames = model.interfaces.map(\.displayName)
        XCTAssertEqual(displayNames, ["home-vpn", "office-vpn"])
        XCTAssertEqual(namer.rescanCount, 1, "rescan один за refresh, а не по одному на интерфейс")
    }

    func testRefreshForcedRescanPicksUpRenamedConfig() {
        let namer = MockTunnelNamer(knownNames: ["utun3": "old-name"], namesDiscoveredOnRescan: ["utun3": "work-vpn"])
        let model = WireGuardStatusModel(
            commandRunner: StubCommandRunner(results: [
                .success(makeDump([
                    makeInterfaceDumpLine("utun3"),
                    makePeerDumpLine(interfaceName: "utun3", handshakeSecondsAgo: 60),
                ])),
            ]),
            tunnelNamer: namer
        )

        model.refresh(forceNameRescan: true)
        waitUntil({ !model.isLoading }, "refresh должен завершиться")

        XCTAssertEqual(model.interfaces[0].displayName, "work-vpn", "принудительный rescan должен заменить закэшированное имя")
        XCTAssertEqual(namer.rescanCount, 1, "принудительный refresh — ровно один rescan")
    }

    func testRefreshForcedRescanStillUnknownStaysRaw() {
        let namer = MockTunnelNamer()
        let model = WireGuardStatusModel(
            commandRunner: StubCommandRunner(results: [
                .success(makeDump([
                    makeInterfaceDumpLine("utun9"),
                    makePeerDumpLine(interfaceName: "utun9", handshakeSecondsAgo: 60),
                ])),
            ]),
            tunnelNamer: namer
        )

        model.refresh(forceNameRescan: true)
        waitUntil({ !model.isLoading }, "refresh должен завершиться")

        XCTAssertEqual(model.interfaces[0].displayName, "utun9", "незнакомый utun — fallback на сырое имя")
        XCTAssertEqual(namer.rescanCount, 1, "после принудительного rescan повторного быть не должно")
    }

    func testRefreshKeepsLastGoodDataOnError() {
        let model = WireGuardStatusModel(
            commandRunner: StubCommandRunner(results: [
                .success(makeDump([
                    makeInterfaceDumpLine("utun3"),
                    makePeerDumpLine(interfaceName: "utun3", handshakeSecondsAgo: 60),
                ])),
                .failure(NSError(domain: "WGStatusBarTests", code: 1)),
                .success(makeDump([
                    makeInterfaceDumpLine("utun7"),
                    makePeerDumpLine(interfaceName: "utun7", handshakeSecondsAgo: 60),
                ])),
            ]),
            tunnelNamer: MockTunnelNamer(knownNames: ["utun3": "work-vpn", "utun7": "home-vpn"])
        )

        model.refresh()
        waitUntil({ !model.isLoading }, "первый refresh должен завершиться")
        XCTAssertEqual(model.interfaces.count, 1)
        XCTAssertEqual(model.interfaces[0].name, "utun3")

        model.refresh()
        waitUntil({ !model.isLoading && model.lastError != nil }, "ошибочный refresh должен завершиться с lastError")

        XCTAssertNotNil(model.lastError, "ошибка команды должна попасть в lastError")
        XCTAssertEqual(model.interfaces.count, 1, "данные последнего успешного тика должны остаться")
        XCTAssertEqual(model.interfaces[0].displayName, "work-vpn")

        model.refresh()
        waitUntil({ !model.isLoading && model.lastError == nil }, "успешный refresh после ошибки должен завершиться")

        XCTAssertNil(model.lastError, "lastError живёт один цикл refresh")
        XCTAssertEqual(model.interfaces[0].name, "utun7", "успешный тик должен обновить данные")
    }

    // MARK: - Гигиена ключей после удаления StatusMenuView

    /// Ключи, которые использовал только удалённый `StatusMenuView` (и ключи
    /// удалённой на ревью сводной строки `statusText`), не должны оставаться
    /// в таблицах — иначе таблицы копят мёртвые строки.
    func testRemovedStatusMenuViewKeysAreGoneFromBothLocalizations() throws {
        let removedKeys = [
            "app.title", "state.connected", "state.disconnected",
            "peers.not_found", "peer.handshake", "peer.handshake_unknown",
            "status.no_active_connections", "status.all_connected", "status.connected_count",
        ]

        for language in ["en", "ru"] {
            let lprojPath = try XCTUnwrap(
                Bundle.module.path(forResource: language, ofType: "lproj"),
                "нет \(language).lproj в бандле модуля"
            )
            let bundle = Bundle(path: lprojPath)
            for key in removedKeys {
                // localizedString(forKey:value:) при отсутствии ключа возвращает value
                let raw = bundle?.localizedString(forKey: key, value: key, table: "Localizable")
                XCTAssertEqual(raw, key, "мёртвый ключ \(key) должен быть удалён из \(language)")
            }
        }
    }
}

/// Стаб-раннер команды с запрограммированной очередью результатов.
private final class StubCommandRunner: WGShowCommandRunning {
    private let lock = NSLock()
    private var results: [Result<String, Error>]

    init(results: [Result<String, Error>]) {
        self.results = results
    }

    func runDump() async throws -> String {
        lock.lock()
        let result = results.isEmpty ? .success("") : results.removeFirst()
        lock.unlock()

        switch result {
        case .success(let output):
            return output
        case .failure(let error):
            throw error
        }
    }
}

/// Мок-namer со счётчиком rescan'ов; на rescan «обнаруживает» новые имена.
private final class MockTunnelNamer: WireGuardTunnelNaming {
    private let lock = NSLock()
    private var knownNames: [String: String]
    private let namesDiscoveredOnRescan: [String: String]
    private var rescanCountStorage = 0

    init(knownNames: [String: String] = [:], namesDiscoveredOnRescan: [String: String] = [:]) {
        self.knownNames = knownNames
        self.namesDiscoveredOnRescan = namesDiscoveredOnRescan
    }

    var rescanCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return rescanCountStorage
    }

    func displayName(for interfaceName: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return knownNames[interfaceName] ?? interfaceName
    }

    func rescan() {
        lock.lock()
        defer { lock.unlock() }
        rescanCountStorage += 1
        for (interfaceName, name) in namesDiscoveredOnRescan {
            knownNames[interfaceName] = name
        }
    }
}
