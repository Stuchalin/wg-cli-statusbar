import XCTest
@testable import WGStatusBarCore

final class WireGuardRuntimeReaderTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wg-runtime-reader-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // MARK: - Хелперы

    private func makeReader(
        directory: String? = nil,
        fileSystem: WireGuardTunnelNameFileSystem = FileManagerTunnelNameFileSystem()
    ) -> WireGuardRuntimeReader {
        WireGuardRuntimeReader(
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

    /// Управление mtime в фикстурах: расхождение пары эмулируется сдвигом
    /// дат, а не ожиданием реального времени. Для проверки границы
    /// (ровно 2 с) даты фиксированные, без привязки к стеновым часам.
    private func setModificationDate(_ name: String, to date: Date) {
        try? FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: tempDir.appendingPathComponent(name).path
        )
    }

    /// Обёртка, у которой один файл «нечитаемый» (contents → nil): право
    /// 0400 root на `.name` в daemon-режиме здесь не воспроизвести.
    private final class UnreadablePathFileSystem: WireGuardTunnelNameFileSystem {
        private let base = FileManagerTunnelNameFileSystem()
        private let unreadablePath: String

        init(unreadablePath: String) {
            self.unreadablePath = unreadablePath
        }

        func entries(inDirectory path: String) -> [String] {
            base.entries(inDirectory: path)
        }

        func contents(ofFile path: String) -> String? {
            path == unreadablePath ? nil : base.contents(ofFile: path)
        }

        func fileExists(atPath path: String) -> Bool {
            base.fileExists(atPath: path)
        }

        func modificationDate(ofFile path: String) -> Date? {
            base.modificationDate(ofFile: path)
        }
    }

    // MARK: - Валидные пары

    func testValidPairIsReturned() {
        writeFile("work-vpn.name", contents: "utun2\n")
        writeFile("utun2.sock", contents: "")

        XCTAssertEqual(
            makeReader().readPairs(),
            [WireGuardRuntimePair(configName: "work-vpn", interfaceName: "utun2")]
        )
    }

    func testMultipleTunnelsAreAllReturned() {
        writeFile("work-vpn.name", contents: "utun2")
        writeFile("utun2.sock", contents: "")
        writeFile("home.name", contents: "utun7")
        writeFile("utun7.sock", contents: "")

        XCTAssertEqual(
            Set(makeReader().readPairs()),
            [
                WireGuardRuntimePair(configName: "work-vpn", interfaceName: "utun2"),
                WireGuardRuntimePair(configName: "home", interfaceName: "utun7"),
            ]
        )
    }

    // MARK: - Устаревшие и битые записи

    func testNameWithoutNeighboringSockIsDropped() {
        // del_if удаляет .name; если .sock рядом нет — записи нет.
        writeFile("work-vpn.name", contents: "utun2")

        XCTAssertEqual(makeReader().readPairs(), [])
    }

    func testSockWithoutNameFileYieldsNoPairs() {
        // Скан идёт по .name-файлам; одиночный сокет — не запись.
        writeFile("utun2.sock", contents: "")

        XCTAssertEqual(makeReader().readPairs(), [])
    }

    func testLingeringNameWithRecreatedSockIsDropped() {
        // work-vpn снесли мимо del_if — `.name` завис; позже home-vpn подняли
        // на том же utun2, и сокет пересоздан. Содержимое старого `.name`
        // всё ещё указывает на utun2, но mtime пары разошлись
        // (правило get_real_interface из darwin.bash: |Δ| < 2 c).
        writeFile("work-vpn.name", contents: "utun2")
        setModificationDate("work-vpn.name", to: Date(timeIntervalSinceNow: -3600))
        writeFile("utun2.sock", contents: "")

        XCTAssertEqual(makeReader().readPairs(), [])
    }

    func testOldButConsistentPairStaysValid() {
        // Туннель подняли два часа назад: оба mtime старые, но согласованные
        // (|Δ| < 2 c) — запись актуальна, абсолютный возраст не при чём.
        writeFile("work-vpn.name", contents: "utun2")
        writeFile("utun2.sock", contents: "")
        let oldDate = Date(timeIntervalSinceNow: -7200)
        setModificationDate("work-vpn.name", to: oldDate)
        setModificationDate("utun2.sock", to: oldDate)

        XCTAssertEqual(
            makeReader().readPairs(),
            [WireGuardRuntimePair(configName: "work-vpn", interfaceName: "utun2")]
        )
    }

    func testMtimeBoundaryExactlyTwoSecondsRejected() {
        let base = Date(timeIntervalSince1970: 1_000_000_000)
        writeFile("work-vpn.name", contents: "utun2")
        writeFile("utun2.sock", contents: "")
        setModificationDate("work-vpn.name", to: base)
        setModificationDate("utun2.sock", to: base.addingTimeInterval(2))

        XCTAssertEqual(makeReader().readPairs(), [], "Δ = 2 c — уже не пара")
    }

    func testMtimeBoundaryUnderTwoSecondsAccepted() {
        let base = Date(timeIntervalSince1970: 1_000_000_000)
        writeFile("work-vpn.name", contents: "utun2")
        writeFile("utun2.sock", contents: "")
        setModificationDate("work-vpn.name", to: base)
        setModificationDate("utun2.sock", to: base.addingTimeInterval(1.99))

        XCTAssertEqual(
            makeReader().readPairs(),
            [WireGuardRuntimePair(configName: "work-vpn", interfaceName: "utun2")],
            "Δ = 1.99 c — ещё пара"
        )
    }

    func testEmptyNameContentsIsDropped() {
        writeFile("empty.name", contents: "")
        writeFile("utun2.sock", contents: "")

        XCTAssertEqual(makeReader().readPairs(), [])
    }

    func testWhitespaceOnlyNameContentsIsDropped() {
        writeFile("blank.name", contents: " \n ")
        writeFile("utun2.sock", contents: "")

        XCTAssertEqual(makeReader().readPairs(), [])
    }

    func testUnreadableNameFileIsDropped() {
        // Право 0400 root на `.name` (исходный баг): contents → nil,
        // пара отбрасывается без падения скана.
        writeFile("work-vpn.name", contents: "utun2")
        writeFile("utun2.sock", contents: "")

        let fs = UnreadablePathFileSystem(
            unreadablePath: tempDir.appendingPathComponent("work-vpn.name").path
        )

        XCTAssertEqual(makeReader(fileSystem: fs).readPairs(), [])
    }

    func testMissingDirectoryReturnsEmpty() {
        let missing = tempDir.appendingPathComponent("no-such-dir").path

        XCTAssertEqual(makeReader(directory: missing).readPairs(), [])
    }

    // MARK: - Без кэша (контракт для демона)

    func testScanRereadsDirectoryOnEveryCall() {
        // Демон спрашивает состояние на каждый запрос: удалённая между
        // вызовами пара должна исчезнуть из ответа — ридер не кэширует.
        writeFile("work-vpn.name", contents: "utun2")
        writeFile("utun2.sock", contents: "")
        let reader = makeReader()
        XCTAssertEqual(reader.readPairs().count, 1)

        try? FileManager.default.removeItem(at: tempDir.appendingPathComponent("work-vpn.name"))

        XCTAssertEqual(reader.readPairs(), [])
    }

    // MARK: - isPairCurrent (валидация кэша namer'а)

    func testPairCurrentTrueForValidPair() {
        writeFile("work-vpn.name", contents: "utun2")
        writeFile("utun2.sock", contents: "")

        XCTAssertTrue(makeReader().isPairCurrent(configName: "work-vpn", interfaceName: "utun2"))
    }

    func testPairCurrentFalseWhenNameFileMissing() {
        writeFile("utun2.sock", contents: "")

        XCTAssertFalse(makeReader().isPairCurrent(configName: "work-vpn", interfaceName: "utun2"))
    }

    func testPairCurrentFalseWhenContentsPointToAnotherInterface() {
        // За конфигом work-vpn закрепился другой utun.
        writeFile("work-vpn.name", contents: "utun9")
        writeFile("utun2.sock", contents: "")
        writeFile("utun9.sock", contents: "")

        XCTAssertFalse(makeReader().isPairCurrent(configName: "work-vpn", interfaceName: "utun2"))
    }

    func testPairCurrentFalseWithoutSock() {
        writeFile("work-vpn.name", contents: "utun2")

        XCTAssertFalse(makeReader().isPairCurrent(configName: "work-vpn", interfaceName: "utun2"))
    }

    func testPairCurrentFalseOnDivergedMtime() {
        writeFile("work-vpn.name", contents: "utun2")
        setModificationDate("work-vpn.name", to: Date(timeIntervalSinceNow: -3600))
        writeFile("utun2.sock", contents: "")

        XCTAssertFalse(makeReader().isPairCurrent(configName: "work-vpn", interfaceName: "utun2"))
    }
}
