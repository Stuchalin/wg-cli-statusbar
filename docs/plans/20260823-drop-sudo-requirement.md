# План: Привилегированный демон — убрать запуск под sudo (drop-sudo-requirement)

## Overview

WGStatusBar читает статус WireGuard через `wg show all dump`, требующий root. Сейчас .app из Finder живёт в error-state; рабочее состояние — только `sudo .../Contents/MacOS/WGStatusBar`. 

Решение (согласовано на брейншторме): root-демон (LaunchDaemon) `WGStatusBarHelper` отвечает на запросы приложения по unix-сокету; установка — кнопкой из меню статус-бара через `osascript ... with administrator privileges` (системный промпт с Touch ID), без Developer ID и SMJobBless/SMAppService (требуют стабильную подпись). Приложение больше не запускается от root; dev-режим под `sudo` сохраняется как фолбэк.

Ключевые свойства:
- одно нажатие пальцем за всё время установки; демон персистентен (launchd `RunAtLoad` + `KeepAlive`);
- секреты (private-key, preshared-key) санируются демоном до отправки — в канал и память приложения не попадают;
- состояние сервиса не хранится, а выводится из фактов на каждом тике — застрявших состояний нет;
- протокол с двумя числами в заголовке: `protocol` (совместимость формата) и `build` (версия бинаря демона — любой апдейт хелпера доезжает до пользователя пунктом «Обновить сервис»).

## Context (from discovery)

- Файлы: `Package.swift` (добавить цель `WGStatusBarHelper`), `Sources/App/main.swift` (инъекция `InstallerService`), `Sources/WGStatusBarCore/WireGuardStatusBarCore.swift` (`ProcessWGShowRunner`, `WGShowCommandRunning`, модель, `L10n`), `Sources/WGStatusBarCore/StatusItemController.swift` (`StatusMenuAction`, `StatusMenuStructure`, `performStatusAction`), `Sources/WGStatusBarCore/StatusCardView.swift`, `Sources/WGStatusBarCore/DumpParser.swift` (секретные поля читаются мимо — санированный дамп парсится без изменений), `scripts/build-app.sh`, `Makefile`, `README.md`.
- Тесты: `Tests/WGStatusBarTests/` (7 файлов); паттерны — `@testable import WGStatusBarCore`, моки раннера/неймера через `init(commandRunner:tunnelNamer:)`, спавн процессов только короткоживущий (`ProcessWGShowRunnerTests`), никаких `NSStatusItem`/`NSHostingView` в тестах.
- Тонкие main-файлы (`Sources/App/main.swift`) юнит-тестами не покрываются — конвенция проекта; той же конвенции следует `Sources/Helper/main.swift`.
- L10n: каждый новый ключ — в **обоих** `Resources/{en,ru}.lproj/Localizable.strings`, плейсхолдеры только `%@`.
- Тесты локально запускать с `DEVELOPER_DIR` на Xcode.app (CLT без XCTest).

## Development Approach

- **Testing approach: TDD** — сначала тест (красный), потом реализация (зелёный), в каждой задаче.
- Задачи выполняются последовательно; переход к следующей — только после зелёного `swift test`.
- Тесты — отдельные чекбоксы, не в одном пункте с реализацией.
- План живой: отклонения по скоупу фиксируются здесь (➕ новая задача, ⚠️ блокер).
- Существующее поведение под sudo не ломаем (фолбэк-раннер остаётся).

## Testing Strategy

- **Unit-тесты обязательны в каждой задаче** (XCTest, `swift test`): успех + ошибки, таблично где уместно.
- Сокет-логика — интеграционные тесты в одном процессе: сервер демона на tmp-сокете с заглушкой исполнителя, реальный `wg` и root не нужны. Процессов не спавним (мягче существующего правила «только короткоживущий zsh»).
- `InstallerService`: тестируются сборка osascript-команды (чистая функция, с пробелами в путях) и разбор кодов возврата; реальный запуск с промптом не автоматизируется.
- AppKit-обвязка (пункты меню, карточка) — через `StatusMenuStructure`/`performStatusAction`/`StatusCardViewModel`, как сейчас.
- E2E-тестов в проекте нет; ручной чеклист на тестовой машине — Post-Completion.

## Progress Tracking

- Выполненное помечать `[x]` сразу.
- Новые задачи — префикс ➕, блокеры — ⚠️.

## Solution Overview

Архитектура «тонкий привилегированный демон + тупой клиент»:

```
┌─ WGStatusBar.app (юзер) ─────────────┐        ┌─ WGStatusBarHelper (root, launchd) ─┐
│ WireGuardStatusModel.refresh()       │        │ accept-loop, одно соединение за раз │
│   └─ runDump(): SocketWGShowRunner ──┼─unix──►│   → резолв wg (PATH-кэш)            │
│        сокет есть? нет → Process…    │ socket │   → wg show all dump (timeout 4 c) │
│ Card / Menu (состояние сервиса)      │        │   → санировать секреты             │
│ InstallerService (osascript+TouchID) │        │ ← ok/err <protocol> <build>         │
└──────────────────────────────────────┘        └─────────────────────────────────────┘
```

Ключевые решения (согласовано):
- **SMJobBless/SMAppService отвергнуты** — требуют стабильной подписи (Developer ID); у нас ad-hoc, пересобирается каждую сборку.
- **Сокет `/var/run/wgstatusbar.sock`**, права `root:admin 0660`; демон биндит сам, на старте `unlink`+`bind` (переживает зависший сокет-файл). Peer-credentials для будущих `up`/`down` — точка расширения, не сейчас.
- **Две версии в заголовке**: `protocol` — равенство (ломающие изменения формата), `build` — монотонный номер бинаря; `installed build < build из бандла` → `outdated` → пункт «Обновить сервис». Константы живут в `WGStatusBarCore` — один источник для app и helper, рассинхрон невозможен. Обновление app без изменений хелпера палец не дёргает.
- **Состояния сервиса выводятся из фактов** на каждом тике: сокета нет → `absent`; есть, но не отвечает (коннект отклонён, таймаут, мусор, EOF) → `broken`; отвечает не той версией протокола или старым build → `outdated`; всё ок → `installed`.
- **TOCTOU установки** (root выполняет скрипт из юзер-вайбл бандла) осознанно не закрывается чексуммой — принимаемый риск для опенсорс-инструмента с технической аудиторией; документировать в README. Чинится по-настоящему только переездом на Developer ID + SMAppService (будущий апгрейд; протокол проектируется так, чтобы миграция была сменой транспорта).
- **wg-missing — типизированная ошибка**: демон отвечает `err 1 wg-missing`; фолбэк-раннер маппит exit `127`; карточка показывает человекочитаемое сообщение + команды установки (клик = копирование). Приоритетнее состояния сервиса: без wg установка демона не помогает.
- PATH демона: launchd без Homebrew → резолв `/opt/homebrew/bin/wg`, `/usr/local/bin/wg`, `/usr/bin/wg`. Кэшируется **только успешный** резолв; промах перепроверяется на каждом запросе (три stat-а раз в 5 c — бесплатно), чтобы установка wg после `wg-missing` подхватывалась без перезапуска демона.

## Technical Details

**Протокол** (line-based, одно соединение = один запрос: connect → команда → читать до EOF → close):

```
→ show
← ok <protocol> <build>\n<санированный dump>
← err <protocol> <build> <code>[ <detail>]     # коды: wg-missing | wg-failed
```

Оба числа — в любом ответе, включая `err`: outdated-детект работает и по ошибочному ответу (например, `wg-missing` от старого бинаря демона).

**API хелпера — методы и логика работы** (сигнатуры приблизительные, детали фиксируются в задачах):

**1. Wire-протокол — `HelperProtocol.swift`**

```swift
let helperProtocolVersion: Int   // сейчас 1
let helperBuildNumber: Int       // монотонный, растёт с каждым релизом хелпера

enum HelperRequest { case show }
enum HelperResponseCode { case wgMissing, wgFailed }
enum HelperResponse {
    case ok(protocolVersion: Int, build: Int, dump: String)
    case err(protocolVersion: Int, build: Int, code: HelperResponseCode, detail: String?)
}
func encode(_ request: HelperRequest) -> String
func decode(response: String) -> HelperResponse?
```

Логика работы. Две константы компилируются и в приложение, и в демон — числа гарантированно не расходятся. `protocolVersion` меняется только при ломающих изменениях формата; `buildNumber` — при любом изменении кода хелпера (release-чеклист): так обновления хелпера доезжают до пользователя пунктом «Обновить сервис». `encode` превращает запрос в строку протокола (`show\n`). `decode` разбирает ответ демона-текста: первая строка — заголовок (`ok <protocol> <build>` или `err <protocol> <build> <code> [деталь]`), всё после неё — dump (для `ok`). Текст не подошёл под формат → `nil`, вызывающий считает ответ битым.

**2. Санизатор дампа — `DumpSanitizer.swift`**

```swift
func sanitizeWGDump(_ dump: String) -> String
```

Логика работы. Принимает сырой вывод `wg show all dump`, возвращает тот же вывод без секретов: в строке интерфейса (5 полей) private key → `(none)`, в строке пира (9 полей) preshared key → `(none)`. Пир-строки обрабатываются только после того, как встретилась строка интерфейса — как у парсера, чтобы мусор в начале дампа не переписывался. Вызывается демоном перед отправкой в сокет — единственная точка, где секступаются секреты.

**3. Резолвер пути wg — `WGBinaryResolver.swift`**

```swift
struct WGBinaryResolver {
    init(searchPaths: [String], fileExists: (String) -> Bool)
    func resolve() -> String?   // например "/opt/homebrew/bin/wg"
}
```

Логика работы. Демон живёт в launchd без пользовательского PATH, поэтому ищет wg сам: обходит пути поиска (`/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`) и возвращает первый существующий. Найденный путь кэшируется; ничего не нашлось — кэша нет, следующий запрос ищет заново (иначе после `brew install wireguard-tools` демон не ожил бы до перезагрузки).

**4. Исполнитель команды wg — `WGShowExecutor.swift`**

```swift
protocol WGShowExecuting { func runDump() async throws -> String }
struct WGShowExecutor: WGShowExecuting { init(resolver: WGBinaryResolver) }
```

Логика работы. Продакшн-исполнитель: находит wg через резолвер (не нашёл → ошибка `wgMissing`), запускает его с литеральными аргументами `show all dump`, ждёт завершения с таймаутом ~4 c (завис — убивает и возвращает ошибку), сырой вывод возвращает как есть — санитизация не его дело.

**5. Сервер демона — `HelperDaemon.swift`**

```swift
final class DaemonServer {
    init(executor: WGShowExecuting, socketPath: String, readDeadline: TimeInterval = 5)
    func run() async
}
```

Логика работы. Сердце привилегированной части. На старте удаляет протухший сокет-файл и биндит новый (`/var/run/wgstatusbar.sock`, права 0660 root:admin). Дальше вечный цикл accept, по одному клиенту за раз: читает строку команды под дедлайном (молчащий клиент не подвешивает демон); `show` → дамп у исполнителя → санитизация → ответ `ok <protocol> <build>` + дамп; ошибка исполнителя → `err` с кодом (`wg-missing` / `wg-failed`); неизвестная команда → `err` и разрыв; клиент отключился — молча забыть и обслуживать следующего.

**6. Сокет-клиент — `SocketWGShowRunner.swift`**

```swift
struct SocketWGShowRunner: WGShowCommandRunning {
    init(socketPath: String, timeout: TimeInterval = 5)
    func runDump() async throws -> String
}
```

Логика работы. Замена запуску wg через процесс на стороне приложения: подключается к сокету демона, шлёт `show`, читает ответ до EOF под 5-секундным дедлайном. Пришёл `ok` — возвращает текст дампа (модель не знает, откуда он). Пришёл `err` — превращает код в типизированную ошибку: `wg-missing` → `.wgMissing`, `wg-failed` → `.generic(detail)`. Версии из заголовка сверяются с константами приложения: не совпал протокол или build старее — ошибка `daemonOutdated`. Дальше по причине сбоя: коннект отклонён (демон умер) → `.connectionRefused`; молчание до дедлайна → `.commandTimeout`; мусор или мгновенный EOF → `.badResponse`.

**7. Установщик — `InstallerService.swift`**

```swift
enum InstallResult { case success, cancelled, failure(String) }
final class InstallerService {
    static func installScriptPath(bundle: Bundle) -> String?
    static func osascriptCommand(scriptPath: String, binaryPath: String?) -> [String]
    static func interpret(exitCode: Int, stderr: String) -> InstallResult
    func install() async
    func uninstall() async
}
```

Логика работы. `installScriptPath` — чистая функция резолва скрипта установки из бандла (nil в dev-запуске голого бинаря — понятная ошибка до запуска osascript). `osascriptCommand` — чистая функция: собирает массив аргументов osascript (с экранированием путей с пробелами) для команды `do shell script "<скрипт> --binary <путь>" with administrator privileges`; тестируется отдельно. `interpret` — чистая функция разбора кода возврата и stderr: успех / пользователь отменил промпт / сбой с текстом. `install`/`uninstall` выполняют команду процессом: macOS показывает промпт пароль/Touch ID, root-скрипт из бандла делает установку/удаление. Отмена промпта — тихо ничего не делать; сбой — stderr в ошибку модели на один тик; успех — немедленный `refresh()`, карточка оживает не дожидаясь тика.

**Санизация**: в строке интерфейса (5 полей) поле 2 (private-key) и в строке пира (9 полей) поле 3 (preshared-key) → `(none)`; split/join по табам. Санитайзер повторяет трекинг парсера: 9-полевая строка обрабатывается только после строки интерфейса; мусорные строки — нетронутыми. Продукционный путь: `DaemonServer` пропускает вывод исполнителя через `sanitizeWGDump` перед отправкой — единая точка, секреты не покидают демон.

**Таймауты**: клиент — 5 c (connect+read, ошибка `commandTimeout` как сейчас); демон убивает `wg` через ~4 c и отвечает `err`. EOF клиента посреди запроса — демон прекращает ожидание ребёнка. Дедлайн на чтение строки запроса в демоне (инжектируется): молчащий клиент (connect без send) не вешает последовательный accept-loop.

**Обработка ошибок** (семантика существующая: ошибка живёт один тик, последние живые данные остаются):
- состояние сервиса из фактов: сокета нет → `absent`; коннект отклонён, таймаут при живом сокете, декод-провал или мгновенный EOF → `broken`; протокол не равен или build меньше → `outdated`; иначе `installed`;
- `err wg-missing` / exit `127` → типизированная `.wgMissing` — приоритетнее состояния сервиса, карточка показывает команды установки;
- демон: зависший `wg` — таймаут ~4 c; молчащий клиент — дедлайн чтения; вход парсится строго, аргументы в `wg` литеральные;
- установка: отмена промпта — тихий no-op; сбой скрипта — его stderr в ошибку на один тик; «установилось, но сокет не поднялся» — состояние `absent`/`broken`, пункт меню на месте, повтор доступен.

**Установка**: `scripts/install-daemon.sh --binary <путь>` (идемпотентный): `launchctl bootout` (игнорируя «не найден») → `cp` в `/Library/PrivilegedHelperTools/com.stuchalin.wgstatusbar.helper` (`chmod 755`, `root:wheel`) → plist `/Library/LaunchDaemons/com.stuchalin.wgstatusbar.helper.plist` (`RunAtLoad`, `KeepAlive`) → `launchctl bootstrap system`. Uninstall зеркален: `bootout` → удалить plist, бинарь, сокет. `InstallerService` после успеха дёргает немедленный `refresh()`; отмена промпта — тихий no-op; сбой скрипта — его stderr в ошибку на один тик.

**Выбор раннера**: на каждом refresh — `FileManager.fileExists(/var/run/wgstatusbar.sock)` (инжектится): есть → `SocketWGShowRunner`; нет → `ProcessWGShowRunner` (dev/sudo).

**Меню**: `StatusMenuAction` += `installService` / `uninstallService`; `StatusMenuStructure.entries(refreshEnabled:serviceState:)`; пункты: `absent` → «Установить сервис», `broken`/`outdated` → «Обновить сервис», `installed` → «Удалить сервис» (перед «Выход»). `performStatusAction` принимает инжектнутый установщик.

**L10n-ключи** (en+ru; `error.*` добавляются в Task 6 вместе с типизированными ошибками, `card.*` — в Task 9, `button.*` — в Task 11, `error.install_script_missing` — в Task 10): `button.install_service`, `button.update_service`, `button.remove_service`, `error.wg_missing`, `error.daemon_outdated`, `error.service_unreachable` (для `connectionRefused` и `badResponse`; `commandTimeout` переиспользует существующий `error.wg_show_timeout`), `error.install_script_missing` (сообщение для dev-запуска без .app), `card.copy`, `card.copied`. Команды установки (`brew install wireguard-tools`, `sudo port install wireguard-tools`) — константы, не локализуются.

**Сборка**: `build-app.sh` копирует `WGStatusBarHelper` в `Contents/MacOS/` и `install-daemon.sh`/`uninstall-daemon.sh` в `Contents/Resources/`. Кнопка установки — только в .app (скрипт ищется в бандле; при отсутствии скрипта `InstallerService` даёт понятную ошибку). Dev-режим голого бинаря живёт под sudo с фолбэк-раннером; установка демона вручную: `sudo scripts/install-daemon.sh --binary .build/debug/WGStatusBarHelper`.

## What Goes Where

- **Implementation Steps** — код, тесты, скрипты, документация в этом репо.
- **Post-Completion** — ручная проверка (wg есть на рабочем Mac — базовые сценарии проверяются локально; тестовая машина опциональна), внешние проверки.

## Implementation Steps

### Task 1: Протокол хелпера — константы версий и кодек

**Files:**
- Create: `Sources/WGStatusBarCore/HelperProtocol.swift`
- Create: `Tests/WGStatusBarTests/HelperProtocolTests.swift`

- [x] тест: декод `ok 1 5\n<dump>` → успех с `protocol`, `build`, dump-строками
- [x] тест: декод `err 1 5 wg-missing` и `err 1 5 wg-failed <detail>` → типизированные ошибки (с `protocol` и `build`)
- [x] тест: мусор/пустая строка → ошибка декодинга; encode round-trip
- [x] реализация: `helperProtocolVersion = 1`, `helperBuildNumber` (константы), enum запроса/ответа, encode/decode wire-формата
- [x] `swift test` зелёный

### Task 2: Санизатор дампа

**Files:**
- Create: `Sources/WGStatusBarCore/DumpSanitizer.swift`
- Create: `Tests/WGStatusBarTests/DumpSanitizerTests.swift`

- [x] тест: интерфейс+пиры → секретные поля (2-е интерфейса, 3-е пира) = `(none)`, остальное байт-в-байт
- [x] тест: пустой дамп, мусорные строки, строки с лишними полями — проходят нетронутыми; 9-полевая строка до строки интерфейса — нетронутая (трекинг как у парсера)
- [x] реализация: `sanitizeWGDump(String) -> String` (split/join по табам; 5-полевая строка — всегда, 9-полевая — только после строки интерфейса)
- [x] тест: санированный дамп `parseWGShowDump` парсится в идентичную модель с исходным
- [x] `swift test` зелёный

### Task 3: Резолвер бинаря wg

**Files:**
- Create: `Sources/WGStatusBarCore/WGBinaryResolver.swift`
- Create: `Tests/WGStatusBarTests/WGBinaryResolverTests.swift`

- [x] тест: первый существующий из `/opt/homebrew/bin/wg`, `/usr/local/bin/wg`, `/usr/bin/wg` (инжектированная FS)
- [x] тест: успешный резолв кэшируется (повторный вызов — без обращений к FS); промах НЕ кэшируется — каждый вызов перепроверяет (иначе wg-missing — тупик до перезагрузки демона)
- [x] реализация: резолвер с инжектируемой проверкой существования; кэш — только hit
- [x] `swift test` зелёный

### Task 4: Сервер демона в Core (accept-loop)

**Files:**
- Create: `Sources/WGStatusBarCore/HelperDaemon.swift`
- Create: `Sources/WGStatusBarCore/WGShowExecutor.swift` (в этой задаче — только протокол `WGShowExecuting`; структура исполнителя — Task 5)
- Create: `Tests/WGStatusBarTests/HelperDaemonTests.swift`

- [x] тест: `show` → `ok <protocol> <build>` + вывод заглушки **с секретами санирован сервером** (заглушка возвращает дамп с маркерами в секретных полях — в ответе их нет): единая точка санитизации — `DaemonServer`
- [x] тест: исполнитель вернул ошибку (включая таймаут) → `err` с кодом и `<build>`; неизвестная команда → `err wg-failed` + разрыв соединения
- [x] тест: клиент отключился до ответа — цикл жив, следующий запрос обслуживается; два последовательных соединения
- [x] тест: молчащий клиент (connect без send) — по дедлайну чтения (короткий, инжектированный) соединение закрывается, цикл жив
- [x] реализация: протокол `WGShowExecuting` (инжектируемый исполнитель; таймаут wg — ответственность продакшн-исполнителя Task 5, не сервера), `DaemonServer` (unlink+bind, права 0660 best-effort, дедлайн чтения запроса, диспетчер, санитизация вывода, ответ, EOF-обработка)
- [x] `swift test` зелёный

### Task 5: Исполнитель wg и цель WGStatusBarHelper

**Files:**
- Modify: `Sources/WGStatusBarCore/WGShowExecutor.swift` (добавляется структура исполнителя к протоколу из Task 4)
- Create: `Tests/WGStatusBarTests/WGShowExecutorTests.swift`
- Create: `Sources/Helper/main.swift`
- Modify: `Package.swift`

- [x] тест: исполнитель с подменённым бинарем (короткоживущий `/bin/zsh -c 'echo ...'`-стаб, по образцу `ProcessWGShowRunnerTests`) — успех и ненулевой exit; исполнитель возвращает сырой вывод (санитизация — в сервере, Task 4)
- [x] тест: стаб-бинарь с долгим выполнением и инжектированный короткий таймаут — процесс убит, ошибка таймаута (таймаут wg живёт в исполнителе, единственный владелец)
- [x] реализация: production-исполнитель — резолв wg (Task 3, кэш hit/промах-перепроверка), запуск с литеральными аргументами, таймаут ~4 c, отмена по EOF
- [x] цель `executableTarget WGStatusBarHelper` (path `Sources/Helper`, depends on Core); `main.swift` — тонкая обёртка (сокет `/var/run/wgstatusbar.sock`, запуск сервера), без юнит-тестов по конвенции тонких main
- [x] `swift build` собирает обе цели; `swift test` зелёный

### Task 6: SocketWGShowRunner и типизированные ошибки

**Files:**
- Create: `Sources/WGStatusBarCore/SocketWGShowRunner.swift`
- Create: `Tests/WGStatusBarTests/SocketWGShowRunnerTests.swift`
- Modify: `Sources/WGStatusBarCore/WireGuardStatusBarCore.swift`
- Modify: `Sources/WGStatusBarCore/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/WGStatusBarCore/Resources/ru.lproj/Localizable.strings`
- Modify: `Tests/WGStatusBarTests/WGStatusBarTests.swift`

- [x] тест: round-trip с `DaemonServer` на tmp-сокете — возвращает дамп-текст (после санитизации сервером; контракт `WGShowCommandRunning` не меняется)
- [x] тест: `err wg-missing` → `.wgMissing`; `err wg-failed <detail>` → `.generic(detail)`; коннект отклонён → `.connectionRefused`; молчание до дедлайна → `.commandTimeout`; мусор/мгновенный EOF → `.badResponse`
- [x] тест: заголовок (`ok` или `err`) с чужим `protocol` или меньшим `build` → `.daemonOutdated`
- [x] реализация: `SocketWGShowRunner` (connect+send+read до EOF под 5-секундным дедлайном, декод через Task 1)
- [x] реализация: enum типизированной ошибки статуса (`wgMissing`, `commandTimeout`, `daemonOutdated`, `connectionRefused`, `badResponse`, `generic(String)` + localizedMessage; L10n-ключи `error.wg_missing`, `error.daemon_outdated`, `error.service_unreachable` — в обоих lproj в этой задаче; `commandTimeout` переиспользует существующий `error.wg_show_timeout`)
- [x] мост для карточки: `@Published lastFailure: StatusFailure?`, `lastError: String?` — вычисляемая строка из него; `StatusCardView` читает `model.lastError` без правок (тип `String?` сохраняется)
- [x] обновить существующие тесты модели под типизированную ошибку (сеттер `lastError` в `openWireGuardConfigFolder` переезжает на `lastFailure = .generic(...)` — вычисляемое свойство сеттера не имеет)
- [x] `swift test` зелёный

### Task 7: Фолбэк-раннер — exit 127 → wg-missing

**Files:**
- Modify: `Sources/WGStatusBarCore/WireGuardStatusBarCore.swift` (`ProcessWGShowRunner`)
- Modify: `Tests/WGStatusBarTests/ProcessWGShowRunnerTests.swift`

- [ ] тест: команда с exit `127` (инжектированный короткоживущий zsh) → `.wgMissing`, не generic
- [ ] тест: прочие ненулевые коды — прежнее поведение
- [ ] реализация: маппинг `terminationStatus == 127` → `.wgMissing`
- [ ] `swift test` зелёный

### Task 8: Состояние сервиса и выбор раннера в модели

**Files:**
- Create: `Sources/WGStatusBarCore/ServiceState.swift`
- Modify: `Sources/WGStatusBarCore/WireGuardStatusBarCore.swift`
- Modify: `Tests/WGStatusBarTests/WGStatusBarTests.swift`
- Create: `Tests/WGStatusBarTests/ServiceStateTests.swift`

- [ ] тест (таблично): вывод состояния из фактов — нет сокета → `absent`; коннект отклонён, таймаут при живом сокете, декод-провал или мгновенный EOF → `broken`; протокол не равен → `outdated`; build меньше (в т.ч. по `err`-ответу) → `outdated`; всё ок → `installed`; `wg-missing` не влияет на состояние сервиса
- [ ] реализация: enum `ServiceState` + чистая функция вывода (входы — сокет-файл, исход коннекта, заголовок ответа)
- [ ] реализация: инжектируемый probe сокета в модели; выбор раннера на каждом refresh: сокета нет → инжектированный `commandRunner` (в продакшне — `ProcessWGShowRunner`), сокет есть → `SocketWGShowRunner` с инжектируемым `socketPath` (дефолт `/var/run/wgstatusbar.sock`); `@Published serviceState`; внутренний init — `init(commandRunner:tunnelNamer:socketExists:socketPath:)`, существующий `init(commandRunner:tunnelNamer:)` остаётся перегрузкой (probe всегда false, дефолтный путь) — старые тесты не трогаются, тесты состояния инжектируют свой probe и tmp-сокет
- [ ] тест: модель с моками — состояние публикуется и обновляется между тиками
- [ ] `swift test` зелёный

### Task 9: Карточка — wg-missing с командами установки

**Files:**
- Modify: `Sources/WGStatusBarCore/StatusCardView.swift`
- Modify: `Sources/WGStatusBarCore/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/WGStatusBarCore/Resources/ru.lproj/Localizable.strings`
- Modify: `Tests/WGStatusBarTests/StatusCardViewModelTests.swift`

- [ ] тест: ViewModel при `.wgMissing` — человекочитаемое сообщение + команды `brew install wireguard-tools` и `sudo port install wireguard-tools` (константами, не L10n)
- [ ] тест: прочие ошибки — прежний рендер
- [ ] реализация: ViewModel-состояние + SwiftUI-блок команд (моноширинно, клик = копирование в pasteboard, краткая индикация «скопировано»); L10n-ключи `card.copy`, `card.copied` добавить в оба lproj в этой задаче
- [ ] `swift test` зелёный

### Task 10: InstallerService — установка через osascript

**Files:**
- Create: `Sources/WGStatusBarCore/InstallerService.swift`
- Create: `Tests/WGStatusBarTests/InstallerServiceTests.swift`
- Modify: `Sources/WGStatusBarCore/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/WGStatusBarCore/Resources/ru.lproj/Localizable.strings`

- [ ] тест: сборка osascript-команды из путей бандла — install и uninstall (два вызова одной чистой функции), корректное экранирование путей с пробелами (`do shell script "'...' --binary '...'" with administrator privileges`)
- [ ] тест: `interpret(exitCode:stderr:)` — успех; отмена (User canceled) → тихий результат; сбой → ошибка со stderr
- [ ] тест: `installScriptPath(bundle:)` — резолв из бандла; nil без скрипта (dev без .app) → понятная ошибка до запуска osascript
- [ ] реализация: чистая функция построения команды + запуск `Process` (запуск не тестируем), колбэк успеха → `refresh()` у модели; L10n-ключ `error.install_script_missing` в обоих lproj в этой задаче
- [ ] `swift test` зелёный

### Task 11: Меню — пункты установки/обновления/удаления

**Files:**
- Modify: `Sources/WGStatusBarCore/StatusItemController.swift`
- Modify: `Sources/App/main.swift`
- Modify: `Sources/WGStatusBarCore/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/WGStatusBarCore/Resources/ru.lproj/Localizable.strings`
- Modify: `Tests/WGStatusBarTests/StatusItemControllerTests.swift`

- [ ] тест: `StatusMenuStructure.entries(refreshEnabled:serviceState:)` — `absent` → «Установить», `broken`/`outdated` → «Обновить», `installed` → «Удалить», пункт перед «Выход»
- [ ] тест: `performStatusAction(.installService/.uninstallService)` дёргает инжектнутый установщик; прочие действия не тронуты
- [ ] реализация: кейсы `StatusMenuAction`, расширение структуры меню, диспетчеризация с `InstallerService`, контроллер прокидывает `model.serviceState`
- [ ] инъекция `InstallerService` в `Sources/App/main.swift`
- [ ] `swift test` зелёный

### Task 12: Скрипты install/uninstall и сборка .app

**Files:**
- Create: `scripts/install-daemon.sh`
- Create: `scripts/uninstall-daemon.sh`
- Modify: `scripts/build-app.sh`

- [ ] `install-daemon.sh --binary <путь>`: идемпотентный (bootout-игнор → cp 755 root:wheel в `/Library/PrivilegedHelperTools/com.stuchalin.wgstatusbar.helper` → plist `RunAtLoad`+`KeepAlive` → `bootstrap system`)
- [ ] `uninstall-daemon.sh`: `bootout` → удаление plist, бинаря, сокета
- [ ] `build-app.sh`: копирует `WGStatusBarHelper` в `Contents/MacOS/`, скрипты — в `Contents/Resources/`; `bash -n` на оба скрипта
- [ ] `scripts/build-app.sh` собирается без ошибок; `swift test` зелёный

### Task 13: Verify acceptance criteria

Локально проверяемое (на рабочем Mac, wg есть):

- [ ] секреты не покидают демон: тест Task 4 (маркеры в секретных полях не попадают в ответ) зелёный; в протоколе только `(none)`
- [ ] все требования Overview реализованы; edge-кейсы секции «Обработка ошибок» покрыты тестами
- [ ] состояния меню во всех четырёх состояниях сервиса проверены тестами
- [ ] полный прогон: `swift test` (с `DEVELOPER_DIR`); покрытие не ниже текущего
- [ ] `scripts/build-app.sh` собирается; в `Contents/MacOS/` есть `WGStatusBarHelper`, в `Contents/Resources/` — оба скрипта
- [ ] dev-режим `sudo .build/debug/WGStatusBar` работает как раньше при отсутствующем демоне (сокета нет → процессный раннер; с установленным демоном dev-бинарь тоже пойдёт через сокет — ожидаемо)

### Task 14: [Final] Update documentation

- [ ] README: убрать «sudo limitation», добавить раздел про демон (установка кнопкой, Touch ID, TOCTOU-заметка, ручной чеклист тестовой машины)
- [ ] CLAUDE.md: архитектура — цель `WGStatusBarHelper`, протокол, состояния сервиса, пути/сокет, правило бампа `helperBuildNumber`
- [ ] `docs/plans/completed/` — перенести план

## Post-Completion

**Ручная проверка** (wg на рабочем Mac есть — проверяется локально; тестовая машина опциональна):
- из Finder .app без root: без демона — ошибка + «Установить сервис»; после установки — живые данные
- установка кнопкой через Touch ID-промпт; сокет поднялся, карточка живая без sudo
- wg-missing recovery: снести wg (или скрыть пути) → карточка с командами установки → вернуть wg → следующий тик подхватил (промах резолва не кэшируется)
- чьё имя показывает системный промпт (osascript или WGStatusBar) — косметика доверия
- переживание перезагрузки (launchd поднял демон сам)
- `outdated`: собрать app с бампнутым `helperBuildNumber` → пункт «Обновить сервис» → переустановка
- «Удалить сервис» — plist, бинарь, сокет ушли
- PATH-резолв: демон находит wg в реальном `/opt/homebrew/bin`
- читает ли обычный юзер `/var/run/wireguard/*.name` (неймер имён); если нет — `displayName` деградирует до `utunN` (фолбэк есть), лечение — будущая задача (отдавать маппинг из демона)
- dev-режим `sudo .build/debug/WGStatusBar` рядом с установленным демоном

**Внешнее / будущее**:
- миграция на Developer ID + SMAppService/SMJobBless, когда появится подпись (смена транспорта, протокол готов)
- peer-credentials (`LOCAL_PEERCRED`) при добавлении команд `up`/`down`
