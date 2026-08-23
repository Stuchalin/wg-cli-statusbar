import AppKit
import WGStatusBarCore

/// Владеет моделью и статус-айтемом; без окна — приложение только меню-бара.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = WireGuardStatusModel()
    /// Установка/удаление root-демона из меню: osascript показывает системный
    /// промпт (пароль/Touch ID). Успех — немедленный refresh (карточка оживает,
    /// не дожидаясь тика), сбой — stderr скрипта в ошибку на один тик, отмена
    /// промпта — тихий no-op внутри сервиса.
    private let installer = InstallerService()
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installer.onSuccess = { [weak model] in model?.refresh() }
        installer.onFailure = { [weak model] message in model?.reportServiceFailure(message) }
        statusItemController = StatusItemController(model: model, installer: installer)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
