import XCTest
@testable import WGStatusBarCore

/// Клиент маскированного просмотра конфига: round-trip против реального
/// `DaemonServer` на tmp-сокете (фейковый FS ридера вместо настоящих конфигов)
/// и сырые слушатели-заглушки для сценариев, которые живой сервер произвести не
/// может (старый build, мусорный конверт, разросшийся ответ). Синтетическая
/// канарейка секрета живёт только в значениях назначений PrivateKey/
/// PresharedKey — ассерты доказывают, что она не пересекает границу демона
/// (сырой ответ, разобранный документ, ошибки, захваченный stderr), при том
/// что комментарии/хуки/неизвестные директивы остаются видимыми by design.
/// Реальных конфигов, wg и root здесь нет.
final class ConfigSocketTests: XCTestCase {
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
        let path = "/tmp/wgstatusbar-configsockettests-"
            + UUID().uuidString.prefix(8)
            + ".sock"
        socketPaths.append(path)
        return path
    }

    private func stubError(_ operation: String, _ errno: Int32) -> NSError {
        NSError(
            domain: "ConfigSocketTests",
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: errno \(errno)"]
        )
    }

    // MARK: - Фикстуры

    /// Псевдокаталог конфигов ридера (файлы — по точным путям, листинг стора
    /// этим тестам не нужен).
    private static let configsDirectory = "/tmp/wgstatusbar-configsockettests-configs"

    private func configFilePath(_ name: String) -> String {
        Self.configsDirectory + "/" + name + ".conf"
    }

    /// Фейковый FS ридера: содержимое и исходы открытия по точным путям.
    /// Открытие всегда даёт свежий дескриптор (как реальный open(2)) —
    /// повторный запрос читает тот же файл заново, а не EOF использованного
    /// дескриптора.
    private final class FakeReaderFileSystem: TunnelConfigReaderFileSystem {
        var contents: [String: String] = [:]
        var outcomes: [String: TunnelConfigOpenOutcome] = [:]

        func openFileNoFollow(atPath path: String) -> TunnelConfigOpenOutcome {
            if let text = contents[path] {
                return .opened(FakeReaderFileHandle(content: Array(text.utf8)))
            }
            return outcomes[path] ?? .notFound
        }
    }

    /// Фейковый дескриптор: содержимое целиком одним чтением.
    private final class FakeReaderFileHandle: TunnelConfigReaderFileHandle {
        private let content: [UInt8]
        private var offset = 0

        init(content: [UInt8]) {
            self.content = content
        }

        var isRegularFile: Bool { true }

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

    /// Заглушка исполнителя `show` — config-тесты его не трогают.
    private final class StubShowExecutor: WGShowExecuting {
        func runDump() async throws -> String { "" }
    }

    /// Конфиг с канарейкой только в значениях назначений ключей: остальной
    /// текст — свои сентинелы, чья видимость проверяется отдельно (они и
    /// должны остаться в ответе).
    private var secretConfig: String {
        "[Interface]\n"
            + "PrivateKey = \(configSecretCanary)\n"
            + "ListenPort = 51820\n"
            + "# комментарий: comment-sentinel остаётся\n"
            + "[Peer]\n"
            + "PublicKey = pub-key-1\n"
            + "PresharedKey = \(configPresharedCanary)\n"
            + "AllowedIPs = 10.0.0.0/24\n"
            + "PostUp = echo hook-sentinel\n"
            + "UnknownDirective = unknown-sentinel\n"
    }

    private func makeServer(readerFS: FakeReaderFileSystem) throws -> String {
        let socketPath = makeSocketPath()
        let server = DaemonServer(
            executor: StubShowExecutor(),
            socketPath: socketPath,
            configReader: TunnelConfigReader(
                searchPaths: [Self.configsDirectory],
                fileSystem: readerFS
            )
        )
        serverTask = Task.detached { try await server.run() }
        try waitUntilListening(socketPath: socketPath)
        return socketPath
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

    // MARK: - Сырой сокет-клиент (POSIX, без клиента приложения)

    private func connectToServer(socketPath: String) throws -> Int32 {
        var lastErrno = ECONNREFUSED
        for _ in 0..<100 {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw stubError("socket", errno) }
            let connected = withUnixSocketAddress(path: socketPath) { address, length in
                connect(fd, address, length)
            }
            if connected == 0 { return fd }
            lastErrno = errno
            close(fd)
            if lastErrno != ECONNREFUSED { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw stubError("connect", lastErrno)
    }

    private func sendAll(_ fd: Int32, _ text: String) throws {
        let bytes = Array(text.utf8)
        let written = bytes.withUnsafeBufferPointer { buffer in
            write(fd, buffer.baseAddress, buffer.count)
        }
        guard written == bytes.count else { throw stubError("write", errno) }
    }

    private func readToEOF(_ fd: Int32, timeout: TimeInterval = 5) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var data: [UInt8] = []
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw stubError("read timeout", ETIMEDOUT) }
            var pollDescriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollDescriptor, 1, Int32(remaining * 1000))
            guard ready > 0 else { throw stubError("poll", errno) }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let received = chunk.withUnsafeMutableBytes { raw in
                recv(fd, raw.baseAddress, raw.count, 0)
            }
            guard received > 0 else { break }
            data.append(contentsOf: chunk[0..<received])
        }
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// Полный обмен сырым сокетом: connect → send → чтение до EOF.
    @discardableResult
    private func performRawExchange(socketPath: String, request: String) throws -> String {
        let fd = try connectToServer(socketPath: socketPath)
        defer { close(fd) }
        try sendAll(fd, request)
        return try readToEOF(fd)
    }

    /// Слушатель-заглушка ровно на одно соединение (по образцу
    /// SocketTunnelClientTests): вычитывает запрос и отвечает фиксированным
    /// текстом (`nil` — мгновенный EOF).
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

    /// Слушатель, который принимает соединение и молчит: клиент обязан уйти по
    /// собственному дедлайну.
    private func serveSilentConnection(path: String) throws {
        try? FileManager.default.removeItem(atPath: path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw stubError("socket", errno) }
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
        Thread.detachNewThread {
            defer {
                close(fd)
                try? FileManager.default.removeItem(atPath: path)
            }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            Self.drainRequestLine(fd: client)
            Thread.sleep(forTimeInterval: 3)  // тишина дольше дедлайна клиента
            close(client)
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

    /// Сокет-файл без слушателя: bind и close без listen.
    private func makeStaleSocketFile(path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw stubError("socket", errno) }
        defer { close(fd) }
        let bound = withUnixSocketAddress(path: path) { address, length in
            Darwin.bind(fd, address, length)
        }
        guard bound == 0 else { throw stubError("bind", errno) }
    }

    /// Пишущий заглушечный поток ответов кусками со счётчиком записанных байт:
    /// успех записи после ухода клиента — EPIPE (SIGPIPE подавлен), и по
    /// счётчику видно, прочитал ли клиент ответ целиком или оборвал по лимиту.
    private final class ChunkedResponseWriter {
        private let lock = NSLock()
        private var writtenStorage = 0

        var writtenBytes: Int { lock.withLock { writtenStorage } }

        private func record(_ count: Int) {
            lock.withLock { writtenStorage += count }
        }

        /// Заголовок + `payloadBytes` байт 'A' кусками по `chunkSize`.
        func writeHeaderAndPayload(to fd: Int32, header: String, payloadBytes: Int, chunkSize: Int) {
            var headerLeft = Array(header.utf8)
            while !headerLeft.isEmpty {
                let written = headerLeft.withUnsafeBufferPointer { buffer in
                    write(fd, buffer.baseAddress, buffer.count)
                }
                if written <= 0 { return }
                record(written)
                headerLeft.removeFirst(Int(written))
            }
            var chunk = [UInt8](repeating: UInt8(ascii: "A"), count: chunkSize)
            var sent = 0
            while sent < payloadBytes {
                let wanted = min(chunkSize, payloadBytes - sent)
                let written = chunk.withUnsafeBufferPointer { buffer in
                    write(fd, buffer.baseAddress, wanted)
                }
                if written <= 0 { return }
                record(written)
                sent += Int(written)
            }
        }
    }

    /// Слушатель с чанковым писателем: отвечает заголовком ok и `payloadBytes`
    /// байт мусора — сильно за клиентским лимитом recv.
    private func serveChunkedOverlimitResponse(path: String, payloadBytes: Int) throws -> ChunkedResponseWriter {
        try? FileManager.default.removeItem(atPath: path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw stubError("socket", errno) }
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
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

        let writer = ChunkedResponseWriter()
        Thread.detachNewThread {
            defer {
                close(fd)
                try? FileManager.default.removeItem(atPath: path)
            }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            var noSigPipe: Int32 = 1
            _ = setsockopt(
                client,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSigPipe,
                socklen_t(MemoryLayout<Int32>.size)
            )
            defer { close(client) }
            Self.drainRequestLine(fd: client)
            writer.writeHeaderAndPayload(
                to: client,
                header: "ok \(helperProtocolVersion) \(helperBuildNumber)\n",
                payloadBytes: payloadBytes,
                chunkSize: 16 * 1024
            )
        }
        return writer
    }

    /// Перенаправляет stderr процесса в tmp-файл на время `body`: сервер демона
    /// живёт в том же процессе, его логи уходят в stderr теста. Возвращает
    /// результат body и захваченный текст.
    private func withCapturedStderr<T>(_ body: () throws -> T) rethrows -> (value: T, stderr: String) {
        let path = NSTemporaryDirectory()
            .appending("wgstatusbar-configsockettests-stderr-\(UUID().uuidString).log")
        let savedFD = dup(STDERR_FILENO)
        precondition(savedFD >= 0, "dup(stderr) не удался")
        precondition(freopen(path, "w", stderr) != nil, "freopen stderr не удался")
        defer {
            fflush(stderr)
            dup2(savedFD, STDERR_FILENO)
            close(savedFD)
        }
        let value = try body()
        fflush(stderr)
        let captured = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(atPath: path)
        return (value, captured)
    }

    private func assertThrowsConfigFetchError(
        _ expected: ConfigFetchError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("операция должна была бросить \(expected)", file: file, line: line)
        } catch let error as ConfigFetchError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("ожидалась ConfigFetchError \(expected), брошено \(error)", file: file, line: line)
        }
    }

    // MARK: - Round-trip с реальным DaemonServer

    func testConfigRoundTripReturnsSanitizedDocumentAndCanaryNeverCrossesDaemon() async throws {
        let readerFS = FakeReaderFileSystem()
        readerFS.contents[configFilePath("work")] = secretConfig
        let socketPath = try makeServer(readerFS: readerFS)

        // Сырой обмен под захватом stderr: сервер живёт в этом процессе, его
        // логи — stderr теста; канарейка не должна попасть и туда.
        let captured = try withCapturedStderr {
            try performRawExchange(socketPath: socketPath, request: encode(.config("work")))
        }
        let rawResponse = captured.value

        // Значения назначений ключей спрятаны до отправки: ни private, ни
        // preshared-канарейки в сырых байтах ответа нет.
        XCTAssertFalse(rawResponse.contains(configSecretCanary), "private key не должен попадать в ответ")
        XCTAssertFalse(rawResponse.contains(configPresharedCanary), "preshared key не должен попадать в ответ")
        XCTAssertFalse(
            captured.stderr.contains(configSecretCanary),
            "private key не должен попадать в stderr (лог) демона"
        )
        XCTAssertFalse(
            captured.stderr.contains(configPresharedCanary),
            "preshared key не должен попадать в stderr (лог) демона"
        )

        // Разбор клиентом: точный санированный текст.
        let client = SocketConfigClient(socketPath: socketPath)
        let document = try await client.maskedConfig(named: "work")
        XCTAssertEqual(document.text, sanitizeWGQuickConfig(secretConfig))
        XCTAssertFalse(document.text.contains(configSecretCanary), "разобранный документ без private key")
        XCTAssertFalse(document.text.contains(configPresharedCanary), "разобранный документ без preshared key")
        XCTAssertTrue(document.hasFinalNewline)
        // Документированная видимость: комментарий, хук и неизвестная
        // директива остаются в полном тексте by design (равенство выше уже
        // это доказывает — здесь явные ассерты для диагностики).
        XCTAssertTrue(document.text.contains("comment-sentinel"), "комментарий остаётся видимым")
        XCTAssertTrue(document.text.contains("hook-sentinel"), "хук остаётся видимым")
        XCTAssertTrue(document.text.contains("unknown-sentinel"), "неизвестная директива остаётся видимой")
    }

    func testConfigRoundTripPreservesFinalNewlineStateOfDocument() async throws {
        // Собственный `\n` документа живёт внутри base64: терминатор конверта —
        // транспортное обрамление и не добавляет документу перевод строки.
        let readerFS = FakeReaderFileSystem()
        readerFS.contents[configFilePath("with-newline")] = "[Interface]\nListenPort = 1\n"
        readerFS.contents[configFilePath("no-newline")] = "[Interface]\nListenPort = 2"
        let socketPath = try makeServer(readerFS: readerFS)
        let client = SocketConfigClient(socketPath: socketPath)

        let withNewline = try await client.maskedConfig(named: "with-newline")
        XCTAssertEqual(withNewline.text, "[Interface]\nListenPort = 1\n")
        XCTAssertTrue(withNewline.hasFinalNewline)

        let withoutNewline = try await client.maskedConfig(named: "no-newline")
        XCTAssertEqual(withoutNewline.text, "[Interface]\nListenPort = 2")
        XCTAssertFalse(withoutNewline.hasFinalNewline)
    }

    func testConfigRoundTripsEmptyDocument() async throws {
        // Пустой файл — валидный ok-конверт `b64:\n`: пустой документ отличим
        // от ошибки и от отсутствующего ответа.
        let readerFS = FakeReaderFileSystem()
        readerFS.contents[configFilePath("empty")] = ""
        let socketPath = try makeServer(readerFS: readerFS)

        let document = try await SocketConfigClient(socketPath: socketPath).maskedConfig(named: "empty")
        XCTAssertEqual(document.text, "")
        XCTAssertFalse(document.hasFinalNewline)
    }

    // MARK: - недоступность конфига → .unavailable

    func testConfigFileFailuresMapToUnavailable() async throws {
        let readerFS = FakeReaderFileSystem()
        readerFS.outcomes[configFilePath("symlinked")] = .symlink
        readerFS.outcomes[configFilePath("huge")] = .opened(
            FakeReaderFileHandle(
                content: [UInt8](repeating: 0x61, count: TunnelConfigReader.maxSizeBytes + 1)
            )
        )
        let socketPath = try makeServer(readerFS: readerFS)
        let client = SocketConfigClient(socketPath: socketPath)

        // Файла нет; первый матч — симлинк; сверх лимита — один честный код.
        for name in ["nosuch", "symlinked", "huge"] {
            await assertThrowsConfigFetchError(.unavailable) {
                try await client.maskedConfig(named: name)
            }
        }
    }

    func testConfigInvalidNamesMapToUnavailable() async throws {
        let socketPath = try makeServer(readerFS: FakeReaderFileSystem())
        let client = SocketConfigClient(socketPath: socketPath)

        for name in ["bad name", "../etc/passwd", "abcdefghijklmnop", "штатный"] {
            await assertThrowsConfigFetchError(.unavailable) {
                try await client.maskedConfig(named: name)
            }
        }
    }

    func testConfigErrorsCarryNoContent() {
        // Ошибки вьювера типизированы и без ассоциированных данных: ни текст
        // документа, ни путь не могут пересечь границу вместе с ошибкой.
        let errors: [ConfigFetchError] = [
            .daemonOutdated, .connectionRefused, .timedOut, .badResponse, .unavailable,
        ]
        for error in errors {
            let description = String(describing: error)
            XCTAssertFalse(description.contains(configSecretCanary), "ошибка не несёт канарейку: \(description)")
            XCTAssertFalse(description.contains(".conf"), "ошибка не несёт имя файла: \(description)")
        }
    }

    // MARK: - версии заголовка → daemonOutdated

    func testConfigOldDaemonBuildMapsToDaemonOutdatedNotGenericFailure() async throws {
        // Старый бинарь демона не знает `config`: его ответ — unknown command
        // (err wg-failed) или чужой заголовок. Сверка версий обязана дать
        // «обновить сервис», а не ошибку просмотра или мусор канала.
        let cases = [
            // Старый build в ok-заголовке.
            "ok \(helperProtocolVersion) \(helperBuildNumber - 1)\nb64:QUFBQQ==\n",
            // Старый build в err — реальный ответ старого бинаря на `config`.
            "err \(helperProtocolVersion) \(helperBuildNumber - 1) wg-failed unknown command: config work\n",
            // Чужой протокол в ok.
            "ok \(helperProtocolVersion + 1) \(helperBuildNumber)\nb64:QUFBQQ==\n",
            // Чужой протокол в err — outdated бьёт код ошибки.
            "err \(helperProtocolVersion + 1) \(helperBuildNumber) config-unavailable\n",
        ]
        for response in cases {
            let socketPath = makeSocketPath()
            try serveOneConnection(path: socketPath, response: response)
            await assertThrowsConfigFetchError(.daemonOutdated) {
                try await SocketConfigClient(socketPath: socketPath).maskedConfig(named: "work")
            }
        }
    }

    // MARK: - err-детали и чужие коды

    func testConfigErrDetailOnWireIsIgnored() async throws {
        // Контракт демона — код без детали; если деталь всё-таки пришла,
        // клиент её не показывает (в ошибке и следа быть не должно).
        let socketPath = makeSocketPath()
        try serveOneConnection(
            path: socketPath,
            response: "err \(helperProtocolVersion) \(helperBuildNumber) config-unavailable leaked wire detail\n"
        )
        await assertThrowsConfigFetchError(.unavailable) {
            try await SocketConfigClient(socketPath: socketPath).maskedConfig(named: "work")
        }
    }

    func testConfigForeignErrCodesMapToBadResponse() async throws {
        // Коды show/туннельных операций не отвечают `config`: защитные ветки
        // исчерпывающего switch → мусор канала.
        for code in ["wg-missing", "wg-failed", "wg-quick-missing", "tunnel-not-found"] {
            let socketPath = makeSocketPath()
            try serveOneConnection(
                path: socketPath,
                response: "err \(helperProtocolVersion) \(helperBuildNumber) \(code)\n"
            )
            await assertThrowsConfigFetchError(.badResponse) {
                try await SocketConfigClient(socketPath: socketPath).maskedConfig(named: "work")
            }
        }
    }

    // MARK: - битый конверт → badResponse

    func testConfigBadEnvelopePayloadsMapToBadResponse() async throws {
        let payloads = [
            "",  // конверта нет — пустой payload не «пустой документ»
            "QUFBQUFB\n",  // base64 без тега
            "b64:AAAA\nextra\n",  // вторая строка payload
            "b64:AA A\n",  // пробел — не алфавит base64
            "b64:AAA\n",  // длина не кратна 4
            "b64:====\n",  // больше двух =
        ]
        for payload in payloads {
            let socketPath = makeSocketPath()
            try serveOneConnection(
                path: socketPath,
                response: "ok \(helperProtocolVersion) \(helperBuildNumber)\n\(payload)"
            )
            await assertThrowsConfigFetchError(.badResponse) {
                try await SocketConfigClient(socketPath: socketPath).maskedConfig(named: "work")
            }
        }
    }

    // MARK: - лимит байт ответа на этапе recv

    func testConfigOverLimitPeerIsRejectedBeforeFurtherAccumulation() async throws {
        // Пир, льющий сильно за лимит, отбрасывается по ходу recv: клиент
        // перестаёт читать и закрывает соединение, писатель получает EPIPE и
        // недописывает хвост — накопление не доходит до полного объёма.
        let payloadBytes = SocketConfigClient.maxResponseBytes + 512 * 1024
        let socketPath = makeSocketPath()
        let writer = try serveChunkedOverlimitResponse(path: socketPath, payloadBytes: payloadBytes)

        await assertThrowsConfigFetchError(.badResponse) {
            try await SocketConfigClient(socketPath: socketPath).maskedConfig(named: "work")
        }

        // Писатель обязан увидеть обрыв (EPIPE), не дописав подготовленный
        // объём: клиент не вычитал и не накопил весь ответ. Ждём, пока счётчик
        // записанного стабилизируется (писатель упёрся в EPIPE) — с потолком
        // на случай, когда он завис бы в блокированной записи.
        let totalBytes = "ok \(helperProtocolVersion) \(helperBuildNumber)\n".utf8.count + payloadBytes
        var lastWritten = -1
        var stableSince = Date()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let written = writer.writtenBytes
            if written >= totalBytes { break }
            if written != lastWritten {
                lastWritten = written
                stableSince = Date()
            } else if Date().timeIntervalSince(stableSince) > 0.3 {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertLessThan(
            writer.writtenBytes,
            totalBytes,
            "клиент должен оборвать чтение по лимиту, не вычитывая весь поток"
        )
    }

    func testConfigResponseLimitFitsMaximumLegitimateEnvelope() {
        // Лимит recv выведен из максимума легитимного конверта МАСКИРОВАННОГО
        // документа: заголовок версий + тег + base64 текста размера
        // `maxSanitizedConfigBytes` (санитизация удлиняет raw-файл — лимит
        // ридера ограничивает только вход) + терминатор, с запасом только на
        // рост заголовка (64 байта против текущих ~8).
        let headerBytes = "ok \(helperProtocolVersion) \(helperBuildNumber)\n".utf8.count
        let maxBase64Bytes = (maxSanitizedConfigBytes + 2) / 3 * 4
        let maxLegitimateBytes = headerBytes + ConfigEnvelope.tag.utf8.count + maxBase64Bytes + 1
        XCTAssertGreaterThanOrEqual(
            SocketConfigClient.maxResponseBytes,
            maxLegitimateBytes,
            "лимит recv обязан вмещать максимальный легитимный конверт"
        )
        XCTAssertLessThanOrEqual(
            SocketConfigClient.maxResponseBytes - maxLegitimateBytes,
            64,
            "запас лимита — только на рост заголовка, без бездонного буфера"
        )
    }

    /// Файл в пределах лимита ридера, но маскирование удлиняет его за лимит
    /// raw-размера (строки `PrivateKey=x` по 12 байт → 22 байта): легитимный
    /// ответ демона обязан доходить до клиента целиком, а не отвергаться как
    /// мусор канала (регрессия: лимиты, выведенные из raw-лимита ридера).
    func testConfigRoundTripsGrowthHeavyDocumentWithinReaderLimit() async throws {
        let line = "PrivateKey=x\n"
        let lineCount = (TunnelConfigReader.maxSizeBytes - 1024) / line.utf8.count
        let raw = String(repeating: line, count: lineCount)
        XCTAssertLessThanOrEqual(raw.utf8.count, TunnelConfigReader.maxSizeBytes, "файл проходит лимит ридера")
        let masked = sanitizeWGQuickConfig(raw)
        XCTAssertGreaterThan(masked.utf8.count, TunnelConfigReader.maxSizeBytes, "маскирование удлиняет документ за raw-лимит")
        XCTAssertLessThanOrEqual(masked.utf8.count, maxSanitizedConfigBytes, "рост в пределах 2×")

        let readerFS = FakeReaderFileSystem()
        readerFS.contents[configFilePath("growth")] = raw
        let socketPath = try makeServer(readerFS: readerFS)

        let document = try await SocketConfigClient(socketPath: socketPath).maskedConfig(named: "growth")
        XCTAssertEqual(document.text, masked)
        XCTAssertFalse(document.text.contains("PrivateKey=x"), "значения назначений спрятаны")
    }

    /// Кнопка деталей не глушится туннельными операциями — запрос `config`
    /// может встать в последовательную очередь accept-loop за show-тиком и
    /// op-бюджетом; клиентский дедлайн обязан покрывать худший случай
    /// (4.0 + 9.0 = 13.0 с), числа — из констант (по образцу туннельного
    /// инварианта в `SocketTunnelClientTests`).
    func testConfigTimeoutCoversSequentialQueueBehindShowAndTunnelOp() {
        let showBudget = WGShowExecutor.defaultTimeout + 2 * WGShowExecutor.defaultKillGrace
        let opBudget = WGQuickExecutor.defaultOpTimeout + 2 * WGQuickExecutor.defaultKillGrace
        XCTAssertGreaterThan(
            SocketConfigClient.defaultTimeout,
            showBudget + opBudget,
            "config-дедлайн обязан пережить очередь за show-тиком и туннельной операцией"
        )
    }

    // MARK: - недоступность демона и тишина

    func testConnectionRefusedWhenDaemonIsNotListening() async throws {
        let stalePath = makeSocketPath()
        try makeStaleSocketFile(path: stalePath)
        await assertThrowsConfigFetchError(.connectionRefused) {
            try await SocketConfigClient(socketPath: stalePath).maskedConfig(named: "work")
        }

        await assertThrowsConfigFetchError(.connectionRefused) {
            try await SocketConfigClient(
                socketPath: "/tmp/wgstatusbar-configsockettests-missing.sock"
            ).maskedConfig(named: "work")
        }
    }

    func testSilenceUntilClientDeadlineMapsToTimedOut() async throws {
        let socketPath = makeSocketPath()
        try serveSilentConnection(path: socketPath)

        let client = SocketConfigClient(socketPath: socketPath, timeout: 0.4)
        let started = Date()
        await assertThrowsConfigFetchError(.timedOut) {
            try await client.maskedConfig(named: "work")
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed, 0.3, "тишина должна длиться до клиентского дедлайна")
        XCTAssertLessThan(elapsed, 2.0, "ошибка должна прийти по клиентскому дедлайну, а не позже")
    }

    func testGarbageResponseAndInstantEOFMapToBadResponse() async throws {
        let garbagePath = makeSocketPath()
        try serveOneConnection(path: garbagePath, response: "definitely not a protocol header\n")
        await assertThrowsConfigFetchError(.badResponse) {
            try await SocketConfigClient(socketPath: garbagePath).maskedConfig(named: "work")
        }

        let eofPath = makeSocketPath()
        try serveOneConnection(path: eofPath, response: nil)
        await assertThrowsConfigFetchError(.badResponse) {
            try await SocketConfigClient(socketPath: eofPath).maskedConfig(named: "work")
        }
    }
}
