import XCTest
@testable import WGStatusBarCore

/// Клиент туннельных операций: round-trip против реального `DaemonServer` на
/// tmp-сокете (заглушки стора конфигов и исполнителя вместо wg-quick/wg) и
/// сырые слушатели-заглушки для сценариев, которые живой сервер произвести не
/// может (чужие версии заголовка, мусор, мгновенный EOF). Реального wg-quick
/// и root нет, процессы не спавнятся. Плюс инвариант таймингов: худший случай
/// очереди последовательного демона против клиентского дедлайна операции.
final class SocketTunnelClientTests: XCTestCase {
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
        let path = "/tmp/wgstatusbar-tunnelclienttests-"
            + UUID().uuidString.prefix(8)
            + ".sock"
        socketPaths.append(path)
        return path
    }

    private func stubError(_ operation: String, _ errno: Int32) -> NSError {
        NSError(
            domain: "SocketTunnelClientTests",
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: errno \(errno)"]
        )
    }

    // MARK: - Фикстуры

    /// Заглушка исполнителя `show` — туннельные тесты его не трогают,
    /// `DaemonServer` требует хоть какой-то.
    private final class StubShowExecutor: WGShowExecuting {
        func runDump() async throws -> String { "" }
    }

    /// Псевдодиректория конфигов: один «существующий» путь с настраиваемым
    /// листингом (по образцу HelperDaemonTests).
    private final class StubConfigFileSystem: TunnelConfigFileSystem {
        static let directory = "/tmp/wgstatusbar-tunnelclienttests-configs"
        var entries: [String] = []

        func contentsOfDirectory(atPath path: String) -> [String]? {
            path == Self.directory ? entries : nil
        }

        func isDirectory(atPath path: String) -> Bool {
            path == Self.directory
        }
    }

    private func makeConfigStore(names: [String]) -> TunnelConfigStore {
        let fileSystem = StubConfigFileSystem()
        fileSystem.entries = names.map { $0 + ".conf" }
        return TunnelConfigStore(
            searchPaths: [StubConfigFileSystem.directory],
            fileSystem: fileSystem
        )
    }

    /// Вызов туннельного исполнителя для ассертов (кортежи не Equatable).
    private struct TunnelCall: Equatable {
        let command: String
        let name: String
    }

    /// Заглушка исполнителя up/down: конфигурируемая ошибка/задержка +
    /// журнал вызовов (по образцу HelperDaemonTests).
    private final class StubTunnelExecutor: WGQuickExecuting {
        private let lock = NSLock()
        private var thrownError: Error?
        private var delay: TimeInterval = 0
        private var callsStorage: [TunnelCall] = []

        func configure(error: Error? = nil, delay: TimeInterval = 0) {
            lock.withLock {
                self.thrownError = error
                self.delay = delay
            }
        }

        var calls: [TunnelCall] {
            lock.withLock { callsStorage }
        }

        func runUp(name: String) async throws {
            try await perform(command: "up", name: name)
        }

        func runDown(name: String) async throws {
            try await perform(command: "down", name: name)
        }

        private func perform(command: String, name: String) async throws {
            let (thrownError, delay) = lock.withLock {
                callsStorage.append(TunnelCall(command: command, name: name))
                return (self.thrownError, self.delay)
            }
            if delay > 0 {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            if let thrownError {
                throw thrownError
            }
        }
    }

    /// Поднимает `DaemonServer` и ждёт настоящего listen-состояния: файл сокета
    /// появляется на bind — раньше listen, и connect в этом окне ловит
    /// ECONNREFUSED (флейк).
    private func startServer(
        socketPath: String,
        configStore: TunnelConfigStore,
        tunnelExecutor: WGQuickExecuting
    ) async throws {
        let server = DaemonServer(
            executor: StubShowExecutor(),
            socketPath: socketPath,
            configStore: configStore,
            tunnelExecutor: tunnelExecutor
        )
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

    /// Слушатель-заглушка ровно на одно соединение: bind+listen синхронно,
    /// accept в фоне — вычитывает запрос и отвечает фиксированным текстом
    /// (`nil` — мгновенный EOF). Для ответов, которые живой DaemonServer
    /// произвести не может (старый build, чужой протокол, мусор).
    private func serveOneConnection(path: String, response: String?) throws {
        try? FileManager.default.removeItem(atPath: path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw stubError("socket", errno) }
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

    private func assertThrowsStatusFailure(
        _ expected: StatusFailure,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("операция должна была бросить \(expected)", file: file, line: line)
        } catch let failure as StatusFailure {
            XCTAssertEqual(failure, expected, file: file, line: line)
        } catch {
            XCTFail("ожидалась StatusFailure \(expected), брошено \(error)", file: file, line: line)
        }
    }

    // MARK: - Round-trip с реальным DaemonServer

    func testListReturnsNamesFromDaemon() async throws {
        let socketPath = makeSocketPath()
        try await startServer(
            socketPath: socketPath,
            configStore: makeConfigStore(names: ["kvmka-ai", "kvmka-full"]),
            tunnelExecutor: StubTunnelExecutor()
        )

        let client = SocketTunnelClient(socketPath: socketPath)
        let names = try await client.list()

        XCTAssertEqual(names, ["kvmka-ai", "kvmka-full"], "list возвращает имена конфигов демона")
    }

    func testListEmptyConfigSetReturnsNoNames() async throws {
        let socketPath = makeSocketPath()
        try await startServer(
            socketPath: socketPath,
            configStore: makeConfigStore(names: []),
            tunnelExecutor: StubTunnelExecutor()
        )

        let client = SocketTunnelClient(socketPath: socketPath)
        let names = try await client.list()

        XCTAssertEqual(names, [], "пустой ok-payload — пустой список, не ошибка")
    }

    func testUpDownRoundTripCallsExecutor() async throws {
        let socketPath = makeSocketPath()
        let executor = StubTunnelExecutor()
        try await startServer(
            socketPath: socketPath,
            configStore: makeConfigStore(names: ["kvmka-ai"]),
            tunnelExecutor: executor
        )

        let client = SocketTunnelClient(socketPath: socketPath)
        try await client.up("kvmka-ai")
        try await client.down("kvmka-ai")

        XCTAssertEqual(
            executor.calls,
            [TunnelCall(command: "up", name: "kvmka-ai"), TunnelCall(command: "down", name: "kvmka-ai")],
            "клиент отправляет имя как есть, демон валидирует и запускает исполнитель"
        )
    }

    // MARK: - err-ответы → локализованные .generic

    func testUpUnknownNameMapsToLocalizedTunnelNotFound() async throws {
        let socketPath = makeSocketPath()
        try await startServer(
            socketPath: socketPath,
            configStore: makeConfigStore(names: []),
            tunnelExecutor: StubTunnelExecutor()
        )

        let client = SocketTunnelClient(socketPath: socketPath)
        await assertThrowsStatusFailure(
            .generic(L10n.string("error.tunnel_not_found"))
        ) {
            try await client.up("ghost")
        }
    }

    func testExecutorErrorsMapToLocalizedGenericsWithoutWireDetail() async throws {
        let socketPath = makeSocketPath()
        let executor = StubTunnelExecutor()
        try await startServer(
            socketPath: socketPath,
            configStore: makeConfigStore(names: ["kvmka-ai"]),
            tunnelExecutor: executor
        )
        let client = SocketTunnelClient(socketPath: socketPath)

        // quickMissing → своя строка; timedOut/failed → общий провал операции.
        // Деталь failed (stderr-хвост) не пересекает wire — демон отвечает
        // кодом; равенство с ожидаемым .generic ловит утечку, если бы деталь
        // всё-таки попала в сообщение.
        let cases: [(thrown: Error, expected: StatusFailure)] = [
            (WGQuickExecutorError.quickMissing, .generic(L10n.string("error.wgquick_missing"))),
            (WGQuickExecutorError.timedOut, .generic(L10n.string("error.tunnel_op_failed"))),
            (
                WGQuickExecutorError.failed("wg-quick: rm /etc/wireguard/kvmka-ai.conf: secret-echo"),
                .generic(L10n.string("error.tunnel_op_failed"))
            ),
        ]
        for testCase in cases {
            executor.configure(error: testCase.thrown)
            await assertThrowsStatusFailure(testCase.expected) {
                try await client.up("kvmka-ai")
            }
        }
    }

    func testErrDetailOnWireIsIgnoredByClient() async throws {
        // Демон туннельные ошибки шлёт без детали (stderr-хвост — только в его
        // лог). Клиент обязан игнорировать деталь, даже если она пришла:
        // wg-quick эхом печатает команды и хуки конфига — показывать её нельзя.
        let socketPath = makeSocketPath()
        try serveOneConnection(
            path: socketPath,
            response: "err \(helperProtocolVersion) \(helperBuildNumber) wg-failed leaked secret-echo\n"
        )

        let client = SocketTunnelClient(socketPath: socketPath)
        await assertThrowsStatusFailure(.generic(L10n.string("error.tunnel_op_failed"))) {
            try await client.up("kvmka-ai")
        }
    }

    func testWGMissingWithMatchingVersionsMapsToTypedWGMissing() async throws {
        // Защитная ветка исчерпывающего switch: живой демон туннельным
        // операциям wg-missing не шлёт (отсутствие wg внутри wg-quick —
        // wg-failed), но код обязан маппиться в типизированный wgMissing,
        // а не в .generic.
        let socketPath = makeSocketPath()
        try serveOneConnection(
            path: socketPath,
            response: "err \(helperProtocolVersion) \(helperBuildNumber) wg-missing\n"
        )

        let client = SocketTunnelClient(socketPath: socketPath)
        await assertThrowsStatusFailure(.wgMissing) { try await client.up("kvmka-ai") }
    }

    func testTunnelKeysExistInBothLocalizations() throws {
        // Гигиена: отсутствие ключа в таблице не ловится ничем другим — UI
        // показал бы сырой ключ вместо строки.
        let keys = [
            "error.wgquick_missing",
            "error.tunnel_not_found",
            "error.tunnel_op_failed",
            "menu.tunnels_section",
            "tunnel.accessibility.on",
            "tunnel.accessibility.off",
        ]
        for language in ["en", "ru"] {
            let lprojPath = try XCTUnwrap(
                Bundle.module.path(forResource: language, ofType: "lproj"),
                "нет \(language).lproj в бандле модуля"
            )
            let bundle = Bundle(path: lprojPath)
            for key in keys {
                // localizedString(forKey:value:) при отсутствии ключа возвращает value
                let raw = bundle?.localizedString(forKey: key, value: key, table: "Localizable")
                XCTAssertNotEqual(raw, key, "ключ \(key) отсутствует в \(language)")
            }
        }
        // Тишина операции — общий провал, не commandTimeout про wg show.
        XCTAssertNotEqual(L10n.string("error.tunnel_op_failed"), L10n.string("error.wg_show_timeout"))
    }

    // MARK: - недоступность демона

    func testConnectionRefusedWhenDaemonIsNotListening() async throws {
        // Файл сокета есть, слушателя нет (демон убит без очистки).
        let stalePath = makeSocketPath()
        try makeStaleSocketFile(path: stalePath)
        let staleClient = SocketTunnelClient(socketPath: stalePath)
        await assertThrowsStatusFailure(.connectionRefused) { try await staleClient.list() }
        await assertThrowsStatusFailure(.connectionRefused) { try await staleClient.up("kvmka-ai") }

        // Пути нет вовсе — демона не устанавливали.
        let missingClient = SocketTunnelClient(
            socketPath: "/tmp/wgstatusbar-tunnelclienttests-missing.sock"
        )
        await assertThrowsStatusFailure(.connectionRefused) { try await missingClient.list() }
    }

    func testSilenceUntilDeadlineMapsToGenericOpFailure() async throws {
        let socketPath = makeSocketPath()
        let executor = StubTunnelExecutor()
        // Исполнитель молчит дольше клиентского дедлайна — демон не успевает
        // ответить до таймаута клиента.
        executor.configure(delay: 3)
        try await startServer(
            socketPath: socketPath,
            configStore: makeConfigStore(names: ["kvmka-ai"]),
            tunnelExecutor: executor
        )

        let client = SocketTunnelClient(socketPath: socketPath, timeout: 0.5)
        let started = Date()
        await assertThrowsStatusFailure(.generic(L10n.string("error.tunnel_op_failed"))) {
            try await client.up("kvmka-ai")
        }

        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed, 0.4, "тишина должна длиться до клиентского дедлайна")
        XCTAssertLessThan(elapsed, 2.0, "ошибка должна прийти по клиентскому дедлайну, а не позже")
    }

    // MARK: - битый канал

    func testGarbageResponseAndInstantEOFMapToBadResponse() async throws {
        let garbagePath = makeSocketPath()
        try serveOneConnection(path: garbagePath, response: "definitely not a protocol header\n")
        let garbageClient = SocketTunnelClient(socketPath: garbagePath)
        await assertThrowsStatusFailure(.badResponse) { try await garbageClient.list() }

        let eofPath = makeSocketPath()
        try serveOneConnection(path: eofPath, response: nil)
        let eofClient = SocketTunnelClient(socketPath: eofPath)
        await assertThrowsStatusFailure(.badResponse) { try await eofClient.up("kvmka-ai") }
    }

    // MARK: - версии заголовка → daemonOutdated

    func testForeignHeaderVersionsMapToDaemonOutdated() async throws {
        let cases: [String] = [
            // Чужой протокол в ok.
            "ok \(helperProtocolVersion + 1) \(helperBuildNumber)\nkvmka-ai\n",
            // Старый build в ok — демон до туннельных команд.
            "ok \(helperProtocolVersion) \(helperBuildNumber - 1)\nkvmka-ai\n",
            // Чужой протокол в err — outdated бьёт код ошибки.
            "err \(helperProtocolVersion + 1) \(helperBuildNumber) wg-quick-missing\n",
            // Старый build в err: unknown command от старого бинаря демона.
            "err \(helperProtocolVersion) \(helperBuildNumber - 1) wg-failed unknown command\n",
        ]
        for response in cases {
            let socketPath = makeSocketPath()
            try serveOneConnection(path: socketPath, response: response)
            let client = SocketTunnelClient(socketPath: socketPath)
            await assertThrowsStatusFailure(.daemonOutdated) { try await client.list() }
        }
    }

    // MARK: - инвариант таймингов

    func testSequentialDaemonWorstCaseFitsUnderOpDeadline() {
        // Инвариант: худший случай очереди последовательного accept-loop —
        // show-тик, стартовавший ДО клика (подавление тика в модели работает
        // только для последующих), держит демон до конца show-бюджета, затем
        // операция тратит свой op-бюджет. Сумма бюджетов обязана с запасом
        // укладываться в клиентский дедлайн операции — иначе зависший wg-quick
        // встречает тишину клиента (ложный провал) вместо err-ответа демона.
        let showBudget = WGShowExecutor.defaultTimeout + 2 * WGShowExecutor.defaultKillGrace
        let opBudget = WGQuickExecutor.defaultOpTimeout + 2 * WGQuickExecutor.defaultKillGrace
        XCTAssertLessThan(
            showBudget + opBudget,
            SocketTunnelClient.opTimeout,
            "худший случай очереди демона (\(showBudget) c + \(opBudget) c = \(showBudget + opBudget) c) "
                + "обязан укладываться в дедлайн операции (\(SocketTunnelClient.opTimeout) c)"
        )
    }
}
