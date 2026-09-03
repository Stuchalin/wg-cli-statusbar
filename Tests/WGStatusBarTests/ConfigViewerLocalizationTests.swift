import XCTest
@testable import WGStatusBarCore

/// Локализация вьювера: каждая таблица (en, ru) содержит все ключи окна,
/// аутентификации, категорий ошибок и accessibility, и значения непусты.
final class ConfigViewerLocalizationTests: XCTestCase {
    /// Все ключи вьювера конфига: окно/кнопки/прогресс/режим, ошибки
    /// загрузки, Reveal (Task 3) и accessibility обеих кнопок строки.
    static let viewerKeys = [
        // Окно вьювера
        "config.viewer.title",
        "config.viewer.reload",
        "config.viewer.reveal",
        "config.viewer.hide",
        "config.viewer.loading",
        "config.viewer.revealing",
        "config.viewer.masked_badge",
        "config.viewer.raw_badge",
        // Ошибки загрузки
        "config.error.load_failed",
        "config.error.unavailable",
        // Аутентификация Reveal
        "config.auth.reason",
        "config.auth.cancel",
        // Категории ошибок Reveal
        "config.reveal.error.service_install",
        "config.reveal.error.service_update",
        "config.reveal.error.invalid_name",
        "config.reveal.error.helper_unavailable",
        "config.reveal.error.helper_outdated",
        "config.reveal.error.auth_failed",
        "config.reveal.error.auth_unavailable",
        "config.reveal.error.read_failed",
        // Accessibility
        "tunnel.accessibility.details",
        "tunnel.accessibility.on",
        "tunnel.accessibility.off",
    ]

    /// Заголовок окна подставляет имя туннеля — формат обязан сохраниться
    /// в обеих таблицах.
    func testTitleKeyKeepsFormatSpecifierInBothLocalizations() throws {
        for language in ["en", "ru"] {
            let bundle = try localizationBundle(for: language)
            let title = bundle.localizedString(forKey: "config.viewer.title", value: "", table: "Localizable")
            XCTAssertTrue(
                title.contains("%@"),
                "заголовок окна в \(language) обязан подставлять имя: «\(title)»"
            )
        }
    }

    func testEveryViewerKeyPresentAndNonEmptyInBothLocalizations() throws {
        for language in ["en", "ru"] {
            let bundle = try localizationBundle(for: language)
            for key in Self.viewerKeys {
                // localizedString(forKey:value:) при отсутствии ключа
                // возвращает value — прокидываем сам ключ как маркер пропуска.
                let raw = bundle.localizedString(forKey: key, value: key, table: "Localizable")
                XCTAssertNotEqual(raw, key, "ключ \(key) отсутствует в \(language).lproj/Localizable.strings")
                XCTAssertFalse(raw.isEmpty, "значение ключа \(key) в \(language) пустое")
            }
        }
    }

    private func localizationBundle(for language: String) throws -> Bundle {
        let lprojPath = try XCTUnwrap(
            Bundle.module.path(forResource: language, ofType: "lproj"),
            "нет \(language).lproj в бандле модуля"
        )
        return try XCTUnwrap(Bundle(path: lprojPath))
    }
}
