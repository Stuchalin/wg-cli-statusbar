import AppKit
import SwiftUI

// MARK: - Граница показа

/// Показ окна настроек; инжектируется в `StatusItemController` (продакшн —
/// `SettingsWindowController`, владеющий одним переиспользуемым окном).
public protocol SettingsPresenting: AnyObject {
    func showSettings()
}

// MARK: - Контент окна

/// Контент окна настроек: одна секция «Основные» с опцией «Запускать при
/// входе». Логики нет — состояние и действия целиком из `SettingsModel`:
/// переключатель показывает только системный `enabled` (оптимистичного Bool
/// нет), `requiresApproval` — пояснение и кнопка в Login Items, недоступность
/// — причина, оконная ошибка — под опцией.
struct SettingsContentView: View {
    @ObservedObject private var model: SettingsModel

    init(model: SettingsModel) {
        self.model = model
    }

    var body: some View {
        Form {
            Section(L10n.string("settings.section.general")) {
                HStack(spacing: 8) {
                    // Binding без хранения: get — системный статус, set — запрос
                    // действия; итог переключатель покажет после перечитывания.
                    Toggle(
                        L10n.string("settings.launch_at_login.toggle"),
                        isOn: Binding(
                            get: { model.isToggleOn },
                            set: { model.setLaunchAtLogin($0) }
                        )
                    )
                    .disabled(!model.isToggleEnabled)
                    if model.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                if model.showsApprovalHint {
                    Text(L10n.string("settings.launch_at_login.approval_hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L10n.string("settings.launch_at_login.open_login_items")) {
                        model.openLoginItemsSettings()
                    }
                }
                if let reason = model.unavailableMessage {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = model.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 200)
    }
}

// MARK: - Контроллер окна

/// Владелец единственного переиспользуемого окна настроек (`NSWindow` +
/// `NSHostingView`), по образцу `ConfigViewerController`. Бизнес-логики нет:
/// статус перечитывает `SettingsModel.refresh()` — при показе окна и на
/// каждой активации приложения (`didBecomeActiveNotification`: пользователь
/// мог поменять Login Items в System Settings и вернуться). Активация
/// перечитывает статус безусловно — это одно чтение `SMAppService.status`,
/// а закрытое окно при следующем показе всё равно перечитает его заново.
///
/// Окно не трогает `WireGuardStatusModel`, тики, `serviceState` и
/// `inFlightTunnels`. Создавать на главном потоке.
public final class SettingsWindowController: NSObject, SettingsPresenting {
    private let model: SettingsModel
    private let notificationCenter: NotificationCenter
    private var window: NSWindow?

    /// `notificationCenter` инжектируется для тестов триггера активации.
    public init(model: SettingsModel, notificationCenter: NotificationCenter = .default) {
        self.model = model
        self.notificationCenter = notificationCenter
        super.init()
        // Селекторный обсервер доставляет синхронно на потоке публикации —
        // AppKit публикует активацию на главном, модель главнопоточная.
        notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    deinit {
        notificationCenter.removeObserver(self)
    }

    public func showSettings() {
        activateApp()
        let window = existingWindow()
        model.refresh()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        model.refresh()
    }

    /// Тот же версионный гейт, что у `ConfigViewerController.activateApp`:
    /// приложение accessory, без активации окно не получило бы фокус.
    private func activateApp() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func existingWindow() -> NSWindow {
        if let window { return window }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 240),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        // Окно переживает закрытие и переиспользуется; состояния, которое
        // надо снимать при закрытии, у окна нет — статус перечитывается при
        // следующем показе.
        window.isReleasedWhenClosed = false
        window.title = L10n.string("settings.window.title")
        window.contentView = NSHostingView(rootView: SettingsContentView(model: model))
        window.center()
        self.window = window
        return window
    }
}
