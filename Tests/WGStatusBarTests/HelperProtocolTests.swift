import XCTest
@testable import WGStatusBarCore

final class HelperProtocolTests: XCTestCase {
    private static let dump =
        "wg0\tSECRETPRIVATEKEY\tpub-key-1\t0\t(none)\n" +
        "wg0\tpub-key-1\tSECRETPSK\tendpoint.example:51820\t10.0.0.0/24\t0\t0\t0\toff\n"

    // MARK: - decode: ok

    func testDecodeOkReturnsVersionsAndDump() {
        let response = decode(response: "ok 1 5\n\(Self.dump)")
        XCTAssertEqual(response, .ok(protocolVersion: 1, build: 5, dump: Self.dump))
    }

    func testDecodeOkWithEmptyDump() {
        // Пустой payload — это и «интерфейсов нет» для show, и успех up/down
        // (туннельные операции отвечают `ok` без payload).
        XCTAssertEqual(
            decode(response: "ok 1 5\n"),
            .ok(protocolVersion: 1, build: 5, dump: "")
        )
    }

    func testDecodeOkWithNameListPayload() {
        // Ответ `list`: имена по одному в строке, каждое завершено `\n` —
        // проходит те же правила, что и дамп show.
        let names = "kvmka-ai\nkvmka-full\n"
        XCTAssertEqual(
            decode(response: "ok 1 9\n\(names)"),
            .ok(protocolVersion: 1, build: 9, dump: names)
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
            decode(response: "err 1 5 wg-missing\n"),
            .err(protocolVersion: 1, build: 5, code: .wgMissing, detail: nil)
        )
    }

    func testDecodeErrWgFailedWithDetail() {
        XCTAssertEqual(
            decode(response: "err 1 5 wg-failed wg exited with status 3\n"),
            .err(protocolVersion: 1, build: 5, code: .wgFailed, detail: "wg exited with status 3")
        )
    }

    func testDecodeErrWgFailedWithoutDetail() {
        XCTAssertEqual(
            decode(response: "err 3 9 wg-failed\n"),
            .err(protocolVersion: 3, build: 9, code: .wgFailed, detail: nil)
        )
    }

    func testDecodeErrQuickMissing() {
        // Демон шлёт этот код без детали (stderr wg-quick остаётся в его логе),
        // но decode умеет и вариант с ней.
        XCTAssertEqual(
            decode(response: "err 1 9 wg-quick-missing\n"),
            .err(protocolVersion: 1, build: 9, code: .quickMissing, detail: nil)
        )
        XCTAssertEqual(
            decode(response: "err 1 9 wg-quick-missing not in search paths\n"),
            .err(protocolVersion: 1, build: 9, code: .quickMissing, detail: "not in search paths")
        )
    }

    func testDecodeErrTunnelNotFound() {
        XCTAssertEqual(
            decode(response: "err 1 9 tunnel-not-found\n"),
            .err(protocolVersion: 1, build: 9, code: .tunnelNotFound, detail: nil)
        )
        XCTAssertEqual(
            decode(response: "err 1 9 tunnel-not-found no config for name\n"),
            .err(protocolVersion: 1, build: 9, code: .tunnelNotFound, detail: "no config for name")
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
            "err 1 9 wgquick-missing\n", // опечатка в wire-имени нового кода
            "ok 1 5 wg-missing\nline", // код ошибки в ok-заголовке — мусор
            "ok 1 9 tunnel-not-found\nline",
        ]
        for response in malformed {
            XCTAssertNil(
                decode(response: response),
                "ожидался nil для ответа \(response.debugDescription)"
            )
        }
    }

    // MARK: - decode: усечённый ответ → nil

    func testDecodeTruncatedResponseReturnsNil() {
        // Клиент читает до EOF: обрыв записи демона — это «полный» ответ без
        // терминатора заголовка либо с незавершённой последней строкой дампа.
        // Принять его успехом — показать пустой/частичный статус как
        // `installed`; правильный вердикт — битый ответ (broken, следующий
        // тик переспросит).
        let truncated = [
            "ok 1 5", // заголовок без \n — не успех с пустым дампом
            "err 1 5 wg-missing", // err без \n — тоже усечён
            "ok 1 5\nwg0\t(no", // дамп оборван посреди строки
            "ok 1 5\nline1\nline2", // дамп без финального перевода строки
        ]
        for response in truncated {
            XCTAssertNil(
                decode(response: response),
                "ожидался nil для усечённого ответа \(response.debugDescription)"
            )
        }
    }

    // MARK: - encode

    func testEncodeShowRequest() {
        XCTAssertEqual(encode(.show), "show\n")
    }

    func testEncodeTunnelRequests() {
        XCTAssertEqual(encode(.list), "list\n")
        XCTAssertEqual(encode(.up("kvmka-ai")), "up kvmka-ai\n")
        XCTAssertEqual(encode(.down("kvmka-full")), "down kvmka-full\n")
    }

    // MARK: - Константы версий

    func testVersionConstantsArePositive() {
        // Оба числа уходят в wire-заголовок — стартуют с 1 и только растут.
        XCTAssertGreaterThan(helperProtocolVersion, 0)
        XCTAssertGreaterThan(helperBuildNumber, 0)
    }
}
