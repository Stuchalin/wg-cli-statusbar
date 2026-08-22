import AppKit
import WGStatusBarCore

/// Владеет моделью и статус-айтемом; без окна — приложение только меню-бара.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = WireGuardStatusModel()
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController(model: model)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
