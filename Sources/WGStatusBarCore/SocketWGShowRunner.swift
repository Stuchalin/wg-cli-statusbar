import Foundation

/// Типизированная ошибка получения статуса WireGuard: бросается сокет-раннером
/// (а с Task 7 — и фолбэк-процессным), модель хранит её в `lastFailure` и
/// выводит человекочитаемую строку для карточки. `wgMissing` приоритетнее
/// состояния сервиса: без CLI установка демона не помогает.
public enum StatusFailure: Error, Equatable {
    /// `wg` не установлен: `err wg-missing` от демона или exit 127 от фолбэка.
    case wgMissing
    /// Демон не ответил за клиентский дедлайн (connect+чтение целиком).
    case commandTimeout
    /// Демон отвечает чужим протоколом или старым build — обновить сервис.
    case daemonOutdated
    /// Коннект отклонён — демона нет или он умер при живом сокет-файле.
    case connectionRefused
    /// Мусор в ответе или мгновенный EOF — канал не похож на протокол.
    case badResponse
    /// Прочий сбой с готовым текстом (деталь err-ответа, stderr wg).
    case generic(String)

    /// Сообщение для карточки. `commandTimeout` переиспользует строку
    /// процессного раннера; команды установки wg (Task 9) — не здесь.
    public var localizedMessage: String {
        switch self {
        case .wgMissing:
            return L10n.string("error.wg_missing")
        case .commandTimeout:
            return L10n.string("error.wg_show_timeout")
        case .daemonOutdated:
            return L10n.string("error.daemon_outdated")
        case .connectionRefused, .badResponse:
            return L10n.string("error.service_unreachable")
        case .generic(let detail):
            return detail
        }
    }
}

extension StatusFailure: LocalizedError {
    public var errorDescription: String? { localizedMessage }
}

/// Сокет-клиент демона для `show`: подключается к unix-сокету (продакшн —
/// `/var/run/wgstatusbar.sock`), шлёт `show`, читает ответ до EOF под одним
/// дедлайном на весь обмен — транспорт в общем `HelperClient`, этот тип
/// держит только интерпретацию ответа `show`. `ok` → текст дампа (санитирован
/// демоном — модель не знает, откуда дамп); `err` → типизированная ошибка
/// кода; версии заголовка сверяются с константами приложения — чужой протокол
/// или старый build (включая err-ответы) → `daemonOutdated`; коннект отклонён
/// → `connectionRefused`; тишина до дедлайна → `commandTimeout`; мусор или
/// мгновенный EOF → `badResponse`.
public struct SocketWGShowRunner: WGShowCommandRunning {
    private let client: HelperClient
    private let timeout: TimeInterval

    /// Продакшн-дедлайн полного обмена (connect+send+чтение до EOF). Больше
    /// худшего случая бюджета демона (`WGShowExecutor.defaultTimeout +
    /// 2 * defaultKillGrace`): зависший wg обязан успеть получить err-ответ
    /// демона, а не таймаут клиента по тишине.
    public static let defaultTimeout: TimeInterval = 5.0

    public init(socketPath: String, timeout: TimeInterval = SocketWGShowRunner.defaultTimeout) {
        self.client = HelperClient(socketPath: socketPath)
        self.timeout = timeout
    }

    public func runDump() async throws -> String {
        let response: String
        do {
            response = try await client.exchange(.show, timeout: timeout)
        } catch let error as HelperClientError {
            throw Self.translate(error)
        }
        return try Self.interpret(response: response)
    }

    /// Транспортные сбои → кейсы `StatusFailure`: тишина — `commandTimeout`
    /// (текст строки — про `wg show`, это его команда).
    private static func translate(_ error: HelperClientError) -> StatusFailure {
        switch error {
        case .connectionRefused:
            return .connectionRefused
        case .timedOut:
            return .commandTimeout
        case .badChannel:
            return .badResponse
        }
    }

    /// Интерпретация ответа `show`: общая часть (decode + версии заголовка) —
    /// `HelperClient.decodeAndVerifyVersions`, здесь — только маппинг кодов:
    /// ok → дамп, err → типизированная ошибка кода.
    private static func interpret(response: String) throws -> String {
        let decoded = try HelperClient.decodeAndVerifyVersions(response)

        switch decoded {
        case .ok(_, _, let dump):
            return dump
        case .err(_, _, .wgMissing, _):
            throw StatusFailure.wgMissing
        case .err(_, _, .wgFailed, let detail):
            // Демон всегда прикладывает деталь; пустая — деградируем в общую строку.
            throw StatusFailure.generic(detail ?? L10n.string("error.service_unreachable"))
        case .err(_, _, .quickMissing, _), .err(_, _, .tunnelNotFound, _):
            // Коды туннельных операций (list/up/down) не отвечают `show` — их
            // маппинг живёт в `SocketTunnelClient`; защитная ветка исчерпывающего
            // switch для нештатного демона.
            throw StatusFailure.generic(L10n.string("error.service_unreachable"))
        }
    }
}
