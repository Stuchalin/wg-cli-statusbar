import XCTest
@testable import WGStatusBarCore

/// Продакшн-исполнитель wg-quick против короткоживущих стабов. Стаб —
/// исполняемый скрипт с zsh-shebang, резолвимый инъекцией `searchPaths`
/// (стаб-путь — единственный кандидат, по образцу `WGShowExecutorTests`);
/// аргументы НЕ инжектируются — они литеральные `["up"|"down", name]`, как
/// в продакшне, поэтому стаб читает `$1`/`$2`. Отдельно пинируется инъекция
/// PATH (главный продакшн-провал: под launchd у демона нет Homebrew в PATH,
/// и wg-quick гибнет на системном bash 3.2 — юнит-стабы без PATH-теста
/// проходят зелёными при мёртвой фиче) и launchd-поведение `up`: успешный
/// `up` darwin wg-quick не завершается сам (`wait` до смерти туннеля) —
/// успех определяется маркером монитора в stderr (быстрый путь) или пробой
/// `/var/run/wireguard` после таймаута; держатель пайпов (выживший ребёнок
/// wg-quick) не клинит возврат.
final class WGQuickExecutorTests: XCTestCase {
    /// Пишет исполняемый стаб-скрипт с zsh-shebang и возвращает его путь.
    private func makeStub(script: String) throws -> String {
        let path = NSTemporaryDirectory().appending("wgstatusbar-wgquick-\(UUID().uuidString)")
        try "#!/bin/zsh\n\(script)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    private func makeExecutor(
        binaryPath: String,
        binaryExists: Bool = true,
        timeout: TimeInterval = 5,
        killGrace: TimeInterval = 2,
        tunnelUpProbe: @escaping (String) -> Bool = { _ in false }
    ) -> WGQuickExecutor {
        WGQuickExecutor(
            resolver: WGQuickResolver(
                searchPaths: [binaryPath],
                fileExists: { _ in binaryExists }
            ),
            timeout: timeout,
            killGrace: killGrace,
            tunnelUpProbe: tunnelUpProbe
        )
    }

    // MARK: - happy path и литеральные аргументы

    func testExitZeroSucceedsPassingLiteralUpAndName() async throws {
        // Стаб пишет свои аргументы в маркер: исполнитель обязан запускать
        // стаб ровно с `up <name>` — литеральные аргументы, как в продакшне.
        let marker = NSTemporaryDirectory().appending("wgstatusbar-wgquick-args-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: marker) }
        let stub = try makeStub(script: "printf '%s %s' \"$1\" \"$2\" > \(marker); exit 0")
        let executor = makeExecutor(binaryPath: stub)

        try await executor.runUp(name: "work-vpn")

        let recorded = try String(contentsOfFile: marker, encoding: .utf8)
        XCTAssertEqual(recorded, "up work-vpn", "стаб получает литеральные [up, name]")
    }

    func testExitZeroSucceedsPassingLiteralDownAndName() async throws {
        let marker = NSTemporaryDirectory().appending("wgstatusbar-wgquick-args-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: marker) }
        let stub = try makeStub(script: "printf '%s %s' \"$1\" \"$2\" > \(marker); exit 0")
        let executor = makeExecutor(binaryPath: stub)

        try await executor.runDown(name: "kvmka-full")

        let recorded = try String(contentsOfFile: marker, encoding: .utf8)
        XCTAssertEqual(recorded, "down kvmka-full", "стаб получает литеральные [down, name]")
    }

    // MARK: - ненулевой exit

    func testNonZeroExitWithStderrCarriesStderrDetail() async throws {
        let stub = try makeStub(script: "echo boom 1>&2; exit 4")
        let executor = makeExecutor(binaryPath: stub)

        do {
            try await executor.runUp(name: "work-vpn")
            XCTFail("ненулевой exit должен давать ошибку")
        } catch {
            XCTAssertEqual(error as? WGQuickExecutorError, .failed("boom"))
        }
    }

    func testNonZeroExitWithoutStderrUsesStatusCodeDetail() async throws {
        let stub = try makeStub(script: "exit 3")
        let executor = makeExecutor(binaryPath: stub)

        do {
            try await executor.runDown(name: "work-vpn")
            XCTFail("ненулевой exit должен давать ошибку")
        } catch {
            XCTAssertEqual(error as? WGQuickExecutorError, .failed("exit status 3"))
        }
    }

    func testLongStderrDetailIsTruncatedToTail() async throws {
        // Деталь `.failed` — хвост stderr (~300 символов): хвост содержит
        // причину сбоя, лимит не тащит мегабайты выхлопа wg-quick в лог демона.
        let stub = try makeStub(script: "printf 'x%.0s' {1..1700} 1>&2; printf 'TAIL' 1>&2; exit 1")
        let executor = makeExecutor(binaryPath: stub)

        do {
            try await executor.runUp(name: "work-vpn")
            XCTFail("ненулевой exit должен давать ошибку")
        } catch {
            guard case .failed(let detail) = error as? WGQuickExecutorError else {
                return XCTFail("ожидался failed, получено: \(error)")
            }
            XCTAssertEqual(detail.count, 300, "деталь обрезана до лимита")
            XCTAssertTrue(detail.hasSuffix("TAIL"), "деталь — хвост stderr, а не начало")
        }
    }

    // MARK: - таймаут

    func testTimeoutThrowsAndKillsHangingProcess() async throws {
        // Стаб записывает свой pid и засыпает: по op-таймауту процесс обязан
        // быть убит, иначе демон держал бы висяк в accept-loop. Таймаут — с
        // запасом поверх старта zsh с замещённым окружением (~0.5 с до первой
        // строки скрипта: без полного env старт шелла небыстрый): TERM обязан
        // приходить уже выполняющему sleep стабу, а не стартующему шеллу.
        let pidFile = NSTemporaryDirectory().appending("wgstatusbar-wgquick-pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: pidFile) }
        let stub = try makeStub(
            script: "printf '%s\\n' $$ > \(pidFile); sleep 30"
        )
        let executor = makeExecutor(binaryPath: stub, timeout: 1.5)

        do {
            try await executor.runUp(name: "work-vpn")
            XCTFail("зависший процесс должен падать по таймауту")
        } catch {
            XCTAssertEqual(error as? WGQuickExecutorError, .timedOut)
        }

        let pidData = try String(contentsOfFile: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(pidData), "стаб должен записать свой pid")
        XCTAssertTrue(
            Self.waitUntilProcessDies(pid, within: 3),
            "процесс \(pid) должен быть убит по таймауту, таймаут живёт в исполнителе"
        )
    }

    func testTimeoutEscalatesToSigkillWhenChildIgnoresTerm() async throws {
        // Стаб игнорирует SIGTERM: через killGrace следует SIGKILL — иначе
        // TERM-игнорирующий wg-quick подвешивал бы accept-loop демона.
        let pidFile = NSTemporaryDirectory().appending("wgstatusbar-wgquick-termtrap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: pidFile) }
        let stub = try makeStub(
            script: "trap '' TERM; printf '%s\\n' $$ > \(pidFile); sleep 30"
        )
        let executor = makeExecutor(binaryPath: stub, timeout: 1.5, killGrace: 0.5)

        do {
            try await executor.runDown(name: "work-vpn")
            XCTFail("игнорирующий TERM процесс должен погибнуть по таймауту")
        } catch {
            XCTAssertEqual(error as? WGQuickExecutorError, .timedOut)
        }

        let pidData = try String(contentsOfFile: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(pidData), "стаб должен записать свой pid")
        XCTAssertTrue(
            Self.waitUntilProcessDies(pid, within: 3),
            "процесс \(pid) должен быть убит SIGKILL после игнорирования TERM"
        )
    }

    func testUpGracefulExitZeroAfterTermSucceedsWithoutProbe() async throws {
        // Успевший завершиться после TERM exit 0 (аккуратный wg-quick с
        // trap'ом) — это собственное честное завершение, а не наш SIGKILL:
        // исход уходит в classify и отвечает ok, проба не консультируется.
        // Стаб крутит собственный цикл шелла, а не внешний sleep: POSIX-шеллы
        // (и zsh) откладывают trap до конца текущей внешней команды — со
        // `sleep 30` trap не успевает до нашего SIGKILL, и ветка недостижима.
        var probeCount = 0
        let stub = try makeStub(script: "trap 'exit 0' TERM; while :; do :; done")
        let executor = makeExecutor(
            binaryPath: stub,
            timeout: 1.5,
            killGrace: 0.5,
            tunnelUpProbe: { _ in probeCount += 1; return false }
        )

        try await executor.runUp(name: "work-vpn")

        XCTAssertEqual(probeCount, 0, "exit 0 после TERM — успех classify, проба не нужна")
    }

    func testUpMarkerAndTimeoutRaceFallsThroughToProbe() async throws {
        // Гонка «TERM op-таймаута раньше нашего marker-KILL» (маркер в
        // последнюю секунду бюджета): маркер-ветка исход не забирает
        // (timedOut-латч стоит), а в timeout-ветке судьбу решает проба —
        // TERM-трап wg-quick мог уже снести туннель, сам по себе exit 0
        // ничего не доказывает. Проба видит туннель мёртвым → честный
        // timedOut. Статус здесь ровно 0 (trap срабатывает в собственном
        // цикле шелла, не в ожидании внешней команды — со `sleep` trap
        // отложился бы за наш SIGKILL): исход держится ТОЛЬКО дизъюнктом
        // `stderrMarkerSeen` — без него classify ответил бы ложный ok.
        var probeCount = 0
        let stub = try makeStub(
            script: """
            sleep 0.5
            printf '%s\\n' '\(WGQuickExecutor.upMonitorMarker)' 1>&2
            trap 'exit 0' TERM
            while :; do :; done
            """
        )
        let executor = makeExecutor(
            binaryPath: stub,
            timeout: 1.5,
            killGrace: 0.5,
            tunnelUpProbe: { _ in probeCount += 1; return false }
        )

        do {
            try await executor.runUp(name: "work-vpn")
            XCTFail("гонка маркер/TERM с мёртвым туннелем — честный timedOut, не ok")
        } catch {
            XCTAssertEqual(error as? WGQuickExecutorError, .timedOut)
        }
        XCTAssertEqual(probeCount, 1, "исход гонки решает проба живого туннеля")
    }

    func testDownTimeoutWithoutPipeHolderStaysTimedOut() async throws {
        // Регрессия классификации: ребёнок умирает от TERM op-таймаута сам,
        // пайпов никто не держит (exec — нет осиротевших детей), drains
        // сходятся — результат приходит путём данных, а не abandoned. Такой
        // `down` обязан отвечать timedOut (процесс убили МЫ), а не
        // `failed("exit status 15")` из classify.
        let stub = try makeStub(script: "exec /bin/sleep 30")
        let executor = makeExecutor(binaryPath: stub, timeout: 1.5, killGrace: 0.5)

        do {
            try await executor.runDown(name: "work-vpn")
            XCTFail("зависший down должен падать по таймауту")
        } catch {
            XCTAssertEqual(error as? WGQuickExecutorError, .timedOut)
        }
    }

    func testDownNeverConsultsProbeOrMarker() async throws {
        // Инвариант анти-копипасты: `down` идёт без маркера и без пробы —
        // `wait` есть только в ветке up, успех down — обычный exit. Регресс
        // в копию runUp (маркер и/или probeName) отвечал бы ok по виснущему
        // стабу при «живой» пробе, пряча провал teardown за ok.
        var probeCount = 0
        let stub = try makeStub(
            script: "printf '%s\\n' '\(WGQuickExecutor.upMonitorMarker)' 1>&2; exec /bin/sleep 30"
        )
        let executor = makeExecutor(
            binaryPath: stub,
            timeout: 1.5,
            killGrace: 0.5,
            tunnelUpProbe: { _ in probeCount += 1; return true }
        )

        do {
            try await executor.runDown(name: "work-vpn")
            XCTFail("зависший down обязан отвечать timedOut даже при «живой» пробе")
        } catch {
            XCTAssertEqual(error as? WGQuickExecutorError, .timedOut)
        }
        XCTAssertEqual(probeCount, 0, "down не консультирует пробу — его запуску её не передают")
    }

    // MARK: - launchd-ветка wg-quick: успешный `up` не завершается сам

    func testUpSucceedsOnMonitorMarkerAndKillsHangingScript() async throws {
        // Продакшн-поведение darwin wg-quick под root: `detect_launchd`
        // находит `domain =` в `launchctl procinfo` и финальный `wait` держит
        // скрипт живым, пока жив туннель (проверено на живой машине: скрипт
        // висит сутками). Стаб имитирует это: печатает маркер монитора в
        // stderr и засыпает. Исполнитель обязан увидеть маркер, добить скрипт
        // и ответить успехом СРАЗУ — не по op-таймауту и не зависнув вовсе.
        // Убийство сигналом подтверждается пробой живого туннеля (туннель
        // реально поднят — стаб висит в wait) — без пробы ok был бы слепым.
        let pidFile = NSTemporaryDirectory().appending("wgstatusbar-wgquick-marker-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: pidFile) }
        let stub = try makeStub(
            script: "printf '%s\\n' $$ > \(pidFile); printf '%s\\n' '\(WGQuickExecutor.upMonitorMarker)' 1>&2; sleep 30"
        )
        var probeCount = 0
        let executor = makeExecutor(binaryPath: stub, tunnelUpProbe: { _ in probeCount += 1; return true })

        let started = Date()
        try await executor.runUp(name: "work-vpn")
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(probeCount, 1, "ok по marker-KILL подтверждается пробой живого туннеля")

        XCTAssertLessThan(
            elapsed,
            4,
            "успех по маркеру приходит за ~старт zsh + задержка KILL (~2 c), а не по таймауту 5 c"
        )

        let pidData = try String(contentsOfFile: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(pidData), "стаб должен записать свой pid")
        XCTAssertTrue(
            Self.waitUntilProcessDies(pid, within: 3),
            "скрипт \(pid) обязан быть добит SIGKILL после маркера — иначе висит в wait вечно"
        )
    }

    func testUpMarkerFollowedByNonZeroExitFailsWithStderrDetail() async throws {
        // Маркер печатается ДО PostUp-хуков wg-quick (cmd_up: monitor_daemon
        // → execute_hooks POST_UP), teardown-трап в этот момент ещё стоит:
        // под set -e сорвавшийся PostUp роняет скрипт, трап разбирает туннель,
        // exit ненулевой. Такой самостоятельный ненулевой exit — честный
        // провал, а не «успех по маркеру». Стаб печатает маркер, спит
        // (гарантирует, что drain-таск зафиксирует маркер до выхода), печатает
        // строку провала хука и выходит с кодом 4 — раньше, чем наш KILL по
        // задержке (мёртвому процессу сигнал не нужен). Деталь обязана нести
        // текст провала из stderr: на wire она не идёт, лог демона —
        // единственный канал диагностики, «exit status 4» причину не называет.
        let stub = try makeStub(
            script: "printf '%s\\n' '\(WGQuickExecutor.upMonitorMarker)' 1>&2; sleep 0.3; printf 'postup hook failed\\n' 1>&2; exit 4"
        )
        let executor = makeExecutor(binaryPath: stub)

        do {
            try await executor.runUp(name: "work-vpn")
            XCTFail("маркер + самостоятельный ненулевой exit — провал wg-quick")
        } catch {
            guard case .failed(let detail) = error as? WGQuickExecutorError else {
                return XCTFail("ожидался failed, получено: \(error)")
            }
            XCTAssertTrue(
                detail.contains("postup hook failed"),
                "деталь обязана нести stderr провала, а не только код выхода: <\(detail)>"
            )
        }
    }

    func testUpMarkerSelfExitFailureWithPipeHolderStillCarriesStderrDetail() async throws {
        // Провал после маркера при живом держателе write-конца stderr
        // (продакшн-форма: daemonизированный wireguard-go наследует пайпы
        // wg-quick, EOF не приходит и после смерти скрипта): раннер не виснет
        // и не уходит в abandoned — короткий grace дочитывает уже записанное
        // в пайп, деталь провала доезжает до лога демона по снапшоту.
        let stub = try makeStub(
            script: """
            sleep 5 &
            printf '%s\\n' '\(WGQuickExecutor.upMonitorMarker)' 1>&2
            sleep 0.3
            printf 'postup hook failed\\n' 1>&2
            exit 4
            """
        )
        let executor = makeExecutor(binaryPath: stub)

        let started = Date()
        do {
            try await executor.runUp(name: "work-vpn")
            XCTFail("маркер + ненулевой exit при держателе пайпа — провал wg-quick")
        } catch {
            guard case .failed(let detail) = error as? WGQuickExecutorError else {
                return XCTFail("ожидался failed, получено: \(error)")
            }
            XCTAssertTrue(
                detail.contains("postup hook failed"),
                "деталь обязана нести stderr провала и без EOF пайпа: <\(detail)>"
            )
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(started),
            4.5,
            "возврат ограничен grace дочитывания (~старт zsh + 0.3 c + 0.5 c), а не смертью держателя (5 c) и не бюджетом (9 c)"
        )
    }

    func testUpMarkerFollowedBySelfExitZeroSucceeds() async throws {
        // Будущий wg-quick без launchd-`wait`, завершающийся сам после
        // маркера с нулём, — это успех: маркер-ветка чтит самостоятельный
        // exit 0 наравне с убийством зависшего скрипта. Стаб выходит раньше
        // KILL-задержки (мёртвому процессу сигнал не нужен).
        let stub = try makeStub(
            script: "printf '%s\\n' '\(WGQuickExecutor.upMonitorMarker)' 1>&2; sleep 0.3; exit 0"
        )
        let executor = makeExecutor(binaryPath: stub)

        try await executor.runUp(name: "work-vpn")
    }

    func testUpPostUpHookSlowerThanKillGraceReturnsOk() async throws {
        // Обратная сторона grace-окна upMonitorKillDelay: PostUp-хук медленнее
        // паузы убивается вместе со скриптом ДО своего ненулевого exit —
        // ответ ok (туннель жив — хук осиротел, не провалился; проба
        // подтверждает), поздний провал осиротевшего хука ненаблюдаем по
        // дизайну (бюджет ответа демона конечен, хуки — нет; полный разбор —
        // у константы upMonitorKillDelay). Sleep здесь всегда на 1.5 с дольше
        // grace: «провал» не успевает выйти сам, KILL приходит посреди хука.
        // Регресс в любую сторону ловится: сломанный marker-KILL даст хуку
        // выйти самому → .failed; выросший grace — тоже (sleep привязан к
        // константе); мёртвая проба — .failed вместо ok.
        let stub = try makeStub(
            script: "printf '%s\\n' '\(WGQuickExecutor.upMonitorMarker)' 1>&2; sleep \(WGQuickExecutor.upMonitorKillDelay + 1.5); exit 4"
        )
        let executor = makeExecutor(binaryPath: stub, tunnelUpProbe: { _ in true })

        try await executor.runUp(name: "work-vpn")
    }

    func testUpMarkerKillWithDeadTunnelFailsHonestly() async throws {
        // Обратная сторона probe-гейта marker-KILL: между маркером и KILL
        // сорвавшийся PostUp успел РАЗОБРАТЬ туннель (set -e → teardown-трап
        // завершился до нашей задержки) — скрипт убит сигналом, но туннеля
        // больше нет, и ok означал бы ложный успех при опущенном туннеле.
        // Мёртвая проба → честный failed с текстовой деталью (stderr здесь не
        // собирается — буферы непрочитаны); карточку сойдёт show-тик.
        let stub = try makeStub(
            script: "printf '%s\\n' '\(WGQuickExecutor.upMonitorMarker)' 1>&2; sleep 30"
        )
        let executor = makeExecutor(binaryPath: stub, tunnelUpProbe: { _ in false })

        let started = Date()
        do {
            try await executor.runUp(name: "work-vpn")
            XCTFail("marker-KILL с мёртвым туннелем — провал, а не ok")
        } catch {
            guard case .failed(let detail) = error as? WGQuickExecutorError else {
                return XCTFail("ожидался failed, получено: \(error)")
            }
            XCTAssertTrue(
                detail.contains("signal"),
                "деталь поясняет убийство сигналом при мёртвой пробе: <\(detail)>"
            )
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(started),
            4,
            "возврат по marker-KILL (~2 c), не по op-таймауту 5 c"
        )
    }

    func testUpMarkerSubstringInsideForeignStderrLineDoesNotTriggerMarkerKill() async throws {
        // Регрессия подстрочной сверки маркера: wg-quick печатает каждый хук
        // в stderr ДО выполнения (`echo "[#] $hook" >&2` из execute_hooks),
        // а PreUp-хуки бегут в cmd_up ДО set_config/адресов/маршрутов/DNS и
        // настоящего маркера — хук, чей текст или вывод несёт подстроку
        // маркера, не изображает завершение настройки: ранний marker-KILL
        // отвечал бы ложным ok на полуподнятом туннеле (голый utun от
        // add_if: без конфига, маршрутов, DNS и монитора). Обе формы
        // подстрочного вхождения — эхо хука `[#] …` и произвольная строка с
        // маркером внутри — обязаны уйти в честный таймаут. Таймаут 3 c
        // больше «маркер + KILL» (~1.5 c) с запасом: при регрессе ok пришёл
        // бы заведомо раньше TERM — тест падает на XCTFail, не флэжит.
        let stub = try makeStub(
            script: """
            printf '%s\\n' '[#] echo "\(WGQuickExecutor.upMonitorMarker)"; sleep 2' 1>&2
            printf 'setup: %s\\n' '\(WGQuickExecutor.upMonitorMarker)' 1>&2
            sleep 30
            """
        )
        let executor = makeExecutor(binaryPath: stub, timeout: 3, killGrace: 0.5)

        do {
            try await executor.runUp(name: "work-vpn")
            XCTFail("подстрока маркера в чужой строке stderr — не сигнал завершения настройки")
        } catch {
            XCTAssertEqual(error as? WGQuickExecutorError, .timedOut)
        }
    }

    func testUpMarkerAfterForeignLinesAndSplitAcrossWritesStillMatches() async throws {
        // Продакшн-форма маркера, а не «единственная строка одним printf»:
        // перед маркером в stderr идут строки-эхо хуков `[#] …`, а drain
        // читает stderr чанками — маркер может разорваться границей чанка
        // (поэтому сверяется весь накопленный буфер, а не последний чанк).
        // Стаб печатает чужую строку, затем маркер двумя порциями с паузой —
        // ok обязан прийти по маркеру (~2 c), а не по таймауту. Проба жива —
        // это успех marker-KILL с реально поднятым туннелем.
        let marker = WGQuickExecutor.upMonitorMarker
        let splitAt = marker.index(marker.startIndex, offsetBy: marker.count / 2)
        let head = String(marker[..<splitAt])
        let tail = String(marker[splitAt...])
        let stub = try makeStub(
            script: """
            printf '%s\\n' '[#] PreUp = echo configuring' 1>&2
            printf '%s' '\(head)' 1>&2
            sleep 0.3
            printf '%s\\n' '\(tail)' 1>&2
            sleep 30
            """
        )
        let executor = makeExecutor(
            binaryPath: stub,
            timeout: 4,
            killGrace: 0.5,
            tunnelUpProbe: { _ in true }
        )

        let started = Date()
        try await executor.runUp(name: "work-vpn")
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(
            elapsed,
            3.5,
            "маркер после чужих строк и разорванный границей чанка обязан давать быстрый ok (~2 c), а не таймаут 4 c"
        )
    }

    func testUpTimeoutWithLiveTunnelProbeSucceeds() async throws {
        // Запасной путь при дрейфе текста маркера в будущих версиях wg-quick:
        // маркер не совпал, op-таймаут убил скрипт уже ПОСЛЕ настройки —
        // проба `/var/run/wireguard/<name>.name` + `<utun>.sock` видит туннель
        // → успех, а не ложный timedOut при реально поднятом туннеле.
        let pidFile = NSTemporaryDirectory().appending("wgstatusbar-wgquick-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: pidFile) }
        let stub = try makeStub(script: "printf '%s\\n' $$ > \(pidFile); sleep 30")
        let executor = makeExecutor(binaryPath: stub, timeout: 1.5, killGrace: 0.5, tunnelUpProbe: { _ in true })

        try await executor.runUp(name: "work-vpn")

        let pidData = try String(contentsOfFile: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(pidData), "стаб должен записать свой pid")
        XCTAssertTrue(Self.waitUntilProcessDies(pid, within: 3), "скрипт \(pid) должен быть убит по таймауту")
    }

    func testUpAbandonedWithLiveTunnelProbeSucceeds() async throws {
        // Самый продакшн-реальный путь fallback при дрейфе текста маркера:
        // дрейф → op-таймаут убил скрипт уже ПОСЛЕ настройки → пережив его
        // daemonизированный wireguard-go держит write-концы пайпов → EOF не
        // приходит до конца бюджета → раннер отдаёт abandoned, и судьбу
        // решает проба живого туннеля: поднят → медленный, но честный ok.
        // (Держатель `sleep 5 &` жив дольше бюджета 1.5 + 2×0.5 = 2.5 c.)
        var probedNames: [String] = []
        let stub = try makeStub(script: "sleep 5 & sleep 30")
        let executor = makeExecutor(
            binaryPath: stub,
            timeout: 1.5,
            killGrace: 0.5,
            tunnelUpProbe: { probedNames.append($0); return true }
        )

        try await executor.runUp(name: "work-vpn")

        XCTAssertEqual(
            probedNames,
            ["work-vpn"],
            "abandoned для up обязан советоваться с пробой живого туннеля и отвечать ok при поднятом"
        )
    }

    func testPipeHoldingSurvivorBoundsExecutorReturn() async throws {
        // Регрессия клина accept-loop: пережив ребёнок процесс (daemonизированный
        // wireguard-go наследует stdout/stderr wg-quick) держит write-концы
        // пайпов — EOF не приходит и после выхода скрипта. Ожидание drains
        // обязано быть ограничено бюджетом (abandoned → timedOut), иначе один
        // такой `up` навсегда клинил бы последовательный цикл демона. Стаб
        // выходит мгновенно, оставив держателя на 5 c — дольше бюджета.
        let stub = try makeStub(script: "sleep 5 & exit 1")
        let executor = makeExecutor(binaryPath: stub, timeout: 1.5, killGrace: 0.5)

        let started = Date()
        do {
            try await executor.runDown(name: "work-vpn")
            XCTFail("ненулевой exit с несходящимися drains обязан давать ошибку")
        } catch {
            XCTAssertEqual(error as? WGQuickExecutorError, .timedOut)
        }
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(
            elapsed,
            4.5,
            "возврат ограничен бюджетом 1.5 + 2×0.5 = 2.5 c, а не смертью держателя пайпа (5 c)"
        )
    }

    // MARK: - отмена задачи

    func testTaskCancellationThrowsCancellationErrorAndKillsChild() async throws {
        // Отмена задачи (shutdown демона — единственный отменяющий туннельные
        // операции: EOF клиента её не даёт) обязана убить ребёнка и бросить
        // CancellationError, а не висеть до op-таймаута. Зеркалит тест
        // отмены WGShowExecutor на проводке исполнителя wg-quick.
        let pidFile = NSTemporaryDirectory().appending("wgstatusbar-wgquick-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: pidFile) }
        let stub = try makeStub(script: "printf '%s\\n' $$ > \(pidFile); sleep 30")
        let executor = makeExecutor(binaryPath: stub, timeout: 30)

        let task = Task.detached(priority: .medium) {
            try await executor.runUp(name: "work-vpn")
        }

        // Замещённое окружение (PATH) стартует zsh-стаб медленнее (~0.5 c до
        // первой строки) — отменяем строго после записи pid, а не по сну.
        let pid = try Self.waitForPidFile(pidFile, within: 5)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("отменённая задача должна бросать")
        } catch {
            XCTAssertTrue(error is CancellationError, "ожидалась CancellationError, получено: \(error)")
        }

        XCTAssertTrue(
            Self.waitUntilProcessDies(pid, within: 3),
            "процесс \(pid) должен быть убит по отмене задачи"
        )
    }

    func testTaskCancellationAfterMarkerStillThrowsCancellation() async throws {
        // Отмена задачи обязана выигрывать и в маркер-ветке раннера: shutdown
        // демона посреди `up` с уже увиденным маркером — «успех по маркеру»
        // адресован никому (фантомный ok в отменённую задачу), бросаем
        // CancellationError. Пауза после pid-файла даёт drain-таске
        // зафиксировать маркер; исход стабилен и без неё (отмена важнее и в
        // data-пути раннера), пауза сужает проверку до целевой ветки.
        let pidFile = NSTemporaryDirectory().appending("wgstatusbar-wgquick-marker-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: pidFile) }
        let stub = try makeStub(
            script: "printf '%s\\n' $$ > \(pidFile); printf '%s\\n' '\(WGQuickExecutor.upMonitorMarker)' 1>&2; sleep 30"
        )
        let executor = makeExecutor(binaryPath: stub, timeout: 30)

        let task = Task.detached(priority: .medium) {
            try await executor.runUp(name: "work-vpn")
        }

        let pid = try Self.waitForPidFile(pidFile, within: 5)
        Thread.sleep(forTimeInterval: 0.6)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("отменённая задача должна бросать")
        } catch {
            XCTAssertTrue(error is CancellationError, "ожидалась CancellationError, получено: \(error)")
        }

        XCTAssertTrue(
            Self.waitUntilProcessDies(pid, within: 3),
            "процесс \(pid) должен быть убит по отмене задачи"
        )
    }

    /// Ждёт pid-файл стаба и возвращает записанный pid (стаб с замещённым
    /// окружением стартует небыстро — слепой сон вместо ожидания флейчит).
    private static func waitForPidFile(_ path: String, within seconds: TimeInterval) throws -> pid_t {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let data = try? String(contentsOfFile: path, encoding: .utf8) {
                let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
                if let pid = Int32(trimmed), pid > 0 {
                    return pid
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw NSError(
            domain: "WGQuickExecutorTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "стаб не записал pid в \(path) за \(seconds) с"]
        )
    }

    // MARK: - резолв

    func testLaunchFailureSurfacesFailedWithoutHanging() async throws {
        // Файл резолвится (fileExists → да), но не исполняем: запуск падает,
        // раннер отдаёт launchFailed, исполнитель переводит в `.failed`
        // (зеркалит testLaunchFailureSurfacesWgFailedWithoutHanging у
        // show-исполнителя). Drains стартуют только после успешного run —
        // возврат мгновенный, без таймаута и без зависания.
        let path = NSTemporaryDirectory().appending("wgstatusbar-wgquick-noexec-\(UUID().uuidString)")
        try "#!/bin/zsh\nexit 0\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let executor = makeExecutor(binaryPath: path)

        let started = Date()
        do {
            try await executor.runUp(name: "work-vpn")
            XCTFail("неисполняемый бинарь — провал запуска")
        } catch {
            guard case .failed = error as? WGQuickExecutorError else {
                return XCTFail("ожидался failed, получено: \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "провал запуска мгновенный, не таймаут")
    }

    func testResolverMissThrowsQuickMissingWithoutLaunchingProcess() async throws {
        // Промах резолвера обязан падать до запуска процесса: стаб трогал бы
        // файл-маркер, если бы его всё же запустили.
        let marker = NSTemporaryDirectory().appending("wgstatusbar-wgquick-miss-\(UUID().uuidString)")
        let stub = try makeStub(script: "touch \(marker); exit 0")
        let executor = makeExecutor(binaryPath: stub, binaryExists: false)

        do {
            try await executor.runUp(name: "work-vpn")
            XCTFail("промах резолвера должен давать quickMissing")
        } catch {
            XCTAssertEqual(error as? WGQuickExecutorError, .quickMissing)
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker),
            "процесс не должен запускаться без резолва бинаря"
        )
    }

    // MARK: - инъекция PATH

    func testChildPathPutsResolverDirectoriesBeforeSystemOnes() {
        // Продакшн-инвариант PATH: директории резолвера впереди системных
        // (brew bash ≥ 4 и `wg` обязаны выигрывать у /usr/bin), системный
        // хвост присутствует, дублей нет.
        let path = WGQuickExecutor.childPath(
            resolverDirectories: wgQuickBinarySearchPaths.map {
                URL(fileURLWithPath: $0).deletingLastPathComponent().path
            }
        )
        XCTAssertEqual(
            path,
            "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "продакшн-PATH ребёнка wg-quick — директории резолвера + системный хвост без дублей"
        )

        let entries = path.split(separator: ":").map(String.init)
        XCTAssertEqual(Set(entries).count, entries.count, "дубликатов путей быть не должно")
        for brew in ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"] {
            XCTAssertLessThan(
                entries.firstIndex(of: brew)!,
                entries.firstIndex(of: "/usr/bin")!,
                "\(brew) обязан идти впереди системных путей"
            )
        }
    }

    func testExecutorInjectsResolverDirectoryAheadOfSystemInChildPATH() async throws {
        // Регрессия главного продакшн-провала: ребёнок обязан получить PATH
        // от исполнителя (директория стаба впереди системных), а не наследовать
        // окружение демона — без инъекции юнит-стабы зелёные, а под launchd
        // wg-quick гибнет на системном bash 3.2 / отсутствии brew в PATH.
        let stubDir = NSTemporaryDirectory().appending("wgstatusbar-wgquick-pathdir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: stubDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: stubDir) }
        let stubPath = stubDir + "/wg-quick"
        let pathFile = stubDir + "/path.txt"
        let stub = FileManager.default.createFile(
            atPath: stubPath,
            contents: Data("#!/bin/zsh\nprintf '%s' \"$PATH\" > \(pathFile)\nexit 0\n".utf8)
        )
        XCTAssertTrue(stub, "стаб обязан быть создан")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubPath)
        let executor = makeExecutor(binaryPath: stubPath)

        try await executor.runUp(name: "work-vpn")

        let childPath = try String(contentsOfFile: pathFile, encoding: .utf8)
        let entries = childPath.split(separator: ":").map(String.init)
        XCTAssertEqual(entries.first, stubDir, "директория резолва обязана быть первой в PATH ребёнка: <\(childPath)>")
        XCTAssertTrue(entries.contains("/usr/bin"), "системные пути обязаны остаться в PATH ребёнка: <\(childPath)>")
        let stubIndex = entries.firstIndex(of: stubDir)
        let systemIndex = entries.firstIndex(of: "/usr/bin")
        if let stubIndex, let systemIndex {
            XCTAssertLessThan(stubIndex, systemIndex, "директория wg-quick обязана идти впереди системных путей")
        }
    }

    // MARK: - проба «туннель поднят» (fallback при дрейфе маркера)

    func testTunnelIsUpRequiresSocketAndMtimeCorrelation() {
        // Семантика get_real_interface wg-quick один-в-один: непустой `utun*`
        // в `.name`, `.sock` — настоящий сокет (`-S`, не обычный файл), mtime
        // пары расходится меньше 2 c. Фейковая FS — словарь описаний файлов.
        struct FakeFile {
            var content: String?
            var type: FileAttributeType
            var modified: Date
        }
        let base = Date()
        func makeProbe(files: [String: FakeFile]) -> Bool {
            WGQuickExecutor.tunnelIsUp(
                name: "work-vpn",
                runtimeDirectory: "/run/wg",
                fileContents: { files[$0]?.content },
                fileAttributes: { path in
                    guard let file = files[path] else { return nil }
                    return [.type: file.type, .modificationDate: file.modified]
                }
            )
        }
        func nameFile(
            _ content: String? = "utun7\n",
            modified: Date = base
        ) -> FakeFile {
            FakeFile(content: content, type: .typeRegular, modified: modified)
        }
        func sockFile(
            type: FileAttributeType = .typeSocket,
            modified: Date = base
        ) -> FakeFile {
            FakeFile(content: nil, type: type, modified: modified)
        }

        XCTAssertTrue(
            makeProbe(files: ["/run/wg/work-vpn.name": nameFile(), "/run/wg/utun7.sock": sockFile()]),
            "пара .name→utun + сокет с согласованными mtime — туннель поднят"
        )
        XCTAssertFalse(
            makeProbe(files: [:]),
            "без .name туннеля нет"
        )
        XCTAssertFalse(
            makeProbe(files: ["/run/wg/work-vpn.name": nameFile()]),
            ".sock нет — туннель мёртв"
        )
        XCTAssertFalse(
            makeProbe(
                files: ["/run/wg/work-vpn.name": nameFile(), "/run/wg/utun7.sock": sockFile(type: .typeRegular)]
            ),
            ".sock — обычный файл, не сокет (`-S` из get_real_interface)"
        )
        XCTAssertFalse(
            makeProbe(
                files: [
                    "/run/wg/work-vpn.name": nameFile(modified: base),
                    "/run/wg/utun7.sock": sockFile(modified: base.addingTimeInterval(3)),
                ]
            ),
            "mtime пары разошлись на 3 c — пара пережила свой туннель"
        )
        XCTAssertFalse(
            makeProbe(
                files: [
                    "/run/wg/work-vpn.name": nameFile(modified: base),
                    "/run/wg/utun7.sock": sockFile(modified: base.addingTimeInterval(2)),
                ]
            ),
            "Δ ровно 2 c — граница get_real_interface строгая (< 2, не ≤)"
        )
        XCTAssertTrue(
            makeProbe(
                files: [
                    "/run/wg/work-vpn.name": nameFile(modified: base),
                    "/run/wg/utun7.sock": sockFile(modified: base.addingTimeInterval(1.99)),
                ]
            ),
            "Δ 1.99 c — пара ещё валидна"
        )
        XCTAssertFalse(
            makeProbe(files: ["/run/wg/work-vpn.name": nameFile("\n"), "/run/wg/.sock": sockFile()]),
            "пустой .name — туннеля нет"
        )
        XCTAssertFalse(
            makeProbe(files: ["/run/wg/work-vpn.name": nameFile("en0\n"), "/run/wg/en0.sock": sockFile()]),
            "не utun в .name — пара wg-quick не валидна"
        )
    }

    /// Поллит `kill(pid, 0)` до ESRCH: зомби считается живым, пока статус
    /// не собран `waitUntilExit` исполнителя — к моменту возврата runUp
    /// процесс уже reaped, остаётся дождаться смерти.
    private static func waitUntilProcessDies(_ pid: pid_t, within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if kill(pid, 0) == -1 && errno == ESRCH {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }
}
