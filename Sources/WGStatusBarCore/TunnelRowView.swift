import SwiftUI

/// Чистые данные строки туннеля: считаются из модели без UI, тестируются
/// юнит-тестами (по образцу `StatusCardViewModel`).
///
/// `isBusy` — операция над ЭТИМ туннелем в полёте (спиннер вместо точки);
/// `isEnabled` — операций нет вообще: одна операция за раз, пока что-то в
/// полёте, некликабельны все строки, включая эту. Кнопка деталей от этих
/// флагов не зависит: открытие вьювера — не туннельная операция.
public struct TunnelRowViewModel: Equatable {
    public let name: String
    public let isUp: Bool
    public let isBusy: Bool
    public let isEnabled: Bool

    init(name: String, isUp: Bool, inFlightTunnels: Set<String>) {
        self.name = name
        self.isUp = isUp
        self.isBusy = inFlightTunnels.contains(name)
        self.isEnabled = inFlightTunnels.isEmpty
    }

    /// Подпись VoiceOver: состояние туннеля (включён/выключен).
    public var accessibilityLabel: String {
        L10n.string(isUp ? "tunnel.accessibility.on" : "tunnel.accessibility.off", name)
    }

    /// Подпись VoiceOver кнопки деталей: открыть конфиг этого туннеля —
    /// отдельная от toggle подпись и отдельный hit-target.
    public var detailsAccessibilityLabel: String {
        L10n.string("tunnel.accessibility.details", name)
    }
}

/// Строка туннеля секции Tunnels: ●/○ + имя (клик — toggle) и отдельная
/// кнопка деталей (клик — вьювер конфига). Наблюдает модель
/// (`@ObservedObject`): спиннер, кликабельность и isUp обновляются живьём
/// без пересборки меню — isUp выводится lookup'ом из `tunnels` (последний
/// ответ `state` — демон источник состояния, снапшот интерфейсов здесь не
/// при делах), isBusy/isEnabled — из `inFlightTunnels`. Клик внутри
/// view-based пункта не закрывает меню (`TunnelMenuItem`, прецедент —
/// интерактивные контролы карточки); закрытие трекинга для окна вьювера —
/// забота обработчика `onShowDetails` (StatusItemController).
struct TunnelRowView: View {
    @ObservedObject private var model: WireGuardStatusModel
    private let tunnelName: String
    private let onToggle: (String) -> Void
    /// Кнопка деталей: имя выбранного туннеля уходит в вьювер конфига.
    private let onShowDetails: (String) -> Void

    init(
        model: WireGuardStatusModel,
        tunnelName: String,
        onToggle: @escaping (String) -> Void,
        onShowDetails: @escaping (String) -> Void
    ) {
        self.model = model
        self.tunnelName = tunnelName
        self.onToggle = onToggle
        self.onShowDetails = onShowDetails
    }

    private var row: TunnelRowViewModel {
        TunnelRowViewModel(
            name: tunnelName,
            isUp: model.tunnels.first(where: { $0.name == tunnelName })?.isUp ?? false,
            inFlightTunnels: model.inFlightTunnels
        )
    }

    var body: some View {
        HStack(spacing: 4) {
            toggleControl
            detailsControl
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        // Ширина карточки (320 в StatusCardView) — строки с ней вровень.
        .frame(width: 320, alignment: .leading)
    }

    /// Главный контрол строки: точка/спиннер + имя, клик — up/down. Занимает
    /// всю ширину кроме кнопки деталей — крупный hit-target, как раньше.
    private var toggleControl: some View {
        Button {
            onToggle(row.name)
        } label: {
            HStack(spacing: 8) {
                if row.isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else if row.isUp {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 10, height: 10)
                } else {
                    Circle()
                        .strokeBorder(Color.secondary, lineWidth: 1)
                        .frame(width: 10, height: 10)
                }
                Text(row.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        // Одна операция за раз: пока in-flight, toggle не принимает клики
        // и приглушается (спиннер остаётся видимым).
        .allowsHitTesting(row.isEnabled)
        .opacity(row.isEnabled ? 1 : 0.5)
        .accessibilityLabel(Text(row.accessibilityLabel))
    }

    /// Кнопка деталей: отдельный hit-target и подпись VoiceOver; не глушится
    /// туннельными операциями — вьювер в них не участвует (ошибки загрузки —
    /// оконные, с Reload).
    private var detailsControl: some View {
        Button {
            onShowDetails(row.name)
        } label: {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text(row.detailsAccessibilityLabel))
    }
}
