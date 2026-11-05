import Combine
import Foundation
import ServiceManagement

// MARK: - Граница логин-айтема

/// Статус регистрации приложения как логин-айтема — зеркало
/// `SMAppService.Status` плюс явный `unknown` для будущих значений системы.
public enum LoginItemStatus: Equatable {
    case enabled
    case notRegistered
    /// Зарегистрировано, но пользователь не одобрил (или выключил) в
    /// System Settings → Login Items — это не «выключено».
    case requiresApproval
    /// Система ещё ни разу не видела сервис приложения — нормальный статус
    /// свежей установки до первого `register()` (Apple DTS), не ошибка.
    case notFound
    case unknown
}

/// Граница над `SMAppService.mainApp` (продакшн — `SMAppServiceLoginItem`):
/// модель настроек работает только через неё, тесты подставляют мок.
/// Источник истины — система: статус всегда читается заново, не хранится.
public protocol LoginItemManaging: AnyObject {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettingsLoginItems()
}

/// Тонкая продакшн-обёртка над `SMAppService.mainApp` — без логики и без
/// тестов; маппинг состояний и ошибок живёт в `SettingsModel`.
public final class SMAppServiceLoginItem: LoginItemManaging {
    public init() {}

    public var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .notRegistered
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        @unknown default:
            return .unknown
        }
    }

    public func register() throws {
        try SMAppService.mainApp.register()
    }

    public func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    public func openSystemSettingsLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// Отдельный факт «запущено из .app-бандла»: голый бинарь (`make run`)
/// логин-айтемом быть не может, и это своя причина недоступности, не
/// системный `notFound`. Чистая функция над URL бандла — продакшн передаёт
/// `Bundle.main.bundleURL`, модель получает уже готовый Bool.
public func isRunningFromAppBundle(bundleURL: URL) -> Bool {
    bundleURL.pathExtension.lowercased() == "app"
}

// MARK: - Отображаемое состояние

/// Почему опция недоступна (переключатель не показывается рабочим).
public enum LaunchAtLoginUnavailableReason: Equatable {
    /// Голый бинарь, не .app-бандл (dev-запуск).
    case notInAppBundle
    /// Попытка `register()` закончилась статусом `notFound` (бросила или
    /// система так и не увидела сервис) — сам по себе `notFound` до попытки
    /// этой причиной не является.
    case notFound
    /// Неизвестный системе статус (будущие значения `SMAppService.Status`).
    case unknownStatus
}

/// Отображаемое состояние опции «Запускать при входе» — по одному на
/// каждый системный статус и на голый бинарь.
public enum LaunchAtLoginDisplayState: Equatable {
    case on
    case off
    /// Ждёт одобрения в Login Items: пояснение + кнопка «Открыть Login
    /// Items»; переключатель не трогает регистрацию.
    case requiresApproval
    case unavailable(LaunchAtLoginUnavailableReason)

    /// Чистый маппинг факта о бандле и системного статуса.
    /// `registerEndedNotFound` — последняя попытка `register()` оставила
    /// статус `notFound`: только тогда `notFound` недоступен с причиной, до
    /// попытки это обычное «выключено» свежей установки, из которого
    /// `register()` и выводит приложение.
    public static func derive(
        isAppBundle: Bool,
        status: LoginItemStatus?,
        registerEndedNotFound: Bool
    ) -> LaunchAtLoginDisplayState {
        guard isAppBundle else { return .unavailable(.notInAppBundle) }
        switch status {
        case .enabled:
            return .on
        case .notRegistered:
            return .off
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return registerEndedNotFound ? .unavailable(.notFound) : .off
        case .unknown, nil:
            return .unavailable(.unknownStatus)
        }
    }
}

/// Оконные ошибки операций — фиксированные категории без текста `NSError`.
public enum LaunchAtLoginError: Error, Equatable {
    case registerFailed
    case unregisterFailed

    public var userMessage: String {
        switch self {
        case .registerFailed:
            return L10n.string("settings.launch_at_login.error.register_failed")
        case .unregisterFailed:
            return L10n.string("settings.launch_at_login.error.unregister_failed")
        }
    }
}

// MARK: - Модель окна настроек

/// Модель окна настроек: опция «Запускать при входе» поверх
/// `LoginItemManaging`. Главнопоточная по соглашению (как
/// `ConfigViewerModel`): каждое async-завершение прыгает через
/// `MainActor.run`.
///
/// Правила:
/// - источник истины — система: статус не хранится в `UserDefaults`,
///   оптимистичного Bool нет; статус перечитывается в `refresh()` (показ
///   окна, активация приложения — вызывает окно), непосредственно перед
///   действием и после каждого действия, включая сбой;
/// - `requiresApproval` — не «выключено»: действие в этом состоянии —
///   no-op, никаких авто-unregister/re-register поверх отказа пользователя;
/// - оконная ошибка переживает `refresh()` и заменяется только новым
///   действием пользователя;
/// - одна операция за раз: повтор во время операции — молчаливый no-op;
/// - `notFound` до попытки — «выключено» (свежая установка, система ещё не
///   видела сервис), переключатель зовёт `register()`; если после попытки
///   статус всё ещё `notFound`, опция недоступна с причиной, пока система
///   не покажет другой статус.
///
/// Окно не трогает `WireGuardStatusModel`, тики, `serviceState` и
/// `inFlightTunnels`.
public final class SettingsModel: ObservableObject {
    /// Последний прочитанный системный статус; nil — ещё не читался или
    /// голый бинарь (системе вопросов не задаём).
    @Published public private(set) var loginItemStatus: LoginItemStatus?
    /// Идёт register/unregister.
    @Published public private(set) var isBusy = false
    /// Оконная ошибка последнего действия (фиксированная категория).
    @Published public private(set) var errorMessage: String?
    /// Последний `register()` (успешный или нет) оставил статус `notFound`;
    /// сбрасывается, как только система покажет любой другой статус.
    @Published public private(set) var registerEndedNotFound = false

    private let loginItem: LoginItemManaging
    private let isAppBundle: Bool

    public init(loginItem: LoginItemManaging, isAppBundle: Bool) {
        self.loginItem = loginItem
        self.isAppBundle = isAppBundle
    }

    // MARK: Производное состояние для окна

    public var displayState: LaunchAtLoginDisplayState {
        LaunchAtLoginDisplayState.derive(
            isAppBundle: isAppBundle,
            status: loginItemStatus,
            registerEndedNotFound: registerEndedNotFound
        )
    }

    /// Переключатель включён только при `enabled` от системы.
    public var isToggleOn: Bool {
        displayState == .on
    }

    /// Переключатель кликабелен только в `on`/`off` и вне операции.
    public var isToggleEnabled: Bool {
        guard !isBusy else { return false }
        switch displayState {
        case .on, .off:
            return true
        case .requiresApproval, .unavailable:
            return false
        }
    }

    /// Показывать пояснение и кнопку «Открыть Login Items».
    public var showsApprovalHint: Bool {
        displayState == .requiresApproval
    }

    /// Локализованная причина недоступности; nil, если опция доступна.
    public var unavailableMessage: String? {
        guard case .unavailable(let reason) = displayState else { return nil }
        switch reason {
        case .notInAppBundle:
            return L10n.string("settings.launch_at_login.unavailable.not_in_bundle")
        case .notFound:
            return L10n.string("settings.launch_at_login.unavailable.not_found")
        case .unknownStatus:
            return L10n.string("settings.launch_at_login.unavailable.unknown")
        }
    }

    // MARK: Действия

    /// Перечитывает системный статус. Оконную ошибку не трогает — её
    /// заменяет только новое действие.
    public func refresh() {
        guard isAppBundle else {
            loginItemStatus = nil
            return
        }
        let status = loginItem.status
        if status != .notFound {
            registerEndedNotFound = false
        }
        loginItemStatus = status
    }

    /// Переключение пользователем. Статус перечитывается до решения; если
    /// система уже в нужном состоянии, ждёт одобрения или опция недоступна —
    /// no-op (ошибка прошлого действия при этом не стирается).
    public func setLaunchAtLogin(_ enabled: Bool) {
        guard !isBusy else { return }
        refresh()
        let state = displayState
        let shouldRegister: Bool
        switch (state, enabled) {
        case (.off, true):
            shouldRegister = true
        case (.on, false):
            shouldRegister = false
        default:
            return
        }

        isBusy = true
        errorMessage = nil
        let loginItem = loginItem
        Task.detached {
            var failure: LaunchAtLoginError?
            do {
                if shouldRegister {
                    try loginItem.register()
                } else {
                    try loginItem.unregister()
                }
            } catch {
                failure = shouldRegister ? .registerFailed : .unregisterFailed
            }
            let result = failure
            await MainActor.run { [weak self] in
                self?.finishOperation(wasRegister: shouldRegister, failure: result)
            }
        }
    }

    /// Кнопка «Открыть Login Items» (подсказка `requiresApproval`).
    public func openLoginItemsSettings() {
        loginItem.openSystemSettingsLoginItems()
    }

    private func finishOperation(wasRegister: Bool, failure: LaunchAtLoginError?) {
        isBusy = false
        if let failure {
            errorMessage = failure.userMessage
        }
        // После успеха и после сбоя: показываем то, что говорит система.
        refresh()
        if wasRegister && loginItemStatus == .notFound {
            registerEndedNotFound = true
        }
    }
}
