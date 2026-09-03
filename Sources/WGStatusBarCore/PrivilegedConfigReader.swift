import Darwin
import Foundation
import LocalAuthentication

// MARK: - Пути установленного хелпера

/// Фиксированные пути установленного root-хелпера (их создаёт
/// install-daemon.sh). Reveal исполняет ТОЛЬКО этот бинарь; копия в
/// user-writable бандле приложения никогда не выполняется.
public enum InstalledHelperPaths {
    /// Каталог PrivilegedHelperTools: root-owned, без group/world-записи.
    public static let directory = "/Library/PrivilegedHelperTools"
    /// Сам бинарь: root-owned, обычный файл, исполняемый, без group/world-записи.
    public static let binary = "/Library/PrivilegedHelperTools/com.stuchalin.wgstatusbar.helper"
}

// MARK: - Локальная аутентификация владельца

/// Исход аутентификации владельца. Отмена — не ошибка приложения: текущий
/// маскированный документ сохраняется, глобального сбоя нет.
public enum ConfigRevealAuthOutcome: Equatable {
    case success
    case userCancelled
    /// Политика недоступна (нет пароля/биометрии на этой macOS).
    case unavailable
    case failed
}

/// Граница локальной аутентификации для Reveal: свежая проверка на каждое
/// действие — успех в прошлом не авторизует будущее. Инжектируется: системный
/// промпт не автоматизируется (Testing Strategy).
public protocol ConfigRevealAuthenticating {
    func authenticate(reason: String) async -> ConfigRevealAuthOutcome
}

/// Продакшн: `LAContext.evaluatePolicy(.deviceOwnerAuthentication)` — Touch ID,
/// Apple Watch или пароль пользователя по возможностям macOS. Контекст
/// создаётся заново на каждый вызов, `touchIDAuthenticationAllowableReuseDuration = 0`
/// — переиспользование недавней разблокировки запрещено. Отмена задачи
/// инвалидирует контекст: висящий промпт закрывается вместе с окном вьювера.
public struct LocalAuthenticationConfigAuthenticator: ConfigRevealAuthenticating {
    public init() {}

    public func authenticate(reason: String) async -> ConfigRevealAuthOutcome {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        context.localizedCancelTitle = L10n.string("config.auth.cancel")
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ConfigRevealAuthOutcome, Never>) in
                context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                    continuation.resume(returning: Self.classify(success: success, error: error))
                }
            }
        } onCancel: {
            // Invalidate завершает висящую evaluatePolicy ошибкой отмены —
            // промпт не переживает окно, которое его породило.
            context.invalidate()
        }
    }

    /// Классификация ответа LAContext: отмена (пользователем, приложением
    /// после invalidate, системой) — тихий исход; недоступность политики
    /// (биометрия/пароль не настроены) — отдельная ветка; прочее — сбой.
    /// Ошибки LAError не содержат содержимого конфигурации и в диагностику
    /// не попадают — наружу уходит только категория.
    private static func classify(success: Bool, error: Error?) -> ConfigRevealAuthOutcome {
        if success { return .success }
        switch (error as? LAError)?.code {
        case .userCancel, .appCancel, .systemCancel:
            return .userCancelled
        case .biometryNotAvailable, .biometryNotEnrolled, .biometryLockout, .passcodeNotSet:
            return .unavailable
        default:
            return .failed
        }
    }
}

// MARK: - Процессный слой

/// Сбой процессного слоя: типизированные категории без stdout/stderr —
/// данные ребёнка (в т.ч. возможный raw-конфиг) не попадают в диагностику.
public enum PrivilegedProcessError: Error, Equatable {
    /// `Process.run()` бросил: бинаря нет или он неисполняем.
    case launchFailed
    /// Дедлайн таймаута (лестница TERM → SIGKILL не помогла ждать дальнейшего).
    case timedOut
    /// Задача отменена до или во время выполнения.
    case cancelled
    /// Ненулевой выход или смерть от сигнала.
    case exitFailure
    /// stdout превысил потолок накопления — мусорный канал.
    case outputExceeded
}

/// Исход процесса: stdout возвращается только при нулевом выходе.
/// `promptCancelled` — пользователь отменил админ-промпт osascript (детект по
/// номеру ошибки AppleScript `(-128)` в stderr внутри слоя; сам текст stderr
/// наружу не идёт).
public enum PrivilegedProcessOutcome: Equatable {
    case success(stdout: String)
    case promptCancelled
    case failure(PrivilegedProcessError)
}

/// Запуск внешнего процесса с параллельным чанк-дрейном stdout/stderr,
/// потолком накопления до декодирования, опциональным таймаутом и отменой
/// задачи с ограниченным завершением ребёнка. Инжектируется — стабы в тестах
/// программируются исходами и считают вызовы.
public protocol PrivilegedProcessRunning {
    /// - Parameters:
    ///   - argv: `argv[0]` — путь к исполняемому файлу, остальные — аргументы.
    ///   - timeout: дедлайн TERM → SIGKILL; `nil` — без таймаута: админ-промпт
    ///     osascript висит, пока пользователь думает (того же образца, что
    ///     InstallerService); ограничена только отмена задачи.
    ///   - maxCollectedBytes: потолок накопления каждого потока вывода;
    ///     превышение stdout — `outputExceeded`, чтение продолжается в никуда,
    ///     чтобы заполненный пайп не блокировал ребёнка на записи.
    func run(_ argv: [String], timeout: TimeInterval?, maxCollectedBytes: Int) async -> PrivilegedProcessOutcome
}

/// Продакшн процессного слоя: `Process` + два параллельных дрейна кусками
/// (`availableData`) с потолком накопления, лестница TERM → SIGKILL для
/// таймаута и отмены, ограниченное ожидание даже неумирающего ребёнка.
/// Блокирующее ожидание уходит с кооперативного пула (detached-задача), тот
/// же образец, что у ChildProcessRunner демона.
public struct ProcessPrivilegedRunner: PrivilegedProcessRunning {
    /// Grace эскалации SIGTERM → SIGKILL (таймаут и отмена).
    private static let killGrace: TimeInterval = 0.5
    /// Ожидание EOF пайпов после смерти ребёнка: write-концы держит сам
    /// ребёнок, EOF приходит с его смертью; не сошлось — классифицируем по
    /// уже накопленному (fail-closed).
    private static let drainGrace: TimeInterval = 1.0

    public init() {}

    public func run(_ argv: [String], timeout: TimeInterval?, maxCollectedBytes: Int) async -> PrivilegedProcessOutcome {
        let handle = ChildProcessHandle(killGrace: Self.killGrace)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Task.detached(priority: .userInitiated) {
                    continuation.resume(
                        returning: Self.runSync(
                            handle: handle,
                            argv: argv,
                            timeout: timeout,
                            maxCollectedBytes: maxCollectedBytes
                        )
                    )
                }
            }
        } onCancel: {
            handle.cancel()
        }
    }

    /// Потолочное накопление одного потока: копит до `cap` байт, дальше читает
    /// в никуда, запоминая превышение. Писатель один (drain-таск), читаем
    /// после схода DispatchGroup — гонки нет.
    private final class DrainAccumulator {
        private(set) var data = Data()
        private(set) var exceeded = false
        private let cap: Int

        init(cap: Int) {
            self.cap = cap
        }

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            let room = cap - data.count
            if room <= 0 {
                exceeded = true
                return
            }
            data.append(chunk.prefix(room))
            if chunk.count > room {
                exceeded = true
            }
        }
    }

    private static func runSync(
        handle: ChildProcessHandle,
        argv: [String],
        timeout: TimeInterval?,
        maxCollectedBytes: Int
    ) -> PrivilegedProcessOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        // Окружение наследуется: osascript'у нужен контекст пользователя.

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Регистрация до run(): отмена до запуска останавливает ребёнка до
        // рождения; гонка register → run закрывается killIfCancelled.
        guard handle.register(process) else { return .failure(.cancelled) }
        do {
            try process.run()
        } catch {
            return .failure(.launchFailed)
        }
        handle.killIfCancelled()

        let stdoutAccumulator = DrainAccumulator(cap: maxCollectedBytes)
        let stderrAccumulator = DrainAccumulator(cap: maxCollectedBytes)
        let drainQueue = DispatchQueue(label: "com.wgstatusbar.privileged.drain", attributes: .concurrent)
        let drained = DispatchGroup()

        drained.enter()
        drainQueue.async {
            while true {
                let chunk = outPipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }  // EOF
                stdoutAccumulator.append(chunk)
            }
            drained.leave()
        }
        drained.enter()
        drainQueue.async {
            while true {
                let chunk = errPipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                stderrAccumulator.append(chunk)
            }
            drained.leave()
        }

        // Таймаут (если задан): TERM в дедлайн, KILL ещё через grace — тот же
        // латч, что у ChildProcessRunner (`timedOut` бьёт статус: ребёнок,
        // завершившийся на границе дедлайна, классифицируется по данным).
        let stateQueue = DispatchQueue(label: "com.wgstatusbar.privileged.state")
        var exited = false
        var timedOut = false
        let timeoutTask = DispatchWorkItem {
            let shouldTerminate = stateQueue.sync { () -> Bool in
                guard !exited, process.isRunning else { return false }
                timedOut = true
                return true
            }
            if shouldTerminate {
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
        if timeout != nil {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout!, execute: timeoutTask)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout! + killGrace, execute: killTask)
        }
        process.terminationHandler = { _ in
            stateQueue.sync { exited = true }
            timeoutTask.cancel()
            killTask.cancel()
        }

        // Ожидание выхода. С таймаутом — ограничено бюджетом timeout + 2×grace:
        // неумирающий даже от KILL ребёнок (непрерываемый сон в ядре) не
        // подвешивает задачу навсегда — исход timedOut, ребёнок и дрейны
        // остаются системе. Без таймаута — до выхода или отмены: промпт может
        // висеть сколь угодно (осознанно, как у InstallerService); отмена
        // поднимает лестницу TERM → KILL, а ожидание ограничивается 2×grace
        // после её старта.
        let waitDeadline = timeout.map { Date().addingTimeInterval($0 + 2 * killGrace) }
        var cancelDeadline: Date?
        while !stateQueue.sync(execute: { exited }) {
            if handle.isCancelled, cancelDeadline == nil {
                cancelDeadline = Date().addingTimeInterval(2 * killGrace)
            }
            if let deadline = waitDeadline, Date() >= deadline {
                return .failure(.timedOut)
            }
            if let deadline = cancelDeadline, Date() >= deadline {
                return .failure(.cancelled)
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        // По факту выхода мгновенен и забирает зомби.
        process.waitUntilExit()

        // EOF наших пайпов приходит со смертью ребёнка (write-концы держит
        // он один); ждём ограниченно — не сошлось, классифицируем накопленное.
        _ = drained.wait(timeout: .now() + drainGrace)

        // Отмена важнее классификации: результат уже никому не адресован.
        if handle.isCancelled {
            return .failure(.cancelled)
        }
        if stateQueue.sync(execute: { timedOut }) {
            return .failure(.timedOut)
        }
        if process.terminationReason == .exit, process.terminationStatus == 0 {
            if stdoutAccumulator.exceeded {
                return .failure(.outputExceeded)
            }
            guard let stdout = String(data: stdoutAccumulator.data, encoding: .utf8) else {
                return .failure(.exitFailure)
            }
            return .success(stdout: stdout)
        }
        // Ненулевой выход/сигнал: отмена админ-промпта osascript детектится по
        // номеру ошибки AppleScript `(-128)` в stderr (текст локализуется
        // системой, номер — нет; тот же приём, что InstallerService.interpret).
        // Сам stderr наружу не идёт — только категория исхода.
        if stderrAccumulator.data.range(of: Data("(-128)".utf8)) != nil {
            return .promptCancelled
        }
        return .failure(.exitFailure)
    }
}

// MARK: - Префлайт установленного хелпера

/// Снимок lstat для префлайта: тип записи, владелец и биты прав.
public struct PrivilegedHelperStatEntry: Equatable {
    public let isSymbolicLink: Bool
    public let isDirectory: Bool
    public let isRegularFile: Bool
    /// uid владельца; root == 0.
    public let ownerUID: Int
    /// Биты прав без типа файла (st_mode & 0o7777).
    public let permissions: Int

    public init(
        isSymbolicLink: Bool,
        isDirectory: Bool,
        isRegularFile: Bool,
        ownerUID: Int,
        permissions: Int
    ) {
        self.isSymbolicLink = isSymbolicLink
        self.isDirectory = isDirectory
        self.isRegularFile = isRegularFile
        self.ownerUID = ownerUID
        self.permissions = permissions
    }
}

/// Файловый слой префлайта: lstat по точным путям, инжектируется.
public protocol PrivilegedHelperProbingFileSystem {
    /// lstat-информация пути; `nil` — пути нет. lstat не следует за симлинком
    /// — тип последнего компонента виден напрямую.
    func statEntry(atPath path: String) -> PrivilegedHelperStatEntry?
}

public struct PosixPrivilegedHelperProbingFileSystem: PrivilegedHelperProbingFileSystem {
    public init() {}

    public func statEntry(atPath path: String) -> PrivilegedHelperStatEntry? {
        var status = stat()
        guard lstat(path, &status) == 0 else { return nil }
        let fileType = Int(status.st_mode & S_IFMT)
        return PrivilegedHelperStatEntry(
            isSymbolicLink: fileType == S_IFLNK,
            isDirectory: fileType == S_IFDIR,
            isRegularFile: fileType == S_IFREG,
            ownerUID: Int(status.st_uid),
            permissions: Int(status.st_mode & 0o7777)
        )
    }
}

// MARK: - Оркестрация Reveal

/// Ошибка Reveal: типизированные категории без каких-либо данных — ни stdout,
/// ни stderr, ни содержимое конфигурации наружу не идут. Гайдансы сервиса —
/// те же смыслы, что пункты меню Install/Update Service.
public enum PrivilegedConfigError: Error, Equatable {
    /// Сервис не установлен (сокет-файла нет) — установить из меню.
    case serviceInstallRequired
    /// Сервис сломан или устарел — обновить из меню.
    case serviceUpdateRequired
    case invalidName
    /// Установленный хелпер отсутствует, небезопасен или не отвечает
    /// capability-пробе — переустановить сервис.
    case helperUnavailable
    /// Установленный хелпер старее требуемого приложением build или отвечает
    /// чужим протоколом — обновить сервис.
    case helperOutdated
    case authenticationUnavailable
    case authenticationFailed
    case privilegedReadFailed
}

extension PrivilegedConfigError {
    /// Локализованный текст для окна вьювера: фиксированные категории.
    public var userMessage: String {
        switch self {
        case .serviceInstallRequired:
            return L10n.string("config.reveal.error.service_install")
        case .serviceUpdateRequired:
            return L10n.string("config.reveal.error.service_update")
        case .invalidName:
            return L10n.string("config.reveal.error.invalid_name")
        case .helperUnavailable:
            return L10n.string("config.reveal.error.helper_unavailable")
        case .helperOutdated:
            return L10n.string("config.reveal.error.helper_outdated")
        case .authenticationUnavailable:
            return L10n.string("config.reveal.error.auth_unavailable")
        case .authenticationFailed:
            return L10n.string("config.reveal.error.auth_failed")
        case .privilegedReadFailed:
            return L10n.string("config.reveal.error.read_failed")
        }
    }
}

/// Итог Reveal: raw-документ — только после успешной аутентификации и
/// успешного привилегированного чтения; отмена (аутентификация, админ-промпт,
/// закрытие окна) — безопасный тихий исход; повторный вызов во время
/// выполняющегося — подавлен.
public enum ConfigRevealOutcome: Equatable {
    case revealed(TunnelConfigDocument)
    case cancelledByUser
    case suppressed
    case failed(PrivilegedConfigError)
}

/// Оркестратор Reveal для модели вьювера (инжектируется как зависимость).
public protocol ConfigRevealExecuting {
    func reveal(named name: String, serviceState: ServiceState) async -> ConfigRevealOutcome
}

/// Привилегированное one-shot raw-чтение конфига. Порядок границ fail-closed:
/// состояние сервиса → shape имени → lstat каталога и бинаря → capability-проба
/// (тот самый бинарь, обычный пользователь, без промпта) → только затем свежая
/// аутентификация владельца и привилегированный osascript-запуск. Любой сбой
/// на ранних границах — ноль промптов и ноль привилегированных процессов.
public final class PrivilegedConfigReader: ConfigRevealExecuting {
    /// Таймаут capability-пробы: ответ мгновенный и побочных эффектов нет,
    /// промпта нет — зависший бинарь не должен держать Reveal.
    public static let capabilityProbeTimeout: TimeInterval = 5.0
    /// Потолок накопления capability-пробы: ответ фиксированной формы ~40 байт.
    static let capabilityMaxCollectedBytes = 4096
    /// Потолок накопления stdout osascript: тег + base64 документа предельного
    /// размера + терминатор, с запасом (легитимный ответ больше не бывает).
    static let rawEnvelopeMaxCollectedBytes: Int = {
        let documentBytes = TunnelConfigReader.maxSizeBytes
        let base64Bytes = (documentBytes + 2) / 3 * 4
        return 64 + ConfigEnvelope.tag.utf8.count + base64Bytes + 2
    }()

    /// Биты group/other write — небезопасны и для каталога, и для бинаря.
    private static let unsafeWritableBits = 0o022

    private let fileSystem: PrivilegedHelperProbingFileSystem
    private let processRunner: PrivilegedProcessRunning
    private let authenticator: ConfigRevealAuthenticating
    private let helperDirectoryPath: String
    private let helperBinaryPath: String

    /// Один Reveal одновременно: повторный клик — тихий no-op (кнопку глушит
    /// и модель вьювера, но сервис гасит дубль и сам).
    private let claimLock = NSLock()
    private var isRevealing = false

    public init(
        fileSystem: PrivilegedHelperProbingFileSystem = PosixPrivilegedHelperProbingFileSystem(),
        processRunner: PrivilegedProcessRunning = ProcessPrivilegedRunner(),
        authenticator: ConfigRevealAuthenticating = LocalAuthenticationConfigAuthenticator(),
        helperDirectoryPath: String = InstalledHelperPaths.directory,
        helperBinaryPath: String = InstalledHelperPaths.binary
    ) {
        self.fileSystem = fileSystem
        self.processRunner = processRunner
        self.authenticator = authenticator
        self.helperDirectoryPath = helperDirectoryPath
        self.helperBinaryPath = helperBinaryPath
    }

    public func reveal(named name: String, serviceState: ServiceState) async -> ConfigRevealOutcome {
        guard beginClaim() else { return .suppressed }
        defer { endClaim() }

        // 1. Состояние сервиса — до любых файловых, процессных и промпт-границ:
        // маскированный путь без живого демона не бывает, а Reveal поверх
        // старого бинаря (без one-shot-режима) запрещён.
        guard serviceState == .installed else {
            return .failed(serviceState == .absent ? .serviceInstallRequired : .serviceUpdateRequired)
        }
        // 2. Имя — shape-проверка wg-quick (общая с ридером и стором): чужие
        // строки до любой границы процесса.
        guard TunnelConfigStore.isNameShapeValid(name) else {
            return .failed(.invalidName)
        }
        // 3. lstat каталога и бинаря: root-владение, обычный файл, права без
        // group/world-записи, исполняемость.
        if let failure = Self.preflightDirectoryFailure(fileSystem.statEntry(atPath: helperDirectoryPath))
            ?? Self.preflightBinaryFailure(fileSystem.statEntry(atPath: helperBinaryPath)) {
            return .failed(failure)
        }
        // 4. Capability-проба: точный установленный бинарь от обычного
        // пользователя, без промпта. Старый бинарь не знает флаг и начал бы
        // демона — сверка build отсекает его до привилегированной границы.
        switch await processRunner.run(
            [helperBinaryPath, "--capabilities"],
            timeout: Self.capabilityProbeTimeout,
            maxCollectedBytes: Self.capabilityMaxCollectedBytes
        ) {
        case .success(let stdout):
            if let failure = Self.parseCapabilitiesOutput(stdout) {
                return .failed(failure)
            }
        case .promptCancelled:
            // Проба без промпта — категории не бывает; мусорный канал.
            return .failed(.helperUnavailable)
        case .failure(.cancelled):
            return .cancelledByUser
        case .failure:
            return .failed(.helperUnavailable)
        }
        // 5. Свежая аутентификация владельца — только после префлайта.
        switch await authenticator.authenticate(reason: L10n.string("config.auth.reason")) {
        case .success:
            break
        case .userCancelled:
            return .cancelledByUser
        case .unavailable:
            return .failed(.authenticationUnavailable)
        case .failed:
            return .failed(.authenticationFailed)
        }
        // 6. Привилегированный one-shot запуск через osascript: второй
        // (администраторский) промпт появляется, только если у macOS нет
        // переиспользуемой авторизации; его отмена — тот же тихий исход.
        switch await processRunner.run(
            Self.osascriptCommand(helperPath: helperBinaryPath, name: name),
            timeout: nil,
            maxCollectedBytes: Self.rawEnvelopeMaxCollectedBytes
        ) {
        case .success(let stdout):
            return Self.decodeRawEnvelope(stdout)
        case .promptCancelled:
            return .cancelledByUser
        case .failure(.cancelled):
            return .cancelledByUser
        case .failure:
            return .failed(.privilegedReadFailed)
        }
    }

    // MARK: Чистые части (тестируются)

    /// argv osascript для привилегированного one-shot чтения: системный
    /// админ-промпт + shell-команда. Двухслойное экранирование того же
    /// образца, что InstallerService.osascriptCommand: `'`/`'\''` для shell,
    /// `\` и `"` для литерала AppleScript. Имя уже прошло shape-проверку
    /// wg-quick (без кавычек и управляющих символов), но экранирование на
    /// этом не завязано.
    public static func osascriptCommand(helperPath: String, name: String) -> [String] {
        let shellCommand = shellQuoted(helperPath) + " --print-config-raw " + shellQuoted(name)
        return [
            "/usr/bin/osascript",
            "-e",
            "do shell script \"\(applescriptEscaped(shellCommand))\" with administrator privileges"
        ]
    }

    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func applescriptEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Каталог хелпера: существует, не симлинк, каталог, root, без
    /// group/world-записи.
    static func preflightDirectoryFailure(_ entry: PrivilegedHelperStatEntry?) -> PrivilegedConfigError? {
        guard let entry else { return .helperUnavailable }
        guard !entry.isSymbolicLink, entry.isDirectory else { return .helperUnavailable }
        guard entry.ownerUID == 0 else { return .helperUnavailable }
        guard entry.permissions & unsafeWritableBits == 0 else { return .helperUnavailable }
        return nil
    }

    /// Бинарь хелпера: существует, не симлинк, обычный файл, root, без
    /// group/world-записи, исполняемый владельцем.
    static func preflightBinaryFailure(_ entry: PrivilegedHelperStatEntry?) -> PrivilegedConfigError? {
        guard let entry else { return .helperUnavailable }
        guard !entry.isSymbolicLink, entry.isRegularFile else { return .helperUnavailable }
        guard entry.ownerUID == 0 else { return .helperUnavailable }
        guard entry.permissions & unsafeWritableBits == 0 else { return .helperUnavailable }
        guard entry.permissions & 0o100 != 0 else { return .helperUnavailable }
        return nil
    }

    /// Разбор ответа `--capabilities`: строго одна строка из четырёх слов
    /// (`capabilities <протокол> <build> config-raw-v1`) с завершающим `\n` —
    /// без ведущих/двойных пробелов (пустые подпоследовательности не
    /// отбрасываются: ответ обязан совпасть с образцом точно). Протокол обязан
    /// совпасть точно; build — не старее требуемого приложением (старый бинарь
    /// без one-shot-режима должен обновиться, а не исполняться). Любой мусор —
    /// `helperUnavailable`, возраст/протокол — `helperOutdated`.
    static func parseCapabilitiesOutput(_ output: String) -> PrivilegedConfigError? {
        guard output.hasSuffix("\n") else { return .helperUnavailable }
        let line = String(output.dropLast())
        guard !line.contains("\n"), !line.contains("\r") else { return .helperUnavailable }
        let tokens = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard tokens.count == 4,
              tokens[0] == "capabilities",
              tokens[3] == helperConfigRawCapabilityToken,
              let protocolVersion = Int(tokens[1]),
              let build = Int(tokens[2])
        else { return .helperUnavailable }
        guard protocolVersion == helperProtocolVersion else { return .helperOutdated }
        guard build >= helperBuildNumber else { return .helperOutdated }
        return nil
    }

    /// Разбор stdout привилегированного чтения: ровно один `b64:`-конверт
    /// (обрамление транспорта), внутри — точный raw-текст документа с его
    /// собственным завершающим `\n`. Любой мусор — фиксированная категория
    /// без данных.
    static func decodeRawEnvelope(_ stdout: String) -> ConfigRevealOutcome {
        switch ConfigEnvelope.decode(stdout) {
        case .success(let text):
            return .revealed(TunnelConfigDocument(text: text))
        case .failure:
            return .failed(.privilegedReadFailed)
        }
    }

    // MARK: Захват права на единственный Reveal

    private func beginClaim() -> Bool {
        claimLock.lock()
        defer { claimLock.unlock() }
        if isRevealing { return false }
        isRevealing = true
        return true
    }

    private func endClaim() {
        claimLock.lock()
        defer { claimLock.unlock() }
        isRevealing = false
    }
}
