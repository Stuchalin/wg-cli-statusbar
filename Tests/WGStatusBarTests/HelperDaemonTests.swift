import XCTest
@testable import WGStatusBarCore

/// Сервер демона против tmp-сокета в одном процессе: заглушка исполнителя вместо
/// реального `wg`, клиент — сырой unix-сокет (как будущий SocketWGShowRunner).
/// Реального wg и root здесь нет, процессы не спавнятся.
final class HelperDaemonTests: XCTestCase {
    private var socketPath = ""
    private var serverTask: Task<Void, Error>?

    override func setUp() {
        super.setUp()
        // sun_path вмещает ~103 байта — NSTemporaryDirectory() с UUID не влезает,
        // поэтому короткий /tmp-путь с усечённым UUID (уникальности хватает).
        socketPath = "/tmp/wgstatusbar-helperdaemontests-"
            + UUID().uuidString.prefix(8)
            + ".sock"
    }

    override func tearDown() {
        // Отмена будит accept-цикл фиктивным соединением, run() завершится и
        // приберёт сокет-файл сам; здесь чистим остаток на случай его гибели.
        serverTask?.cancel()
        try? FileManager.default.removeItem(atPath: socketPath)
        serverTask = nil
        super.tearDown()
    }

    // MARK: - Фикстуры

    private func startServer(executor: WGShowExecuting, readDeadline: TimeInterval = 5) async throws {
        let server = DaemonServer(executor: executor, socketPath: socketPath, readDeadline: readDeadline)
        serverTask = Task.detached { try await server.run() }
        // Файл сокета появляется на bind — раньше accept-цикла.
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: socketPath) {
            if Date() > deadline {
                XCTFail("сервер не поднял сокет \(socketPath) за 5 с")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Заглушка исполнителя: конфигурируемый дамп/ошибка/задержка + счётчики
    /// (запуски и завершённые вызовы — отмена до конца задержки не считается
    /// завершившимся).
    private final class StubExecutor: WGShowExecuting {
        private let lock = NSLock()
        private var dump = ""
        private var thrownError: Error?
        private var delay: TimeInterval = 0
        private var startCounter = 0
        private var callCounter = 0

        func configure(dump: String = "", error: Error? = nil, delay: TimeInterval = 0) {
            lock.withLock {
                self.dump = dump
                self.thrownError = error
                self.delay = delay
            }
        }

        /// Вызовы, дошедшие до задержки (она уже идёт с зафиксированным значением —
        /// переконфигурация действует только на следующие).
        var startCount: Int {
            lock.withLock { startCounter }
        }

        var callCount: Int {
            lock.withLock { callCounter }
        }

        func runDump() async throws -> String {
            let (dump, thrownError, delay) = lock.withLock {
                startCounter += 1
                return (self.dump, self.thrownError, self.delay)
            }
            if delay > 0 {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            lock.withLock { callCounter += 1 }
            if let thrownError {
                throw thrownError
            }
            return dump
        }
    }

    // MARK: - Клиент (POSIX-сокет, без зависимости от клиента приложения)

    /// Сокет-файл без слушателя: bind без listen и close — как после гибели
    /// демона без очистки (launchd поднимет бинарь заново поверх файла).
    private func makeStaleSocketFile() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw clientError("socket", errno) }
        defer { close(fd) }
        let bound = withUnixSocketAddress(path: socketPath) { address, length in
            Darwin.bind(fd, address, length)  // голый bind в тест-таргете конфликтует с Cocoa bindings
        }
        guard bound == 0 else { throw clientError("bind", errno) }
    }

    private func connectToServer() throws -> Int32 {
        // Между появлением файла сокета (bind) и listen есть крошечное окно,
        // где connect получает ECONNREFUSED — ретраим, чтобы не флейкать.
        var lastErrno = ECONNREFUSED
        for _ in 0..<100 {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else {
                throw clientError("socket", errno)
            }
            let connected = withUnixSocketAddress(path: socketPath) { address, length in
                connect(fd, address, length)
            }
            if connected == 0 {
                return fd
            }
            lastErrno = errno
            close(fd)
            if lastErrno != ECONNREFUSED {
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw clientError("connect", lastErrno)
    }

    private func clientError(_ operation: String, _ errno: Int32) -> NSError {
        NSError(
            domain: "HelperDaemonTests",
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: errno \(errno)"]
        )
    }

    private func sendAll(_ fd: Int32, _ text: String) throws {
        let bytes = Array(text.utf8)
        let written = bytes.withUnsafeBufferPointer { buffer in
            write(fd, buffer.baseAddress, buffer.count)
        }
        guard written == bytes.count else {
            throw clientError("write", errno)
        }
    }

    /// Читает до EOF под таймаутом: успешный возврат значит, что сервер закрыл
    /// соединение после ответа (протокол — одно соединение = один запрос).
    private func readToEOF(_ fd: Int32, timeout: TimeInterval = 5) throws -> (response: String, elapsed: TimeInterval) {
        let started = Date()
        let deadline = started.addingTimeInterval(timeout)
        var data: [UInt8] = []
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw clientError("read timeout", ETIMEDOUT) }
            var pollDescriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollDescriptor, 1, Int32(remaining * 1000))
            guard ready > 0 else { throw clientError("poll", errno) }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let received = chunk.withUnsafeMutableBytes { raw in
                recv(fd, raw.baseAddress, raw.count, 0)
            }
            guard received > 0 else { break }
            data.append(contentsOf: chunk[0..<received])
        }
        let response = String(bytes: data, encoding: .utf8) ?? ""
        return (response, Date().timeIntervalSince(started))
    }

    /// Полный обмен: connect → send (`nil` — молчащий клиент, только connect) → читать до EOF.
    @discardableResult
    private func performExchange(
        _ request: String?,
        readTimeout: TimeInterval = 5
    ) throws -> (response: String, elapsed: TimeInterval) {
        let fd = try connectToServer()
        defer { close(fd) }
        if let request {
            try sendAll(fd, request)
        }
        return try readToEOF(fd, timeout: readTimeout)
    }

    /// Клиент уходит до ответа сервера: connect → send → close, не читая.
    private func connectSendAndClose(_ request: String) throws {
        let fd = try connectToServer()
        try sendAll(fd, request)
        close(fd)
    }

    private func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("условие не наступило за \(timeout) с")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - show → ok + санитизация сервером

    func testShowReturnsOkHeaderWithVersionsAndSanitizedDump() async throws {
        let secretDump =
            "wg0\tSECRETPRIVATEKEY\tpub-key-1\t0\t(none)\n" +
            "wg0\tpub-key-1\tSECRETPSK\tendpoint.example:51820\t10.0.0.0/24\t0\t0\t0\toff\n"
        let executor = StubExecutor()
        executor.configure(dump: secretDump)
        try await startServer(executor: executor)

        let exchange = try performExchange(encode(.show))
        let response = try XCTUnwrap(
            decode(response: exchange.response),
            "ответ сервера должен разобраться кодеком протокола"
        )

        XCTAssertEqual(
            response,
            .ok(protocolVersion: helperProtocolVersion, build: helperBuildNumber, dump: sanitizeWGDump(secretDump)),
            "заголовок — версии демона из констант, дамп — санированный"
        )
        // Единая точка санитизации — сервер: маркеры секретов не покидают демон.
        XCTAssertFalse(exchange.response.contains("SECRETPRIVATEKEY"), "private key не должен попасть в ответ")
        XCTAssertFalse(exchange.response.contains("SECRETPSK"), "preshared key не должен попасть в ответ")
    }

    // MARK: - ошибки исполнителя → err с версиями

    func testExecutorErrorMapsToErrResponse() async throws {
        let cases: [(thrown: Error, expectedCode: HelperResponseCode, expectedDetail: String?)] = [
            (WGShowExecutorError.wgMissing, .wgMissing, nil),
            (WGShowExecutorError.wgFailed("wg exited with status 3"), .wgFailed, "wg exited with status 3"),
            (WGShowExecutorError.timedOut, .wgFailed, "wg timed out"),
            // stderr wg бывает многострочным: деталь обязана стать одной строкой.
            (WGShowExecutorError.wgFailed("line1\nline2\twith tab"), .wgFailed, "line1 line2 with tab"),
            // Деталь из одних пробелов после flatten — пустая, опускается.
            (WGShowExecutorError.wgFailed(" \n\t "), .wgFailed, nil),
        ]
        let executor = StubExecutor()
        try await startServer(executor: executor)

        for testCase in cases {
            executor.configure(error: testCase.thrown)
            let exchange = try performExchange(encode(.show))
            let response = try XCTUnwrap(
                decode(response: exchange.response),
                "ошибка исполнителя должна давать err-ответ, а не разрыв: \(testCase.thrown)"
            )
            XCTAssertEqual(
                response,
                .err(
                    protocolVersion: helperProtocolVersion,
                    build: helperBuildNumber,
                    code: testCase.expectedCode,
                    detail: testCase.expectedDetail
                ),
                "для брошенной ошибки \(testCase.thrown)"
            )
        }
    }

    // MARK: - неизвестная команда

    func testUnknownCommandReturnsErrAndClosesConnection() async throws {
        let executor = StubExecutor()
        try await startServer(executor: executor)

        // Успешный возврат readToEOF = сервер закрыл соединение после ответа.
        let exchange = try performExchange("bogus\n")
        let response = try XCTUnwrap(decode(response: exchange.response))
        XCTAssertEqual(
            response,
            .err(
                protocolVersion: helperProtocolVersion,
                build: helperBuildNumber,
                code: .wgFailed,
                detail: "unknown command: bogus"
            )
        )
        XCTAssertEqual(executor.callCount, 0, "неизвестная команда не должна трогать исполнителя")
    }

    // MARK: - устойчивость accept-цикла

    func testTwoSequentialConnectionsAreServed() async throws {
        let executor = StubExecutor()
        try await startServer(executor: executor)

        for (index, dump) in ["dump-one\n", "dump-two\n"].enumerated() {
            executor.configure(dump: dump)
            let exchange = try performExchange(encode(.show))
            let response = try XCTUnwrap(decode(response: exchange.response))
            XCTAssertEqual(response, .ok(protocolVersion: helperProtocolVersion, build: helperBuildNumber, dump: dump))
            XCTAssertEqual(executor.callCount, index + 1, "каждое соединение — один вызов исполнителя")
        }
    }

    func testClientDisconnectedBeforeResponseDoesNotKillLoop() async throws {
        let executor = StubExecutor()
        // Задержка: клиент закрывается раньше, чем сервер отвечает — работа
        // отменяется по EOF, цикл не ждёт конца задержки.
        executor.configure(dump: "dump\n", delay: 0.15)
        try await startServer(executor: executor)

        try connectSendAndClose(encode(.show))

        // Цикл жив после отключившегося клиента: следующий обслуживается.
        let exchange = try performExchange(encode(.show))
        let response = try XCTUnwrap(
            decode(response: exchange.response),
            "после отключившегося клиента сервер должен обслужить следующего"
        )
        XCTAssertEqual(response, .ok(protocolVersion: helperProtocolVersion, build: helperBuildNumber, dump: "dump\n"))
        XCTAssertEqual(executor.callCount, 1, "отменённый вызов не считается завершившимся, второй — доходит до конца")
    }

    func testClientEOFDuringLongWorkCancelsExecutorAndFreesLoop() async throws {
        // План: EOF клиента посреди запроса — демон прекращает ожидание
        // ребёнка. Длинная работа (30 с) отменяется по закрытию клиента —
        // следующий клиент обслуживается задолго до её конца.
        let executor = StubExecutor()
        executor.configure(dump: "dump\n", delay: 30)
        try await startServer(executor: executor)

        try connectSendAndClose(encode(.show))
        // Первый вызов уже в 30-секундной задержке — теперь её можно снять:
        // конфиг действует на следующие вызовы, текущий продолжает спать,
        // пока EOF-отмена его не разбудит.
        try await waitFor { executor.startCount == 1 }
        executor.configure(dump: "dump\n")

        let exchange = try performExchange(encode(.show), readTimeout: 5)
        let response = try XCTUnwrap(
            decode(response: exchange.response),
            "сервер обязан обслужить следующего клиента не дожидаясь 30-секундной работы"
        )
        XCTAssertEqual(response, .ok(protocolVersion: helperProtocolVersion, build: helperBuildNumber, dump: "dump\n"))
        XCTAssertLessThan(
            exchange.elapsed,
            10,
            "EOF первого клиента должен освобождать accept-loop отменой работы, а не ждать её конца"
        )
        XCTAssertEqual(executor.callCount, 1, "первый (отменённый) вызов не считается завершившимся")
    }

    func testSilentClientIsClosedByReadDeadlineAndLoopSurvives() async throws {
        let executor = StubExecutor()
        executor.configure(dump: "dump\n")
        try await startServer(executor: executor, readDeadline: 0.2)

        let exchange = try performExchange(nil)

        XCTAssertEqual(exchange.response, "", "молчащему клиенту сервер ничего не отвечает — только закрывает")
        XCTAssertLessThan(
            exchange.elapsed,
            2.0,
            "EOF должен приходить по инжектированному короткому дедлайну чтения, а не по умолчанию 5 с"
        )

        // Цикл жив: следующий клиент обслуживается.
        let followUp = try performExchange(encode(.show))
        let response = try XCTUnwrap(
            decode(response: followUp.response),
            "после молчащего клиента сервер должен обслужить следующего"
        )
        XCTAssertEqual(response, .ok(protocolVersion: helperProtocolVersion, build: helperBuildNumber, dump: "dump\n"))
    }

    func testExtraDataAfterCommandDoesNotDisturbResponse() async throws {
        // Лишние данные после строки команды (протокол — одна строка на
        // соединение): наблюдатель EOF поглощает их по байту, не мешая ни
        // ответу, ни детекции EOF — ответ доходит, цикл жив.
        let executor = StubExecutor()
        // Задержка: мусор гарантированно попадает в сокет, пока работает
        // исполнитель и живёт наблюдатель.
        executor.configure(dump: "dump\n", delay: 0.1)
        try await startServer(executor: executor)

        let fd = try connectToServer()
        defer { close(fd) }
        try sendAll(fd, encode(.show) + "garbage-after-command")
        let exchange = try readToEOF(fd)

        let response = try XCTUnwrap(
            decode(response: exchange.response),
            "мусор после команды не должен мешать ответу на саму команду"
        )
        XCTAssertEqual(response, .ok(protocolVersion: helperProtocolVersion, build: helperBuildNumber, dump: "dump\n"))

        let followUp = try performExchange(encode(.show))
        XCTAssertNotNil(
            decode(response: followUp.response),
            "после клиента с мусором сервер должен обслужить следующего"
        )
    }

    // MARK: - перезапуск поверх протухшего сокет-файла

    func testServerSurvivesStaleSocketFileLeftByDeadDaemon() async throws {
        // Перезапуск демона (launchd KeepAlive) поверх протухшего сокет-файла:
        // unlink+bind на старте должен перебиндить путь, exchange работает.
        try makeStaleSocketFile()

        let executor = StubExecutor()
        executor.configure(dump: "dump\n")
        try await startServer(executor: executor)

        let exchange = try performExchange(encode(.show))
        let response = try XCTUnwrap(
            decode(response: exchange.response),
            "протухший сокет-файл не должен мешать bind нового демона"
        )
        XCTAssertEqual(response, .ok(protocolVersion: helperProtocolVersion, build: helperBuildNumber, dump: "dump\n"))
    }

    // MARK: - мусор без перевода строки сверх лимита

    func testOverlongRequestWithoutNewlineIsDroppedAndLoopSurvives() async throws {
        let executor = StubExecutor()
        executor.configure(dump: "dump\n")
        try await startServer(executor: executor)

        // 2 КБ без `\n` — превышение лимита длины запроса: соединение
        // закрывается молча, исполнитель не трогается, цикл жив.
        let fd = try connectToServer()
        try sendAll(fd, String(repeating: "x", count: 2048))
        close(fd)

        XCTAssertEqual(executor.callCount, 0, "мусор не должен доходить до исполнителя")
        let followUp = try performExchange(encode(.show))
        let response = try XCTUnwrap(
            decode(response: followUp.response),
            "после сверхдлинного мусорного запроса сервер должен обслужить следующего"
        )
        XCTAssertEqual(response, .ok(protocolVersion: helperProtocolVersion, build: helperBuildNumber, dump: "dump\n"))
        XCTAssertEqual(executor.callCount, 1)
    }
}
