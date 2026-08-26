import XCTest
@testable import WGStatusBarCore

/// Скан конфигов wg-quick и валидация имени (демон): `names()` фильтруется
/// тем же regex, что и `validate`, — поэтому оба проверяются вместе.
final class TunnelConfigStoreTests: XCTestCase {
    /// Поддельная FS: множество «существующих» директорий + их листинги.
    private final class FakeConfigFileSystem: TunnelConfigFileSystem {
        var directories: Set<String> = []
        var entriesByDirectory: [String: [String]] = [:]
        private(set) var listedDirectories: [String] = []

        func contentsOfDirectory(atPath path: String) -> [String]? {
            listedDirectories.append(path)
            return entriesByDirectory[path]
        }

        func isDirectory(atPath path: String) -> Bool {
            directories.contains(path)
        }
    }

    private let searchPaths = [
        "/etc/wireguard",
        "/usr/local/etc/wireguard",
        "/opt/homebrew/etc/wireguard",
        "/opt/local/etc/wireguard",
    ]

    // MARK: - скан

    func testNamesCollectsConfBasenamesFromAllExistingDirectories() {
        let fs = FakeConfigFileSystem()
        fs.directories = ["/etc/wireguard", "/opt/homebrew/etc/wireguard"]
        fs.entriesByDirectory = [
            "/etc/wireguard": ["work.conf"],
            "/opt/homebrew/etc/wireguard": ["kvmka-ai.conf", "kvmka-full.conf"],
        ]
        let store = TunnelConfigStore(searchPaths: searchPaths, fileSystem: fs)

        XCTAssertEqual(store.names(), ["kvmka-ai", "kvmka-full", "work"])
    }

    func testNamesSortsAndDeduplicatesAcrossPaths() {
        // Одинаковое имя в двух директориях — один туннель: wg-quick
        // резолвит первый попавшийся конфиг, дубль в меню — ложный выбор.
        let fs = FakeConfigFileSystem()
        fs.directories = ["/etc/wireguard", "/opt/homebrew/etc/wireguard"]
        fs.entriesByDirectory = [
            "/etc/wireguard": ["zzz.conf", "dup.conf"],
            "/opt/homebrew/etc/wireguard": ["aaa.conf", "dup.conf"],
        ]
        let store = TunnelConfigStore(searchPaths: searchPaths, fileSystem: fs)

        XCTAssertEqual(store.names(), ["aaa", "dup", "zzz"])
    }

    func testNamesIgnoresNonConfEntriesAndMissingDirectories() {
        let fs = FakeConfigFileSystem()
        // Существует только /etc/wireguard; остальные три пути — мимо.
        fs.directories = ["/etc/wireguard"]
        fs.entriesByDirectory = [
            "/etc/wireguard": [
                "work.conf",
                "notes.txt",
                "work.conf.bak",
                "conf",
                "UPPER.CONF", // суффикс `.conf` чувствителен к регистру
            ],
        ]
        let store = TunnelConfigStore(searchPaths: searchPaths, fileSystem: fs)

        XCTAssertEqual(store.names(), ["work"])
        XCTAssertEqual(
            fs.listedDirectories,
            ["/etc/wireguard"],
            "отсутствующие директории не листятся и не падают"
        )
    }

    func testNamesFiltersByWgQuickNameRegex() {
        // Неоперабельный конфиг (имя — не интерфейс по правилам wg-quick)
        // вообще не попадает в список: клик по нему всё равно умрёт в скрипте.
        let fs = FakeConfigFileSystem()
        fs.directories = ["/etc/wireguard"]
        fs.entriesByDirectory = [
            "/etc/wireguard": [
                "good.conf",
                ".conf", // пустой basename
                "bad name.conf", // пробел
                "слишком-длинное-имя-конфига-больше-15.conf", // > 15 символов
                "слишком.conf", // юникод
                "slash-name.conf", // ок — дефис в классе regex
            ],
        ]
        let store = TunnelConfigStore(searchPaths: searchPaths, fileSystem: fs)

        XCTAssertEqual(store.names(), ["good", "slash-name"])
    }

    func testNamesReturnsEmptyWhenNoDirectoriesExist() {
        let fs = FakeConfigFileSystem()
        let store = TunnelConfigStore(searchPaths: searchPaths, fileSystem: fs)

        XCTAssertEqual(store.names(), [])
    }

    // MARK: - валидация

    func testValidateAcceptsExistingNameWithSpecialRegexCharacters() {
        let fs = FakeConfigFileSystem()
        fs.directories = ["/etc/wireguard"]
        fs.entriesByDirectory = [
            "/etc/wireguard": ["plain.conf", "with=plus+.conf", "dots.and-dash_1.conf"],
        ]
        let store = TunnelConfigStore(searchPaths: searchPaths, fileSystem: fs)

        XCTAssertTrue(store.validate("plain"))
        XCTAssertTrue(store.validate("with=plus+"), "= и + входят в класс regex wg-quick")
        XCTAssertTrue(store.validate("dots.and-dash_1"))
    }

    func testValidateRejectsBadShapeEvenWhenConfigExists() {
        let fs = FakeConfigFileSystem()
        fs.directories = ["/etc/wireguard"]
        fs.entriesByDirectory = [
            "/etc/wireguard": [
                "bad name.conf", // пробел — файл реально лежит, но имя неинтерфейсное
                "штатный.conf", // юникод
                "abcdefghijklmnop.conf", // 16 символов — лимит имён интерфейсов
            ],
        ]
        let store = TunnelConfigStore(searchPaths: searchPaths, fileSystem: fs)

        XCTAssertFalse(store.validate("bad name"))
        XCTAssertFalse(store.validate("штатный"))
        XCTAssertFalse(store.validate("abcdefghijklmnop"))
    }

    func testValidateRejectsNamesThatCannotComeFromAConfigBasename() {
        let fs = FakeConfigFileSystem()
        fs.directories = ["/etc/wireguard"]
        fs.entriesByDirectory = ["/etc/wireguard": ["work.conf"]]
        let store = TunnelConfigStore(searchPaths: searchPaths, fileSystem: fs)

        // Слэш: basename листинга содержать его не может — это уже путь,
        // wg-quick выполнил бы произвольный путь от root.
        XCTAssertFalse(store.validate("etc/wireguard/work"))
        XCTAssertFalse(store.validate("../etc/passwd"))
        XCTAssertFalse(store.validate(""), "пустое имя — не интерфейс")
        // `..` проходит shape-проверку (точки в классе regex), но конфига
        // `...conf` нет — отсекается presence-половиной.
        XCTAssertFalse(store.validate(".."))
    }

    func testValidateRejectsWellShapedNameWithoutConfig() {
        let fs = FakeConfigFileSystem()
        fs.directories = ["/etc/wireguard"]
        fs.entriesByDirectory = ["/etc/wireguard": ["work.conf"]]
        let store = TunnelConfigStore(searchPaths: searchPaths, fileSystem: fs)

        XCTAssertFalse(store.validate("nosuch"), "имя корректно, но конфига нет — wg-quick упал бы")
    }

    func testValidateReflectsDirectoryRemoval() {
        // Конфиг удалили между list и up: presence-половина валидации
        // сканирует заново на каждом вызове, без кэша.
        let fs = FakeConfigFileSystem()
        fs.directories = ["/etc/wireguard"]
        fs.entriesByDirectory = ["/etc/wireguard": ["work.conf"]]
        let store = TunnelConfigStore(searchPaths: searchPaths, fileSystem: fs)

        XCTAssertTrue(store.validate("work"))

        fs.entriesByDirectory["/etc/wireguard"] = []
        XCTAssertFalse(store.validate("work"))
    }
}
