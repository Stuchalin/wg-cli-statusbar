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

    // MARK: - Модель: statusText / menuTitle

    func testStatusTextWhenNoInterfaces() {
        let model = WireGuardStatusModel(testing: [])

        XCTAssertEqual(model.statusText, L10n.string("status.no_interfaces"))
    }

    func testStatusTextWhenAllConnected() {
        let model = WireGuardStatusModel(
            testing: [
                makeInterface("wg0", peers: [makeActivePeer("peer-a")]),
                makeInterface("wg1", peers: [makeActivePeer("peer-b")]),
            ]
        )

        XCTAssertEqual(model.statusText, L10n.string("status.all_connected"))
    }

    func testStatusTextWhenSomeConnected() {
        let model = WireGuardStatusModel(
            testing: [
                makeInterface("wg0", peers: [makeActivePeer("peer-a")]),
                makeInterface("wg1", peers: [makeNeverPeer("peer-b")]),
            ]
        )

        XCTAssertEqual(model.statusText, L10n.string("status.connected_count", "1", "2"))
    }

    func testMenuTitleWhenActiveAndInactive() {
        let connectedModel = WireGuardStatusModel(testing: [makeInterface("wg0", peers: [makeActivePeer("peer-a")])])
        let disconnectedModel = WireGuardStatusModel(testing: [makeInterface("wg0", peers: [makeNeverPeer("peer-b")])])

        XCTAssertEqual(connectedModel.menuTitle, L10n.string("menu.title.on"))
        XCTAssertEqual(disconnectedModel.menuTitle, L10n.string("menu.title.off"))
    }
}
