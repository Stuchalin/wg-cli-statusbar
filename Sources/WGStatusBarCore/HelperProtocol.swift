import Foundation

/// Версия wire-протокола общения приложения с демоном. Компилируется и в
/// приложение, и в демон — числа гарантированно не расходятся. Меняется только
/// при ломающих изменениях формата (сравнение на равенство).
public let helperProtocolVersion = 1

/// Монотонный номер билда демона: бампируется с каждым релизом хелпера
/// (release-чеклист). Приложение сравнивает его с ответом демона — устаревший
/// бинарь предлагается обновить пунктом «Обновить сервис».
public let helperBuildNumber = 2

/// Запрос приложения к демону (line-based: соединение = один запрос).
public enum HelperRequest {
    case show
}

/// Код ошибки из заголовка `err`.
public enum HelperResponseCode: Equatable {
    case wgMissing
    case wgFailed
}

/// Разобранный ответ демона; обе версии — в любом ответе, включая `err`
/// (outdated-детект работает и по ошибочному ответу).
public enum HelperResponse: Equatable {
    case ok(protocolVersion: Int, build: Int, dump: String)
    case err(protocolVersion: Int, build: Int, code: HelperResponseCode, detail: String?)
}

/// Кодирует запрос в строку wire-протокола (`show\n`).
public func encode(_ request: HelperRequest) -> String {
    switch request {
    case .show:
        return "show\n"
    }
}

/// Разбирает ответ демона: первая строка — заголовок
/// (`ok <protocol> <build>` или `err <protocol> <build> <code> [деталь]`),
/// всё после неё — dump (для `ok`). Текст не подошёл под формат → `nil`,
/// вызывающий считает ответ битым.
public func decode(response: String) -> HelperResponse? {
    let headerEnd = response.firstIndex(of: "\n") ?? response.endIndex
    let header = String(response[..<headerEnd])
    let dump = headerEnd < response.endIndex
        ? String(response[response.index(after: headerEnd)...])
        : ""

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
        default:
            return nil
        }
        return .err(protocolVersion: protocolVersion, build: build, code: code, detail: tokens.count > 4 ? tokens[4] : nil)
    default:
        return nil
    }
}
