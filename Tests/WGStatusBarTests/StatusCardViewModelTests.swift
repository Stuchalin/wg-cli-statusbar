import XCTest
@testable import WGStatusBarCore

final class StatusCardViewModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Фикстуры (относительно фиксированного now, с запасом от порогов 2/10 мин)

    private func makePeer(
        _ key: String,
        handshakeSecondsAgo: Int?,
        endpoint: String? = "203.0.113.10:51820",
        allowedIps: String? = "0.0.0.0/0",
        rx: UInt64 = 897_500,
        tx: UInt64 = 123_456
    ) -> WGPeer {
        WGPeer(
            publicKey: key,
            endpoint: endpoint,
            allowedIps: allowedIps,
            latestHandshake: handshakeSecondsAgo.map { now.addingTimeInterval(TimeInterval(-$0)) },
            rxBytes: rx,
            txBytes: tx
        )
    }

    private func makeViewModel(
        _ interfaces: [WGInterface],
        isLoading: Bool = false,
        errorMessage: String? = nil
    ) -> StatusCardViewModel {
        StatusCardViewModel(interfaces: interfaces, isLoading: isLoading, errorMessage: errorMessage, now: now)
    }

    // MARK: - Заголовок интерфейса: имя и цвет точки (свежесть)

    func testInterfaceHeaderCarriesNamesAndFreshness() {
        let viewModel = makeViewModel([
            WGInterface(name: "utun3", peers: [], displayName: "work-vpn"),
        ])

        XCTAssertEqual(viewModel.interfaces.count, 1)
        XCTAssertEqual(viewModel.interfaces[0].displayName, "work-vpn")
        XCTAssertEqual(viewModel.interfaces[0].name, "utun3")
        XCTAssertEqual(viewModel.interfaces[0].freshness, .never, "пиров нет → точки-статуса нет, цвет secondary")
    }

    func testInterfaceFreshnessFreshestPeerWins() {
        let fresh = makeViewModel([
            WGInterface(name: "utun3", peers: [makePeer("a", handshakeSecondsAgo: 60)]),
        ])
        XCTAssertEqual(fresh.interfaces[0].freshness, .fresh, "хендшейк 60 с назад → green")

        let aging = makeViewModel([
            WGInterface(name: "utun3", peers: [makePeer("a", handshakeSecondsAgo: 5 * 60)]),
        ])
        XCTAssertEqual(aging.interfaces[0].freshness, .aging, "хендшейк 5 мин назад → orange")

        let stale = makeViewModel([
            WGInterface(name: "utun3", peers: [makePeer("a", handshakeSecondsAgo: 15 * 60)]),
        ])
        XCTAssertEqual(stale.interfaces[0].freshness, .stale, "хендшейк 15 мин назад → secondary")

        let mixed = makeViewModel([
            WGInterface(name: "utun3", peers: [
                makePeer("a", handshakeSecondsAgo: 15 * 60),
                makePeer("b", handshakeSecondsAgo: 60),
            ]),
        ])
        XCTAssertEqual(mixed.interfaces[0].freshness, .fresh, "при нескольких пирах точка берётся от самого свежего")
    }

    // MARK: - Тексты пира: трафик и хендшейк

    func testPeerTrafficAndHandshakeTexts() {
        let viewModel = makeViewModel([
            WGInterface(name: "utun3", peers: [makePeer("a", handshakeSecondsAgo: 57)]),
        ])

        let peer = viewModel.interfaces[0].peers[0]
        XCTAssertEqual(peer.trafficText, "↓ \(Formatters.formatBytes(897_500))  ↑ \(Formatters.formatBytes(123_456))")
        XCTAssertEqual(peer.handshakeText, L10n.string("ago.seconds", "57"))
        XCTAssertEqual(peer.endpoint, "203.0.113.10:51820")
    }

    func testPeerHandshakeNilForNever() {
        let viewModel = makeViewModel([
            WGInterface(name: "utun3", peers: [makePeer("a", handshakeSecondsAgo: nil)]),
        ])

        XCTAssertNil(viewModel.interfaces[0].peers[0].handshakeText, "never → текст решает вью (peer.handshake_never)")
    }

    // MARK: - Pubkey показывается только при >1 пире

    func testPublicKeyShownOnlyWithMultiplePeers() {
        let single = makeViewModel([
            WGInterface(name: "utun3", peers: [makePeer("a", handshakeSecondsAgo: 60)]),
        ])
        XCTAssertFalse(single.interfaces[0].showsPublicKeys, "один пир → pubkey не показывается")

        let multiple = makeViewModel([
            WGInterface(name: "utun3", peers: [
                makePeer("a", handshakeSecondsAgo: 60),
                makePeer("b", handshakeSecondsAgo: nil),
            ]),
        ])
        XCTAssertTrue(multiple.interfaces[0].showsPublicKeys, ">1 пира → pubkey показывается укороченным")
    }

    func testShortPublicKeyKeepsHeadAndTail() {
        let key = "Q1P4Lb5dQ3FnK9Xr2VvA7sH0jZ8cB6N4mY1wE5tR3gU="
        XCTAssertEqual(StatusCardViewModel.shortPublicKey(key), "Q1P4Lb5d…3gU=")
    }

    func testShortPublicKeyBoundaryAroundTwelveCharacters() {
        XCTAssertEqual(StatusCardViewModel.shortPublicKey("aaaaaaaaaaaa"), "aaaaaaaaaaaa", "12 символов — граница, не укорачивается")
        XCTAssertEqual(StatusCardViewModel.shortPublicKey("aaaaaaaaaaaaa"), "aaaaaaaa…aaaa", "13 символов — укорачивается")
    }

    // MARK: - Маршрутизация: «весь трафик» / список подсетей

    func testRouteFullTunnelSinglePeer() {
        let viewModel = makeViewModel([
            WGInterface(name: "utun3", peers: [
                makePeer("a", handshakeSecondsAgo: 60, allowedIps: "0.0.0.0/0, ::/0"),
            ]),
        ])

        XCTAssertEqual(viewModel.interfaces[0].routeScope, .fullTunnel)
        XCTAssertEqual(viewModel.interfaces[0].routeText, L10n.string("badge.full_tunnel"))
    }

    func testRouteSplitTunnelListsSubnets() {
        let viewModel = makeViewModel([
            WGInterface(name: "utun3", peers: [
                makePeer("a", handshakeSecondsAgo: 60, allowedIps: "10.0.0.0/24, 192.168.1.0/24"),
            ]),
        ])

        XCTAssertEqual(viewModel.interfaces[0].routeScope, .splitTunnel)
        XCTAssertEqual(viewModel.interfaces[0].routeText, "10.0.0.0/24, 192.168.1.0/24")
    }

    func testRouteFullTunnelPriorityAcrossPeers() {
        let viewModel = makeViewModel([
            WGInterface(name: "utun3", peers: [
                makePeer("a", handshakeSecondsAgo: 60, allowedIps: "10.0.0.0/24"),
                makePeer("b", handshakeSecondsAgo: nil, allowedIps: "0.0.0.0/0"),
            ]),
        ])

        XCTAssertEqual(viewModel.interfaces[0].routeScope, .fullTunnel, "любой пир с default route → весь трафик на уровне интерфейса")
        XCTAssertEqual(viewModel.interfaces[0].routeText, L10n.string("badge.full_tunnel"))
    }

    func testRouteSplitSubnetsMergedAcrossPeersWithoutDuplicates() {
        let viewModel = makeViewModel([
            WGInterface(name: "utun3", peers: [
                makePeer("a", handshakeSecondsAgo: 60, allowedIps: "10.0.0.0/24"),
                makePeer("b", handshakeSecondsAgo: nil, allowedIps: "10.0.0.0/24,192.168.1.0/24"),
            ]),
        ])

        XCTAssertEqual(viewModel.interfaces[0].routeText, "10.0.0.0/24, 192.168.1.0/24", "подсети объединяются без дублей")
    }

    func testRouteNoneWhenNoAllowedIps() {
        for allowedIps in [nil, "", "(none)"] {
            let viewModel = makeViewModel([
                WGInterface(name: "utun3", peers: [
                    makePeer("a", handshakeSecondsAgo: 60, allowedIps: allowedIps),
                ]),
            ])

            XCTAssertEqual(viewModel.interfaces[0].routeScope, .none)
            XCTAssertNil(viewModel.interfaces[0].routeText, "allowedIps=\(allowedIps ?? "nil") → строки маршрута нет")
        }
    }

    func testRouteTextExcludesNonePlaceholderAmongSubnets() {
        let viewModel = makeViewModel([
            WGInterface(name: "utun3", peers: [
                makePeer("a", handshakeSecondsAgo: 60, allowedIps: "10.0.0.0/24, (none)"),
            ]),
        ])

        XCTAssertEqual(viewModel.interfaces[0].routeScope, .splitTunnel)
        XCTAssertEqual(viewModel.interfaces[0].routeText, "10.0.0.0/24", "placeholder (none) не попадает в список подсетей")
    }

    // MARK: - Empty state, ошибки, загрузка

    func testEmptyStateWhenNoInterfaces() {
        let empty = makeViewModel([])
        XCTAssertEqual(empty.emptyStateText, L10n.string("status.no_interfaces"))

        let nonEmpty = makeViewModel([
            WGInterface(name: "utun3", peers: [makePeer("a", handshakeSecondsAgo: 60)]),
        ])
        XCTAssertNil(nonEmpty.emptyStateText)
    }

    func testErrorAndLoadingPassThrough() {
        let viewModel = makeViewModel([], isLoading: true, errorMessage: "boom")

        XCTAssertTrue(viewModel.isLoading)
        XCTAssertEqual(viewModel.errorMessage, "boom")
    }

    // MARK: - Локализация новых ключей карточки

    func testCardKeysExistInBothLocalizations() throws {
        var keysWithPlaceholder: Set<String> = []
        for language in ["en", "ru"] {
            let lprojPath = try XCTUnwrap(
                Bundle.module.path(forResource: language, ofType: "lproj"),
                "нет \(language).lproj в бандле модуля"
            )
            let bundle = Bundle(path: lprojPath)
            for key in [
                "badge.full_tunnel", "peer.handshake_never",
                "legend.fresh", "legend.aging", "legend.stale", "legend.toggle",
            ] {
                let raw = bundle?.localizedString(forKey: key, value: "MISSING", table: "Localizable")
                XCTAssertNotEqual(raw, "MISSING", "ключ \(key) отсутствует в \(language)")
                if raw?.contains("%@") == true {
                    keysWithPlaceholder.insert(key)
                }
            }
        }
        XCTAssertTrue(keysWithPlaceholder.isEmpty, "у ключей карточки не должно быть плейсхолдеров: \(keysWithPlaceholder)")
    }
}
