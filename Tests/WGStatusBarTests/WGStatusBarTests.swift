import Combine
import XCTest
@testable import WGStatusBarCore

final class WGStatusBarTests: XCTestCase {
    // MARK: - Фикстуры

    /// Хендшейк 60 с назад — свежий (порог green 120 с), с запасом от границы.
    func makeActiveHandshake() -> Date {
        Date(timeIntervalSinceNow: -60)
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

    // MARK: - Модель: menuTitle и showsTunnelUp

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
        // Поднятый туннель — через успешный refresh (тайтл читает свежесть
        // снапшота); «off»-кейсы честны при любом пути.
        let tunnelUpModel = makeRefreshedModel(dump: makeConnectedDump(interfaceName: "wg0"))
        let unverifiedModel = WireGuardStatusModel(testing: [makeInterface("wg0", peers: [makeNeverPeer("peer-b")])])
        let emptyModel = WireGuardStatusModel(testing: [])

        XCTAssertEqual(tunnelUpModel.menuTitle, L10n.string("menu.title.on"))
        XCTAssertEqual(unverifiedModel.menuTitle, L10n.string("menu.title.off"), "снапшот без успешного тика не озвучивается как «on»")
        XCTAssertEqual(emptyModel.menuTitle, L10n.string("menu.title.off"), "пустой дамп — туннелей нет")
    }

    /// Регрессия исходной жалобы: туннель поднят, но трафика нет — все
    /// хендшейки stale или never. Щиток всё равно горит: иконка — факт
    /// туннеля, свежесть хендшейков живёт в карточке, а не в иконке.
    /// Живой снапшот — через refresh.
    func testTunnelUpWithStaleOrNeverHandshakesStillShowsUp() {
        let allStale = makeRefreshedModel(dump: makeDump([
            makeInterfaceDumpLine("wg0"),
            makePeerDumpLine(interfaceName: "wg0", handshakeSecondsAgo: 15 * 60),
        ]))

        XCTAssertEqual(allStale.menuTitle, L10n.string("menu.title.on"))

        let staleAndNever = makeRefreshedModel(dump: makeDump([
            makeInterfaceDumpLine("wg0"),
            makePeerDumpLine(interfaceName: "wg0", handshakeSecondsAgo: 15 * 60),
            makeInterfaceDumpLine("wg1"),
            makePeerDumpLine(interfaceName: "wg1", key: "peer-b-pub-key=", handshakeSecondsAgo: nil),
        ]))

        XCTAssertEqual(staleAndNever.menuTitle, L10n.string("menu.title.on"))
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
        XCTAssertEqual(model.menuTitle, L10n.string("menu.title.on"), "интерфейс в дампе + свежий снапшот — туннель поднят")
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

    /// Дамп одного поднятого интерфейса (хендшейк 60 с назад — fresh; для
    /// иконки достаточно наличия интерфейса, хендшейк — атрибут карточки).
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
        XCTAssertTrue(model.showsTunnelUp, "интерфейс в дампе + свежий снапшот — щиток горит")
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
        XCTAssertTrue(model.showsTunnelUp, "иконка не мигает на однократный сбой")
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
        XCTAssertFalse(model.showsTunnelUp, "устаревший снапшот не кормит иконку")
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
        XCTAssertTrue(model.showsTunnelUp, "иконка оживает на первом успешном тике")
    }

    /// Пустые `interfaces` — не устаревшие (нечему устаревать).
    func testEmptyInterfacesAreNeverStale() {
        let model = WireGuardStatusModel(testing: [])

        XCTAssertFalse(model.isDataStale, "пустые данные не помечаются устаревшими")
        XCTAssertFalse(model.showsTunnelUp, "пустой дамп — туннелей нет, щиток не горит")
    }

    /// Данные, инъектированные минуя успешный тик (`lastSuccessAt == nil`),
    /// считаются устаревшими: иконка их не показывает.
    func testInjectedInterfacesWithoutSuccessAreStale() {
        let model = WireGuardStatusModel(testing: [makeInterface("wg0", peers: [makeActivePeer("peer-a")])])

        XCTAssertTrue(model.isDataStale, "данные без маркера успеха — устаревшие")
        XCTAssertFalse(model.showsTunnelUp, "непроверенный снапшот не кормит иконку")
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

        XCTAssertFalse(model.interfaces.isEmpty, "предусловие: интерфейс остаётся в снапшоте")
        XCTAssertEqual(model.menuTitle, L10n.string("menu.title.off"), "устаревший снапшот гасит тайтл")
    }

    /// Иконка бара питается тем же решением: контроллер читает свежесть
    /// снапшота (`iconUp` → `showsTunnelUp`), а не только данные.
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
        XCTAssertTrue(StatusItemController.iconUp(for: model), "живой снапшот — иконка «on»")

        clock.current = clock.current.addingTimeInterval(11)
        model.refresh()
        waitUntil({ !model.isLoading && model.lastFailure != nil }, "ошибочный refresh должен завершиться")

        XCTAssertFalse(StatusItemController.iconUp(for: model), "устаревший снапшот — иконка гаснет")
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

    // MARK: - Модель: каталог конфигов (Open Configs ⌘O)

    /// Поддельная FS для выбора каталога конфигов (та же абстракция, что у
    /// `TunnelConfigStore`): множество «существующих» директорий + листинги.
    /// Отсутствующего ключа в `entriesByDirectory` хватает для листинга `nil`
    /// (каталог есть, но не читается).
    private final class ConfigFolderFileSystem: TunnelConfigFileSystem {
        var directories: Set<String> = []
        var entriesByDirectory: [String: [String]] = [:]

        func contentsOfDirectory(atPath path: String) -> [String]? {
            entriesByDirectory[path]
        }

        func isDirectory(atPath path: String) -> Bool {
            directories.contains(path)
        }
    }

    func testConfigFolderPrefersRootActuallyCarryingConfigs() {
        // Машина на Apple Silicon: пустой `/etc/wireguard` с более высоким
        // приоритетом не должен выигрывать у `/opt/homebrew/etc/wireguard`,
        // откуда меню берёт туннели.
        let fs = ConfigFolderFileSystem()
        fs.directories = ["/etc/wireguard", "/opt/homebrew/etc/wireguard"]
        fs.entriesByDirectory = ["/opt/homebrew/etc/wireguard": ["kvmka-ai.conf"]]

        let path = WireGuardStatusModel.configFolderPath(
            searchPaths: tunnelConfigSearchPaths,
            legacyFallback: "/Users/test/Library/Application Support/wireguard",
            fileSystem: fs
        )

        XCTAssertEqual(path, "/opt/homebrew/etc/wireguard")
    }

    func testConfigFolderKeepsPriorityOrderWhenSeveralRootsCarryConfigs() {
        // Конфиги в нескольких корнях — побеждает первый по порядку поиска
        // (тот же порядок, по которому wg-quick резолвит конфиг).
        let fs = ConfigFolderFileSystem()
        fs.directories = ["/etc/wireguard", "/opt/homebrew/etc/wireguard"]
        fs.entriesByDirectory = [
            "/etc/wireguard": ["work.conf"],
            "/opt/homebrew/etc/wireguard": ["kvmka-ai.conf"],
        ]

        let path = WireGuardStatusModel.configFolderPath(
            searchPaths: tunnelConfigSearchPaths,
            legacyFallback: "/Users/test/Library/Application Support/wireguard",
            fileSystem: fs
        )

        XCTAssertEqual(path, "/etc/wireguard")
    }

    func testConfigFolderFallsBackToFirstExistingRootWithoutConfigs() {
        // Ни одного `.conf`: открываем первый существующий корень с нечитаемым
        // листингом (nil) — как пустой, так и нечитаемый каталог не претендует
        // на роль «папки с конфигами», но остаётся fallback'ом.
        let fs = ConfigFolderFileSystem()
        fs.directories = ["/opt/homebrew/etc/wireguard"]

        let path = WireGuardStatusModel.configFolderPath(
            searchPaths: tunnelConfigSearchPaths,
            legacyFallback: "/Users/test/Library/Application Support/wireguard",
            fileSystem: fs
        )

        XCTAssertEqual(path, "/opt/homebrew/etc/wireguard")
    }

    func testConfigFolderFallsBackToLegacyAppSupportFolder() {
        // Ни один корень демона не существует — легаси-папка приложения
        // WireGuard (поведение до управления туннелями) не потеряна.
        let legacy = "/Users/test/Library/Application Support/wireguard"
        let fs = ConfigFolderFileSystem()
        fs.directories = [legacy]

        let path = WireGuardStatusModel.configFolderPath(
            searchPaths: tunnelConfigSearchPaths,
            legacyFallback: legacy,
            fileSystem: fs
        )

        XCTAssertEqual(path, legacy)
    }

    func testConfigFolderReturnsNilWhenNothingExists() {
        let fs = ConfigFolderFileSystem()

        let path = WireGuardStatusModel.configFolderPath(
            searchPaths: tunnelConfigSearchPaths,
            legacyFallback: "/Users/test/Library/Application Support/wireguard",
            fileSystem: fs
        )

        XCTAssertNil(path)
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
    /// отработанным тиком. Часы инжектятся тестами устарелости посреди
    /// туннельной операции.
    private func makeInstalledModel(
        showExecutor: WGShowExecuting,
        tunnelNamer: WireGuardTunnelNaming,
        tunnelClient: TunnelCommandRunning,
        now: @escaping () -> Date = Date.init
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
            now: now,
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

    /// Регрессия бага tunnel-management: `.name`-файлы `/var/run/wireguard`
    /// читаемы только root, namer в daemon-режиме промахивается всегда —
    /// раньше isUp выводился из displayName, поднятый туннель читался
    /// «выключенным», и клик слал `up` (wg-quick → «already exists» →
    /// «Tunnel operation failed»). Теперь направление — из ответа `state`:
    /// namer-промах не влияет. Имя стоит в inFlight ровно на время операции,
    /// успех снимает его и делает немедленный refresh.
    func testToggleTunnelSendsDownWhenStateSaysUpDespiteNamerMiss() {
        let client = MockTunnelClient()
        client.configure(
            stateResults: [.success([TunnelState(name: "kvmka-ai", isUp: true, utun: "utun3")])],
            opResults: [.success(())],
            gate: true
        )
        let model = makeInstalledModel(
            showExecutor: CountingShowExecutor(dump: makeWireDump(makeConnectedDump(interfaceName: "utun3"))),
            tunnelNamer: MockTunnelNamer(),  // промах: displayName остаётся utun3
            tunnelClient: client
        )
        XCTAssertEqual(model.interfaces.first?.displayName, "utun3", "предусловие: namer в daemon-режиме промахивается")

        model.loadTunnels()
        waitUntil({ model.tunnels == [TunnelInfo(name: "kvmka-ai", isUp: true)] }, "state должен заполнить tunnels")

        model.toggleTunnel(named: "kvmka-ai")
        waitUntil({ !client.downCalls.isEmpty }, "поднятый по state туннель должен уйти в down")
        XCTAssertTrue(client.upCalls.isEmpty, "up не должен зваться — его слал баг «already exists»")
        XCTAssertEqual(model.inFlightTunnels, ["kvmka-ai"], "операция в полёте: имя в inFlightTunnels")

        client.releaseGate()
        waitUntil(
            { model.inFlightTunnels.isEmpty && !model.isLoading },
            "успех обязан снять имя с inFlight и сделать немедленный refresh"
        )

        XCTAssertNil(model.lastFailure)
    }

    /// Опущенный по state туннель уходит в up — инверсия старого вывода:
    /// namer резолвит utun3 в имя туннеля (старая модель считала бы его
    /// поднятым и слала down), но состояние знает только демон.
    func testToggleTunnelSendsUpWhenStateSaysDownDespiteNamerHit() {
        let client = MockTunnelClient()
        client.configure(stateResults: [.success([TunnelState(name: "kvmka-full", isUp: false, utun: nil)])])
        let model = makeInstalledModel(
            showExecutor: CountingShowExecutor(dump: makeWireDump(makeConnectedDump(interfaceName: "utun3"))),
            tunnelNamer: MockTunnelNamer(knownNames: ["utun3": "kvmka-full"]),
            tunnelClient: client
        )

        model.loadTunnels()
        waitUntil({ model.tunnels == [TunnelInfo(name: "kvmka-full", isUp: false)] }, "state должен заполнить tunnels")

        model.toggleTunnel(named: "kvmka-full")

        waitUntil({ !client.upCalls.isEmpty }, "state говорит down — должен уйти в up, снапшот не при делах")
        XCTAssertTrue(client.downCalls.isEmpty, "down не должен вызываться")
        waitUntil({ model.inFlightTunnels.isEmpty }, "операция должна завершиться и снять имя")
    }

    /// Одна операция за раз — инвариант модели, не только UI (строки уходят в
    /// disabled асинхронным ре-рендером): пока операция в полёте, повторный
    /// клик — по тому же или другому туннелю — молчаливый no-op. Иначе пара
    /// операций в последовательной очереди демона (4 + 9 + 9 = 22 c)
    /// переваливает клиентский дедлайн 16 c — вторая ложной ошибкой.
    func testSecondToggleDuringInFlightOperationIsSilentNoOp() {
        let client = MockTunnelClient()
        client.configure(gate: true)
        let model = WireGuardStatusModel(
            commandRunner: StubCommandRunner(results: [.success("")]),
            tunnelNamer: MockTunnelNamer(),
            socketExists: { false },
            socketPath: helperSocketPath,
            tunnelCommandRunner: client
        )
        model.refresh()
        waitUntil({ !model.isLoading }, "refresh должен завершиться")

        model.toggleTunnel(named: "kvmka-ai")
        waitUntil({ !client.upCalls.isEmpty }, "первая операция должна стартовать")

        model.toggleTunnel(named: "kvmka-ai")  // тот же туннель
        model.toggleTunnel(named: "kvmka-full")  // другой туннель
        spinRunLoop()

        XCTAssertEqual(client.upCalls, ["kvmka-ai"], "вторая операция не должна стартовать")
        XCTAssertTrue(client.downCalls.isEmpty, "down не должен вызываться вовсе")
        XCTAssertEqual(model.inFlightTunnels, ["kvmka-ai"], "в полёте — ровно одна операция")

        client.releaseGate()
        waitUntil({ model.inFlightTunnels.isEmpty }, "операция должна завершиться и снять имя")
    }

    /// Успех операции перезаливает состояние (строки сходятся к ответу state
    /// без ожидания следующего открытия меню): loadTunnels вызывается и после
    /// успешного up/down, не только после провала.
    func testToggleSuccessReloadsTunnelsOnInstalledDaemon() {
        let client = MockTunnelClient()
        client.configure(
            stateResults: [
                .success([TunnelState(name: "kvmka-ai", isUp: false, utun: nil)]),
                .success([TunnelState(name: "kvmka-ai", isUp: true, utun: "utun3")]),
            ],
            opResults: [.success(())],
            gate: true
        )
        let model = makeInstalledModel(
            showExecutor: CountingShowExecutor(dump: makeWireDump("")),
            tunnelNamer: MockTunnelNamer(),
            tunnelClient: client
        )
        model.loadTunnels()
        waitUntil(
            { model.tunnels == [TunnelInfo(name: "kvmka-ai", isUp: false)] },
            "state должен заполнить tunnels"
        )
        XCTAssertEqual(client.stateCalls, 1, "предусловие: один state на заполнение")

        model.toggleTunnel(named: "kvmka-ai")
        waitUntil({ !client.upCalls.isEmpty }, "опущенный туннель должен уйти в up")
        client.releaseGate()
        waitUntil(
            { model.inFlightTunnels.isEmpty && client.stateCalls == 2 },
            "успех обязан перезапросить состояние туннелей"
        )
        XCTAssertEqual(
            model.tunnels,
            [TunnelInfo(name: "kvmka-ai", isUp: true)],
            "после успешного up строки читают поднятое состояние из нового state"
        )
    }

    /// Окно между успешной операцией и ответом `state`: успех снимает имя
    /// с inFlight синхронно, а перезалив состояния приедет позже (в
    /// последовательной очереди демона — за show немедленного refresh).
    /// Регресс: раньше в этом окне строка держала старую точку, и повторный
    /// клик читал старое направление — ту же выполненную команду (up по
    /// поднятому → «already exists», ложная ошибка операции). Теперь `ok`
    /// демона переворачивает точку оптимистично; здесь второй state
    /// провален (строки держат последнее известное — то самое окно).
    func testToggleSuccessFlipsRowBeforeStateReplyArrives() {
        let client = MockTunnelClient()
        client.configure(
            stateResults: [
                .success([TunnelState(name: "kvmka-ai", isUp: false, utun: nil)]),
                .failure(StatusFailure.badResponse),
            ],
            opResults: [.success(())]
        )
        let model = makeInstalledModel(
            showExecutor: CountingShowExecutor(dump: makeWireDump("")),
            tunnelNamer: MockTunnelNamer(),
            tunnelClient: client
        )
        model.loadTunnels()
        waitUntil(
            { model.tunnels == [TunnelInfo(name: "kvmka-ai", isUp: false)] },
            "state должен заполнить tunnels"
        )

        model.toggleTunnel(named: "kvmka-ai")
        waitUntil(
            { model.inFlightTunnels.isEmpty && client.stateCalls == 2 },
            "успешный up обязан завершиться и перезапросить состояние"
        )

        XCTAssertEqual(
            model.tunnels,
            [TunnelInfo(name: "kvmka-ai", isUp: true)],
            "точка строки — уже поднята: ok демона, а не только ответ state"
        )

        model.toggleTunnel(named: "kvmka-ai")  // повторный клик в окне до нового state
        waitUntil({ !client.downCalls.isEmpty }, "повторный клик обязан слать инверсную команду")
        XCTAssertEqual(
            client.upCalls,
            ["kvmka-ai"],
            "второго up быть не должно — окно больше не отправляет ту же команду"
        )
        waitUntil({ model.inFlightTunnels.isEmpty }, "вторая операция должна завершиться")
    }

    /// Догнавший опоздавший ДО-операционный state не отменяет оптимистичную
    /// точку: последовательный демон упорядочивает отправку ответов, но
    /// применение их моделью идёт через GCD-поток → continuation → MainActor
    /// и может задержаться. Второй state (отправлен до up) висит на клапане,
    /// пока операция завершается, флипает строку и запрашивает третий state;
    /// затем второй отпускается — без latest-wins (`loadTunnelsGeneration`)
    /// его до-операционное «down» перетёрло бы «up» после ответа операции.
    func testDelayedPreOpStateReplyDoesNotCancelOptimisticFlip() {
        let client = MockTunnelClient()
        client.configure(
            stateResults: [
                .success([TunnelState(name: "kvmka-ai", isUp: false, utun: nil)]),  // 1-й: заполнение
                .success([TunnelState(name: "kvmka-ai", isUp: false, utun: nil)]),  // 2-й: до-операционный, зависает
                .success([TunnelState(name: "kvmka-ai", isUp: true, utun: "utun3")]),  // 3-й: после up
            ],
            opResults: [.success(())],
            gateStateCall: 2
        )
        let model = makeInstalledModel(
            showExecutor: CountingShowExecutor(dump: makeWireDump("")),
            tunnelNamer: MockTunnelNamer(),
            tunnelClient: client
        )
        model.loadTunnels()
        waitUntil(
            { model.tunnels == [TunnelInfo(name: "kvmka-ai", isUp: false)] },
            "первый state должен заполнить tunnels"
        )

        model.loadTunnels()  // второй state — повиснет на клапане
        waitUntil({ client.stateCalls == 2 }, "до-операционный state должен стартовать")

        model.toggleTunnel(named: "kvmka-ai")  // направление down → up
        waitUntil(
            { model.inFlightTunnels.isEmpty && client.stateCalls == 3 },
            "успех обязан поставить flip и перезапросить состояние"
        )
        XCTAssertEqual(
            model.tunnels,
            [TunnelInfo(name: "kvmka-ai", isUp: true)],
            "точка строки — поднята: ok демона плюс после-операционный state"
        )

        client.releaseStateGate()  // опоздавший до-операционный ответ догоняет модель
        spinRunLoop()

        XCTAssertEqual(
            model.tunnels,
            [TunnelInfo(name: "kvmka-ai", isUp: true)],
            "опоздавший ответ старого запроса отбрасывается (latest-wins)"
        )
    }

    /// In-flight операция глушит show-тик: refresh не запускается вовсе — без
    /// ошибки, без смены serviceState, show демона не дёргается; снапшот не
    /// устаревает, даже когда операция пережила stalenessLimit.
    func testInFlightTunnelSuppressesShowTick() {
        let clock = FakeClock()
        let client = MockTunnelClient()
        client.configure(
            stateResults: [.success([TunnelState(name: "kvmka-ai", isUp: true, utun: "utun3")])],
            opResults: [.success(())],
            gate: true
        )
        let showExecutor = CountingShowExecutor(dump: makeWireDump(makeConnectedDump(interfaceName: "utun3")))
        let model = makeInstalledModel(
            showExecutor: showExecutor,
            tunnelNamer: MockTunnelNamer(),
            tunnelClient: client,
            now: { clock.current }
        )
        let callsAfterSetup = showExecutor.calls

        model.loadTunnels()
        waitUntil({ model.tunnels == [TunnelInfo(name: "kvmka-ai", isUp: true)] }, "state должен заполнить tunnels")

        model.toggleTunnel(named: "kvmka-ai")
        waitUntil({ !client.downCalls.isEmpty }, "операция должна стартовать")

        model.refresh()  // тик таймера (или ⌘R) посреди операции
        XCTAssertFalse(model.isLoading, "подавленный тик не должен ставить isLoading")
        XCTAssertNil(model.lastFailure, "подавленный тик не должен трогать lastFailure")
        XCTAssertEqual(model.serviceState, .installed, "подавленный тик не должен менять serviceState")
        XCTAssertEqual(showExecutor.calls, callsAfterSetup, "show демона не должен дёргаться во время операции")

        // Худший случай очереди демона (13 c) переживает stalenessLimit
        // (10 c): пока операция жива, снапшот не приглушается.
        clock.current = clock.current.addingTimeInterval(11)
        XCTAssertFalse(model.isDataStale, "в полёте снапшот не устаревает")
        XCTAssertTrue(model.showsTunnelUp, "иконка не гаснет посреди живой операции")

        client.releaseGate()
        waitUntil(
            { showExecutor.calls == callsAfterSetup + 1 && !model.isLoading },
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
            stateResults: [
                .success([TunnelState(name: "kvmka-ai", isUp: true, utun: "utun3")]),
                .failure(StatusFailure.connectionRefused),  // state после провала тоже падает — глотается
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
        waitUntil({ model.tunnels == [TunnelInfo(name: "kvmka-ai", isUp: true)] }, "state должен заполнить tunnels")
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

    /// state маппится в tunnels напрямую: имена + isUp — данные демона,
    /// вывод из снапшота интерфейсов удалён вместе с `isTunnelUp`.
    func testLoadTunnelsMapsStateToTunnels() {
        let showExecutor = CountingShowExecutor(dump: makeWireDump(makeConnectedDump(interfaceName: "utun3")))
        let client = MockTunnelClient()
        client.configure(stateResults: [.success([
            TunnelState(name: "kvmka-ai", isUp: true, utun: "utun3"),
            TunnelState(name: "kvmka-full", isUp: false, utun: nil),
        ])])
        let model = makeInstalledModel(
            showExecutor: showExecutor,
            tunnelNamer: MockTunnelNamer(knownNames: ["utun3": "kvmka-ai"]),
            tunnelClient: client
        )

        model.loadTunnels()
        waitUntil({ model.tunnels.count == 2 }, "state должен заполнить tunnels")

        XCTAssertEqual(model.tunnels, [
            TunnelInfo(name: "kvmka-ai", isUp: true),
            TunnelInfo(name: "kvmka-full", isUp: false),
        ], "isUp — данные демона, а не вывод из displayName интерфейсов")
    }

    /// Инверсия старого поведения: isUp строк больше не пересчитывается из
    /// снапшота — 5-с тик с новым дампом меняет `interfaces`, но `tunnels`
    /// держит последний ответ state, пока не придёт новый.
    func testTunnelStatesDoNotFollowInterfaceSnapshotUpdates() {
        let showExecutor = CountingShowExecutor(dump: "")  // интерфейсов нет
        let client = MockTunnelClient()
        client.configure(stateResults: [.success([TunnelState(name: "kvmka-ai", isUp: false, utun: nil)])])
        let model = makeInstalledModel(
            showExecutor: showExecutor,
            tunnelNamer: MockTunnelNamer(knownNames: ["utun3": "kvmka-ai"]),
            tunnelClient: client
        )
        model.loadTunnels()
        waitUntil({ model.tunnels == [TunnelInfo(name: "kvmka-ai", isUp: false)] }, "state должен заполнить tunnels")

        showExecutor.setDump(makeWireDump(makeConnectedDump(interfaceName: "utun3")))
        model.refresh()
        waitUntil({ model.interfaces.count == 1 }, "новый тик должен принести интерфейс")

        XCTAssertEqual(model.tunnels, [TunnelInfo(name: "kvmka-ai", isUp: false)], "тик не переворачивает isUp без нового state")
        XCTAssertEqual(client.stateCalls, 1, "пересчёт не требует нового state")
    }

    /// Ошибки state глотаются: ни lastFailure, ни очистки tunnels, ни
    /// откатывания имён интерфейсов — данные меню оппортунистические.
    func testLoadTunnelsSwallowsClientErrors() {
        let showExecutor = CountingShowExecutor(dump: makeWireDump(makeConnectedDump(interfaceName: "utun3")))
        let client = MockTunnelClient()
        client.configure(stateResults: [
            .success([TunnelState(name: "kvmka-ai", isUp: true, utun: "utun3")]),
            .failure(StatusFailure.connectionRefused),
        ])
        let model = makeInstalledModel(
            showExecutor: showExecutor,
            tunnelNamer: MockTunnelNamer(),  // промах: имя интерфейса даёт только state
            tunnelClient: client
        )

        model.loadTunnels()
        waitUntil(
            { model.tunnels == [TunnelInfo(name: "kvmka-ai", isUp: true)] },
            "первый state должен заполнить tunnels"
        )
        XCTAssertEqual(model.interfaces.first?.displayName, "kvmka-ai", "предусловие: имя интерфейса пришло из state")

        model.loadTunnels()
        waitUntil({ client.stateCalls == 2 }, "второй state должен быть отправлен")
        spinRunLoop()

        XCTAssertEqual(model.tunnels, [TunnelInfo(name: "kvmka-ai", isUp: true)], "ошибка state не чистит tunnels")
        XCTAssertEqual(model.interfaces.first?.displayName, "kvmka-ai", "ошибка state не откатывает имя интерфейса")
        XCTAssertNil(model.lastFailure, "ошибка state не попадает в карточку")
    }

    /// Идентичный ответ — без republish: повторный state с теми же именами и
    /// состояниями не должен давать новый выхлоп `$tunnels` (подписка в
    /// `StatusItemController` перестраивает открытое меню на каждый выхлоп —
    /// иначе каждое открытие меню перестраивало бы секцию дважды).
    func testLoadTunnelsDoesNotRepublishIdenticalState() {
        let showExecutor = CountingShowExecutor(dump: makeWireDump(makeConnectedDump(interfaceName: "utun3")))
        let client = MockTunnelClient()
        client.configure(stateResults: [
            .success([TunnelState(name: "kvmka-ai", isUp: true, utun: "utun3")]),
            .success([TunnelState(name: "kvmka-ai", isUp: true, utun: "utun3")]),
        ])
        let model = makeInstalledModel(
            showExecutor: showExecutor,
            tunnelNamer: MockTunnelNamer(knownNames: ["utun3": "kvmka-ai"]),
            tunnelClient: client
        )

        var emissions = 0
        let cancellable = model.$tunnels.sink { _ in emissions += 1 }
        defer { cancellable.cancel() }

        model.loadTunnels()
        waitUntil(
            { client.stateCalls == 1 && model.tunnels == [TunnelInfo(name: "kvmka-ai", isUp: true)] },
            "первый state должен заполнить tunnels"
        )
        let emissionsAfterFirstState = emissions

        model.loadTunnels()
        waitUntil({ client.stateCalls == 2 }, "второй state должен быть отправлен")
        spinRunLoop()

        XCTAssertEqual(
            emissions,
            emissionsAfterFirstState,
            "идентичный ответ — без нового выхлопа $tunnels"
        )
    }

    /// До `.installed` loadTunnels не дёргает клиента вовсе: у старого демона
    /// state — unknown command, секции быть не должно.
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
        XCTAssertEqual(client.stateCalls, 0, "до первого тика state не отправляется")

        model.refresh()
        waitUntil({ !model.isLoading }, "refresh должен завершиться")
        XCTAssertEqual(model.serviceState, .absent, "предусловие: сокета нет — состояние absent")

        model.loadTunnels()
        spinRunLoop()
        XCTAssertEqual(client.stateCalls, 0, "в absent-состоянии state не отправляется")
    }

    // MARK: - Модель: имена интерфейсов из state (приоритет над namer)

    /// state-utun совпал с интерфейсом снапшота → displayName становится
    /// именем конфига, namer-результат перетёрт: демон — источник имён в
    /// daemon-режиме (`.name`-файлы под root, namer промахивается всегда).
    func testStateInterfaceNameOverridesNamerResult() {
        let client = MockTunnelClient()
        client.configure(stateResults: [.success([TunnelState(name: "kvmka-ai", isUp: true, utun: "utun3")])])
        let model = makeInstalledModel(
            showExecutor: CountingShowExecutor(dump: makeWireDump(makeConnectedDump(interfaceName: "utun3"))),
            tunnelNamer: MockTunnelNamer(knownNames: ["utun3": "wrong-name"]),
            tunnelClient: client
        )
        XCTAssertEqual(model.interfaces.first?.displayName, "wrong-name", "предусловие: namer дал своё имя")

        model.loadTunnels()
        waitUntil(
            { model.interfaces.first?.displayName == "kvmka-ai" },
            "ответ state обязан перетереть namer на первом же пути записи"
        )
    }

    /// Тик не откатывает имя: 5-с refresh гонит namer-резолв (промах), затем
    /// применяет сохранённый state-маппинг — без этого карточка возвращала
    /// бы `utunN` при открытом меню каждые 5 с.
    func testRefreshKeepsStateInterfaceNameWhenNamerMisses() {
        let showExecutor = CountingShowExecutor(dump: makeWireDump(makeConnectedDump(interfaceName: "utun3")))
        let client = MockTunnelClient()
        client.configure(stateResults: [.success([TunnelState(name: "kvmka-ai", isUp: true, utun: "utun3")])])
        let model = makeInstalledModel(
            showExecutor: showExecutor,
            tunnelNamer: MockTunnelNamer(),  // промах на каждом тике
            tunnelClient: client
        )
        model.loadTunnels()
        waitUntil(
            { model.interfaces.first?.displayName == "kvmka-ai" },
            "state обязан дать имя конфига"
        )

        let callsAfterFirstTick = showExecutor.calls
        model.refresh()
        waitUntil(
            { showExecutor.calls > callsAfterFirstTick && !model.isLoading },
            "новый тик должен пройти"
        )

        XCTAssertEqual(
            model.interfaces.first?.displayName,
            "kvmka-ai",
            "5-с тик с namer-промахом не должен откатывать имя к utunN"
        )
    }

    /// Демон исчез посреди запуска (uninstall из меню): успешный тик
    /// sudo-фолбэка обязан сбросить state-маппинг — иначе последний ответ
    /// умершего демона вечно перетирал бы свежий namer-резолв при
    /// переиспользовании utun другим конфигом (namer — источник имён в
    /// dev-режиме без демона).
    func testDaemonlessTickDropsStaleStateInterfaceNames() {
        let client = MockTunnelClient()
        client.configure(stateResults: [.success([TunnelState(name: "kvmka-ai", isUp: true, utun: "utun3")])])
        // sun_path вмещает ~103 байта — короткий /tmp-путь с усечённым UUID.
        let socketPath = "/tmp/wgstatusbar-modeltests-"
            + UUID().uuidString.prefix(8)
            + ".sock"
        daemonSocketPaths.append(socketPath)
        let server = DaemonServer(
            executor: CountingShowExecutor(dump: makeWireDump(makeConnectedDump(interfaceName: "utun3"))),
            socketPath: socketPath
        )
        daemonServerTasks.append(Task.detached { try await server.run() })
        waitDaemonListening(socketPath: socketPath)

        let fallbackRunner = StubCommandRunner(results: [.success(makeConnectedDump(interfaceName: "utun3"))])
        let model = WireGuardStatusModel(
            commandRunner: fallbackRunner,
            tunnelNamer: MockTunnelNamer(knownNames: ["utun3": "fresh-namer-name"]),
            socketExists: { FileManager.default.fileExists(atPath: socketPath) },
            socketPath: socketPath,
            tunnelCommandRunner: client
        )
        model.refresh()
        waitUntil({ model.serviceState == .installed }, "живой демон должен довести модель до installed")
        model.loadTunnels()
        waitUntil(
            { model.interfaces.first?.displayName == "kvmka-ai" },
            "предусловие: пока демон жив, state перетирает namer"
        )

        // Демон удалили: сокета нет — тик уходит в фолбэк-раннер.
        try? FileManager.default.removeItem(atPath: socketPath)
        model.refresh()
        waitUntil(
            { fallbackRunner.consumedCount > 0 && !model.isLoading },
            "тик фолбэка должен пройти"
        )

        XCTAssertEqual(model.serviceState, .absent, "сокет исчез — состояние absent")
        XCTAssertEqual(
            model.interfaces.first?.displayName,
            "fresh-namer-name",
            "устаревший state-маппинг не должен перетирать namer в dev-режиме без демона"
        )
    }

    /// Конфликт «два конфига на одном utun» (окно свежести пар на стороне
    /// данных): свёртка маппинга — first-wins без падения
    /// (`Dictionary(uniqueKeysWithValues:)` на дубликате крэшила бы).
    func testStateMappingKeepsFirstEntryForDuplicatedUtun() {
        let client = MockTunnelClient()
        client.configure(stateResults: [.success([
            TunnelState(name: "kvmka-ai", isUp: true, utun: "utun3"),
            TunnelState(name: "kvmka-full", isUp: true, utun: "utun3"),
        ])])
        let model = makeInstalledModel(
            showExecutor: CountingShowExecutor(dump: makeWireDump(makeConnectedDump(interfaceName: "utun3"))),
            tunnelNamer: MockTunnelNamer(),
            tunnelClient: client
        )

        model.loadTunnels()
        waitUntil({ model.tunnels.count == 2 }, "обе строки state должны попасть в tunnels")

        XCTAssertEqual(
            model.interfaces.first?.displayName,
            "kvmka-ai",
            "при дубликате utun в маппинге побеждает первый ответ"
        )
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
    private var stateResults: [Result<[TunnelState], Error>] = []
    private var opResults: [Result<Void, Error>] = []
    private var gated = false
    private var gateContinuation: CheckedContinuation<Void, Never>?
    /// Порядковый номер (с 1) state-вызова, который должен повиснуть до
    /// `releaseStateGate()` — управляемо задержанный ответ одного запроса
    /// (гонка «опоздавший до-операционный state против optimistic flip»).
    private var stateGateCallNumber: Int?
    private var stateGateContinuation: CheckedContinuation<Void, Never>?
    private var stateCallsStorage = 0
    private var upCallsStorage: [String] = []
    private var downCallsStorage: [String] = []

    func configure(
        stateResults: [Result<[TunnelState], Error>] = [],
        opResults: [Result<Void, Error>] = [],
        gate: Bool = false,
        gateStateCall: Int? = nil
    ) {
        lock.withLock {
            self.stateResults = stateResults
            self.opResults = opResults
            self.gated = gate
            self.stateGateCallNumber = gateStateCall
        }
    }

    var stateCalls: Int { lock.withLock { stateCallsStorage } }
    var upCalls: [String] { lock.withLock { upCallsStorage } }
    var downCalls: [String] { lock.withLock { downCallsStorage } }

    /// Отпускает зависшую на клапане операцию.
    func releaseGate() {
        lock.withLock {
            gateContinuation?.resume()
            gateContinuation = nil
        }
    }

    /// Отпускает зависший на клапане state-вызов.
    func releaseStateGate() {
        lock.withLock {
            stateGateContinuation?.resume()
            stateGateContinuation = nil
            stateGateCallNumber = nil
        }
    }

    func state() async throws -> [TunnelState] {
        let call: (number: Int, result: Result<[TunnelState], Error>) = lock.withLock {
            stateCallsStorage += 1
            let result = stateResults.isEmpty ? .success([]) : stateResults.removeFirst()
            return (stateCallsStorage, result)
        }
        await waitOnStateGate(callNumber: call.number)
        switch call.result {
        case .success(let states):
            return states
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
    /// не порождает); `state` клапан не трогает — гейтится только наблюдаемая
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

    /// Клапан для ровно одного state-вызова с заданным номером (остальные
    /// проходят): задержка ответа одного запроса без остановки прочих.
    private func waitOnStateGate(callNumber: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock {
                if callNumber == stateGateCallNumber, stateGateContinuation == nil {
                    stateGateContinuation = continuation
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
