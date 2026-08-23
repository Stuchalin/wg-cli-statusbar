import XCTest
@testable import WGStatusBarCore

final class DumpSanitizerTests: XCTestCase {
    /// Реалистичный дамп: два интерфейса, у первого два пира (один без endpoint).
    private static let rawDump =
        "wg0\tSECRET-PRIVATE-KEY-1\tpub-key-1\t51820\t(none)\n" +
        "wg0\tpub-key-1\tSECRET-PSK-1\tendpoint.example:51820\t10.0.0.0/24\t1755900000\t1024\t2048\toff\n" +
        "wg0\tpub-key-2\tSECRET-PSK-2\t(none)\t(none)\t0\t0\t0\toff\n" +
        "wg1\tSECRET-PRIVATE-KEY-2\tpub-key-3\t0\t0x1234\n" +
        "wg1\tpub-key-3\tSECRET-PSK-3\tpeer.example:51820\t0.0.0.0/0\t1755900100\t999\t1\t25"

    // MARK: - секретные поля

    func testSanitizeReplacesSecretFieldsWithNone() {
        let expected =
            "wg0\t(none)\tpub-key-1\t51820\t(none)\n" +
            "wg0\tpub-key-1\t(none)\tendpoint.example:51820\t10.0.0.0/24\t1755900000\t1024\t2048\toff\n" +
            "wg0\tpub-key-2\t(none)\t(none)\t(none)\t0\t0\t0\toff\n" +
            "wg1\t(none)\tpub-key-3\t0\t0x1234\n" +
            "wg1\tpub-key-3\t(none)\tpeer.example:51820\t0.0.0.0/0\t1755900100\t999\t1\t25"

        let sanitized = sanitizeWGDump(Self.rawDump)
        XCTAssertEqual(sanitized, expected)
        XCTAssertFalse(sanitized.contains("SECRET"), "секреты не должны покидать санитайзер")
    }

    func testSanitizeAlreadySanitizedDumpIsStable() {
        // Идемпотентность: повторная санизация ничего не меняет.
        let once = sanitizeWGDump(Self.rawDump)
        XCTAssertEqual(sanitizeWGDump(once), once)
    }

    // MARK: - нетронутые входы (трекинг как у парсера)

    func testSanitizePassesThroughShortGarbageUntouched() {
        let untouched = [
            "", // пустой дамп
            "\n",
            "\n\n",
            "some garbage line",
            "a\tb\tc", // 3 поля
        ]
        for dump in untouched {
            XCTAssertEqual(
                sanitizeWGDump(dump),
                dump,
                "ожидался вход нетронутым: \(dump.debugDescription)"
            )
        }
    }

    /// Fail-closed: строка из 5+ полей нераспознанной формы — мусор это или
    /// дрейф формата `wg` (добавленное поле после обновления wireguard-tools) —
    /// не уносит секреты: позиция секрета неизвестна, вычищаются оба слота.
    func testSanitizeScrubsSecretSlotsOfUnrecognizedLongLines() {
        let cases: [(input: String, expected: String)] = [
            // 6 полей — не интерфейс, но private key на слоте интерфейса.
            (
                "wg0\tSECRET-PRIVATE-KEY\tpub-key-1\t51820\t(none)\tEXTRA",
                "wg0\t(none)\t(none)\t51820\t(none)\tEXTRA"
            ),
            // 9-полевая строка ДО строки интерфейса — не пир, psk на слоте пира.
            (
                "wg0\tpub-key-1\tSECRET-PSK\tendpoint.example:51820\t10.0.0.0/24\t0\t0\t0\toff",
                "wg0\t(none)\t(none)\tendpoint.example:51820\t10.0.0.0/24\t0\t0\t0\toff"
            ),
            // 10 полей — мусор по формату (или дрейфнувший пир), psk на слоте пира.
            (
                "wg0\tpub-key-1\tSECRET-PSK\tendpoint.example:51820\t10.0.0.0/24\t0\t0\t0\toff\tEXTRA",
                "wg0\t(none)\t(none)\tendpoint.example:51820\t10.0.0.0/24\t0\t0\t0\toff\tEXTRA"
            ),
        ]
        for testCase in cases {
            let sanitized = sanitizeWGDump(testCase.input)
            XCTAssertEqual(
                sanitized,
                testCase.expected,
                "вход: \(testCase.input.debugDescription)"
            )
            XCTAssertFalse(sanitized.contains("SECRET"), "секреты не должны покидать санитайзер")
            XCTAssertEqual(sanitizeWGDump(sanitized), sanitized, "санитизация идемпотентна")
        }
    }

    func testSanitizeKeepsTrailingNewline() {
        // `wg` завершает вывод переводом строки — он не должен теряться.
        let sanitized = sanitizeWGDump("wg0\tSECRET-PRIVATE-KEY\tpub-key-1\t0\t(none)\n")
        XCTAssertEqual(sanitized, "wg0\t(none)\tpub-key-1\t0\t(none)\n")
    }

    func testSanitizeTracksInterfaceAcrossGarbageLines() {
        // Мусорная строка между интерфейсом и пиром не сбрасывает трекинг
        // (парсер держит currentInterface до конца дампа).
        let dump =
            "wg0\tSECRET-PRIVATE-KEY\tpub-key-1\t0\t(none)\n" +
            "garbage\n" +
            "wg0\tpub-key-1\tSECRET-PSK\tendpoint.example:51820\t10.0.0.0/24\t0\t0\t0\toff"

        let expected =
            "wg0\t(none)\tpub-key-1\t0\t(none)\n" +
            "garbage\n" +
            "wg0\tpub-key-1\t(none)\tendpoint.example:51820\t10.0.0.0/24\t0\t0\t0\toff"

        XCTAssertEqual(sanitizeWGDump(dump), expected)
    }

    // MARK: - контракт с парсером

    func testSanitizedDumpParsesToIdenticalModel() {
        // Парсер читает секретные поля мимо — замена на `(none)` не меняет модель.
        XCTAssertEqual(
            parseWGShowDump(sanitizeWGDump(Self.rawDump)),
            parseWGShowDump(Self.rawDump)
        )
    }
}
