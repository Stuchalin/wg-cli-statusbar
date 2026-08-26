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
    /// Причина завершения: `.exit` — вышел сам (статус = код возврата),
    /// `.uncaughtSignal` — умер от сигнала. Различие нужно вызывающему в
    /// ветке маркера: убитый нами скрипт wg-quick (wait-ветка) и вышедший
    /// сам по себе с ненулевым кодом — разные исходы одной и той же строки
    /// stderr.
    let terminationReason: Process.TerminationReason
    /// Латч «дедлайн сработал до фактического выхода»: ставится в гонке на
    /// границе дедлайна (`isRunning` отстаёт от фактического выхода) — ребёнок,
    /// завершившийся успешно уже после срабатывания дедлайна, отдаёт данные,
    /// а не таймаут (окончательная классификация `timedOut && статус != 0` —
    /// у вызывающего).
    let timedOut: Bool
    /// Заданный `stderrKillMarker` увиден в stderr отдельной строкой
    /// (`stderrContainsLine`), SIGKILL по задержке
    /// запланирован (успевший выйти сам ребёнок до него не доживает —
    /// смотрите `terminationReason`/`terminationStatus`).
    /// Вывод в этой ветке не собирался: EOF пайпов может прийти только со
    /// смертью переживших ребёнка процессов (см. параметр `stderrKillMarker`)
    /// — буферы не читаются, строки результата пусты.
    let stderrMarkerSeen: Bool
}

/// Сбои, которые нельзя выразить сырым результатом: ребёнка нет вовсе или
/// его выхода не дождались.
internal enum ChildProcessError: Error {
    /// `Process.run()` бросил: бинарь отсутствует или без права исполнения.
    case launchFailed(String)
    /// Ребёнок не умер даже за SIGKILL + killGrace — ожидание оставлено,
    /// живой ребёнок и дренирующие потоки — системе (деградация
    /// патологического случая, не вечный клин последовательного accept-loop);
    /// либо выход состоялся, но EOF пайпов не пришёл до общего дедлайна —
    /// write-концы удерживает пережив ребёнка процесс (daemonизированный
    /// wireguard-go наследует stdout/stderr wg-quick), раньше такое ожидание
    /// висело вечно и клинило accept-loop демона.
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
/// Опция `stderrKillMarker` — для детей, которые после успешной работы не
/// завершаются сами (wg-quick в launchd-режиме `detect_launchd` сидит в
/// финальном `wait`, пока жив туннель): строка-маркер в stderr означает
/// «настройка завершена», раннер через `markerKillDelay` добивает ребёнка
/// SIGKILL (не TERM: до маркера wg-quick не снял teardown-трапы — TERM снёс
/// бы только что собранный туннель; мгновенный KILL — убил бы скрипт до
/// рождения сабшелла-монитора) и отдаёт результат с `stderrMarkerSeen`,
/// не дожидаясь EOF пайпов — их write-концы удерживают пережив ребёнка
/// процессы (daemonизированный wireguard-go), EOF приходит лишь со смертью
/// туннеля.
///
/// Маркер сверяется ЦЕЛОЙ строкой stderr (`stderrContainsLine`): wg-quick
/// печатает настоящий маркер собственным `echo … >&2`, но каждый хук перед
/// выполнением эхом попадает в stderr как `[#] <текст хука>`, а PreUp-хуки
/// бегут ДО set_config/адресов/маршрутов/DNS — хук, чей текст или вывод
/// несёт подстроку маркера, не изображал бы завершение настройки: ранний
/// marker-KILL давал бы ложный ok на полуподнятом туннеле. Хук, сознательно
/// печатающий ТОЧНУЮ строку маркера, неотличим — этот остаток поглощён
/// принятым риском «конфиг = произвольный root-код» (README): автор такого
/// хука и без подделки исполняет произвольный код от root.
///
/// Две точки входа: асинхронная (ниже) — для исполнителей демона, владеет
/// `ChildProcessHandle` и проводкой отмены задачи сама; синхронная с явным
/// `handle:` — ядро, отдельный параметр оставлен ради теста гонки
/// register → cancel → run.
///
/// Маркер `stderrKillMarker` — всегда ровно одна строка без `\n`; сверка
/// целых строк — `stderrContainsLine` ниже.
internal func runChildProcess(
    executableURL: URL,
    arguments: [String],
    environment: [String: String]?,
    timeout: TimeInterval,
    killGrace: TimeInterval,
    stderrKillMarker: String? = nil,
    markerKillDelay: TimeInterval = 0
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
                            killGrace: killGrace,
                            stderrKillMarker: stderrKillMarker,
                            markerKillDelay: markerKillDelay
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

/// Есть ли в `data` строка, побайтово равная `line` (между границей потока/`\n`
/// и следующим `\n`). Маркер обязан жить целой строкой: эхо wg-quick
/// `[#] <текст хука>` (хук печатается ДО выполнения, PreUp — до set_config)
/// и любой вывод с подстрокой маркера внутри чужой строки сигналом
/// завершения настройки не считаются — ранний KILL по подстроке отвечал бы
/// ложным успехом на полуподнятом туннеле. Неполный хвост без `\n` не
/// сверяется: маркер печатается `echo` с терминатором, дождёмся его.
internal func stderrContainsLine(_ data: Data, line: Data) -> Bool {
    let needle = line + Data([0x0A])
    var searchStart = data.startIndex
    while let hit = data.range(of: needle, in: searchStart..<data.endIndex) {
        // Начало попадания обязано быть границей строки: началом потока или
        // байтом сразу после `\n` — иначе маркер сидит внутри чужой строки.
        if hit.lowerBound == data.startIndex || data[hit.lowerBound - 1] == 0x0A {
            return true
        }
        searchStart = hit.lowerBound + 1
    }
    return false
}

internal func runChildProcess(
    handle: ChildProcessHandle,
    executableURL: URL,
    arguments: [String],
    environment: [String: String]?,
    timeout: TimeInterval,
    killGrace: TimeInterval,
    stderrKillMarker: String? = nil,
    markerKillDelay: TimeInterval = 0
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
    var markerSeen = false

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
    // stderr — инкрементально: накопление для детали ошибки то же, что и при
    // чтении до EOF, плюс наблюдение за `stderrKillMarker` до конца потока.
    // Целочисленная сверка по всему накопленному буферу: маркер может
    // разорваться границей chunk'а; `errorData` трогает только этот drain-таск
    // (писатель один), флаг — под stateQueue, как `timedOut`/`exited`.
    let markerData = stderrKillMarker.map { Data($0.utf8) }
    drained.enter()
    drainQueue.async {
        while true {
            let chunk = errPipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }  // EOF
            errorData.append(chunk)
            guard let markerData, stderrContainsLine(errorData, line: markerData) else { continue }
            let alreadySeen = stateQueue.sync { () -> Bool in
                if markerSeen { return true }
                markerSeen = true
                return false
            }
            guard !alreadySeen else { continue }
            // Не мгновенно и SIGKILL: см. комментарий опции `stderrKillMarker`.
            // Проверка isRunning сужает гонку переиспользования pid уже
            // завершившегося процесса (образец — scheduleSigkill).
            DispatchQueue.global().asyncAfter(deadline: .now() + markerKillDelay) {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
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

    // Ветка маркера: настройка, которую он обозначает, завершена — вывод не
    // собираем и drains не ждём (EOF удерживают пережив ребёнка процессы,
    // см. опцию `stderrKillMarker`; дренирующие задачи завершатся с их
    // смертью, ничего не течёт дальше числа живых туннелей). Маркер не
    // гарантирует финал wg-quick (печатается до PostUp-хуков), поэтому в
    // результате отдаются статус И причина завершения — окончательная
    // классификация за вызывающим, как и во всех остальных ветках.
    if stateQueue.sync(execute: { markerSeen }) {
        // Отмена задачи важнее и здесь: shutdown демона уже TERM'ит ребёнка,
        // результат никому не адресован — не отвечаем «успехом по маркеру».
        if handle.isCancelled {
            throw ChildProcessError.cancelled
        }
        return ChildProcessResult(
            stdout: "",
            stderr: "",
            terminationStatus: process.terminationStatus,
            terminationReason: process.terminationReason,
            timedOut: stateQueue.sync(execute: { timedOut }),
            stderrMarkerSeen: true
        )
    }

    // И EOF пайпов ждём не вечно: write-концы может удерживать пережив
    // ребёнок процесс — не сошлись до общего дедлайна → abandoned, вызывающий
    // классифицирует сам (иначе один такой op клинил бы accept-loop демона).
    // Нулевой остаток бюджета не отменяет саму проверку: `wait` с дедлайном
    // «сейчас» мгновенно возвращает .success для уже сошедшихся drains —
    // ребёнок, вышедший прямо на границе бюджета с уже закрывшимися пайпами,
    // классифицируется по своим данным, а не как abandoned.
    let drainBudgetMilliseconds = Int(max(0, waitDeadline.timeIntervalSinceNow * 1000))
    if drained.wait(timeout: .now() + .milliseconds(drainBudgetMilliseconds)) == .timedOut {
        throw ChildProcessError.abandoned
    }

    // Отмена задачи важнее классификации выхода: вызывающий уже не ждёт
    // результат, ответ никому не адресован.
    if handle.isCancelled {
        throw ChildProcessError.cancelled
    }

    return ChildProcessResult(
        stdout: String(data: outputData, encoding: .utf8) ?? "",
        stderr: String(data: errorData, encoding: .utf8) ?? "",
        terminationStatus: process.terminationStatus,
        terminationReason: process.terminationReason,
        timedOut: stateQueue.sync(execute: { timedOut }),
        stderrMarkerSeen: false
    )
}
