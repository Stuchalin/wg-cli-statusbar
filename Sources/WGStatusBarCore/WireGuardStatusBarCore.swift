import AppKit
import Combine
import Foundation

/// Запускает `wg show all dump` и возвращает сырой вывод; инжектится для тестов.
public protocol WGShowCommandRunning {
    func runDump() async throws -> String
}

/// Продакшн-раннер: `/bin/zsh -lc "wg show all dump"` (login-shell, чтобы Homebrew's
/// `wg` был на PATH) с таймаутом. Процесс и таймаут инжектятся для тестов раннера.
/// Exit 127 (command not found) → `StatusFailure.wgMissing` — как `err wg-missing`
/// от демона, карточка показывает команды установки. Сырой вывод содержит
/// секреты — не логировать.
public struct ProcessWGShowRunner: WGShowCommandRunning {
    private let executableURL: URL
    private let arguments: [String]
    private let timeout: TimeInterval

    public init(
        executableURL: URL = URL(fileURLWithPath: "/bin/zsh"),
        arguments: [String] = ["-lc", "wg show all dump"],
        timeout: TimeInterval = 5.0
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.timeout = timeout
    }

    public func runDump() async throws -> String {
        let executableURL = self.executableURL
        let arguments = self.arguments
        let timeout = self.timeout
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached {
                do {
                    let output = try Self.runWGShowSync(
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
    }

    private static func runWGShowSync(
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

        // Каналы дренируются параллельно ожиданию: дамп больше буфера пайпа
        // (~64 KiB, ~200+ пиров) блокирует запись процесса — waitUntilExit без
        // чтения висел бы до таймаута вместо данных.
        var outputData = Data()
        var errorData = Data()
        let drainQueue = DispatchQueue(label: "com.wgstatusbar.runwgshow.drain", attributes: .concurrent)
        let drained = DispatchGroup()

        let stateQueue = DispatchQueue(label: "com.wgstatusbar.runwgshow.state")
        var timedOut = false
        var exited = false

        try process.run()

        // Дренирование стартует только после успешного запуска: при броске run()
        // write-концы пайпов остаются открытыми у нас, и readDataToEndOfFile
        // не получил бы EOF — читатели висели бы вечно (утечка потоков и FD).
        // Ребёнку за микросекунды между run() и стартом чтения не заполнить
        // буфер пайпа — он ещё должен успеть exec.
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
                // kill вместо terminate(): между проверкой isRunning и сигналом
                // процесс может успеть завершиться — kill несуществующему pid
                // просто вернёт ошибку, гонка безвредна.
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

        // Латч timedOut ставится в гонке на границе дедлайна (`isRunning`
        // отстаёт от фактического выхода процесса): процесс, завершившийся
        // успешно уже после срабатывания дедлайна, отдаёт данные, а не таймаут.
        // Убитый сигналом или завершившийся с ошибкой при сработавшем
        // дедлайне — таймаут.
        if stateQueue.sync(execute: { timedOut }), process.terminationStatus != 0 {
            throw StatusFailure.commandTimeout
        }

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorText = String(data: errorData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            // 127 — command not found: wg нет на PATH. Типизированная ошибка
            // приоритетнее текста stderr («zsh: command not found: wg» бесполезен
            // в карточке — ей нужны команды установки, Task 9).
            if process.terminationStatus == 127 {
                throw StatusFailure.wgMissing
            }
            if errorText.isEmpty {
                throw NSError(
                    domain: "WGStatusBar",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: L10n.string("error.wg_show_failed", String(process.terminationStatus))]
                )
            }
            throw NSError(
                domain: "WGStatusBar",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: errorText.trimmingCharacters(in: .whitespacesAndNewlines)]
            )
        }

        return output
    }
}

/// Именование туннелей для модели; инжектится для тестов (моки со счётчиками).
public protocol WireGuardTunnelNaming: AnyObject {
    func displayName(for interfaceName: String) -> String
    func rescan()
}

extension WireGuardTunnelNamer: WireGuardTunnelNaming {}

public final class WireGuardStatusModel: ObservableObject {
    @Published public private(set) var interfaces: [WGInterface] = []
    @Published public private(set) var isLoading = false
    /// Типизированная ошибка последнего тика; живёт один refresh-цикл.
    @Published public private(set) var lastFailure: StatusFailure?
    /// Состояние сервиса демона, выведено из фактов последнего тика
    /// (сокет-файл + исход обмена) — не хранится, пересчитывается на каждом
    /// refresh. Управляет пунктом меню установки/обновления/удаления сервиса.
    @Published public private(set) var serviceState: ServiceState = .absent
    /// Туннели из конфигов wg-quick (демон, `list`): имена + выведенный isUp.
    /// Данные меню — оппортунистические: ошибки `loadTunnels()` глотаются,
    /// статус карточки от них не зависит.
    @Published public private(set) var tunnels: [TunnelInfo] = []
    /// Имена туннелей с операцией в полёте (наличие имени = in-flight): строки
    /// меню некликабельны, show-тик подавлен, снапшот не устаревает.
    /// Отдельного состояния «failed» нет — ошибку несёт существующий one-tick
    /// `lastFailure`.
    @Published public private(set) var inFlightTunnels: Set<String> = []

    private let commandRunner: WGShowCommandRunning
    private let tunnelNamer: WireGuardTunnelNaming
    /// Туннельные операции демона (продакшн — `SocketTunnelClient`; мок —
    /// в тестах модели).
    private let tunnelCommandRunner: TunnelCommandRunning
    /// Probe сокета демона на каждом refresh: файл есть → работаем через
    /// демон, нет → фолбэк (продакшн — процессный раннер, dev/sudo).
    private let socketExists: () -> Bool
    private let socketPath: String
    private var timer: Timer?
    private let refreshInterval: TimeInterval = 5
    /// Срок жизни снапшота: данные последнего успешного тика старше лимита —
    /// устаревшие (иконка гаснет, карточка приглушает). Больше refreshInterval,
    /// чтобы одиночный сбой не мигал иконкой.
    private let stalenessLimit: TimeInterval = 10
    /// Часы, инжектятся тестами (сценарии «успех → сбой → успех» без ожидания).
    private let now: () -> Date
    /// Момент последнего успешного тика (из `now()`); nil — успеха ещё не было.
    private var lastSuccessAt: Date?
    /// Номер текущего refresh; завершения старых поколений отбрасываются.
    private var refreshGeneration = 0

    public convenience init() {
        self.init(
            commandRunner: ProcessWGShowRunner(),
            tunnelNamer: WireGuardTunnelNamer(),
            socketExists: { FileManager.default.fileExists(atPath: helperSocketPath) },
            socketPath: helperSocketPath
        )
        refresh()
        startTimer()
    }

    internal convenience init(testing interfaces: [WGInterface]) {
        self.init(
            commandRunner: ProcessWGShowRunner(),
            tunnelNamer: WireGuardTunnelNamer(),
            socketExists: { false },
            socketPath: helperSocketPath
        )
        self.interfaces = interfaces
    }

    /// Перегрузка для существующих refresh-тестов: probe всегда false,
    /// дефолтный путь — сокетный путь не активируется.
    internal convenience init(commandRunner: WGShowCommandRunning, tunnelNamer: WireGuardTunnelNaming) {
        self.init(
            commandRunner: commandRunner,
            tunnelNamer: tunnelNamer,
            socketExists: { false },
            socketPath: helperSocketPath
        )
    }

    /// Полный init: свой probe сокета и путь — тесты состояния инжектируют
    /// мутабельный флаг и tmp-сокет; часы — фейковые часы тестов устарелости;
    /// туннельный клиент — мок туннельных тестов.
    internal init(
        commandRunner: WGShowCommandRunning,
        tunnelNamer: WireGuardTunnelNaming,
        socketExists: @escaping () -> Bool,
        socketPath: String,
        now: @escaping () -> Date = Date.init,
        tunnelCommandRunner: TunnelCommandRunning = SocketTunnelClient()
    ) {
        self.commandRunner = commandRunner
        self.tunnelNamer = tunnelNamer
        self.socketExists = socketExists
        self.socketPath = socketPath
        self.now = now
        self.tunnelCommandRunner = tunnelCommandRunner
    }

    deinit {
        timer?.invalidate()
    }

    /// Хотя бы один интерфейс подключён — правда по данным, безотносительно
    /// свежести снапшота.
    public var isAnyConnected: Bool {
        interfaces.contains(where: \.isConnected)
    }

    /// Данные устарели: снапшот непуст и последнему успешному тику прошло
    /// больше `stalenessLimit` (или успешных тиков не было — в продакшене
    /// недостижимо, `interfaces` пишет только успешный тик). Пустые данные —
    /// не устаревшие (нечему).
    ///
    /// Операция над туннелем в полёте — не устаревшие при любом прошедшем
    /// времени: show-тик подавлен, `lastSuccessAt` не обновляется, а худший
    /// случай очереди демона (13 c) переживает лимит (10 c) — без этого
    /// иконка гасла бы и карточка приглушалась посреди живой операции.
    public var isDataStale: Bool {
        guard !interfaces.isEmpty else { return false }
        guard inFlightTunnels.isEmpty else { return false }
        guard let lastSuccessAt else { return true }
        return now().timeIntervalSince(lastSuccessAt) > stalenessLimit
    }

    /// Состояние иконки/VoiceOver: подключён И данные не устарели — замороженный
    /// снапшот при потере источника не должен показывать «живой» щиток.
    public var showsConnected: Bool {
        isAnyConnected && !isDataStale
    }

    /// Строка ошибки для карточки, вычисляется из `lastFailure`; тип `String?`
    /// сохранён — `StatusCardView` читает её без правок. Обновления едут через
    /// `objectWillChange` от `lastFailure`, сеттера нет.
    public var lastError: String? {
        lastFailure?.localizedMessage
    }

    /// Любая ошибка раннера → `StatusFailure`: типизированные (сокет-раннер,
    /// таймаут и exit 127 фолбэка) проходят как есть, чужие (сбой запуска
    /// процессного раннера) заворачиваются в `.generic` с их текстом —
    /// поведение строки ошибки не меняется.
    private static func failure(from error: Error) -> StatusFailure {
        error as? StatusFailure ?? .generic(error.localizedDescription)
    }

    /// Тайтл для VoiceOver: как и иконка, от `showsConnected` — устаревший
    /// снапшот не озвучивается как «подключено».
    public var menuTitle: String {
        showsConnected ? L10n.string("menu.title.on") : L10n.string("menu.title.off")
    }

    /// `forceNameRescan` — принудительный рескан имён туннелей (кнопка «Обновить»);
    /// обычный тик ресканит лениво и только встретив незнакомый utun.
    public func refresh(forceNameRescan: Bool = false) {
        // Туннельная операция в полёте: show-тик пропускается целиком — без
        // выставления ошибки, без смены serviceState (демон занят op-бюджетом
        // до 9 c, а его accept-loop последовательен: queued show молчал бы до
        // клиентского дедлайна и выводился бы в broken) и без стирания
        // lastFailure. Триггер «после ответа up/down» вернёт данные сам.
        guard inFlightTunnels.isEmpty else { return }
        // Тик таймера или ⌘R могут стартовать refresh поверх ещё не завершившегося
        // (команда с 5-секундным таймаутом): применяем только результат последнего,
        // чтобы старый снапшот/ошибка не перезаписали свежие данные.
        refreshGeneration += 1
        let generation = refreshGeneration
        isLoading = true
        lastFailure = nil

        // Выбор раннера из фактов на каждом тике: сокет демона есть →
        // SocketWGShowRunner; нет → инжектированный фолбэк (продакшн —
        // ProcessWGShowRunner, dev-режим под sudo). Факт фиксируется до
        // запуска — тем же фактом по завершении выводится состояние сервиса.
        let socketPresent = socketExists()
        let runner: WGShowCommandRunning = socketPresent
            ? SocketWGShowRunner(socketPath: socketPath)
            : commandRunner
        let namer = tunnelNamer
        Task.detached {
            do {
                let output = try await runner.runDump()
                let parsed = Self.resolveDisplayNames(
                    for: parseWGShowDump(output),
                    namer: namer,
                    forcingRescan: forceNameRescan
                )
                await MainActor.run { [weak self] in
                    guard let self, generation == self.refreshGeneration else { return }
                    self.interfaces = parsed
                    self.recomputeTunnelStates()
                    self.lastSuccessAt = self.now()
                    self.isLoading = false
                    self.serviceState = ServiceState.derive(socketFileExists: socketPresent, outcome: .success(output))
                }
            } catch {
                let failure = Self.failure(from: error)
                await MainActor.run { [weak self] in
                    guard let self, generation == self.refreshGeneration else { return }
                    self.lastFailure = failure
                    self.isLoading = false
                    self.serviceState = ServiceState.derive(socketFileExists: socketPresent, outcome: .failure(failure))
                }
            }
        }
    }

    /// Проставляет интерфейсам `displayName` из namer'а.
    ///
    /// Незнакомый utun после первого прохода — единственный исключительный
    /// `rescan()` за refresh (между тиками мог подняться новый конфиг wg-quick),
    /// затем повторный резолв только ещё неизвестных имён. При принудительном
    /// рескане второго не нужно — каталог только что перечитан.
    private static func resolveDisplayNames(
        for interfaces: [WGInterface],
        namer: WireGuardTunnelNaming,
        forcingRescan: Bool
    ) -> [WGInterface] {
        if forcingRescan {
            namer.rescan()
        }

        var resolved = interfaces
        var hasUnknownName = false
        for index in resolved.indices {
            let displayName = namer.displayName(for: resolved[index].name)
            hasUnknownName = hasUnknownName || displayName == resolved[index].name
            resolved[index].displayName = displayName
        }

        if hasUnknownName && !forcingRescan {
            namer.rescan()
            for index in resolved.indices where resolved[index].displayName == resolved[index].name {
                resolved[index].displayName = namer.displayName(for: resolved[index].name)
            }
        }

        return resolved
    }

    public func openWireGuardConfigFolder() {
        let candidateFolders: [URL] = [
            URL(fileURLWithPath: "/usr/local/etc/wireguard"),
            URL(fileURLWithPath: "/etc/wireguard"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library")
                .appendingPathComponent("Application Support")
                .appendingPathComponent("wireguard")
        ]

        for path in candidateFolders {
            if FileManager.default.fileExists(atPath: path.path) {
                NSWorkspace.shared.open(path)
                return
            }
        }
        lastFailure = .generic(L10n.string("error.config_folder_not_found"))
    }

    /// Ошибка установки/удаления сервиса демона (stderr скрипта или сбой
    /// запуска osascript): текст — в ошибку карточки на один тик, следующий
    /// refresh сотрёт. Привязывается к `InstallerService.onFailure` в AppDelegate.
    public func reportServiceFailure(_ message: String) {
        lastFailure = .generic(message)
    }

    // MARK: - Туннели

    /// Туннель поднят ⟺ какой-то интерфейс снапшота носит его имя: namer
    /// резолвит `utunN` → имя конфига wg-quick в `displayName`, а единственный
    /// источник правды о состоянии — `wg show`.
    ///
    /// Честная оговорка: при нерезолве namer'а (displayName остался `utunN` —
    /// `.name`-файл потерян или интерфейс поднят вне wg-quick) строка
    /// показывает «выключен», а клик up приносит err от wg-quick («interface
    /// already exists») — карточка покажет общую ошибку операции (деталь на
    /// wire не приходит). Расхождение живёт, пока туннель не пересоздадут:
    /// самоизлечения нет.
    public func isTunnelUp(named name: String) -> Bool {
        interfaces.contains { $0.displayName == name }
    }

    /// Подтягивает список туннелей демона (`list` → имена; isUp выводится из
    /// текущего снапшота). Триггеры: открытие меню, ответ up/down, переход
    /// serviceState при открытом меню — НЕ 5-секундный тик. Ошибки глотаются
    /// молча: данные меню оппортунистические, не источник статуса (иначе
    /// dev-фолбэк без демона получал бы ложную ошибку на карточке). До
    /// `.installed` демон не дёргается вовсе: у старого build `list` —
    /// unknown command.
    public func loadTunnels() {
        guard serviceState == .installed else { return }
        let client = tunnelCommandRunner
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let names = try await client.list()
                let updated = names.map { TunnelInfo(name: $0, isUp: self.isTunnelUp(named: $0)) }
                // Без изменений — без republish (как recomputeTunnelStates):
                // идентичный список не должен пересобирать открытое меню.
                if updated != self.tunnels {
                    self.tunnels = updated
                }
            } catch {
                // Молча: список конфигов — не источник статуса.
            }
        }
    }

    /// Клик по строке туннеля: направление — из `isTunnelUp`, операция — через
    /// демон. Пока имя в `inFlightTunnels`, show-тик подавлен и снапшот не
    /// устаревает. Успех → немедленный `refresh()` + `loadTunnels()`;
    /// провал → one-tick `lastFailure` + `loadTunnels()` БЕЗ refresh — пролог
    /// `refresh()` стирает `lastFailure` синхронно, ошибка не отрисовалась бы
    /// вовсе; данные сойдёт следующий 5-с тик (прецедент: провал установки
    /// сервиса — one-tick error без refresh).
    public func toggleTunnel(named name: String) {
        // Одна операция за раз — не только по имени: бюджет худшего случая
        // очереди демона (show 4 c + операция 9 c, закреплён тестом) верен
        // ровно для одной операции; клик до того, как строки ушли в disabled
        // (ре-ренд SwiftUI асинхронен), — молчаливый no-op.
        guard inFlightTunnels.isEmpty else { return }
        let shouldTearDown = isTunnelUp(named: name)
        inFlightTunnels.insert(name)
        let client = tunnelCommandRunner
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if shouldTearDown {
                    try await client.down(name)
                } else {
                    try await client.up(name)
                }
                self.inFlightTunnels.remove(name)
                self.refresh()
                self.loadTunnels()
            } catch {
                self.inFlightTunnels.remove(name)
                self.lastFailure = Self.failure(from: error)
                self.loadTunnels()
            }
        }
    }

    /// isUp строк пересчитывается из свежего снапшота после каждого успешного
    /// тика (`list` отдаёт только имена). Без изменений — без republish.
    private func recomputeTunnelStates() {
        guard !tunnels.isEmpty else { return }
        let updated = tunnels.map { TunnelInfo(name: $0.name, isUp: isTunnelUp(named: $0.name)) }
        if updated != tunnels {
            tunnels = updated
        }
    }

    private func startTimer() {
        // .common, а не дефолтный режим run loop: пока открыто меню NSStatusItem,
        // главный run loop работает в NSEventTrackingRunLoopMode и таймер из
        // scheduledTimer стоит — карточка замирала бы на всё время открытого меню.
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}

enum L10n {
    // In an .app the resource bundle is copied to Contents/Resources —
    // the standard location and the only one codesign accepts (files in the
    // .app root make it "unsealed"). The generated Bundle.module accessor
    // looks in the .app root instead, so it only works for bare-binary dev
    // runs and stays as the fallback.
    private static let bundle: Bundle = {
        let standard = Bundle.main.resourceURL?
            .appendingPathComponent("WGStatusBar_WGStatusBarCore.bundle")
        return standard.flatMap(Bundle.init(url:)) ?? .module
    }()

    static func string(_ key: String, _ args: String...) -> String {
        let raw = NSLocalizedString(key, tableName: "Localizable", bundle: bundle, comment: "")
        if args.isEmpty {
            return raw
        }
        return String(format: raw, arguments: args)
    }
}
