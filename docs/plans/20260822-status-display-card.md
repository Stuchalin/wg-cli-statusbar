# План: Человекочитаемая карточка статуса подключения (status-display-card)

## Overview

Улучшение отображения статуса WireGuard в WGStatusBar по двум осям:

1. **Читаемость и цвета**: вместо технических строк (public key, «never») — карточка со свежестью хендшейка (🟢🟡⚪), трафиком ↓↑, endpoint и маршрутизацией («весь трафик» / список подсетей).
2. **Человекочитаемые имена туннелей**: `utun2` → имя конфига wg-quick (например `work-vpn`) через `/var/run/wireguard/*.name`.

Архитектурно: уход от SwiftUI `MenuBarExtra` к AppKit-гибриду (как CodexBar): `NSStatusItem` + `NSMenu`, где первый пункт — SwiftUI-карточка в `NSHostingView`, ниже — нативные пункты меню со стандартной клавиатурной навигацией (Обновить ⌘R, Открыть конфиги ⌘O, Управление тоннелями (disabled), Выход ⌘Q).

Источник данных меняется на `wg show all dump` (машиночитаемый формат: epoch-хендшейки, байты трафика).

## Context (from discovery)

- Файлы: `Package.swift` (не меняется), `Sources/App/main.swift` (переписать), `Sources/WGStatusBarCore/WireGuardStatusBarCore.swift` (вся логика одним файлом — разбить), `Sources/WGStatusBarCore/Resources/{en,ru}.lproj/Localizable.strings`, `Tests/WGStatusBarTests/WGStatusBarTests.swift`.
- Формат `wg show all dump` проверен по man-странице и `show.c` wireguard-tools: строка интерфейса — 5 tab-полей (`name, private-key, public-key, listen-port, fwmark`); строка пира — 9 (`name, public-key, preshared-key, endpoint, allowed-ips, latest-handshake, rx, tx, keepalive`); handshake = unix-секунды (`0` = never); rx/tx = байты; пустые значения — `(none)`/`off`.
- Механика имён wg-quick проверена по официальному `darwin.bash`: `add_if` пишет реальное имя интерфейса в `/var/run/wireguard/<имя_конфига>.name`, `del_if` удаляет; свежесть валидируется соседним `<utun>.sock`.
- Референс гибрида: `steipete/CodexBar` — `NSMenuItem` с кастомным view, отключение нативной подсветки (`MenuCardMenuItem.isHighlighted = false`).
- Конфиги wg-quick ищет в `/etc/wireguard`, затем `/usr/local/etc/wireguard` (текущий список каталогов кнопки «Открыть конфиги» не меняем).
- Существующий `StatusMenuView` и парсер `parseWGShow` удаляются.

## Development Approach

- **Testing approach: TDD** — сначала тест (красный), потом реализация (зелёный), для каждой задачи.
- Задачи выполняются последовательно, каждая завершается зелёными тестами (`swift test`).
- Малые сфокусированные изменения; тесты — отдельные чекбоксы, не в одном пункте с реализацией.
- План живой: отклонения по скоупу фиксируются в этом файле (➕ новая задача, ⚠️ блокер).
- Backward compatibility не требуется (приложение без UI-совместимости), но публичный API библиотеки `WGStatusBarCore` меняем осознанно.

## Testing Strategy

- **Unit-тесты обязательны в каждой задаче** (XCTest, `swift test`), успех+ошибка сценарии.
- Чистая логика (свежесть, форматтеры, парсер, резолвер, классификация маршрутов) — 100% через юнит-тесты.
- AppKit/SwiftUI-слой (`StatusItemController`, `StatusCardView`) — ручная проверка на тестовой машине (см. Post-Completion); из тестируемого — изолированные вычислимые части (содержимое меню, выбор бейджа).
- E2E-тестов в проекте нет.

## Progress Tracking

- Выполненное помечать `[x]` сразу.
- Новые задачи — префикс ➕, блокеры — ⚠️.

## Solution Overview

Выбранный подход — AppKit-гибрид (вариант A из брейншторма), альтернативы (`MenuBarExtra(.window)` — нет нативной клавиатурной навигации; `.menu` — нет цветов) отклонены пользователем.

Ключевые решения:
- **`NSStatusItem` + `NSMenu`** c пересборкой в `menuNeedsUpdate` — меню всегда свежее при открытии; SwiftUI-карточка — содержимое первого пункта.
- **`wg show all dump`** вместо человекочитаемого вывода: точные epoch-времена и байты; секретные поля (private key, PSK) парсятся мимо и в модель не попадают; сырой вывод не логируется.
- **Тонкая модель**: `WGInterface { name, displayName, peers }`, `WGPeer { publicKey, endpoint, allowedIps, latestHandshake: Date?, rxBytes, txBytes }`.
- **`WireGuardTunnelNamer`**: кэш `utun → имя конфига`; рескан только при появлении неизвестного utun или по кнопке «Обновить»; fallback — сырое имя.
- **Свежесть**: green ≤ 2 мин; orange 2–10 мин; secondary > 10 мин / never. `isConnected` (и тайтл `wg: on/off`) = есть пир green|orange. Пороги — константы в одном enum.
- **ⓘ-легенда** раскрывается внутри карточки (in-place) с пересборкой меню; план Б — статичная caption-строка (решение принимает пользователь по результату спайка на тестовой машине).

## Technical Details

- Точка входа `main.swift`: без `@main`; `NSApplication` + `AppDelegate` + `NSApp.setActivationPolicy(.accessory)` + `app.run()`.
- `StatusItemController`: владеет `NSStatusItem` (тайтл `wg: on/off`), `NSMenu` с делегатом; подписка на `WireGuardStatusModel.objectWillChange` (Combine) для тайтла и контента.
- Карточка ~320 pt: точка состояния + `displayName` (headline) + `utun` мелко (secondary); endpoint (secondary); allowed-ips: бейдж «весь трафик» при `0.0.0.0/0`/`::/0` (подсети не перечислять), иначе список подсетей одной строкой (`lineLimit(1)`, `truncationMode(.middle)`); трафик `↓ N KiB  ↑ N KiB` (`.monospacedDigit()`); хендшейк «N назад» цветом свежести. Пиров >1 — блок на пира, pubkey укорочен только тогда.
- Локализация: все новые строки через `L10n.string`, ключи одновременно в en и ru (плейсхолдер только `%@`, числа передаются строкой).
- Ошибка (`lastError`) живёт один цикл refresh; при ошибке данные последнего успешного тика остаются показываться.

## What Goes Where

- **Implementation Steps** — код, тесты, локализация, документация в этом репо.
- **Post-Completion** — ручная проверка UI на тестовой машине, спи-проверки NSMenu-легенды, клавиатура/тёмная тема.

## Implementation Steps

### Task 1: HandshakeFreshness и классификация маршрутов

**Files:**
- Create: `Sources/WGStatusBarCore/HandshakeFreshness.swift`
- Create: `Tests/WGStatusBarTests/HandshakeFreshnessTests.swift`

- [x] тест: свежесть от `Date` — границы 2 мин (включительно → green) и 10 мин (включительно → orange), > 10 мин → stale, nil → never
- [x] тест: `isConnected`-семантика — green|orange дают «подключён», stale/never — нет
- [x] реализация `enum HandshakeFreshness { case fresh, aging, stale, never }` с константами порогов (120 c / 600 c) и фабрикой `freshness(date:now:)`
- [x] тест: классификация allowed ips — `0.0.0.0/0` или `::/0` → fullTunnel; только подсети → splitTunnel; пусто/`(none)` → нет маршрутов
- [x] реализация `RouteScope` (fullTunnel/splitTunnel) парсингом строки allowed ips
- [x] `swift test` — зелёные

### Task 2: Форматтеры байт и «N назад»

**Files:**
- Create: `Sources/WGStatusBarCore/Formatters.swift`
- Create: `Tests/WGStatusBarTests/FormattersTests.swift`

- [x] тест: байты — 0, 512 B, «876 KiB» (876.48·1024 ≈ 897500 байт), 1.5 MiB, 3 GiB; бинарные единицы (1024)
- [x] реализация `formatBytes(UInt64) -> String` (KiB/MiB/GiB; дробная часть: <10 единиц → до одного знака с отбрасывом хвостовых нулей («3 GiB», «1.5 MiB»), ≥10 → 0 знаков)
- [x] тест: «N назад» — 57 сек; 3 мин; 1 ч 5 мин; 2 ч; сутки+
- [x] реализация `formatAgo(Date, now:) -> String` с локализованными ключами `ago.seconds/minutes/hours/days`; числа передаются строкой, плейсхолдер только `%@` (как `status.connected_count`), `L10n` не расширять
- [x] добавить ключи `ago.*` (включая `ago.days`) в en и ru `Localizable.strings`
- [x] `swift test` — зелёные

### Task 3: Модель и парсер `wg show all dump`

**Files:**
- Create: `Sources/WGStatusBarCore/Model.swift`
- Create: `Sources/WGStatusBarCore/DumpParser.swift`
- Modify: `Sources/WGStatusBarCore/WireGuardStatusBarCore.swift` (модель уезжает в Model.swift)
- Modify: `Tests/WGStatusBarTests/WGStatusBarTests.swift`

- [x] тест: полный дамп (2 интерфейса, несколько пиров) — имена, endpoint, allowed ips, handshake epoch → `Date`, `0` → nil, rx/tx
- [x] тест: `(none)` в endpoint/allowed-ips, `off` keepalive; пустой вывод → []; мусорный вывод → []; мусорная строка между валидными — скипается, остальное парсится
- [x] тест: приватный ключ и PSK из дампа не появляются ни в одном поле модели (секреты не утекают)
- [x] заменить модель: `WGInterface { name, displayName, peers }`, `WGPeer { publicKey, endpoint, allowedIps, latestHandshake: Date?, rxBytes, txBytes: UInt64 }`; `isActive`/`isConnected` — через `HandshakeFreshness`
- [x] реализовать `parseWGShowDump(String) -> [WGInterface]`; удалить `parseWGShow` и старые тесты парсера
- [x] `swift test` — зелёные (старые тесты модели адаптировать под новую модель)

### Task 4: WireGuardTunnelNamer — имена туннелей

**Files:**
- Create: `Sources/WGStatusBarCore/WireGuardTunnelNamer.swift`
- Create: `Tests/WGStatusBarTests/WireGuardTunnelNamerTests.swift`

- [ ] тест: во временной директории `work-vpn.name` с содержимым `utun2` + `utun2.sock` → резолв `utun2` → `work-vpn`; кейс `utun10` (6 байт + перевод строки в конце)
- [ ] тест: нет `.sock` рядом → запись считается устаревшей, fallback на сырое имя
- [ ] тест: каталог не существует / пуст → fallback; несколько `.name` файлов → каждый мапится на свой utun
- [ ] тест кэша: повторный `displayName(for:)` без изменений не читает файловую систему (инжект-фс/счётчик чтений)
- [ ] реализация: сканирование `<dir>/*.name`, чтение содержимого целиком + trim переводов строк (без фиксации длины), кэш `utun → имя` под `NSLock` (вызовы из фонового refresh и главного потока по ⌘R), инжект пути (по умолчанию `/var/run/wireguard`)
- [ ] `swift test` — зелёные

### Task 5: Интеграция модели — dump-команда и displayName

**Files:**
- Modify: `Sources/WGStatusBarCore/WireGuardStatusBarCore.swift`
- Modify: `Tests/WGStatusBarTests/WGStatusBarTests.swift`

- [ ] тест: `statusText`/`menuTitle` на новой модели (0 интерфейсов / все подключены / часть); фикстуры с запасом от порогов (−60 с / −5 мин / −15 мин), чтобы не флапать на границах 2/10 мин
- [ ] тест: после refresh `displayName` интерфейса — из namer; при неизвестном utun namer делает ровно один рескан (мок-namer, счётчик вызовов)
- [ ] команда меняется на `wg show all dump` в `runWGShowSync`; таймаут/логин-шелл механика без изменений

**Note:** сырой вывод dump содержит секреты (private key, PSK) — не логировать нигде; это ограничение реализации, чекбоксом не проверяется.
- [ ] интеграция namer в `refresh()`: ленивый рескан только для незнакомых utun + принудительный по кнопке Обновить (параметр refresh)
- [ ] `swift test` — зелёные

### Task 6: StatusCardView — карточка статуса

**Files:**
- Create: `Sources/WGStatusBarCore/StatusCardView.swift`
- Modify: `Sources/WGStatusBarCore/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/WGStatusBarCore/Resources/ru.lproj/Localizable.strings`
- Create: `Tests/WGStatusBarTests/StatusCardViewModelTests.swift`

- [ ] тест view-model карточки: строки интерфейса (имя+точка цвета), тексты трафика и хендшейка, показ pubkey только при >1 пире
- [ ] тест view-model карточки: выбор «весь трафик»/список подсетей (при нескольких пирах с разными scope — приоритет full-tunnel на уровне интерфейса)
- [ ] тест view-model карточки: empty-state — `interfaces.isEmpty` → строка `status.no_interfaces` (потребитель `statusText` — карточка, отдельного view больше нет)
- [ ] реализация view-model (чистый тип, тестируемый) + тонкий `StatusCardView` поверх неё
- [ ] верстка: заголовок (displayName headline + utun secondary), endpoint, allowed-ips строка, `↓/↑` трафик `.monospacedDigit()`, хендшейк цветом свежести, спиннер isLoading, красная caption lastError
- [ ] ⓘ-легенда: in-place toggle, локализованные 3 строки легенды; пересборка меню через колбэк
- [ ] новые ключи в en+ru (`legend.*`, `badge.full_tunnel`, `peer.*` и пр.)
- [ ] `swift test` — зелёные

### Task 7: StatusItemController — NSStatusItem + NSMenu

**Files:**
- Create: `Sources/WGStatusBarCore/StatusItemController.swift`
- Create: `Tests/WGStatusBarTests/StatusItemControllerTests.swift`

- [ ] тест: вычисление тайтла `wg: on/off` от состояния модели
- [ ] тест: структура меню (пункты/шорткаты/разделители/enabled) на изолированном билдере
- [ ] реализация: `NSStatusItem`, `NSMenu` c `menuNeedsUpdate`-пересборкой; первый пункт `NSMenuItem` + `NSHostingView(rootView: StatusCardView)`, подсветка пункта отключена
- [ ] пункты target/action: Обновить ⌘R (принудительный рескан имён), Открыть конфиги ⌘O (существующий список каталогов), Управление тоннелями (disabled), Выход ⌘Q
- [ ] подписка на `objectWillChange`: обновление тайтла и контента карточки
- [ ] `swift test` — зелёные

### Task 8: Точка входа AppKit и удаление StatusMenuView

**Files:**
- Modify: `Sources/App/main.swift`
- Modify: `Sources/WGStatusBarCore/WireGuardStatusBarCore.swift` (удалить StatusMenuView)
- Modify: `Sources/WGStatusBarCore/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/WGStatusBarCore/Resources/ru.lproj/Localizable.strings`

- [ ] `main.swift`: без `@main`; `NSApplication` + `AppDelegate` (создаёт модель и `StatusItemController`), `setActivationPolicy(.accessory)`, `app.run()`
- [ ] удалить `StatusMenuView` и ставшие ненужными импорты; вычистить неиспользуемые артефакты: `menuIcon`/`statusColor` (если не нужны карточке), ключи `peer.handshake*`, `state.connected`, `peers.not_found`, `app.title` из en/ru (проверить использование, удалить неиспользуемые)
- [ ] `swift build` и `swift test` — зелёные
- [ ] короткое ручное smoke-запуск на этой машине: приложение стартует, показывает статус-айтел и ошибку `wg show` (wg отсутствует — ожидаемо)

### Task 9: Проверка критериев приёмки

- [ ] все требования Overview реализованы (карточка, цвета, имена, пункты меню с шорткатами)
- [ ] краевые случаи: пустой вывод wg, ошибка команды, неизвестный utun, пиров 0/1/много
- [ ] полный прогон: `swift test`
- [ ] сборка release: `swift build -c release`

### Task 10: Документация

- [ ] обновить README.md: новая карточка, `wg show all dump`, механизм имён wg-quick
- [ ] обновить CLAUDE.md: архитектура (StatusItemController, dump-парсер, namer), изменившиеся команды/структура
- [ ] перенести план в `docs/plans/completed/`

## Post-Completion

**Ручная проверка на тестовой машине** (на рабочем Mac wg отсутствует — локальный запуск покажет ошибку `wg show`, это норма; приложение там запускается под sudo):

- СПАЙК ⓘ-легенды: раскрытие/сворачивание внутри NSMenu, пересборка высоты; если NSMenu капризничает — переключиться на план Б (статичная caption-строка легенды), решение фиксируется в плане.
- Клавиатурная навигация: стрелки по пунктам, ⌘R/⌘O/⌘Q, Esc закрывает меню.
- Имя туннеля: `wg-quick up <конфиг>` → в карточке имя конфига; `wg-quick down` → туннель исчезает.
- Цвета: тёмная/светлая тема; 🟢 при активном трафике, 🟡 при простое > 2 мин.
- Full/split: конфиг с `0.0.0.0/0` → бейдж «весь трафик»; конфиг только с подсетями → список подсетей.
- Права: чтение `/var/run/wireguard/*.name` под sudo; без прав — мягкий fallback на utun-имя.

**Внешние зависимости**: нет.
