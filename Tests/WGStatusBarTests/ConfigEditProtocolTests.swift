import XCTest
@testable import WGStatusBarCore

final class ConfigEditProtocolTests: XCTestCase {
    private let session = "01234567-89AB-CDEF-0123-456789ABCDEF"

    func testSeparateCapabilitiesPreserveRevealFormat() {
        XCTAssertEqual(parseHelperArgv(["--config-edit-capabilities"]), .configEditCapabilities)
        XCTAssertEqual(helperCapabilitiesOutput(), "capabilities \(helperProtocolVersion) \(helperBuildNumber) config-raw-v1\n")
        XCTAssertEqual(helperConfigEditCapabilitiesOutput(), "config-edit \(helperProtocolVersion) \(helperBuildNumber) config-edit-v1\n")
    }

    func testEditorLaunchRequiresExactValidatedArguments() {
        for (flag, saving) in [("--read-config-edit", false), ("--write-config-edit", true)] {
            guard case .configEdit(let launch) = parseHelperArgv([flag, "work", "501", "123", session]) else {
                return XCTFail("Editor invocation rejected")
            }
            XCTAssertEqual(launch.name, "work")
            XCTAssertEqual(launch.clientUID, 501)
            XCTAssertEqual(launch.clientPID, 123)
            XCTAssertEqual(launch.saving, saving)
            for arguments in [[flag, "../work", "501", "123", session],
                              [flag, "work", "0", "123", session],
                              [flag, "work", "501", "-1", session],
                              [flag, "work", "501", "123", "../bad"],
                              [flag, "work", "501", "123", session, "extra"]] {
                XCTAssertEqual(parseHelperArgv(arguments), .invalid)
            }
        }
    }

    func testWirePreservesHeavyEscapingAndExactDocumentLimit() throws {
        let text = String(repeating: "\u{0001}", count: TunnelConfigReader.maxSizeBytes)
        let message = ConfigEditMessage(kind: .save, text: text, revision: String(repeating: "a", count: 64))
        let encoded = try message.encoded()
        XCTAssertLessThanOrEqual(encoded.utf8.count, ConfigEditMessage.wireLimit)
        XCTAssertEqual(try ConfigEditMessage.decode(encoded), message)
        XCTAssertThrowsError(try ConfigEditMessage.decode("{}"))
        XCTAssertThrowsError(try ConfigEditMessage.decode("{\"kind\":\"unknown\"}"))
    }

    func testHelperSessionDoesNotRunAsOrdinaryUser() throws {
        guard geteuid() != 0 else { throw XCTSkip("Unit tests must not run as root") }
        guard case .configEdit(let launch) = parseHelperArgv(["--read-config-edit", "work", "501", "123", session]) else {
            return XCTFail("Invalid fixture")
        }
        XCTAssertNotEqual(runHelperConfigEditSession(launch), 0)
    }
}
