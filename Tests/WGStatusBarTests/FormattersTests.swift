import XCTest
@testable import WGStatusBarCore

final class FormattersTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - formatBytes

    func testFormatBytesZero() {
        XCTAssertEqual(Formatters.formatBytes(0), "0 B")
    }

    func testFormatBytesBelowOneKib() {
        XCTAssertEqual(Formatters.formatBytes(512), "512 B")
    }

    func testFormatBytesDoubleDigitKibHasNoFraction() {
        // 897500 байт = 876.46 KiB → ≥10 единиц → 0 знаков
        XCTAssertEqual(Formatters.formatBytes(897_500), "876 KiB")
    }

    func testFormatBytesMibWithFraction() {
        // 1.5 * 1024 * 1024
        XCTAssertEqual(Formatters.formatBytes(1_572_864), "1.5 MiB")
    }

    func testFormatBytesGibDropsTrailingZero() {
        // 3 * 1024^3 → «3 GiB», не «3.0 GiB»
        XCTAssertEqual(Formatters.formatBytes(3_221_225_472), "3 GiB")
    }

    func testFormatBytesExactUnitBoundaries() {
        XCTAssertEqual(Formatters.formatBytes(1_024), "1 KiB")
        XCTAssertEqual(Formatters.formatBytes(1_048_576), "1 MiB")
        XCTAssertEqual(Formatters.formatBytes(1_073_741_824), "1 GiB")
    }

    // MARK: - formatAgo

    func testFormatAgoUnderMinuteUsesSeconds() {
        let date = now.addingTimeInterval(-57)
        XCTAssertEqual(Formatters.formatAgo(date, now: now), L10n.string("ago.seconds", "57"))
    }

    func testFormatAgoMinutes() {
        let date = now.addingTimeInterval(-3 * 60)
        XCTAssertEqual(Formatters.formatAgo(date, now: now), L10n.string("ago.minutes", "3"))
    }

    func testFormatAgoHourWithMinuteRemainderDropsRemainder() {
        // 1 ч 5 мин → крупнейшая единица часы, остаток минут отбрасывается
        let date = now.addingTimeInterval(-(1 * 3600 + 5 * 60))
        XCTAssertEqual(Formatters.formatAgo(date, now: now), L10n.string("ago.hours", "1"))
    }

    func testFormatAgoWholeHours() {
        let date = now.addingTimeInterval(-2 * 3600)
        XCTAssertEqual(Formatters.formatAgo(date, now: now), L10n.string("ago.hours", "2"))
    }

    func testFormatAgoDayAndMoreUsesDays() {
        let dayAndTwoHours = now.addingTimeInterval(-26 * 3600)
        XCTAssertEqual(Formatters.formatAgo(dayAndTwoHours, now: now), L10n.string("ago.days", "1"))

        let week = now.addingTimeInterval(-7 * 24 * 3600)
        XCTAssertEqual(Formatters.formatAgo(week, now: now), L10n.string("ago.days", "7"))
    }

    // MARK: - Локализация ключей ago.*

    func testAgoKeysExistWithPlaceholderInBothLocalizations() throws {
        for language in ["en", "ru"] {
            let lprojPath = try XCTUnwrap(
                Bundle.module.path(forResource: language, ofType: "lproj"),
                "нет \(language).lproj в бандле модуля"
            )
            let bundle = Bundle(path: lprojPath)
            for key in ["ago.seconds", "ago.minutes", "ago.hours", "ago.days"] {
                let raw = bundle?.localizedString(forKey: key, value: "MISSING", table: "Localizable")
                XCTAssertNotEqual(raw, "MISSING", "ключ \(key) отсутствует в \(language)")
                XCTAssertTrue(raw?.contains("%@") == true, "\(language)/\(key) без плейсхолдера %@: \(raw ?? "nil")")
            }
        }
    }
}
