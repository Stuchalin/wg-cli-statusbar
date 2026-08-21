import SwiftUI
import WGStatusBarCore

@main
struct WGStatusBarApp: App {
    @StateObject private var model = WireGuardStatusModel()

    var body: some Scene {
        MenuBarExtra(model.menuTitle, systemImage: model.menuIcon) {
            StatusMenuView(model: model)
        }
        .menuBarExtraStyle(.menu)
        Settings {
            EmptyView()
        }
    }
}
