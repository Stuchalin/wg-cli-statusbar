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
    /// символов; собирается и в маркер-ветке самостоятельного ненулевого
    /// выхода — снапшотом, без ожидания EOF пайпов) либо `exit status N`
    /// при пустом stderr, только для лога демона.
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
///
/// Особенность `up` (darwin wg-quick, brew): под root `detect_launchd` находит
/// `domain =` в `launchctl procinfo $$` и финальный `wait` держит скрипт живым,
/// пока жив туннель, — успешный `up` НЕ завершается сам (проверено на живой
/// машине: скрипт висит в `wait` сутками при поднятом туннеле). Поэтому успех
/// `up` определяется двумя сигналами: строка-маркер монитора в stderr (быстрый
/// путь — адреса/маршруты/DNS применены, до PostUp-хуков; раннер добивает
/// скрипт SIGKILL, туннель и монитор живут, а самостоятельный ненулевой exit
/// после маркера — провал set -e, см. ветку маркера в `run`) либо, при дрейфе
/// текста маркера, пост-таймаутная проба `/var/run/wireguard/<name>.name` +
/// `<utun>.sock` (get_real_interface-пара): туннель поднят — отвечаем
/// успехом, а не таймаутом. `down` не виснет (`wait` включён только в ветке
/// `up`).
///
/// Кэш резолвера — mutating, поэтому класс, а не структура: протокол не даёт
/// `mutating`; последовательный accept-loop демона — единственный клиент.
public final class WGQuickExecutor: WGQuickExecuting {
    private var resolver: WGQuickResolver
    private let timeout: TimeInterval
    private let killGrace: TimeInterval
    private let tunnelUpProbe: (String) -> Bool

    /// Продакшн-бюджет операции wg-quick (SIGTERM): up/down гоняют адреса,
    /// маршруты и DNS (networksetup) — заметно дольше `wg show`. Худший случай
    /// бюджета ответа демона `defaultOpTimeout + 2 * defaultKillGrace` (9.0 c)
    /// обязан с запасом укладываться в клиентский дедлайн операций
    /// (`SocketTunnelClient.opTimeout`, инвариант-тест там же), включая
    /// show-тик, стартовавший в очереди раньше операции.
    public static let defaultOpTimeout: TimeInterval = 8.0
    /// Продакшн-grace эскалации: TERM → KILL и KILL → отказ от ожидания.
    public static let defaultKillGrace: TimeInterval = 0.5

    /// Строка-маркер запуска монитора wg-quick (darwin): печатается в stderr
    /// ПОСЛЕ применения адресов/маршрутов/DNS и непосредственно перед финальным
    /// `wait` — увидели значит настройка туннеля завершена. Раннер сверяет
    /// маркер ЦЕЛОЙ строкой stderr: настоящий печатается собственным
    /// `echo … >&2`, а хуки wg-quick эхом попадают в stderr как
    /// `[#] <текст хука>` ДО выполнения (PreUp — до set_config) — подстрока
    /// маркера в чужой строке не изображала бы завершение настройки (ложный
    /// ok на полуподнятом туннеле); сознательная печать точной строки хуком
    /// неотличима и поглощена принятым риском «конфиг = произвольный
    /// root-код» (README). Дрейф текста в будущих версиях wg-quick
    /// деградирует до медленного проба-пути (полный op-таймаут +
    /// `tunnelIsUp`), не до ложного провала.
    static let upMonitorMarker = "[+] Backgrounding route monitor"
    /// Пауза между маркером и SIGKILL скрипта. Нижняя граница — рождение
    /// сабшелла-монитора: маркер печатается ДО него, мгновенный сигнал убивал
    /// бы скрипт раньше монитора (туннель без обслуживания маршрутов/DNS).
    /// Настоящее назначение — grace-окно для PostUp-хуков: под демоном
    /// wg-quick НЕ завершается сам при успехе (финальный `wait`), так что
    /// самостоятельный exit после маркера бывает только у провала (`set -e`
    /// роняет скрипт сорвавшимся хуком) — раннер чтит собственные выходы
    /// ровно это окно, и исполнитель честно классифицирует их. Хук, не
    /// уложившийся в окно, убивается вместе со скриптом посреди выполнения:
    /// ответ — ok (настройку туннеля маркер уже доказал), а поздний провал
    /// осиротевшего хука ненаблюдаем — вывод не читается, teardown-трап
    /// wg-quick не выполняется (CLI wg-quick в этом месте разобрал бы
    /// туннель и вышел ненулевым). Это осознанная граница, а не пропуск в
    /// классификации: бюджет ответа демона конечен (9 c), длительности хуков
    /// — нет, никакое конечное окно их не покрывает, а расширение окна
    /// замедляет каждый успешный up и расширяет гонку TERM/KILL.
    static let upMonitorKillDelay: TimeInterval = 1.0

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
    ///   - tunnelUpProbe: проверка «туннель реально поднят» для
    ///     пост-таймаутной классификации `up` (инъекция — для тестов;
    ///     продакшн — `tunnelIsUp(name:)`).
    public init(
        resolver: WGQuickResolver = WGQuickResolver(
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        ),
        timeout: TimeInterval = WGQuickExecutor.defaultOpTimeout,
        killGrace: TimeInterval = WGQuickExecutor.defaultKillGrace,
        tunnelUpProbe: ((String) -> Bool)? = nil
    ) {
        self.resolver = resolver
        self.timeout = timeout
        self.killGrace = killGrace
        self.tunnelUpProbe = tunnelUpProbe ?? { Self.tunnelIsUp(name: $0) }
    }

    public func runUp(name: String) async throws {
        try await run(
            arguments: ["up", name],
            stderrKillMarker: Self.upMonitorMarker,
            markerKillDelay: Self.upMonitorKillDelay,
            probeName: name
        )
    }

    public func runDown(name: String) async throws {
        try await run(arguments: ["down", name], stderrKillMarker: nil, markerKillDelay: 0, probeName: nil)
    }

    /// Аргументы литеральные, без шелла — ровно как в продакшне, поэтому
    /// не инжектируются (подмена `wg` стабом — резолвером, не аргументами).
    /// `probeName`/маркер — только для `up`: успех `down` — обычный exit.
    private func run(
        arguments: [String],
        stderrKillMarker: String?,
        markerKillDelay: TimeInterval,
        probeName: String?
    ) async throws {
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
                killGrace: killGrace,
                stderrKillMarker: stderrKillMarker,
                markerKillDelay: markerKillDelay
            )
        } catch let error as ChildProcessError {
            // `abandoned` — пайпы не отдали EOF до бюджета: write-концы держит
            // переживший скрипт процесс (daemonизированный wireguard-go
            // наследует stdout/stderr wg-quick). Для `up` это может быть
            // успешный запуск, убитый по таймауту уже ПОСЛЕ настройки, —
            // решает проба живого туннеля, для остальных — честный timedOut.
            if case .abandoned = error, let probeName, tunnelUpProbe(probeName) {
                return
            }
            throw Self.translate(error)
        }

        // Ветка маркера (только `up`): маркер печатается ДО PostUp-хуков и
        // снятия teardown-трапа (cmd_up wg-quick: monitor_daemon →
        // execute_hooks POST_UP → trap -) — он обещает «настройка до PostUp
        // завершена», но не «wg-quick завершился успешно». Успех: убитый
        // нами скрипт (wait-ветка, смерть от сигнала) либо самостоятельный
        // exit 0; самостоятельный ненулевой exit — set -e провалил PostUp-хук,
        // teardown-трап разобрал туннель — честный failed, а не скрытый ok
        // (раннер отдаёт сюда снапшот stderr — деталь с текстом провала
        // хука доезжает до лога демона, единственного канала диагностики).
        // Граница честности — upMonitorKillDelay: провалившийся позже паузы
        // хук ненаблюдаем вовсе (скрипт убит посреди хука, хук-сирота жив,
        // его провал и teardown остаются за кадром) — конечный бюджет ответа
        // против неограниченных хуков, подробности у константы.
        // Гонку «TERM op-таймаута раньше нашего KILL» (маркер в последнюю
        // секунду бюджета) отдаём timeout-ветке ниже — судьбу решает проба.
        if result.stderrMarkerSeen, !result.timedOut {
            if result.terminationReason == .uncaughtSignal || result.terminationStatus == 0 {
                return
            }
            throw WGQuickExecutorError.failed(Self.detail(from: result))
        }

        if result.timedOut, result.terminationStatus != 0 || result.stderrMarkerSeen {
            // Убитый по op-таймауту `up` с реально поднятым туннелем
            // (launchd-ветка wg-quick не возвращает управление — запасной
            // путь при дрейфе текста маркера; сюда же и гонка TERM/KILL из
            // ветки маркера — трап мог уже снести туннель и проглотить код
            // выхода, судьбу решает проба). `down` без пробы честно
            // отвечает timedOut: процесс убили МЫ, а не его собственный сбой.
            // Успевший завершиться после TERM exit 0 идёт дальше в classify.
            if let probeName, tunnelUpProbe(probeName) { return }
            throw WGQuickExecutorError.timedOut
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

    /// Классификация дожившего до выхода wg-quick (ветки маркера и
    /// таймаут-латча разобраны в `run`): ненулевой exit — `failed` с хвостом
    /// stderr (лимит — не тащить мегабайты в лог, хвост содержит причину);
    /// нулевой — успех, stdout игнорируется.
    private static func classify(_ result: ChildProcessResult) throws {
        guard result.terminationStatus == 0 else {
            throw WGQuickExecutorError.failed(Self.detail(from: result))
        }
    }

    /// Продакшн-проба «туннель реально поднят»: пара
    /// `/var/run/wireguard/<name>.name` + `<utun>.sock` с семантикой
    /// `get_real_interface` самого wg-quick один-в-один: непустой `utun*` в
    /// `.name`; `.sock` существует И является сокетом (`-S`, обычный файл по
    /// этому пути парой не считается); mtime пары расходится меньше чем на
    /// 2 c — пару создаёт wireguard-go одним махом в `add_if`, расхождение
    /// выдаёт пережитки старой (ту же сверку делает и
    /// `WireGuardTunnelNamer`). Честное ограничение: пара рождается в
    /// `add_if` ДО set_config/адресов/маршрутов/DNS — проба доказывает
    /// «интерфейс существует», а не «настройка завершена» (полноту знает
    /// только маркер монитора; проба — деградированный запасной путь, и её
    /// расхождение с реальностью сойдёт ближайшим show-тиком модели).
    /// Инъекция FS — для тестов.
    static func tunnelIsUp(
        name: String,
        runtimeDirectory: String = "/var/run/wireguard",
        fileContents: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) },
        fileAttributes: (String) -> [FileAttributeKey: Any]? = {
            try? FileManager.default.attributesOfItem(atPath: $0)
        }
    ) -> Bool {
        let namePath = "\(runtimeDirectory)/\(name).name"
        guard let raw = fileContents(namePath) else { return false }
        let interface = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // wg-quick пишет в .name реальный интерфейс `utun*`; пустой файл или
        // мусор — туннеля нет.
        guard interface.hasPrefix("utun") else { return false }
        // `-S` из get_real_interface: путь обязан быть сокетом wireguard-go,
        // а не просто существующим файлом.
        guard let sockAttributes = fileAttributes("\(runtimeDirectory)/\(interface).sock"),
              (sockAttributes[.type] as? FileAttributeType) == .typeSocket
        else { return false }
        // mtime-корреляция из get_real_interface (|Δ| < 2 c): отсутствующая
        // пара атрибутов — провал, как у wg-quick (там stat-фолбэки 100/200
        // разводят mtime гарантированно).
        guard let nameAttributes = fileAttributes(namePath),
              let sockModified = sockAttributes[.modificationDate] as? Date,
              let nameModified = nameAttributes[.modificationDate] as? Date,
              abs(sockModified.timeIntervalSince(nameModified)) < 2
        else { return false }
        return true
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
