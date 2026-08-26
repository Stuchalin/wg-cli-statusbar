# Tunnel state fix: демон-сторона состояния туннелей (запрос state)

## Overview

Фикс бага tunnel-management (PR #5): при подключённом туннеле строка в меню показывает «выключена» (пустой значок), а клик по ней шлёт `up` вместо `down` → wg-quick «already exists» → «Tunnel operation failed». Корень: `/var/run/wireguard/<conf>.name` создаётся wireguard-go с правами 0400 root — приложение (обычный пользователь) прочитать его не может, namer в daemon-режиме промахивается всегда, `displayName` остаётся `utunN`, и `isTunnelUp` (= совпадение displayName с именем туннеля) всегда false. Побочный симптом того же корня: карточка показывает `utunN` вместо имени конфига.

Решение (согласовано на брейншторме, вариант A+): состояние туннелей вычисляет демон (он root и файлы читает) — новый аддитивный запрос `state` возвращает `имя → up|down + utun`; клиент берёт isUp и маппинг имён интерфейсов напрямую из него, namer остаётся фолбэком (dev-режим под sudo). `list` не трогается (совместимость со старым приложением).

Подтверждено диагностикой: лог демона на тест-машине полон повторов «up kvmka-wg-full failed ... already exists as utun2»; `.name` — `-r-------- root`; PATH-инъекция и stderr-логирование работают как задумано.

## Context (from discovery)

- `Sources/WGStatusBarCore/HelperProtocol.swift` — `helperProtocolVersion = 1`, `helperBuildNumber = 16`, `HelperRequest { show, list, up(String), down(String) }` (новых err-кодов фикс не добавляет — ответы state используют существующие `ok`/`err`).
- `Sources/WGStatusBarCore/WireGuardTunnelNamer.swift` — namer: протокол `WireGuardTunnelNameFileSystem` (entries/contents/fileExists/modificationDate, строки 5–13), `directoryPath = "/var/run/wireguard"` (строка 68), кэш + ленивый рескан, правило свежести пары `.name`/`<utun>.sock` (|Δmtime| < 2 c).
- `Sources/WGStatusBarCore/HelperDaemon.swift` — `DaemonServer` с инжектом `configStore`/`tunnelExecutor` (init, строка 106); маршрутизация `show`/`list`/`up`/`down` (строки 262–266).
- `Sources/WGStatusBarCore/SocketTunnelClient.swift` — протокол `TunnelCommandRunning { list/up/down }` (строки 16–20), `opTimeout = 16.0`, маппинг ошибок в локализованные `.generic`.
- `Sources/WGStatusBarCore/WireGuardStatusBarCore.swift` — модель: `tunnels: [TunnelInfo]` (строка 173), `inFlightTunnels` (178), `isTunnelUp(named:)` через displayName (458–459), `loadTunnels()` через list (469+), направление `toggleTunnel` из `isTunnelUp` (500–502), проставление displayName из namer (`resolveDisplayNames`, строки 366–391), `recomputeTunnelStates()` (525–531, вызывается из `refresh()` строка 343).
- `Sources/WGStatusBarCore/TunnelRowView.swift` — строка меню, `isUp` живым вызовом `model.isTunnelUp` (строка 52); моки `TunnelCommandRunning` в тестах: `MockTunnelClient` (WGStatusBarTests) и `GatedTunnelClient` (StatusItemControllerTests.swift:162–186).
- `Sources/WGStatusBarCore/Model.swift` — `TunnelInfo` (строка 64).
- Тесты-образцы: `WireGuardTunnelNamerTests` (инжектируемый FS), `HelperDaemonTests` (реальный `DaemonServer` на tmp-сокете, стабы), `SocketTunnelClientTests`, `WGStatusBarTests` (моки `TunnelCommandRunning`).

## Development Approach

- Подход: обычный (код → тесты в каждой задаче), не TDD.
- Задачи строго по порядку; гейты каждой задачи: `swift build` + `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` (сейчас 294 теста зелёные).
- Тесты отдельными чекбоксами (success + error), полный сьют зелёный перед следующей задачей.
- План обновлять при отклонении скоупа (префиксы ➕/⚠️).

## Testing Strategy

- Unit-тесты обязательны в каждой задаче. E2E-автотестов нет (конвенция проекта: без NSStatusItem/NSHostingView); ручная верификация — Post-Completion.
- Интеграционные: клиент ↔ реальный `DaemonServer` в одном процессе.

## Progress Tracking

- Отмечать `[x]` сразу; ➕ новые задачи, ⚠️ блокеры. ralphex сам перенесёт завершённый план в `docs/plans/completed/`.

## What Goes Where

- Implementation Steps — автоматизируемое агентом (код, тесты, документация).
- Post-Completion — ручная проверка на тест-машине с живым демоном.

## Implementation Steps

### Task 1: `WireGuardRuntimeReader` — извлечение сканера из namer'а
- [ ] новый `WireGuardRuntimeReader` (Core): скан `/var/run/wireguard/*.name` → валидированные пары «конфиг → utun» с правилом свежести namer'а (соседний `<utun>.sock`, |Δmtime| < 2 c; битый/нечитаемый файл → пара отбрасывается); инжектируемые FS и `directoryPath` — переиспользовать `WireGuardTunnelNameFileSystem`
- [ ] `WireGuardTunnelNamer` рефакторится внутрь на ридер (кэш, ленивый рескан и публичный контракт `displayName(for:)` не меняются) — чистый рефактор без смены поведения
- [ ] тесты `WireGuardRuntimeReaderTests`: валидная пара; .name без .sock; .sock без .name; расхождение mtime ≥ 2 c (зависший .name на переиспользованном utun); пустое содержимое .name; отсутствующая директория → пустой результат
- [ ] существующие `WireGuardTunnelNamerTests` остаются зелёными поверх ридера (переносить кейсы свежести не дублированием, а использованием ридера в фейках при необходимости)
- [ ] полный сьют зелёный

### Task 2: Протокол — запрос `state`, bump build
- [ ] `HelperRequest` += `.state`; `encode` → `state\n`
- [ ] bump `helperBuildNumber` 16 → 17 (helper-код меняется; версия протокола остаётся 1; новых err-кодов нет — ответы state используют существующие `ok`/`err`, исчерпывающие switch'ы клиентов не ломаются)
- [ ] тесты `HelperProtocolTests`: encode round-trip `.state`; `ok` с payload трёхполевых строк проходит существующие правила decode (терминатор заголовка, payload пустой или с `\n`)
- [ ] полный сьют зелёный

### Task 3: Демон — маршрутизация `state`
- [ ] `handleClient`: `case "state" where argument == nil` → из `configStore.names()` × пар ридера: строки `name\tup\tutunN` / `name\tdown\t` (у опущенных utun-поле пустое; всегда 3 поля); конфиг «поднят» ⟺ валидная пара ридера есть; `show`/`list`/`up`/`down` не меняются
- [ ] `DaemonServer.init` += инжект ридера (с продакшн-дефолтом); state — локальный скан без процессов, в существующие дедлайны укладывается; **скан выполняется заново на каждый запрос** (кэша в ридере нет — кэш остаётся только в namer'е; закэшированный ридер тихо повторил бы исходный баг)
- [ ] тесты `HelperDaemonTests`: `state` happy path (смешанные up/down, пустой utun у down); пустой `/var/run/wireguard` → все down; конфиг без пары → down; **два state-запроса подряд: между ними из фейкового FS удаляется пара → второй отвечает down**; `list`/`show` не сломаны; state с аргументом → unknown-command err (как у show/list)
- [ ] полный сьют зелёный

### Task 4: Клиент — `TunnelState` и `state()`
- [ ] `TunnelState { name: String, isUp: Bool, utun: String? }` (Model.swift, рядом с `TunnelInfo`)
- [ ] `TunnelCommandRunning` += `state() async throws -> [TunnelState]` (модель пока остаётся на `list()` — переключение в Task 5, каждая задача зелёная); `SocketTunnelClient.state()`: тот же транспорт/сверка версий/маппинг ошибок, что у `list()`; парсинг: split по `\n`, каждая строка split по `\t` с `omittingEmptySubsequences: false` (дефолтный split съедает пустое третье поле down-строк) — ровно 3 поля, `up` требует непустой utun, `down` — пустой; мусорная строка payload → `.badResponse`
- [ ] оба мока `TunnelCommandRunning` расширяются `state()`: `MockTunnelClient` (WGStatusBarTests, программируемый `stateResults` + счётчики) и `GatedTunnelClient` (StatusItemControllerTests.swift:162, тривиальный возврат `[]`)
- [ ] тесты `SocketTunnelClientTests`: state happy path (up с utun, down без) против реального `DaemonServer`; пустой набор конфигов → пустой ok-payload → `[]`; мусорный payload → `.badResponse`; старый build демона → `daemonOutdated`; отказ соединения
- [ ] полный сьют зелёный

### Task 5: Модель — isUp из state, displayName из state, направление toggle
- [ ] `loadTunnels()` зовёт `state()`: `tunnels` строится напрямую из ответа (`TunnelInfo(name:isUp:)`); `isTunnelUp(named:)` через displayName **удаляется**; направление `toggleTunnel` — из `tunnels`; после ответа up/down — `state()` вместо `list()`
- [ ] `TunnelRowView.swift:52` — строка меню берёт `isUp` lookup'ом из `model.tunnels` по имени (сейчас живой вызов `model.isTunnelUp`; это ровно элемент, на котором виден симптом бага)
- [ ] `recomputeTunnelStates()` (WireGuardStatusBarCore.swift:525–531, вызов из `refresh()` строка 343) удаляется вместе с `isTunnelUp` — точки строк обновляются открытием меню, ответом up/down и переходом serviceState, 5-с тик их больше не переворачивает (регрессии нет: в daemon-режиме isTunnelUp и так всегда false — сам баг; в sudo-режиме `state()` даёт isUp не хуже работающего под root namer'а)
- [ ] маппинг имён: модель хранит последний маппинг из state (`stateInterfaceNames: [utun: имя]`, обновляется каждым ответом `state()`) и применяет его в `refresh()` ПОСЛЕ namer-резолва (`resolveDisplayNames`) — state перебивает namer на **обоих** путях записи displayName, иначе 5-с тик возвращал бы `utunN` при открытом меню; namer остаётся для непокрытых интерфейсов и dev-режима без демона; живая пересборка меню переименует карточку в открытом меню
- [ ] ошибки `state` глотаются (строки/имена держат последнее известное, `lastFailure`/`serviceState` не трогаются); `loadTunnels` по-прежнему гейтится на `serviceState == .installed`
- [ ] клиентский `list()` удаляется из `TunnelCommandRunning`/`SocketTunnelClient`/обоих моков вместе с клиентскими list-тестами (мёртвый код после переключения модели; wire-запрос и `serveList` демона НЕ трогаются — совместимость со старым приложением демон-сторонняя)
- [ ] существующие туннельные тесты переводятся с `list`/`isTunnelUp` на `state` (`listResults` → `stateResults`) — все использующие их: в `WGStatusBarTests` toggle success/failure, loadTunnels map/swallow/no-republish, `testTunnelIsUpFollowsInterfaceSnapshotUpdates` (удалить или переписать в инверсию: снапшот-тик меняет `interfaces`, `tunnels` не меняется без нового ответа state), `testInFlightTunnelSuppressesShowTick` (направление теперь из `tunnels` — запрограммировать state), `testLoadTunnelsSkipsClientWhenServiceNotInstalled` (`listCalls` → `stateCalls`); в `SocketTunnelClientTests` транспортные кейсы на `client.list()` (refused / garbage+EOF / foreign-header) переписываются на `state()`; инварианты сохраняются: no-op при in-flight, глотание ошибок, отсутствие republish идентичного списка
- [ ] обновить док-комментарии, ставшие неточными: `TunnelInfo` (Model.swift:60–64 — «isUp — вывод модели, пересчитывается на тике» больше не так), `tunnels` (WireGuardStatusBarCore.swift:170–173 — «(демон, `list`)»), заголовок `SocketTunnelClient` (описывает `list`), `TunnelRowView` (строки 28–33 — «isUp выводится из снапшота (`isTunnelUp`)»), `StatusItemController` (строки 247–249 и 359–361 — упоминания пересчёта isUp)
- [ ] тесты `WGStatusBarTests`: **регрессия бага** — state говорит isUp=true → клик шлёт `down` (не up); isUp=false → `up`; displayName: state-utun совпал с интерфейсом → имя конфига, namer-результат перетёрт; state-провал → туннели/имена не изменились; `tunnels` обновился после toggle; **тик не откатывает имя** — успешный state → `refresh()` → displayName остаётся именем конфига при промахе namer'а
- [ ] полный сьют зелёный

### Task 6: Verify acceptance criteria
- [ ] проверить по коду все требования Overview (isUp только из state, направление toggle, displayName-приоритет демона, list не тронут)
- [ ] полный сьют + `swift build -c release`
- [ ] grep-гейты (скоуп `Sources/` + `Tests/`): `isTunnelUp` не осталось; `helperBuildNumber = 17`; `state` в encode/маршрутизации/клиенте/модели
- [ ] код-ревью диффа ветки (корректность, совместимость старого приложения с демоном 17)

### Task 7: [Final] Update documentation
- [ ] CLAUDE.md: запрос `state` в протоколе (формат трёхполевых строк), `WireGuardRuntimeReader` в архитектуре (namer поверх ридера; демон — источник состояния и имён в daemon-режиме), data flow (`loadTunnels` через state, приоритет displayName, namer — фолбэк), секция тестов — новые файлы
- [ ] README: буллет управления туннелями (состояние и имена определяет демон); абзац про имена в «How it reads status» (README.md:39 — «Tunnel names come from the wg-quick mechanism» больше не вся правда); переработка пункта Display names в Manual test checklist (README.md:148 говорит «serving the mapping from the daemon is a future task» — теперь это сделано); сценарий фикса в чеклист: поднятый туннель ●, клик = down в логе демона, имя конфига в карточке
- [ ] план: все чекбоксы закрыты

## Technical Details

Wire-протокол (добавка к существующему):

```
→ state
← ok <protocol> <build>\nname\tup\tutun2\nname\tdown\t\n...
```

- Всегда 3 поля через `\t`; `up` ⟹ непустой utun, `down` ⟹ пустой. Пустой payload = нет конфигов.
- `helperBuildNumber`: 16 → 17; `helperProtocolVersion` остаётся 1; `list` не меняется (старое приложение продолжает работать с демоном 17: list отвечает, state не спрашивается).
- Правило «поднят»: валидная пара ридера (`.name` + соседний `<utun>.sock`, |Δmtime| < 2 c) — то же правило, что у namer'а, теперь в одном месте.
- Приоритет источников `displayName`: state демона → namer → имя интерфейса (utunN); enforced на обоих путях записи — `loadTunnels()` и 5-с тик `refresh()` (тик применяет сохранённый state-маппинг после namer-резолва). `isUp` строк — только из state (вывод из displayName удалён, вместе с `recomputeTunnelStates` на тике). Обновление точек строк: открытие меню, ответ up/down, переход serviceState.
- Триггеры `loadTunnels()` не меняются: menuNeedsUpdate, ответ up/down, переход serviceState в установленное (Install/Update попадает сюда через `serviceStateDidChange` контроллера, не прямым вызовом); НЕ в 5-с тик. Клиентский `list()` после переключения удаляется (демон-сторонний `serveList` остаётся для старых приложений).

## Post-Completion

**Ручная верификация (тест-машина /Users/sdf, демон + wg):**

- Обновить демон до build 17 (Update из меню или install-daemon.sh)
- Поднятый снаружи туннель: строка показывает ● (не пустой значок)
- Клик по поднятому: в `/var/log/wgstatusbar-helper.log` появляется `down <имя>` (не `up ... already exists`), туннель опускается, карточка гаснет
- Клик по опущенному: `up`, туннель поднимается, ●
- Карточка показывает имя конфига (`kvmka-wg-full`) вместо `utunN`
- Старый демон (9/16) → приложение показывает Update, секции туннелей нет (на рабочей машине разработчика демон build 8 — ожидаемо)

**Внешние системы:** нет.
