import Foundation

/// Клиент туннельных операций демона: `list` → имена конфигов wg-quick,
/// `up`/`down` → управление туннелем. Транспорт — общий `HelperClient`;
/// интерпретация своя: общая часть (decode + сверка версий заголовка — старый
/// build или чужой протокол → `daemonOutdated` даже по `err`), а коды `err`
/// маппятся в локализованные `.generic` — новые кейсы `StatusFailure` не
/// вводятся (иначе сломается исчерпывающий switch в `ServiceState.derive` и
/// его тесты). Деталь с wire не берётся: демон туннельные ошибки отправляет
/// только с кодом, без детали (Task 4). Тишина до дедлайна — тоже
/// `.generic(error.tunnel_op_failed)`, не `commandTimeout`: его текст — про
/// `wg show`, чужой команде не подходит.
public struct SocketTunnelClient {
    /// Продакшн-дедлайн полного обмена операцией. Покрывает худший случай
    /// очереди последовательного accept-loop демона: show-тик, стартовавший
    /// ДО клика (подавление тика в модели работает только для последующих),
    /// держит демон до `WGShowExecutor.defaultTimeout +
    /// 2 * defaultKillGrace` (4.0 c), затем op-бюджет
    /// `WGQuickExecutor.defaultOpTimeout + 2 * defaultKillGrace` (9.0 c) —
    /// 13.0 c суммарно; инвариант закреплён тестом.
    public static let opTimeout: TimeInterval = 16.0

    private let client: HelperClient
    private let timeout: TimeInterval

    public init(
        socketPath: String = helperSocketPath,
        timeout: TimeInterval = SocketTunnelClient.opTimeout
    ) {
        self.client = HelperClient(socketPath: socketPath)
        self.timeout = timeout
    }

    /// Имена операбельных туннелей из конфигов демона (`ok` с именами по
    /// одному в строке; пустой payload — пустой список).
    public func list() async throws -> [String] {
        let payload = try await exchange(.list)
        return payload.split(separator: "\n").map(String.init)
    }

    public func up(_ name: String) async throws {
        try await exchange(.up(name))
    }

    public func down(_ name: String) async throws {
        try await exchange(.down(name))
    }

    /// Обмен + командно-специфичная интерпретация: `ok` → payload (для
    /// up/down демон отвечает успехом без payload), `err` → локализованный
    /// `.generic`; транспортные сбои — в свои кейсы (тишина — общий провал
    /// операции).
    private func exchange(_ request: HelperRequest) async throws -> String {
        let response: String
        do {
            response = try await client.exchange(request, timeout: timeout)
        } catch let error as HelperClientError {
            throw Self.translate(error)
        }

        let decoded = try HelperClient.decodeAndVerifyVersions(response)
        switch decoded {
        case .ok(_, _, let payload):
            return payload
        case .err(_, _, .quickMissing, _):
            throw StatusFailure.generic(L10n.string("error.wgquick_missing"))
        case .err(_, _, .tunnelNotFound, _):
            throw StatusFailure.generic(L10n.string("error.tunnel_not_found"))
        case .err(_, _, .wgFailed, _):
            throw StatusFailure.generic(L10n.string("error.tunnel_op_failed"))
        case .err(_, _, .wgMissing, _):
            // `wg-missing` — код `show`; туннельным операциям демон его не
            // шлёт (wg-quick зовёт wg внутри — его отсутствие = wg-failed).
            // Защитная ветка исчерпывающего switch: истина «wg не установлен».
            throw StatusFailure.wgMissing
        }
    }

    /// Транспортные сбои → кейсы `StatusFailure`. Тишина до дедлайна —
    /// `.generic`, не `commandTimeout`: его строка локализована под `wg show`.
    private static func translate(_ error: HelperClientError) -> StatusFailure {
        switch error {
        case .connectionRefused:
            return .connectionRefused
        case .badChannel:
            return .badResponse
        case .timedOut:
            return .generic(L10n.string("error.tunnel_op_failed"))
        }
    }
}
