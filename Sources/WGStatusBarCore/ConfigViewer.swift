import AppKit
import Combine
import SwiftUI

// MARK: - Границы данных вьювера

/// Чтение маскированного конфига (продакшн — `SocketConfigClient`): полный
/// текст со спрятанными значениями канонических назначений
/// PrivateKey/PresharedKey. Отдельная от `WireGuardStatusModel` граница —
/// вьювер не участвует в тиках статуса, туннельных операциях и установке
/// сервиса.
public protocol MaskedConfigReading {
    func maskedConfig(named name: String) async throws -> TunnelConfigDocument
}

extension SocketConfigClient: MaskedConfigReading {}

/// Показ конфига в окне вьювера; инжектируется в `StatusItemController`
/// (продакшн — `ConfigViewerController`, владеющий одним переиспользуемым
/// окном).
public protocol ConfigViewing: AnyObject {
    func showConfig(named name: String)
}

// MARK: - Модель окна вьювера

/// Режим показа документа.
public enum ConfigViewerMode: Equatable {
    /// Маскированный документ: значения канонических назначений ключей
    /// спрятаны демоном до отправки (дефолт; возвращается Hide'ом).
    case masked
    /// Raw-документ: появляется только после успешной аутентификации
    /// владельца И успешного привилегированного one-shot чтения.
    case raw
}

/// Модель окна вьювера: один выбранный туннель, один документ. Поколение
/// (generation) гасит опоздавшие завершения — закрытие окна, смена туннеля,
/// Reload и Hide отменяют текущую задачу и поднимают поколение, а каждый
/// async-результат применяется только при совпавшем поколении. Каждый
/// безопасный переход снимает raw-состояние синхронно, до какого-либо await.
///
/// Вьювер не трогает `WireGuardStatusModel`: ни `lastFailure` карточки, ни
/// `inFlightTunnels`, ни тики — ошибки здесь оконные. Swift не гарантирует
/// физического обнуления всех копий снятой с показа `String` (как и
/// пользовательского буфера обмена) — документированное ограничение.
public final class ConfigViewerModel: ObservableObject {
    @Published public private(set) var tunnelName: String?
    @Published public private(set) var displayedText: String = ""
    @Published public private(set) var mode: ConfigViewerMode = .masked
    @Published public private(set) var isLoading = false
    @Published public private(set) var isRevealing = false
    /// Оконная ошибка (загрузка/Reveal) — фиксированные категории без данных
    /// документа; nil при отмене пользователем (отмена — не ошибка).
    @Published public private(set) var errorMessage: String?

    /// Номер текущего поколения; растёт на каждом переходе, отменяющем
    /// ожидание. Читается только на главном потоке (все завершения идут
    /// через `MainActor.run`).
    private var generation = 0
    /// Маскированный текст последней успешной загрузки: Hide возвращает к
    /// нему показ, не перезагружая документ.
    private var lastMaskedText: String = ""
    /// Текущая операция (загрузка или Reveal): её отменяют close, смена
    /// туннеля, Reload и Hide.
    private var operationTask: Task<Void, Never>?

    private let maskedReader: MaskedConfigReading
    private let revealExecutor: ConfigRevealExecuting
    /// Уже выведенное моделью статуса состояние сервиса — для fail-closed
    /// Reveal (`.absent`/`.broken`/`.outdated` гасятся до промпта). Вьювер
    /// состояние сам не выводит и очередь show-тиков не читает.
    private let serviceStateProvider: () -> ServiceState

    public init(
        maskedReader: MaskedConfigReading,
        revealExecutor: ConfigRevealExecuting,
        serviceStateProvider: @escaping () -> ServiceState
    ) {
        self.maskedReader = maskedReader
        self.revealExecutor = revealExecutor
        self.serviceStateProvider = serviceStateProvider
    }

    // MARK: Переходы

    /// Открытие/смена выбранного туннеля: маскированная загрузка. Прошлое
    /// ожидание отменяется, raw-состояние снимается до await.
    public func show(name: String) {
        beginLoading(named: name)
    }

    /// Reload: повторная маскированная загрузка выбранного туннеля —
    /// поколение растёт (опоздавшие результаты старой загрузки гасятся),
    /// raw-состояние снято до await.
    public func reload() {
        guard let name = tunnelName else { return }
        beginLoading(named: name)
    }

    private func beginLoading(named name: String) {
        operationTask?.cancel()
        generation += 1
        let currentGeneration = generation
        tunnelName = name
        mode = .masked
        displayedText = ""
        lastMaskedText = ""
        errorMessage = nil
        isLoading = true
        isRevealing = false

        let reader = maskedReader
        operationTask = Task.detached {
            do {
                let document = try await reader.maskedConfig(named: name)
                await MainActor.run { [weak self] in
                    self?.applyMasked(document, generation: currentGeneration)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.applyLoadFailure(error, generation: currentGeneration)
                }
            }
        }
    }

    /// Reveal: свежая аутентификация владельца + привилегированное one-shot
    /// чтение (порядок границ — внутри `PrivilegedConfigReader`). Повтор во
    /// время Reveal или загрузки — молчаливый no-op; отмена пользователем
    /// (аутентификация, админ-промпт) — не ошибка: маскированный документ
    /// сохраняется.
    public func revealSecrets() {
        guard let name = tunnelName, !isRevealing, !isLoading else { return }
        let currentGeneration = generation
        let serviceState = serviceStateProvider()
        isRevealing = true
        errorMessage = nil

        let executor = revealExecutor
        operationTask = Task.detached {
            let outcome = await executor.reveal(named: name, serviceState: serviceState)
            await MainActor.run { [weak self] in
                self?.applyReveal(outcome, generation: currentGeneration)
            }
        }
    }

    /// Hide: показ возвращается к маскированному документу. Висящий Reveal
    /// отменяется (промпт закрывается), его опоздавший результат гасится
    /// поднятым поколением.
    public func hideSecrets() {
        operationTask?.cancel()
        generation += 1
        isRevealing = false
        mode = .masked
        displayedText = lastMaskedText
    }

    /// Закрытие окна: состояние снимается целиком, висящие операции
    /// отменяются — опоздавшие результаты гасятся поколением.
    public func close() {
        operationTask?.cancel()
        generation += 1
        isRevealing = false
        isLoading = false
        tunnelName = nil
        mode = .masked
        displayedText = ""
        lastMaskedText = ""
        errorMessage = nil
    }

    // MARK: Применение результатов (только совпавшее поколение)

    private func applyMasked(_ document: TunnelConfigDocument, generation expectedGeneration: Int) {
        guard generation == expectedGeneration else { return }
        isLoading = false
        displayedText = document.text
        lastMaskedText = document.text
        mode = .masked
    }

    private func applyLoadFailure(_ error: Error, generation expectedGeneration: Int) {
        guard generation == expectedGeneration else { return }
        isLoading = false
        errorMessage = Self.message(for: error)
    }

    private func applyReveal(_ outcome: ConfigRevealOutcome, generation expectedGeneration: Int) {
        guard generation == expectedGeneration else { return }
        isRevealing = false
        switch outcome {
        case .revealed(let document):
            // Файл мог измениться между маскированной загрузкой и Reveal —
            // документ заменяется целиком только что прочитанной raw-версией.
            displayedText = document.text
            mode = .raw
        case .cancelledByUser, .suppressed:
            // Тихие исходы: маскированный документ сохраняется, ошибки нет.
            break
        case .failed(let error):
            errorMessage = error.userMessage
        }
    }

    /// Текст оконной ошибки загрузки: фиксированные категории без данных
    /// ответа. Старый демон — то же «обновите сервис», что пункт меню.
    private static func message(for error: Error) -> String {
        switch error as? ConfigFetchError {
        case .daemonOutdated:
            return L10n.string("error.daemon_outdated")
        case .connectionRefused, .timedOut:
            return L10n.string("error.service_unreachable")
        case .badResponse, nil:
            return L10n.string("config.error.load_failed")
        case .unavailable:
            return L10n.string("config.error.unavailable")
        }
    }
}

// MARK: - Контент окна

/// Контент окна вьювера: панель инструментов (режим, прогресс, Reload,
/// Reveal/Hide), оконная ошибка и сам документ — моноширинно, только чтение,
/// выделение и копирование доступны (`.textSelection`).
struct ConfigViewerContentView: View {
    @ObservedObject private var model: ConfigViewerModel

    init(model: ConfigViewerModel) {
        self.model = model
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            documentArea
        }
        .frame(minWidth: 520, minHeight: 360)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text(L10n.string(model.mode == .raw ? "config.viewer.raw_badge" : "config.viewer.masked_badge"))
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
            if model.isLoading || model.isRevealing {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.string(model.isRevealing ? "config.viewer.revealing" : "config.viewer.loading"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(L10n.string("config.viewer.reload")) {
                model.reload()
            }
            .disabled(model.tunnelName == nil || model.isLoading)
            if model.mode == .raw {
                Button(L10n.string("config.viewer.hide")) {
                    model.hideSecrets()
                }
            } else {
                Button(L10n.string("config.viewer.reveal")) {
                    model.revealSecrets()
                }
                // Пустой документ раскрывать нечего; спиннер загрузки —
                // повторный клик глушился бы и так (guard модели).
                .disabled(model.isRevealing || model.isLoading || model.displayedText.isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Документ: пустая область при пустом тексте (пустой файл или ошибка
    /// загрузки — текст ошибки уже выше), иначе прокручиваемый текст.
    private var documentArea: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(model.displayedText)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
    }
}

// MARK: - Контроллер окна

/// Владелец единственного переиспользуемого окна вьювера (`NSWindow` +
/// `NSHostingView` с контентом SwiftUI). Бизнес-логики нет: показ/смена
/// туннеля уходит в `ConfigViewerModel`, закрытие окна — `model.close()`
/// (отменяет висящие операции, снимает raw-состояние). Приложение
/// accessory: перед показом активируем его, иначе окно не получило бы фокус.
public final class ConfigViewerController: NSObject, ConfigViewing, NSWindowDelegate {
    private let model: ConfigViewerModel
    private var window: NSWindow?

    public init(model: ConfigViewerModel) {
        self.model = model
        super.init()
    }

    public func showConfig(named name: String) {
        // Открытие другого туннеля продвигает поколение модели и гасит
        // прошлое raw-состояние — окно одно и переиспользуется.
        activateApp()
        let window = existingWindow()
        window.title = L10n.string("config.viewer.title", name)
        model.show(name: name)
        window.makeKeyAndOrderFront(nil)
    }

    public func windowWillClose(_ notification: Notification) {
        model.close()
    }

    /// `activate(ignoringOtherApps:)` с macOS 14 устарел; безликая
    /// `activate()` на 13 отсутствует — гейт по версии, тот же приём, что у
    /// остальных новых API проекта.
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
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // Окно переживает закрытие и переиспользуется: состояние снимает
        // модель (`windowWillClose`), а не dealloc окна.
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ConfigViewerContentView(model: model))
        window.delegate = self
        window.center()
        self.window = window
        return window
    }
}
