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

/// Продакшн-исполнитель демона: резолвит бинарь `wg` через `WGBinaryResolver`
/// (промах → `wgMissing`, процесс не запускается; промах не кэшируется —
/// `brew install wireguard-tools` подхватится следующим запросом), запускает
/// его с литеральными аргументами через общий раннер `runChildProcess`
/// (жёсткий дедлайн TERM → KILL → ограниченное ожидание, drain пайпов, отмена
/// задачи) и классифицирует сырой результат в свои ошибки. Кэш резолвера —
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

        // Отмена задачи (клиент ушёл по EOF) — забота раннера: он же убивает
        // ребёнка сигналом. Окружение наследуется (nil).
        let result: ChildProcessResult
        do {
            result = try await runChildProcess(
                executableURL: URL(fileURLWithPath: binaryPath),
                arguments: arguments,
                environment: nil,
                timeout: timeout,
                killGrace: killGrace
            )
        } catch let error as ChildProcessError {
            throw Self.translate(error)
        }
        return try Self.classify(result)
    }

    /// Перевод сбоев раннера в свои ошибки: раннер типонезависим и о
    /// `WGShowExecutorError` не знает.
    private static func translate(_ error: ChildProcessError) -> Error {
        switch error {
        case .launchFailed(let message):
            return WGShowExecutorError.wgFailed(message)
        case .abandoned:
            return WGShowExecutorError.timedOut
        case .cancelled:
            return CancellationError()
        }
    }

    /// Классификация дожившего до выхода wg: латч таймаута с ненулевым
    /// статусом — таймаут (TERM-игнорирующий wg не отдаёт данные как успех);
    /// ненулевой exit — `wgFailed` с деталью из stderr (или кодом выхода);
    /// нулевой — сырой stdout как есть.
    private static func classify(_ result: ChildProcessResult) throws -> String {
        if result.timedOut, result.terminationStatus != 0 {
            throw WGShowExecutorError.timedOut
        }
        guard result.terminationStatus == 0 else {
            let stderrDetail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !stderrDetail.isEmpty {
                throw WGShowExecutorError.wgFailed(stderrDetail)
            }
            throw WGShowExecutorError.wgFailed("exit status \(result.terminationStatus)")
        }
        return result.stdout
    }
}
