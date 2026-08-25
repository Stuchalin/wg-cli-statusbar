# Tunnel management: перечень туннелей в меню + up/down через демон

## Overview

Приложение из view-only становится управляющим: в меню под карточкой появляется секция «Tunnels» со списком конфигов wg-quick (по строке на туннель, состояние ●/○), клик по строке поднимает/опускает туннель через root-демон. Меню при операции остаётся открытым (спиннер в строке), привилегированный путь — уже установленный демон (никаких osascript на каждое действие).

Подход (согласован на брейншторме, вариант A):

- Протокол демона расширяется аддитивно: запросы `list`, `up <name>`, `down <name>`. **`helperProtocolVersion` не бампается** (проверено по коду: старый демон на неизвестную команду отвечает валидным `err` с версиями в заголовке → outdated-механизм сам предложит Update и скроет секцию). Обязателен bump `helperBuildNumber` (8 → 9).
- Состояние up/down клиент выводит сам из dump+namer (единственный источник правды — `wg show`); `list` отдаёт только имена.
- Взаимоисключения туннелей НЕТ (wg-quick держит несколько интерфейсов одновременно — проверено по скрипту); предупреждение о двух full-tunnel идёт в README.
- Одна операция за раз: пока in-flight, все строки некликабельны, периодический show-тик модели приостановлен (последовательный accept-loop демона).

## Context (from discovery)

Файлы-участники (все существуют, прочитаны):

- `Sources/WGStatusBarCore/HelperProtocol.swift` — `helperProtocolVersion = 1`, `helperBuildNumber = 8`, `HelperRequest { show }`, `encode`/`decode`, `HelperResponseCode { wgMissing, wgFailed }`.
- `Sources/WGStatusBarCore/WGShowExecutor.swift` — образец исполнителя: `WGShowExecutorError`, `WGShowExecuting`, `ChildProcessHandle` (internal), двухступенчатый таймаут TERM→KILL, drain пайпов; константы `defaultTimeout = 3.0`, `defaultKillGrace = 0.5`.
- `Sources/WGStatusBarCore/WGBinaryResolver.swift` — образец резолвера: `wgBinarySearchPaths`, инжектируемый `fileExists`, кэш с ревалидацией.
- `Sources/WGStatusBarCore/SocketWGShowRunner.swift` — клиент: `StatusFailure`, `exchangeBlocking`/`connectToDaemon`/`sendAll`/`readToEOF` под одним дедлайном, `interpret` со сверкой версий, `defaultTimeout = 5.0`.
- `Sources/WGStatusBarCore/HelperDaemon.swift` — `DaemonServer(executor:socketPath:readDeadline:)`, `handleClient` switch по строке команды, default → `err wg-failed unknown command`.
- `Sources/WGStatusBarCore/StatusItemController.swift` — меню как данные; disabled-плейсхолдер `.manageTunnels` (id = 3, ключ `button.tunnel_management_soon`); `CardMenuItem` — образец view-based пункта, клики в котором не закрывают меню.
- `Sources/WGStatusBarCore/WireGuardStatusBarCore.swift` — модель: `@Published interfaces/lastFailure/serviceState`, `refresh(forceNameRescan:)` (пролог стирает `lastFailure` — критично для Task 6), `Timer` c `refreshInterval`; прецедент хранения UI-состояния вне вью — `isLegendVisible` в `StatusItemController.swift`.
- Локализация: `Sources/WGStatusBarCore/Resources/{en,ru}.lproj/Localizable.strings`.
- Тесты-образцы: `HelperProtocolTests`, `HelperDaemonTests` (реальный `DaemonServer` на tmp-сокете со стаб-исполнителем), `SocketWGShowRunnerTests`, `WGShowExecutorTests` (`/bin/zsh`-стабы), `StatusItemControllerTests`, `WGStatusBarTests`.

Факты окружения: wg-quick на машине ищет конфиги в `/etc/wireguard`, `/usr/local/etc/wireguard`, `/opt/homebrew/etc/wireguard` (строка 44 его скрипта); на этой машине — `/opt/homebrew/etc/wireguard/{kvmka-ai,kvmka-full}.conf`. Тесты только через `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` (CLT без XCTest).

## Development Approach

- Подход: обычный (код → тесты в каждой задаче), не TDD.
- Задачи строго по порядку, каждая заканчивается зелёным полным сьютом.
- Гейты каждой задачи: `swift build` + `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`.
- Каждый чекбокс-код сопровождается тестами (success + error сценарии) — тесты отдельными чекбоксами, не в одном пункте с кодом.
- План обновлять при отклонении скоупа (префиксы ➕/⚠️).
- Имена новых типов в плане — предложения; при реализации допустимы синонимы, если семантика сохранена (зафиксировать в плане).

## Testing Strategy

- Unit-тесты обязательны в каждой задаче (см. задачи).
- E2E/UI-автотестов в проекте нет (NSStatusItem/NSHostingView в тесты не тянутся — конвенция проекта); ручной GUI-чеклист — в Post-Completion.
- Интеграционные: клиент ↔ реальный `DaemonServer` в одном процессе (прецедент `SocketWGShowRunnerTests`), демон ↔ стаб-исполнители.

## Progress Tracking

- Отмечать `[x]` сразу после выполнения.
- ➕ — новые обнаруженные задачи, ⚠️ — блокеры.
- ralphex сам переносит завершённый план в `docs/plans/completed/`.

## What Goes Where

- Implementation Steps — только автоматизируемое агентом (код, тесты, документация).
- Post-Completion — ручная проверка (без чекбоксов): живой GUI, реальный демон, обновление установленного демона.

## Implementation Steps

### Task 1: Протокол — новые запросы, коды ошибок, bump build
- [x] `HelperProtocol.swift`: `HelperRequest` += `.list`, `.up(String)`, `.down(String)`; `encode` → `list\n`, `up <name>\n`, `down <name>\n`
- [x] `HelperResponseCode` += `.quickMissing` (wire `wg-quick-missing`), `.tunnelNotFound` (wire `tunnel-not-found`); `decode` понимает оба кода в `err`
- [x] `decode`: убедиться, что `ok` с payload-списком имён (каждое с `\n`) и `ok` с пустым payload проходят существующие правила (терминатор заголовка, dump пустой или с `\n`) — докомментировать в doc-комментарии
- [x] минимальная обработка новых кодов в `SocketWGShowRunner.interpret` (его switch по `err`-кодам исчерпывающий — без правки таргет не скомпилируется; временно → `.generic`, финальный маппинг уточнит Task 5)
- [x] bump `helperBuildNumber` 8 → 9 (helper-код меняется; протокол остаётся 1)
- [x] тесты `HelperProtocolTests`: round-trip encode трёх новых запросов; decode `ok` с payload-списком и `ok` пустым; decode `err` с новыми кодами (+ деталь); отрицательные кейсы (мусор, `ok` с лишними токенами)
- [x] полный сьют зелёный

### Task 2: Общий child-process runner + `WGQuickExecutor` (демон)
- [x] извлечь из `WGShowExecutor.runWGSync` переиспользуемый internal-раннер `runChildProcess(executable:arguments:environment:timeout:killGrace:)` (TERM→KILL→ограниченное ожидание, drain пайпов, `ChildProcessHandle`); контракт: возвращает сырой результат `{ stdout, stderr, terminationStatus, timedOut }`, классификация ошибок — у вызывающего (`WGShowExecutor`/`WGQuickExecutor` переводят в свои типы; типоспецифичные ошибки в раннер не утекают); `WGShowExecutor` переводится на раннер без изменения поведения — существующие `WGShowExecutorTests` остаются зелёными
- [x] `WGBinaryResolver`-образец: `wgQuickBinarySearchPaths` (`/opt/homebrew/bin/wg-quick`, `/usr/local/bin/wg-quick`, `/opt/local/bin/wg-quick`, `/usr/bin/wg-quick`) + резолвер `WGQuickResolver` с тем же кэш-с-ревалидацией контрактом (инжектируемый `fileExists`)
- [x] `WGQuickExecutor` (протокол `WGQuickExecuting { runUp(name:) / runDown(name:) }`): литеральные аргументы `["up", name]` / `["down", name]`; **инъекция окружения** — `process.environment["PATH"]` = директории резолвера вперёд + системные пути (`/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`): под launchd у демона нет Homebrew в PATH, а wg-quick — `#!/usr/bin/env bash`, требующий bash ≥ 4 (системный bash 3.2 убивает его «Version mismatch»), и внутренне зовёт `wg`/`route`/`ifconfig` по PATH (проверено эмпирически на этой машине: с launchd-PATH падает, с brew-PATH работает); ошибки `WGQuickExecutorError { quickMissing, timedOut, failed(String) }` — `failed` несёт хвост stderr (~300 символов) ТОЛЬКО для лога демона, на wire деталь не попадает (см. Task 4)
- [x] константы `defaultOpTimeout = 8.0`, `defaultKillGrace = 0.5` (бюджет ответа демона 9.0 c; клиентский дедлайн `opTimeout = 16.0` появится в Task 5, инвариант-тест — там же, чтобы каждая задача компилировалась самостоятельно)
- [x] тесты `WGQuickExecutorTests` (стабы — исполняемые скрипты с zsh-shebang, резолвимые инъекцией `searchPaths` резолвера — стаб-путь единственный кандидат, по прецеденту `WGShowExecutorTests.makeExecutor`; аргументы НЕ инжектируются — они литеральные `["up"|"down", name]`, как в продакшне; таймауты короткие): exit 0; ненулевой exit с stderr и без неё; таймаут-путь (TERM→KILL, латч timedOut); `quickMissing` через `fileExists = false`; **PATH-тест** — стаб печатает `$PATH`, ассерт: brew-директории впереди системных (ловит главный продакшн-провал — юнит-стабы без этого проходят зелёными при мёртвой фиче)
- [x] полный сьют зелёный

### Task 3: Скан конфигов + валидация имени (демон)
- [ ] `TunnelConfigStore`: `tunnelConfigSearchPaths = ["/etc/wireguard", "/usr/local/etc/wireguard", "/opt/homebrew/etc/wireguard", "/opt/local/etc/wireguard"]` (пути wg-quick + MacPorts-префикс для паритета с `wgQuickBinarySearchPaths`; отсутствующая директория пропускается), `names()` — basenames `*.conf` из существующих директорий, сортировка + дедуп; инжектируемый FS (`contentsOfDirectory`, `isDirectory`) для тестов
- [ ] валидация `TunnelConfigStore.validate(_ name: String) -> Bool`: regex wg-quick один-в-один `^[a-zA-Z0-9_=+.-]{1,15}$` (его собственная проверка имён интерфейсов; отсекает `/`, пустое, пробелы, имена длиннее 15 симв — wg-quick трактует такой аргумент как путь к конфигу) И имя присутствует в `names()`; `names()` фильтруется тем же regex — неоперабельный конфиг вообще не попадает в список
- [ ] тесты `TunnelConfigStoreTests`: скан из нескольких фейковых директорий (дедуп одинаковых имён между путями, сортировка, не-`.conf` игнорируются, отсутствующая директория не падает, фильтрация по regex); валидация — валидное имя (включая `=` и `+`), имя со слэшем, `..`, пустое, пробел, 16+ символов, несуществующее имя, юникод
- [ ] полный сьют зелёный

### Task 4: `DaemonServer` — маршрутизация list/up/down
- [ ] `handleClient`: разбор команды на первое слово + аргумент; switch: `list` → `names()` → `ok`-ответ с именами по одному в строке; `up`/`down` → валидация → исполнитель → `ok` без payload; ошибочные пути → `err` **только с кодом**: `quickMissing → wg-quick-missing`, `tunnelNotFound → tunnel-not-found`, `timedOut`/`failed → wg-failed`; деталь на wire не отправляется — stderr-хвост wg-quick пишется в stderr демона (через plist уже уходит в `/var/log/wgstatusbar-helper.log`): wg-quick эхом печатает в stderr исполняемые команды (включая Pre/PostUp-хуки из конфига), а ошибки дочернего wg могут цитировать строки конфига — секреты не покидают демон (fail-closed, как `DumpSanitizer`); `show` и default-ветка без изменений
- [ ] up/down НЕ заворачиваются в `runDumpCancellingOnClientEOF` (прецедент show не переносится): отключившийся клиент не отменяет wg-quick — SIGTERM посреди `up` оставил бы полуприменённый туннель (адреса, маршруты, DNS через networksetup); операция ограничена собственным op-таймаутом (клин accept-loop исключён), отменяет только shutdown сервера
- [ ] `DaemonServer.init` += инжект `configStore` и `tunnelExecutor` (с продакшн-дефолтами); суммарное время ответа list/up/down ограничено op-таймаутом исполнителя (sequential accept-loop; полный бюджет очереди — инвариант-тест в Task 5)
- [ ] ➕ ранний эмпирический гейт (до UI-задач; требует установленного демона — вручную, не автоматизируется; осознанное исключение из «What Goes Where»: stop-the-line до UI-задач): поставить build 9 на машину (Update из меню), послать `up <имя>` напрямую (`nc -U /var/run/wgstatusbar.sock`) и убедиться, что `ok` приходит раньше opTimeout, а не по нему: wg-quick `detect_launchd` грепает `launchctl procinfo` на `domain =` — под launchd-демоном он может не дизоунить monitor_daemon, и ветка `wait` заблокирует `up` до смерти интерфейса (тогда каждый up = 8-с таймаут при реально поднятом туннеле; триггер не проверен без root). Если виснет — стоп и пересмотр запуска на стороне демона, решение зафиксировать в этом плане
- [ ] тесты `HelperDaemonTests`: `list` возвращает имена стаб-стора; `up`/`down` happy path (`ok` + версии в заголовке); `up` невалидного имени → `err tunnel-not-found`; стаб-исполнитель бросает каждый тип ошибки → маппинг кодов, ассерт «err без детали»; старое поведение `show`/unknown command не сломано
- [ ] полный сьют зелёный

### Task 5: Клиент — `HelperClient` + `SocketTunnelClient`
- [ ] выделить из `SocketWGShowRunner` общий транспорт `HelperClient` (connect/send/read-to-EOF под дедлайном, неблокирующий connect, SO_NOSIGPIPE, poll-циклы); `SocketWGShowRunner` делегирует ему, публичный контракт `WGShowCommandRunning` и `defaultTimeout = 5.0` не меняются
- [ ] `SocketTunnelClient`: `list() async throws -> [String]`, `up(_ name: String)` / `down(_ name:)` (`Void`); `opTimeout = 16.0` — покрывает худший случай последовательного демона: show-тик, стартовавший ДО клика (подавление тика работает только для последующих), держит демон до 4.0 c, op-бюджет ещё 9.0 c → 13.0 c; сверка версий как в `interpret` (старый build/чужой протокол → `.daemonOutdated` даже по `err`); маппинг кодов → `StatusFailure` `.generic(L10n-строка)` — новые кейсы `StatusFailure` НЕ вводятся (иначе сломается исчерпывающий switch в `ServiceState.derive` и его тесты), сообщения без детали с wire (демон её не присылает, Task 4): `wg-quick-missing → error.wgquick_missing`, `tunnel-not-found → error.tunnel_not_found`, `wg-failed → error.tunnel_op_failed`; connect/EOF → существующие `connectionRefused`/`badResponse`; тишина до `opTimeout` → `.generic(error.tunnel_op_failed)` (НЕ `.commandTimeout` — его текст про `wg show`, чужой команде не подходит); заменить временную обработку из Task 1
- [ ] L10n-ключи ошибок в en+ru (`error.wgquick_missing`, `error.tunnel_not_found`, `error.tunnel_op_failed`) — потребляются маппингом уже в этой задаче, не в Task 7
- [ ] тест-инвариант: `WGShowExecutor.defaultTimeout + 2 * defaultKillGrace` (4.0) `+ WGQuickExecutor.defaultOpTimeout + 2 * defaultKillGrace` (9.0) `< SocketTunnelClient.opTimeout` (16.0) — худший случай очереди последовательного accept-loop (show перед op), числа из констант, по образцу `WGShowExecutorTests`
- [ ] тесты `SocketTunnelClientTests` (по образцу `SocketWGShowRunnerTests`, против реального `DaemonServer` на tmp-сокете): `list` happy path; `up`/`down` happy path; старый build демона (стаб с меньшим build) → `daemonOutdated`; отказ соединения; мусор/EOF
- [ ] полный сьют зелёный

### Task 6: Модель — `tunnels`, `inFlightTunnels`, подавление тика
- [ ] `TunnelInfo { name, isUp }`; модель: `@Published tunnels: [TunnelInfo]`, `@Published private(set) var inFlightTunnels: Set<String>` (наличие имени = операция в полёте; отдельное состояние `failed` не вводится — ошибку несёт существующий one-tick `lastFailure`)
- [ ] `isUp` вычисляется из текущих `interfaces` + displayName (namer): туннель поднят ⟺ какое-то `interface.displayName == name`; при нерезолве namer'а (displayName остаётся utunN) строка показывает «выключен», клик up даёт err — карточка покажет общую ошибку операции (деталь «already exists» на wire не приходит), расхождение живёт, пока туннель не пересоздадут (самоизлечения нет), задокументировать честно
- [ ] `loadTunnels()`: только при `serviceState == .installed`; `list` → `tunnels` (только имена; isUp пересчитывается при каждом обновлении interfaces); ошибки глотаются молча — данные меню оппортунистические, не источник статуса (иначе dev-фолбэк без демона получил бы ложную ошибку на карточке); вызывается из menuNeedsUpdate, после ответа up/down, после успешного Install/Update; НЕ в 5-секундный тик
- [ ] `toggleTunnel(named:)`: добавить имя в `inFlightTunnels` → отправить up/down (направление из isUp) → убрать имя; успех → немедленный `refresh()` + `loadTunnels()`; провал → `lastFailure` + `loadTunnels()` **без** `refresh()` — пролог `refresh()` синхронно стирает `lastFailure` (`WireGuardStatusBarCore.swift:294`), ошибка не отрисовалась бы вовсе; данные обновит следующий 5-с тик (прецедент: провал установки → one-tick error без refresh); пока множество непусто — `refresh()` пропускает show-тик (без выставления ошибки и без изменения serviceState) и `isDataStale` не наступает (худший случай очереди 13 c > `stalenessLimit` 10 c — иначе иконка погасла бы и карточка приглушилась посреди живой операции)
- [ ] инжект по протоколу `TunnelCommandRunning` (реализация — `SocketTunnelClient`; мок — по образцу `WGShowCommandRunning` из `WGStatusBarTests`)
- [ ] `Sources/App/main.swift`: расширить `installer.onSuccess` — `refresh()` + `loadTunnels()` (триггер «после Install/Update» физически живёт в AppDelegate, не в модели)
- [ ] тесты `WGStatusBarTests`: toggle happy path (имя в inFlight выставилось и снялось, isUp перевернулся после refresh); провал операции → `lastFailure`, туннели не чистятся; inFlight глушит show-тик; `loadTunnels` маппит имена и глотает ошибки клиента; `loadTunnels` не зовёт клиент при `serviceState != .installed`; isUp-вывод из displayName
- [ ] полный сьют зелёный

### Task 7: UI — секция Tunnels в меню
- [ ] `StatusMenuStructure`: убрать disabled `.manageTunnels` — вместе с кейсом `StatusMenuAction.manageTunnels`, веткой в `performStatusAction` и ключом `button.tunnel_management_soon` из обоих `.strings`; обновить существующие тесты, ассертящие плейсхолдер (`testMenuStructureEntriesOrderAndShortcuts`, `testFactoryBuildsMenuItemsMatchingStructure`); секция как данные — заголовок + строки (`TunnelInfo` + `isEnabled`), item-строитель строк передаётся в `StatusMenuFactory` провайдером по образцу `cardItemProvider` (фабрика остаётся тестируемой без NSHostingView); позиция — между Open Configs ⌘O и сервисным пунктом; видимость: `serviceState == .installed` И `!tunnels.isEmpty`, иначе секции нет целиком (включая заголовок и разделители)
- [ ] `TunnelRowViewModel` (чистый, тестируемый: имя, isUp, isBusy, isEnabled = нет inFlight-операций) + SwiftUI `TunnelRowView` (●/○, имя, `ProgressView` при busy, `allowsHitTesting(!isEnabled)` + визуальное приглушение)
- [ ] `TunnelMenuItem` — view-based NSMenuItem по образцу `CardMenuItem` (NSHostingView, нативный хайлайт off, клик внутри не закрывает меню); клик по строке → `toggleTunnel(named:)`; вью наблюдает модель (`@ObservedObject`) — спиннер/состояние обновляются живьём без пересборки меню
- [ ] `StatusItemController`: построение строк из модели в `menuNeedsUpdate` + вызов `model.loadTunnels()` при открытии меню; подписка на изменение `tunnels` → пересборка секции, пока меню открыто (list асинхронный — иначе при первом открытии секция появилась бы только со второго раза); состояние строк (`isEnabled`) — из `inFlightTunnels`; Refresh ⌘R тоже disabled при непустом `inFlightTunnels` (иначе клик — молча подавленный no-op; существующий параметр структуры `refreshEnabled`)
- [ ] L10n-ключи в en+ru: заголовок секции (`menu.tunnels_section`), accessibility-подписи строк (вкл/выкл туннель) — error-ключи добавлены раньше, в Task 5
- [ ] тесты: `StatusItemControllerTests`/`StatusMenuStructure` — позиция секции, скрытие при `serviceState != .installed` и при пустых tunnels, отсутствие старого пункта; `TunnelRowViewModelTests` — состояния idle/busy/disabled, isUp
- [ ] полный сьют зелёный

### Task 8: Verify acceptance criteria
- [ ] проверить по коду все требования Overview (запросы, валидация, таймаут-инварианты, видимость секции, одна-операция-за-раз, подавление тика)
- [ ] полный сьют + `swift build -c release`
- [ ] код-ревью диффа ветки (корректность, безопасность: валидация имени, инъекция путей, утечки секретов в stderr-детали)
- [ ] grep-проверки: `button.tunnel_management_soon` нигде не остался; таймаут-константы согласованы (4.0 + 9.0 = 13.0 < 16.0, числа из констант — как в инвариант-тесте Task 5)

### Task 9: [Final] Update documentation
- [ ] README: фича (управление туннелями) и закрытие соответствующего пункта Roadmap; расширить раздел принятых рисков — wg-quick исполняет Pre/PostUp как root из user-writable конфигов; два одновременно поднятых full-tunnel конфликтуют за дефолтный маршрут и системный DNS (networksetup), приложение НЕ вводит взаимоисключение; in-flight операция блокирует show-тики демона на секунды; дополнить раздел «Manual test checklist» туннельными сценариями (up/down кликами под установленным демоном, секция скрыта при старом демоне, PATH-инъекция проверяется после обновления демона)
- [ ] CLAUDE.md: новые файлы/типы в архитектуре, запросы протокола (list/up/down, новые err-коды, ответ без детали), data flow (loadTunnels триггеры, inFlightTunnels, подавление тика), секция меню, инварианты бюджетов и PATH-окружения wg-quick; секция тестов — новые тестовые файлы
- [ ] план: все чекбоксы закрыты

## Technical Details

Wire-протокол (line-based, соединение = запрос; новое — в скобках):

```
→ show | [list] | [up <name>] | [down <name>]
← ok <protocol> <build>\n<dump-или-имена-или-пусто>
← err <protocol> <build> <code>[ <detail>]   # коды: wg-missing | wg-failed | [wg-quick-missing | tunnel-not-found]
```

Константы и инварианты:

| Что | Значение | Инвариант |
|---|---|---|
| WGQuickExecutor.defaultOpTimeout | 8.0 c | бюджет `opTimeout + 2*killGrace` = 9.0 c |
| WGQuickExecutor.defaultKillGrace | 0.5 c | — |
| SocketTunnelClient.opTimeout | 16.0 c | show-бюджет 4.0 + op-бюджет 9.0 = 13.0 < 16.0 — даже show-тик, вставший в очередь перед операцией, не выбивает клиентский дедлайн |
| helperBuildNumber | 8 → 9 | helper-код меняется |
| helperProtocolVersion | 1 (не меняется) | старый демон отвечает err на неизвестную команду → outdated |
| PATH ребёнка wg-quick | brew-директории вперёд + системные | под launchd у демона нет Homebrew в PATH: shebang `env bash` находит системный bash 3.2, а wg-quick требует bash ≥ 4 и сам зовёт `wg`/`route` по PATH (проверено эмпирически) |

Валидация имени (демон, оба условия): regex wg-quick `^[a-zA-Z0-9_=+.-]{1,15}$` И `.conf` существует в `/etc/wireguard`, `/usr/local/etc/wireguard`, `/opt/homebrew/etc/wireguard`; `names()` фильтруется тем же regex.

State-machine операций (клиент): idle (имени нет в `inFlightTunnels`) → in-flight (клик; все строки disabled; show-тик пропущен) → ok → immediate `refresh()`+`loadTunnels()`, имя удалено | err → `lastFailure` (one-tick, локализованное сообщение без детали) + `loadTunnels()` без refresh (refresh стирает lastFailure; данные сойдёт следующий 5-с тик), имя удалено. Повторный клик по другой строке в in-flight невозможен (строки disabled). Ошибки `loadTunnels` глотаются (оппортунистические данные меню). Особый случай: таймаут up при реально поднятом туннеле (detect_launchd-риск, см. гейт в Task 4) — ошибка живёт один тик, следующий успешный тик покажет туннель поднятым, состояние сходится само.

Err-ответы up/down на wire — только код, без детали: stderr wg-quick (эхо исполняемых команд, включая хуки из конфига) остаётся в логе демона `/var/log/wgstatusbar-helper.log`; секреты не покидают демон.

## Post-Completion

**Ручная верификация (нужен установленный демон + wg на машине):**

- `up` из-под демона отвечает `ok` раньше opTimeout, а не по нему (detect_launchd/`wait`-риск из Task 4 на живом демоне)
- Обновить демон через меню (Update) — build 9; убедиться, что после обновления секция Tunnels появилась
- Открыть меню: обе строки kvmka-ai / kvmka-full с корректным ●/○ (kvmka-full поднят на момент написания плана)
- Клик по опущенному туннелю: меню не закрывается, спиннер в строке, через 1–5 с ●, карточка обновилась
- Клик по поднятому: аналогично, ○, utun исчез из карточки
- Провал: временно переименовать/сломать конфиг, клик — ошибка на карточке, строка вернулась в норму
- Old-daemon путь: перед обновлением демона убедиться, что секции нет и показан Update
- Параллельный `wg-quick up` в терминале во время клика — приложение не ломается (err отобразился)

**Внешние системы:** нет.
