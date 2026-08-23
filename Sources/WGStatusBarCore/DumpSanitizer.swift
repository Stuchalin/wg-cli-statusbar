import Foundation

/// Санирует сырой вывод `wg show all dump`: секретные поля заменяются на
/// placeholder `(none)`, остальное проходит байт-в-байт. Вызывается демоном
/// перед отправкой дампа в сокет — единственная точка, где секступаются
/// секреты (private-key, preshared-key), в канал и память приложения они
/// не попадают.
///
/// Трекинг строк повторяет `parseWGShowDump`: строка интерфейса — ровно 5
/// полей (секрет — поле 2, private key), строка пира — ровно 9 полей и
/// только после строки интерфейса (секрет — поле 3, preshared key).
///
/// Fail-closed: строка из 5+ полей нераспознанной формы (мусор или дрейф
/// формата `wg` после обновления wireguard-tools — версии демона и wg
/// независимы) не покидает санитайзер с секретами — позиция секрета в ней
/// неизвестна, поэтому вычищаются оба слота (поля 2 и 3). Короткие строки
/// (до 4 полей) носителями секретов в известных форматах не бывают и
/// проходят как есть.
public func sanitizeWGDump(_ dump: String) -> String {
    var sawInterfaceLine = false
    var sanitizedLines: [String] = []

    for rawLine in dump.split(separator: "\n", omittingEmptySubsequences: false) {
        var fields = rawLine.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)

        if fields.count == 5 {
            fields[1] = "(none)"
            sawInterfaceLine = true
        } else if fields.count == 9, sawInterfaceLine {
            fields[2] = "(none)"
        } else if fields.count >= 5 {
            fields[1] = "(none)"
            fields[2] = "(none)"
        }
        // Строки до 4 полей (мусор) — как есть.
        sanitizedLines.append(fields.joined(separator: "\t"))
    }

    return sanitizedLines.joined(separator: "\n")
}
