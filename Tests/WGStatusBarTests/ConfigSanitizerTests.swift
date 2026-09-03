import XCTest
@testable import WGStatusBarCore

/// Маскирование канонических назначений PrivateKey/PresharedKey в тексте
/// конфига: значение → `(hidden)`, всё остальное — байт-в-байт.
final class ConfigSanitizerTests: XCTestCase {
    // MARK: - маскирование назначений

    func testMasksPrivateKeyAndPresharedKeyValues() {
        let config = "[Interface]\nPrivateKey = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n[Peer]\nPresharedKey = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n"
        let expected = "[Interface]\nPrivateKey = (hidden)\n[Peer]\nPresharedKey = (hidden)\n"

        XCTAssertEqual(sanitizeWGQuickConfig(config), expected)
    }

    func testMaskingIsCaseInsensitiveWithStableShape() {
        // Ключ сохраняется как написан, форма вывода стабильна:
        // `<ключ> = (hidden)` — независимо от пробелов в оригинале.
        let config = "PRIVATEKEY=abcdef=\n  presharedkey = fedcba"
        let expected = "PRIVATEKEY = (hidden)\npresharedkey = (hidden)"

        XCTAssertEqual(sanitizeWGQuickConfig(config), expected)
    }

    func testValueWithEqualsSignsIsMaskedEntirely() {
        // base64-значение с `=` внутри и в конце: разделитель — первый `=`,
        // хвост целиком уходит в значение.
        XCTAssertEqual(
            sanitizeWGQuickConfig("PrivateKey = a=b=c="),
            "PrivateKey = (hidden)"
        )
    }

    func testEmptySecretValueIsMasked() {
        XCTAssertEqual(
            sanitizeWGQuickConfig("PrivateKey ="),
            "PrivateKey = (hidden)"
        )
    }

    // MARK: - не-назначения проходят как есть

    func testCommentLinesAreNotMasked() {
        let config = "# PrivateKey = realsecret\n  # отступ перед комментарием\n# просто комментарий\n"

        XCTAssertEqual(sanitizeWGQuickConfig(config), config)
    }

    func testHookValuesContainingKeyNamesAreNotMasked() {
        let config = "PostUp = echo PrivateKey is none of your business\nPreDown = wg syncconf PresharedKey\n"

        XCTAssertEqual(sanitizeWGQuickConfig(config), config)
    }

    func testUnknownDirectivesAndSectionsPassThrough() {
        let config = "[Interface]\n[Peer]\nNotAKey = something\nJust a bare line\n"

        XCTAssertEqual(sanitizeWGQuickConfig(config), config)
    }

    func testNonSecretAssignmentsKeepExactBytes() {
        let config = "Address = 10.0.0.1/24\nAddress= 10.0.0.1/24\nAllowedIPs = 0.0.0.0/0, ::/0\nEndpoint = vpn.example.com:51820\n"

        XCTAssertEqual(sanitizeWGQuickConfig(config), config)
    }

    func testNoFalsePositivesOnSimilarKeys() {
        // Похоже на ключ по вхождению, но не равно ему — не назначение
        // секретного ключа, остаётся как есть.
        let config = "MyPrivateKey = x\nPresharedKeys = y\nPrivateKeyExtra = z\nPrivateKeyWithoutAssignment\n"

        XCTAssertEqual(sanitizeWGQuickConfig(config), config)
    }

    // MARK: - структура документа

    func testBlankLinesAndFinalNewlineStatePreserved() {
        XCTAssertEqual(
            sanitizeWGQuickConfig("A = 1\n\nPrivateKey = s\n"),
            "A = 1\n\nPrivateKey = (hidden)\n"
        )
        XCTAssertEqual(
            sanitizeWGQuickConfig("A = 1\nPrivateKey = s"),
            "A = 1\nPrivateKey = (hidden)"
        )
    }

    func testEmptyConfigSanitizesToEmpty() {
        XCTAssertEqual(sanitizeWGQuickConfig(""), "")
    }

    func testFullDocumentRoundTrip() {
        let config = """
        [Interface]
        # домашний туннель
        Address = 10.10.0.2/32
        PrivateKey = eH DennisDenisDenisDenisDenisDenisDenis=
        DNS = 10.10.0.1
        PostUp = /usr/local/bin/notify-up home

        [Peer]
        PublicKey = pubpubpubpubpubpubpubpubpubpubpubpub=
        PresharedKey = pspspspspspspspspspspspspspspsspsp=
        AllowedIPs = 0.0.0.0/0, ::/0
        Endpoint = vpn.example.com:51820
        PersistentKeepalive = 25
        """
        let expected = """
        [Interface]
        # домашний туннель
        Address = 10.10.0.2/32
        PrivateKey = (hidden)
        DNS = 10.10.0.1
        PostUp = /usr/local/bin/notify-up home

        [Peer]
        PublicKey = pubpubpubpubpubpubpubpubpubpubpubpub=
        PresharedKey = (hidden)
        AllowedIPs = 0.0.0.0/0, ::/0
        Endpoint = vpn.example.com:51820
        PersistentKeepalive = 25
        """

        XCTAssertEqual(sanitizeWGQuickConfig(config), expected)
    }

    // MARK: - граница роста

    /// Санитизация удлиняет документ: строка-назначение не короче `PrivateKey=`
    /// (11 байт) становится `<ключ> = (hidden)` (22 байта) — рост не больше 2×.
    /// Патологический файл сплошных минимальных назначений в пределах лимита
    /// ридера обязан оставаться в пределах `maxSanitizedConfigBytes` — из этой
    /// границы клиент выводит свой потолок байт ответа.
    func testSanitizedGrowthStaysWithinMaxSanitizedBytes() {
        let raw = String(repeating: "PrivateKey=x\n", count: 20_000)
        let masked = sanitizeWGQuickConfig(raw)

        XCTAssertGreaterThan(masked.utf8.count, raw.utf8.count, "минимальные назначения удлиняют текст")
        XCTAssertLessThanOrEqual(
            masked.utf8.count,
            maxSanitizedConfigBytes,
            "рост маскированного текста не выходит за 2×-границу"
        )
        XCTAssertEqual(
            maxSanitizedConfigBytes,
            2 * TunnelConfigReader.maxSizeBytes,
            "граница выведена из лимита ридера с запасом ровно 2×"
        )
    }
}
