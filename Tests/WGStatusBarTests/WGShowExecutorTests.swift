import XCTest
@testable import WGStatusBarCore

/// Продакшн-исполнитель против короткоживущих стабов `/bin/zsh -f -c ...`
/// (по образцу `ProcessWGShowRunnerTests`): бинарь подменяется резолвером с
/// единственным кандидатом `/bin/zsh`, аргументы и таймаут — инъекцией.
/// Проверяется сырой вывод без санитизации (секреты — забота `DaemonServer`),
/// `wgMissing` без запуска процесса, классификация ненулевого exit, таймаут
/// с убийством процесса, отмена задачи и инвариант таймингов: бюджет
/// исполнителя укладывается в клиентский дедлайн сокет-раннера.
final class WGShowExecutorTests: XCTestCase {
    private func makeExecutor(
        arguments: [String],
        timeout: TimeInterval = 5,
        killGrace: TimeInterval = 2,
        binaryExists: Bool = true
    ) -> WGShowExecutor {
        WGShowExecutor(
            resolver: WGBinaryResolver(
                searchPaths: ["/bin/zsh"],
                fileExists: { _ in binaryExists }
            ),
            arguments: arguments,
            timeout: timeout,
            killGrace: killGrace
        )
    }

    func testReturnsRawStdoutWithoutSanitization() async throws {
        // Стаб-«дамп» с маркером в секретном поле: исполнитель отдаёт вывод
        // как есть — санитизация живёт в сервере, не здесь.
        let dump = "wg0\tSECRETKEY\t51820\toff\t123"
        let executor = makeExecutor(arguments: ["-f", "-c", "printf %s '\(dump)'"])

        let output = try await executor.runDump()

        XCTAssertEqual(output, dump, "исполнитель возвращает сырой вывод байт-в-байт")
    }

    func testResolverMissThrowsWGMissingWithoutLaunchingProcess() async throws {
        // Промах резолвера обязан падать до запуска процесса: стаб трогал бы
        // файл-маркер, если бы его всё же запустили.
        let marker = NSTemporaryDirectory().appending("wgstatusbar-executor-miss-\(UUID().uuidString)")
        let executor = makeExecutor(
            arguments: ["-f", "-c", "touch \(marker)"],
            binaryExists: false
        )

        do {
            _ = try await executor.runDump()
            XCTFail("промах резолвера должен давать wgMissing")
        } catch {
            XCTAssertEqual(error as? WGShowExecutorError, .wgMissing)
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker),
            "процесс не должен запускаться без резолва бинаря"
        )
    }

    func testNonZeroExitWithStderrSurfacesStderrText() async throws {
        let executor = makeExecutor(arguments: ["-f", "-c", "echo boom 1>&2; exit 4"])

        do {
            _ = try await executor.runDump()
            XCTFail("ненулевой exit должен давать ошибку")
        } catch {
            XCTAssertEqual(error as? WGShowExecutorError, .wgFailed("boom"))
        }
    }

    func testNonZeroExitWithoutStderrUsesStatusCodeDetail() async throws {
        let executor = makeExecutor(arguments: ["-f", "-c", "exit 3"])

        do {
            _ = try await executor.runDump()
            XCTFail("ненулевой exit должен давать ошибку")
        } catch {
            XCTAssertEqual(error as? WGShowExecutorError, .wgFailed("exit status 3"))
        }
    }

    func testTimeoutThrowsAndKillsHangingProcess() async throws {
        // Стаб записывает свой pid и засыпает: по таймауту процесс обязан быть
        // убит (kill(pid, 0) → ESRCH), иначе демон держал бы зомби-висяк.
        let pidFile = NSTemporaryDirectory().appending("wgstatusbar-executor-pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: pidFile) }
        let executor = makeExecutor(
            arguments: ["-f", "-c", "printf '%s\\n' $$ > \(pidFile); sleep 30"],
            timeout: 0.3
        )

        do {
            _ = try await executor.runDump()
            XCTFail("зависший процесс должен падать по таймауту")
        } catch {
            XCTAssertEqual(error as? WGShowExecutorError, .timedOut)
        }

        let pidData = try String(contentsOfFile: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(pidData), "стаб должен записать свой pid")
        XCTAssertTrue(
            Self.waitUntilProcessDies(pid, within: 3),
            "процесс \(pid) должен быть убит по таймауту, таймаут живёт в исполнителе"
        )
    }

    func testTimeoutEscalatesToSigkillWhenChildIgnoresTerm() async throws {
        // Стаб игнорирует SIGTERM (`trap '' TERM`): таймаут обязан быть жёстким —
        // через killGrace следует SIGKILL, иначе игнорирующий TERM wg подвешивал
        // бы последовательный accept-loop демона до собственного выхода.
        let pidFile = NSTemporaryDirectory().appending("wgstatusbar-executor-termtrap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: pidFile) }
        let executor = makeExecutor(
            arguments: ["-f", "-c", "trap '' TERM; printf '%s\\n' $$ > \(pidFile); sleep 30"],
            timeout: 0.3,
            killGrace: 0.3
        )

        do {
            _ = try await executor.runDump()
            XCTFail("игнорирующий TERM процесс должен погибнуть по таймауту")
        } catch {
            XCTAssertEqual(error as? WGShowExecutorError, .timedOut)
        }

        let pidData = try String(contentsOfFile: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(pidData), "стаб должен записать свой pid")
        XCTAssertTrue(
            Self.waitUntilProcessDies(pid, within: 3),
            "процесс \(pid) должен быть убит SIGKILL после игнорирования TERM"
        )
    }

    func testProductionWorstCaseBudgetFitsUnderClientDeadline() {
        // Инвариант таймингов: полный бюджет ответа демона (TERM → KILL →
        // отказ от ожидания) меньше клиентского дедлайна с запасом на джиттер
        // планировщика и накладные расходы демона — иначе TERM-игнорирующий wg
        // встречает тишину клиента (commandTimeout → ложное broken) вместо
        // err-ответа демона.
        let worstCase = WGShowExecutor.defaultTimeout + 2 * WGShowExecutor.defaultKillGrace
        XCTAssertLessThanOrEqual(
            worstCase,
            SocketWGShowRunner.defaultTimeout - 0.5,
            "худший случай демона (\(worstCase) c) обязан укладываться в клиентский дедлайн "
                + "(\(SocketWGShowRunner.defaultTimeout) c) с запасом ≥ 0.5 c"
        )
    }

    func testTermIgnoringChildGetsDaemonErrBeforeClientDeadline() async throws {
        // Socket-level регрессия с продакшн-таймингами: стаб wg игнорирует
        // SIGTERM — самый долгий путь исполнителя (TERM в таймаут, KILL ещё
        // через killGrace). Демон обязан успеть ответить `err wg-failed
        // wg timed out` до клиентского дедлайна: клиент, отвалившийся по
        // тишине, показывает commandTimeout и помечает здоровый сервис broken.
        let socketPath = "/tmp/wgstatusbar-executor-budget-"
            + UUID().uuidString.prefix(8)
            + ".sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let executor = WGShowExecutor(
            resolver: WGBinaryResolver(searchPaths: ["/bin/zsh"], fileExists: { _ in true }),
            arguments: ["-f", "-c", "trap '' TERM; sleep 30"]
        )
        let server = DaemonServer(executor: executor, socketPath: socketPath)
        let serverTask = Task.detached { try await server.run() }
        defer { serverTask.cancel() }
        try Self.waitUntilListening(socketPath: socketPath)

        // Дефолты обеих сторон — продакшн: 3 c TERM + 0.5 c grace ×2 против 5 c клиента.
        let runner = SocketWGShowRunner(socketPath: socketPath)

        do {
            _ = try await runner.runDump()
            XCTFail("TERM-игнорирующий стаб должен дать err-ответ демона")
        } catch let failure as StatusFailure {
            XCTAssertEqual(
                failure,
                .generic("wg timed out"),
                "клиент должен получить err-ответ демона до своего дедлайна, а не \(failure)"
            )
        }
    }

    func testTaskCancellationThrowsCancellationErrorAndKillsChild() async throws {
        // Отмена задачи (клиент ушёл по EOF посреди запроса) обязана убить
        // ребёнка и бросить CancellationError, а не висеть до таймаута wg.
        let pidFile = NSTemporaryDirectory().appending("wgstatusbar-executor-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: pidFile) }
        let executor = makeExecutor(
            arguments: ["-f", "-c", "printf '%s\\n' $$ > \(pidFile); sleep 30"],
            timeout: 30
        )
        let task = Task.detached(priority: .medium) {
            try await executor.runDump()
        }

        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("отменённая задача должна бросать")
        } catch {
            XCTAssertTrue(error is CancellationError, "ожидалась CancellationError, получено: \(error)")
        }

        // Броска мало: ребёнок обязан быть убит (kill(pid, 0) → ESRCH), иначе
        // отменённые запросы оставляют демону висячие wg-процессы.
        let pidData = try String(contentsOfFile: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(pidData), "стаб должен записать свой pid")
        XCTAssertTrue(
            Self.waitUntilProcessDies(pid, within: 3),
            "процесс \(pid) должен быть убит по отмене задачи"
        )
    }

    func testCancelBetweenRegisterAndRunKillsLaunchedChild() throws {
        // Точное чередование гонки register → cancel → run: cancel видит
        // pid == 0 и не может сигналить; повторная проверка после запуска
        // обязана убить ребёнка — иначе отмена в окне старта терялась, и wg
        // жил бы до собственного выхода или таймаута вместо отмены.
        // pid берём у самого Process — TERM после killIfCancelled приходит
        // раньше, чем стаб успел бы записать pid-файл.
        let handle = ChildProcessHandle(killGrace: 0.3)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", "sleep 30"]

        XCTAssertTrue(handle.register(process), "отмены ещё не было — регистрация обязана пройти")
        handle.cancel()  // pid == 0: сигнал невозможен, окно гонки

        try process.run()
        handle.killIfCancelled()

        // Без убийства стаб спит 30 с — ждём смерти с дедлайном, не блокируя тест.
        let deathDeadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deathDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertFalse(process.isRunning, "ребёнок должен быть убит после отмены в окне register→run")
        process.waitUntilExit()  // reaping зомби

        let pid = process.processIdentifier
        XCTAssertTrue(
            Self.waitUntilProcessDies(pid, within: 3),
            "процесс \(pid) должен быть мёртв после отмены в окне register→run"
        )
    }

    func testLaunchFailureSurfacesWgFailedWithoutHanging() async throws {
        // run() бросает (бинарь без права исполнения): провал запуска —
        // wgFailed, читатели пайпов не стартуют до успешного run() — не висят
        // на незакрытых write-концах.
        let notExecutable = NSTemporaryDirectory().appending("wgstatusbar-executor-noexec-\(UUID().uuidString)")
        try "not a program".write(toFile: notExecutable, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: notExecutable) }

        let executor = WGShowExecutor(
            resolver: WGBinaryResolver(searchPaths: [notExecutable], fileExists: { _ in true }),
            arguments: ["-f", "-c", "printf hello"],
            timeout: 5
        )

        do {
            _ = try await executor.runDump()
            XCTFail("неисполняемый бинарь должен давать ошибку запуска")
        } catch let error as WGShowExecutorError {
            guard case .wgFailed = error else {
                return XCTFail("ожидался wgFailed, получено: \(error)")
            }
        }
    }

    func testLargeOutputBeyondPipeBufferIsDrained() async throws {
        // 200 KB > буфера пайпа (~64 KiB): без параллельного чтения стаб
        // блокировался бы на записи и падал по таймауту вместо данных.
        let executor = makeExecutor(arguments: ["-f", "-c", "head -c 200000 /dev/zero | tr '\\0' x"])

        let output = try await executor.runDump()

        XCTAssertEqual(output.count, 200_000)
    }

    /// Поллит `kill(pid, 0)` до ESRCH: зомби считается живым, пока статус
    /// не собран `waitUntilExit` исполнителя — к моменту возврата runDump
    /// процесс уже reaped, остаётся дождаться смерти.
    private static func waitUntilProcessDies(_ pid: pid_t, within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if kill(pid, 0) == -1 && errno == ESRCH {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    /// Ждёт настоящего listen-состояния сервера (файл сокета появляется на
    /// bind — раньше listen, connect в этом окне ловит ECONNREFUSED).
    private static func waitUntilListening(socketPath: String, timeout: TimeInterval = 5) throws {
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
}
