# План: Грейс-устарелость снапшота — иконка не врёт при потере источника (stale-snapshot-grace)

## Overview

После удаления сервиса демона сокет исчезает → модель уходит на фолбэк-раннер (`zsh -lc wg show`) → без sudo он падает каждый тик → в catch-ветке `refresh()` `interfaces` не трогаются, и снапшот последнего успешного тика заморожен. Иконка перерисовывается каждый тик, но `isAnyConnected` считается от `latestHandshake`, который протухает только по `agingThreshold = 600 c` — до ~10 минут заполненный щиток и «живая» карточка при полной слепоте приложения.

Фикс: у снапшота появляется срок жизни. Успех тика ставит `lastSuccessAt`; данные старше `stalenessLimit = 10 c` считаются устаревшими: иконка (и VoiceOver-тайтл) гаснут, карточка не очищается, а приглушает данные (opacity 0.5) с пометкой «данные устарели». Однократный сбой мигания не даёт (грейс), потеря источника гасит щиток за ~10–15 с (грейс + граница 5-секундного тика).

## Context (from discovery)

- Механика бага: `Sources/WGStatusBarCore/WireGuardStatusBarCore.swift` — catch-ветка `refresh()` обновляет только `lastFailure`/`serviceState`; `HandshakeFreshness.swift:17` — `agingThreshold = 600`; `Model.swift` — `isActive` вычисляется от `Date()` на момент обращения.
- Иконка/VoiceOver: `StatusItemController.updateStatusIcon()` → `StatusIcon.image(connected: model.isAnyConnected)` + `model.menuTitle`.
- Карточка: `StatusCardViewModel` (чистая, `Equatable`, тестируется) + `StatusCardView` строит её в `body` из модели (`interfaces/isLoading/failure`).
- Перерисовку каждый тик уже гонит `objectWillChange` (мутации `lastFailure` в начале/конце refresh) — отдельных таймеров не нужно.
- Тестовые паттерны: мок-раннер через `init(commandRunner:tunnelNamer:)`; для свежести/карточки инжектируется `now`. Модель часов пока не имеет — добавляем `now: () -> Date` в полный внутренний init.
- Конвенции: L10n-ключи в обоих lproj (en/ru); тесты — `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`.
- Ветка: `fix/stale-icon-after-uninstall` (уже создана, коммитим в неё).

## Development Approach

- **Testing approach: TDD** — сначала тест (красный), потом реализация (зелёный), в каждой задаче.
- Задачи последовательно; переход — только после зелёного `swift test`.
- Малые изменения; план живой (➕ новая задача, ⚠️ блокер).

## Testing Strategy

- **Unit-тесты обязательны в каждой задаче** (XCTest): успех + ошибки; граница грейса проверяется с запасом от порога (5 c и 11 c при лимите 10 c — точная граница на 5-секундном тике малозначима).
- Часы модели — фейковые (`now: () -> Date` с мутабельным значением в тесте); сценарии «успех → неудача в грейсе → неудача за грейсом → успех» гоняются без реального ожидания времени.
- View-модель карточки — чистая, проверяем `isStale` в `Equatable`-сравнениях.
- E2E нет; ручная проверка — Post-Completion.

## Progress Tracking

- Выполненное помечать `[x]` сразу; новые задачи ➕, блокеры ⚠️.

## Solution Overview

Вычисляемая устарелость без нового published-состояния (выбрано на брейншторме из трёх вариантов):

- `lastSuccessAt: Date?` — приватное поле модели, ставится в success-ветке `refresh()` из инжектируемых часов. Не публикуется.
- `stalenessLimit: TimeInterval = 10` — рядом с `refreshInterval`.
- `isDataStale: Bool` — `interfaces` непусты и (`lastSuccessAt == nil` || прошло больше лимита). Пустые данные — не устаревшие (нечему).
- `showsConnected: Bool` — `isAnyConnected && !isDataStale`. Иконка и `menuTitle` читают его; `isAnyConnected` остаётся публичной «правдой по данным».
- Карточка: `isStale` в `StatusCardViewModel` → строка «данные устарели» над списком + `.opacity(0.5)` на блоке интерфейсов; ошибка тика — как обычно, выше.

Почему вычисляемое, а не `@Published`: переход устарелости всё равно случается только на тике, `objectWillChange` уже стреляет каждый тик — отдельное состояние ничего не добавляет.

## Technical Details

- Часы: полный внутренний init модели получает `now: @escaping () -> Date = Date.init`; существующие convenience-иниты не меняют сигнатуру (пробрасывают дефолт). Тесты устарелости используют полный init с фейковыми часами и мок-раннером.
- `lastSuccessAt` ставится в `MainActor`-комплшене success-ветки (`self.lastSuccessAt = now()`), там же где `interfaces = parsed`.
- Граница: устарелость — строго больше лимита (`>`); при тике каждые 5 c фактическое угасание иконки ≈ 10–15 c.
- `lastSuccessAt == nil` при непустых данных → устарело: в продакшене недостижимо (`interfaces` пишет только успешный тик), семантика чистая и проверяется инъекцией `init(testing:)`.
- Сон/пробуждение: время сна входит в elapsed → первый тик после пробуждения честно пометит данные устаревшими, иконка кратко погаснет до первого успешного тика (~≤5 c) даже при живом демоне. Принято осознанно (данные действительно стары); сброс по `didWakeNotification` не строим.
- L10n: один новый ключ `status.stale_data` (en: "Data is stale", ru: «Данные устарели») — в обоих lproj.
- `StatusCardViewModel.init(..., isStale: Bool = false)`; поле входит в `Equatable`. `StatusCardView` в `body` передаёт `model.isDataStale`.

## What Goes Where

- **Implementation Steps** — код, тесты, документация.
- **Post-Completion** — ручная проверка на живой машине.

## Implementation Steps

### Task 1: Модель — маркер успеха, часы, вычисляемая устарелость

**Files:**
- Modify: `Sources/WGStatusBarCore/WireGuardStatusBarCore.swift`
- Modify: `Tests/WGStatusBarTests/WGStatusBarTests.swift`

- [x] тест: успех тика (мок-раннер, фейковые часы) → `isDataStale == false`, `showsConnected == isAnyConnected`
- [x] тест: неудача в пределах грейса (успех → сдвиг часов на 5 c → неудача) → не устарело
- [x] тест: неудача за грейсом (успех → сдвиг на 11 c → неудача) → `isDataStale == true`, `showsConnected == false`, `interfaces` не очищены
- [x] тест: успех после устаревания → ожило (`isDataStale == false`); пустые `interfaces` → не устарело; `lastSuccessAt == nil` + данные (инъекция `init(testing:)`) → устарело
- [x] реализация: `now: () -> Date` в полном init (дефолт `Date.init`), `stalenessLimit = 10`, `lastSuccessAt` в success-ветке, вычисляемые `isDataStale`/`showsConnected`
- [x] `swift test` зелёный

### Task 2: Иконка и VoiceOver — переход на showsConnected

**Files:**
- Modify: `Sources/WGStatusBarCore/WireGuardStatusBarCore.swift` (там живёт `menuTitle`)
- Modify: `Sources/WGStatusBarCore/StatusItemController.swift`
- Modify: `Tests/WGStatusBarTests/WGStatusBarTests.swift`

- [x] тест: `menuTitle` при устаревших данных (успех → сдвиг часов за грейс → неудача) — «off»-тайтл; при живых данных — «on» (полный init + фейковые часы + stub-раннер)
- [x] переработать `testMenuTitleWhenActiveAndInactive` и `testAgingHandshakeStillCountsAsConnected` (WGStatusBarTests.swift:184–214): фикстуры с подключёнными интерфейсами прогнать через успешный refresh со stub-раннером — `lastSuccessAt` ставится успехом, ассерты «on» остаются зелёными; через `init(testing:)` они теперь честно устаревшие (`lastSuccessAt == nil`)
- [x] реализация: `updateStatusIcon()` → `StatusIcon.image(connected: model.showsConnected)`; `menuTitle` → от `showsConnected`; `isAnyConnected` не трогаем
- [x] `swift test` зелёный

### Task 3: Карточка — приглушение устаревших данных и пометка

**Files:**
- Modify: `Sources/WGStatusBarCore/StatusCardView.swift`
- Modify: `Sources/WGStatusBarCore/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/WGStatusBarCore/Resources/ru.lproj/Localizable.strings`
- Modify: `Tests/WGStatusBarTests/StatusCardViewModelTests.swift`

- [ ] тест view-модели: `isStale` прокидывается в инициализацию и участвует в `Equatable` (дефолт `false` — существующие тесты не меняются)
- [ ] реализация view-модели: поле `isStale` + параметр init
- [ ] реализация вью: при `isStale` — строка `status.stale_data` (caption, secondary) над списком интерфейсов, блок интерфейсов в `.opacity(0.5)`; ошибка тика и команды установки — без изменений
- [ ] L10n-ключ `status.stale_data` в обоих lproj (en + ru) + включить ключ в key-presence тест (`testCardKeysExistInBothLocalizations`)
- [ ] `swift test` зелёный

### Task 4: Verify acceptance criteria и документация

**Files:**
- Modify: `CLAUDE.md`

- [ ] сценарий бага покрыт тестами: потеря источника (все тики падают) гасит иконку не позже грейса + тика; данные остаются в карточке приглушёнными
- [ ] мигание на однократный сбой отсутствует (грейс-тест Task 1)
- [ ] полный прогон: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
- [ ] CLAUDE.md (тексты там английские): «Data from the last successful tick stays visible» → данные остаются на грейс 10 c (`stalenessLimit`), дальше — приглушены в карточке и не кормят иконку (`showsConnected`); там же в Domain rules — «Menu-bar icon flips … Model exposes `isAnyConnected`» дополнить: иконка читает `showsConnected`, `isAnyConnected` остаётся правдой по данным
- [ ] перенести план в `docs/plans/completed/`

## Post-Completion

**Ручная проверка** (на машине с демоном):
- поставить демон, убедиться в живых данных → «Удалить сервис» → щиток гаснет за ~10–15 c, карточка показывает ошибку + приглушённые пиры с пометкой «данные устарели»
- однократный сбой (перезапуск демона в момент тика) — иконка не мигает
- вернуть сервис (кнопкой) — иконка оживает на первом же успешном тике
- сон/пробуждение машины при живом демоне: иконка кратко гаснет (off) до первого успешного тика после пробуждения — принятое поведение, не баг
