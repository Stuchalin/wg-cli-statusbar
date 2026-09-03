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

    private func startServer(
        executor: WGShowExecuting,
        readDeadline: TimeInterval = 5,
        configStore: TunnelConfigStore = TunnelConfigStore(
            searchPaths: [],
            fileSystem: FileManagerTunnelConfigFileSystem()
        ),
        tunnelExecutor: WGQuickExecuting = StubTunnelExecutor(),
        runtimeReader: WireGuardRuntimeReader? = nil,
        configReader: TunnelConfigReader? = nil
    ) async throws {
        let server = DaemonServer(
            executor: executor,
            socketPath: socketPath,
            readDeadline: readDeadline,
            configStore: configStore,
            tunnelExecutor: tunnelExecutor,
            // Дефолт — пустой псевдокаталог `/var/run/wireguard`: настоящая
            // машина не должна протекать в тесты (по образцу
            // SocketTunnelClientTests.startServer).
            runtimeReader: runtimeReader ?? makeRuntimeReader(StubRuntimeFileSystem()),
            configReader: configReader ?? makeConfigReader(FakeReaderFileSystem())
        )
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

    // MARK: - Фикстуры туннельных запросов

    /// Псевдодиректория конфигов: один «существующий» путь с настраиваемым
    /// листингом — стор поверх неё, как FakeConfigFileSystem в тестах стора.
    private final class StubConfigFileSystem: TunnelConfigFileSystem {
        static let directory = "/tmp/wgstatusbar-helperdaemontests-configs"
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

    /// Псевдокаталог `/var/run/wireguard` для запроса `state`: мутабельная
    /// карта «имя файла → содержимое + mtime» поверх протокола ридера — пары
    /// добавляются и убираются между запросами; у пары один штамп времени,
    /// поэтому |Δmtime| = 0 < 2 c (правило свежести проходит).
    private final class StubRuntimeFileSystem: WireGuardTunnelNameFileSystem {
        private let lock = NSLock()
        private var files: [String: (contents: String, modificationDate: Date)] = [:]

        func addPair(config: String, interface: String) {
            let stamp = Date()
            lock.withLock {
                files[config + ".name"] = (interface, stamp)
                files[interface + ".sock"] = ("", stamp)
            }
        }

        /// Убирает только `.name`: пара распадается, сокет-сосед остаётся —
        /// как зависшая после сноса туннеля запись.
        func removeNameFile(config: String) {
            lock.withLock {
                files.removeValue(forKey: config + ".name")
            }
        }

        private func file(at path: String) -> (contents: String, modificationDate: Date)? {
            lock.withLock { files[(path as NSString).lastPathComponent] }
        }

        func entries(inDirectory path: String) -> [String] {
            lock.withLock { Array(files.keys) }
        }

        func contents(ofFile path: String) -> String? {
            file(at: path)?.contents
        }

        func fileExists(atPath path: String) -> Bool {
            file(at: path) != nil
        }

        func modificationDate(ofFile path: String) -> Date? {
            file(at: path)?.modificationDate
        }
    }

    private func makeRuntimeReader(_ fileSystem: WireGuardTunnelNameFileSystem) -> WireGuardRuntimeReader {
        WireGuardRuntimeReader(fileSystem: fileSystem)
    }

    // MARK: - Фикстуры запроса config

    /// Фейковый FS ридера конфигов: исходы открытия по точному пути
    /// (по образцу TunnelConfigReaderTests).
    private final class FakeReaderFileSystem: TunnelConfigReaderFileSystem {
        var outcomes: [String: TunnelConfigOpenOutcome] = [:]

        func openFileNoFollow(atPath path: String) -> TunnelConfigOpenOutcome {
            outcomes[path] ?? .notFound
        }
    }

    /// Фейковый дескриптор: содержимое целиком, флаг регулярности.
    private final class FakeReaderFileHandle: TunnelConfigReaderFileHandle {
        private let content: [UInt8]
        private var offset = 0
        var regular = true

        init(content: [UInt8]) {
            self.content = content
        }

        var isRegularFile: Bool { regular }

        func read(into buffer: UnsafeMutableRawPointer, maxLength: Int) -> TunnelConfigReadChunk {
            guard offset < content.count else { return .endOfFile }
            let count = min(maxLength, content.count - offset)
            content.withUnsafeBytes { raw in
                _ = memcpy(buffer, raw.baseAddress!.advanced(by: offset), count)
            }
            offset += count
            return .bytes(count)
        }

        func close() {}
    }

    private func makeConfigReader(_ fs: FakeReaderFileSystem) -> TunnelConfigReader {
        TunnelConfigReader(searchPaths: [StubConfigFileSystem.directory], fileSystem: fs)
    }

    private func configFilePath(_ name: String) -> String {
        StubConfigFileSystem.directory + "/" + name + ".conf"
    }

    /// Вызов туннельного исполнителя для ассертов (кортежи не Equatable).
    private struct TunnelCall: Equatable {
        let command: String
        let name: String
    }

    /// Заглушка исполнителя up/down: конфигурируемая ошибка/задержка +
    /// счётчики и журнал вызовов (по образцу StubExecutor).
    private final class StubTunnelExecutor: WGQuickExecuting {
        private let lock = NSLock()
        private var thrownError: Error?
        private var delay: TimeInterval = 0
        private var callsStorage: [TunnelCall] = []
        private var startCounter = 0
        private var callCounter = 0

        func configure(error: Error? = nil, delay: TimeInterval = 0) {
            lock.withLock {
                self.thrownError = error
                self.delay = delay
            }
        }

        var calls: [TunnelCall] {
            lock.withLock { callsStorage }
        }

        var startCount: Int {
            lock.withLock { startCounter }
        }

        var callCount: Int {
            lock.withLock { callCounter }
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
                startCounter += 1
                return (self.thrownError, self.delay)
            }
            if delay > 0 {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            lock.withLock { callCounter += 1 }
            if let thrownError {
                throw thrownError
            }
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

        // Хвост у show/list/state держит команду неизвестной: безадресные
        // команды аргументов не принимают (не «show extra» после появления
        // list/up/down/state).
        let bogusRequests = ["bogus\n", "show extra\n", "list extra\n", "state extra\n"]
        for request in bogusRequests {
            // Успешный возврат readToEOF = сервер закрыл соединение после ответа.
            let exchange = try performExchange(request)
            let response = try XCTUnwrap(decode(response: exchange.response))
            XCTAssertEqual(
                response,
                .err(
                    protocolVersion: helperProtocolVersion,
                    build: helperBuildNumber,
                    code: .wgFailed,
                    detail: "unknown command: \(request.trimmingCharacters(in: .whitespacesAndNewlines))"
                ),
                "для запроса \(request)"
            )
        }
        XCTAssertEqual(executor.callCount, 0, "неизвестная команда не должна трогать исполнителя")
    }

    // MARK: - list → имена конфигов

    func testListReturnsNamesFromStoreOnePerLine() async throws {
        let store = makeConfigStore(names: ["kvmka-ai", "kvmka-full"])
        try await startServer(executor: StubExecutor(), configStore: store)

        let exchange = try performExchange(encode(.list))
        let response = try XCTUnwrap(
            decode(response: exchange.response),
            "list должен отвечать ok-payload с именами, а не разрывом"
        )
        XCTAssertEqual(
            response,
            .ok(protocolVersion: helperProtocolVersion, build: helperBuildNumber, dump: "kvmka-ai\nkvmka-full\n"),
            "payload — имена по одному в строке, заголовок — версии из констант"
        )
    }

    func testListWithEmptyStoreReturnsOkWithEmptyPayload() async throws {
        // Конфигов нет (или директорий) — это не ошибка: ok с пустым payload.
        let store = makeConfigStore(names: [])
        try await startServer(executor: StubExecutor(), configStore: store)

        let exchange = try performExchange(encode(.list))
        let response = try XCTUnwrap(decode(response: exchange.response))
        XCTAssertEqual(
            response,
            .ok(protocolVersion: helperProtocolVersion, build: helperBuildNumber, dump: "")
        )
    }

    // MARK: - state → строки состояния туннелей

    func testStateReturnsUpForValidatedPairsAndDownForOthers() async throws {
        // kvmka-full без пары (туннель опущен или запись зависла) — down с
        // пустым третьим полем: полей всегда три, включая пустой utun.
        let store = makeConfigStore(names: ["kvmka-ai", "kvmka-full", "home"])
        let runtime = StubRuntimeFileSystem()
        runtime.addPair(config: "kvmka-ai", interface: "utun2")
        runtime.addPair(config: "home", interface: "utun7")
        try await startServer(
            executor: StubExecutor(),
            configStore: store,
            runtimeReader: makeRuntimeReader(runtime)
        )

        let exchange = try performExchange(encode(.state))
        let response = try XCTUnwrap(
            decode(response: exchange.response),
            "state должен отвечать ok-payload со строками состояния, а не разрывом"
        )
        XCTAssertEqual(
            response,
            .ok(
                protocolVersion: helperProtocolVersion,
                build: helperBuildNumber,
                dump: "home\tup\tutun7\nkvmka-ai\tup\tutun2\nkvmka-full\tdown\t\n"
            ),
            "payload — по строке на конфиг стора (в его порядке): up с utun, down с пустым третьим полем"
        )
    }

    func testStateWithEmptyRuntimeDirectoryReturnsAllDown() async throws {
        // Пустой `/var/run/wireguard` (ни один туннель не поднимался) — не
        // ошибка: каждый конфиг стора отвечает down.
        let store = makeConfigStore(names: ["kvmka-ai", "kvmka-full"])
        try await startServer(
            executor: StubExecutor(),
            configStore: store,
            runtimeReader: makeRuntimeReader(StubRuntimeFileSystem())
        )

        let exchange = try performExchange(encode(.state))
        let response = try XCTUnwrap(decode(response: exchange.response))
        XCTAssertEqual(
            response,
            .ok(
                protocolVersion: helperProtocolVersion,
                build: helperBuildNumber,
                dump: "kvmka-ai\tdown\t\nkvmka-full\tdown\t\n"
            ),
            "нет ни одной пары ридера — все конфиги down с пустым utun-полем"
        )
    }

    func testStateRescansRuntimeDirectoryOnEveryRequest() async throws {
        // Свежий скан на каждый запрос — контракт и ридера, и сервера: пара,
        // убранная между двумя state, обязана превратить второй ответ в down
        // (закэшированный up тихо повторил бы исходный баг «already exists»).
        let store = makeConfigStore(names: ["kvmka-ai"])
        let runtime = StubRuntimeFileSystem()
        runtime.addPair(config: "kvmka-ai", interface: "utun2")
        try await startServer(
            executor: StubExecutor(),
            configStore: store,
            runtimeReader: makeRuntimeReader(runtime)
        )

        let first = try XCTUnwrap(
            decode(response: performExchange(encode(.state)).response)
        )
        XCTAssertEqual(
            first,
            .ok(protocolVersion: helperProtocolVersion, build: helperBuildNumber, dump: "kvmka-ai\tup\tutun2\n")
        )

        runtime.removeNameFile(config: "kvmka-ai")

        let second = try XCTUnwrap(
            decode(response: performExchange(encode(.state)).response)
        )
        XCTAssertEqual(
            second,
            .ok(protocolVersion: helperProtocolVersion, build: helperBuildNumber, dump: "kvmka-ai\tdown\t\n"),
            "удалённая между запросами пара — второй state отвечает down"
        )
    }

    func testStateDoesNotDisturbShowAndListRouting() async throws {
        // state не сдвигает соседние маршруты: show/list на том же сервере,
        // поднятом с ридером, отвечают как раньше.
        let store = makeConfigStore(names: ["kvmka-ai"])
        let runtime = StubRuntimeFileSystem()
        runtime.addPair(config: "kvmka-ai", interface: "utun2")
        let executor = StubExecutor()
        executor.configure(dump: "dump\n")
        try await startServer(
            executor: executor,
            configStore: store,
            runtimeReader: makeRuntimeReader(runtime)
        )

        let state = try XCTUnwrap(decode(response: performExchange(encode(.state)).response))
        XCTAssertEqual(state, .ok(protocolVersion: helperProtocolVersion, build: helperBuildNumber, dump: "kvmka-ai\tup\tutun2\n"))

        let show = try XCTUnwrap(decode(response: performExchange(encode(.show)).response))
        XCTAssertEqual(show, .ok(protocolVersion: helperProtocolVersion, build: helperBuildNumber, dump: "dump\n"))

        let list = try XCTUnwrap(decode(response: performExchange(encode(.list)).response))
        XCTAssertEqual(list, .ok(protocolVersion: helperProtocolVersion, build: helperBuildNumber, dump: "kvmka-ai\n"))
    }

    // MARK: - config → маскированный конверт

    func testConfigReturnsSanitizedEnvelope() async throws {
        // Канарейка — только в значениях назначений ключей; санитизация
        // обязана спрятать оба до того, как байты покинут демон.
        let raw = "[Interface]\n"
            + "PrivateKey = \(configSecretCanary)\n"
            + "ListenPort = 51820\n"
            + "# комментарий: \(configSecretCanary)\n"
            + "[Peer]\n"
            + "PresharedKey = \(configPresharedCanary)\n"
            + "PostUp = echo \(configSecretCanary)\n"
            + "UnknownDirective = \(configSecretCanary)\n"
        let fs = FakeReaderFileSystem()
        fs.outcomes[configFilePath("kvmka-ai")] = .opened(
            FakeReaderFileHandle(content: Array(raw.utf8))
        )
        try await startServer(executor: StubExecutor(), configReader: makeConfigReader(fs))

        let exchange = try performExchange(encode(.config("kvmka-ai")))
        let response = try XCTUnwrap(
            decode(response: exchange.response),
            "config должен отвечать ok-конвертом, а не разрывом"
        )

        let expectedPayload = ConfigEnvelope.encode(sanitizeWGQuickConfig(raw))
        XCTAssertEqual(
            response,
            .ok(protocolVersion: helperProtocolVersion, build: helperBuildNumber, dump: expectedPayload),
            "payload — один b64-конверт санированного текста, заголовок — версии из констант"
        )
        // Fail-closed: сырой ответ не несёт ни приватную, ни preshared-канарейку.
        XCTAssertFalse(exchange.response.contains(configSecretCanary), "private key не должен попасть в ответ")
        XCTAssertFalse(exchange.response.contains(configPresharedCanary), "preshared key не должен попасть в ответ")
    }

    func testConfigRoundTripsEmptyDocument() async throws {
        // Пустой файл — валидный конверт `b64:\n`: пустой документ отличим от
        // отсутствующего ответа.
        let fs = FakeReaderFileSystem()
        fs.outcomes[configFilePath("kvmka-ai")] = .opened(FakeReaderFileHandle(content: []))
        try await startServer(executor: StubExecutor(), configReader: makeConfigReader(fs))

        let exchange = try performExchange(encode(.config("kvmka-ai")))
        XCTAssertEqual(
            exchange.response,
            Self.okResponseText(dump: "b64:\n"),
            "пустой документ — ok с голым тегом конверта"
        )
    }

    func testConfigPreservesDocumentWithoutFinalNewline() async throws {
        // Терминатор конверта — обрамление транспорта; собственный `\n`
        // документа живёт внутри base64 и не появляется из ниоткуда.
        let raw = "[Interface]\nListenPort = 51820"
        let fs = FakeReaderFileSystem()
        fs.outcomes[configFilePath("kvmka-ai")] = .opened(
            FakeReaderFileHandle(content: Array(raw.utf8))
        )
        try await startServer(executor: StubExecutor(), configReader: makeConfigReader(fs))

        let exchange = try performExchange(encode(.config("kvmka-ai")))
        let response = try XCTUnwrap(decode(response: exchange.response))
        guard case .ok(_, _, let payload) = response else {
            XCTFail("ожидался ok-ответ, получен \(response)")
            return
        }
        guard case .success(let text) = ConfigEnvelope.decode(payload) else {
            XCTFail("конверт должен разбираться: \(payload.debugDescription)")
            return
        }
        XCTAssertEqual(text, raw, "отсутствие завершающего \\n сохраняется точно")
    }

    func testConfigWithoutArgumentAndWithTrailingArgumentsIsRejected() async throws {
        // Отсутствующий аргумент — пустое имя, лишние слова — часть имени:
        // оба не проходят валидацию ридера и дают err без детали и payload.
        let bogusRequests = ["config\n", "config one two\n"]
        let fs = FakeReaderFileSystem()
        fs.outcomes[configFilePath("kvmka-ai")] = .opened(
            FakeReaderFileHandle(content: Array("[Interface]\n".utf8))
        )
        try await startServer(executor: StubExecutor(), configReader: makeConfigReader(fs))

        for request in bogusRequests {
            let exchange = try performExchange(request)
            XCTAssertEqual(
                exchange.response,
                Self.errResponseText(code: "config-unavailable"),
                "для запроса \(request)"
            )
        }
    }

    func testConfigReaderFailuresMapToErrConfigUnavailableWithoutPartialOutput() async throws {
        // Все исходы «читать нельзя» — один деталь-фри код: ни содержимое, ни
        // путь, ни частичный документ не покидают демон.
        let fs = FakeReaderFileSystem()
        fs.outcomes[configFilePath("symlinked")] = .symlink
        fs.outcomes[configFilePath("unreadable")] = .unreadable
        let irregular = FakeReaderFileHandle(content: Array("fifo\n".utf8))
        irregular.regular = false
        fs.outcomes[configFilePath("special")] = .opened(irregular)
        fs.outcomes[configFilePath("huge")] = .opened(
            FakeReaderFileHandle(content: [UInt8](repeating: 0x61, count: TunnelConfigReader.maxSizeBytes + 1))
        )
        fs.outcomes[configFilePath("binary")] = .opened(FakeReaderFileHandle(content: [0x41, 0xFF]))
        try await startServer(executor: StubExecutor(), configReader: makeConfigReader(fs))

        let bogusNames = [
            "symlinked", "unreadable", "special", "huge", "binary", // небезопасные файлы
            "nosuch", // файла нет
            "bad name", "../etc/passwd", "abcdefghijklmnop", // имя мимо shape-правила
        ]
        for name in bogusNames {
            let exchange = try performExchange(encode(.config(name)))
            XCTAssertEqual(
                exchange.response,
                Self.errResponseText(code: "config-unavailable"),
                "для имени \(name)"
            )
        }
    }

    /// Готовый err-ответ для строковых ассертов: версии из констант, без детали.
    private static func errResponseText(code: String) -> String {
        "err \(helperProtocolVersion) \(helperBuildNumber) \(code)\n"
    }

    /// Готовый ok-ответ для строковых ассертов: версии из констант + payload.
    private static func okResponseText(dump: String) -> String {
        "ok \(helperProtocolVersion) \(helperBuildNumber)\n\(dump)"
    }

    // MARK: - up/down → ok без payload

    func testUpAndDownHappyPathReturnOkWithoutPayloadAndReachExecutor() async throws {
        let store = makeConfigStore(names: ["kvmka-ai"])
        let tunnelExecutor = StubTunnelExecutor()
        try await startServer(executor: StubExecutor(), configStore: store, tunnelExecutor: tunnelExecutor)

        for request in [encode(.up("kvmka-ai")), encode(.down("kvmka-ai"))] {
            let exchange = try performExchange(request)
            let response = try XCTUnwrap(
                decode(response: exchange.response),
                "успешная операция должна отвечать ok, а не разрывом"
            )
            XCTAssertEqual(
                response,
                .ok(protocolVersion: helperProtocolVersion, build: helperBuildNumber, dump: ""),
                "успех up/down — ok без payload, версии в заголовке"
            )
        }
        XCTAssertEqual(
            tunnelExecutor.calls,
            [TunnelCall(command: "up", name: "kvmka-ai"), TunnelCall(command: "down", name: "kvmka-ai")],
            "команда и имя должны дойти до исполнителя в исходном виде"
        )
    }

    func testUpDownWithInvalidNameReturnsTunnelNotFoundAndSkipsExecutor() async throws {
        // Хорошей формы имя без конфига, путь-инъекция, пробел, пустое имя,
        // отсутствующий аргумент — всё не проходит валидацию стора.
        let bogusRequests = [
            "up nosuch\n",
            "down nosuch\n",
            "up ../etc/passwd\n",
            "up etc/wireguard/work\n",
            "up bad name\n",
            "up шфта\n",
            "up\n",
            "down\n",
        ]
        let store = makeConfigStore(names: ["kvmka-ai"])
        let tunnelExecutor = StubTunnelExecutor()
        try await startServer(executor: StubExecutor(), configStore: store, tunnelExecutor: tunnelExecutor)

        for request in bogusRequests {
            let exchange = try performExchange(request)
            let response = try XCTUnwrap(
                decode(response: exchange.response),
                "невалидное имя должно давать err-ответ, а не разрыв: \(request)"
            )
            XCTAssertEqual(
                response,
                .err(protocolVersion: helperProtocolVersion, build: helperBuildNumber, code: .tunnelNotFound, detail: nil),
                "для запроса \(request)"
            )
        }
        XCTAssertTrue(tunnelExecutor.calls.isEmpty, "невалидное имя не должно доходить до wg-quick")
    }

    // MARK: - ошибки исполнителя up/down → err только с кодом

    func testTunnelExecutorErrorMapsToErrCodeWithoutDetail() async throws {
        let cases: [(thrown: Error, expectedCode: HelperResponseCode)] = [
            (WGQuickExecutorError.quickMissing, .quickMissing),
            (WGQuickExecutorError.timedOut, .wgFailed),
            (WGQuickExecutorError.failed("wg-quick echo: PrivateKey = SECRETPSK\nwg: invalid config"), .wgFailed),
            // Default-ветка: чужая ошибка (не WGQuickExecutorError) — лог в
            // stderr демона + err wg-failed без детали, как и типизированные.
            (NSError(domain: "HelperDaemonTests", code: 42), .wgFailed),
        ]
        let store = makeConfigStore(names: ["kvmka-ai"])
        let tunnelExecutor = StubTunnelExecutor()
        try await startServer(executor: StubExecutor(), configStore: store, tunnelExecutor: tunnelExecutor)

        for testCase in cases {
            tunnelExecutor.configure(error: testCase.thrown)
            let exchange = try performExchange(encode(.up("kvmka-ai")))
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
                    detail: nil
                ),
                "для брошенной ошибки \(testCase.thrown) — err без детали"
            )
            // Fail-closed, как DumpSanitizer: stderr-хвост wg-quick (эхо
            // команд, цитаты строк конфига) не покидает демон даже по err.
            XCTAssertFalse(
                exchange.response.contains("SECRETPSK"),
                "деталь stderr wg-quick не должна попадать на wire"
            )
        }
    }

    func testClientDisconnectDuringTunnelOperationDoesNotCancelIt() async throws {
        // EOF клиента не отменяет up/down (в отличие от show): SIGTERM посреди
        // up оставил бы полуприменённый туннель — операция обязана дойти до
        // конца, ограничивает её только op-таймаут исполнителя.
        let store = makeConfigStore(names: ["kvmka-ai"])
        let tunnelExecutor = StubTunnelExecutor()
        tunnelExecutor.configure(delay: 0.3)
        try await startServer(executor: StubExecutor(), configStore: store, tunnelExecutor: tunnelExecutor)

        try connectSendAndClose(encode(.up("kvmka-ai")))
        try await waitFor { tunnelExecutor.callCount == 1 }

        XCTAssertEqual(tunnelExecutor.calls, [TunnelCall(command: "up", name: "kvmka-ai")])
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
