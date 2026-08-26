import Foundation

/// Версия wire-протокола общения приложения с демоном. Компилируется и в
/// приложение, и в демон — числа гарантированно не расходятся. Меняется только
/// при ломающих изменениях формата (сравнение на равенство).
public let helperProtocolVersion = 1

/// Монотонный номер билда демона: бампируется с каждым релизом хелпера
/// (release-чеклист). Приложение сравнивает его с ответом демона — устаревший
/// бинарь предлагается обновить пунктом «Обновить сервис».
public let helperBuildNumber = 14

/// Запрос приложения к демону (line-based: соединение = один запрос).
public enum HelperRequest {
    case show
    case list
    case up(String)
    case down(String)
}

/// Код ошибки из заголовка `err`.
public enum HelperResponseCode: Equatable {
    case wgMissing
    case wgFailed
    /// `wg-quick` не установлен (для туннельных операций up/down).
    case quickMissing
    /// Конфиг с таким именем не найден (имя не прошло валидацию демона).
    case tunnelNotFound
}

/// Разобранный ответ демона; обе версии — в любом ответе, включая `err`
/// (outdated-детект работает и по ошибочному ответу).
public enum HelperResponse: Equatable {
    case ok(protocolVersion: Int, build: Int, dump: String)
    case err(protocolVersion: Int, build: Int, code: HelperResponseCode, detail: String?)
}

/// Кодирует запрос в строку wire-протокола (`show\n`, `list\n`,
/// `up <name>\n`, `down <name>\n`).
public func encode(_ request: HelperRequest) -> String {
    switch request {
    case .show:
        return "show\n"
    case .list:
        return "list\n"
    case .up(let name):
        return "up \(name)\n"
    case .down(let name):
        return "down \(name)\n"
    }
}

/// Разбирает ответ демона: первая строка — заголовок
/// (`ok <protocol> <build>` или `err <protocol> <build> <code> [деталь]`),
/// всё после неё — payload для `ok` (поле `dump`): дамп `show`, список имён
/// туннелей `list` (по одному в строке, каждое с `\n`) или пусто (`up`/`down`
/// отвечают успехом без payload). Правила для всех видов payload одни —
/// они сформулированы для дампа и покрывают список имён и пустой ответ
/// без правок. Текст не подошёл под формат → `nil`, вызывающий считает
/// ответ битым.
///
/// Усечённые ответы отвергаются: клиент читает до EOF, поэтому обрыв записи
/// (демон умер посреди send) выглядит как «полный» ответ без терминатора.
/// Терминатор заголовка обязателен, а payload — пустой или завершённый
/// переводом строки (`wg` терминирует каждую строку дампа, имена `list`
/// уходят построчно) — иначе заголовок `ok` без `\n` превратился бы в успех
/// с пустым payload, незавершённая последняя строка — в успех с частичным.
public func decode(response: String) -> HelperResponse? {
    guard let headerEnd = response.firstIndex(of: "\n") else { return nil }
    let header = String(response[..<headerEnd])
    let dump = headerEnd < response.endIndex
        ? String(response[response.index(after: headerEnd)...])
        : ""
    if !dump.isEmpty && !dump.hasSuffix("\n") { return nil }

    // maxSplits 4: деталь `err` — остаток заголовка целиком, с пробелами.
    let tokens = header.split(
        separator: " ",
        maxSplits: 4,
        omittingEmptySubsequences: true
    ).map(String.init)
    guard tokens.count >= 3,
          let protocolVersion = Int(tokens[1]),
          let build = Int(tokens[2])
    else { return nil }

    switch tokens[0] {
    case "ok":
        guard tokens.count == 3 else { return nil }
        return .ok(protocolVersion: protocolVersion, build: build, dump: dump)
    case "err":
        guard tokens.count >= 4 else { return nil }
        let code: HelperResponseCode
        switch tokens[3] {
        case "wg-missing":
            code = .wgMissing
        case "wg-failed":
            code = .wgFailed
        case "wg-quick-missing":
            code = .quickMissing
        case "tunnel-not-found":
            code = .tunnelNotFound
        default:
            return nil
        }
        return .err(protocolVersion: protocolVersion, build: build, code: code, detail: tokens.count > 4 ? tokens[4] : nil)
    default:
        return nil
    }
}
