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

/// Сокет-клиент демона: подключается к unix-сокету (продакшн —
/// `/var/run/wgstatusbar.sock`), шлёт `show`, читает ответ до EOF под одним
/// дедлайном на весь обмен. `ok` → текст дампа (санитирован демоном — модель
/// не знает, откуда дамп); `err` → типизированная ошибка кода; версии
/// заголовка сверяются с константами приложения — чужой протокол или старый
/// build (включая err-ответы) → `daemonOutdated`; коннект отклонён →
/// `connectionRefused`; тишина до дедлайна → `commandTimeout`; мусор или
/// мгновенный EOF → `badResponse`.
public struct SocketWGShowRunner: WGShowCommandRunning {
    private let socketPath: String
    private let timeout: TimeInterval

    /// Продакшн-дедлайн полного обмена (connect+send+чтение до EOF). Больше
    /// худшего случая бюджета демона (`WGShowExecutor.defaultTimeout +
    /// 2 * defaultKillGrace`): зависший wg обязан успеть получить err-ответ
    /// демона, а не таймаут клиента по тишине.
    public static let defaultTimeout: TimeInterval = 5.0

    public init(socketPath: String, timeout: TimeInterval = SocketWGShowRunner.defaultTimeout) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    public func runDump() async throws -> String {
        let socketPath = self.socketPath
        let timeout = self.timeout
        return try await withCheckedThrowingContinuation { continuation in
            // poll/connect/recv блокируют поток — уходим с кооперативного пула.
            DispatchQueue.global().async {
                do {
                    let dump = try Self.exchangeBlocking(
                        socketPath: socketPath,
                        timeout: timeout
                    )
                    continuation.resume(returning: dump)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Полный обмен под одним дедлайном: connect → `show` → чтение до EOF →
    /// декод (протокол — одно соединение = один запрос, EOF = конец ответа).
    private static func exchangeBlocking(socketPath: String, timeout: TimeInterval) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StatusFailure.badResponse }
        defer { close(fd) }

        // Запись в демон, умерший между connect и send, — ошибка send, а не
        // SIGPIPE, который убил бы всё приложение.
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        try connectToDaemon(fd: fd, socketPath: socketPath, deadline: deadline)
        try sendAll(fd: fd, text: encode(.show), deadline: deadline)
        let response = try readToEOF(fd: fd, deadline: deadline)
        return try interpret(response: response)
    }

    // MARK: - Сокет-операции под дедлайном (poll-затем-операция, как в DaemonServer)

    private static func connectToDaemon(fd: Int32, socketPath: String, deadline: Date) throws {
        // Неблокирующий connect: переполненный backlog unix-сокета блокирует
        // connect неопределённо долго — дедлайн обязан работать и здесь.
        let originalFlags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK)
        defer { _ = fcntl(fd, F_SETFL, originalFlags) }

        let connected = withUnixSocketAddress(path: socketPath) { address, length in
            connect(fd, address, length)
        }
        if connected == 0 { return }
        guard errno == EINPROGRESS else { throw StatusFailure.connectionRefused }

        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw StatusFailure.commandTimeout }
            var pollDescriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&pollDescriptor, 1, Int32(remaining * 1000))
            if ready < 0 {
                if errno == EINTR { continue }
                throw StatusFailure.badResponse
            }
            if ready == 0 { throw StatusFailure.commandTimeout }
            // Результат неблокирующего connect читается из SO_ERROR.
            var pendingError: Int32 = 0
            var pendingErrorLength = socklen_t(MemoryLayout<Int32>.size)
            _ = getsockopt(fd, SOL_SOCKET, SO_ERROR, &pendingError, &pendingErrorLength)
            if pendingError != 0 { throw StatusFailure.connectionRefused }
            return
        }
    }

    private static func sendAll(fd: Int32, text: String, deadline: Date) throws {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw StatusFailure.commandTimeout }
            var pollDescriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&pollDescriptor, 1, Int32(remaining * 1000))
            if ready < 0 {
                if errno == EINTR { continue }
                throw StatusFailure.badResponse
            }
            if ready == 0 { throw StatusFailure.commandTimeout }
            let sent = bytes.withUnsafeBufferPointer { buffer in
                send(fd, buffer.baseAddress! + offset, bytes.count - offset, 0)
            }
            if sent < 0 {
                if errno == EINTR { continue }
                throw StatusFailure.badResponse
            }
            offset += sent
        }
    }

    private static func readToEOF(fd: Int32, deadline: Date) throws -> String {
        var data: [UInt8] = []
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw StatusFailure.commandTimeout }
            var pollDescriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollDescriptor, 1, Int32(remaining * 1000))
            if ready < 0 {
                if errno == EINTR { continue }
                throw StatusFailure.badResponse
            }
            if ready == 0 { throw StatusFailure.commandTimeout }
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let received = chunk.withUnsafeMutableBytes { raw in
                recv(fd, raw.baseAddress, raw.count, 0)
            }
            if received == 0 { break } // EOF: демон закрыл соединение после ответа.
            if received < 0 {
                if errno == EINTR { continue }
                throw StatusFailure.badResponse
            }
            data.append(contentsOf: chunk[0..<received])
        }
        // Не-UTF8 — мусор: decode вернёт nil → badResponse.
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    // MARK: - Ответ

    /// Декод + сверка версий заголовка с константами приложения: чужой протокол
    /// или старый build — `daemonOutdated` в любом ответе (включая err —
    /// outdated-детект работает и по ошибочному), иначе ok → дамп, err →
    /// типизированная ошибка кода.
    private static func interpret(response: String) throws -> String {
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

        switch decoded {
        case .ok(_, _, let dump):
            return dump
        case .err(_, _, .wgMissing, _):
            throw StatusFailure.wgMissing
        case .err(_, _, .wgFailed, let detail):
            // Демон всегда прикладывает деталь; пустая — деградируем в общую строку.
            throw StatusFailure.generic(detail ?? L10n.string("error.service_unreachable"))
        case .err(_, _, .quickMissing, let detail), .err(_, _, .tunnelNotFound, let detail):
            // Коды туннельных операций: на wire приходят без детали (stderr-хвост
            // wg-quick остаётся в логе демона). Временный маппинг до Task 5 —
            // финальные локализованные сообщения вводит SocketTunnelClient.
            throw StatusFailure.generic(detail ?? L10n.string("error.service_unreachable"))
        }
    }
}
