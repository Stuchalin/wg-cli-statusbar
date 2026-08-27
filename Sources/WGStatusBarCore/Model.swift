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

/// Туннель из конфигов wg-quick (демон, запрос `state`): имя = basename
/// конфига. `isUp` — данные демона, а не вывод модели: `/var/run/wireguard`
/// читаем только root, приложение состояние из дампа не выводит.
/// Обновляется каждым ответом `state` (открытие меню, ответ up/down, переход
/// serviceState) — 5-с тик его не переворачивает.
public struct TunnelInfo: Equatable {
    public let name: String
    public let isUp: Bool

    public init(name: String, isUp: Bool) {
        self.name = name
        self.isUp = isUp
    }
}

/// Строка состояния туннеля из запроса `state` демона. В отличие от
/// `TunnelInfo`, и `isUp`, и интерфейс — данные демона, а не вывод модели:
/// `/var/run/wireguard` читаем только root, приложение состояние из дампа
/// не выводит. `utun` заполнен только у поднятого туннеля.
public struct TunnelState: Equatable {
    public let name: String
    public let isUp: Bool
    /// Имя интерфейса поднятом туннеля (`utun2`); у опущенного — `nil`.
    public let utun: String?

    public init(name: String, isUp: Bool, utun: String?) {
        self.name = name
        self.isUp = isUp
        self.utun = utun
    }
}
