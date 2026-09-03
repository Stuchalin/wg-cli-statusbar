import Foundation

/// Ошибка получения маскированного конфига: транспорт, версии и содержимое
/// ответа `config` — без единого байта самого документа. Вьювер (Task 4)
/// превращает их в свои локальные состояния; `daemonOutdated` несёт
/// «Обновить сервис», `unavailable` — оконную ошибку «конфиг недоступен».
public enum ConfigFetchError: Error, Equatable {
    /// Демон отвечает чужим протоколом или старым build — обновить сервис.
    case daemonOutdated
    /// Коннект отклонён — демона нет или он умер при живом сокет-файле.
    case connectionRefused
    /// Тишина до клиентского дедлайна (connect+send+чтение целиком).
    case timedOut
    /// Мусор в канале, мгновенный EOF или невалидный `b64:`-конверт.
    case badResponse
    /// Конфиг недоступен: имя невалидно, файла нет, он небезопасен, нечитаем,
    /// велик или не декодируется — `err config-unavailable` без детали.
    case unavailable
}

/// Клиент маскированного просмотра конфига: `config <name>` → полный текст со
/// спрятанными значениями канонических назначений PrivateKey/PresharedKey.
/// Транспорт и общая часть ответа — общий `HelperClient` (дедлайн на весь
/// обмен, decode + сверка версий заголовка: чужой протокол или старый build —
/// `daemonOutdated` даже по `err`); специфика здесь — лимит байт ответа на
/// этапе recv и разбор `b64:`-конверта. Терминатор конверта — обрамление
/// транспорта: собственный завершающий `\n` санитизированного документа живёт
/// внутри base64 и доходит клиентом нетронутым (пустой документ остаётся
/// пустым — `b64:\n`). Состояние вьювера/модели сюда не замешивается —
/// отдельный от `WireGuardStatusModel` и туннельных операций путь данных.
public struct SocketConfigClient {
    /// Дедлайн полного обмена (connect+send+чтение до EOF). Обработка
    /// `config` на стороне демона — локальное чтение файла (~0 с), но запрос
    /// сидит в той же последовательной очереди accept-loop, что show-тик и
    /// туннельные операции. Кнопка деталей намеренно не глушится во время
    /// операции (открытие вьювера — не туннельная операция): худший случай —
    /// show-бюджет 4.0 с (тик, начавшийся до клика) + op-бюджет 9.0 с = 13.0 с,
    /// та же математика очереди, что у `SocketTunnelClient.opTimeout`.
    public static let defaultTimeout: TimeInterval = 16.0

    /// Потолок байт ответа, проверяемый по ходу recv (до накопления):
    /// заголовок + тег + base64 маскированного документа + терминатор, с
    /// запасом на заголовок. По проводу идёт маскированный текст, а санитизация
    /// удлиняет документ — потолок выводится из `maxSanitizedConfigBytes`, не
    /// из лимита ридера (иначе легитимный ответ демона отвергался бы как
    /// мусор). Крупнее легитимного ответа демона не бывает; разросшийся канал —
    /// мусор.
    static let maxResponseBytes: Int = {
        let documentBytes = maxSanitizedConfigBytes
        let base64Bytes = (documentBytes + 2) / 3 * 4
        // Заголовок `ok <protocol> <build>\n` короче 64 байт с запасом.
        return 64 + ConfigEnvelope.tag.utf8.count + base64Bytes + 1
    }()

    private let client: HelperClient
    private let timeout: TimeInterval

    public init(
        socketPath: String = helperSocketPath,
        timeout: TimeInterval = SocketConfigClient.defaultTimeout
    ) {
        self.client = HelperClient(socketPath: socketPath)
        self.timeout = timeout
    }

    /// Маскированный конфиг туннеля: точный текст, каким его отдал демон
    /// (санитизированные значения назначений ключей, остальное — как в
    /// файле), с сохранённым состоянием завершающего перевода строки.
    public func maskedConfig(named name: String) async throws -> TunnelConfigDocument {
        let response: String
        do {
            response = try await client.exchange(
                .config(name),
                timeout: timeout,
                responseLimit: Self.maxResponseBytes
            )
        } catch let error as HelperClientError {
            throw Self.translate(error)
        }
        return try Self.interpret(response: response)
    }

    /// Транспортные сбои → свои кейсы (у вьювера своя тишина-ошибка, текст
    /// `commandTimeout` — про `wg show` и сюда не подходит).
    private static func translate(_ error: HelperClientError) -> ConfigFetchError {
        switch error {
        case .connectionRefused:
            return .connectionRefused
        case .timedOut:
            return .timedOut
        case .badChannel:
            return .badResponse
        }
    }

    /// Интерпретация ответа `config`: версии заголовка — общий `HelperClient`
    /// (`daemonOutdated` бьёт и код ошибки — старый бинарь не знает `config` и
    /// отвечает unknown command, это не ошибка просмотра); `ok` → разбор
    /// конверта; `config-unavailable` → честная оконная ошибка, деталь с wire
    /// игнорируется; чужие коды с совпавшими версиями — мусор канала.
    private static func interpret(response: String) throws -> TunnelConfigDocument {
        let decoded: HelperResponse
        do {
            decoded = try HelperClient.decodeAndVerifyVersions(response)
        } catch let failure as StatusFailure {
            // decodeAndVerifyVersions бросает только эти два — перевод в
            // ошибки вьювера без утечки StatusFailure наружу.
            switch failure {
            case .daemonOutdated:
                throw ConfigFetchError.daemonOutdated
            default:
                throw ConfigFetchError.badResponse
            }
        }

        switch decoded {
        case .ok(_, _, let payload):
            let text = try decodeEnvelope(payload)
            return TunnelConfigDocument(text: text)
        case .err(_, _, .configUnavailable, _):
            throw ConfigFetchError.unavailable
        case .err(_, _, .wgMissing, _), .err(_, _, .wgFailed, _),
             .err(_, _, .quickMissing, _), .err(_, _, .tunnelNotFound, _):
            // Коды show/туннельных операций не отвечают `config` — защитные
            // ветки исчерпывающего switch для нештатного демона.
            throw ConfigFetchError.badResponse
        }
    }

    private static func decodeEnvelope(_ payload: String) throws -> String {
        // Маскированный документ длиннее raw-файла (санитизация удлиняет
        // строки) — потолок декода берётся от максимума маскированного текста.
        switch ConfigEnvelope.decode(payload, maxDecodedBytes: maxSanitizedConfigBytes) {
        case .success(let text):
            return text
        case .failure:
            throw ConfigFetchError.badResponse
        }
    }
}
