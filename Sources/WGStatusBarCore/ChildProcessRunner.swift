import Foundation

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

/// Сырой результат ребёнка без какой-либо классификации: перевод в
/// типоспецифичные ошибки (`WGShowExecutorError`, `WGQuickExecutorError`) —
/// ответственность вызывающего, раннер о них не знает.
internal struct ChildProcessResult {
    /// stdout ребёнка (UTF-8, невалидные байты → пустая строка).
    let stdout: String
    /// stderr ребёнка — источник детали для ошибок вызывающего.
    let stderr: String
    /// Статус завершения (номер сигнала, если ребёнок убит).
    let terminationStatus: Int32
    /// Латч «дедлайн сработал до фактического выхода»: ставится в гонке на
    /// границе дедлайна (`isRunning` отстаёт от фактического выхода) — ребёнок,
    /// завершившийся успешно уже после срабатывания дедлайна, отдаёт данные,
    /// а не таймаут (окончательная классификация `timedOut && статус != 0` —
    /// у вызывающего).
    let timedOut: Bool
}

/// Сбои, которые нельзя выразить сырым результатом: ребёнка нет вовсе или
/// его выхода не дождались.
internal enum ChildProcessError: Error {
    /// `Process.run()` бросил: бинарь отсутствует или без права исполнения.
    case launchFailed(String)
    /// Ребёнок не умер даже за SIGKILL + killGrace: ожидание оставлено,
    /// живой ребёнок и дренирующие потоки — системе (деградация
    /// патологического случая, не вечный клин последовательного accept-loop).
    case abandoned
    /// Задача отменена до или во время выполнения.
    case cancelled
}

/// Общий раннер child-процессов демона: запуск с литеральными аргументами,
/// параллельный drain пайпов (вывод больше буфера пайпа блокирует запись
/// ребёнка — wait без чтения висел бы до таймаута), двухступенчатый таймаут
/// TERM в `timeout` → KILL ещё через `killGrace` → ограниченное ожидание,
/// отмена задачи через `ChildProcessHandle`. Выделен из прежнего
/// `WGShowExecutor.runWGSync`; классификацию результата не делает.
///
/// Две точки входа: асинхронная (ниже) — для исполнителей демона, владеет
/// `ChildProcessHandle` и проводкой отмены задачи сама; синхронная с явным
/// `handle:` — ядро, отдельный параметр оставлен ради теста гонки
/// register → cancel → run.
internal func runChildProcess(
    executableURL: URL,
    arguments: [String],
    environment: [String: String]?,
    timeout: TimeInterval,
    killGrace: TimeInterval
) async throws -> ChildProcessResult {
    let handle = ChildProcessHandle(killGrace: killGrace)
    // Блокирующее ожидание уходит с кооперативного пула; отмена задачи
    // будит его сигналом ребёнку. Ошибки остаются ChildProcessError — перевод
    // в типы исполнителя на вызывающем.
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            Task.detached {
                do {
                    continuation.resume(
                        returning: try runChildProcess(
                            handle: handle,
                            executableURL: executableURL,
                            arguments: arguments,
                            environment: environment,
                            timeout: timeout,
                            killGrace: killGrace
                        )
                    )
                } catch {
                    // runChildProcess кидает только ChildProcessError —
                    // ветка недостижима, но continuation не должен висеть.
                    continuation.resume(throwing: error)
                }
            }
        }
    } onCancel: {
        handle.cancel()
    }
}

internal func runChildProcess(
    handle: ChildProcessHandle,
    executableURL: URL,
    arguments: [String],
    environment: [String: String]?,
    timeout: TimeInterval,
    killGrace: TimeInterval
) throws -> ChildProcessResult {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    // nil — наследовать окружение демона; непустой словарь заменяет его целиком.
    process.environment = environment

    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    var outputData = Data()
    var errorData = Data()
    let drainQueue = DispatchQueue(label: "com.wgstatusbar.childrunner.drain", attributes: .concurrent)
    let drained = DispatchGroup()

    let stateQueue = DispatchQueue(label: "com.wgstatusbar.childrunner.state")
    var timedOut = false
    var exited = false

    // Регистрация до run(): отмена, пришедшая до запуска, останавливает
    // ребёнка ещё до его рождения. Но отмена в окне между register и run
    // видит pid == 0 и не может сигналить — повторная проверка после
    // запуска добивает уже живого ребёнка.
    guard handle.register(process) else {
        throw ChildProcessError.cancelled
    }
    do {
        try process.run()
    } catch {
        throw ChildProcessError.launchFailed(error.localizedDescription)
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
    // ребёнок, игнорирующий или ловящий TERM, не должен подвешивать
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
    // демон; отдаём abandoned, оставив живого ребёнка и дренирующие потоки
    // системе.
    let waitDeadline = Date().addingTimeInterval(timeout + 2 * killGrace)
    while !stateQueue.sync(execute: { exited }) {
        if Date() >= waitDeadline {
            throw ChildProcessError.abandoned
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
    // По факту выхода мгновенен и гарантирует reaping зомби.
    process.waitUntilExit()
    drained.wait()

    // Отмена задачи важнее классификации выхода: вызывающий уже не ждёт
    // результат, ответ никому не адресован.
    if handle.isCancelled {
        throw ChildProcessError.cancelled
    }

    return ChildProcessResult(
        stdout: String(data: outputData, encoding: .utf8) ?? "",
        stderr: String(data: errorData, encoding: .utf8) ?? "",
        terminationStatus: process.terminationStatus,
        timedOut: stateQueue.sync(execute: { timedOut })
    )
}
