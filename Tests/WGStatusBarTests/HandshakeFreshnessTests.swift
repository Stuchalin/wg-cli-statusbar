import XCTest
@testable import WGStatusBarCore

final class HandshakeFreshnessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Границы свежести

    func testFreshnessRecentHandshakeIsFresh() {
        let handshake = now.addingTimeInterval(-57)
        XCTAssertEqual(HandshakeFreshness.freshness(date: handshake, now: now), .fresh)
    }

    func testFreshnessAtTwoMinuteBoundaryIsFresh() {
        let handshake = now.addingTimeInterval(-HandshakeFreshness.freshThreshold)
        XCTAssertEqual(HandshakeFreshness.freshness(date: handshake, now: now), .fresh)
    }

    func testFreshnessJustBeyondTwoMinutesIsAging() {
        let handshake = now.addingTimeInterval(-HandshakeFreshness.freshThreshold - 1)
        XCTAssertEqual(HandshakeFreshness.freshness(date: handshake, now: now), .aging)
    }

    func testFreshnessAtTenMinuteBoundaryIsAging() {
        let handshake = now.addingTimeInterval(-HandshakeFreshness.agingThreshold)
        XCTAssertEqual(HandshakeFreshness.freshness(date: handshake, now: now), .aging)
    }

    func testFreshnessJustBeyondTenMinutesIsStale() {
        let handshake = now.addingTimeInterval(-HandshakeFreshness.agingThreshold - 1)
        XCTAssertEqual(HandshakeFreshness.freshness(date: handshake, now: now), .stale)
    }

    func testFreshnessNilHandshakeIsNever() {
        XCTAssertEqual(HandshakeFreshness.freshness(date: nil, now: now), .never)
    }

    func testFreshnessFutureHandshakeIsFresh() {
        // Эпоха хендшейка приходит от ядра: при отстающих локальных часах возраст
        // отрицательный — считаем пир свежим, сдвиг часов не роняет статус.
        let handshake = now.addingTimeInterval(30)
        XCTAssertEqual(HandshakeFreshness.freshness(date: handshake, now: now), .fresh)
    }

    // MARK: - Классификация allowed ips

    func testIPv4DefaultRouteIsFullTunnel() {
        XCTAssertEqual(RouteScope(allowedIps: "0.0.0.0/0"), .fullTunnel)
    }

    func testIPv6DefaultRouteIsFullTunnel() {
        XCTAssertEqual(RouteScope(allowedIps: "::/0"), .fullTunnel)
    }

    func testMixedDefaultRoutesWithoutSpacesIsFullTunnel() {
        XCTAssertEqual(RouteScope(allowedIps: "0.0.0.0/0,::/0"), .fullTunnel)
    }

    func testDefaultRouteAmongSubnetsIsFullTunnel() {
        XCTAssertEqual(RouteScope(allowedIps: "10.0.0.0/24, 0.0.0.0/0"), .fullTunnel)
    }

    func testSubnetsOnlyIsSplitTunnel() {
        XCTAssertEqual(RouteScope(allowedIps: "10.0.0.0/24, 192.168.1.0/24"), .splitTunnel)
        XCTAssertEqual(RouteScope(allowedIps: "fd00:abcd::/64"), .splitTunnel)
    }

    func testEmptyAllowedIpsIsNoRoutes() {
        XCTAssertEqual(RouteScope(allowedIps: nil), RouteScope.none)
        XCTAssertEqual(RouteScope(allowedIps: ""), RouteScope.none)
        XCTAssertEqual(RouteScope(allowedIps: "   "), RouteScope.none)
    }

    func testNonePlaceholderIsNoRoutes() {
        XCTAssertEqual(RouteScope(allowedIps: "(none)"), RouteScope.none)
    }

    func testNonePlaceholderAmongSubnetsIsStillSplitTunnel() {
        // `(none)` вперемешку с подсетями: маршруты есть — сплит-туннель
        XCTAssertEqual(RouteScope(allowedIps: "10.0.0.0/24, (none)"), .splitTunnel)
    }
}
