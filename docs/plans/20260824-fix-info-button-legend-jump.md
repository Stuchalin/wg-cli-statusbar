# Fix: прыгающая ⓘ-кнопка легенды в карточке статуса

## Overview

Кнопка ⓘ (info.circle, переключатель легенды цветов) в SwiftUI-карточке первого
пункта меню при нажатии исчезает до прихода тика обновления (≤5 с), затем
возвращается — и высота карточки прыгает. Фикс устраняет прыжки (замер высоты
переносится на проход run loop после рендера SwiftUI) и заодно делает легенду
переживающей переоткрытие меню (сейчас `rebuildMenu()` в `menuNeedsUpdate`
создаёт новый `NSHostingView`, и `@State isLegendVisible` сбрасывается).

Критерии готовности (проверяются в Task 2 и ручным чеклистом):

- нажатие ⓘ разворачивает/сворачивает легенду сразу, кнопка не исчезает,
  высота меняется один раз — без «возвращения» на тике обновления;
- легенда сохраняет состояние при закрытии/переоткрытии меню;
- существующий тест-сьют и обе сборки (debug/release) зелёные.

## Context (from discovery)

- Файлы: `Sources/WGStatusBarCore/StatusCardView.swift`,
  `Sources/WGStatusBarCore/StatusItemController.swift` — единственный call site
  `StatusCardView(` находится в `StatusItemController.makeCardItem`
  (проверено grep'ом, других потребителей нет).
- Корневая причина (подтверждена scratch-тестом с изолированным `NSHostingView`):
  кнопка делает `isLegendVisible.toggle()` и тут же **синхронно** зовёт
  `onContentChange()` → `resizeCardToContent()` читает `hostingView.fittingSize`
  в том же стеке вызовов. SwiftUI коммитит рендер позже — замер возвращает
  старую высоту, `guard abs(fittingSize.height - frame.height) > 0.5` не
  проходит, frame не растёт. Контент с легендой рендерится в старый короткий
  frame и обрезается (верхний ряд с кнопкой срезается). Через ≤5 с тик модели →
  `modelDidChange()` → `resizeCardToContent()` — теперь замер валиден, frame
  растёт: кнопка возвращается, высота прыгает.
  Scratch-тест: синхронный замер после мутации = delta 0 (старая высота 65),
  замер через `DispatchQueue.main.async` = delta 57 (новая высота 122).
- Паттерн проекта: тонкая SwiftUI-вёрстка поверх чистой view-модели; владелец
  frame хостинга — `StatusItemController` (подход CodexBar: frame высотой 1 →
  `fittingSize` → итоговый frame).

## Development Approach

- **Testing approach**: Regular (код → сборка → существующий тест-сьют).
- Изменения локальные, два файла, без новых API и зависимостей; смена сигнатуры
  колбэка вью и его единственного call site — одно атомарное изменение, поэтому
  выполняется в одной задаче (между частями сборка была бы красной).
- Каждый этап завершается сборкой/тестами перед переходом к следующему.
- Тест-инвариант проекта (CLAUDE.md): в юнит-тестах не используются
  `NSStatusItem`/`NSHostingView` — изменяемый код живёт именно в этом слое,
  поэтому автоматических тестов на фикс нет; гейт — зелёная сборка и
  неменяемый существующий сьют + ручной чеклист (Post-Completion).

## Testing Strategy

- **Unit-тесты**: не добавляются — по конвенции проекта слой
  `NSHostingView`/`NSStatusItem` из тестов исключён; существующий сьют
  (`swift test`) обязан оставаться зелёным после каждого этапа.
- **E2e-тесты**: в проекте отсутствуют.
- **Ручная верификация**: чеклист в Post-Completion (мгновенное разворачивание
  легенды без исчезновения кнопки, память легенды между открытиями меню,
  сворачивание без прыжков).

## Progress Tracking

- Отмечать выполненные пункты `[x]` сразу после завершения.
- Новые задачи помечать ➕, блокеры ⚠️.
- Держать план в синхроне с фактической работой.

## Solution Overview

Два независимых изменения, согласованных на брейншторме (вариант A + память
легенды):

1. **Async-замер**: колбэк переключения легенды в контроллере диспатчит
   `resizeCardToContent()` через `DispatchQueue.main.async` — замер выполняется
   после рендера SwiftUI, frame меняется сразу при клике.
2. **Память легенды**: видимость легенды хранится в контроллере
   (`isLegendVisible`) и сеется в новую вью при каждой пересборке меню.
   Внутри вью остаётся `@State` (мгновенный гарантированный ре-рендер):
   рукописный `Binding(get:set:)` не гарантирует инвалидацию вью, легенда ждала
   бы тика модели — тот же баг в новой упаковке.

Ключевые решения и обоснование:

- `onContentChange: () -> Void` заменяется на `onLegendChange: (Bool) -> Void`:
  его единственный потребитель — кнопка легенды, а контроллеру нужно и новое
  значение (сохранить), и момент (перемерять).
- Тайминг `DispatchQueue.main.async` идентичен уже работающему паттерну
  `receive(on: DispatchQueue.main)` в sink модели — именно он сегодня даёт
  валидный замер на тике (высота «доскакивает» при открытом меню).
- `modelDidChange()` → `resizeCardToContent()` не меняется: его синхронный
  замер стоит на валидном тайминге (async-доставка sink после мутации).
- `helperBuildNumber` не бампаем: меняется только app-side код общей библиотеки
  (карточка/контроллер меню); кодовые пути демона не затронуты.

## Technical Details

`StatusCardView`:

```swift
public init(
    model: WireGuardStatusModel,
    initialLegendVisible: Bool = false,
    onLegendChange: @escaping (Bool) -> Void = { _ in }
) {
    self.model = model
    _isLegendVisible = State(initialValue: initialLegendVisible)
    self.onLegendChange = onLegendChange
}

// кнопка ⓘ:
Button {
    isLegendVisible.toggle()
    onLegendChange(isLegendVisible)
} label: { ... }
```

`StatusItemController`:

```swift
/// Видимость легенды: хранится здесь, чтобы переживать пересборки меню
/// (menuNeedsUpdate создаёт новый NSHostingView — @State вью сбрасывается).
private var isLegendVisible = false

// в makeCardItem:
let cardView = StatusCardView(
    model: model,
    initialLegendVisible: isLegendVisible
) { [weak self] visible in
    self?.legendToggled(to: visible)
}

private func legendToggled(to visible: Bool) {
    isLegendVisible = visible
    // SwiftUI коммитит рендер после текущего стека вызовов: синхронный замер
    // видел бы старую высоту (ⓘ исчезала до следующего тика) — мерим на
    // следующем проходе run loop, когда контент уже перестроен.
    DispatchQueue.main.async { [weak self] in self?.resizeCardToContent() }
}
```

Обновляемые док-комментарии: шапка `StatusCardView` (строки 141–145 про
`onContentChange`), комментарий `installCommandsSection` (строка 287 — «высота
блока постоянна — `onContentChange` не нужен», переформулировать без старого
имени колбэка) и комментарий `resizeCardToContent` (строки 283–284).

## What Goes Where

- **Implementation Steps**: правки двух файлов + гейты сборки/тестов.
- **Post-Completion**: ручной UI-чеклист, перемещение плана в `completed/`.

## Implementation Steps

### Task 1: Async-замер и память легенды (вью + контроллер, атомарно)

Смена сигнатуры колбэка вью и его единственного call site — одно изменение:
между ними сборка не собирается, поэтому одна задача.

**Files:**
- Modify: `Sources/WGStatusBarCore/StatusCardView.swift`
- Modify: `Sources/WGStatusBarCore/StatusItemController.swift`

- [ ] `StatusCardView`: заменить `onContentChange: () -> Void` на `onLegendChange: @escaping (Bool) -> Void` и добавить параметр `initialLegendVisible: Bool = false` в init; `_isLegendVisible = State(initialValue:)`
- [ ] `StatusCardView`, кнопка ⓘ: `isLegendVisible.toggle(); onLegendChange(isLegendVisible)` (вместо `onContentChange()`)
- [ ] `StatusItemController`: добавить `private var isLegendVisible = false` с комментарием о переживании пересборок меню
- [ ] `StatusItemController.makeCardItem`: передать `initialLegendVisible: isLegendVisible` и колбэк `{ [weak self] visible in self?.legendToggled(to: visible) }`
- [ ] `StatusItemController`: реализовать `legendToggled(to:)` — сохранить значение + `DispatchQueue.main.async { [weak self] in self?.resizeCardToContent() }` с тайминговым комментарием (синхронный замер видит старую высоту)
- [ ] обновить док-комментарии: шапка `StatusCardView` (механика посева/репорта), комментарий `installCommandsSection` (строка 287, убрать упоминание `onContentChange`), комментарий `resizeCardToContent` (замер валиден только после рендера SwiftUI)
- [ ] `swift build` — без ошибок
- [ ] `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` — сьют зелёный (тесты не меняются)
- [ ] убедиться, что упоминаний `onContentChange` в коде не осталось: `grep -rn onContentChange Sources/ Tests/` — пусто

### Task 2: Verify acceptance criteria

- [ ] критерии из Overview реализованы: async-замер (кнопка не исчезает, высота меняется один раз) + память легенды между переоткрытиями меню
- [ ] полный сьют: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` — зелёный
- [ ] `swift build -c release` — зелёный
- [ ] код-ревью диффа: подпись колбэков, weak-захваты (`[weak self] visible in …`, `[weak self] in self?…`), отсутствие лишних изменений

### Task 3: [Final] Update documentation

**Files:**
- Modify: `CLAUDE.md` (если описание перестало соответствовать коду)
- Move: `docs/plans/20260824-fix-info-button-legend-jump.md` → `docs/plans/completed/`

- [ ] обновить CLAUDE.md, если описание `StatusItemController`/карточки перестало соответствовать коду (легенда теперь хранится в контроллере)
- [ ] переместить план в `docs/plans/completed/`

## Post-Completion

**Manual verification** (ручной чеклист на машине с GUI, после `swift build`):

- [ ] открыть меню → нажать ⓘ → легенда разворачивается сразу, кнопка ⓘ не исчезает, высота меняется один раз без «возвращения» через ~5 с
- [ ] при открытом меню дождаться 1–2 тиков обновления (5 с) → без прыжков высоты и миганий карточки
- [ ] нажать ⓘ повторно → сворачивание легенды тоже мгновенное и без прыжков
- [ ] развернуть легенду → закрыть меню → открыть снова → легенда всё ещё развёрнута, высота карточки сразу правильная — без обрезки легенды и без доскакивания на следующем тике
- [ ] состояние wg-missing (wg не установлен — карточка с командами установки CLI) → ⓘ работает без прыжков

**External system updates**: не требуются.
