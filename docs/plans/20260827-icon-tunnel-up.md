# Иконка от факта поднятых туннелей + опрос state каждые 5 с

## Overview

Иконка щитка сейчас привязана к свежести хендшейков (`showsConnected = isAnyConnected && !isDataStale`, где `isAnyConnected` — «у какого-то интерфейса есть пир с хендшейком ≤ 10 мин»). WireGuard хендшейкает по потребности: туннель поднят, но трафика нет → через 10 минут все пиры «stale» → щиток гаснет, хотя туннель живой. Это жалоба, которую чиним.

Новая семантика (согласована на брейншторме, по секциям):

- **Иконка = факт туннеля**: непустой дамп (`interfaces` из `wg show all dump`) = в ядре есть wg-интерфейс = туннель поднят. Хендшейк-статус остаётся внутри карточки (карточка не меняется). Гейт устаревания сохраняется: потеря источника → щиток гаснет ~10–15 с (фикс №3 не откатывается).
- **Опрос `state` демона каждые 5 с**: строки меню (●/○, `TunnelInfo.isUp`) и маппинг `stateInterfaceNames` перестают замерзать между открытиями меню; туннель, опущенный в терминале, переворачивает строку вживую при открытом меню.

Демон, протокол и локализация не меняются; `helperBuildNumber` не поднимается — осознанное решение, а не умолчание: `WGStatusBarCore` компилируется и в бинарь хелпера, но daemon-пути (протокол, исполнители, сервер) не тронуты, поведение демона не меняется. Побочный эффект семантики — туннель с пирами без единого хендшейка зажигает щиток сразу, а не после первого хендшейка; щиток больше не «мигает» на стыке 10 минут при простаивающем туннеле.

## Context (from discovery)

Файлы-участники (прочитаны, номера строк проверены):

- `Sources/WGStatusBarCore/WireGuardStatusBarCore.swift` — `isAnyConnected` (:282), `isDataStale` (:295), `showsConnected` (:304), `menuTitle` (:325), `refresh()` с гардом `inFlightTunnels` (:337), `loadTunnels()` с гардом `serviceState == .installed` (:510) и no-republish идентичного `tunnels` (:534), таймер `startTimer()` (:599, замыкание дёргает только `refresh()`), `refreshInterval = 5` (:201).
- `Sources/WGStatusBarCore/Model.swift` — `WGInterface.isConnected` (:14), `WGPeer.isActive` (:55).
- `Sources/WGStatusBarCore/HandshakeFreshness.swift` — `isActive` (:20).
- `Sources/WGStatusBarCore/StatusItemController.swift` — `iconConnected(for:)` (:307) → `StatusIcon.image(connected:)` (:300).
- Тесты: `Tests/WGStatusBarTests/WGStatusBarTests.swift` — `isConnected` (:173–175), `menuTitle`/`isAnyConnected` (:207–213), aging-кейсы (:224, :233), fresh-кейс (:280), инвариант `showsConnected == isAnyConnected` (:459), staleness-кейсы (:479, :500–501, :526, :534, :543–544, :562–569), `iconConnected` (:573–592), ин-flight (:1112); `Tests/WGStatusBarTests/HandshakeFreshnessTests.swift` — семантика `isActive` (:45–61).
- README: строки 15 (иконка = свежий хендшейк + свежесть данных), 37–38 (доменные правила isActive/isConnected), 143–145 (потеря источника, sleep/wake — остаются по смыслу).
- CLAUDE.md: Domain rules (абзац про `showsConnected`/`isActive`/`isConnected`), Tunnels data flow («never in the 5-second tick»), бюджет-инвариант, Testing notes (`iconConnected`).

Проверено grep'ом: цепочка `HandshakeFreshness.isActive → WGPeer.isActive → WGInterface.isConnected → isAnyConnected → showsConnected` в продакшене других потребителей не имеет; карточка красится напрямую от `HandshakeFreshness` (`StatusCardView.swift`), туннельные моки в тестах модели уже несут счётчики вызовов. Прецедент формата и подхода — `docs/plans/20260826-tunnel-management.md` (обычный подход, не TDD). Тесты только через `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` (CLT без XCTest).

## Development Approach

- Подход: обычный (код → тесты в каждой задаче), не TDD — прецедент плана 20260826-tunnel-management.
- Задачи строго по порядку; гейт каждой задачи — `swift build` + зелёный полный сьют (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`).
- Тесты — отдельными чекбоксами, не в одном пункте с кодом; success + error сценарии.
- План живой: ➕ — новые задачи, ⚠️ — блокеры; при отклонении скоупа обновлять план.
- Имена (`showsTunnelUp`, `iconUp`) — предложения; при реализации допустимы синонимы при сохранении семантики (зафиксировать в плане).

## Testing Strategy

- Unit-тесты обязательны в каждой задаче (см. задачи).
- E2E/UI-автотестов в проекте нет (NSStatusItem/NSHostingView в тесты не тянутся — конвенция проекта); ручной GUI-чеклист — в Post-Completion.
- Таймер как единица не тестируется (замыкание тривиальное, конвенция сохраняется); логика `loadTunnels` покрыта напрямую модельными тестами с моком.

## Progress Tracking

- Отмечать `[x]` сразу после выполнения.
- ➕ — новые обнаруженные задачи, ⚠️ — блокеры.
- Завершённый план переносится в `docs/plans/completed/`.

## Solution Overview

Два независимых клиентских изменения:

1. **Иконка от дампа.** `showsTunnelUp = !interfaces.isEmpty && !isDataStale`. Оба слагаемых обязательны: пустой дамп → off; непустой, но устаревший (> `stalenessLimit` 10 с) → off. Дамп, а не `state`, потому что: приходит каждые 5 с уже сейчас в обоих режимах (демон и sudo-фолбэк без демона, где `tunnels` всегда пуст и иконка от `state` гасла бы навсегда); staleness-гейт от того же тика — одна формула; `state` — каталог конфигов и не видит туннели вне каталога (конфиг удалили при поднятом туннеле), дамп честнее. Мёртвая после смены семантики цепочка `isActive → isConnected → isAnyConnected` удаляется целиком.
2. **Опрос `state` каждые 5 с.** Таймер дёргает `refresh()` + `loadTunnels()`; в `loadTunnels()` добавляется гард `inFlightTunnels.isEmpty` — симметрично `refresh()`: во время операции (бюджет ≤ 9 с) запрос не выстраивается в очередь демона, ответ был бы отброшен latest-wins поколением (`loadTunnelsGeneration`) всё равно. Бюджет очереди демона не ломается: show ≤ 4 с + state ~0 (скан каталога, без процессов) + op ≤ 9 с ≈ 13 с < 16 с `opTimeout`; константы и инвариант-тест не трогаются. Открытое меню не мерцает: `tunnels` репаблишится только при изменении (:534), подписка `$tunnels` переворачивает строки. Оптимистичный flip после up/down сходится как раньше (механизм поколений не меняется). Ошибки `state` глотаются молча — данные меню оппортунистические.

Спецэффект для VoiceOver: `menuTitle` («wg: on/off») теперь озвучивает «туннель поднят», а не «свежий хендшейк» — тексты не меняются.

## Technical Details

- Формула: `public var showsTunnelUp: Bool { !interfaces.isEmpty && !isDataStale }`. Технически `isDataStale` при пустом дампе возвращает `false` (`guard !interfaces.isEmpty`), поэтому проверка непустоты обязательна — без неё пустой дамп зажигал бы щиток.
- Удаляемое (продакшн-код): `isAnyConnected` (WireGuardStatusBarCore.swift:282), `WGInterface.isConnected` (Model.swift:14), `WGPeer.isActive` (Model.swift:55), `HandshakeFreshness.isActive` (HandshakeFreshness.swift:20). Пороги свежести (fresh ≤ 120 с, aging ≤ 600 с) и классификация `HandshakeFreshness` остаются — карточка работает от них.
- `loadTunnels()`: порядок гардов — `serviceState == .installed`, затем `inFlightTunnels.isEmpty`; триггеры в doc-комментарии пополняются 5-с тиком.
- Инвариант очереди (без изменений констант): worst case клика = show 4.0 + state ~0 + op 9.0 ≈ 13.0 с < `SocketTunnelClient.opTimeout` 16.0 с.
- Не меняются: демон, протокол, `helperBuildNumber`, локализация («wg: on/off»), карточка, строки меню, ленд-скрипты.

## What Goes Where

- Implementation Steps — только автоматизируемое (код, тесты, документация).
- Post-Completion — ручная проверка живого GUI (без чекбоксов).

## Implementation Steps

### Task 1: Иконка — `showsTunnelUp` и вычистка мёртвой цепочки

**Files:**
- Modify: `Sources/WGStatusBarCore/WireGuardStatusBarCore.swift`
- Modify: `Sources/WGStatusBarCore/Model.swift`
- Modify: `Sources/WGStatusBarCore/HandshakeFreshness.swift`
- Modify: `Sources/WGStatusBarCore/StatusItemController.swift`
- Modify: `Tests/WGStatusBarTests/WGStatusBarTests.swift`
- Modify: `Tests/WGStatusBarTests/HandshakeFreshnessTests.swift`

- [x] `WireGuardStatusBarCore.swift`: `showsConnected` (:304) → `showsTunnelUp` = `!interfaces.isEmpty && !isDataStale`; doc-комментарий — иконка отражает факт поднятого туннеля, хендшейки живут в карточке, устаревший снапшот щиток не зажигает; `menuTitle` (:325) читает новое имя, тексты «wg: on/off» не меняются
- [x] Удалить мёртвую цепочку: `isAnyConnected` (:282), `WGInterface.isConnected` (Model.swift:14), `WGPeer.isActive` (Model.swift:55), `HandshakeFreshness.isActive` (HandshakeFreshness.swift:20) вместе с их doc-комментариями
- [x] `StatusItemController.swift`: `iconConnected(for:)` (:307) переименовать в пару к новому свойству (`iconUp(for:)`), поправить doc-комментарий (:306)
- [x] Тесты WGStatusBarTests — новая семантика: переписать кейсы :207–213, :224, :233, :280, :460, :479, :500, :526, :534, :543–544, :562–569, :586–592, :1112 на «on = интерфейс есть + данные свежие»; добавить регрессионный кейс жалобы: интерфейс есть, все хендшейки stale/never → щиток горит; «off» = интерфейсов нет / данные устарели
- [x] Тесты — удалить кейсы мёртвого кода: `WGPeer.isActive` (`testPeerActivityUsesHandshakeFreshness` :166–170), `isConnected` (`testInterfaceConnectedWhenAnyPeerActive` :172–176), `isAnyConnected` (:211–213, :501, :543), инвариант `showsConnected == isAnyConnected` (:459), `HandshakeFreshness.isActive` (HandshakeFreshnessTests :45–61); MARK :164 («активность через HandshakeFreshness») убрать вместе с тестом, MARK :178 переформулировать без `isAnyConnected`
- [x] Grep-свит doc-комментариев в Sources/ по `showsConnected`/`iconConnected`/«подключён»: doc `iconConnected` (:306), `updateStatusIcon` (:296 — «заливка = подключён» → туннель-семантика); прочие упоминания найдёт свит
- [x] Гейт: `swift build` + `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` — зелёный полный сьют

### Task 2: Опрос `state` каждые 5 секунд

**Files:**
- Modify: `Sources/WGStatusBarCore/WireGuardStatusBarCore.swift`
- Modify: `Sources/WGStatusBarCore/Model.swift`
- Modify: `Sources/WGStatusBarCore/StatusItemController.swift`
- Modify: `Tests/WGStatusBarTests/WGStatusBarTests.swift`

- [x] `startTimer()` (:599): замыкание таймера дёргает `refresh()` + `loadTunnels()`; doc-комментарий таймера дополнить (тик теперь несёт и данные меню)
- [x] `loadTunnels()` (:509): добавить гард `guard inFlightTunnels.isEmpty` после гарда `serviceState` (:510); переписать doc-комментарий — триггеры пополняются 5-с тиком («never in the 5-second tick» уходит), при in-flight операции запрос не выстраивается в очередь демона
- [x] Doc-комментарии, ложные после появления тикового `state`: `TunnelInfo` (Model.swift:63–64 — «5-с тик его не переворачивает» уходит, список триггеров пополняется тиком), `inFlightTunnels` (:185–188 — «show-тик подавлен» → show- и state-тики подавлены), `updateRefreshItemEnabledState` (StatusItemController.swift:314 — «глушит show-тик» → оба тика)
- [x] Тест (success): при `serviceState == .installed` без in-flight операции вызов `loadTunnels()` отправляет `state` (счётчик мока растёт) — существующий поток тестов дополняется прямым кейсом тикового вызова
- [x] Тест (guard): имя в `inFlightTunnels` → `loadTunnels()` не отправляет `state` (счётчик не растёт); после завершения операции явный post-op `loadTunnels()` отправляет
- [x] Гейт: `swift build` + `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` — зелёный полный сьют

### Task 3: Документация

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`

- [ ] README:15 — иконка «on» = поднят хоть один wg-интерфейс (есть в дампе) + данные свежи; хендшейк-свежесть описывается как атрибут карточки (README:17–19 уже так); README:37 — правило «peer is active / interface is connected» заменить на факт-семантику иконки
- [ ] README:38, :143–145 — сверить формулировки: сталость/потеря источника остаются как есть, «connected»-слова заменить на туннель-семантику где нужно
- [ ] CLAUDE.md: Domain rules — абзац про `showsConnected`/`isActive`/`isConnected` переписать под `showsTunnelUp` = наличие интерфейса + свежесть; Tunnels data flow — 5-с тик становится триггером `loadTunnels()` (убрать «never in the 5-second tick»); буллет `TunnelInfo` в секции WGStatusBarCore (список триггеров state); абзац Data flow вверху («A `Timer` re-fires refresh every 5 seconds»; «it no longer feeds the icon (`showsConnected`)»); инвариант бюджета дополнить (+ state ~0 в очереди, show + state + op ≈ 13 с < 16 с); Testing notes — `iconUp` вместо `iconConnected`, новые кейсы
- [ ] Гейт: `swift build` + `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` — зелёный полный сьют (доки не ломают код, но сверка идёт на зелёной базе)

### Task 4: Verify acceptance criteria

- [ ] Все требования Overview реализованы: иконка от факта туннеля, staleness-гейт сохранён, опрос state каждые 5 с, гард in-flight, мёртвый код удалён
- [ ] Краевые случаи покрыты тестами: пустой дамп → off; все хендшейки stale/never → on; устаревший снапшот → off; sudo-фолбэк без демона — тиковый `loadTunnels()` тихий no-op
- [ ] Полный сьют: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
- [ ] E2E-тестов в проекте нет (конвенция) — ручной чеклист в Post-Completion

### Task 5: [Final] Завершение плана

- [ ] Перенести план в `docs/plans/completed/`
- [ ] Финальная сверка: все чекбоксы `[x]`, сьют зелёный

## Post-Completion

**Ручная проверка (живой GUI, оба режима — демон и `sudo .build/debug/WGStatusBar`):**

- Поднятый туннель без трафика ≥ 10 минут: щиток горит, точки карточки серые, «N назад» растёт — исходная жалоба закрыта.
- Только что поднятый туннель (хендшейков ещё не было): щиток зажигается сразу после первого тика (≤ 5 с).
- `sudo wg-quick down <name>` при закрытом меню: щиток гаснет ≤ 5 с; при открытом меню: строка ●→○ переворачивается ≤ 5 с без мерцания остальных.
- Потеря демона (`launchctl bootout …`): щиток гаснет ~10–15 с, карточка приглушает снапшот с пометкой устаревания — поведение фикса №3 сохранилось.
- Туннельная операция из меню: во время спиннера меню не дёргается state-запросами, после ответа данные сходятся.
