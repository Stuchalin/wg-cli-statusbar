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
/// разных потоков под локом.
private final class ChildProcessHandle {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

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
    /// pid безвреден, гонка с завершением процесса — тоже.
    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if let process {
            kill(process.processIdentifier, SIGTERM)
        }
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// Продакшн-исполнитель демона: резолвит бинарь `wg` через `WGBinaryResolver`
/// (промах → `wgMissing`, процесс не запускается; промах не кэшируется —
/// `brew install wireguard-tools` подхватится следующим запросом), запускает
/// его с литеральными аргументами и дедлайном, зависший ребёнок убивается.
/// Кэш резолвера — mutating, поэтому класс, а не структура: протокол не даёт
/// `mutating`; последовательный accept-loop демона — единственный клиент,
/// блокировки не нужны. Сырой вывод содержит секреты — не логировать.
public final class WGShowExecutor: WGShowExecuting {
    private var resolver: WGBinaryResolver
    private let arguments: [String]
    private let timeout: TimeInterval

    /// - Parameters:
    ///   - resolver: резолвер бинаря `wg` (инжектируемая FS — для тестов).
    ///   - arguments: аргументы запуска — литеральные, без шелла; инжектируются
    ///     для тестовых стабов.
    ///   - timeout: дедлайн выполнения wg; клиентский таймаут (5 c) больше,
    ///     чтобы демон успел ответить `err` вместо обрыва по тишины.
    public init(
        resolver: WGBinaryResolver = WGBinaryResolver(
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        ),
        arguments: [String] = ["show", "all", "dump"],
        timeout: TimeInterval = 4.0
    ) {
        self.resolver = resolver
        self.arguments = arguments
        self.timeout = timeout
    }

    public func runDump() async throws -> String {
        guard let binaryPath = resolver.resolve() else {
            throw WGShowExecutorError.wgMissing
        }

        // Блокирующий waitUntilExit уходит с кооперативного пула; отмена
        // задачи (клиент ушёл по EOF) будит его сигналом ребёнку.
        let handle = ChildProcessHandle()
        let executableURL = URL(fileURLWithPath: binaryPath)
        let arguments = self.arguments
        let timeout = self.timeout
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task.detached {
                    do {
                        let output = try Self.runWGSync(
                            handle: handle,
                            executableURL: executableURL,
                            arguments: arguments,
                            timeout: timeout
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
        timeout: TimeInterval
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

        // Регистрация до run(): отмена, пришедшая в микросекунды старта,
        // не должна потерять ребёнка.
        guard handle.register(process) else {
            throw CancellationError()
        }
        do {
            try process.run()
        } catch {
            throw WGShowExecutorError.wgFailed(error.localizedDescription)
        }

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
        process.terminationHandler = { _ in
            stateQueue.sync { exited = true }
            timeoutTask.cancel()
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutTask)
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
