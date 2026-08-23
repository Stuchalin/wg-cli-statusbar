import Foundation

/// Продакшн-путь сокета демона: его биндит `DaemonServer`, приложение
/// подключается через `SocketWGShowRunner`, модель пробует файл на каждом
/// refresh для выбора раннера.
public let helperSocketPath = "/var/run/wgstatusbar.sock"

/// Состояние привилегированного сервиса (демона), выведенное из фактов
/// последнего refresh-тика — не хранится, а пересчитывается, застрявших
/// состояний нет. Управляет пунктом меню установки/обновления/удаления.
public enum ServiceState: Equatable {
    /// Сокет-файла нет — сервис не установлен (или полностью удалён).
    case absent
    /// Сокет есть, но демон не отвечает: коннект отклонён, тишина до
    /// клиентского дедлайна, мусор в ответе или мгновенный EOF.
    case broken
    /// Демон отвечает чужим протоколом или старым build (в любом ответе,
    /// включая err) — сервис пора обновить.
    case outdated
    /// Демон ответил текущим протоколом и build.
    case installed

    /// Выводит состояние из фактов одного тика: наличия сокет-файла на старте
    /// refresh и исхода обмена. Без сокета раннером был фолбэк (процессный),
    /// обмена с демоном не было — `absent` при любом исходе. При живом сокете
    /// типизированная ошибка `SocketWGShowRunner`'а уже содержит разбор
    /// заголовка ответа: `daemonOutdated` покрывает и чужой протокол, и старый
    /// build (в ok- и err-ответах); `wgMissing`/`generic` — err-ответы с
    /// валидным заголовком текущей версии: демон жив и актуален, проблема в
    /// wg, не в сервисе — на состояние сервиса не влияют.
    public static func derive(socketFileExists: Bool, outcome: Result<String, StatusFailure>) -> ServiceState {
        guard socketFileExists else { return .absent }
        switch outcome {
        case .success:
            return .installed
        case .failure(.daemonOutdated):
            return .outdated
        case .failure(.connectionRefused), .failure(.commandTimeout), .failure(.badResponse):
            return .broken
        case .failure(.wgMissing), .failure(.generic):
            return .installed
        }
    }
}
