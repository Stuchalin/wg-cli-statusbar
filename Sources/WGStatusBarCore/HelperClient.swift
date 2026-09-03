import Foundation

/// Ошибка транспорта обмена с демоном — только канал, без интерпретации
/// протокола: коды `err` и payload разбирает вызывающий (`show` и туннельные
/// операции маппят их по-разному). Переводится в `StatusFailure` на месте:
/// show превращает тишину в `commandTimeout` (его текст — про `wg show`),
/// туннельные операции — в общий провал операции.
enum HelperClientError: Error, Equatable {
    /// Коннект отклонён — демона нет или он умер при живом сокет-файле.
    case connectionRefused
    /// Тишина до клиентского дедлайна (connect+send+чтение целиком).
    case timedOut
    /// Мусор в канале, ошибка сокета или недоступный fd.
    case badChannel
}

/// Транспорт wire-протокола демона: connect → отправка запроса → чтение до
/// EOF под одним дедлайном на весь обмен (протокол — одно соединение = один
/// запрос, EOF = конец ответа). Неблокирующий connect (переполненный backlog
/// unix-сокета не должен вешать дедлайн), SO_NOSIGPIPE (запись в демон,
/// умерший между connect и send, — ошибка send, а не SIGPIPE, который убил бы
/// всё приложение), poll-циклы с EINTR-ретраями. Выделен из
/// `SocketWGShowRunner`; интерпретация ответа — не его работа: общую часть
/// (формат заголовка + сверка версий) даёт `decodeAndVerifyVersions`,
/// командно-специфичный маппинг кодов `err` держат клиенты.
struct HelperClient {
    let socketPath: String

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// Полный обмен: ответ демона сырым текстом. poll/connect/recv блокируют
    /// поток — уходят с кооперативного пула в глобальную очередь.
    /// `responseLimit` — потолок байт ответа, проверяемый по ходу recv, до
    /// накопления (клиент `config` ограничивает конверт; остальные вызовы
    /// живут как раньше — без лимита).
    func exchange(
        _ request: HelperRequest,
        timeout: TimeInterval,
        responseLimit: Int? = nil
    ) async throws -> String {
        let socketPath = self.socketPath
        // Запрос кодируется заранее: в блокирующий поток уходят только строки.
        let requestText = encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    continuation.resume(
                        returning: try Self.exchangeBlocking(
                            requestText: requestText,
                            socketPath: socketPath,
                            timeout: timeout,
                            responseLimit: responseLimit
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func exchangeBlocking(
        requestText: String,
        socketPath: String,
        timeout: TimeInterval,
        responseLimit: Int?
    ) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HelperClientError.badChannel }
        defer { close(fd) }

        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        try connectToDaemon(fd: fd, socketPath: socketPath, deadline: deadline)
        try sendAll(fd: fd, text: requestText, deadline: deadline)
        return try readToEOF(fd: fd, deadline: deadline, limit: responseLimit)
    }

    // MARK: - Сокет-операции под дедлайном (poll-затем-операция, как в DaemonServer)

    private static func connectToDaemon(fd: Int32, socketPath: String, deadline: Date) throws {
        // Неблокирующий connect: блокирующий не подчиняется дедлайну обмена.
        // На macOS AF_UNIX при переполненном backlog ядро отвечает мгновенным
        // ECONNREFUSED (проверено эмпирически), так что EINPROGRESS-ветка ниже
        // платформенно-оборонительная: если ядро всё же вернёт «в процессе»,
        // poll дождётся готовности или дедлайна — зависание и ошибка
        // классификации (EINPROGRESS как отказ) исключены.
        let originalFlags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK)
        defer { _ = fcntl(fd, F_SETFL, originalFlags) }

        let connected = withUnixSocketAddress(path: socketPath) { address, length in
            connect(fd, address, length)
        }
        if connected == 0 { return }
        guard errno == EINPROGRESS else { throw HelperClientError.connectionRefused }

        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw HelperClientError.timedOut }
            var pollDescriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&pollDescriptor, 1, Int32(remaining * 1000))
            if ready < 0 {
                if errno == EINTR { continue }
                throw HelperClientError.badChannel
            }
            if ready == 0 { throw HelperClientError.timedOut }
            // Результат неблокирующего connect читается из SO_ERROR.
            var pendingError: Int32 = 0
            var pendingErrorLength = socklen_t(MemoryLayout<Int32>.size)
            _ = getsockopt(fd, SOL_SOCKET, SO_ERROR, &pendingError, &pendingErrorLength)
            if pendingError != 0 { throw HelperClientError.connectionRefused }
            return
        }
    }

    private static func sendAll(fd: Int32, text: String, deadline: Date) throws {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw HelperClientError.timedOut }
            var pollDescriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&pollDescriptor, 1, Int32(remaining * 1000))
            if ready < 0 {
                if errno == EINTR { continue }
                throw HelperClientError.badChannel
            }
            if ready == 0 { throw HelperClientError.timedOut }
            let sent = bytes.withUnsafeBufferPointer { buffer in
                send(fd, buffer.baseAddress! + offset, bytes.count - offset, 0)
            }
            if sent < 0 {
                if errno == EINTR { continue }
                throw HelperClientError.badChannel
            }
            offset += sent
        }
    }

    private static func readToEOF(fd: Int32, deadline: Date, limit: Int?) throws -> String {
        var data: [UInt8] = []
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw HelperClientError.timedOut }
            var pollDescriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollDescriptor, 1, Int32(remaining * 1000))
            if ready < 0 {
                if errno == EINTR { continue }
                throw HelperClientError.badChannel
            }
            if ready == 0 { throw HelperClientError.timedOut }
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let received = chunk.withUnsafeMutableBytes { raw in
                recv(fd, raw.baseAddress, raw.count, 0)
            }
            if received == 0 { break } // EOF: демон закрыл соединение после ответа.
            if received < 0 {
                if errno == EINTR { continue }
                throw HelperClientError.badChannel
            }
            // Потолок проверяется до накопления: разросшийся ответ — это
            // разлад канала (демон не может прислать больше легитимного
            // максимума), дальше он не читается и не копится в память.
            if let limit, data.count + received > limit {
                throw HelperClientError.badChannel
            }
            data.append(contentsOf: chunk[0..<received])
        }
        // Не-UTF8 — мусор: decode вернёт nil → badResponse у вызывающего.
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    // MARK: - Ответ

    /// Общая часть интерпретации ответа: decode + сверка версий заголовка с
    /// константами приложения. Чужой протокол или старый build —
    /// `daemonOutdated` в любом ответе (включая err — outdated-детект работает
    /// и по ошибочному); неформат — `badResponse`. Остальной разбор (payload
    /// `ok` и маппинг кодов `err`) — командно-специфичный, его держат клиенты.
    static func decodeAndVerifyVersions(_ response: String) throws -> HelperResponse {
        guard let decoded = decode(response: response) else {
            throw StatusFailure.badResponse
        }

        let header: (protocolVersion: Int, build: Int)
        switch decoded {
        case let .ok(protocolVersion, build, _):
            header = (protocolVersion, build)
        case let .err(protocolVersion, build, _, _):
            header = (protocolVersion, build)
        }
        guard header.protocolVersion == helperProtocolVersion, header.build >= helperBuildNumber else {
            throw StatusFailure.daemonOutdated
        }
        return decoded
    }
}
