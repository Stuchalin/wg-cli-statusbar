import XCTest
@testable import WGStatusBarCore

/// Ридер конфигов: резолв по приоритету каталогов, дескрипторное чтение
/// с лимитом, точное сохранение текста (включая завершающий `\n`) и
/// типизированные ошибки без содержимого.
final class TunnelConfigReaderTests: XCTestCase {
    /// Фейковый FS: исходы открытия по точному пути.
    private final class FakeReaderFileSystem: TunnelConfigReaderFileSystem {
        var outcomes: [String: TunnelConfigOpenOutcome] = [:]
        private(set) var openedPaths: [String] = []

        func openFileNoFollow(atPath path: String) -> TunnelConfigOpenOutcome {
            openedPaths.append(path)
            return outcomes[path] ?? .notFound
        }
    }

    /// Фейковый дескриптор: содержимое кусками, EINTR, падающие чтения,
    /// нерегулярность по fstat, счётчик close.
    private final class FakeReaderFileHandle: TunnelConfigReaderFileHandle {
        var content: [UInt8]
        var regular = true
        var interruptFirstReads = 0
        var failAllReads = false
        var maxChunkSize = Int.max
        private var offset = 0
        private(set) var closeCount = 0

        init(content: [UInt8]) {
            self.content = content
        }

        var isRegularFile: Bool { regular }

        func read(into buffer: UnsafeMutableRawPointer, maxLength: Int) -> TunnelConfigReadChunk {
            if failAllReads { return .failed }
            if interruptFirstReads > 0 {
                interruptFirstReads -= 1
                return .interrupted
            }
            guard offset < content.count else { return .endOfFile }
            let count = min(maxLength, maxChunkSize, content.count - offset)
            content.withUnsafeBytes { raw in
                _ = memcpy(buffer, raw.baseAddress!.advanced(by: offset), count)
            }
            offset += count
            return .bytes(count)
        }

        func close() {
            closeCount += 1
        }
    }

    private let searchPaths = [
        "/etc/wireguard",
        "/usr/local/etc/wireguard",
        "/opt/homebrew/etc/wireguard",
        "/opt/local/etc/wireguard",
    ]

    private func configPath(_ directory: String, _ name: String) -> String {
        directory + "/" + name + ".conf"
    }

    private func makeReader(_ fs: FakeReaderFileSystem) -> TunnelConfigReader {
        TunnelConfigReader(searchPaths: searchPaths, fileSystem: fs)
    }

    private func bytes(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }

    private func success(
        _ result: Result<TunnelConfigDocument, TunnelConfigReaderError>
    ) -> TunnelConfigDocument {
        guard case .success(let document) = result else {
            XCTFail("ожидался успех, получено: \(result)")
            return TunnelConfigDocument(text: "")
        }
        return document
    }

    private func failure(
        _ result: Result<TunnelConfigDocument, TunnelConfigReaderError>
    ) -> TunnelConfigReaderError {
        guard case .failure(let error) = result else {
            XCTFail("ожидалась ошибка, получено: \(result)")
            return .invalidName
        }
        return error
    }

    // MARK: - успех

    func testSuccessReturnsExactTextWithFinalNewline() {
        let fs = FakeReaderFileSystem()
        let text = "[Interface]\nPrivateKey = abc\n[Peer]\nPresharedKey = def\n"
        fs.outcomes[configPath("/etc/wireguard", "work")] = .opened(FakeReaderFileHandle(content: bytes(text)))
        let document = success(makeReader(fs).readConfig(named: "work"))

        XCTAssertEqual(document.text, text, "текст возвращается байт-в-байт")
        XCTAssertTrue(document.hasFinalNewline)
    }

    func testSuccessPreservesMissingFinalNewline() {
        let fs = FakeReaderFileSystem()
        let text = "[Interface]\nListenPort = 51820"
        fs.outcomes[configPath("/etc/wireguard", "work")] = .opened(FakeReaderFileHandle(content: bytes(text)))
        let document = success(makeReader(fs).readConfig(named: "work"))

        XCTAssertEqual(document.text, text, "завершающий перевод строки не добавляется")
        XCTAssertFalse(document.hasFinalNewline)
    }

    func testEmptyFileYieldsEmptyDocument() {
        let fs = FakeReaderFileSystem()
        fs.outcomes[configPath("/etc/wireguard", "work")] = .opened(FakeReaderFileHandle(content: []))
        let document = success(makeReader(fs).readConfig(named: "work"))

        XCTAssertEqual(document.text, "")
        XCTAssertFalse(document.hasFinalNewline)
    }

    func testReadsDeliveredInSmallChunksReassembleMultibyteUTF8() {
        // Многобайтовые символы режутся между read-вызовами: декод — только
        // после полного накопления, «частичный документ» не существует.
        let fs = FakeReaderFileSystem()
        let text = "[Interface]\n# комментарий — émoji 🇷🇺 и хвост\n"
        let handle = FakeReaderFileHandle(content: bytes(text))
        handle.maxChunkSize = 1
        fs.outcomes[configPath("/etc/wireguard", "work")] = .opened(handle)
        let document = success(makeReader(fs).readConfig(named: "work"))

        XCTAssertEqual(document.text, text)
    }

    // MARK: - резолв по приоритету

    func testSearchPrecedencePicksFirstDirectoryMatch() {
        let fs = FakeReaderFileSystem()
        fs.outcomes[configPath("/etc/wireguard", "work")] = .opened(FakeReaderFileHandle(content: bytes("first\n")))
        fs.outcomes[configPath("/opt/homebrew/etc/wireguard", "work")] = .opened(FakeReaderFileHandle(content: bytes("second\n")))
        let document = success(makeReader(fs).readConfig(named: "work"))

        XCTAssertEqual(document.text, "first\n")
        XCTAssertEqual(fs.openedPaths, [configPath("/etc/wireguard", "work")], "ниже по приоритету не открывается")
    }

    func testSkipsAbsentDirectoriesToLaterPath() {
        let fs = FakeReaderFileSystem()
        fs.outcomes[configPath("/opt/homebrew/etc/wireguard", "work")] = .opened(FakeReaderFileHandle(content: bytes("brew\n")))
        let document = success(makeReader(fs).readConfig(named: "work"))

        XCTAssertEqual(document.text, "brew\n")
        XCTAssertEqual(
            fs.openedPaths,
            [
                configPath("/etc/wireguard", "work"),
                configPath("/usr/local/etc/wireguard", "work"),
                configPath("/opt/homebrew/etc/wireguard", "work"),
            ],
            "отсутствующие каталоги пропускаются по порядку, после матча поиск останавливается"
        )
    }

    func testSpecialRegexCharactersResolveConfPath() {
        // Имя с символами класса regex wg-quick проходит общую shape-проверку
        // и собирается в точный путь `<dir>/<name>.conf`.
        let fs = FakeReaderFileSystem()
        let result = makeReader(fs).readConfig(named: "dots.and-dash_1")

        XCTAssertEqual(failure(result), .notFound)
        XCTAssertEqual(
            fs.openedPaths,
            searchPaths.map { configPath($0, "dots.and-dash_1") }
        )
    }

    // MARK: - небезопасный первый матч

    func testSymlinkFirstMatchDoesNotFallThroughToDuplicate() {
        let fs = FakeReaderFileSystem()
        fs.outcomes[configPath("/etc/wireguard", "work")] = .symlink
        fs.outcomes[configPath("/opt/homebrew/etc/wireguard", "work")] = .opened(FakeReaderFileHandle(content: bytes("duplicate\n")))
        let result = makeReader(fs).readConfig(named: "work")

        XCTAssertEqual(failure(result), .symlink)
        XCTAssertEqual(fs.openedPaths, [configPath("/etc/wireguard", "work")], "дубль ниже приоритетом не открывается")
    }

    func testUnreadableFirstMatchDoesNotFallThroughToDuplicate() {
        let fs = FakeReaderFileSystem()
        fs.outcomes[configPath("/etc/wireguard", "work")] = .unreadable
        fs.outcomes[configPath("/opt/homebrew/etc/wireguard", "work")] = .opened(FakeReaderFileHandle(content: bytes("duplicate\n")))
        let result = makeReader(fs).readConfig(named: "work")

        XCTAssertEqual(failure(result), .unreadable)
        XCTAssertEqual(fs.openedPaths, [configPath("/etc/wireguard", "work")])
    }

    // MARK: - имя

    func testInvalidNameFailsWithoutTouchingFilesystem() {
        let fs = FakeReaderFileSystem()
        let reader = makeReader(fs)
        let invalidNames = [
            "", // пустое
            "bad name", // пробел
            "a/b", // слэш — уже путь
            "../etc/passwd",
            "abcdefghijklmnop", // 16 символов — лимит имён интерфейсов
            "штатный", // юникод
        ]
        for name in invalidNames {
            XCTAssertEqual(failure(reader.readConfig(named: name)), .invalidName, "имя: \(name)")
        }
        XCTAssertTrue(fs.openedPaths.isEmpty, "до файловой системы дело не доходит")
    }

    func testNotFoundWhenNoDirectoryHasConfig() {
        let fs = FakeReaderFileSystem()
        let result = makeReader(fs).readConfig(named: "nosuch")

        XCTAssertEqual(failure(result), .notFound)
        XCTAssertEqual(fs.openedPaths.count, searchPaths.count)
    }

    // MARK: - дескриптор и чтение

    func testNonRegularDescriptorFailsAsNotRegularFile() {
        // Спецфайл или подмена класса файла между open и fstat — чтения нет.
        let fs = FakeReaderFileSystem()
        let handle = FakeReaderFileHandle(content: bytes("fifo-content\n"))
        handle.regular = false
        fs.outcomes[configPath("/etc/wireguard", "work")] = .opened(handle)
        let result = makeReader(fs).readConfig(named: "work")

        XCTAssertEqual(failure(result), .notRegularFile)
        XCTAssertEqual(handle.closeCount, 1)
    }

    func testReadErrorFailsWithoutPartialContent() {
        let fs = FakeReaderFileSystem()
        let handle = FakeReaderFileHandle(content: bytes("partial-content-that-must-not-escape\n"))
        handle.failAllReads = true
        fs.outcomes[configPath("/etc/wireguard", "work")] = .opened(handle)
        let result = makeReader(fs).readConfig(named: "work")

        XCTAssertEqual(failure(result), .unreadable)
        XCTAssertEqual(handle.closeCount, 1)
    }

    func testInterruptedReadsAreRetried() {
        let fs = FakeReaderFileSystem()
        let text = "[Interface]\nPrivateKey = abc\n"
        let handle = FakeReaderFileHandle(content: bytes(text))
        handle.interruptFirstReads = 3
        fs.outcomes[configPath("/etc/wireguard", "work")] = .opened(handle)
        let document = success(makeReader(fs).readConfig(named: "work"))

        XCTAssertEqual(document.text, text)
        XCTAssertEqual(handle.closeCount, 1)
    }

    func testEndlessInterruptedReadsFailAsUnreadable() {
        // Вечный EINTR не подвешивает читающего — потолок прерываний.
        let fs = FakeReaderFileSystem()
        let handle = FakeReaderFileHandle(content: bytes("x\n"))
        handle.interruptFirstReads = Int.max
        fs.outcomes[configPath("/etc/wireguard", "work")] = .opened(handle)
        let result = makeReader(fs).readConfig(named: "work")

        XCTAssertEqual(failure(result), .unreadable)
        XCTAssertEqual(handle.closeCount, 1)
    }

    // MARK: - лимит

    func testExactSizeLimitSucceeds() {
        let fs = FakeReaderFileSystem()
        fs.outcomes[configPath("/etc/wireguard", "work")] = .opened(
            FakeReaderFileHandle(content: [UInt8](repeating: 0x61, count: TunnelConfigReader.maxSizeBytes))
        )
        let document = success(makeReader(fs).readConfig(named: "work"))

        XCTAssertEqual(document.text.utf8.count, TunnelConfigReader.maxSizeBytes)
    }

    func testOneByteOverLimitFailsAsTooLarge() {
        let fs = FakeReaderFileSystem()
        fs.outcomes[configPath("/etc/wireguard", "work")] = .opened(
            FakeReaderFileHandle(content: [UInt8](repeating: 0x61, count: TunnelConfigReader.maxSizeBytes + 1))
        )
        let result = makeReader(fs).readConfig(named: "work")

        XCTAssertEqual(failure(result), .tooLarge)
    }

    func testFarOverLimitFailsAsTooLargeWithoutReadingTail() {
        let fs = FakeReaderFileSystem()
        let handle = FakeReaderFileHandle(content: [UInt8](repeating: 0x61, count: TunnelConfigReader.maxSizeBytes * 4))
        fs.outcomes[configPath("/etc/wireguard", "work")] = .opened(handle)
        let result = makeReader(fs).readConfig(named: "work")

        XCTAssertEqual(failure(result), .tooLarge)
        XCTAssertEqual(handle.closeCount, 1)
    }

    // MARK: - кодировка

    func testInvalidUTF8FailsWholeDocument() {
        let fs = FakeReaderFileSystem()
        fs.outcomes[configPath("/etc/wireguard", "work")] = .opened(FakeReaderFileHandle(content: [0x41, 0xFF, 0x42]))
        let result = makeReader(fs).readConfig(named: "work")

        XCTAssertEqual(failure(result), .invalidUTF8)
    }

    // MARK: - гигиена

    func testCloseCalledOnceOnEveryHandleOutcome() {
        func run(_ handle: FakeReaderFileHandle) -> Result<TunnelConfigDocument, TunnelConfigReaderError> {
            let fs = FakeReaderFileSystem()
            fs.outcomes[configPath("/etc/wireguard", "work")] = .opened(handle)
            let result = makeReader(fs).readConfig(named: "work")
            XCTAssertEqual(handle.closeCount, 1, "дескриптор закрыт ровно один раз")
            return result
        }

        _ = run(FakeReaderFileHandle(content: bytes("ok\n")))
        let irregular = FakeReaderFileHandle(content: bytes("x\n"))
        irregular.regular = false
        _ = run(irregular)
        let failing = FakeReaderFileHandle(content: bytes("x\n"))
        failing.failAllReads = true
        _ = run(failing)
        _ = run(FakeReaderFileHandle(content: [UInt8](repeating: 0x61, count: TunnelConfigReader.maxSizeBytes + 1)))
        _ = run(FakeReaderFileHandle(content: [0x41, 0xFF]))
    }

    func testErrorsExposeNeitherContentNorPaths() {
        // Сентинел содержимого: не настоящее значение ключа, просто метка,
        // которой не должно оказаться ни в одном описании ошибки.
        let contentSentinel = "FILE-CONTENT-SENTINEL-4B91"
        let fs = FakeReaderFileSystem()
        fs.outcomes[configPath("/etc/wireguard", "work")] = .symlink

        var errors: [TunnelConfigReaderError] = [
            failure(makeReader(fs).readConfig(named: "work")),
        ]

        let fsUnreadable = FakeReaderFileSystem()
        fsUnreadable.outcomes[configPath("/etc/wireguard", "work")] = .unreadable
        errors.append(failure(makeReader(fsUnreadable).readConfig(named: "work")))

        let irregular = FakeReaderFileHandle(content: bytes(contentSentinel))
        irregular.regular = false
        let fsIrregular = FakeReaderFileSystem()
        fsIrregular.outcomes[configPath("/etc/wireguard", "work")] = .opened(irregular)
        errors.append(failure(makeReader(fsIrregular).readConfig(named: "work")))

        let failing = FakeReaderFileHandle(content: bytes(contentSentinel))
        failing.failAllReads = true
        let fsFailing = FakeReaderFileSystem()
        fsFailing.outcomes[configPath("/etc/wireguard", "work")] = .opened(failing)
        errors.append(failure(makeReader(fsFailing).readConfig(named: "work")))

        let oversize = FakeReaderFileHandle(content: bytes(contentSentinel) + [UInt8](repeating: 0x61, count: TunnelConfigReader.maxSizeBytes))
        let fsOversize = FakeReaderFileSystem()
        fsOversize.outcomes[configPath("/etc/wireguard", "work")] = .opened(oversize)
        errors.append(failure(makeReader(fsOversize).readConfig(named: "work")))

        let invalidUTF8 = FakeReaderFileHandle(content: Array((contentSentinel + "\n").utf8) + [0xFF])
        let fsInvalidUTF8 = FakeReaderFileSystem()
        fsInvalidUTF8.outcomes[configPath("/etc/wireguard", "work")] = .opened(invalidUTF8)
        errors.append(failure(makeReader(fsInvalidUTF8).readConfig(named: "work")))

        errors.append(failure(makeReader(FakeReaderFileSystem()).readConfig(named: "work")))
        errors.append(failure(makeReader(FakeReaderFileSystem()).readConfig(named: "bad name")))

        for error in errors {
            let description = String(describing: error)
            XCTAssertFalse(description.contains(contentSentinel), "ошибка не несёт содержимое: \(description)")
            XCTAssertFalse(description.contains("/etc/wireguard"), "ошибка не несёт путь: \(description)")
            XCTAssertFalse(description.contains(".conf"), "ошибка не несёт имя файла: \(description)")
        }
    }
}
