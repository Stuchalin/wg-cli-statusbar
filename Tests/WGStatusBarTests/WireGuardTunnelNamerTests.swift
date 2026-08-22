import XCTest
@testable import WGStatusBarCore

final class WireGuardTunnelNamerTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wg-namer-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // MARK: - Хелперы

    private func makeNamer(
        directory: String? = nil,
        fileSystem: WireGuardTunnelNameFileSystem = FileManagerTunnelNameFileSystem()
    ) -> WireGuardTunnelNamer {
        WireGuardTunnelNamer(
            directoryPath: directory ?? tempDir.path,
            fileSystem: fileSystem
        )
    }

    private func writeFile(_ name: String, contents: String) {
        FileManager.default.createFile(
            atPath: tempDir.appendingPathComponent(name).path,
            contents: Data(contents.utf8)
        )
    }

    /// Управление mtime в фикстурах: «сокет пересоздан позже `.name`»
    /// эмулируется сдвигом дат назад, а не ожиданием реального времени.
    private func setModificationDate(_ name: String, to date: Date) {
        try? FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: tempDir.appendingPathComponent(name).path
        )
    }

    /// Обёртка с счётчиками операций: для проверки кэша «повтор не читает фс».
    private final class CountingFileSystem: WireGuardTunnelNameFileSystem {
        private let base: WireGuardTunnelNameFileSystem
        private(set) var listCount = 0
        private(set) var readCount = 0
        private(set) var existsCount = 0
        private(set) var statCount = 0

        var totalOperations: Int { listCount + readCount + existsCount + statCount }

        init(base: WireGuardTunnelNameFileSystem) {
            self.base = base
        }

        func entries(inDirectory path: String) -> [String] {
            listCount += 1
            return base.entries(inDirectory: path)
        }

        func contents(ofFile path: String) -> String? {
            readCount += 1
            return base.contents(ofFile: path)
        }

        func fileExists(atPath path: String) -> Bool {
            existsCount += 1
            return base.fileExists(atPath: path)
        }

        func modificationDate(ofFile path: String) -> Date? {
            statCount += 1
            return base.modificationDate(ofFile: path)
        }
    }

    // MARK: - Резолв имён

    func testResolveWorkVpnWithNeighboringSock() {
        writeFile("work-vpn.name", contents: "utun2")
        writeFile("utun2.sock", contents: "")

        XCTAssertEqual(makeNamer().displayName(for: "utun2"), "work-vpn")
    }

    func testResolveUtun10WithTrailingNewline() {
        // Имя интерфейса из 6 байт + перевод строки в конце.
        writeFile("client.name", contents: "utun10\n")
        writeFile("utun10.sock", contents: "")

        XCTAssertEqual(makeNamer().displayName(for: "utun10"), "client")
    }

    // MARK: - Устаревшие записи

    func testEntryWithoutNeighboringSockFallsBackToRawName() {
        // del_if удаляет .name; если .sock рядом нет — запись устарела.
        writeFile("work-vpn.name", contents: "utun2")

        XCTAssertEqual(makeNamer().displayName(for: "utun2"), "utun2")
    }

    // MARK: - Каталоги-крайние-случаи

    func testMissingDirectoryFallsBackToRawName() {
        let missing = tempDir.appendingPathComponent("no-such-dir").path

        XCTAssertEqual(makeNamer(directory: missing).displayName(for: "utun2"), "utun2")
    }

    func testEmptyDirectoryFallsBackToRawName() {
        XCTAssertEqual(makeNamer().displayName(for: "utun2"), "utun2")
    }

    // MARK: - Несколько .name файлов

    func testMultipleNameFilesMapToTheirInterfaces() {
        writeFile("work-vpn.name", contents: "utun2")
        writeFile("utun2.sock", contents: "")
        writeFile("home.name", contents: "utun7")
        writeFile("utun7.sock", contents: "")

        let namer = makeNamer()
        XCTAssertEqual(namer.displayName(for: "utun2"), "work-vpn")
        XCTAssertEqual(namer.displayName(for: "utun7"), "home")
    }

    // MARK: - Кэш

    func testRepeatedDisplayNameDoesNotRescanDirectory() {
        writeFile("work-vpn.name", contents: "utun2")
        writeFile("utun2.sock", contents: "")

        let counting = CountingFileSystem(base: FileManagerTunnelNameFileSystem())
        let namer = makeNamer(fileSystem: counting)

        XCTAssertEqual(namer.displayName(for: "utun2"), "work-vpn")
        XCTAssertGreaterThan(counting.listCount, 0, "первый вызов должен сканировать каталог")

        // Попадание в кэш валидируется (чтение .name + проверка сокета),
        // но валидная запись не требует листинга каталога.
        let listsAfterFirst = counting.listCount
        XCTAssertEqual(namer.displayName(for: "utun2"), "work-vpn")
        XCTAssertEqual(counting.listCount, listsAfterFirst, "валидный кэш не должен пересканировать каталог")
    }

    // MARK: - Устаревший кэш (переиспользование utun)

    func testStaleCacheOnUtunReuseSelfHeals() {
        // macOS переиспользует номера utun: за закэшированным work-vpn
        // мог подняться уже home-vpn на том же utun2.
        writeFile("work-vpn.name", contents: "utun2")
        writeFile("utun2.sock", contents: "")
        let namer = makeNamer()
        XCTAssertEqual(namer.displayName(for: "utun2"), "work-vpn")

        try? FileManager.default.removeItem(at: tempDir.appendingPathComponent("work-vpn.name"))
        writeFile("home-vpn.name", contents: "utun2")

        XCTAssertEqual(namer.displayName(for: "utun2"), "home-vpn", "устаревший кэш должен перечитываться сам")
    }

    func testStaleCacheWithoutNeighboringSockFallsBackToRawName() {
        // Туннель снесли мимо del_if: .name остался, сокета нет — запись
        // устарела даже без появления нового конфига на этом utun.
        writeFile("work-vpn.name", contents: "utun2")
        writeFile("utun2.sock", contents: "")
        let namer = makeNamer()
        XCTAssertEqual(namer.displayName(for: "utun2"), "work-vpn")

        try? FileManager.default.removeItem(at: tempDir.appendingPathComponent("utun2.sock"))

        XCTAssertEqual(namer.displayName(for: "utun2"), "utun2", "без сокета закэшированное имя теряет силу")
    }

    func testStaleCacheOnUtunReuseWithLingeringNameSelfHeals() {
        // work-vpn снесли мимо del_if — `.name` завис; позже home-vpn подняли
        // на том же utun2, и сокет пересоздан. Содержимое старого `.name`
        // всё ещё указывает на utun2 и сокет существует, но mtime пары
        // разошлись (правило get_real_interface из darwin.bash: |Δ| < 2 c) —
        // закэшированное имя должно потерять силу.
        writeFile("work-vpn.name", contents: "utun2")
        writeFile("utun2.sock", contents: "")
        let staleDate = Date(timeIntervalSinceNow: -3600)
        setModificationDate("work-vpn.name", to: staleDate)
        setModificationDate("utun2.sock", to: staleDate)

        let namer = makeNamer()
        XCTAssertEqual(namer.displayName(for: "utun2"), "work-vpn")

        writeFile("home-vpn.name", contents: "utun2")
        try? FileManager.default.removeItem(at: tempDir.appendingPathComponent("utun2.sock"))
        writeFile("utun2.sock", contents: "")

        XCTAssertEqual(namer.displayName(for: "utun2"), "home-vpn", "зависший .name не должен пережить пересоздание сокета")
    }

    func testScanSkipsLingeringNameWithRecreatedSock() {
        // Тот же зависший `.name`, но без этапа кэша: скан не должен
        // отображать устаревший конфиг на переиспользованный utun —
        // иначе выбор между двумя `.name` зависел бы от порядка листинга.
        writeFile("work-vpn.name", contents: "utun2")
        setModificationDate("work-vpn.name", to: Date(timeIntervalSinceNow: -3600))
        writeFile("home-vpn.name", contents: "utun2")
        writeFile("utun2.sock", contents: "")

        XCTAssertEqual(makeNamer().displayName(for: "utun2"), "home-vpn")
    }

    func testLongLivedConsistentPairStaysValid() {
        // Туннель подняли два часа назад: оба mtime старые, но согласованные
        // (|Δ| < 2 c) — запись актуальна, абсолютный возраст не при чём.
        writeFile("work-vpn.name", contents: "utun2")
        writeFile("utun2.sock", contents: "")
        let oldDate = Date(timeIntervalSinceNow: -7200)
        setModificationDate("work-vpn.name", to: oldDate)
        setModificationDate("utun2.sock", to: oldDate)

        let counting = CountingFileSystem(base: FileManagerTunnelNameFileSystem())
        let namer = makeNamer(fileSystem: counting)

        XCTAssertEqual(namer.displayName(for: "utun2"), "work-vpn")
        let listsAfterFirst = counting.listCount
        XCTAssertEqual(namer.displayName(for: "utun2"), "work-vpn")
        XCTAssertEqual(counting.listCount, listsAfterFirst, "согласованная пара не требует пересканирования каталога")
    }

    func testUnknownUtunAfterScanDoesNotRescan() {
        writeFile("work-vpn.name", contents: "utun2")
        writeFile("utun2.sock", contents: "")

        let counting = CountingFileSystem(base: FileManagerTunnelNameFileSystem())
        let namer = makeNamer(fileSystem: counting)

        _ = namer.displayName(for: "utun2")
        let afterFirst = counting.totalOperations

        XCTAssertEqual(namer.displayName(for: "utun99"), "utun99")
        XCTAssertEqual(counting.totalOperations, afterFirst, "промах по кэшу не должен пересканировать")
    }

    func testRescanPicksUpNewTunnel() {
        // Контракт для модели (Task 5): незнакомый utun сам не ресканится —
        // модель зовёт rescan() и резолвит заново.
        let namer = makeNamer()
        XCTAssertEqual(namer.displayName(for: "utun5"), "utun5")

        writeFile("work-vpn.name", contents: "utun5")
        writeFile("utun5.sock", contents: "")

        XCTAssertEqual(namer.displayName(for: "utun5"), "utun5", "без rescan новое имя не подхватывается")

        namer.rescan()
        XCTAssertEqual(namer.displayName(for: "utun5"), "work-vpn")
    }

    // MARK: - Rescan замещает кэш целиком

    func testRescanForgetsRemovedTunnel() {
        // Туннель снесли (del_if удалил файлы) — после rescan кэш не должен
        // подсвечивать устаревшее имя.
        writeFile("work-vpn.name", contents: "utun2")
        writeFile("utun2.sock", contents: "")
        let namer = makeNamer()
        XCTAssertEqual(namer.displayName(for: "utun2"), "work-vpn")

        try? FileManager.default.removeItem(at: tempDir.appendingPathComponent("work-vpn.name"))
        try? FileManager.default.removeItem(at: tempDir.appendingPathComponent("utun2.sock"))
        namer.rescan()

        XCTAssertEqual(namer.displayName(for: "utun2"), "utun2", "после удаления .name/.sock rescan должен забыть имя")
    }

    // MARK: - Мусорные записи в каталоге

    func testScanIgnoresMalformedEntries() {
        // Пустой .name, .name из одних пробелов, запись с именем ровно ".name"
        // (пустое имя конфига) и посторонний файл — в кэш не попадают.
        writeFile("empty.name", contents: "")
        writeFile("blank.name", contents: " \n ")
        writeFile(".name", contents: "utun8")
        writeFile("utun8.sock", contents: "")
        writeFile("work-vpn.conf", contents: "utun9")
        writeFile("utun9.sock", contents: "")

        let namer = makeNamer()
        XCTAssertEqual(namer.displayName(for: "utun8"), "utun8", "запись с пустым именем конфига игнорируется")
        XCTAssertEqual(namer.displayName(for: "utun9"), "utun9", "файл не .name не читается как запись")
    }
}
