import XCTest
@testable import WGStatusBarCore

/// Продакшн-исполнитель wg-quick против короткоживущих стабов. Стаб —
/// исполняемый скрипт с zsh-shebang, резолвимый инъекцией `searchPaths`
/// (стаб-путь — единственный кандидат, по образцу `WGShowExecutorTests`);
/// аргументы НЕ инжектируются — они литеральные `["up"|"down", name]`, как
/// в продакшне, поэтому стаб читает `$1`/`$2`. Отдельно пинируется инъекция
/// PATH (главный продакшн-провал: под launchd у демона нет Homebrew в PATH,
/// и wg-quick гибнет на системном bash 3.2 — юнит-стабы без PATH-теста
/// проходят зелёными при мёртвой фиче).
final class WGQuickExecutorTests: XCTestCase {
    /// Пишет исполняемый стаб-скрипт с zsh-shebang и возвращает его путь.
    private func makeStub(script: String) throws -> String {
        let path = NSTemporaryDirectory().appending("wgstatusbar-wgquick-\(UUID().uuidString)")
        try "#!/bin/zsh\n\(script)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    private func makeExecutor(
        binaryPath: String,
        binaryExists: Bool = true,
        timeout: TimeInterval = 5,
        killGrace: TimeInterval = 2
    ) -> WGQuickExecutor {
        WGQuickExecutor(
            resolver: WGQuickResolver(
                searchPaths: [binaryPath],
                fileExists: { _ in binaryExists }
            ),
            timeout: timeout,
            killGrace: killGrace
        )
    }

    // MARK: - happy path и литеральные аргументы

    func testExitZeroSucceedsPassingLiteralUpAndName() async throws {
        // Стаб пишет свои аргументы в маркер: исполнитель обязан запускать
        // стаб ровно с `up <name>` — литеральные аргументы, как в продакшне.
        let marker = NSTemporaryDirectory().appending("wgstatusbar-wgquick-args-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: marker) }
        let stub = try makeStub(script: "printf '%s %s' \"$1\" \"$2\" > \(marker); exit 0")
        let executor = makeExecutor(binaryPath: stub)

        try await executor.runUp(name: "work-vpn")

        let recorded = try String(contentsOfFile: marker, encoding: .utf8)
        XCTAssertEqual(recorded, "up work-vpn", "стаб получает литеральные [up, name]")
    }

    func testExitZeroSucceedsPassingLiteralDownAndName() async throws {
        let marker = NSTemporaryDirectory().appending("wgstatusbar-wgquick-args-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: marker) }
        let stub = try makeStub(script: "printf '%s %s' \"$1\" \"$2\" > \(marker); exit 0")
        let executor = makeExecutor(binaryPath: stub)

        try await executor.runDown(name: "kvmka-full")

        let recorded = try String(contentsOfFile: marker, encoding: .utf8)
        XCTAssertEqual(recorded, "down kvmka-full", "стаб получает литеральные [down, name]")
    }

    // MARK: - ненулевой exit

    func testNonZeroExitWithStderrCarriesStderrDetail() async throws {
        let stub = try makeStub(script: "echo boom 1>&2; exit 4")
        let executor = makeExecutor(binaryPath: stub)

        do {
            try await executor.runUp(name: "work-vpn")
            XCTFail("ненулевой exit должен давать ошибку")
        } catch {
            XCTAssertEqual(error as? WGQuickExecutorError, .failed("boom"))
        }
    }

    func testNonZeroExitWithoutStderrUsesStatusCodeDetail() async throws {
        let stub = try makeStub(script: "exit 3")
        let executor = makeExecutor(binaryPath: stub)

        do {
            try await executor.runDown(name: "work-vpn")
            XCTFail("ненулевой exit должен давать ошибку")
        } catch {
            XCTAssertEqual(error as? WGQuickExecutorError, .failed("exit status 3"))
        }
    }

    func testLongStderrDetailIsTruncatedToTail() async throws {
        // Деталь `.failed` — хвост stderr (~300 символов): хвост содержит
        // причину сбоя, лимит не тащит мегабайты выхлопа wg-quick в лог демона.
        let stub = try makeStub(script: "printf 'x%.0s' {1..1700} 1>&2; printf 'TAIL' 1>&2; exit 1")
        let executor = makeExecutor(binaryPath: stub)

        do {
            try await executor.runUp(name: "work-vpn")
            XCTFail("ненулевой exit должен давать ошибку")
        } catch {
            guard case .failed(let detail) = error as? WGQuickExecutorError else {
                return XCTFail("ожидался failed, получено: \(error)")
            }
            XCTAssertEqual(detail.count, 300, "деталь обрезана до лимита")
            XCTAssertTrue(detail.hasSuffix("TAIL"), "деталь — хвост stderr, а не начало")
        }
    }

    // MARK: - таймаут

    func testTimeoutThrowsAndKillsHangingProcess() async throws {
        // Стаб записывает свой pid и засыпает: по op-таймауту процесс обязан
        // быть убит, иначе демон держал бы висяк в accept-loop. Таймаут — с
        // запасом поверх старта zsh с замещённым окружением (~0.5 с до первой
        // строки скрипта: без полного env старт шелла небыстрый): TERM обязан
        // приходить уже выполняющему sleep стабу, а не стартующему шеллу.
        let pidFile = NSTemporaryDirectory().appending("wgstatusbar-wgquick-pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: pidFile) }
        let stub = try makeStub(
            script: "printf '%s\\n' $$ > \(pidFile); sleep 30"
        )
        let executor = makeExecutor(binaryPath: stub, timeout: 1.5)

        do {
            try await executor.runUp(name: "work-vpn")
            XCTFail("зависший процесс должен падать по таймауту")
        } catch {
            XCTAssertEqual(error as? WGQuickExecutorError, .timedOut)
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
        // Стаб игнорирует SIGTERM: через killGrace следует SIGKILL — иначе
        // TERM-игнорирующий wg-quick подвешивал бы accept-loop демона.
        let pidFile = NSTemporaryDirectory().appending("wgstatusbar-wgquick-termtrap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: pidFile) }
        let stub = try makeStub(
            script: "trap '' TERM; printf '%s\\n' $$ > \(pidFile); sleep 30"
        )
        let executor = makeExecutor(binaryPath: stub, timeout: 1.5, killGrace: 0.5)

        do {
            try await executor.runDown(name: "work-vpn")
            XCTFail("игнорирующий TERM процесс должен погибнуть по таймауту")
        } catch {
            XCTAssertEqual(error as? WGQuickExecutorError, .timedOut)
        }

        let pidData = try String(contentsOfFile: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(pidData), "стаб должен записать свой pid")
        XCTAssertTrue(
            Self.waitUntilProcessDies(pid, within: 3),
            "процесс \(pid) должен быть убит SIGKILL после игнорирования TERM"
        )
    }

    // MARK: - отмена задачи

    func testTaskCancellationThrowsCancellationErrorAndKillsChild() async throws {
        // Отмена задачи (shutdown демона — единственный отменяющий туннельные
        // операции: EOF клиента её не даёт) обязана убить ребёнка и бросить
        // CancellationError, а не висеть до op-таймаута. Зеркалит тест
        // отмены WGShowExecutor на проводке исполнителя wg-quick.
        let pidFile = NSTemporaryDirectory().appending("wgstatusbar-wgquick-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: pidFile) }
        let stub = try makeStub(script: "printf '%s\\n' $$ > \(pidFile); sleep 30")
        let executor = makeExecutor(binaryPath: stub, timeout: 30)

        let task = Task.detached(priority: .medium) {
            try await executor.runUp(name: "work-vpn")
        }

        // Замещённое окружение (PATH) стартует zsh-стаб медленнее (~0.5 c до
        // первой строки) — отменяем строго после записи pid, а не по сну.
        let pid = try Self.waitForPidFile(pidFile, within: 5)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("отменённая задача должна бросать")
        } catch {
            XCTAssertTrue(error is CancellationError, "ожидалась CancellationError, получено: \(error)")
        }

        XCTAssertTrue(
            Self.waitUntilProcessDies(pid, within: 3),
            "процесс \(pid) должен быть убит по отмене задачи"
        )
    }

    /// Ждёт pid-файл стаба и возвращает записанный pid (стаб с замещённым
    /// окружением стартует небыстро — слепой сон вместо ожидания флейчит).
    private static func waitForPidFile(_ path: String, within seconds: TimeInterval) throws -> pid_t {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let data = try? String(contentsOfFile: path, encoding: .utf8) {
                let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
                if let pid = Int32(trimmed), pid > 0 {
                    return pid
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw NSError(
            domain: "WGQuickExecutorTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "стаб не записал pid в \(path) за \(seconds) с"]
        )
    }

    // MARK: - резолв

    func testResolverMissThrowsQuickMissingWithoutLaunchingProcess() async throws {
        // Промах резолвера обязан падать до запуска процесса: стаб трогал бы
        // файл-маркер, если бы его всё же запустили.
        let marker = NSTemporaryDirectory().appending("wgstatusbar-wgquick-miss-\(UUID().uuidString)")
        let stub = try makeStub(script: "touch \(marker); exit 0")
        let executor = makeExecutor(binaryPath: stub, binaryExists: false)

        do {
            try await executor.runUp(name: "work-vpn")
            XCTFail("промах резолвера должен давать quickMissing")
        } catch {
            XCTAssertEqual(error as? WGQuickExecutorError, .quickMissing)
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker),
            "процесс не должен запускаться без резолва бинаря"
        )
    }

    // MARK: - инъекция PATH

    func testChildPathPutsResolverDirectoriesBeforeSystemOnes() {
        // Продакшн-инвариант PATH: директории резолвера впереди системных
        // (brew bash ≥ 4 и `wg` обязаны выигрывать у /usr/bin), системный
        // хвост присутствует, дублей нет.
        let path = WGQuickExecutor.childPath(
            resolverDirectories: wgQuickBinarySearchPaths.map {
                URL(fileURLWithPath: $0).deletingLastPathComponent().path
            }
        )
        XCTAssertEqual(
            path,
            "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "продакшн-PATH ребёнка wg-quick — директории резолвера + системный хвост без дублей"
        )

        let entries = path.split(separator: ":").map(String.init)
        XCTAssertEqual(Set(entries).count, entries.count, "дубликатов путей быть не должно")
        for brew in ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"] {
            XCTAssertLessThan(
                entries.firstIndex(of: brew)!,
                entries.firstIndex(of: "/usr/bin")!,
                "\(brew) обязан идти впереди системных путей"
            )
        }
    }

    func testExecutorInjectsResolverDirectoryAheadOfSystemInChildPATH() async throws {
        // Регрессия главного продакшн-провала: ребёнок обязан получить PATH
        // от исполнителя (директория стаба впереди системных), а не наследовать
        // окружение демона — без инъекции юнит-стабы зелёные, а под launchd
        // wg-quick гибнет на системном bash 3.2 / отсутствии brew в PATH.
        let stubDir = NSTemporaryDirectory().appending("wgstatusbar-wgquick-pathdir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: stubDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: stubDir) }
        let stubPath = stubDir + "/wg-quick"
        let pathFile = stubDir + "/path.txt"
        let stub = FileManager.default.createFile(
            atPath: stubPath,
            contents: Data("#!/bin/zsh\nprintf '%s' \"$PATH\" > \(pathFile)\nexit 0\n".utf8)
        )
        XCTAssertTrue(stub, "стаб обязан быть создан")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubPath)
        let executor = makeExecutor(binaryPath: stubPath)

        try await executor.runUp(name: "work-vpn")

        let childPath = try String(contentsOfFile: pathFile, encoding: .utf8)
        let entries = childPath.split(separator: ":").map(String.init)
        XCTAssertEqual(entries.first, stubDir, "директория резолва обязана быть первой в PATH ребёнка: <\(childPath)>")
        XCTAssertTrue(entries.contains("/usr/bin"), "системные пути обязаны остаться в PATH ребёнка: <\(childPath)>")
        let stubIndex = entries.firstIndex(of: stubDir)
        let systemIndex = entries.firstIndex(of: "/usr/bin")
        if let stubIndex, let systemIndex {
            XCTAssertLessThan(stubIndex, systemIndex, "директория wg-quick обязана идти впереди системных путей")
        }
    }

    /// Поллит `kill(pid, 0)` до ESRCH: зомби считается живым, пока статус
    /// не собран `waitUntilExit` исполнителя — к моменту возврата runUp
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
}
