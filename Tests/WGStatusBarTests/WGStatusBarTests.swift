import XCTest
@testable import WGStatusBarCore

final class WGStatusBarTests: XCTestCase {
    // MARK: - Фикстуры

    /// Хендшейк 60 с назад — свежий (порог green 120 с), с запасом от границы.
    func makeActiveHandshake() -> Date {
        Date(timeIntervalSinceNow: -60)
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

    /// Модель после одного успешного тика с заданным дампом: `lastSuccessAt`
    /// поставлен успехом, снапшот живой — тайтл «on» честен. Часы — фейковые
    /// и замороженные: снапшот не устаревает, даже если прогон между refresh
    /// и ассертом затянется (отладчик, пауза машины). Голая инъекция
    /// `init(testing:)` для «on» больше не годится: без успешного тика данные
    /// устаревшие (`lastSuccessAt == nil`) и тайтл был бы «off».
    func makeRefreshedModel(dump: String) -> WireGuardStatusModel {
        let clock = FakeClock()
        let model = WireGuardStatusModel(
            commandRunner: StubCommandRunner(results: [.success(dump)]),
            tunnelNamer: MockTunnelNamer(),
            socketExists: { false },
            socketPath: helperSocketPath,
            now: { clock.current }
        )
        model.refresh()
        waitUntil({ !model.isLoading }, "refresh должен завершиться")
        return model
    }

    func testMenuTitleWhenActiveAndInactive() {
        // Подключённый кейс — через успешный refresh (тайтл читает свежесть
        // снапшота); «off»-кейсы честны при любом пути — не подключён.
        let connectedModel = makeRefreshedModel(dump: makeConnectedDump(interfaceName: "wg0"))
        let disconnectedModel = WireGuardStatusModel(testing: [makeInterface("wg0", peers: [makeNeverPeer("peer-b")])])
        let emptyModel = WireGuardStatusModel(testing: [])

        XCTAssertEqual(connectedModel.menuTitle, L10n.string("menu.title.on"))
        XCTAssertEqual(disconnectedModel.menuTitle, L10n.string("menu.title.off"))
        XCTAssertEqual(emptyModel.menuTitle, L10n.string("menu.title.off"))

        XCTAssertTrue(connectedModel.isAnyConnected)
        XCTAssertFalse(disconnectedModel.isAnyConnected)
        XCTAssertFalse(emptyModel.isAnyConnected)
    }

    /// Aging-хендшейк (−5 мин, с запасом от порога 10 мин) — всё ещё
    /// «подключён»: green|orange дают active. Живой снапшот — через refresh.
    func testAgingHandshakeStillCountsAsConnected() {
        let allAging = makeRefreshedModel(dump: makeDump([
            makeInterfaceDumpLine("wg0"),
            makePeerDumpLine(interfaceName: "wg0", handshakeSecondsAgo: 5 * 60),
        ]))

        XCTAssertEqual(allAging.menuTitle, L10n.string("menu.title.on"))

        let partlyAging = makeRefreshedModel(dump: makeDump([
            makeInterfaceDumpLine("wg0"),
            makePeerDumpLine(interfaceName: "wg0", handshakeSecondsAgo: 5 * 60),
            makeInterfaceDumpLine("wg1"),
            makePeerDumpLine(interfaceName: "wg1", key: "peer-b-pub-key=", handshakeSecondsAgo: nil),
        ]))

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
        // Чужая (не StatusFailure) ошибка раннера заворачивается в .generic с её текстом.
        if case .generic = model.lastFailure {} else {
            XCTFail("чужая ошибка раннера должна заворачиваться в .generic, получили \(String(describing: model.lastFailure))")
        }
        XCTAssertEqual(model.interfaces.count, 1, "данные последнего успешного тика должны остаться")
        XCTAssertEqual(model.interfaces[0].displayName, "work-vpn")

        model.refresh()
        waitUntil({ !model.isLoading && model.lastError == nil }, "успешный refresh после ошибки должен завершиться")

        XCTAssertNil(model.lastError, "lastError живёт один цикл refresh")
        XCTAssertEqual(model.interfaces[0].name, "utun7", "успешный тик должен обновить данные")
    }

    // MARK: - Модель: мост типизированной ошибки в строку карточки

    func testRefreshTypedFailureBridgesToLastErrorString() {
        let model = WireGuardStatusModel(
            commandRunner: StubCommandRunner(results: [
                .failure(StatusFailure.wgMissing),
                .failure(StatusFailure.daemonOutdated),
            ]),
            tunnelNamer: MockTunnelNamer()
        )

        model.refresh()
        waitUntil({ !model.isLoading && model.lastFailure != nil }, "refresh с типизированной ошибкой должен завершиться")

        XCTAssertEqual(model.lastFailure, .wgMissing, "StatusFailure от раннера проходит в модель как есть")
        XCTAssertEqual(model.lastError, L10n.string("error.wg_missing"), "карточка получает локализованную строку из lastFailure")

        model.refresh()
        waitUntil({ model.lastFailure == .daemonOutdated }, "второй refresh должен опубликовать daemonOutdated")

        XCTAssertEqual(model.lastError, L10n.string("error.daemon_outdated"))
    }

    // MARK: - Модель: грейс-устарелость снапшота

    /// Модель с фейковыми часами (probe сокета всегда false — раннер инжектирован,
    /// как в остальных refresh-тестах).
    func makeClockModel(clock: FakeClock, results: [Result<String, Error>]) -> WireGuardStatusModel {
        WireGuardStatusModel(
            commandRunner: StubCommandRunner(results: results),
            tunnelNamer: MockTunnelNamer(),
            socketExists: { false },
            socketPath: helperSocketPath,
            now: { clock.current }
        )
    }

    /// Дамп одного подключённого интерфейса (хендшейк 60 с назад — fresh).
    func makeConnectedDump(interfaceName: String) -> String {
        makeDump([
            makeInterfaceDumpLine(interfaceName),
            makePeerDumpLine(interfaceName: interfaceName, handshakeSecondsAgo: 60),
        ])
    }

    /// Успешный тик ставит маркер успеха: данные свежие, иконка честная.
    func testSuccessTickKeepsSnapshotFresh() {
        let clock = FakeClock()
        let model = makeClockModel(
            clock: clock,
            results: [.success(makeConnectedDump(interfaceName: "utun3"))]
        )

        model.refresh()
        waitUntil({ !model.isLoading }, "refresh должен завершиться")

        XCTAssertFalse(model.isDataStale, "успешный тик — снапшот свежий")
        XCTAssertEqual(model.showsConnected, model.isAnyConnected, "на живых данных showsConnected совпадает с isAnyConnected")
        XCTAssertTrue(model.showsConnected, "fresh-хендшейк + свежий снапшот — подключён")
    }

    /// Неудача в пределах грейса (5 c < лимита 10 c) — мигания иконки нет.
    func testFailureWithinGraceKeepsSnapshotFresh() {
        let clock = FakeClock()
        let model = makeClockModel(clock: clock, results: [
            .success(makeConnectedDump(interfaceName: "utun3")),
            .failure(StatusFailure.connectionRefused),
        ])

        model.refresh()
        waitUntil({ !model.isLoading }, "успешный refresh должен завершиться")

        clock.current = clock.current.addingTimeInterval(5)
        model.refresh()
        waitUntil({ !model.isLoading && model.lastFailure != nil }, "ошибочный refresh должен завершиться")

        XCTAssertFalse(model.isDataStale, "одиночный сбой в грейсе не устаревает данные")
        XCTAssertTrue(model.showsConnected, "иконка не мигает на однократный сбой")
        XCTAssertEqual(model.interfaces.count, 1, "данные последнего успеха остаются")
    }

    /// Неудача за грейсом (11 c > лимита 10 c) — снапшот устарел, иконка гаснет,
    /// данные в модели не очищаются.
    func testFailureBeyondGraceMarksSnapshotStale() {
        let clock = FakeClock()
        let model = makeClockModel(clock: clock, results: [
            .success(makeConnectedDump(interfaceName: "utun3")),
            .failure(StatusFailure.connectionRefused),
        ])

        model.refresh()
        waitUntil({ !model.isLoading }, "успешный refresh должен завершиться")

        clock.current = clock.current.addingTimeInterval(11)
        model.refresh()
        waitUntil({ !model.isLoading && model.lastFailure != nil }, "ошибочный refresh должен завершиться")

        XCTAssertTrue(model.isDataStale, "за грейсом снапшот устаревает")
        XCTAssertFalse(model.showsConnected, "устаревший снапшот не кормит иконку")
        XCTAssertTrue(model.isAnyConnected, "правда по данным остаётся подключённой")
        XCTAssertEqual(model.interfaces.count, 1, "interfaces не очищаются")
        XCTAssertEqual(model.interfaces[0].peers.count, 1, "пиры остаются на месте")
    }

    /// Успех после устаревания оживает снапшот на первом же тике.
    func testSuccessAfterStalenessRevivesSnapshot() {
        let clock = FakeClock()
        let model = makeClockModel(clock: clock, results: [
            .success(makeConnectedDump(interfaceName: "utun3")),
            .failure(StatusFailure.connectionRefused),
            .success(makeConnectedDump(interfaceName: "utun3")),
        ])

        model.refresh()
        waitUntil({ !model.isLoading }, "успешный refresh должен завершиться")
        clock.current = clock.current.addingTimeInterval(11)
        model.refresh()
        waitUntil({ !model.isLoading && model.lastFailure != nil }, "ошибочный refresh должен завершиться")
        XCTAssertTrue(model.isDataStale, "предусловие: снапшот устарел")

        model.refresh()
        waitUntil({ !model.isLoading && model.lastError == nil }, "восстанавливающий refresh должен завершиться")

        XCTAssertFalse(model.isDataStale, "успешный тик снимает устарелость")
        XCTAssertTrue(model.showsConnected, "иконка оживает на первом успешном тике")
    }

    /// Пустые `interfaces` — не устаревшие (нечему устаревать).
    func testEmptyInterfacesAreNeverStale() {
        let model = WireGuardStatusModel(testing: [])

        XCTAssertFalse(model.isDataStale, "пустые данные не помечаются устаревшими")
        XCTAssertFalse(model.showsConnected)
    }

    /// Данные, инъектированные минуя успешный тик (`lastSuccessAt == nil`),
    /// считаются устаревшими: иконка их не показывает.
    func testInjectedInterfacesWithoutSuccessAreStale() {
        let model = WireGuardStatusModel(testing: [makeInterface("wg0", peers: [makeActivePeer("peer-a")])])

        XCTAssertTrue(model.isDataStale, "данные без маркера успеха — устаревшие")
        XCTAssertTrue(model.isAnyConnected, "правда по данным остаётся подключённой")
        XCTAssertFalse(model.showsConnected, "непроверенный снапшот не кормит иконку")
    }

    /// Тайтл VoiceOver следует устарелости вместе с иконкой: живой снапшот
    /// подключённого интерфейса — «on», замороженный за грейсом — «off».
    func testMenuTitleFollowsSnapshotStaleness() {
        let clock = FakeClock()
        let model = makeClockModel(
            clock: clock,
            results: [
                .success(makeConnectedDump(interfaceName: "utun3")),
                .failure(StatusFailure.connectionRefused),
            ]
        )

        model.refresh()
        waitUntil({ !model.isLoading }, "успешный refresh должен завершиться")

        XCTAssertEqual(model.menuTitle, L10n.string("menu.title.on"), "живые данные — «on»")

        clock.current = clock.current.addingTimeInterval(11)
        model.refresh()
        waitUntil({ !model.isLoading && model.lastFailure != nil }, "ошибочный refresh должен завершиться")

        XCTAssertTrue(model.isAnyConnected, "предусловие: в данных интерфейс всё ещё подключён")
        XCTAssertEqual(model.menuTitle, L10n.string("menu.title.off"), "устаревший снапшот гасит тайтл")
    }

    /// Иконка бара питается тем же решением: контроллер читает свежесть
    /// снапшота (`iconConnected` → `showsConnected`), а не только данные.
    func testStatusIconFollowsSnapshotStaleness() {
        let clock = FakeClock()
        let model = makeClockModel(
            clock: clock,
            results: [
                .success(makeConnectedDump(interfaceName: "utun3")),
                .failure(StatusFailure.connectionRefused),
            ]
        )

        model.refresh()
        waitUntil({ !model.isLoading }, "успешный refresh должен завершиться")
        XCTAssertTrue(StatusItemController.iconConnected(for: model), "живой снапшот — иконка «on»")

        clock.current = clock.current.addingTimeInterval(11)
        model.refresh()
        waitUntil({ !model.isLoading && model.lastFailure != nil }, "ошибочный refresh должен завершиться")

        XCTAssertFalse(StatusItemController.iconConnected(for: model), "устаревший снапшот — иконка гаснет")
    }

    /// Граница грейса не включается: elapsed ровно `stalenessLimit` (10 c) —
    /// данные ещё свежие (устарелость строго больше лимита).
    func testGraceBoundaryIsExclusive() {
        let clock = FakeClock()
        let model = makeClockModel(
            clock: clock,
            results: [
                .success(makeConnectedDump(interfaceName: "utun3")),
                .failure(StatusFailure.connectionRefused),
            ]
        )

        model.refresh()
        waitUntil({ !model.isLoading }, "успешный refresh должен завершиться")

        clock.current = clock.current.addingTimeInterval(10)
        model.refresh()
        waitUntil({ !model.isLoading && model.lastFailure != nil }, "ошибочный refresh должен завершиться")

        XCTAssertFalse(model.isDataStale, "elapsed == лимита — ещё свежо, граница не включается")
    }

    // MARK: - Модель: probe сокета и состояние сервиса

    /// Легаси-перегрузка `init(commandRunner:tunnelNamer:)` держит probe сокета
    /// всегда false — все существующие refresh-тесты идут через инжектированный
    /// раннер, состояние сервиса остаётся absent (сокетного пути нет).
    func testLegacyInitUsesInjectedRunnerAndStaysAbsent() {
        let model = WireGuardStatusModel(
            commandRunner: StubCommandRunner(results: [
                .success(makeDump([
                    makeInterfaceDumpLine("utun3"),
                    makePeerDumpLine(interfaceName: "utun3", handshakeSecondsAgo: 60),
                ])),
            ]),
            tunnelNamer: MockTunnelNamer()
        )

        XCTAssertEqual(model.serviceState, .absent, "до первого тика состояние — absent")
        model.refresh()
        waitUntil({ !model.isLoading }, "refresh должен завершиться")

        XCTAssertEqual(model.interfaces[0].name, "utun3", "дамп приходит от инжектированного раннера")
        XCTAssertEqual(model.serviceState, .absent, "без сокета состояние сервиса — absent")
    }

    // MARK: - Модель: ошибка установки сервиса в карточку

    func testReportServiceFailureSurfacesGenericErrorForOneTick() {
        // Единственный канал ошибок установки в карточку (stderr скрипта или
        // сбой osascript): текст — в lastFailure/lastError, следующий refresh
        // сотрёт (модель тестируется без таймера и тика).
        let model = WireGuardStatusModel(testing: [])

        model.reportServiceFailure("boom")

        XCTAssertEqual(model.lastFailure, .generic("boom"))
        XCTAssertEqual(model.lastError, "boom")
    }

    // MARK: - Модель: туннели (list/up/down)

    /// Реальный DaemonServer на tmp-сокете — единственный способ довести
    /// модель до `serviceState == .installed` (состояние выводится из факта
    /// живого обмена, не хранится). Туннельный клиент модели — мок: list/up/down
    /// до демона не доходят, спавна процессов нет.
    private var daemonSocketPaths: [String] = []
    private var daemonServerTasks: [Task<Void, Error>] = []

    override func tearDown() {
        for task in daemonServerTasks {
            task.cancel()
        }
        for path in daemonSocketPaths {
            try? FileManager.default.removeItem(atPath: path)
        }
        daemonSocketPaths.removeAll()
        daemonServerTasks.removeAll()
        super.tearDown()
    }

    /// Модель + поднятый DaemonServer со стабильным show-исполнителем и моком
    /// туннельного клиента; на выходе модель уже в `.installed` с одним
    /// отработанным тиком.
    private func makeInstalledModel(
        showExecutor: WGShowExecuting,
        tunnelNamer: WireGuardTunnelNaming,
        tunnelClient: TunnelCommandRunning
    ) -> WireGuardStatusModel {
        // sun_path вмещает ~103 байта — короткий /tmp-путь с усечённым UUID.
        let socketPath = "/tmp/wgstatusbar-modeltests-"
            + UUID().uuidString.prefix(8)
            + ".sock"
        daemonSocketPaths.append(socketPath)
        let server = DaemonServer(executor: showExecutor, socketPath: socketPath)
        daemonServerTasks.append(Task.detached { try await server.run() })
        waitDaemonListening(socketPath: socketPath)

        let model = WireGuardStatusModel(
            commandRunner: StubCommandRunner(results: []),
            tunnelNamer: tunnelNamer,
            socketExists: { FileManager.default.fileExists(atPath: socketPath) },
            socketPath: socketPath,
            tunnelCommandRunner: tunnelClient
        )
        model.refresh()
        waitUntil({ model.serviceState == .installed }, "живой демон должен довести модель до installed")
        return model
    }

    /// Ждёт настоящего listen-состояния: файл сокета появляется на bind —
    /// раньше listen, и connect в этом окне ловит ECONNREFUSED (флейк).
    private func waitDaemonListening(socketPath: String, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            if fd >= 0 {
                let connected = withUnixSocketAddress(path: socketPath) { address, length in
                    connect(fd, address, length)
                }
                close(fd)
                if connected == 0 { return }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("демон не начал слушать \(socketPath) за \(timeout) с")
    }

    /// Прокручивает main run loop — даёт фоновым задачам модели шанс
    /// выполниться (для ассертов «ничего не произошло»).
    private func spinRunLoop(_ seconds: TimeInterval = 0.1) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// Дамп для show-исполнителя демона: wire-протокол требует терминированный
    /// payload (реальный `wg show` завершает вывод переводом строки; пустой
    /// дамп — валиден как есть).
    private func makeWireDump(_ dump: String) -> String {
        dump.isEmpty ? dump : dump + "\n"
    }

    /// Happy path: поднятый туннель уходит в down (направление — из
    /// displayName-снапшота), имя стоит в inFlight ровно на время операции,
    /// успех делает немедленный refresh — isUp переворачивается.
    func testToggleTunnelTearsDownAndClearsInFlightOnSuccess() {
        let clock = FakeClock()
        let client = MockTunnelClient()
        client.configure(gate: true)
        let model = WireGuardStatusModel(
            commandRunner: StubCommandRunner(results: [
                .success(makeConnectedDump(interfaceName: "utun3")),
                .success(""),  // после down: интерфейсов в дампе нет
            ]),
            tunnelNamer: MockTunnelNamer(knownNames: ["utun3": "kvmka-ai"]),
            socketExists: { false },
            socketPath: helperSocketPath,
            now: { clock.current },
            tunnelCommandRunner: client
        )
        model.refresh()
        waitUntil({ !model.isLoading }, "первый refresh должен завершиться")
        XCTAssertTrue(model.isTunnelUp(named: "kvmka-ai"), "предусловие: displayName резолвится в имя туннеля")

        model.toggleTunnel(named: "kvmka-ai")
        waitUntil({ !client.downCalls.isEmpty }, "поднятый туннель должен уйти в down")
        XCTAssertEqual(model.inFlightTunnels, ["kvmka-ai"], "операция в полёте: имя в inFlightTunnels")

        client.releaseGate()
        waitUntil(
            { model.inFlightTunnels.isEmpty && !model.isLoading },
            "успех обязан снять имя с inFlight и сделать немедленный refresh"
        )

        XCTAssertFalse(model.isTunnelUp(named: "kvmka-ai"), "успешный down + refresh переворачивают isUp")
        XCTAssertNil(model.lastFailure)
    }

    /// Опущенный туннель уходит в up: направление выводится из снапшота
    /// (интерфейса с таким displayName нет).
    func testToggleTunnelBringsUpWhenSnapshotHasNoInterface() {
        let client = MockTunnelClient()
        let model = WireGuardStatusModel(
            commandRunner: StubCommandRunner(results: [.success("")]),
            tunnelNamer: MockTunnelNamer(),
            socketExists: { false },
            socketPath: helperSocketPath,
            tunnelCommandRunner: client
        )
        model.refresh()
        waitUntil({ !model.isLoading }, "refresh должен завершиться")

        model.toggleTunnel(named: "kvmka-full")

        waitUntil({ !client.upCalls.isEmpty }, "опущенный туннель должен уйти в up")
        XCTAssertTrue(client.downCalls.isEmpty, "down не должен вызываться")
        waitUntil({ model.inFlightTunnels.isEmpty }, "операция должна завершиться и снять имя")
    }

    /// In-flight операция глушит show-тик: refresh не запускается вовсе — без
    /// ошибки, без смены serviceState, раннер не дёргается; снапшот не
    /// устаревает, даже когда операция пережила stalenessLimit.
    func testInFlightTunnelSuppressesShowTick() {
        let clock = FakeClock()
        let client = MockTunnelClient()
        client.configure(gate: true)
        let runner = StubCommandRunner(results: [
            .success(makeConnectedDump(interfaceName: "utun3")),
            .success(""),  // должен быть израсходован только после конца операции
        ])
        let model = WireGuardStatusModel(
            commandRunner: runner,
            tunnelNamer: MockTunnelNamer(knownNames: ["utun3": "kvmka-ai"]),
            socketExists: { false },
            socketPath: helperSocketPath,
            now: { clock.current },
            tunnelCommandRunner: client
        )
        model.refresh()
        waitUntil({ !model.isLoading }, "первый refresh должен завершиться")
        XCTAssertEqual(runner.consumedCount, 1)

        model.toggleTunnel(named: "kvmka-ai")
        waitUntil({ !client.downCalls.isEmpty }, "операция должна стартовать")

        model.refresh()  // тик таймера (или ⌘R) посреди операции
        XCTAssertFalse(model.isLoading, "подавленный тик не должен ставить isLoading")
        XCTAssertNil(model.lastFailure, "подавленный тик не должен трогать lastFailure")
        XCTAssertEqual(model.serviceState, .absent, "подавленный тик не должен менять serviceState")
        XCTAssertEqual(runner.consumedCount, 1, "раннер не должен дёргаться во время операции")

        // Худший случай очереди демона (13 c) переживает stalenessLimit
        // (10 c): пока операция жива, снапшот не приглушается.
        clock.current = clock.current.addingTimeInterval(11)
        XCTAssertFalse(model.isDataStale, "в полёте снапшот не устаревает")
        XCTAssertTrue(model.showsConnected, "иконка не гаснет посреди живой операции")

        client.releaseGate()
        waitUntil(
            { runner.consumedCount == 2 && !model.isLoading },
            "после успеха должен пройти немедленный refresh"
        )
        XCTAssertFalse(model.isDataStale, "успешный тик снимает устарелость")
    }

    /// Провал операции: one-tick lastFailure (локализованное сообщение), имя
    /// снято с inFlight, refresh НЕ зовётся (пролог refresh стирает
    /// lastFailure — ошибка не отрисовалась бы), туннели не чистятся.
    func testToggleTunnelFailureSurfacesErrorWithoutRefresh() {
        let showExecutor = CountingShowExecutor(dump: makeWireDump(makeConnectedDump(interfaceName: "utun3")))
        let client = MockTunnelClient()
        client.configure(
            listResults: [
                .success(["kvmka-ai"]),
                .failure(StatusFailure.connectionRefused),  // list после провала тоже падает — глотается
            ],
            opResults: [.failure(StatusFailure.generic(L10n.string("error.tunnel_op_failed")))],
            gate: true
        )
        let model = makeInstalledModel(
            showExecutor: showExecutor,
            tunnelNamer: MockTunnelNamer(knownNames: ["utun3": "kvmka-ai"]),
            tunnelClient: client
        )
        model.loadTunnels()
        waitUntil({ model.tunnels == [TunnelInfo(name: "kvmka-ai", isUp: true)] }, "list должен заполнить tunnels")
        let showCallsAfterSetup = showExecutor.calls

        model.toggleTunnel(named: "kvmka-ai")
        waitUntil({ !client.downCalls.isEmpty }, "поднятый туннель должен уйти в down")
        client.releaseGate()
        waitUntil(
            { model.inFlightTunnels.isEmpty && model.lastFailure != nil },
            "провал обязан снять имя с inFlight и поставить lastFailure"
        )

        XCTAssertEqual(model.lastError, L10n.string("error.tunnel_op_failed"), "карточка получает локализованное сообщение")
        XCTAssertEqual(model.tunnels, [TunnelInfo(name: "kvmka-ai", isUp: true)], "провал не чистит tunnels")
        XCTAssertEqual(showExecutor.calls, showCallsAfterSetup, "провал не зовёт refresh — иначе он сотрёт lastFailure")
        XCTAssertFalse(model.isLoading)
    }

    /// list маппится в tunnels, isUp выводится из displayName-снапшота
    /// (единственный источник правды — wg show, демон состояние не хранит).
    func testLoadTunnelsMapsNamesAndDerivesIsUpFromDisplayName() {
        let showExecutor = CountingShowExecutor(dump: makeWireDump(makeConnectedDump(interfaceName: "utun3")))
        let client = MockTunnelClient()
        client.configure(listResults: [.success(["kvmka-ai", "kvmka-full"])])
        let model = makeInstalledModel(
            showExecutor: showExecutor,
            tunnelNamer: MockTunnelNamer(knownNames: ["utun3": "kvmka-ai"]),
            tunnelClient: client
        )
        XCTAssertEqual(model.interfaces.first?.displayName, "kvmka-ai", "предусловие: namer резолвит utun в имя конфига")

        model.loadTunnels()
        waitUntil({ model.tunnels.count == 2 }, "list должен заполнить tunnels")

        XCTAssertEqual(model.tunnels, [
            TunnelInfo(name: "kvmka-ai", isUp: true),
            TunnelInfo(name: "kvmka-full", isUp: false),
        ], "isUp выводится из displayName интерфейсов, а не хранится демоном")
    }

    /// isUp пересчитывается при каждом обновлении interfaces: новый тик с
    /// поднятым интерфейсом переворачивает строку без нового запроса list.
    func testTunnelIsUpFollowsInterfaceSnapshotUpdates() {
        let showExecutor = CountingShowExecutor(dump: "")  // интерфейсов нет
        let client = MockTunnelClient()
        client.configure(listResults: [.success(["kvmka-ai"])])
        let model = makeInstalledModel(
            showExecutor: showExecutor,
            tunnelNamer: MockTunnelNamer(knownNames: ["utun3": "kvmka-ai"]),
            tunnelClient: client
        )
        model.loadTunnels()
        waitUntil({ model.tunnels == [TunnelInfo(name: "kvmka-ai", isUp: false)] }, "list должен заполнить tunnels")

        showExecutor.setDump(makeWireDump(makeConnectedDump(interfaceName: "utun3")))
        model.refresh()
        waitUntil({ model.interfaces.count == 1 }, "новый тик должен принести интерфейс")

        XCTAssertEqual(model.tunnels, [TunnelInfo(name: "kvmka-ai", isUp: true)], "успешный тик пересчитывает isUp строк")
        XCTAssertEqual(client.listCalls, 1, "пересчёт не должен требовать нового list")
    }

    /// Ошибки list глотаются: ни lastFailure, ни очистки tunnels — данные
    /// меню оппортунистические.
    func testLoadTunnelsSwallowsClientErrors() {
        let showExecutor = CountingShowExecutor(dump: makeWireDump(makeConnectedDump(interfaceName: "utun3")))
        let client = MockTunnelClient()
        client.configure(listResults: [
            .success(["kvmka-ai"]),
            .failure(StatusFailure.connectionRefused),
        ])
        let model = makeInstalledModel(
            showExecutor: showExecutor,
            tunnelNamer: MockTunnelNamer(knownNames: ["utun3": "kvmka-ai"]),
            tunnelClient: client
        )

        model.loadTunnels()
        waitUntil({ model.tunnels == [TunnelInfo(name: "kvmka-ai", isUp: true)] }, "первый list должен заполнить tunnels")

        model.loadTunnels()
        waitUntil({ client.listCalls == 2 }, "второй list должен быть отправлен")
        spinRunLoop()

        XCTAssertEqual(model.tunnels, [TunnelInfo(name: "kvmka-ai", isUp: true)], "ошибка list не чистит tunnels")
        XCTAssertNil(model.lastFailure, "ошибка list не попадает в карточку")
    }

    /// До `.installed` loadTunnels не дёргает клиента вовсе: у старого демона
    /// list — unknown command, секции быть не должно.
    func testLoadTunnelsSkipsClientWhenServiceNotInstalled() {
        let client = MockTunnelClient()
        let model = WireGuardStatusModel(
            commandRunner: StubCommandRunner(results: [.success(makeConnectedDump(interfaceName: "utun3"))]),
            tunnelNamer: MockTunnelNamer(),
            socketExists: { false },
            socketPath: helperSocketPath,
            tunnelCommandRunner: client
        )

        model.loadTunnels()
        spinRunLoop()
        XCTAssertEqual(client.listCalls, 0, "до первого тика list не отправляется")

        model.refresh()
        waitUntil({ !model.isLoading }, "refresh должен завершиться")
        XCTAssertEqual(model.serviceState, .absent, "предусловие: сокета нет — состояние absent")

        model.loadTunnels()
        spinRunLoop()
        XCTAssertEqual(client.listCalls, 0, "в absent-состоянии list не отправляется")
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

/// Фейковые часы: мутабельное «сейчас», тесты устарелости сдвигают его без ожидания.
final class FakeClock {
    var current: Date

    init(start: Date = Date()) {
        current = start
    }
}

/// Стаб-раннер команды с запрограммированной очередью результатов.
private final class StubCommandRunner: WGShowCommandRunning {
    private let lock = NSLock()
    private var results: [Result<String, Error>]
    private var consumedCountStorage = 0

    init(results: [Result<String, Error>]) {
        self.results = results
    }

    /// Сколько результатов израсходовано — ассерт «подавленный тик не дёргает
    /// раннер».
    var consumedCount: Int {
        lock.withLock { consumedCountStorage }
    }

    func runDump() async throws -> String {
        let result: Result<String, Error> = lock.withLock {
            consumedCountStorage += 1
            return results.isEmpty ? .success("") : results.removeFirst()
        }

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

/// Мок туннельного клиента: программируемые очереди результатов, журнал
/// вызовов и «клапан» — операция висит, пока тест её не отпустит
/// (наблюдение in-flight-состояния модели без гонок).
private final class MockTunnelClient: TunnelCommandRunning {
    private let lock = NSLock()
    private var listResults: [Result<[String], Error>] = []
    private var opResults: [Result<Void, Error>] = []
    private var gated = false
    private var gateContinuation: CheckedContinuation<Void, Never>?
    private var listCallsStorage = 0
    private var upCallsStorage: [String] = []
    private var downCallsStorage: [String] = []

    func configure(
        listResults: [Result<[String], Error>] = [],
        opResults: [Result<Void, Error>] = [],
        gate: Bool = false
    ) {
        lock.withLock {
            self.listResults = listResults
            self.opResults = opResults
            self.gated = gate
        }
    }

    var listCalls: Int { lock.withLock { listCallsStorage } }
    var upCalls: [String] { lock.withLock { upCallsStorage } }
    var downCalls: [String] { lock.withLock { downCallsStorage } }

    /// Отпускает зависшую на клапане операцию.
    func releaseGate() {
        lock.withLock {
            gateContinuation?.resume()
            gateContinuation = nil
        }
    }

    func list() async throws -> [String] {
        let result: Result<[String], Error> = lock.withLock {
            listCallsStorage += 1
            return listResults.isEmpty ? .success([]) : listResults.removeFirst()
        }
        switch result {
        case .success(let names):
            return names
        case .failure(let error):
            throw error
        }
    }

    func up(_ name: String) async throws {
        let result: Result<Void, Error> = lock.withLock {
            upCallsStorage.append(name)
            return opResults.isEmpty ? .success(()) : opResults.removeFirst()
        }
        await waitOnGate()
        if case .failure(let error) = result {
            throw error
        }
    }

    func down(_ name: String) async throws {
        let result: Result<Void, Error> = lock.withLock {
            downCallsStorage.append(name)
            return opResults.isEmpty ? .success(()) : opResults.removeFirst()
        }
        await waitOnGate()
        if case .failure(let error) = result {
            throw error
        }
    }

    /// Клапан для up/down: когда активен, первая операция висит до
    /// `releaseGate()` (одна операция за раз — параллельных вызовов модель
    /// не порождает); `list` клапан не трогает — гейтится только наблюдаемая
    /// операция toggle.
    private func waitOnGate() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock {
                if gated, gateContinuation == nil {
                    gateContinuation = continuation
                    return false
                }
                return true
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }
}

/// Стаб show-исполнителя для реального DaemonServer в тестах модели:
/// настраиваемый дамп + счётчик вызовов (ассерт «провал операции не зовёт
/// refresh»: show-тик идёт через демон, раннер модели не при делах).
private final class CountingShowExecutor: WGShowExecuting {
    private let lock = NSLock()
    private var dumpStorage: String
    private var callsStorage = 0

    init(dump: String) {
        self.dumpStorage = dump
    }

    var calls: Int { lock.withLock { callsStorage } }

    func setDump(_ dump: String) {
        lock.withLock { dumpStorage = dump }
    }

    func runDump() async throws -> String {
        lock.withLock {
            callsStorage += 1
            return dumpStorage
        }
    }
}
