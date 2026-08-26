import AppKit
import Combine
import SwiftUI

/// Действия нативных пунктов меню; адресуются через `NSMenuItem.tag`.
enum StatusMenuAction: Int, Equatable {
    case refresh = 1
    case openConfigs = 2
    case quit = 4
    case installService = 5
    case uninstallService = 6
}

/// Установка/удаление сервиса демона для диспетчеризации пунктов меню;
/// инжектруется для тестов (продакшн — `InstallerService`, привязывается
/// в AppDelegate).
public protocol ServiceInstalling: AnyObject {
    func install() async
    func uninstall() async
}

extension InstallerService: ServiceInstalling {}

/// Пункт-карточка не подсвечивается нативно: своё состояние рисует SwiftUI-контент
/// (референс CodexBar — `MenuCardMenuItem` с `isHighlighted == false`).
final class CardMenuItem: NSMenuItem {
    override var isHighlighted: Bool { false }
}

/// Пункт-строка туннеля: как карточка, не подсвечивается нативно и клик
/// внутри не закрывает меню — клики обрабатывает SwiftUI-контент
/// (`TunnelRowView` → toggle).
final class TunnelMenuItem: NSMenuItem {
    override var isHighlighted: Bool { false }
}

/// Иконки меню-бара (векторные PDF из бандла, 18×18 из MediaBox).
/// Template-рендер: AppKit красит альфа-маску под тему (чёрный/белый),
/// двухтон щита On-иконки переживает через альфу (100%/72%).
/// Static — тестируется без создания `NSStatusItem`.
enum StatusIcon {
    static let on: NSImage? = load("StatusIconOn")
    static let off: NSImage? = load("StatusIconOff")

    static func image(connected: Bool) -> NSImage? { connected ? on : off }

    private static func load(_ name: String) -> NSImage? {
        let image = Bundle.module.image(forResource: name)
        image?.isTemplate = true
        return image
    }
}

/// Структура меню статуса как данные — изолирована от `NSStatusItem`, тестируется напрямую.
enum StatusMenuStructure {
    enum Entry: Equatable {
        case card
        /// Заголовок секции Tunnels (не действие).
        case tunnelsHeader(title: String)
        /// Строка туннеля: данные на момент сборки (текущее состояние вью
        /// выводит из модели живьём).
        case tunnelRow(TunnelInfo, isEnabled: Bool)
        case action(
            id: StatusMenuAction,
            title: String,
            keyEquivalent: String,
            modifiers: NSEvent.ModifierFlags,
            isEnabled: Bool
        )
        case separator
    }

    /// Карточка → разделитель → Обновить/Конфиги → [Tunnels: заголовок +
    /// строки] → разделитель → Сервис (по состоянию) → Выход.
    /// `refreshEnabled = false`, пока идёт refresh (спиннер в карточке);
    /// туннельная операция в полёте дополнительно отключает «Обновить»
    /// (подавленный тик — молчаливый no-op), все строки (одна операция за
    /// раз) и пункт сервиса — скрипт установки/удаления начинается с
    /// `launchctl bootout`, и SIGTERM демону посреди операции оставил бы
    /// полуприменённый туннель. Секция Tunnels видна только при живом демоне и непустом списке —
    /// иначе её нет целиком, включая заголовок и разделители. Пункт сервиса:
    /// `absent` → «Установить», `broken`/`outdated` → «Обновить»
    /// (переустановка), `installed` → «Удалить».
    static func entries(
        refreshEnabled: Bool = true,
        serviceState: ServiceState = .absent,
        tunnels: [TunnelInfo] = [],
        hasInFlightTunnelOperation: Bool = false
    ) -> [Entry] {
        var entries: [Entry] = [
            .card,
            .separator,
            .action(id: .refresh, title: L10n.string("button.refresh"), keyEquivalent: "r", modifiers: .command, isEnabled: refreshEnabled && !hasInFlightTunnelOperation),
            .action(id: .openConfigs, title: L10n.string("button.open_configs"), keyEquivalent: "o", modifiers: .command, isEnabled: true),
        ]
        if serviceState == .installed && !tunnels.isEmpty {
            entries.append(.separator)
            entries.append(.tunnelsHeader(title: L10n.string("menu.tunnels_section")))
            for tunnel in tunnels {
                entries.append(.tunnelRow(tunnel, isEnabled: !hasInFlightTunnelOperation))
            }
        }
        entries.append(.separator)
        entries.append(serviceEntry(for: serviceState, isEnabled: !hasInFlightTunnelOperation))
        entries.append(.action(id: .quit, title: L10n.string("button.quit"), keyEquivalent: "q", modifiers: .command, isEnabled: true))
        return entries
    }

    /// Пункт меню сервиса из состояния: демона нет — установить; не отвечает
    /// или устарел — обновить (скрипт установки идемпотентен, действие то же);
    /// жив — удалить. Во время туннельной операции пункт отключён.
    private static func serviceEntry(for state: ServiceState, isEnabled: Bool) -> Entry {
        let action = serviceAction(for: state)
        return .action(id: action.id, title: action.title, keyEquivalent: "", modifiers: [], isEnabled: isEnabled)
    }

    /// Действие и заголовок пункта сервиса из состояния — единый источник для
    /// сборки меню и живого обновления пункта при открытом меню.
    static func serviceAction(for state: ServiceState) -> (id: StatusMenuAction, title: String) {
        switch state {
        case .absent:
            return (.installService, L10n.string("button.install_service"))
        case .broken, .outdated:
            return (.installService, L10n.string("button.update_service"))
        case .installed:
            return (.uninstallService, L10n.string("button.remove_service"))
        }
    }
}

/// Изолированный билдер: собирает `NSMenuItem` из структуры меню.
/// Карточка и строки туннелей приходят через провайдеры, чтобы тесты
/// структуры не создавали `NSHostingView`.
enum StatusMenuFactory {
    static func makeItems(
        from entries: [StatusMenuStructure.Entry],
        target: AnyObject?,
        action: Selector,
        cardItemProvider: () -> NSMenuItem,
        tunnelItemProvider: (TunnelInfo, Bool) -> NSMenuItem
    ) -> [NSMenuItem] {
        entries.map { entry in
            switch entry {
            case .card:
                return cardItemProvider()
            case .tunnelsHeader(let title):
                return makeTunnelsHeaderItem(title: title)
            case .tunnelRow(let tunnel, let isEnabled):
                return tunnelItemProvider(tunnel, isEnabled)
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

    /// Заголовок секции Tunnels: неактивный нативный пункт с приглушённым
    /// мелким шрифтом — группировка без отдельной view; `title` остаётся,
    /// чтобы VoiceOver его читал.
    private static func makeTunnelsHeaderItem(title: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.title = title
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        return item
    }
}

/// Владелец `NSStatusItem` (иконка on/off, текст статуса — в accessibilityLabel
/// для VoiceOver) и `NSMenu` с AppKit-гибридом:
/// первый пункт — SwiftUI-карточка `StatusCardView` в `NSHostingView`,
/// ниже — нативные пункты со стандартной клавиатурной навигацией и секция
/// Tunnels (строки-туннели в `NSHostingView`, клик — up/down через модель).
///
/// Меню пересобирается в `menuNeedsUpdate` — при каждом открытии данные свежие
/// (включая `loadTunnels()`); изменение `tunnels` при открытом меню
/// пересобирает секцию (list асинхронный). Контент карточки обновляется сам
/// (`@ObservedObject` модели), контроллер реагирует на `objectWillChange`
/// иконкой, состоянием пункта «Обновить», пунктом сервиса
/// (установить/обновить/удалить) и перемером высоты карточки.
///
/// Создавать на главном потоке (единственный владелец — AppDelegate приложения).
public final class StatusItemController: NSObject, NSMenuDelegate {
    /// Ширина карточки; внутри `StatusCardView` задана `.frame(width: 320)`.
    private static let cardWidth: CGFloat = 320

    private let model: WireGuardStatusModel
    /// Установщик сервиса для пунктов меню (продакшн — `InstallerService`,
    /// колбэки привязываются в AppDelegate).
    private let installer: ServiceInstalling
    private let statusItem: NSStatusItem
    private var cancellable: AnyCancellable?
    /// Ответ `list` асинхронный: к моменту первой сборки меню список туннелей
    /// ещё пуст — его прибытие пересобирает секцию в открытом меню.
    private var tunnelsCancellable: AnyCancellable?
    /// Меню сейчас открыто (`menuNeedsUpdate`…`menuDidClose`): пересборка по
    /// изменению `tunnels` нужна только открытому — закрытое соберётся свежим
    /// при следующем открытии.
    private var isMenuOpen = false
    /// Состояние сервиса последней реакции: смена при открытом меню меняет и
    /// видимость секции Tunnels — без отслеживания секция жила бы своей
    /// жизнью (пункт сервиса обновляется живьём отдельно).
    private var lastServiceState: ServiceState = .absent
    private weak var menu: NSMenu?
    /// Хостинг-вью карточки последней сборки — для перемера высоты (ⓘ-легенда).
    private var cardHostingView: NSHostingView<StatusCardView>?
    /// Видимость легенды (ⓘ): хранится здесь, чтобы переживать пересборки меню
    /// (`menuNeedsUpdate` создаёт новый `NSHostingView` — `@State` вью сбрасывается).
    private var isLegendVisible = false

    public init(model: WireGuardStatusModel, installer: ServiceInstalling) {
        self.model = model
        self.installer = installer
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        updateStatusIcon()

        let menu = NSMenu()
        // isEnabled задаём сами: заголовок секции Tunnels — всегда disabled
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
        // Отдельная подписка на `tunnels` (публикуется только по факту
        // изменения — list/recompute, не каждый тик): прибытие списка или
        // переворот isUp пересобирает секцию, пока меню открыто.
        tunnelsCancellable = model.$tunnels
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.tunnelsDidChange() }
    }

    deinit {
        cancellable?.cancel()
        tunnelsCancellable?.cancel()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func modelDidChange() {
        updateStatusIcon()
        updateRefreshItemEnabledState()
        updateServiceItem()
        resizeCardToContent()
        serviceStateDidChange()
    }

    /// Смена состояния сервиса при открытом меню меняет и секцию Tunnels:
    /// демон умер — строки обязаны исчезнуть (клик по ним — гарантированный
    /// connectionRefused), демон появился — список подтягивается, не дожидаясь
    /// переоткрытия меню. Закрытое меню соберётся свежим при следующем открытии.
    private func serviceStateDidChange() {
        defer { lastServiceState = model.serviceState }
        guard Self.shouldReloadTunnelsAndRebuildMenu(
            previousServiceState: lastServiceState,
            currentServiceState: model.serviceState,
            isMenuOpen: isMenuOpen
        ) else { return }
        model.loadTunnels()
        rebuildMenu()
    }

    /// Решение о живой реакции на смену состояния сервиса — статически, чтобы
    /// тестировать без создания `NSStatusItem` (как `performStatusAction`):
    /// реагируем только на смену И только при открытом меню — закрытое
    /// соберётся свежим при следующем открытии, отсутствие смены — не событие.
    static func shouldReloadTunnelsAndRebuildMenu(
        previousServiceState: ServiceState,
        currentServiceState: ServiceState,
        isMenuOpen: Bool
    ) -> Bool {
        currentServiceState != previousServiceState && isMenuOpen
    }

    /// Иконка в бар: заливка = подключён, контур = нет (ошибка wg или устаревший
    /// снапшот = Off, детали — в карточке). Template-режим сам выбирает цвет
    /// под тему.
    private func updateStatusIcon() {
        statusItem.button?.image = StatusIcon.image(connected: Self.iconConnected(for: model))
        statusItem.button?.setAccessibilityLabel(model.menuTitle)
    }

    /// Решение иконки из модели — статически, чтобы тестировать без создания
    /// `NSStatusItem` (как `performStatusAction`): иконка следует свежести
    /// снапшота (`showsConnected`), замороженные данные щиток не зажигают.
    static func iconConnected(for model: WireGuardStatusModel) -> Bool {
        model.showsConnected
    }

    /// Загруженность меняется и при открытом меню (тик обновления работает
    /// в .common-режиме run loop) — состояние пункта «Обновить» синхронизируем
    /// живьём, не дожидаясь пересборки в `menuNeedsUpdate`. Туннельная
    /// операция в полёте глушит show-тик — клик по «Обновить» был бы молчаливым
    /// no-op, пункт отключается вместе со строками.
    private func updateRefreshItemEnabledState() {
        guard let menu else { return }
        for item in menu.items where item.tag == StatusMenuAction.refresh.rawValue {
            item.isEnabled = !model.isLoading && model.inFlightTunnels.isEmpty
        }
    }

    /// Состояние сервиса тоже выводится на каждом тике и может смениться при
    /// открытом меню (демон поднялся или умер): заголовок и действие пункта
    /// синхронизируем живьём тем же маппингом, что и в сборке меню. Здесь же —
    /// кликабельность: клик по строке туннеля меню не закрывает, и операция,
    /// стартовавшая в открытом меню, обязана тут же отключить пункт сервиса
    /// (как «Обновить» в `updateRefreshItemEnabledState`).
    private func updateServiceItem() {
        guard let menu else { return }
        let action = StatusMenuStructure.serviceAction(for: model.serviceState)
        let serviceTags: Set<Int> = [
            StatusMenuAction.installService.rawValue,
            StatusMenuAction.uninstallService.rawValue,
        ]
        for item in menu.items where serviceTags.contains(item.tag) {
            item.tag = action.id.rawValue
            item.title = action.title
            item.isEnabled = model.inFlightTunnels.isEmpty
        }
    }

    // MARK: - NSMenuDelegate

    public func menuNeedsUpdate(_ menu: NSMenu) {
        isMenuOpen = true
        // Список туннелей тянется при каждом открытии (list асинхронный —
        // ответ пересоберёт секцию по подписке, если придёт после сборки).
        model.loadTunnels()
        rebuildMenu()
    }

    public func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    // MARK: - Сборка меню

    /// Список туннелей пришёл (или пересчитался isUp) — пересобираем меню,
    /// пока оно открыто: иначе при первом открытии секция появилась бы только
    /// со второго раза. Закрытое меню соберётся свежим при следующем открытии.
    private func tunnelsDidChange() {
        guard isMenuOpen else { return }
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let menu else { return }
        let items = StatusMenuFactory.makeItems(
            from: StatusMenuStructure.entries(
                refreshEnabled: !model.isLoading,
                serviceState: model.serviceState,
                tunnels: model.tunnels,
                hasInFlightTunnelOperation: !model.inFlightTunnels.isEmpty
            ),
            target: self,
            action: #selector(statusMenuAction(_:)),
            cardItemProvider: makeCardItem,
            tunnelItemProvider: makeTunnelItem
        )
        menu.removeAllItems()
        items.forEach(menu.addItem)
    }

    /// Строка туннеля: SwiftUI-контент наблюдает модель — спиннер,
    /// кликабельность и isUp обновляются живьём без пересборки меню.
    /// `isEnabled` структуры (снапшот на момент сборки) вью не нужен:
    /// состояние выводится из тех же источников модели.
    private func makeTunnelItem(tunnel: TunnelInfo, isEnabled: Bool) -> NSMenuItem {
        let rowView = TunnelRowView(model: model, tunnelName: tunnel.name) { [weak self] name in
            self?.model.toggleTunnel(named: name)
        }
        let hostingView = NSHostingView(rootView: rowView)
        // Высота строки фиксирована контентом — мерим fittingSize тем же
        // приёмом, что и карточку.
        hostingView.frame = NSRect(origin: .zero, size: NSSize(width: Self.cardWidth, height: 1))
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(
            origin: .zero,
            size: NSSize(
                width: max(Self.cardWidth, ceil(fittingSize.width)),
                height: max(1, ceil(fittingSize.height))
            )
        )

        let item = TunnelMenuItem()
        item.title = ""
        item.view = hostingView
        // enabled, чтобы клики по строке (SwiftUI Button) доходили
        item.isEnabled = true
        return item
    }

    private func makeCardItem() -> NSMenuItem {
        let cardView = StatusCardView(
            model: model,
            initialLegendVisible: isLegendVisible
        ) { [weak self] visible in
            self?.legendToggled(to: visible)
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

    /// Переключение легенды (ⓘ): запоминаем видимость и перемеряем карточку.
    private func legendToggled(to visible: Bool) {
        isLegendVisible = visible
        // SwiftUI коммитит рендер после текущего стека вызовов: синхронный замер
        // видел бы старую высоту (ⓘ исчезала до следующего тика) — мерим на
        // следующем проходе run loop, когда контент уже перестроен.
        DispatchQueue.main.async { [weak self] in self?.resizeCardToContent() }
    }

    /// Карточка изменила высоту (ⓘ-легенда, ошибка) — перемеряем и обновляем frame.
    /// Замер `fittingSize` валиден только после рендера SwiftUI: путь модели
    /// (`modelDidChange`) уже доставляется асинхронно (`receive(on:)`),
    /// переключение легенды диспатчится в `legendToggled`.
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
    /// создания `NSStatusItem` (quit и установщик инжектятся: реальный
    /// обработчик зовёт `NSApplication.terminate`, установщик — InstallerService).
    static func performStatusAction(
        _ action: StatusMenuAction,
        model: WireGuardStatusModel,
        installer: ServiceInstalling? = nil,
        quit: () -> Void
    ) {
        // Установка/удаление во время туннельной операции — молчаливый no-op:
        // скрипты стартуют с `launchctl bootout` → SIGTERM демону → отмена
        // задачи исполнителя → SIGKILL wg-quick посреди применения адресов/
        // маршрутов/DNS (полуприменённый туннель — исход, от которого операции
        // специально защищены от отмены). Пункт меню отключается вместе со
        // строками; guard — вторая линия, как one-op-guard в `toggleTunnel`
        // (ре-рендер disabled асинхронен).
        if action == .installService || action == .uninstallService {
            guard model.inFlightTunnels.isEmpty else { return }
        }
        switch action {
        case .refresh:
            // Кнопка «Обновить» — принудительный рескан имён туннелей
            model.refresh(forceNameRescan: true)
        case .openConfigs:
            model.openWireGuardConfigFolder()
        case .installService:
            // «Установить» и «Обновить» — одно действие: скрипт установки
            // идемпотентен (bootout → cp → bootstrap). Промпт и разбор
            // результата — внутри установщика (отмена — тихий no-op, сбой —
            // в ошибку модели колбэком), здесь только запуск.
            guard let installer else { return }
            Task { await installer.install() }
        case .uninstallService:
            guard let installer else { return }
            Task { await installer.uninstall() }
        case .quit:
            quit()
        }
    }

    @objc private func statusMenuAction(_ sender: NSMenuItem) {
        guard let action = StatusMenuAction(rawValue: sender.tag) else { return }
        Self.performStatusAction(action, model: model, installer: installer) {
            NSApplication.shared.terminate(nil)
        }
    }
}
