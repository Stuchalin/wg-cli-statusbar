import XCTest
@testable import WGStatusBarCore

final class WGShowParsingTests: XCTestCase {
    func makePeer(_ key: String, handshake: String) -> WGPeer {
        WGPeer(publicKey: key, latestHandshake: handshake)
    }

    func makeInterface(_ name: String, peers: [WGPeer]) -> WGInterface {
        WGInterface(name: name, peers: peers)
    }

    func testParseWGShowWithSingleInterfaceAndMultiplePeers() {
        let output = """
interface: wg0
private key: REDACTED
listen port: 51820
peer: peer-a-public-key
endpoint: 203.0.113.10:51820
allowed ips: 10.0.0.2/32
latest handshake: 2 minutes, 10 seconds ago
transfer: 1.20 KiB received, 2.40 KiB sent
peer: peer-b-public-key
latest handshake: never
allowed ips: 10.0.0.3/32

interface: wg1
peer: peer-c-public-key
latest handshake: 1 minute, 5 seconds ago
"""

        let interfaces = WireGuardStatusModel.parseWGShow(output)

        XCTAssertEqual(interfaces.count, 2)

        XCTAssertEqual(interfaces[0].name, "wg0")
        XCTAssertEqual(interfaces[0].peers.count, 2)
        XCTAssertTrue(interfaces[0].isConnected)

        let firstPeer = interfaces[0].peers[0]
        XCTAssertEqual(firstPeer.publicKey, "peer-a-public-key")
        XCTAssertEqual(firstPeer.endpoint, "203.0.113.10:51820")
        XCTAssertEqual(firstPeer.allowedIps, "10.0.0.2/32")
        XCTAssertEqual(firstPeer.latestHandshake, "2 minutes, 10 seconds ago")
        XCTAssertTrue(firstPeer.isActive)

        let secondPeer = interfaces[0].peers[1]
        XCTAssertEqual(secondPeer.publicKey, "peer-b-public-key")
        XCTAssertEqual(secondPeer.latestHandshake, "never")
        XCTAssertFalse(secondPeer.isActive)

        XCTAssertEqual(interfaces[1].name, "wg1")
        XCTAssertEqual(interfaces[1].peers.count, 1)
        XCTAssertEqual(interfaces[1].peers[0].publicKey, "peer-c-public-key")
        XCTAssertTrue(interfaces[1].isConnected)
    }

    func testParseWGShowWithoutPeers() {
        let output = """
interface: wg0
private key: REDACTED
listen port: 51820
"""

        let interfaces = WireGuardStatusModel.parseWGShow(output)

        XCTAssertEqual(interfaces.count, 1)
        XCTAssertEqual(interfaces.first?.name, "wg0")
        XCTAssertEqual(interfaces.first?.peers.count, 0)
        XCTAssertFalse(interfaces.first?.isConnected ?? true)
    }

    func testParseWGShowEmptyOutput() {
        let interfaces = WireGuardStatusModel.parseWGShow("")

        XCTAssertEqual(interfaces.count, 0)
    }

    func testParseWGShowUnsupportedText() {
        let output = """
some random text
without interface headers
"""
        let interfaces = WireGuardStatusModel.parseWGShow(output)

        XCTAssertEqual(interfaces.count, 0)
    }

    func testPeerActiveStateForNeverHandshake() {
        let activePeer = WGPeer(publicKey: "active", latestHandshake: "30 seconds ago")
        let inactivePeer = WGPeer(publicKey: "inactive", latestHandshake: "never")
        let missingPeer = WGPeer(publicKey: "missing", latestHandshake: nil)
        let inactivePeerUppercased = WGPeer(publicKey: "inactive_upper", latestHandshake: "  NEVER ")

        XCTAssertTrue(activePeer.isActive)
        XCTAssertFalse(inactivePeer.isActive)
        XCTAssertFalse(inactivePeerUppercased.isActive)
        XCTAssertFalse(missingPeer.isActive)
    }

    func testStatusTextWhenNoInterfaces() {
        let model = WireGuardStatusModel(testing: [])

        XCTAssertEqual(model.statusText, L10n.string("status.no_interfaces"))
    }

    func testStatusTextWhenAllConnected() {
        let model = WireGuardStatusModel(
            testing: [
                makeInterface(
                    "wg0",
                    peers: [makePeer("peer-a", handshake: "1 minute ago")]
                ),
                makeInterface(
                    "wg1",
                    peers: [makePeer("peer-b", handshake: "30 seconds ago")]
                ),
            ]
        )

        XCTAssertEqual(model.statusText, L10n.string("status.all_connected"))
    }

    func testStatusTextWhenSomeConnected() {
        let model = WireGuardStatusModel(
            testing: [
                makeInterface(
                    "wg0",
                    peers: [makePeer("peer-a", handshake: "1 minute ago")]
                ),
                makeInterface(
                    "wg1",
                    peers: [makePeer("peer-b", handshake: "never")]
                ),
            ]
        )

        XCTAssertEqual(model.statusText, L10n.string("status.connected_count", "1", "2"))
    }

    func testMenuTitleWhenActiveAndInactive() {
        let connectedModel = WireGuardStatusModel(testing: [makeInterface("wg0", peers: [makePeer("peer-a", handshake: "1 minute ago")])])
        let disconnectedModel = WireGuardStatusModel(testing: [makeInterface("wg0", peers: [makePeer("peer-b", handshake: "never")])])

        XCTAssertEqual(connectedModel.menuTitle, L10n.string("menu.title.on"))
        XCTAssertEqual(disconnectedModel.menuTitle, L10n.string("menu.title.off"))
    }
}
