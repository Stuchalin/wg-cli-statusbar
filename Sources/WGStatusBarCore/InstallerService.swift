import Foundation

/// Результат установки/удаления сервиса демона.
public enum InstallResult: Equatable {
    case success
    /// Пользователь закрыл промпт пароль/Touch ID — тихий no-op, не ошибка.
    case cancelled
    case failure(String)
}

/// Подготовленный запуск osascript: argv либо локализованная ошибка до
/// старта процесса (скрипта нет — dev-запуск голого бинаря без .app).
enum PreparedInstallCommand: Equatable {
    case argv([String])
    case failure(String)
}

/// Установка/удаление root-демона кнопкой из меню: osascript
/// `do shell script ... with administrator privileges` показывает системный
/// промпт (пароль/Touch ID) и запускает скрипт из бандла приложения от root.
///
/// Чистые части — сборка argv osascript, разбор кода возврата, резолв скрипта
/// из бандла — статические функции, тестируются напрямую. Сам запуск с
/// системным промптом не автоматизируется (Testing Strategy).
public final class InstallerService {
    /// Успех — немедленный refresh модели (колбэк привязывается в AppDelegate):
    /// карточка оживает, не дожидаясь тика таймера.
    /// Вызывается на главном потоке.
    public var onSuccess: (() -> Void)?
    /// Сбой — текст в ошибку модели на один тик. Отмена промпта сюда не
    /// попадает (тихий no-op). Вызывается на главном потоке.
    public var onFailure: ((String) -> Void)?

    /// Бандл со скриптами установки (продакшн — `Bundle.main`, .app).
    private let bundle: Bundle
    /// Путь бинаря демона для `install-daemon.sh --binary <путь>`.
    private let binaryPath: String?
    /// Запуск osascript; инжектируется для тестов диспетчеризации колбэков —
    /// сам запуск с системным промптом не автоматизируется (Testing Strategy).
    private let runOsa: ([String]) -> InstallResult

    public convenience init() {
        self.init(bundle: .main)
    }

    public init(
        bundle: Bundle,
        binaryPath: String? = nil,
        runOsa: (([String]) -> InstallResult)? = nil
    ) {
        self.bundle = bundle
        self.binaryPath = binaryPath ?? Self.defaultBinaryPath(in: bundle)
        self.runOsa = runOsa ?? Self.runOsaScript
    }

    /// Путь хелпера в бандле приложения — туда его кладёт build-app.sh.
    /// В dev-запуске голого бинаря может не существовать; установка падает
    /// раньше, на отсутствующем скрипте, — путь тогда не используется.
    private static func defaultBinaryPath(in bundle: Bundle) -> String {
        bundle.bundleURL.appendingPathComponent("Contents/MacOS/WGStatusBarHelper").path
    }

    // MARK: - Чистые функции (тестируются)

    /// Резолв скрипта установки из бандла; nil в dev-запуске голого бинаря —
    /// понятная ошибка до запуска osascript.
    public static func installScriptPath(bundle: Bundle) -> String? {
        bundle.path(forResource: "install-daemon", ofType: "sh")
    }

    /// Резолв скрипта удаления из бандла; nil в dev-запуске голого бинаря.
    public static func uninstallScriptPath(bundle: Bundle) -> String? {
        bundle.path(forResource: "uninstall-daemon", ofType: "sh")
    }

    /// argv запуска osascript: системный промпт + shell-команда. Пути в
    /// одинарных кавычках внутри двойных кавычек AppleScript — пробелы не рвут
    /// ни строку AppleScript, ни shell-команду. Путь к .app выбирает
    /// пользователь (апостроф в имени каталога реален), а команда исполняется
    /// от root — поэтому оба слоя экранируются: `'` для shell, `"` и `\` для
    /// литерала AppleScript. Install передаёт `--binary <путь>`, uninstall
    /// зовётся без него.
    public static func osascriptCommand(scriptPath: String, binaryPath: String?) -> [String] {
        var shellCommand = shellQuoted(scriptPath)
        if let binaryPath {
            shellCommand += " --binary " + shellQuoted(binaryPath)
        }
        return [
            "/usr/bin/osascript",
            "-e",
            "do shell script \"\(applescriptEscaped(shellCommand))\" with administrator privileges"
        ]
    }

    /// Оборачивает путь одинарными кавычками; встроенный апостроф закрывается
    /// и переоткрывается (`'\''`) — стандартный способ выжить в POSIX-shell.
    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Экранирует `\` и `"` для строкового литерала AppleScript — путь
    /// проходит через два слоя (AppleScript-строка → shell-команда).
    private static func applescriptEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Разбор кода возврата osascript: успех; «User canceled» в stderr —
    /// пользователь закрыл промпт, тихий no-op; остальное — сбой со stderr.
    public static func interpret(exitCode: Int, stderr: String) -> InstallResult {
        guard exitCode != 0 else { return .success }
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("User canceled") {
            return .cancelled
        }
        return .failure(trimmed.isEmpty ? "exit code \(exitCode)" : trimmed)
    }

    /// Предстартовая сборка: скрипта нет (dev-запуск без .app) —
    /// локализованная ошибка до osascript; иначе argv.
    static func command(scriptPath: String?, binaryPath: String?) -> PreparedInstallCommand {
        guard let scriptPath else {
            return .failure(L10n.string("error.install_script_missing"))
        }
        return .argv(osascriptCommand(scriptPath: scriptPath, binaryPath: binaryPath))
    }

    // MARK: - Запуск (промпт не автоматизируется)

    public func install() async {
        await run(scriptPath: Self.installScriptPath(bundle: bundle), binaryPath: binaryPath)
    }

    public func uninstall() async {
        await run(scriptPath: Self.uninstallScriptPath(bundle: bundle), binaryPath: nil)
    }

    private func run(scriptPath: String?, binaryPath: String?) async {
        let argv: [String]
        switch Self.command(scriptPath: scriptPath, binaryPath: binaryPath) {
        case .failure(let message):
            await MainActor.run { onFailure?(message) }
            return
        case .argv(let value):
            argv = value
        }

        let runOsa = self.runOsa
        let result = await Task.detached(priority: .userInitiated) {
            runOsa(argv)
        }.value

        await MainActor.run {
            switch result {
            case .success:
                onSuccess?()
            case .cancelled:
                break  // тихий no-op — пользователь просто закрыл промпт
            case .failure(let message):
                onFailure?(message)
            }
        }
    }

    /// Синхронный запуск osascript; stdout скрипта не интересует, важны код
    /// возврата и stderr.
    private static func runOsaScript(_ argv: [String]) -> InstallResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return .failure(error.localizedDescription)
        }

        // Каналы дренируются параллельно ожиданию (по образцу
        // ProcessWGShowRunner): заполненный буфер пайпа блокировал бы
        // osascript на записи. Таймаута нет — промпт может висеть, пока
        // пользователь думает: либо ответит, либо отменит.
        var errorData = Data()
        let drainQueue = DispatchQueue(label: "com.wgstatusbar.installer.drain", attributes: .concurrent)
        let drained = DispatchGroup()

        drained.enter()
        drainQueue.async {
            _ = outPipe.fileHandleForReading.readDataToEndOfFile()
            drained.leave()
        }
        drained.enter()
        drainQueue.async {
            errorData = errPipe.fileHandleForReading.readDataToEndOfFile()
            drained.leave()
        }

        process.waitUntilExit()
        drained.wait()

        return interpret(
            exitCode: Int(process.terminationStatus),
            stderr: String(data: errorData, encoding: .utf8) ?? ""
        )
    }
}
