import XCTest
@testable import WGStatusBarCore

/// Модель окна вьювера: переходы, поколение (поздние результаты гасятся),
/// raw-состояние (только после успешной аутентификации + привилегированного
/// чтения), повторные действия. Все границы инжектированы — системных
/// промптов и реального демона здесь нет.
final class ConfigViewerModelTests: XCTestCase {
    // MARK: - Фикстуры

    /// Ридер маскированного конфига с клапанами: каждый запрос висит, пока
    /// тест не отпустит его результатом, — так проверяются гонки поколений.
    /// Отпускание — по имени запроса: порядок старта detached-задач не
    /// детерминирован, тест адресует именно тот запрос, который нужен.
    private final class GatedMaskedReader: MaskedConfigReading {
        private struct Pending {
            let name: String
            let continuation: CheckedContinuation<TunnelConfigDocument, Error>
        }

        private let lock = NSLock()
        private var pending: [Pending] = []
        private var requestedNamesStorage: [String] = []

        var requestedNames: [String] {
            lock.withLock { requestedNamesStorage }
        }

        var pendingCount: Int {
            lock.withLock { pending.count }
        }

        func maskedConfig(named name: String) async throws -> TunnelConfigDocument {
            lock.withLock { requestedNamesStorage.append(name) }
            return try await withCheckedThrowingContinuation { continuation in
                lock.withLock { pending.append(Pending(name: name, continuation: continuation)) }
            }
        }

        /// Резюмит первый висящий запрос с этим именем заданным результатом.
        func complete(name: String, with result: Result<TunnelConfigDocument, Error>) {
            lock.withLock {
                guard let index = pending.firstIndex(where: { $0.name == name }) else { return }
                let continuation = pending.remove(at: index).continuation
                switch result {
                case .success(let document):
                    continuation.resume(returning: document)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }

        deinit {
            // Недорезюменные продолжения — утечка; гасим безопасным сбоем.
            lock.withLock {
                pending.forEach { $0.continuation.resume(throwing: ConfigFetchError.badResponse) }
            }
        }
    }

    /// Оркестратор Reveal с клапанами: фиксирует вызовы (имя + состояние
    /// сервиса), результатом управляет тест.
    private final class MockRevealExecutor: ConfigRevealExecuting {
        private let lock = NSLock()
        private var continuations: [CheckedContinuation<ConfigRevealOutcome, Never>] = []
        private var callsStorage: [(name: String, serviceState: ServiceState)] = []

        var calls: [(name: String, serviceState: ServiceState)] {
            lock.withLock { callsStorage }
        }

        var pendingCount: Int {
            lock.withLock { continuations.count }
        }

        func reveal(named name: String, serviceState: ServiceState) async -> ConfigRevealOutcome {
            lock.withLock { callsStorage.append((name, serviceState)) }
            return await withCheckedContinuation { continuation in
                lock.withLock { continuations.append(continuation) }
            }
        }

        func completeNext(with outcome: ConfigRevealOutcome) {
            lock.withLock {
                guard !continuations.isEmpty else { return }
                continuations.removeFirst().resume(returning: outcome)
            }
        }

        deinit {
            lock.withLock { continuations.forEach { $0.resume(returning: .cancelledByUser) } }
        }
    }

    private func makeModel(
        serviceState: ServiceState = .installed
    ) -> (model: ConfigViewerModel, reader: GatedMaskedReader, executor: MockRevealExecutor) {
        let reader = GatedMaskedReader()
        let executor = MockRevealExecutor()
        let model = ConfigViewerModel(
            maskedReader: reader,
            revealExecutor: executor,
            serviceStateProvider: { serviceState }
        )
        return (model, reader, executor)
    }

    /// Крутит run loop, пока условие не выполнится или не истечёт дедлайн —
    /// завершения задач приезжают через MainActor.run в главную очередь.
    private func waitUntil(_ condition: () -> Bool, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "условие не выполнилось за 2 с", line: line)
    }

    /// Загружает маскированный документ и ждёт применения: сначала ждёт
    /// регистрации клапана (старт detached-задачи асинхронен), затем
    /// отпускает его результатом.
    private func loadMasked(_ text: String, in model: ConfigViewerModel, reader: GatedMaskedReader, line: UInt = #line) {
        model.show(name: "kvmka-ai")
        waitUntil({ reader.pendingCount > 0 }, line: line)
        reader.complete(name: "kvmka-ai", with: .success(TunnelConfigDocument(text: text)))
        waitUntil({ !model.isLoading && model.displayedText == text }, line: line)
    }

    /// Запускает Reveal и доводит до заданного исхода.
    private func reveal(_ outcome: ConfigRevealOutcome, in model: ConfigViewerModel, executor: MockRevealExecutor, line: UInt = #line) {
        model.revealSecrets()
        waitUntil({ executor.pendingCount > 0 }, line: line)
        executor.completeNext(with: outcome)
        waitUntil({ !model.isRevealing }, line: line)
    }

    // MARK: - Загрузка маскированного документа

    func testShowSetsLoadingAndNameImmediately() {
        let (model, reader, _) = makeModel()

        model.show(name: "kvmka-ai")

        // Синхронно, до любого ответа: имя выбрано, документ пуст, загрузка идёт.
        XCTAssertEqual(model.tunnelName, "kvmka-ai")
        XCTAssertTrue(model.isLoading)
        XCTAssertEqual(model.displayedText, "")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(reader.requestedNames, ["kvmka-ai"])
    }

    func testShowAppliesMaskedDocument() {
        let (model, reader, _) = makeModel()
        let document = TunnelConfigDocument(text: "[Interface]\nPrivateKey = (hidden)\n")

        loadMasked(document.text, in: model, reader: reader)

        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.displayedText, document.text)
        XCTAssertEqual(model.mode, .masked)
        XCTAssertNil(model.errorMessage)
    }

    /// Каждый безопасный переход снимает raw-состояние синхронно, до await:
    /// показ другого (или того же) туннеля поверх raw-документа сразу
    /// возвращает маскированный режим и пустой документ.
    func testShowClearsRawStateBeforeAwait() {
        let (model, reader, executor) = makeModel()
        loadMasked("masked", in: model, reader: reader)
        reveal(.revealed(TunnelConfigDocument(text: "raw")), in: model, executor: executor)
        XCTAssertEqual(model.mode, .raw)

        model.show(name: "kvmka-full")

        XCTAssertEqual(model.mode, .masked, "raw-состояние снимается синхронно")
        XCTAssertEqual(model.displayedText, "")
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.isLoading)
    }

    // MARK: - Ошибки загрузки

    func testLoadFailureShowsWindowErrorWithoutPartialDocument() {
        let (model, reader, _) = makeModel()

        model.show(name: "kvmka-ai")
        waitUntil { reader.pendingCount > 0 }
        reader.complete(name: "kvmka-ai", with: .failure(ConfigFetchError.unavailable))
        waitUntil { !model.isLoading }

        XCTAssertEqual(model.errorMessage, L10n.string("config.error.unavailable"))
        XCTAssertEqual(model.displayedText, "", "частичного документа быть не должно")
        XCTAssertEqual(model.mode, .masked)
    }

    /// Маппинг ошибок загрузки в фиксированные категории: старый демон — то
    /// же «обновите сервис», что пункт меню; тишина/отказ — недоступность;
    /// мусор канала и чужие ошибки — общая ошибка загрузки.
    func testLoadErrorMapping() {
        let cases: [(error: Error, key: String)] = [
            (ConfigFetchError.daemonOutdated, "error.daemon_outdated"),
            (ConfigFetchError.connectionRefused, "error.service_unreachable"),
            (ConfigFetchError.timedOut, "error.service_unreachable"),
            (ConfigFetchError.badResponse, "config.error.load_failed"),
            (ConfigFetchError.unavailable, "config.error.unavailable"),
        ]
        for testCase in cases {
            let (model, reader, _) = makeModel()
            model.show(name: "kvmka-ai")
            waitUntil { reader.pendingCount > 0 }
            reader.complete(name: "kvmka-ai", with: .failure(testCase.error))
            waitUntil { !model.isLoading }
            XCTAssertEqual(
                model.errorMessage,
                L10n.string(testCase.key),
                "для \(testCase.error) ожидался текст \(testCase.key)"
            )
        }
    }

    // MARK: - Поколение: поздние результаты гасятся

    /// Закрытие окна во время загрузки: опоздавший документ не применяется.
    func testCloseDuringLoadDiscardsLateCompletion() {
        let (model, reader, _) = makeModel()
        model.show(name: "kvmka-ai")
        XCTAssertTrue(model.isLoading)

        model.close()
        waitUntil { reader.pendingCount > 0 }
        reader.complete(name: "kvmka-ai", with: .success(TunnelConfigDocument(text: "late")))
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        XCTAssertNil(model.tunnelName)
        XCTAssertEqual(model.displayedText, "")
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage)
    }

    /// Смена туннеля: завершение первой загрузки (старое поколение) гасится,
    /// применяется только документ нового туннеля.
    func testSwitchDiscardsFirstCompletion() {
        let (model, reader, _) = makeModel()

        model.show(name: "kvmka-ai")
        model.show(name: "kvmka-full")
        waitUntil { reader.pendingCount == 2 }
        XCTAssertEqual(Set(reader.requestedNames), ["kvmka-ai", "kvmka-full"])

        reader.complete(name: "kvmka-ai", with: .success(TunnelConfigDocument(text: "first")))
        reader.complete(name: "kvmka-full", with: .success(TunnelConfigDocument(text: "second")))
        waitUntil { model.displayedText == "second" }

        XCTAssertEqual(model.tunnelName, "kvmka-full")
        XCTAssertEqual(model.displayedText, "second", "опоздавший документ первого туннеля не применяется")
    }

    /// Reload: поколение растёт, документ перечитывается заново; завершение
    /// загрузки, начатой до Reload, гасится.
    func testReloadFetchesFreshDocumentAndDiscardsStaleGeneration() {
        let (model, reader, _) = makeModel()
        model.show(name: "kvmka-ai")

        model.reload()
        waitUntil { reader.pendingCount == 2 }
        XCTAssertEqual(reader.requestedNames, ["kvmka-ai", "kvmka-ai"], "reload перечитывает тот же туннель")

        // Первый (до-Reload'ный) запрос — старое поколение, гасится; второй —
        // свежий документ. Оба висят под одним именем: разрешение FIFO.
        reader.complete(name: "kvmka-ai", with: .success(TunnelConfigDocument(text: "stale")))
        reader.complete(name: "kvmka-ai", with: .success(TunnelConfigDocument(text: "fresh")))
        waitUntil { model.displayedText == "fresh" }

        XCTAssertEqual(model.displayedText, "fresh", "после Reload показывается свежий документ")
    }

    /// Hide во время висящего Reveal: отмена + рост поколения — опоздавший
    /// raw-результат не возвращается в показ.
    func testHideCancelsPendingRevealAndDiscardsLateResult() {
        let (model, reader, executor) = makeModel()
        loadMasked("masked", in: model, reader: reader)

        model.revealSecrets()
        waitUntil { executor.pendingCount > 0 }
        model.hideSecrets()
        XCTAssertFalse(model.isRevealing, "Hide снимает revealing синхронно")

        executor.completeNext(with: .revealed(TunnelConfigDocument(text: "late raw")))
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        XCTAssertEqual(model.mode, .masked)
        XCTAssertEqual(model.displayedText, "masked", "опоздавший raw-результат гасится поколением")
    }

    // MARK: - Reveal

    /// Файл мог измениться между маскированной загрузкой и Reveal: документ
    /// заменяется целиком только что прочитанной raw-версией.
    func testRevealReplacesWholeDocument() {
        let (model, reader, executor) = makeModel()
        loadMasked("masked version", in: model, reader: reader)

        reveal(.revealed(TunnelConfigDocument(text: "raw version")), in: model, executor: executor)

        XCTAssertEqual(model.displayedText, "raw version", "raw-версия заменяет документ целиком")
        XCTAssertEqual(model.mode, .raw)
    }

    /// Отмена пользователем (аутентификация, админ-промпт) — не ошибка:
    /// маскированный документ сохраняется.
    func testRevealCancelKeepsMaskedDocument() {
        let (model, reader, executor) = makeModel()
        loadMasked("masked", in: model, reader: reader)

        reveal(.cancelledByUser, in: model, executor: executor)

        XCTAssertEqual(model.mode, .masked)
        XCTAssertEqual(model.displayedText, "masked")
        XCTAssertNil(model.errorMessage)
    }

    /// Сбой Reveal: оконная ошибка из фиксированной категории, маскированный
    /// документ сохраняется.
    func testRevealFailureShowsErrorAndKeepsMaskedDocument() {
        let (model, reader, executor) = makeModel()
        loadMasked("masked", in: model, reader: reader)

        reveal(.failed(.authenticationFailed), in: model, executor: executor)

        XCTAssertEqual(model.mode, .masked, "raw — только после успеха")
        XCTAssertEqual(model.displayedText, "masked")
        XCTAssertEqual(model.errorMessage, PrivilegedConfigError.authenticationFailed.userMessage)
    }

    /// Reveal во время загрузки — молчаливый no-op: оркестратор не вызывается.
    func testRevealIgnoredWhileLoading() {
        let (model, _, executor) = makeModel()
        model.show(name: "kvmka-ai")
        XCTAssertTrue(model.isLoading)

        model.revealSecrets()
        // Даём гипотетической задаче шанс проявиться — guard модели её не создаёт.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        XCTAssertTrue(executor.calls.isEmpty, "Reveal при загрузке не доходит до оркестратора")
    }

    /// Повторный Reveal во время выполняющегося — подавлен (одна операция).
    func testDuplicateRevealIsIgnored() {
        let (model, reader, executor) = makeModel()
        loadMasked("masked", in: model, reader: reader)

        model.revealSecrets()
        model.revealSecrets()
        waitUntil { executor.calls.count == 1 }
        XCTAssertEqual(executor.calls.count, 1, "второй Reveal — тихий no-op")
        executor.completeNext(with: .cancelledByUser)
    }

    /// Провайдер состояния сервиса доходит до оркестратора as-is: fail-closed
    /// решение (.absent/.broken/.outdated → гайденс) принимает оркестратор.
    func testServiceStateFlowsToExecutor() {
        let (model, reader, executor) = makeModel(serviceState: .outdated)
        loadMasked("masked", in: model, reader: reader)

        model.revealSecrets()
        waitUntil { !executor.calls.isEmpty }

        XCTAssertEqual(executor.calls.first?.name, "kvmka-ai")
        XCTAssertEqual(executor.calls.first?.serviceState, .outdated)
        executor.completeNext(with: .failed(.serviceUpdateRequired))
    }

    // MARK: - Hide и закрытие

    /// Hide возвращает показ к маскированному документу без перезагрузки.
    func testHideRestoresMaskedDocument() {
        let (model, reader, executor) = makeModel()
        loadMasked("masked body", in: model, reader: reader)
        reveal(.revealed(TunnelConfigDocument(text: "raw body")), in: model, executor: executor)

        model.hideSecrets()

        XCTAssertEqual(model.mode, .masked, "Hide снимает raw синхронно")
        XCTAssertEqual(model.displayedText, "masked body")
    }

    /// Закрытие окна снимает состояние целиком.
    func testCloseClearsAllState() {
        let (model, reader, executor) = makeModel()
        loadMasked("masked", in: model, reader: reader)
        reveal(.revealed(TunnelConfigDocument(text: "raw")), in: model, executor: executor)

        model.close()

        XCTAssertNil(model.tunnelName)
        XCTAssertEqual(model.displayedText, "")
        XCTAssertEqual(model.mode, .masked)
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.isRevealing)
        XCTAssertNil(model.errorMessage)
    }
}
