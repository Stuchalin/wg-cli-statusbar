import AppKit
import XCTest
@testable import WGStatusBarCore

/// Окно настроек: триггер активации приложения перечитывает статус
/// логин-айтема, а все строки окна и пункта меню есть в обеих таблицах.
/// Окно (`NSWindow`) здесь не создаётся — только обсервер активации через
/// инжектированный `NotificationCenter` и мок границы.
final class SettingsWindowTests: XCTestCase {
    /// Минимальный мок: статус программируется тестом, чтения считаются.
    private final class StatusOnlyLoginItem: LoginItemManaging {
        var statusValue: LoginItemStatus
        private(set) var statusReads = 0

        init(status: LoginItemStatus) { statusValue = status }

        var status: LoginItemStatus {
            statusReads += 1
            return statusValue
        }

        func register() throws {}
        func unregister() throws {}
        func openSystemSettingsLoginItems() {}
    }

    // MARK: - Перечитывание статуса на активации приложения

    /// Пользователь поменял Login Items в System Settings и вернулся:
    /// активация приложения перечитывает статус, окно показывает систему.
    func testAppActivationRereadsLoginItemStatus() {
        let loginItem = StatusOnlyLoginItem(status: .notRegistered)
        let model = SettingsModel(loginItem: loginItem, isAppBundle: true)
        let center = NotificationCenter()
        let controller = SettingsWindowController(model: model, notificationCenter: center)
        XCTAssertEqual(loginItem.statusReads, 0, "создание контроллера статус не читает")

        loginItem.statusValue = .enabled
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        XCTAssertEqual(loginItem.statusReads, 1, "активация перечитывает статус")
        XCTAssertEqual(model.displayState, .on)

        loginItem.statusValue = .requiresApproval
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        XCTAssertEqual(loginItem.statusReads, 2, "каждая активация — новое чтение")
        XCTAssertEqual(model.displayState, .requiresApproval)
        withExtendedLifetime(controller) {}
    }

    /// Чужие уведомления статус не трогают.
    func testUnrelatedNotificationDoesNotRereadStatus() {
        let loginItem = StatusOnlyLoginItem(status: .notRegistered)
        let model = SettingsModel(loginItem: loginItem, isAppBundle: true)
        let center = NotificationCenter()
        let controller = SettingsWindowController(model: model, notificationCenter: center)

        center.post(name: NSApplication.didResignActiveNotification, object: nil)

        XCTAssertEqual(loginItem.statusReads, 0)
        withExtendedLifetime(controller) {}
    }

    /// Уничтоженный контроллер отписан: активация больше не читает статус.
    func testDeallocatedControllerStopsObservingActivation() {
        let loginItem = StatusOnlyLoginItem(status: .notRegistered)
        let model = SettingsModel(loginItem: loginItem, isAppBundle: true)
        let center = NotificationCenter()
        var controller: SettingsWindowController? = SettingsWindowController(model: model, notificationCenter: center)
        XCTAssertNotNil(controller)
        controller = nil

        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        XCTAssertEqual(loginItem.statusReads, 0)
    }

    // MARK: - Локализация окна и пункта меню

    /// Строки окна настроек и пункта меню (строки модели — в
    /// `SettingsModelTests`).
    static let windowKeys = [
        "button.settings",
        "settings.window.title",
        "settings.section.general",
        "settings.launch_at_login.toggle",
        "settings.launch_at_login.approval_hint",
        "settings.launch_at_login.open_login_items",
    ]

    func testEverySettingsWindowKeyPresentAndNonEmptyInBothLocalizations() throws {
        for language in ["en", "ru"] {
            let lprojPath = try XCTUnwrap(
                Bundle.module.path(forResource: language, ofType: "lproj"),
                "нет \(language).lproj в бандле модуля"
            )
            let bundle = try XCTUnwrap(Bundle(path: lprojPath))
            for key in Self.windowKeys {
                // При отсутствии ключа localizedString возвращает value —
                // сам ключ служит маркером пропуска.
                let value = bundle.localizedString(forKey: key, value: key, table: "Localizable")
                XCTAssertNotEqual(value, key, "ключ \(key) отсутствует в \(language).lproj/Localizable.strings")
                XCTAssertFalse(value.isEmpty, "значение ключа \(key) в \(language) пустое")
            }
        }
    }
}
