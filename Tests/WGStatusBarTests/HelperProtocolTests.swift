import XCTest
@testable import WGStatusBarCore

final class HelperProtocolTests: XCTestCase {
    private static let dump =
        "wg0\tSECRETPRIVATEKEY\tpub-key-1\t0\t(none)\n" +
        "wg0\tpub-key-1\tSECRETPSK\tendpoint.example:51820\t10.0.0.0/24\t0\t0\t0\toff"

    // MARK: - decode: ok

    func testDecodeOkReturnsVersionsAndDump() {
        let response = decode(response: "ok 1 5\n\(Self.dump)")
        XCTAssertEqual(response, .ok(protocolVersion: 1, build: 5, dump: Self.dump))
    }

    func testDecodeOkWithEmptyDump() {
        XCTAssertEqual(
            decode(response: "ok 1 5\n"),
            .ok(protocolVersion: 1, build: 5, dump: "")
        )
    }

    func testDecodeOkKeepsDumpVerbatimIncludingTrailingNewline() {
        // Демон отправляет дамп как есть — с финальным переводом строки от `wg`.
        let response = decode(response: "ok 2 7\nline1\nline2\n")
        XCTAssertEqual(response, .ok(protocolVersion: 2, build: 7, dump: "line1\nline2\n"))
    }

    // MARK: - decode: err

    func testDecodeErrWgMissing() {
        XCTAssertEqual(
            decode(response: "err 1 5 wg-missing"),
            .err(protocolVersion: 1, build: 5, code: .wgMissing, detail: nil)
        )
    }

    func testDecodeErrWgFailedWithDetail() {
        XCTAssertEqual(
            decode(response: "err 1 5 wg-failed wg exited with status 3"),
            .err(protocolVersion: 1, build: 5, code: .wgFailed, detail: "wg exited with status 3")
        )
    }

    func testDecodeErrWgFailedWithoutDetail() {
        XCTAssertEqual(
            decode(response: "err 3 9 wg-failed"),
            .err(protocolVersion: 3, build: 9, code: .wgFailed, detail: nil)
        )
    }

    // MARK: - decode: мусор → nil

    func testDecodeMalformedResponseReturnsNil() {
        let malformed = [
            "",
            "\n",
            "hello\nworld",
            "ok",
            "ok 1",
            "ok abc 5\nline",
            "ok 1 5 extra\nline",
            "OK 1 5\nline",
            "err",
            "err 1",
            "err 1 5",
            "err 1 5 unknown-code",
            "err abc 5 wg-missing",
            "err 1 xyz wg-failed",
            "ok 1 5 wg-missing\nline", // код ошибки в ok-заголовке — мусор
        ]
        for response in malformed {
            XCTAssertNil(
                decode(response: response),
                "ожидался nil для ответа \(response.debugDescription)"
            )
        }
    }

    // MARK: - encode

    func testEncodeShowRequest() {
        XCTAssertEqual(encode(.show), "show\n")
    }

    // MARK: - Константы версий

    func testVersionConstantsArePositive() {
        // Оба числа уходят в wire-заголовок — стартуют с 1 и только растут.
        XCTAssertGreaterThan(helperProtocolVersion, 0)
        XCTAssertGreaterThan(helperBuildNumber, 0)
    }
}
