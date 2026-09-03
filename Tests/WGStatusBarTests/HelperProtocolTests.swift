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

    func testDecodeOkWithStatePayload() {
        // Ответ `state`: строки всегда из 3 полей через `\t` — у `up` третье
        // поле непустое (utun), у `down` пустое (строка кончается `\t\n`).
        // Проходит те же правила decode, что и дамп: терминатор заголовка
        // обязателен, payload пустой или завершён `\n`.
        let state = "kvmka-ai\tup\tutun2\nkvmka-wg-full\tdown\t\n"
        XCTAssertEqual(
            decode(response: "ok 1 17\n\(state)"),
            .ok(protocolVersion: 1, build: 17, dump: state)
        )
    }

    func testDecodeOkWithEmptyStatePayload() {
        // Пустой payload `state` — конфигов нет: то же правило, что пустой
        // дамп show / успех без payload у up/down.
        XCTAssertEqual(
            decode(response: "ok 1 17\n"),
            .ok(protocolVersion: 1, build: 17, dump: "")
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

    func testDecodeErrConfigUnavailable() {
        // Контракт демона — код без детали; decode умеет и вариант с ней
        // (клиент просмотра деталь игнорирует — закреплено его тестами).
        XCTAssertEqual(
            decode(response: "err 1 18 config-unavailable\n"),
            .err(protocolVersion: 1, build: 18, code: .configUnavailable, detail: nil)
        )
        XCTAssertEqual(
            decode(response: "err 1 18 config-unavailable leaked detail\n"),
            .err(protocolVersion: 1, build: 18, code: .configUnavailable, detail: "leaked detail")
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
            "err 1 18 configunavailable\n", // опечатка в wire-имени кода config
            "err 1 18 config-unavailable-extra\n", // мусорный хвост в коде
            "ok 1 5 wg-missing\nline", // код ошибки в ok-заголовке — мусор
            "ok 1 9 tunnel-not-found\nline",
            "ok 1 18 config-unavailable\nline",
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
            "ok 1 17\nkvmka\tup\tutun2", // payload state без финального `\n`
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

    func testEncodeStateRequest() {
        // `state` — запрос без аргумента: одно слово + `\n`, как show/list.
        XCTAssertEqual(encode(.state), "state\n")
    }

    func testEncodeConfigRequest() {
        XCTAssertEqual(encode(.config("work-vpn")), "config work-vpn\n")
    }

    func testEncodeIsExhaustiveOverRequestCases() {
        // Свитч encode исчерпывающий: raw-запроса в протоколе нет — enum
        // содержит show/list/state/up/down/config, и все шесть кодируются.
        // Появление седьмого кейса сломает компиляцию свитча, а не молчание.
        let requests: [HelperRequest] = [.show, .list, .state, .up("a"), .down("b"), .config("c")]
        XCTAssertEqual(
            Set(requests.map(encode)),
            Set(["show\n", "list\n", "state\n", "up a\n", "down b\n", "config c\n"])
        )
    }

    // MARK: - Константы версий

    func testVersionConstantsArePositive() {
        // Оба числа уходят в wire-заголовок — стартуют с 1 и только растут.
        XCTAssertGreaterThan(helperProtocolVersion, 0)
        XCTAssertGreaterThan(helperBuildNumber, 0)
    }

    // MARK: - Конверт b64

    func testEnvelopeRoundTripsExactTextWithAndWithoutFinalNewline() {
        for text in ["[Interface]\nPrivateKey = abc\n", "[Interface]\nListenPort = 51820", ""] {
            let payload = ConfigEnvelope.encode(text)
            switch ConfigEnvelope.decode(payload) {
            case .success(let decoded):
                XCTAssertEqual(decoded, text, "текст проходит конверт байт-в-байт")
            case .failure(let error):
                XCTFail("конверт должен разбираться для \(text.debugDescription): \(error)")
            }
        }
    }

    func testEnvelopeEncodesEmptyDocumentAsBareTag() {
        // Пустой документ — валидный конверт `b64:\n` (base64 пустоты пуст),
        // а не отсутствующий payload: пустой файл отличим от «нет ответа».
        XCTAssertEqual(ConfigEnvelope.encode(""), "b64:\n")
    }

    func testEnvelopeRejectsAbsentTagExtraLinesAndMalformedBase64() {
        let badPayloads = [
            "", // конверта нет
            "b64:", // без терминатора — усечён
            "AAAA\n", // нет тега
            "b64:AAAA\nAAAA\n", // вторая строка payload
            "b64:AA\nAA\n", // \n внутри закодированной части
            "b64:AAA\rAA\n", // \r внутри закодированной части
            "b64:AAA\n", // длина не кратна 4
            "b64:AA=A\n", // = в середине
            "b64:====\n", // больше двух =
            "b64:AA A\n", // пробел — не алфавит
            "b64:AAAA-\n", // urlsafe-символ — не алфавит
        ]
        for payload in badPayloads {
            if case .success = ConfigEnvelope.decode(payload) {
                XCTFail("конверт должен быть отвергнут: \(payload.debugDescription)")
            }
        }
    }

    func testEnvelopeRejectsNonCanonicalBase64() {
        // Неканоничные хвосты: алфавит, длина и позиция `=` валидны, но
        // неиспользуемые биты паддинга не нули — `AB==`/`AAB=` декодируются
        // теми же байтами, что каноничные `AA==`/`AAA=`. Наш кодировщик
        // порождает только каноничную форму, всё неканоничное — мусор канала.
        let nonCanonical = ["AB==", "AP==", "AAB=", "AAF="]
        for encoded in nonCanonical {
            guard case .failure(.malformedBase64) = ConfigEnvelope.decode("b64:\(encoded)\n") else {
                XCTFail("неканоничный base64 должен давать malformedBase64: \(encoded)")
                continue
            }
        }
        // Каноничные близнецы тех же байтов проходят — отсеивается именно
        // неканоничность формы, а не сами байты.
        for encoded in ["AA==", "AAA="] {
            guard case .success = ConfigEnvelope.decode("b64:\(encoded)\n") else {
                XCTFail("каноничный base64 должен разбираться: \(encoded)")
                continue
            }
        }
    }

    func testEnvelopeRejectsDecodedDataOverReaderLimit() {
        // Декодированное содержимое обязано влезать в лимит ридера: конверт
        // с большим телом — мусор канала, а не документ.
        let oversized = String(
            repeating: "A",
            count: TunnelConfigReader.maxSizeBytes + 1
        )
        guard case .failure(.oversized) = ConfigEnvelope.decode(ConfigEnvelope.encode(oversized)) else {
            XCTFail("конверт сверх лимита ридера должен давать oversized")
            return
        }
    }

    func testEnvelopeRejectsInvalidUTF8Payload() {
        // Валидный base64 из невалидного UTF-8: документом быть не может.
        let invalid = Data([0x41, 0xFF, 0x42]).base64EncodedString()
        guard case .failure(.invalidUTF8) = ConfigEnvelope.decode("b64:\(invalid)\n") else {
            XCTFail("не-UTF8 тело конверта должно давать invalidUTF8")
            return
        }
    }
}
