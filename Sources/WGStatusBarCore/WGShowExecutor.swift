import Foundation

/// Ошибка исполнителя `wg show all dump`. Сервер демона переводит её в код
/// wire-протокола: `wgMissing` → `err wg-missing`, остальное → `err wg-failed`
/// с деталью (таймаут и ненулевой exit — оба `wg-failed`: других кодов в
/// протоколе нет).
public enum WGShowExecutorError: Error, Equatable {
    /// Резолвер не нашёл бинарь `wg`.
    case wgMissing
    /// wg не завершился за таймаут и убит.
    case timedOut
    /// Прочий сбой запуска: ненулевой exit, ошибка процесса.
    case wgFailed(String)
}

/// Исполнитель команды `wg show all dump` на стороне демона. Возвращает сырой
/// вывод (с секретами): санитизация — единственная ответственность
/// `DaemonServer`, не исполнителя. Инжектится в сервер; таймаут wg —
/// ответственность продакшн-исполнителя, не сервера.
public protocol WGShowExecuting {
    func runDump() async throws -> String
}

/// Общий доступ к запущенному ребёнку для таймаута и отмены задачи: `onCancel`
/// бежит не в задаче исполнителя, запуск — в detached-задаче — доступ из
/// разных потоков под локом. `internal` — для теста гонки register→cancel→run.
internal final class ChildProcessHandle {
    private let lock = NSLock()
    /// Grace эскалации SIGTERM → SIGKILL — тот же, что у таймаута:
    /// игнорирующий TERM ребёнок не должен переживать и отмену.
    private let killGrace: TimeInterval
    private var process: Process?
    private var cancelled = false

    init(killGrace: TimeInterval) {
        self.killGrace = killGrace
    }

    /// Регистрирует процесс перед запуском; `false` — задача уже отменена,
    /// ребёнка запускать нельзя.
    func register(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        self.process = process
        return true
    }

    /// Отмена задачи: убить ребёнка, если он уже жив; kill несуществующему
    /// pid безвреден, гонка с завершением процесса — тоже. Дальше — как в
    /// таймауте: не умерший от TERM добивается SIGKILL'ом через grace.
    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return }
        cancelled = true
        terminateChildLocked()
    }

    /// Повторная проверка после успешного run(): отмена в окне между
    /// register и run() застала pid == 0 и ушла без сигнала — теперь ребёнок
    /// запущен, останавливаем его, иначе он жил бы до собственного выхода
    /// или таймаута вместо отмены.
    func killIfCancelled() {
        lock.lock()
        defer { lock.unlock() }
        guard cancelled else { return }
        terminateChildLocked()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// TERM живому ребёнку + SIGKILL через grace; только под локом. У ещё не
    /// запущенного процесса pid == 0, а kill(0, SIGTERM) шлёт сигнал всей
    /// группе процессов демона — сигнал только настоящему pid ребёнка.
    private func terminateChildLocked() {
        guard let process else { return }
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        kill(pid, SIGTERM)
        scheduleSigkill(process: process, pid: pid)
    }

    /// SIGKILL через grace; проверка `isRunning` сужает гонку переиспользования
    /// pid уже завершившегося процесса.
    private func scheduleSigkill(process: Process, pid: pid_t) {
        let grace = killGrace
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            if process.isRunning {
                kill(pid, SIGKILL)
            }
        }
    }
}

/// Продакшн-исполнитель демона: резолвит бинарь `wg` через `WGBinaryResolver`
/// (промах → `wgMissing`, процесс не запускается; промах не кэшируется —
/// `brew install wireguard-tools` подхватится следующим запросом), запускает
/// его с литеральными аргументами и жёстким дедлайном: TERM в `timeout`,
/// KILL ещё через `killGrace`, дальше ожидание ограничено — зависший ребёнок
/// не подвешивает последовательный accept-loop демона. Кэш резолвера —
/// mutating, поэтому класс, а не структура: протокол не даёт `mutating`;
/// последовательный accept-loop демона — единственный клиент, блокировки
/// не нужны. Сырой вывод содержит секреты — не логировать.
public final class WGShowExecutor: WGShowExecuting {
    private var resolver: WGBinaryResolver
    private let arguments: [String]
    private let timeout: TimeInterval
    private let killGrace: TimeInterval

    /// Продакшн-дедлайн выполнения wg (SIGTERM). Худший случай бюджета ответа
    /// демона — `defaultTimeout + 2 * defaultKillGrace` — обязан с запасом
    /// укладываться в клиентский дедлайн `SocketWGShowRunner.defaultTimeout`:
    /// иначе TERM-игнорирующий wg встречает тишину до клиентского таймаута
    /// (`.commandTimeout` → ложное `broken` у сервиса) вместо err-ответа демона.
    public static let defaultTimeout: TimeInterval = 3.0
    /// Продакшн-grace эскалации: TERM → KILL и KILL → отказ от ожидания.
    public static let defaultKillGrace: TimeInterval = 0.5

    /// - Parameters:
    ///   - resolver: резолвер бинаря `wg` (инжектируемая FS — для тестов).
    ///   - arguments: аргументы запуска — литеральные, без шелла; инжектируются
    ///     для тестовых стабов.
    ///   - timeout: дедлайн выполнения wg (SIGTERM); полный бюджет ответа
    ///     (`timeout + 2 * killGrace`) держите ниже клиентского дедлайна —
    ///     демон успевает ответить `err` даже TERM-игнорирующему случаю.
    ///   - killGrace: срок между SIGTERM и SIGKILL (и между SIGKILL и отказом
    ///     от ожидания) — инжектируется коротким в тестах.
    public init(
        resolver: WGBinaryResolver = WGBinaryResolver(
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        ),
        arguments: [String] = ["show", "all", "dump"],
        timeout: TimeInterval = WGShowExecutor.defaultTimeout,
        killGrace: TimeInterval = WGShowExecutor.defaultKillGrace
    ) {
        self.resolver = resolver
        self.arguments = arguments
        self.timeout = timeout
        self.killGrace = killGrace
    }

    public func runDump() async throws -> String {
        guard let binaryPath = resolver.resolve() else {
            throw WGShowExecutorError.wgMissing
        }

        // Блокирующее ожидание уходит с кооперативного пула; отмена задачи
        // (клиент ушёл по EOF) будит его сигналом ребёнку.
        let handle = ChildProcessHandle(killGrace: killGrace)
        let executableURL = URL(fileURLWithPath: binaryPath)
        let arguments = self.arguments
        let timeout = self.timeout
        let killGrace = self.killGrace
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task.detached {
                    do {
                        let output = try Self.runWGSync(
                            handle: handle,
                            executableURL: executableURL,
                            arguments: arguments,
                            timeout: timeout,
                            killGrace: killGrace
                        )
                        continuation.resume(returning: output)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            handle.cancel()
        }
    }

    private static func runWGSync(
        handle: ChildProcessHandle,
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        killGrace: TimeInterval
    ) throws -> String {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Каналы дренируются параллельно ожиданию (как в ProcessWGShowRunner):
        // дамп больше буфера пайпа блокирует запись wg — waitUntilExit без
        // чтения висел бы до таймаута вместо данных.
        var outputData = Data()
        var errorData = Data()
        let drainQueue = DispatchQueue(label: "com.wgstatusbar.wgexecutor.drain", attributes: .concurrent)
        let drained = DispatchGroup()

        let stateQueue = DispatchQueue(label: "com.wgstatusbar.wgexecutor.state")
        var timedOut = false
        var exited = false

        // Регистрация до run(): отмена, пришедшая до запуска, останавливает
        // ребёнка ещё до его рождения. Но отмена в окне между register и run
        // видит pid == 0 и не может сигналить — повторная проверка после
        // запуска добивает уже живого ребёнка.
        guard handle.register(process) else {
            throw CancellationError()
        }
        do {
            try process.run()
        } catch {
            throw WGShowExecutorError.wgFailed(error.localizedDescription)
        }
        handle.killIfCancelled()

        // Дренирование стартует только после успешного запуска: при броске
        // run() write-концы пайпов остаются открытыми у нас, и читатели
        // висели бы вечно на отсутствии EOF.
        drained.enter()
        drainQueue.async {
            outputData = outPipe.fileHandleForReading.readDataToEndOfFile()
            drained.leave()
        }
        drained.enter()
        drainQueue.async {
            errorData = errPipe.fileHandleForReading.readDataToEndOfFile()
            drained.leave()
        }

        // Двухступенчатый таймаут: TERM в дедлайн, KILL ещё через killGrace —
        // wg, игнорирующий или ловящий TERM, не должен подвешивать
        // последовательный accept-loop демона до собственного выхода.
        let timeoutTask = DispatchWorkItem {
            let shouldTerminate = stateQueue.sync { () -> Bool in
                guard !exited, process.isRunning else { return false }
                timedOut = true
                return true
            }
            if shouldTerminate {
                // kill вместо terminate(): между проверкой и сигналом процесс
                // может завершиться сам — kill несуществующему pid безвреден.
                kill(process.processIdentifier, SIGTERM)
            }
        }
        let killTask = DispatchWorkItem {
            let shouldKill = stateQueue.sync { () -> Bool in
                guard !exited, process.isRunning else { return false }
                return true
            }
            if shouldKill {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.terminationHandler = { _ in
            stateQueue.sync { exited = true }
            timeoutTask.cancel()
            killTask.cancel()
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutTask)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout + killGrace, execute: killTask)

        // Ожидание выхода ограничено и за SIGKILL'ом (ещё killGrace): неумирающий
        // даже от KILL ребёнок — непрерываемый сон в ядре — не должен подвешивать
        // демон; отдаём таймаут, оставив живого ребёнка и дренирующие потоки
        // системе (деградация патологического случая, не вечный клин демона).
        let waitDeadline = Date().addingTimeInterval(timeout + 2 * killGrace)
        while !stateQueue.sync(execute: { exited }) {
            if Date() >= waitDeadline {
                throw WGShowExecutorError.timedOut
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        // По факту выхода мгновенен и гарантирует reaping зомби.
        process.waitUntilExit()
        drained.wait()

        // Отмена задачи важнее классификации выхода: вызывающий уже не ждёт
        // результат, `err`-ответ никому не адресован.
        if handle.isCancelled {
            throw CancellationError()
        }

        // Латч timedOut ставится в гонке на границе дедлайна (`isRunning`
        // отстаёт от фактического выхода): wg, завершившийся успешно уже
        // после срабатывания дедлайна, отдаёт данные, а не таймаут.
        if stateQueue.sync(execute: { timedOut }), process.terminationStatus != 0 {
            throw WGShowExecutorError.timedOut
        }

        let errorText = String(data: errorData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let stderrDetail = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !stderrDetail.isEmpty {
                throw WGShowExecutorError.wgFailed(stderrDetail)
            }
            throw WGShowExecutorError.wgFailed("exit status \(process.terminationStatus)")
        }

        return String(data: outputData, encoding: .utf8) ?? ""
    }
}
