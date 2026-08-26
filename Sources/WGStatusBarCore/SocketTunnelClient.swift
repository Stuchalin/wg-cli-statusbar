import Foundation

/// Клиент туннельных операций демона: `state` → состояние туннелей (имена +
/// isUp + utun — данные демона, а не вывод модели), `up`/`down` → управление
/// туннелем. Транспорт — общий `HelperClient`; интерпретация своя: общая
/// часть (decode + сверка версий заголовка — старый build или чужой протокол
/// → `daemonOutdated` даже по `err`), а коды `err` маппятся в локализованные
/// `.generic` — новые кейсы `StatusFailure` не вводятся (иначе сломается
/// исчерпывающий switch в `ServiceState.derive` и его тесты). Деталь с wire
/// не берётся: демон туннельные ошибки отправляет только с кодом, без детали
/// (Task 4). Тишина до дедлайна — тоже `.generic(error.tunnel_op_failed)`,
/// не `commandTimeout`: его текст — про `wg show`, чужой команде не подходит.
/// Туннельные операции демона для модели; инжектится для тестов (мок со
/// счётчиками и программируемыми результатами — по образцу
/// `WGShowCommandRunning`). Wire-запрос `list` демон продолжает обслуживать
/// (совместимость со старым приложением), но клиентского метода у него нет —
/// модель состояние читает только через `state`.
public protocol TunnelCommandRunning {
    func state() async throws -> [TunnelState]
    func up(_ name: String) async throws
    func down(_ name: String) async throws
}

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

    /// Состояние туннелей из конфигов демона: строки payload всегда из трёх
    /// полей через `\t` — `имя\tup\tutunN` у поднятого (utun непустой),
    /// `имя\tdown\t` у опущенного (пустой); пустой payload — конфигов нет.
    /// Разбор строки с `omittingEmptySubsequences: false`: дефолтный split
    /// съедает пустое третье поле down-строк, и полей оставалось бы два.
    /// Любая строка мимо формата (не 3 поля, пустое имя, чужое слово
    /// состояния, up без utun или down с utun) — мусор формата →
    /// `.badResponse`, как битый заголовок у остальных команд.
    public func state() async throws -> [TunnelState] {
        let payload = try await exchange(.state)
        return try payload.split(separator: "\n").map { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3, !fields[0].isEmpty else {
                throw StatusFailure.badResponse
            }
            switch fields[1] {
            case "up":
                guard !fields[2].isEmpty else { throw StatusFailure.badResponse }
                return TunnelState(name: fields[0], isUp: true, utun: fields[2])
            case "down":
                guard fields[2].isEmpty else { throw StatusFailure.badResponse }
                return TunnelState(name: fields[0], isUp: false, utun: nil)
            default:
                throw StatusFailure.badResponse
            }
        }
    }

    public func up(_ name: String) async throws {
        _ = try await exchange(.up(name))
    }

    public func down(_ name: String) async throws {
        _ = try await exchange(.down(name))
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

extension SocketTunnelClient: TunnelCommandRunning {}
