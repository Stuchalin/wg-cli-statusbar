import XCTest
@testable import WGStatusBarCore

/// One-shot-режим бинаря хелпера: чистый разбор argv (исчерпывающе — все
/// допустимые и недопустимые формы), побочный-эффект-свободный capability-
/// ответ и raw-чтение через общий безопасный ридер в одном `b64:`-конверте.
final class HelperOneShotTests: XCTestCase {
    /// Минимальный фейк FS ридера: один открываемый конфиг с содержимым.
    private final class SingleConfigFileSystem: TunnelConfigReaderFileSystem {
        let path: String
        let content: [UInt8]
        private(set) var openCount = 0

        init(path: String, content: [UInt8]) {
            self.path = path
            self.content = content
        }

        func openFileNoFollow(atPath path: String) -> TunnelConfigOpenOutcome {
            guard path == self.path else { return .notFound }
            openCount += 1
            return .opened(OneShotHandle(content: content))
        }
    }

    private final class OneShotHandle: TunnelConfigReaderFileHandle {
        let content: [UInt8]
        private var offset = 0

        init(content: [UInt8]) {
            self.content = content
        }

        var isRegularFile: Bool { true }

        func read(into buffer: UnsafeMutableRawPointer, maxLength: Int) -> TunnelConfigReadChunk {
            guard offset < content.count else { return .endOfFile }
            let count = min(maxLength, content.count - offset)
            content.withUnsafeBytes { raw in
                _ = memcpy(buffer, raw.baseAddress!.advanced(by: offset), count)
            }
            offset += count
            return .bytes(count)
        }

        func close() {}
    }

    private let configPath = "/etc/wireguard/work.conf"

    private func reader(with text: String) -> TunnelConfigReader {
        TunnelConfigReader(
            searchPaths: ["/etc/wireguard"],
            fileSystem: SingleConfigFileSystem(path: configPath, content: Array(text.utf8))
        )
    }

    /// Декодирует конверт обратно в текст — допущение только для сверки
    /// round-trip в тестах; продакшн-клиенты используют ConfigEnvelope.
    private func decoded(_ envelope: String) -> String {
        switch ConfigEnvelope.decode(envelope) {
        case .success(let text):
            return text
        case .failure(let error):
            XCTFail("конверт one-shot обязан декодироваться: \(error)")
            return ""
        }
    }

    // MARK: - разбор argv

    func testNoArgumentsSelectDaemonMode() {
        XCTAssertEqual(parseHelperArgv([]), .daemon)
    }

    func testExactCapabilitiesFlagSelectsCapabilitiesMode() {
        XCTAssertEqual(parseHelperArgv(["--capabilities"]), .capabilities)
    }

    func testExactPrintConfigRawWithNameSelectsRawMode() {
        XCTAssertEqual(parseHelperArgv(["--print-config-raw", "work-vpn"]), .printConfigRaw("work-vpn"))
        XCTAssertEqual(parseHelperArgv(["--print-config-raw", "a"]), .printConfigRaw("a"))
    }

    func testPrintConfigRawWithoutNameIsInvalid() {
        XCTAssertEqual(parseHelperArgv(["--print-config-raw"]), .invalid)
    }

    func testPrintConfigRawWithEmptyNameIsInvalid() {
        XCTAssertEqual(parseHelperArgv(["--print-config-raw", ""]), .invalid)
    }

    func testPrintConfigRawWithExtraArgumentsIsInvalid() {
        XCTAssertEqual(parseHelperArgv(["--print-config-raw", "a", "b"]), .invalid)
        XCTAssertEqual(parseHelperArgv(["--print-config-raw", "a", "--capabilities"]), .invalid)
    }

    func testUnknownFlagIsInvalid() {
        XCTAssertEqual(parseHelperArgv(["--version"]), .invalid)
        XCTAssertEqual(parseHelperArgv(["daemon"]), .invalid)
        XCTAssertEqual(parseHelperArgv(["-h"]), .invalid)
    }

    func testCapabilitiesWithExtraArgumentsIsInvalid() {
        XCTAssertEqual(parseHelperArgv(["--capabilities", "x"]), .invalid)
    }

    // MARK: - capability-ответ

    func testCapabilitiesOutputIsOneExactLine() {
        let output = helperCapabilitiesOutput()
        XCTAssertTrue(output.hasSuffix("\n"), "терминатор строки обязателен")
        let line = String(output.dropLast())
        XCTAssertFalse(line.contains("\n"), "ровно одна строка")
        let tokens = line.split(separator: " ").map(String.init)
        XCTAssertEqual(tokens.count, 4)
        XCTAssertEqual(tokens[0], "capabilities")
        XCTAssertEqual(tokens[1], String(helperProtocolVersion), "текущий протокол")
        XCTAssertEqual(tokens[2], String(helperBuildNumber), "текущий build")
        XCTAssertEqual(tokens[3], helperConfigRawCapabilityToken, "токен config-raw-v1")
    }

    func testCapabilitiesOutputPassesPreflightParser() {
        XCTAssertNil(
            PrivilegedConfigReader.parseCapabilitiesOutput(helperCapabilitiesOutput()),
            "собственный ответ бинаря обязан проходить строгий разбор префлайта"
        )
    }

    // MARK: - one-shot raw-чтение

    func testRawReadReturnsEnvelopeOfExactText() {
        let text = "[Interface]\nPrivateKey = base64value\nAllowedIPs = 10.0.0.1/32\n"
        switch runHelperOneShotRawRead(named: "work", reader: reader(with: text)) {
        case .success(let envelope):
            XCTAssertEqual(envelope.hasPrefix(ConfigEnvelope.tag + ""), true, "конверт начинается с тега")
            XCTAssertTrue(envelope.hasSuffix("\n"), "терминатор конверта")
            XCTAssertEqual(decoded(envelope), text, "raw-текст возвращается байт-в-байт, включая финальный \\n")
        case .failure:
            XCTFail("полное чтение — успех")
        }
    }

    func testRawReadPreservesMissingFinalNewline() {
        let text = "[Interface]\nListenPort = 51820"
        switch runHelperOneShotRawRead(named: "work", reader: reader(with: text)) {
        case .success(let envelope):
            XCTAssertFalse(decoded(envelope).hasSuffix("\n"), "отсутствие финального \\n сохраняется")
        case .failure:
            XCTFail("полное чтение — успех")
        }
    }

    func testRawReadOfEmptyFileIsTagOnlyEnvelope() {
        switch runHelperOneShotRawRead(named: "work", reader: reader(with: "")) {
        case .success(let envelope):
            XCTAssertEqual(envelope, ConfigEnvelope.tag + "\n", "пустой документ — конверт из одного тега")
        case .failure:
            XCTFail("пустой файл — валидный пустой документ")
        }
    }

    func testRawReadEnvelopeCarriesBase64NotPlaintext() {
        let rawPlaintext = "PLAINTEXT-RAW-VALUE-0123456789"
        let text = "PrivateKey = \(rawPlaintext)\n"
        switch runHelperOneShotRawRead(named: "work", reader: reader(with: text)) {
        case .success(let envelope):
            XCTAssertFalse(
                envelope.contains(rawPlaintext),
                "конверт несёт base64 — открытый текст не появляется на транспорте"
            )
        case .failure:
            XCTFail("полное чтение — успех")
        }
    }

    func testRawReadInvalidNameFailsWithFixedCategory() {
        switch runHelperOneShotRawRead(named: "bad name!", reader: reader(with: "x")) {
        case .success:
            XCTFail("недопустимое имя — отказ")
        case .failure(let stderrLine, let exitStatus):
            XCTAssertEqual(stderrLine, HelperOneShotErrorCategory.invalidName)
            XCTAssertNotEqual(exitStatus, 0)
            XCTAssertFalse(stderrLine.contains("bad name!"), "категория не содержит имя")
        }
    }

    func testRawReadMissingFileFailsWithFixedCategory() {
        let emptyFS = TunnelConfigReader(
            searchPaths: ["/etc/wireguard"],
            fileSystem: SingleConfigFileSystem(path: "/etc/wireguard/other.conf", content: Array("x".utf8))
        )
        switch runHelperOneShotRawRead(named: "work", reader: emptyFS) {
        case .success:
            XCTFail("отсутствующий файл — отказ")
        case .failure(let stderrLine, let exitStatus):
            XCTAssertEqual(stderrLine, HelperOneShotErrorCategory.configUnavailable)
            XCTAssertNotEqual(exitStatus, 0)
        }
    }

    func testRawReadOversizedFileFailsWithoutPartialContent() {
        let bigText = String(repeating: "a", count: TunnelConfigReader.maxSizeBytes + 1)
        switch runHelperOneShotRawRead(named: "work", reader: reader(with: bigText)) {
        case .success:
            XCTFail("файл за лимитом — отказ")
        case .failure(let stderrLine, let exitStatus):
            XCTAssertEqual(stderrLine, HelperOneShotErrorCategory.configUnavailable)
            XCTAssertNotEqual(exitStatus, 0)
        }
    }
}
