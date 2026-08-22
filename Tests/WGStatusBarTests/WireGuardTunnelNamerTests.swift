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

    /// Обёртка с счётчиками операций: для проверки кэша «повтор не читает фс».
    private final class CountingFileSystem: WireGuardTunnelNameFileSystem {
        private let base: WireGuardTunnelNameFileSystem
        private(set) var listCount = 0
        private(set) var readCount = 0
        private(set) var existsCount = 0

        var totalOperations: Int { listCount + readCount + existsCount }

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

    func testRepeatedDisplayNameDoesNotTouchFileSystem() {
        writeFile("work-vpn.name", contents: "utun2")
        writeFile("utun2.sock", contents: "")

        let counting = CountingFileSystem(base: FileManagerTunnelNameFileSystem())
        let namer = makeNamer(fileSystem: counting)

        XCTAssertEqual(namer.displayName(for: "utun2"), "work-vpn")
        XCTAssertGreaterThan(counting.totalOperations, 0, "первый вызов должен сканировать фс")

        let afterFirst = counting.totalOperations
        XCTAssertEqual(namer.displayName(for: "utun2"), "work-vpn")
        XCTAssertEqual(counting.totalOperations, afterFirst, "повторный вызов не должен читать фс")
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
}
