import AppKit
import SwiftUI

/// Чистые данные карточки статуса: считаются из модели без UI, тестируются юнит-тестами.
///
/// `StatusCardView` — тонкая вёрстка поверх этого типа; имена полей view-модели —
/// готовые строки для отображения.
public struct StatusCardViewModel: Equatable {
    /// Пир в карточке: endpoint, трафик, хендшейк; pubkey — источник идентификатора,
    /// показывается укороченным только когда у интерфейса больше одного пира.
    public struct Peer: Identifiable, Equatable {
        public let id: String
        public let publicKey: String
        public let endpoint: String?
        /// «↓ N KiB  ↑ N KiB» одной строкой.
        public let trafficText: String
        /// «N назад»; nil = never — текст подставляет вью.
        public let handshakeText: String?
        public let freshness: HandshakeFreshness

        init(_ peer: WGPeer, now: Date) {
            self.id = peer.publicKey
            self.publicKey = peer.publicKey
            self.endpoint = peer.endpoint
            self.trafficText = "↓ \(Formatters.formatBytes(peer.rxBytes))  ↑ \(Formatters.formatBytes(peer.txBytes))"
            self.handshakeText = peer.latestHandshake.map { Formatters.formatAgo($0, now: now) }
            self.freshness = HandshakeFreshness.freshness(date: peer.latestHandshake, now: now)
        }
    }

    /// Интерфейс в карточке: заголовок (точка + имена) и маршрутизация уровня интерфейса.
    public struct Interface: Identifiable, Equatable {
        public let id: String
        /// Человекочитаемое имя (имя конфига wg-quick).
        public let displayName: String
        /// Сырое имя интерфейса (`utun3`) — показывается мелко под заголовком.
        public let name: String
        /// Цвет точки заголовка: fresh — green, aging — orange, stale/never — secondary.
        /// При нескольких пирах — самый свежий хендшейк.
        public let freshness: HandshakeFreshness
        /// Маршрутизация уровня интерфейса: любой пир с default route → fullTunnel.
        public let routeScope: RouteScope
        /// Бейдж «весь трафик» или список подсетей одной строкой; nil — маршрутов нет.
        public let routeText: String?
        public let peers: [Peer]

        /// Pubkey пиров показывается только при >1 пире — иначе один очевиден.
        public var showsPublicKeys: Bool {
            peers.count > 1
        }

        init(_ interface: WGInterface, now: Date) {
            self.id = interface.name
            self.displayName = interface.displayName
            self.name = interface.name
            self.freshness = Self.freshest(
                of: interface.peers.map { HandshakeFreshness.freshness(date: $0.latestHandshake, now: now) }
            )
            self.peers = interface.peers.map { Peer($0, now: now) }

            let peerEntries = interface.peers.map { RouteScope.entries(allowedIps: $0.allowedIps) }
            let scopes = peerEntries.map(RouteScope.init(entries:))
            if scopes.contains(.fullTunnel) {
                self.routeScope = .fullTunnel
                self.routeText = L10n.string("badge.full_tunnel")
            } else if scopes.contains(.splitTunnel) {
                self.routeScope = .splitTunnel
                self.routeText = Self.subnetList(of: peerEntries)
            } else {
                self.routeScope = .none
                self.routeText = nil
            }
        }

        /// Самая свежая из свежестей пиров (fresh > aging > stale > never); пусто → never.
        private static func freshest(of values: [HandshakeFreshness]) -> HandshakeFreshness {
            let rank: [HandshakeFreshness: Int] = [.fresh: 0, .aging: 1, .stale: 2, .never: 3]
            return values.min { (rank[$0] ?? 3) < (rank[$1] ?? 3) } ?? .never
        }

        /// Подсети всех пиров одной строкой, без дублей, default-маршрутов и
        /// placeholder'а `(none)`, в порядке первого появления.
        private static func subnetList(of peerEntries: [[String]]) -> String? {
            var seen: Set<String> = []
            var ordered: [String] = []
            for entries in peerEntries {
                for subnet in entries where subnet != "(none)" && !RouteScope.defaultRoutes.contains(subnet) {
                    if seen.insert(subnet).inserted {
                        ordered.append(subnet)
                    }
                }
            }
            return ordered.isEmpty ? nil : ordered.joined(separator: ", ")
        }
    }

    public let interfaces: [Interface]
    public let isLoading: Bool
    /// Данные снапшота устарели (истёк грейс): карточка их не прячет, а
    /// приглушает и помечает. Ошибка тика при этом показывается как обычно.
    public let isStale: Bool
    /// Строка ошибки последнего тика — `failure?.localizedMessage`.
    public let errorMessage: String?
    /// Команды установки CLI при `.wgMissing` (блок под ошибкой, клик —
    /// копирование); пусто для прочих ошибок.
    public let installCommands: [String]

    /// Команды установки CLI WireGuard: Homebrew и MacPorts. Литеральные
    /// константы — не локализуются (это команды, а не текст).
    public static let wgInstallCommands = [
        "brew install wireguard-tools",
        "sudo port install wireguard-tools",
    ]

    public init(
        interfaces: [WGInterface],
        isLoading: Bool = false,
        failure: StatusFailure? = nil,
        isStale: Bool = false,
        now: Date = Date()
    ) {
        self.interfaces = interfaces.map { Interface($0, now: now) }
        self.isLoading = isLoading
        self.isStale = isStale
        self.errorMessage = failure?.localizedMessage
        self.installCommands = failure == .wgMissing ? Self.wgInstallCommands : []
    }

    /// Строка пустого состояния (интерфейсов нет); nil — когда есть что показать.
    public var emptyStateText: String? {
        interfaces.isEmpty ? L10n.string("status.no_interfaces") : nil
    }

    /// Укороченный pubkey для показа при нескольких пирах: голова + … + хвост.
    public static func shortPublicKey(_ key: String) -> String {
        guard key.count > 12 else { return key }
        return key.prefix(8) + "…" + key.suffix(4)
    }
}

/// Карточка статуса для первого пункта NSMenu (Task 7 вставит её в `NSHostingView`).
///
/// `onContentChange` вызывается, когда содержимое меняет высоту (ⓘ-легенда) —
/// владелец по колбэку перемеряет и обновляет frame пункта-карточки
/// (`resizeCardToContent`), само меню не пересобирается.
public struct StatusCardView: View {
    @ObservedObject private var model: WireGuardStatusModel
    private let onContentChange: () -> Void
    @State private var isLegendVisible = false

    public init(model: WireGuardStatusModel, onContentChange: @escaping () -> Void = {}) {
        self.model = model
        self.onContentChange = onContentChange
    }

    public var body: some View {
        let card = StatusCardViewModel(
            interfaces: model.interfaces,
            isLoading: model.isLoading,
            failure: model.lastFailure,
            isStale: model.isDataStale
        )

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Spacer()
                if card.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    isLegendVisible.toggle()
                    onContentChange()
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(L10n.string("legend.toggle")))
            }

            if let error = card.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            if !card.installCommands.isEmpty {
                installCommandsSection(card.installCommands)
            }

            if let emptyText = card.emptyStateText {
                Text(emptyText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                if card.isStale {
                    Text(L10n.string("status.stale_data"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                interfacesSection(card)
            }

            if isLegendVisible {
                legend
            }
        }
        .padding(12)
        .frame(width: 320)
    }

    /// Блок интерфейсов карточки: при устаревших данных приглушается
    /// (пометка «данные устарели» над ним остаётся читаемой).
    private func interfacesSection(_ card: StatusCardViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(card.interfaces) { interface in
                interfaceSection(interface)
            }
        }
        .opacity(card.isStale ? 0.5 : 1)
    }

    private func interfaceSection(_ interface: StatusCardViewModel.Interface) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color(for: interface.freshness))
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(interface.displayName)
                        .font(.headline)
                    Text(interface.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let routeText = interface.routeText {
                if interface.routeScope == .fullTunnel {
                    Text(routeText)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                } else {
                    Text(routeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            ForEach(interface.peers) { peer in
                peerSection(peer, showsPublicKey: interface.showsPublicKeys)
            }
        }
    }

    private func peerSection(_ peer: StatusCardViewModel.Peer, showsPublicKey: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if showsPublicKey {
                Text(StatusCardViewModel.shortPublicKey(peer.publicKey))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let endpoint = peer.endpoint {
                Text(endpoint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(peer.trafficText)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(peer.handshakeText ?? L10n.string("peer.handshake_never"))
                .font(.caption)
                .foregroundStyle(color(for: peer.freshness))
        }
    }

    /// Блок команд установки CLI (`wgMissing`): моноширинные строки, клик —
    /// копирование в pasteboard. Высота блока постоянна — `onContentChange`
    /// не нужен.
    private func installCommandsSection(_ commands: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(commands, id: \.self) { command in
                InstallCommandRow(command: command)
            }
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            legendRow(color: .green, text: L10n.string("legend.fresh"))
            legendRow(color: .orange, text: L10n.string("legend.aging"))
            legendRow(color: Color.secondary, text: L10n.string("legend.stale"))
        }
    }

    private func legendRow(color: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func color(for freshness: HandshakeFreshness) -> Color {
        switch freshness {
        case .fresh: .green
        case .aging: .orange
        case .stale, .never: .secondary
        }
    }
}

/// Строка команды установки CLI: моноширинная команда + действие копирования;
/// после клика кратко показывается «скопировано», затем метка возвращается.
private struct InstallCommandRow: View {
    private static let copiedIndicatorInterval: TimeInterval = 1.5

    let command: String
    @State private var isCopied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            isCopied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.copiedIndicatorInterval) {
                isCopied = false
            }
        } label: {
            HStack(spacing: 6) {
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(L10n.string(isCopied ? "card.copied" : "card.copy"))
                    .font(.caption2)
                    .foregroundStyle(.tint)
            }
        }
        .buttonStyle(.borderless)
        .accessibilityHint(Text(L10n.string("card.copy")))
    }
}
