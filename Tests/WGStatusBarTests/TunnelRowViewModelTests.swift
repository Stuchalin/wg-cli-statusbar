import XCTest
@testable import WGStatusBarCore

final class TunnelRowViewModelTests: XCTestCase {
    // MARK: - Состояния: idle / busy / disabled

    func testIdleRowIsEnabledAndNotBusy() {
        let row = TunnelRowViewModel(name: "kvmka-ai", isUp: true, inFlightTunnels: [])

        XCTAssertEqual(row.name, "kvmka-ai")
        XCTAssertTrue(row.isUp)
        XCTAssertFalse(row.isBusy, "без операций — точки, не спиннер")
        XCTAssertTrue(row.isEnabled)
    }

    func testRowInFlightIsBusyAndDisabled() {
        let row = TunnelRowViewModel(name: "kvmka-ai", isUp: false, inFlightTunnels: ["kvmka-ai"])

        XCTAssertTrue(row.isBusy, "операция над этим туннелем — спиннер в строке")
        XCTAssertFalse(row.isEnabled, "строка с операцией некликабельна")
    }

    /// Одна операция за раз: чужая операция блокирует и эту строку, но
    /// спиннер крутится только у строки с операцией.
    func testOtherRowInFlightDisablesThisRowWithoutSpinner() {
        let row = TunnelRowViewModel(name: "kvmka-ai", isUp: true, inFlightTunnels: ["kvmka-full"])

        XCTAssertFalse(row.isBusy, "спиннер — только у строки с операцией")
        XCTAssertFalse(row.isEnabled, "пока операция в полёте, некликабельны все строки")
    }

    // MARK: - isUp и accessibility

    func testIsUpPassesThrough() {
        XCTAssertTrue(TunnelRowViewModel(name: "x", isUp: true, inFlightTunnels: []).isUp)
        XCTAssertFalse(TunnelRowViewModel(name: "x", isUp: false, inFlightTunnels: []).isUp)
    }

    func testAccessibilityLabelReflectsState() {
        let up = TunnelRowViewModel(name: "kvmka-ai", isUp: true, inFlightTunnels: [])
        let down = TunnelRowViewModel(name: "kvmka-ai", isUp: false, inFlightTunnels: [])

        XCTAssertEqual(up.accessibilityLabel, L10n.string("tunnel.accessibility.on", "kvmka-ai"))
        XCTAssertEqual(down.accessibilityLabel, L10n.string("tunnel.accessibility.off", "kvmka-ai"))
    }

    // MARK: - Кнопка деталей

    /// Подпись деталей — своя (не состояние туннеля) и несёт имя: отдельный
    /// VoiceOver-элемент рядом с toggle.
    func testDetailsAccessibilityLabelCarriesNameAndIsIndependentOfState() {
        let up = TunnelRowViewModel(name: "kvmka-ai", isUp: true, inFlightTunnels: [])
        let down = TunnelRowViewModel(name: "kvmka-ai", isUp: false, inFlightTunnels: [])

        XCTAssertEqual(up.detailsAccessibilityLabel, L10n.string("tunnel.accessibility.details", "kvmka-ai"))
        XCTAssertEqual(
            down.detailsAccessibilityLabel,
            up.detailsAccessibilityLabel,
            "подпись деталей не зависит от isUp"
        )
    }

    /// Во время операции toggle глушится (isBusy/isEnabled), но подпись кнопки
    /// деталей остаётся доступной: вью-модель не тащит для неё отдельного
    /// флага операции (негейтированность самой кнопки — свойство view-слоя,
    /// его держит ручной QA).
    func testBusyRowKeepsDetailsAccessibilityLabelWhileToggleDisabled() {
        let busy = TunnelRowViewModel(name: "kvmka-ai", isUp: false, inFlightTunnels: ["kvmka-ai"])

        XCTAssertFalse(busy.isEnabled, "toggle во время операции глушится")
        XCTAssertFalse(
            busy.detailsAccessibilityLabel.isEmpty,
            "подпись деталей доступна и во время операции"
        )
    }
}
