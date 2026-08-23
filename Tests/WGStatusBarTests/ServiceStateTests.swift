import XCTest
@testable import WGStatusBarCore

/// Состояние сервиса из фактов: табличные тесты чистой функции
/// `ServiceState.derive` и модель — probe сокета выбирает раннера на каждом
/// refresh, состояние публикуется и обновляется между тиками (tmp-сокет,
/// реальный `DaemonServer` со стабом исполнителя; реального wg и root нет,
/// процессы не спавнятся).
final class ServiceStateTests: XCTestCase {
    private var socketPaths: [String] = []
    private var serverTask: Task<Void, Error>?

    override func tearDown() {
        // Отмена будит accept-цикл фиктивным соединением; чистим остаток
        // сокет-файлов на случай гибели задачи сервера.
        serverTask?.cancel()
        for path in socketPaths {
            try? FileManager.default.removeItem(atPath: path)
        }
        socketPaths.removeAll()
        serverTask = nil
        super.tearDown()
    }

    // MARK: - Фикстуры

    // sun_path вмещает ~103 байта — короткий /tmp-путь с усечённым UUID.
    private func makeSocketPath() -> String {
        let path = "/tmp/wgstatusbar-servicestatetests-"
            + UUID().uuidString.prefix(8)
            + ".sock"
        socketPaths.append(path)
        return path
    }

    /// Мутабельный флаг probe сокета: refresh читает его на main, тест крутит.
    private final class SocketFlag {
        private let lock = NSLock()
        private var storage = false

        var isPresent: Bool {
            get { lock.withLock { storage } }
            set { lock.withLock { storage = newValue } }
        }
    }

    /// Стаб фолбэк-раннера (сокета нет): дамп с `utun3`.
    private final class StubFallbackRunner: WGShowCommandRunning {
        func runDump() async throws -> String {
            "utun3\t(none)\tiface-pub-key=\t(none)\t(none)\n"
        }
    }

    /// Стаб исполнителя демона: дамп с `utun7` — по имени интерфейса видно,
    /// какой раннер отдал данные тику.
    private final class StubDaemonExecutor: WGShowExecuting {
        func runDump() async throws -> String {
            "utun7\t(none)\tiface-pub-key=\t(none)\t(none)\n"
        }
    }

    private final class IdentityNamer: WireGuardTunnelNaming {
        func displayName(for interfaceName: String) -> String { interfaceName }
        func rescan() {}
    }

    private func stubError(_ operation: String) -> NSError {
        NSError(
            domain: "ServiceStateTests",
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: errno \(errno)"]
        )
    }

    /// Прокручивает main run loop, пока условие не станет true (апдейты
    /// модели приезжают на MainActor; async-тест сам на main не живёт).
    private func waitUntil(_ condition: @escaping () -> Bool, _ message: String, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            await MainActor.run {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
        }
        XCTAssertTrue(condition(), message)
    }

    /// Поднимает `DaemonServer` и ждёт настоящего listen-состояния: файл сокета
    /// появляется на bind — раньше listen, и connect в этом окне ловит
    /// ECONNREFUSED (флейк).
    private func startServer(socketPath: String) async throws {
        let server = DaemonServer(executor: StubDaemonExecutor(), socketPath: socketPath)
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

    /// Сокет-файл без слушателя: bind без listen — connect ловит ECONNREFUSED
    /// (демон убит, файл остался).
    private func makeStaleSocketFile(path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw stubError("socket") }
        defer { close(fd) }
        // Darwin.bind: в тест-таргете голый `bind` резолвится в NSObject-метод
        // Cocoa bindings.
        let bound = withUnixSocketAddress(path: path) { address, length in
            Darwin.bind(fd, address, length)
        }
        guard bound == 0 else { throw stubError("bind") }
    }

    // MARK: - Чистая функция: вывод состояния из фактов

    func testDeriveServiceStateFromFactsTable() {
        let cases: [(name: String, socketFileExists: Bool, outcome: Result<String, StatusFailure>, expected: ServiceState)] = [
            // Сокета нет — исход тика принадлежит фолбэк-раннеру, не демону:
            // любое завершение → absent.
            ("нет сокета + успех фолбэка", false, .success("dump"), .absent),
            ("нет сокета + wg-missing фолбэка", false, .failure(.wgMissing), .absent),
            ("нет сокета + таймаут фолбэка", false, .failure(.commandTimeout), .absent),
            ("нет сокета + сбой фолбэка", false, .failure(.generic("boom")), .absent),
            // Живой сокет: ok-ответ.
            ("ok-ответ текущих версий", true, .success("dump"), .installed),
            // Канал не отвечает: коннект отклонён, тишина до дедлайна, мусор
            // или мгновенный EOF.
            ("коннект отклонён", true, .failure(.connectionRefused), .broken),
            ("тишина до клиентского дедлайна", true, .failure(.commandTimeout), .broken),
            ("декод-провал или мгновенный EOF", true, .failure(.badResponse), .broken),
            // daemonOutdated сворачивает оба факта заголовка — чужой протокол
            // и старый build, включая err-ответы (разбор заголовка —
            // SocketWGShowRunner, покрывается его тестами).
            ("чужой протокол или старый build (ok и err)", true, .failure(.daemonOutdated), .outdated),
            // err с валидным заголовком текущей версии: демон жив и актуален,
            // проблема в wg, не в сервисе — на состояние сервиса не влияет.
            ("wg-missing", true, .failure(.wgMissing), .installed),
            ("wg-failed с деталью", true, .failure(.generic("wg exited with status 3")), .installed),
        ]

        for testCase in cases {
            XCTAssertEqual(
                ServiceState.derive(socketFileExists: testCase.socketFileExists, outcome: testCase.outcome),
                testCase.expected,
                testCase.name
            )
        }
    }

    // MARK: - Модель: probe сокета, публикация и обновление состояния

    /// Три тика: без сокета (фолбэк-раннер, absent) → живой демон на tmp-сокете
    /// (сокет-раннер, installed) → демон убит при живом файле (broken).
    func testModelPublishesServiceStateAndUpdatesBetweenTicks() async throws {
        let socketPath = makeSocketPath()
        let socketFlag = SocketFlag()
        let model = WireGuardStatusModel(
            commandRunner: StubFallbackRunner(),
            tunnelNamer: IdentityNamer(),
            socketExists: { socketFlag.isPresent },
            socketPath: socketPath
        )

        var published: [ServiceState] = []
        let cancellable = model.$serviceState.sink { published.append($0) }
        defer { cancellable.cancel() }

        // Тик 1: сокета нет → инжектированный фолбэк-раннер, состояние absent.
        model.refresh()
        await waitUntil(
            { !model.isLoading && model.interfaces.count == 1 },
            "первый тик (без сокета) должен завершиться"
        )
        XCTAssertEqual(model.serviceState, .absent)
        XCTAssertEqual(model.interfaces[0].name, "utun3", "без сокета дамп берёт инжектированный раннер")

        // Тик 2: демон поднялся → сокет-раннер, состояние installed.
        try await startServer(socketPath: socketPath)
        socketFlag.isPresent = true
        model.refresh()
        await waitUntil({ model.serviceState == .installed }, "тик с живым демоном должен дать installed")
        XCTAssertEqual(model.interfaces[0].name, "utun7", "живой сокет переключает refresh на SocketWGShowRunner")
        XCTAssertNil(model.lastFailure)

        // Тик 3: демон умер, файл остался → коннект отклонён, состояние broken.
        serverTask?.cancel()
        // Завершение задачи сервера гарантирует, что его defer уже снял файл
        // сокета — иначе он гонкой удалит наш stale-файл.
        _ = try? await serverTask?.value
        try makeStaleSocketFile(path: socketPath)
        model.refresh()
        await waitUntil({ model.serviceState == .broken }, "тик с мёртвым демоном при живом файле должен дать broken")
        XCTAssertEqual(model.lastFailure, .connectionRefused)

        // Состояние публиковалось и менялось между тиками: absent → installed → broken.
        XCTAssertEqual(
            Array(published.suffix(3)),
            [.absent, .installed, .broken],
            "-serviceState должен публиковать переходы между тиками"
        )
    }

    /// Probe сокета проверяется на каждом тике: демон появился между тиками —
    /// следующий тик уходит через сокет без пересоздания модели.
    func testModelPicksUpDaemonAppearingBetweenTicks() async throws {
        let socketPath = makeSocketPath()
        let socketFlag = SocketFlag()
        let model = WireGuardStatusModel(
            commandRunner: StubFallbackRunner(),
            tunnelNamer: IdentityNamer(),
            socketExists: { socketFlag.isPresent },
            socketPath: socketPath
        )

        model.refresh()
        await waitUntil({ !model.isLoading && model.interfaces.count == 1 }, "тик без сокета должен завершиться")
        XCTAssertEqual(model.interfaces[0].name, "utun3")

        try await startServer(socketPath: socketPath)
        socketFlag.isPresent = true
        model.refresh()
        await waitUntil(
            { !model.isLoading && model.serviceState == .installed && model.interfaces.count == 1 },
            "тик с живым демоном должен завершиться"
        )
        XCTAssertEqual(model.interfaces[0].name, "utun7", "тот же экземпляр модели должен переключиться на сокет-раннер")
    }
}
