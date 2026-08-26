import Foundation

/// Ошибка исполнителя wg-quick. Сервер демона переводит её в коды
/// wire-протокола: `quickMissing` → `err wg-quick-missing`, `tunnelNotFound`
/// в исполнителе не живёт (валидация имени — `TunnelConfigStore`), `timedOut`
/// и `failed` → `err wg-failed`. Деталь `failed` — хвост stderr wg-quick —
/// предназначена только логу демона и на wire не попадает: wg-quick эхом
/// печатает в stderr исполняемые команды (включая Pre/PostUp-хуки из
/// конфига), а ошибки дочернего wg могут цитировать строки конфига —
/// секреты не покидают демон.
public enum WGQuickExecutorError: Error, Equatable {
    /// Резолвер не нашёл бинарь `wg-quick`.
    case quickMissing
    /// wg-quick не завершился за op-таймаут и убит.
    case timedOut
    /// Ненулевой exit или провал запуска; деталь — хвост stderr (~300
    /// символов) или `exit status N`, только для лога демона.
    case failed(String)
}

/// Управление туннелями wg-quick на стороне демона. Валидация имени — не
/// здесь (её делает `DaemonServer` через `TunnelConfigStore` до запуска
/// процесса): исполнитель запускает то, что ему передали.
public protocol WGQuickExecuting {
    func runUp(name: String) async throws
    func runDown(name: String) async throws
}

/// Продакшн-исполнитель wg-quick: резолвит бинарь через `WGQuickResolver`
/// (промах → `quickMissing`, процесс не запускается), запускает его с
/// литеральными аргументами через общий раннер `runChildProcess` и
/// классифицирует сырой результат. Окружение ребёнка подменяется PATH'ом из
/// `childPath` — под launchd у демона нет Homebrew в PATH, а wg-quick —
/// `#!/usr/bin/env bash`, требующий bash ≥ 4 (системный bash 3.2 убивает его
/// «Version mismatch»), и внутренне зовёт `wg`/`route`/`ifconfig` по PATH.
/// Кэш резолвера — mutating, поэтому класс, а не структура: протокол не даёт
/// `mutating`; последовательный accept-loop демона — единственный клиент.
public final class WGQuickExecutor: WGQuickExecuting {
    private var resolver: WGQuickResolver
    private let timeout: TimeInterval
    private let killGrace: TimeInterval

    /// Продакшн-бюджет операции wg-quick (SIGTERM): up/down гоняют адреса,
    /// маршруты и DNS (networksetup) — заметно дольше `wg show`. Худший случай
    /// бюджета ответа демона `defaultOpTimeout + 2 * defaultKillGrace` (9.0 c)
    /// обязан с запасом укладываться в клиентский дедлайн операций
    /// (`SocketTunnelClient.opTimeout`, появляется в Task 5; инвариант-тест —
    /// там же), включая show-тик, стартовавший в очереди раньше операции.
    public static let defaultOpTimeout: TimeInterval = 8.0
    /// Продакшн-grace эскалации: TERM → KILL и KILL → отказ от ожидания.
    public static let defaultKillGrace: TimeInterval = 0.5

    /// Лимит детали `.failed`: хвост stderr для лога демона.
    private static let stderrDetailLimit = 300

    /// Системный хвост PATH ребёнка: wg-quick внутренне зовёт системные
    /// `route`/`ifconfig`/`networksetup` — их директории обязаны остаться.
    static let systemPathDirectories = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    /// - Parameters:
    ///   - resolver: резолвер бинаря `wg-quick` (инжектируемая FS — для тестов).
    ///   - timeout: дедлайн операции (SIGTERM); полный бюджет ответа
    ///     (`timeout + 2 * killGrace`) держите ниже клиентского дедлайна —
    ///     демон успевает ответить `err` даже TERM-игнорирующему случаю.
    ///   - killGrace: срок между SIGTERM и SIGKILL (и между SIGKILL и отказом
    ///     от ожидания) — инжектируется коротким в тестах.
    public init(
        resolver: WGQuickResolver = WGQuickResolver(
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        ),
        timeout: TimeInterval = WGQuickExecutor.defaultOpTimeout,
        killGrace: TimeInterval = WGQuickExecutor.defaultKillGrace
    ) {
        self.resolver = resolver
        self.timeout = timeout
        self.killGrace = killGrace
    }

    public func runUp(name: String) async throws {
        try await run(arguments: ["up", name])
    }

    public func runDown(name: String) async throws {
        try await run(arguments: ["down", name])
    }

    /// Аргументы литеральные, без шелла — ровно как в продакшне, поэтому
    /// не инжектируются (подмена `wg` стабом — резолвером, не аргументами).
    private func run(arguments: [String]) async throws {
        guard let binaryPath = resolver.resolve() else {
            throw WGQuickExecutorError.quickMissing
        }

        // Под launchd наследовать окружение демона нельзя: без brew-директорий
        // в PATH wg-quick погибает на shebang `env bash` (системный 3.2).
        // Отмена задачи (shutdown демона) — забота раннера.
        let environment = ["PATH": Self.childPath(resolverDirectories: resolver.searchDirectories)]
        let result: ChildProcessResult
        do {
            result = try await runChildProcess(
                executableURL: URL(fileURLWithPath: binaryPath),
                arguments: arguments,
                environment: environment,
                timeout: timeout,
                killGrace: killGrace
            )
        } catch let error as ChildProcessError {
            throw Self.translate(error)
        }
        try Self.classify(result)
    }

    /// PATH ребёнка wg-quick: директории резолвера вперёд + системный хвост,
    /// без дублей. В продакшне:
    /// `/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`.
    static func childPath(resolverDirectories: [String]) -> String {
        var seen = Set<String>()
        var ordered: [String] = []
        for directory in resolverDirectories + systemPathDirectories
        where seen.insert(directory).inserted {
            ordered.append(directory)
        }
        return ordered.joined(separator: ":")
    }

    /// Перевод сбоев раннера в свои ошибки: раннер типонезависим.
    private static func translate(_ error: ChildProcessError) -> Error {
        switch error {
        case .launchFailed(let message):
            return WGQuickExecutorError.failed(message)
        case .abandoned:
            return WGQuickExecutorError.timedOut
        case .cancelled:
            return CancellationError()
        }
    }

    /// Классификация дожившего до выхода wg-quick: латч таймаута с ненулевым
    /// статусом — таймаут; ненулевой exit — `failed` с хвостом stderr
    /// (лимит — не тащить мегабайты в лог, хвост содержит причину);
    /// нулевой — успех, stdout игнорируется.
    private static func classify(_ result: ChildProcessResult) throws {
        if result.timedOut, result.terminationStatus != 0 {
            throw WGQuickExecutorError.timedOut
        }
        guard result.terminationStatus == 0 else {
            throw WGQuickExecutorError.failed(Self.detail(from: result))
        }
    }

    private static func detail(from result: ChildProcessResult) -> String {
        let trimmed = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "exit status \(result.terminationStatus)"
        }
        return trimmed.count > stderrDetailLimit
            ? String(trimmed.suffix(stderrDetailLimit))
            : trimmed
    }
}
