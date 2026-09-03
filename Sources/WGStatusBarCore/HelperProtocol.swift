import Foundation

/// Версия wire-протокола общения приложения с демоном. Компилируется и в
/// приложение, и в демон — числа гарантированно не расходятся. Меняется только
/// при ломающих изменениях формата (сравнение на равенство).
public let helperProtocolVersion = 1

/// Монотонный номер билда демона: бампируется с каждым релизом хелпера
/// (release-чеклист). Приложение сравнивает его с ответом демона — устаревший
/// бинарь предлагается обновить пунктом «Обновить сервис». Билд 18 добавляет
/// запрос `config` (маскированный просмотр конфига); протокол не менялся —
/// старые команды сохранили wire-формат, но новый app обязан отличить бинарь
/// без `config` от честной ошибки просмотра, поэтому билд вырос.
public let helperBuildNumber = 18

/// Запрос приложения к демону (line-based: соединение = один запрос).
public enum HelperRequest {
    case show
    case list
    /// Состояние туннелей по каталогу конфигов демона: строки
    /// `имя\tup\tutunN` / `имя\tdown\t` (демон — root, `/var/run/wireguard`
    /// читаем только ему; приложение состояния не выводит из дампа).
    case state
    case up(String)
    case down(String)
    /// Маскированный конфиг `<name>`: полный текст файла со спрятанными
    /// значениями канонических назначений PrivateKey/PresharedKey (санитизация
    /// — на стороне демона, в одном `b64:`-конверте). Raw-запроса в протоколе
    /// нет и не появится: несекретный путь данных — единственный.
    case config(String)
}

/// Код ошибки из заголовка `err`.
public enum HelperResponseCode: Equatable {
    case wgMissing
    case wgFailed
    /// `wg-quick` не установлен (для туннельных операций up/down).
    case quickMissing
    /// Конфиг с таким именем не найден (имя не прошло валидацию демона).
    case tunnelNotFound
    /// Конфиг недоступен для просмотра: имени нет, файл не найден, небезопасен
    /// (симлинк/спецфайл), нечитаем, больше лимита или не декодируется.
    /// Код без детали — содержимое и пути не покидают демон.
    case configUnavailable
}

/// Разобранный ответ демона; обе версии — в любом ответе, включая `err`
/// (outdated-детект работает и по ошибочному ответу).
public enum HelperResponse: Equatable {
    case ok(protocolVersion: Int, build: Int, dump: String)
    case err(protocolVersion: Int, build: Int, code: HelperResponseCode, detail: String?)
}

/// Кодирует запрос в строку wire-протокола (`show\n`, `list\n`, `state\n`,
/// `up <name>\n`, `down <name>\n`, `config <name>\n`).
public func encode(_ request: HelperRequest) -> String {
    switch request {
    case .show:
        return "show\n"
    case .list:
        return "list\n"
    case .state:
        return "state\n"
    case .up(let name):
        return "up \(name)\n"
    case .down(let name):
        return "down \(name)\n"
    case .config(let name):
        return "config \(name)\n"
    }
}

/// Разбирает ответ демона: первая строка — заголовок
/// (`ok <protocol> <build>` или `err <protocol> <build> <code> [деталь]`),
/// всё после неё — payload для `ok` (поле `dump`): дамп `show`, список имён
/// туннелей `list` (по одному в строке, каждое с `\n`), строки состояния
/// `state` (всегда 3 поля через `\t`: `имя\tup\tutunN` / `имя\tdown\t`) или
/// пусто (`up`/`down` отвечают успехом без payload; пустой payload `state` —
/// конфигов нет). Правила для всех видов payload одни —
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
        case "config-unavailable":
            code = .configUnavailable
        default:
            return nil
        }
        return .err(protocolVersion: protocolVersion, build: build, code: code, detail: tokens.count > 4 ? tokens[4] : nil)
    default:
        return nil
    }
}

// MARK: - Конверт payload `config`

/// Ошибка разбора `b64:`-конверта: типизированная, без данных — декодированный
/// текст и сломанные фрагменты наружу не уходят.
enum ConfigEnvelopeError: Error, Equatable {
    /// Payload пуст или конверт не завершён терминатором — конверта нет.
    case missing
    /// Строка payload не начинается с `b64:`.
    case missingTag
    /// В payload больше одной строки (или есть `\r`) — конверт ровно один.
    case extraLines
    /// Закодированная часть — не валидный base64 (алфавит, `=` в середине,
    /// длина не кратна 4).
    case malformedBase64
    /// Декодировано больше `TunnelConfigReader.maxSizeBytes`.
    case oversized
    /// Декодированные байты — не UTF-8.
    case invalidUTF8
}

/// Конверт payload ответа `config` (и позже — one-shot raw-чтения):
/// ровно одна строка `b64:<base64>\n`. Тег отличает пустой документ
/// (`b64:\n` — валидный конверт пустого текста) от отсутствующего
/// (пустой payload — невалиден); терминатор конверта — обрамление
/// транспорта, собственный завершающий `\n` документа живёт внутри
/// закодированных байтов и не меняется ни кодированием, ни разбором.
enum ConfigEnvelope {
    static let tag = "b64:"

    /// Кодирует точный текст документа в однострочный payload-конверт.
    static func encode(_ text: String) -> String {
        tag + Data(text.utf8).base64EncodedString() + "\n"
    }

    /// Разбирает payload `ok`-ответа `config`: снимает только терминатор
    /// конверта, требует тег, одну строку, валидный base64, размер в пределах
    /// лимита ридера и полный UTF-8-декод. Возвращает точный текст документа —
    /// включая наличие или отсутствие у него завершающего `\n`.
    static func decode(_ payload: String) -> Result<String, ConfigEnvelopeError> {
        // decode(response:) уже отвергает незавершённый payload; здесь то же
        // правило для прямых вызовов — усечённый конверт невалиден.
        guard payload.hasSuffix("\n") else { return .failure(.missing) }
        var line = payload
        line.removeLast()
        guard line.hasPrefix(tag) else { return .failure(.missingTag) }
        let encoded = line.dropFirst(tag.count)
        if encoded.contains("\n") || encoded.contains("\r") {
            return .failure(.extraLines)
        }
        guard isWellFormedBase64(encoded),
              let data = Data(base64Encoded: String(encoded))
        else { return .failure(.malformedBase64) }
        guard data.count <= TunnelConfigReader.maxSizeBytes else {
            return .failure(.oversized)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .failure(.invalidUTF8)
        }
        return .success(text)
    }

    private static let base64Alphabet: Set<UInt8> = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8
    )

    /// Строгая форма base64: длина кратна 4, только алфавит, `=` — только
    /// хвостовое заполнение (максимум два). Дефолтный декодер Foundation
    /// местами снисходителен — конверт проверяем своей формой.
    private static func isWellFormedBase64(_ encoded: Substring) -> Bool {
        let bytes = Array(encoded.utf8)
        guard bytes.count % 4 == 0 else { return false }
        var payloadEnd = bytes.count
        while payloadEnd > 0, bytes[payloadEnd - 1] == UInt8(ascii: "=") {
            payloadEnd -= 1
        }
        guard bytes.count - payloadEnd <= 2 else { return false }
        return bytes[0..<payloadEnd].allSatisfy { base64Alphabet.contains($0) }
    }
}
