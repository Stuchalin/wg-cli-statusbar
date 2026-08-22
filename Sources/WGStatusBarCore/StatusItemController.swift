import AppKit
import Combine
import SwiftUI

/// Действия нативных пунктов меню; адресуются через `NSMenuItem.tag`.
enum StatusMenuAction: Int, Equatable {
    case refresh = 1
    case openConfigs = 2
    case manageTunnels = 3
    case quit = 4
}

/// Пункт-карточка не подсвечивается нативно: своё состояние рисует SwiftUI-контент
/// (референс CodexBar — `MenuCardMenuItem` с `isHighlighted == false`).
final class CardMenuItem: NSMenuItem {
    override var isHighlighted: Bool { false }
}

/// Структура меню статуса как данные — изолирована от `NSStatusItem`, тестируется напрямую.
enum StatusMenuStructure {
    enum Entry: Equatable {
        case card
        case action(
            id: StatusMenuAction,
            title: String,
            keyEquivalent: String,
            modifiers: NSEvent.ModifierFlags,
            isEnabled: Bool
        )
        case separator
    }

    /// Карточка → разделитель → Обновить/Конфиги/Управление → разделитель → Выход.
    /// `refreshEnabled = false`, пока идёт refresh (спиннер в карточке).
    static func entries(refreshEnabled: Bool = true) -> [Entry] {
        [
            .card,
            .separator,
            .action(id: .refresh, title: L10n.string("button.refresh"), keyEquivalent: "r", modifiers: .command, isEnabled: refreshEnabled),
            .action(id: .openConfigs, title: L10n.string("button.open_configs"), keyEquivalent: "o", modifiers: .command, isEnabled: true),
            .action(id: .manageTunnels, title: L10n.string("button.tunnel_management_soon"), keyEquivalent: "", modifiers: [], isEnabled: false),
            .separator,
            .action(id: .quit, title: L10n.string("button.quit"), keyEquivalent: "q", modifiers: .command, isEnabled: true),
        ]
    }
}

/// Изолированный билдер: собирает `NSMenuItem` из структуры меню.
/// Карточка приходит через провайдер, чтобы тесты структуры не создавали `NSHostingView`.
enum StatusMenuFactory {
    static func makeItems(
        from entries: [StatusMenuStructure.Entry],
        target: AnyObject?,
        action: Selector,
        cardItemProvider: () -> NSMenuItem
    ) -> [NSMenuItem] {
        entries.map { entry in
            switch entry {
            case .card:
                return cardItemProvider()
            case .separator:
                return NSMenuItem.separator()
            case .action(let id, let title, let keyEquivalent, let modifiers, let isEnabled):
                let item = NSMenuItem()
                item.title = title
                item.keyEquivalent = keyEquivalent
                item.keyEquivalentModifierMask = modifiers
                item.isEnabled = isEnabled
                item.tag = id.rawValue
                item.target = target
                item.action = action
                return item
            }
        }
    }
}

/// Владелец `NSStatusItem` (тайтл `wg: on/off`) и `NSMenu` с AppKit-гибридом:
/// первый пункт — SwiftUI-карточка `StatusCardView` в `NSHostingView`,
/// ниже — нативные пункты со стандартной клавиатурной навигацией.
///
/// Меню пересобирается в `menuNeedsUpdate` — при каждом открытии данные свежие.
/// Контент карточки обновляется сам (`@ObservedObject` модели), контроллер
/// реагирует на `objectWillChange` тайтлом, состоянием пункта «Обновить»
/// и перемером высоты карточки.
///
/// Создавать на главном потоке (единственный владелец — AppDelegate приложения).
public final class StatusItemController: NSObject, NSMenuDelegate {
    /// Ширина карточки; внутри `StatusCardView` задана `.frame(width: 320)`.
    private static let cardWidth: CGFloat = 320

    private let model: WireGuardStatusModel
    private let statusItem: NSStatusItem
    private var cancellable: AnyCancellable?
    private weak var menu: NSMenu?
    /// Хостинг-вью карточки последней сборки — для перемера высоты (ⓘ-легенда).
    private var cardHostingView: NSHostingView<StatusCardView>?

    public init(model: WireGuardStatusModel) {
        self.model = model
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.title = model.menuTitle

        let menu = NSMenu()
        // isEnabled задаём сами: «Управление тоннелями» — всегда disabled
        menu.autoenablesItems = false
        menu.delegate = self
        self.menu = menu
        statusItem.menu = menu
        rebuildMenu()

        // objectWillChange приходит до записи @Published; receive(on:) доставляет
        // асинхронно — sink видит уже обновлённое состояние.
        cancellable = model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.modelDidChange() }
    }

    deinit {
        cancellable?.cancel()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func modelDidChange() {
        statusItem.button?.title = model.menuTitle
        updateRefreshItemEnabledState()
        resizeCardToContent()
    }

    /// Загруженность меняется и при открытом меню (тик обновления работает
    /// в .common-режиме run loop) — состояние пункта «Обновить» синхронизируем
    /// живьём, не дожидаясь пересборки в `menuNeedsUpdate`.
    private func updateRefreshItemEnabledState() {
        guard let menu else { return }
        for item in menu.items where item.tag == StatusMenuAction.refresh.rawValue {
            item.isEnabled = !model.isLoading
        }
    }

    // MARK: - NSMenuDelegate

    public func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    // MARK: - Сборка меню

    private func rebuildMenu() {
        guard let menu else { return }
        let items = StatusMenuFactory.makeItems(
            from: StatusMenuStructure.entries(refreshEnabled: !model.isLoading),
            target: self,
            action: #selector(statusMenuAction(_:)),
            cardItemProvider: makeCardItem
        )
        menu.removeAllItems()
        items.forEach(menu.addItem)
    }

    private func makeCardItem() -> NSMenuItem {
        let cardView = StatusCardView(model: model) { [weak self] in
            self?.resizeCardToContent()
        }
        let hostingView = NSHostingView(rootView: cardView)
        // NSMenu берёт размер пункта из frame view'а — мерим содержимое и фиксируем frame
        // (подход CodexBar: frame высотой 1 → fittingSize → итоговый frame).
        hostingView.frame = NSRect(origin: .zero, size: NSSize(width: Self.cardWidth, height: 1))
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(
            origin: .zero,
            size: NSSize(
                width: max(Self.cardWidth, ceil(fittingSize.width)),
                height: max(1, ceil(fittingSize.height))
            )
        )
        cardHostingView = hostingView

        let item = CardMenuItem()
        // Нативного тайтла нет — пункт рисует view; пустой title, чтобы Tahoe
        // не рисовал fallback «NSMenuItem» при откреплении view.
        item.title = ""
        item.view = hostingView
        // enabled, чтобы клики по интерактивным контролам карточки (ⓘ-легенда) доходили
        item.isEnabled = true
        return item
    }

    /// Карточка изменила высоту (ⓘ-легенда, ошибка) — перемеряем и обновляем frame.
    /// Работает и по открытому меню: пункты берут размер из frame view'а.
    private func resizeCardToContent() {
        guard let hostingView = cardHostingView else { return }
        let fittingSize = hostingView.fittingSize
        guard abs(fittingSize.height - hostingView.frame.height) > 0.5 else { return }
        hostingView.frame = NSRect(
            origin: .zero,
            size: NSSize(width: hostingView.frame.width, height: max(1, ceil(fittingSize.height)))
        )
    }

    // MARK: - Действия пунктов

    /// Диспетчеризация действий меню — статически, чтобы тестировать без
    /// создания `NSStatusItem` (quit инжектится: реальный обработчик зовёт
    /// `NSApplication.terminate`).
    static func performStatusAction(
        _ action: StatusMenuAction,
        model: WireGuardStatusModel,
        quit: () -> Void
    ) {
        switch action {
        case .refresh:
            // Кнопка «Обновить» — принудительный рескан имён туннелей
            model.refresh(forceNameRescan: true)
        case .openConfigs:
            model.openWireGuardConfigFolder()
        case .manageTunnels:
            break  // placeholder — управление туннелями появится позже
        case .quit:
            quit()
        }
    }

    @objc private func statusMenuAction(_ sender: NSMenuItem) {
        guard let action = StatusMenuAction(rawValue: sender.tag) else { return }
        Self.performStatusAction(action, model: model) {
            NSApplication.shared.terminate(nil)
        }
    }
}
