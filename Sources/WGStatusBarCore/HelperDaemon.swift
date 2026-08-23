import Foundation

/// Заполняет `sockaddr_un` путём и передаёт в `body` как `sockaddr*`.
internal func withUnixSocketAddress<R>(
    path: String,
    _ body: (UnsafePointer<sockaddr>, socklen_t) -> R
) -> R {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bytes = Array(path.utf8)
    precondition(
        bytes.count < MemoryLayout.size(ofValue: address.sun_path),
        "путь unix-сокета не влезает в sun_path: \(path)"
    )
    // sun_path уже занулён дефолтным init — хвост остаётся NUL-терминатором.
    withUnsafeMutableBytes(of: &address.sun_path) { rawPath in
        for (index, byte) in bytes.enumerated() {
            rawPath[index] = byte
        }
    }
    return withUnsafePointer(to: address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

/// Одноразовый флаг: ставится из одного потока, читается из другого
/// (отмена сервера из `onCancel`-обработчика, «работа завершена» из задачи
/// serveShow против цикла-наблюдателя) — доступ под локом.
private final class CancelFlag {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        defer { lock.unlock() }
        value = true
    }
}

/// Фатальная ошибка запуска/работы сервера: бинарь демона печатает её и
/// завершается (launchd поднимет заново по KeepAlive).
public enum DaemonServerError: Error, CustomStringConvertible {
    case socketCreationFailed(errno: Int)
    case bindFailed(path: String, errno: Int)
    case listenFailed(errno: Int)
    case acceptFailed(errno: Int)

    public var description: String {
        switch self {
        case .socketCreationFailed(let errno):
            return "socket() failed: errno \(errno)"
        case .bindFailed(let path, let errno):
            return "bind(\(path)) failed: errno \(errno)"
        case .listenFailed(let errno):
            return "listen() failed: errno \(errno)"
        case .acceptFailed(let errno):
            return "accept() failed: errno \(errno)"
        }
    }
}

/// Сервер привилегированного демона: unix-сокет (продакшн —
/// `/var/run/wgstatusbar.sock`, права 0660 root:admin) и вечный accept-цикл,
/// одно соединение за раз — соединение = один запрос. `show` → дамп у
/// исполнителя → санитизация (единственная точка, где секступаются секреты) →
/// `ok <protocol> <build>` + дамп; ошибка исполнителя → `err` с кодом.
/// Отключившийся или молчащий клиент не подвешивает цикл: EOF отменяет
/// ожидание ребёнка, тишина закрывается по дедлайну чтения.
public final class DaemonServer {
    private let executor: WGShowExecuting
    private let socketPath: String
    /// Дедлайн на чтение команды и запись ответа (нечитающий клиент не должен
    /// подвесить последовательный цикл). Инжектится — короткий в тестах.
    private let readDeadline: TimeInterval
    private let cancelFlag = CancelFlag()

    /// Максимальная длина строки команды: запросы крошечные, мусор без `\n`
    /// не должен копиться бесконечно.
    private static let maxRequestLength = 1024

    public init(executor: WGShowExecuting, socketPath: String, readDeadline: TimeInterval = 5) {
        self.executor = executor
        self.socketPath = socketPath
        self.readDeadline = readDeadline
    }

    public func run() async throws {
        let listenFD = try Self.makeListeningSocket(at: socketPath)
        defer {
            close(listenFD)
            // Нормальный выход — только отмена; прибираем файл сокета
            // (best-effort), старт и так переживает протухший (unlink+bind).
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        let cancelFlag = self.cancelFlag
        let socketPath = self.socketPath
        try await withTaskCancellationHandler {
            while !cancelFlag.isSet {
                try Task.checkCancellation()
                let clientFD = try await Self.acceptConnection(on: listenFD)
                if cancelFlag.isSet {
                    // Соединение-будильник от отмены, не клиент.
                    close(clientFD)
                    break
                }
                await self.handleClient(clientFD)
            }
        } onCancel: {
            // Заблокированный accept не видит отмену задачи; закрывать listenFD
            // из чужого потока нельзя (гонка переиспользования номера
            // дескриптора) — будим цикл фиктивным соединением.
            cancelFlag.set()
            Self.wakeUpAcceptLoop(socketPath: socketPath)
        }

        // Выход из цикла — всегда отмена: показать её вызывающему.
        try Task.checkCancellation()
    }

    // MARK: - Сокет

    private static func makeListeningSocket(at path: String) throws -> Int32 {
        // Протухший сокет-файл (демон убит без очистки) не должен мешать bind.
        try? FileManager.default.removeItem(atPath: path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw DaemonServerError.socketCreationFailed(errno: Int(errno))
        }

        // SO_NOSIGPIPE ставится только на неподключённый сокет (на accepted —
        // EINVAL), поэтому на слушающий: принятые соединения наследуют флаг, и
        // запись ушедшему клиенту даёт ошибку send (EPIPE), а не SIGPIPE,
        // который убил бы весь демон.
        var noSigPipe: Int32 = 1
        _ = setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )

        // Файл сокета рождается с правами 0777 & ~umask: без пережатия umask
        // между bind и chmod ниже файл существует с дефолтными правами.
        // 0117 даёт 0660 сразу; umask — процесс-глобальная величина, между
        // установкой и возвратом нет await, конкурирующих потоков в setup нет.
        let previousUmask = umask(0o117)
        let bound = withUnixSocketAddress(path: path) { address, length in
            bind(fd, address, length)
        }
        umask(previousUmask)
        guard bound == 0 else {
            close(fd)
            throw DaemonServerError.bindFailed(path: path, errno: Int(errno))
        }

        // 0660 root:admin — доступ приложению от обычного пользователя.
        // Группа — best-effort: под root файл иначе получил бы wheel.
        if let adminGroup = getgrnam("admin") {
            _ = chown(path, uid_t(bitPattern: -1), adminGroup.pointee.gr_gid)
        }
        _ = chmod(path, 0o660)

        guard listen(fd, 8) == 0 else {
            close(fd)
            throw DaemonServerError.listenFailed(errno: Int(errno))
        }
        return fd
    }

    /// Блокирующий accept, обёрнутый в продолжение (кооперативный пул не
    /// блокируется). EINTR — ретрай, он же безопасен для выхода по отмене:
    /// будильное соединение — это успешный accept, а не ошибка.
    private static func acceptConnection(on listenFD: Int32) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                var clientAddress = sockaddr_un()
                var clientAddressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
                var clientFD: Int32
                repeat {
                    clientFD = withUnsafeMutablePointer(to: &clientAddress) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                            accept(listenFD, sockaddrPointer, &clientAddressLength)
                        }
                    }
                } while clientFD < 0 && errno == EINTR
                if clientFD >= 0 {
                    continuation.resume(returning: clientFD)
                } else {
                    continuation.resume(throwing: DaemonServerError.acceptFailed(errno: Int(errno)))
                }
            }
        }
    }

    /// Соединение-будильник: accept возвращается, цикл видит флаг и выходит.
    private static func wakeUpAcceptLoop(socketPath: String) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = withUnixSocketAddress(path: socketPath) { address, length in
            connect(fd, address, length)
        }
    }

    // MARK: - Один клиент

    private func handleClient(_ clientFD: Int32) async {
        defer { close(clientFD) }

        guard let command = await Self.readRequestLine(fd: clientFD, deadline: readDeadline) else {
            // EOF, таймаут или мусор без `\n` — молча забыть, обслужить следующего.
            return
        }

        switch command {
        case "show":
            await serveShow(to: clientFD)
        default:
            // Разрыв после ответа: протокол — одно соединение = один запрос.
            _ = await Self.writeResponse(
                fd: clientFD,
                text: Self.errResponse(code: "wg-failed", detail: "unknown command: \(command)"),
                deadline: readDeadline
            )
        }
    }

    private func serveShow(to clientFD: Int32) async {
        let response: String
        do {
            // План: EOF клиента посреди запроса — демон прекращает ожидание
            // ребёнка; accept-loop не занят мёртвым клиентом до конца работы wg.
            let rawDump = try await Self.runDumpCancellingOnClientEOF(fd: clientFD) {
                try await self.executor.runDump()
            }
            // Единственная точка санитизации: секреты не покидают демон.
            response = Self.okResponse(dump: sanitizeWGDump(rawDump))
        } catch is CancellationError {
            // Клиент ушёл (или сервер shutdown) — отвечать некому.
            return
        } catch {
            response = Self.errResponse(for: error)
        }
        // Клиент мог уйти, пока работал исполнитель: провал записи — не ошибка
        // цикла, соединение и так закрывается после ответа.
        _ = await Self.writeResponse(fd: clientFD, text: response, deadline: readDeadline)
    }

    /// Гоняет работу исполнителя под наблюдением клиентского сокета: клиент,
    /// закрывший соединение до ответа (EOF), отменяет работу — wg убивается
    /// обработчиком отмены исполнителя. Завершившаяся работа останавливает
    /// наблюдателя (флаг), отмена серверной задачи отменяет работу
    /// (`onCancel`) — все три пути сходятся в `work.value`.
    private static func runDumpCancellingOnClientEOF(
        fd: Int32,
        _ work: @escaping () async throws -> String
    ) async throws -> String {
        let work = Task { try await work() }
        let workFinished = CancelFlag()
        // Наблюдатель живёт своей жизнью: останавливается по EOF/ошибке либо
        // по флагу после завершения работы (≤ одного poll-таймаута).
        Task.detached {
            Self.cancelWorkOnClientEOF(fd: fd, work: work, stop: workFinished)
        }
        return try await withTaskCancellationHandler {
            // Работа завершена — наблюдателю пора выходить (максимум один
            // poll-таймаут он ещё проживёт, поток глобального пула не течёт).
            defer { workFinished.set() }
            return try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    /// Ждёт EOF клиентского сокета (poll + recv по байту: команда уже прочитана,
    /// любые данные после неё протоколу не нужны) и отменяет работу. Байты
    /// поглощаются, а не подсматриваются (`MSG_PEEK`): иначе клиент с мусором
    /// после команды держал бы сокет бесконечно читаемым — busy-loop без паузы
    /// до конца работы wg. Выходит по EOF, ошибке наблюдения или флагу `stop`.
    /// poll/recv блокируют поток — вызывается только из detached-задачи.
    private static func cancelWorkOnClientEOF(
        fd: Int32,
        work: Task<String, Error>,
        stop: CancelFlag
    ) {
        while !stop.isSet {
            var pollDescriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollDescriptor, 1, 100)
            if ready == 0 { continue }
            if ready < 0 {
                if errno == EINTR { continue }
                return  // ошибка наблюдения — работу не трогаем
            }
            var probe: UInt8 = 0
            let received = recv(fd, &probe, 1, 0)
            if received == 0 {
                work.cancel()  // EOF: клиент ушёл до ответа
                return
            }
            if received < 0 && errno != EINTR {
                return
            }
            // received > 0: лишние данные от клиента — поглощены, ждём дальше.
        }
    }

    // MARK: - Wire-ответы

    private static func okResponse(dump: String) -> String {
        "ok \(helperProtocolVersion) \(helperBuildNumber)\n\(dump)"
    }

    private static func errResponse(code: String, detail: String?) -> String {
        var line = "err \(helperProtocolVersion) \(helperBuildNumber) \(code)"
        if let detail {
            // Деталь обязана быть однострочной: заголовок — первая строка ответа.
            let flattened = detail
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
                .trimmingCharacters(in: .whitespaces)
            if !flattened.isEmpty {
                line += " " + flattened
            }
        }
        return line + "\n"
    }

    private static func errResponse(for error: Error) -> String {
        switch error {
        case WGShowExecutorError.wgMissing:
            return errResponse(code: "wg-missing", detail: nil)
        case WGShowExecutorError.timedOut:
            return errResponse(code: "wg-failed", detail: "wg timed out")
        case WGShowExecutorError.wgFailed(let detail):
            return errResponse(code: "wg-failed", detail: detail)
        default:
            return errResponse(code: "wg-failed", detail: error.localizedDescription)
        }
    }

    // MARK: - Чтение/запись с дедлайном

    /// Строка команды до первого `\n` под дедлайном; `nil` — EOF, таймаут,
    /// ошибка сокета или мусор без перевода строки (молчащий клиент не
    /// подвешивает accept-цикл).
    private static func readRequestLine(fd: Int32, deadline: TimeInterval) async -> String? {
        // poll+recv блокируют поток — уходим с кооперативного пула.
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(
                    returning: Self.readRequestLineBlocking(fd: fd, deadline: deadline)
                )
            }
        }
    }

    private static func readRequestLineBlocking(fd: Int32, deadline: TimeInterval) -> String? {
        var buffer: [UInt8] = []
        let deadlineDate = Date().addingTimeInterval(deadline)

        while !buffer.contains(UInt8(ascii: "\n")) {
            guard let chunk = recvChunk(fd: fd, deadline: deadlineDate) else { return nil }
            buffer.append(contentsOf: chunk)
            if buffer.count > maxRequestLength {
                return nil
            }
        }

        let lineEnd = buffer.firstIndex(of: UInt8(ascii: "\n"))!
        return String(bytes: buffer[..<lineEnd], encoding: .utf8)
    }

    /// Один шаг чтения под poll-дедлайном; `nil` — таймаут, EOF или ошибка.
    private static func recvChunk(fd: Int32, deadline: Date) -> [UInt8]? {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            var pollDescriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollDescriptor, 1, Int32(remaining * 1000))
            if ready < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if ready == 0 { return nil }
            var chunk = [UInt8](repeating: 0, count: 256)
            let received = chunk.withUnsafeMutableBytes { raw in
                recv(fd, raw.baseAddress, raw.count, 0)
            }
            if received <= 0 { return nil }
            return Array(chunk[0..<received])
        }
    }

    /// Полная запись ответа под дедлайном; `false` — клиент ушёл (EPIPE) или
    /// не читает — не ошибка цикла.
    @discardableResult
    private static func writeResponse(fd: Int32, text: String, deadline: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(
                    returning: Self.writeResponseBlocking(fd: fd, text: text, deadline: deadline)
                )
            }
        }
    }

    private static func writeResponseBlocking(fd: Int32, text: String, deadline: TimeInterval) -> Bool {
        let bytes = Array(text.utf8)
        var offset = 0
        let deadlineDate = Date().addingTimeInterval(deadline)

        while offset < bytes.count {
            let remaining = deadlineDate.timeIntervalSinceNow
            guard remaining > 0 else { return false }
            var pollDescriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&pollDescriptor, 1, Int32(remaining * 1000))
            if ready < 0 {
                if errno == EINTR { continue }
                return false
            }
            if ready == 0 { return false }
            let sent = bytes.withUnsafeBufferPointer { buffer in
                send(fd, buffer.baseAddress! + offset, bytes.count - offset, 0)
            }
            if sent < 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += sent
        }
        return true
    }
}
