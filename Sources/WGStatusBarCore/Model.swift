import Foundation

/// Интерфейс WireGuard из `wg show all dump`.
public struct WGInterface: Identifiable, Equatable {
    public let id: String
    /// Сырое имя интерфейса (`utun3`, `wg0`).
    public let name: String
    /// Человекочитаемое имя (имя конфига wg-quick от `WireGuardTunnelNamer`);
    /// пока имя не разрезолвлено — совпадает с `name`.
    public var displayName: String
    public var peers: [WGPeer]

    /// Подключён, если хоть один пир активен (хендшейк fresh|aging).
    public var isConnected: Bool {
        peers.contains { $0.isActive }
    }

    public init(name: String, peers: [WGPeer], displayName: String? = nil) {
        self.id = name
        self.name = name
        self.displayName = displayName ?? name
        self.peers = peers
    }
}

/// Пир интерфейса WireGuard из `wg show all dump`.
public struct WGPeer: Identifiable, Equatable {
    public let id: String
    public let publicKey: String
    public var endpoint: String?
    public var allowedIps: String?
    /// Время последнего хендшейка; `nil` = never (epoch 0 в дампе).
    public var latestHandshake: Date?
    public var rxBytes: UInt64
    public var txBytes: UInt64

    public init(
        publicKey: String,
        endpoint: String? = nil,
        allowedIps: String? = nil,
        latestHandshake: Date? = nil,
        rxBytes: UInt64 = 0,
        txBytes: UInt64 = 0
    ) {
        self.id = publicKey
        self.publicKey = publicKey
        self.endpoint = endpoint
        self.allowedIps = allowedIps
        self.latestHandshake = latestHandshake
        self.rxBytes = rxBytes
        self.txBytes = txBytes
    }

    /// Пир активен, пока хендшейк свежий или стареющий (green|orange).
    public var isActive: Bool {
        HandshakeFreshness.freshness(date: latestHandshake).isActive
    }
}

/// Туннель из конфигов wg-quick (демон, запрос `list`): имя = basename
/// конфига. `isUp` — не данные демона, а вывод модели из текущего снапшота
/// `wg show` (`WireGuardStatusModel.isTunnelUp(named:)`): пересчитывается на
/// каждом успешном тике и каждом ответе `list`.
public struct TunnelInfo: Equatable {
    public let name: String
    public let isUp: Bool

    public init(name: String, isUp: Bool) {
        self.name = name
        self.isUp = isUp
    }
}
