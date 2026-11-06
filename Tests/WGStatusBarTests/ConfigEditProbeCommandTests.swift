import XCTest

final class ConfigEditProbeCommandTests: XCTestCase {
    func testApostropheIsEscapedAsShellData() {
        XCTAssertEqual(ConfigEditProbeCommand.shellQuoted("a'b"), "'a'\\''b'")
    }
}
