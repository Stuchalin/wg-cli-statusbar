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
        serviceStateProvider: @escaping () -> ServiceState,
        editExecutor: ConfigEditingExecuting? = nil
    ) {
        self.editExecutor = editExecutor
        self.maskedReader = maskedReader
        self.revealExecutor = revealExecutor
        self.serviceStateProvider = serviceStateProvider
    }

    // MARK: Переходы

    /// Открытие/смена выбранного туннеля: маскированная загрузка. Прошлое
    /// ожидание отменяется, raw-состояние снимается до await.
    public func show(name: String) {
        guard !isSaving, !hasUnsavedChanges else { return }
        beginLoading(named: name)
    }

    /// Reload: повторная маскированная загрузка выбранного туннеля —
    /// поколение растёт (опоздавшие результаты старой загрузки гасятся),
    /// raw-состояние снято до await.
    public func reload() {
        guard !isSaving, !hasUnsavedChanges else { return }
        guard let name = tunnelName else { return }
        beginLoading(named: name)
    }

    private func beginLoading(named name: String) {
        operationTask?.cancel()
        clearEditingState()
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
        guard let name = tunnelName, !isRevealing, !isLoading, !isStartingEdit, !isEditing, !isSaving else { return }
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
        guard !isSaving, !hasUnsavedChanges else { return }
        operationTask?.cancel()
        isLoading = false
        isRevealing = false
        generation += 1
        clearEditingState()
        isRevealing = false
        mode = .masked
        displayedText = lastMaskedText
    }

    /// Закрытие окна: состояние снимается целиком, висящие операции
    /// отменяются — опоздавшие результаты гасятся поколением.
public func close() {
        guard !isSaving, !hasUnsavedChanges else { return }
        windowDidClose()
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

    @Published public var draftText = ""
    @Published public private(set) var isEditing = false
    @Published public private(set) var isStartingEdit = false
    @Published public private(set) var isSaving = false
    @Published public private(set) var requiresEditReload = false
    private var editSnapshot: ConfigEditSnapshot?
    private let editExecutor: ConfigEditingExecuting?

public var hasUnsavedChanges: Bool {
        guard isEditing, let snapshot = editSnapshot else { return false }
        return !draftText.utf8.elementsEqual(snapshot.text.utf8)
    }
    public var canBeginEditing: Bool { editExecutor != nil && tunnelName != nil && !isLoading && !isRevealing && !isStartingEdit && !isSaving && !isEditing }
    public var canSaveEdits: Bool { isEditing && hasUnsavedChanges && !isSaving && !requiresEditReload }

    public func beginEditing() {
        guard canBeginEditing, let name = tunnelName, let executor = editExecutor else { return }
        operationTask?.cancel()
        generation += 1
        let expected = generation
        mode = .masked
        displayedText = lastMaskedText
        isStartingEdit = true
        errorMessage = nil
        let state = serviceStateProvider()
        operationTask = Task.detached {
            let outcome = await executor.loadForEditing(named: name, serviceState: state)
            await MainActor.run { [weak self] in self?.applyEditLoad(outcome, generation: expected) }
        }
    }

    public func saveEdits() {
        guard canSaveEdits, let name = tunnelName, let snapshot = editSnapshot, let executor = editExecutor else { return }
        let text = draftText
        let expected = generation
        let state = serviceStateProvider()
        isSaving = true
        errorMessage = nil
        operationTask = Task.detached {
            let outcome = await executor.save(named: name, revision: snapshot.revision, text: text, serviceState: state)
            await MainActor.run { [weak self] in self?.applyEditSave(outcome, generation: expected) }
        }
    }

    public func discardEdits() {
        guard !isSaving else { return }
        operationTask?.cancel()
        isLoading = false
        isRevealing = false
        generation += 1
        clearEditingState()
        mode = .masked
        displayedText = lastMaskedText
        errorMessage = nil
    }

    private func clearEditingState() {
        draftText = ""
        editSnapshot = nil
        isEditing = false
        isStartingEdit = false
        isSaving = false
        requiresEditReload = false
    }

    private func applyEditLoad(_ outcome: ConfigEditOutcome, generation expected: Int) {
        guard generation == expected else { return }
        isStartingEdit = false
        switch outcome {
        case .snapshot(let snapshot):
            editSnapshot = snapshot
            draftText = snapshot.text
            displayedText = ""
            mode = .raw
            isEditing = true
        case .failed(let error): errorMessage = error.userMessage
        case .cancelled, .suppressed: break
        case .saved: errorMessage = ConfigEditFailure.unavailable.userMessage
        }
    }

    private func applyEditSave(_ outcome: ConfigEditOutcome, generation expected: Int) {
        guard generation == expected else { return }
        isSaving = false
        switch outcome {
        case .saved:
            if let name = tunnelName { beginLoading(named: name) }
        case .failed(let error):
            errorMessage = error.userMessage
            requiresEditReload = error == .conflict || error == .unknownCommitOutcome || error == .activeTunnel
        case .cancelled, .suppressed: break
        case .snapshot:
            errorMessage = ConfigEditFailure.unknownCommitOutcome.userMessage
            requiresEditReload = true
        }
    }

    /// Authorization belongs in windowShouldClose. After an actual close event,
    /// cleanup must be unconditional, even if NSWindow.close bypassed that gate.
    func windowDidClose() {
        operationTask?.cancel()
        generation += 1
        isRevealing = false
        isLoading = false
        clearEditingState()
        tunnelName = nil
        mode = .masked
        displayedText = ""
        lastMaskedText = ""
        errorMessage = nil
    }
}

// MARK: - Контент окна

/// Контент окна вьювера: панель инструментов (режим, прогресс, Reload,
/// Reveal/Hide), оконная ошибка и сам документ — моноширинно, только чтение,
/// выделение и копирование доступны (`.textSelection`).
struct ConfigViewerContentView: View {
    @ObservedObject private var model: ConfigViewerModel
    let requestReload: () -> Void
    let requestHide: () -> Void
    let requestCancel: () -> Void

    init(model: ConfigViewerModel, requestReload: @escaping () -> Void,
         requestHide: @escaping () -> Void, requestCancel: @escaping () -> Void) {
        self.model = model
        self.requestReload = requestReload
        self.requestHide = requestHide
        self.requestCancel = requestCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            if model.isEditing {
                Text(L10n.string("config.editor.warning"))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                ConfigTextEditor(text: $model.draftText, isEditable: !model.isSaving)
                Text(L10n.string(model.hasUnsavedChanges ? "config.editor.modified" : "config.editor.unmodified"))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    Text(model.displayedText).font(.system(.body, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
            }
        }
        .frame(minWidth: 620, minHeight: 360)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text(L10n.string(model.isEditing ? "config.editor.badge" : model.mode == .raw ? "config.viewer.raw_badge" : "config.viewer.masked_badge"))
                .font(.caption2)
            if model.isLoading || model.isRevealing || model.isStartingEdit || model.isSaving {
                ProgressView().controlSize(.small)
                Text(L10n.string(model.isSaving ? "config.editor.saving" : model.isStartingEdit ? "config.editor.opening" : model.isRevealing ? "config.viewer.revealing" : "config.viewer.loading"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(L10n.string("config.viewer.reload"), action: requestReload)
                .disabled(model.tunnelName == nil || model.isLoading || model.isSaving)
            if model.isEditing {
                Button(L10n.string("config.editor.save")) { model.saveEdits() }
                    .keyboardShortcut("s", modifiers: [.command]).disabled(!model.canSaveEdits)
                Button(L10n.string("config.editor.cancel"), action: requestCancel)
                    .keyboardShortcut(.cancelAction).disabled(model.isSaving)
            } else {
                Button(L10n.string("config.editor.edit")) { model.beginEditing() }
                    .disabled(!model.canBeginEditing)
            }
            if model.mode == .raw {
                Button(L10n.string("config.viewer.hide"), action: requestHide).disabled(model.isSaving)
            } else if !model.isEditing {
                Button(L10n.string("config.viewer.reveal")) { model.revealSecrets() }
                    .disabled(model.isRevealing || model.isLoading || model.isStartingEdit || model.displayedText.isEmpty)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

// MARK: - Контроллер окна

/// Владелец единственного переиспользуемого окна вьювера (`NSWindow` +
/// `NSHostingView` с контентом SwiftUI). Бизнес-логики нет: показ/смена
/// туннеля уходит в `ConfigViewerModel`, закрытие окна — `model.close()`
/// (отменяет висящие операции, снимает raw-состояние). Приложение
/// accessory: перед показом активируем его, иначе окно не получило бы фокус.
public final class ConfigViewerController: NSObject, ConfigViewing, NSWindowDelegate, NSMenuItemValidation {
    private let model: ConfigViewerModel
    private var window: NSWindow?

    public init(model: ConfigViewerModel) {
        self.model = model
        super.init()
    }

public func showConfig(named name: String) {
        installApplicationCommands()
        activateApp()
        let window = existingWindow()
        if model.tunnelName == name && (model.isEditing || model.isStartingEdit || model.isSaving) {
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard prepareTransition() else { return }
        window.title = L10n.string("config.viewer.title", name)
        model.show(name: name)
        window.makeKeyAndOrderFront(nil)
    }

public func windowWillClose(_ notification: Notification) {
        model.windowDidClose()
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
        window.contentView = NSHostingView(rootView: ConfigViewerContentView(model: model,
            requestReload: { [weak self] in self?.requestReload() },
            requestHide: { [weak self] in self?.requestHide() },
            requestCancel: { [weak self] in self?.requestCancel() }))
        window.delegate = self
        window.center()
        self.window = window
        return window
    }

    static func allowTransition(model: ConfigViewerModel, confirmDiscard: () -> Bool) -> Bool {
        guard !model.isSaving else { return false }
        if model.hasUnsavedChanges && !confirmDiscard() { return false }
        if model.isEditing || model.isStartingEdit { model.discardEdits() }
        return true
    }

    private func prepareTransition() -> Bool {
        Self.allowTransition(model: model) {
            let alert = NSAlert()
            alert.messageText = L10n.string("config.editor.discard.title")
            alert.informativeText = L10n.string("config.editor.discard.message")
            alert.addButton(withTitle: L10n.string("config.editor.discard.keep"))
            alert.addButton(withTitle: L10n.string("config.editor.discard.confirm"))
            return alert.runModal() == .alertSecondButtonReturn
        }
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool { prepareTransition() }

    public func prepareForApplicationTermination() -> Bool {
        guard prepareTransition() else { return false }
        model.close()
        return true
    }

    private func requestReload() { if prepareTransition() { model.reload() } }
    private func requestHide() { if prepareTransition() { model.hideSecrets() } }
    private func requestCancel() { _ = prepareTransition() }

    /// AppKit-hosted SwiftUI views do not provide a Scene command menu. Register
    /// Save with NSApplication so Cmd-S is dispatched before native text editing.
    static func installSaveCommand(in menu: NSMenu, target: AnyObject, action: Selector) -> NSMenuItem {
        let fileID = NSUserInterfaceItemIdentifier("wgstatusbar.config-file")
        let saveID = NSUserInterfaceItemIdentifier("wgstatusbar.config-save")
        let file: NSMenu
        if let existing = menu.items.first(where: { $0.identifier == fileID })?.submenu {
            file = existing
        } else {
            file = NSMenu(title: L10n.string("config.editor.file_menu"))
            let parent = NSMenuItem(title: file.title, action: nil, keyEquivalent: "")
            parent.identifier = fileID
            parent.submenu = file
            menu.addItem(parent)
        }
        let item: NSMenuItem
        if let existing = file.items.first(where: { $0.identifier == saveID }) { item = existing }
        else {
            item = NSMenuItem(title: L10n.string("config.editor.save"), action: action, keyEquivalent: "s")
            item.identifier = saveID
            file.addItem(item)
        }
        item.target = target
        item.action = action
        item.keyEquivalent = "s"
        item.keyEquivalentModifierMask = .command
        return item
    }

    private func installApplicationCommands() {
        let menu = NSApp.mainMenu ?? NSMenu()
        if menu.items.isEmpty {
            let application = NSMenu()
            let quit = NSMenuItem(title: L10n.string("button.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            quit.target = NSApp
            application.addItem(quit)
            let parent = NSMenuItem()
            parent.submenu = application
            menu.addItem(parent)
        }
        _ = Self.installSaveCommand(in: menu, target: self, action: #selector(saveFromMenu(_:)))
        NSApp.mainMenu = menu
    }

    @objc private func saveFromMenu(_ sender: Any?) { model.saveEdits() }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(saveFromMenu(_:)) else { return true }
        return window?.isKeyWindow == true && model.canSaveEdits
    }
}
