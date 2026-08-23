import XCTest
@testable import WGStatusBarCore

/// Сокет-клиент демона: round-trip против реального `DaemonServer` на tmp-сокете
/// (заглушка исполнителя вместо `wg`) и сырые слушатели-заглушки для сценариев,
/// которые живой сервер произвести не может (мусор, мгновенный EOF, чужие
/// версии заголовка). Реального wg и root нет, процессы не спавнятся.
final class SocketWGShowRunnerTests: XCTestCase {
    private var socketPaths: [String] = []
    private var serverTask: Task<Void, Error>?

    override func tearDown() {
        // Отмена будит accept-цикл фиктивным соединением; здесь чистим остаток
        // на случай гибели задачи сервера.
        serverTask?.cancel()
        for path in socketPaths {
            try? FileManager.default.removeItem(atPath: path)
        }
        socketPaths.removeAll()
        serverTask = nil
        super.tearDown()
    }

    // sun_path вмещает ~103 байта — короткий /tmp-путь с усечённым UUID.
    private func makeSocketPath() -> String {
        let path = "/tmp/wgstatusbar-socketrunnertests-"
            + UUID().uuidString.prefix(8)
            + ".sock"
        socketPaths.append(path)
        return path
    }

    private func stubError(_ operation: String, _ errno: Int32) -> NSError {
        NSError(
            domain: "SocketWGShowRunnerTests",
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: errno \(errno)"]
        )
    }

    // MARK: - Фикстуры

    /// Заглушка исполнителя: конфигурируемый дамп/ошибка/задержка.
    private final class StubExecutor: WGShowExecuting {
        private let lock = NSLock()
        private var dump = ""
        private var thrownError: Error?
        private var delay: TimeInterval = 0

        func configure(dump: String = "", error: Error? = nil, delay: TimeInterval = 0) {
            lock.withLock {
                self.dump = dump
                self.thrownError = error
                self.delay = delay
            }
        }

        func runDump() async throws -> String {
            let (dump, thrownError, delay) = lock.withLock { (self.dump, self.thrownError, self.delay) }
            if delay > 0 {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            if let thrownError {
                throw thrownError
            }
            return dump
        }
    }

    /// Поднимает `DaemonServer` и ждёт настоящего listen-состояния: файл сокета
    /// появляется на bind — раньше listen, и connect в этом окне ловит
    /// ECONNREFUSED (флейк).
    private func startServer(executor: WGShowExecuting, socketPath: String) async throws {
        let server = DaemonServer(executor: executor, socketPath: socketPath)
        serverTask = Task.detached { try await server.run() }
        try waitUntilListening(socketPath: socketPath)
    }

    private func waitUntilListening(socketPath: String, timeout: TimeInterval = 5) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            if fd >= 0 {
                let connected = withUnixSocketAddress(path: socketPath) { address, length in
                    connect(fd, address, length)
                }
                close(fd)
                if connected == 0 { return }
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTFail("сервер не начал слушать \(socketPath) за \(timeout) с")
    }

    /// Слушатель-заглушка ровно на одно соединение: bind+listen синхронно
    /// (connect клиента детерминированно попадает в backlog), accept в фоне —
    /// вычитывает запрос, как реальный сервер (клиент успевает отправить до
    /// close — иначе его send ловит EPIPE, гонка), отвечает фиксированным
    /// текстом (`nil` — мгновенный EOF) и закрывает. Для битых и устаревших
    /// ответов, которые живой DaemonServer произвести не может.
    private func serveOneConnection(path: String, response: String?) throws {
        try? FileManager.default.removeItem(atPath: path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw stubError("socket", errno) }
        // SIGPIPE-подавление наследуется принятым сокетом: запись в уже ушедшего
        // клиента — ошибка write, а не смерть тестового процесса.
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        // Darwin.bind: в тест-таргете голый `bind` резолвится в NSObject-метод
        // Cocoa bindings.
        let bound = withUnixSocketAddress(path: path) { address, length in
            Darwin.bind(fd, address, length)
        }
        guard bound == 0 else {
            close(fd)
            throw stubError("bind", errno)
        }
        guard listen(fd, 1) == 0 else {
            close(fd)
            throw stubError("listen", errno)
        }

        let responseBytes = response.map { Array($0.utf8) }
        Thread.detachNewThread {
            defer {
                close(fd)
                try? FileManager.default.removeItem(atPath: path)
            }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            Self.drainRequestLine(fd: client)
            if let responseBytes {
                responseBytes.withUnsafeBufferPointer { buffer in
                    _ = write(client, buffer.baseAddress, buffer.count)
                }
            }
        }
    }

    /// Вычитывает строку запроса до `\n`/EOF/таймаута — содержимое не важно.
    private static func drainRequestLine(fd: Int32) {
        var buffer: [UInt8] = []
        let deadline = Date().addingTimeInterval(2)
        while !buffer.contains(UInt8(ascii: "\n")) {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return }
            var pollDescriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pollDescriptor, 1, Int32(remaining * 1000)) > 0 else { return }
            var chunk = [UInt8](repeating: 0, count: 256)
            let received = chunk.withUnsafeMutableBytes { raw in
                recv(fd, raw.baseAddress, raw.count, 0)
            }
            guard received > 0 else { return }
            buffer.append(contentsOf: chunk[0..<received])
        }
    }

    /// Сокет-файл без слушателя: bind и close без listen — connect получает
    /// ECONNREFUSED (демон убит, файл остался).
    private func makeStaleSocketFile(path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw stubError("socket", errno) }
        defer { close(fd) }
        let bound = withUnixSocketAddress(path: path) { address, length in
            Darwin.bind(fd, address, length)
        }
        guard bound == 0 else { throw stubError("bind", errno) }
    }

    private func assertRunDumpThrows(
        _ expected: StatusFailure,
        runner: WGShowCommandRunning,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await runner.runDump()
            XCTFail("runDump должен был бросить \(expected)", file: file, line: line)
        } catch let failure as StatusFailure {
            XCTAssertEqual(failure, expected, file: file, line: line)
        } catch {
            XCTFail("ожидалась StatusFailure \(expected), брошено \(error)", file: file, line: line)
        }
    }

    // MARK: - Round-trip с реальным DaemonServer

    func testRoundTripWithDaemonServerReturnsSanitizedDump() async throws {
        let secretDump =
            "wg0\tSECRETPRIVATEKEY\tpub-key-1\t0\t(none)\n" +
            "wg0\tpub-key-1\tSECRETPSK\tendpoint.example:51820\t10.0.0.0/24\t0\t0\t0\toff\n"
        let socketPath = makeSocketPath()
        let executor = StubExecutor()
        executor.configure(dump: secretDump)
        try await startServer(executor: executor, socketPath: socketPath)

        // Контракт WGShowCommandRunning не меняется: модель видит раннер как
        // источник дампа и не знает о сокете.
        let runner: WGShowCommandRunning = SocketWGShowRunner(socketPath: socketPath)
        let dump = try await runner.runDump()

        XCTAssertEqual(dump, sanitizeWGDump(secretDump), "раннер возвращает дамп, санированный сервером")
        XCTAssertFalse(dump.contains("SECRETPRIVATEKEY"), "private key не должен покидать демон")
        XCTAssertFalse(dump.contains("SECRETPSK"), "preshared key не должен покидать демон")
    }

    // MARK: - err-ответы → типизированные ошибки

    func testExecutorErrResponsesMapToTypedFailures() async throws {
        let socketPath = makeSocketPath()
        let executor = StubExecutor()
        try await startServer(executor: executor, socketPath: socketPath)
        let runner = SocketWGShowRunner(socketPath: socketPath)

        let cases: [(thrown: Error, expected: StatusFailure)] = [
            (WGShowExecutorError.wgMissing, .wgMissing),
            (WGShowExecutorError.wgFailed("wg exited with status 3"), .generic("wg exited with status 3")),
        ]
        for testCase in cases {
            executor.configure(error: testCase.thrown)
            await assertRunDumpThrows(testCase.expected, runner: runner)
        }
    }

    // MARK: - недоступность демона

    func testConnectionRefusedWhenDaemonIsNotListening() async throws {
        // Файл сокета есть, слушателя нет (демон убит без очистки).
        let stalePath = makeSocketPath()
        try makeStaleSocketFile(path: stalePath)
        await assertRunDumpThrows(.connectionRefused, runner: SocketWGShowRunner(socketPath: stalePath))

        // Пути нет вовсе — демона не устанавливали.
        await assertRunDumpThrows(
            .connectionRefused,
            runner: SocketWGShowRunner(socketPath: "/tmp/wgstatusbar-socketrunnertests-missing.sock")
        )
    }

    func testSilenceUntilClientDeadlineMapsToCommandTimeout() async throws {
        let socketPath = makeSocketPath()
        let executor = StubExecutor()
        // Исполнитель молчит дольше клиентского дедлайна — демон не успевает
        // ответить до таймаута клиента.
        executor.configure(dump: "dump", delay: 3)
        try await startServer(executor: executor, socketPath: socketPath)

        let runner = SocketWGShowRunner(socketPath: socketPath, timeout: 0.5)
        let started = Date()
        await assertRunDumpThrows(.commandTimeout, runner: runner)

        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed, 0.4, "тишина должна длиться до клиентского дедлайна")
        XCTAssertLessThan(elapsed, 2.0, "ошибка должна прийти по клиентскому дедлайну, а не позже")
    }

    // MARK: - битый канал

    func testGarbageResponseAndInstantEOFMapToBadResponse() async throws {
        let garbagePath = makeSocketPath()
        try serveOneConnection(path: garbagePath, response: "definitely not a protocol header\n")
        await assertRunDumpThrows(.badResponse, runner: SocketWGShowRunner(socketPath: garbagePath))

        let eofPath = makeSocketPath()
        try serveOneConnection(path: eofPath, response: nil)
        await assertRunDumpThrows(.badResponse, runner: SocketWGShowRunner(socketPath: eofPath))
    }

    // MARK: - версии заголовка → daemonOutdated

    func testForeignHeaderVersionsMapToDaemonOutdated() async throws {
        let cases: [String] = [
            // Чужой протокол в ok.
            "ok \(helperProtocolVersion + 1) \(helperBuildNumber)\nwg0\t(none)\tpub-key-1\t0\t(none)\n",
            // Старый build в ok.
            "ok \(helperProtocolVersion) \(helperBuildNumber - 1)\nwg0\t(none)\tpub-key-1\t0\t(none)\n",
            // Чужой протокол в err — outdated бьёт код ошибки.
            "err \(helperProtocolVersion + 1) \(helperBuildNumber) wg-missing\n",
            // Старый build в err: wg-missing от старого бинаря демона.
            "err \(helperProtocolVersion) \(helperBuildNumber - 1) wg-missing\n",
        ]
        for response in cases {
            let socketPath = makeSocketPath()
            try serveOneConnection(path: socketPath, response: response)
            await assertRunDumpThrows(
                .daemonOutdated,
                runner: SocketWGShowRunner(socketPath: socketPath)
            )
        }
    }

    // MARK: - localizedMessage

    func testLocalizedMessagesMapToL10nStrings() {
        XCTAssertEqual(StatusFailure.wgMissing.localizedMessage, L10n.string("error.wg_missing"))
        XCTAssertEqual(StatusFailure.commandTimeout.localizedMessage, L10n.string("error.wg_show_timeout"))
        XCTAssertEqual(StatusFailure.daemonOutdated.localizedMessage, L10n.string("error.daemon_outdated"))
        XCTAssertEqual(StatusFailure.connectionRefused.localizedMessage, L10n.string("error.service_unreachable"))
        XCTAssertEqual(StatusFailure.badResponse.localizedMessage, L10n.string("error.service_unreachable"))
        XCTAssertEqual(StatusFailure.generic("boom").localizedMessage, "boom")
    }
}
