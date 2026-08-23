import XCTest
@testable import WGStatusBarCore

final class WGBinaryResolverTests: XCTestCase {
    /// Поддельная FS: множество «существующих» путей + счётчик обращений.
    private final class FakeFileSystem {
        var existingPaths: Set<String> = []
        private(set) var probeCount = 0

        func fileExists(_ path: String) -> Bool {
            probeCount += 1
            return existingPaths.contains(path)
        }
    }

    private let searchPaths = [
        "/opt/homebrew/bin/wg",
        "/usr/local/bin/wg",
        "/usr/bin/wg",
    ]

    // MARK: - первый существующий

    func testResolveReturnsFirstExistingPath() {
        // Таблично: приоритет порядка поиска, где бы wg ни оказался.
        let cases: [(existing: Set<String>, expected: String)] = [
            (["/opt/homebrew/bin/wg"], "/opt/homebrew/bin/wg"),
            (["/usr/local/bin/wg"], "/usr/local/bin/wg"),
            (["/usr/bin/wg"], "/usr/bin/wg"),
            // Несколько существующих — первый по порядку поиска.
            (["/usr/local/bin/wg", "/usr/bin/wg"], "/usr/local/bin/wg"),
            (["/opt/homebrew/bin/wg", "/usr/local/bin/wg", "/usr/bin/wg"], "/opt/homebrew/bin/wg"),
        ]
        for testCase in cases {
            let fs = FakeFileSystem()
            fs.existingPaths = testCase.existing
            var resolver = WGBinaryResolver(searchPaths: searchPaths, fileExists: fs.fileExists)
            XCTAssertEqual(
                resolver.resolve(),
                testCase.expected,
                "для \(testCase.existing.sorted()) ожидался \(testCase.expected)"
            )
        }
    }

    func testResolveProbesInOrderAndStopsAtFirstHit() {
        let fs = FakeFileSystem()
        fs.existingPaths = ["/usr/local/bin/wg"]
        var resolver = WGBinaryResolver(searchPaths: searchPaths, fileExists: fs.fileExists)

        XCTAssertEqual(resolver.resolve(), "/usr/local/bin/wg")
        XCTAssertEqual(fs.probeCount, 2, "пути проверяются по порядку до первого hit")
    }

    func testResolveReturnsNilWhenNothingExists() {
        let fs = FakeFileSystem()
        var resolver = WGBinaryResolver(searchPaths: searchPaths, fileExists: fs.fileExists)

        XCTAssertNil(resolver.resolve())
        XCTAssertEqual(fs.probeCount, 3, "промах проверяет все пути поиска")
    }

    // MARK: - кэш только hit

    func testResolveCachesSuccessfulHit() {
        let fs = FakeFileSystem()
        fs.existingPaths = ["/opt/homebrew/bin/wg"]
        var resolver = WGBinaryResolver(searchPaths: searchPaths, fileExists: fs.fileExists)

        XCTAssertEqual(resolver.resolve(), "/opt/homebrew/bin/wg")
        XCTAssertEqual(fs.probeCount, 1)

        // Повторный вызов — кэш с перепроверкой существования: один stat
        // закэшированного пути, не полный обход всех кандидатов.
        XCTAssertEqual(resolver.resolve(), "/opt/homebrew/bin/wg")
        XCTAssertEqual(fs.probeCount, 2, "кэш перепроверяет только закэшированный путь")
    }

    func testResolveCachedHitIsInvalidatedWhenWgDisappears() {
        // brew uninstall после успешного резолва: закэшированный путь мёртв —
        // резолвер обязан увидеть удаление (daemon ответит wg-missing, а не
        // вечный wg-failed от запуска несуществующего файла) и снова найти wg
        // после переустановки — без перезапуска демона.
        let fs = FakeFileSystem()
        fs.existingPaths = ["/opt/homebrew/bin/wg"]
        var resolver = WGBinaryResolver(searchPaths: searchPaths, fileExists: fs.fileExists)

        XCTAssertEqual(resolver.resolve(), "/opt/homebrew/bin/wg")

        fs.existingPaths = []
        XCTAssertNil(resolver.resolve(), "удалённый wg — снова промах, а не мёртвый кэш")

        fs.existingPaths = ["/opt/homebrew/bin/wg"]
        XCTAssertEqual(resolver.resolve(), "/opt/homebrew/bin/wg")
    }

    func testResolveMissIsNotCached() {
        let fs = FakeFileSystem()
        var resolver = WGBinaryResolver(searchPaths: searchPaths, fileExists: fs.fileExists)

        // Промах: nil без кэша — каждый вызов перепроверяет FS
        // (иначе wg-missing — тупик до перезагрузки демона).
        XCTAssertNil(resolver.resolve())
        XCTAssertEqual(fs.probeCount, 3)
        XCTAssertNil(resolver.resolve())
        XCTAssertEqual(fs.probeCount, 6, "промах не кэшируется — пути перепроверяются")

        // wg установили (brew install) — следующий вызов находит
        // без перезапуска демона.
        fs.existingPaths = ["/opt/homebrew/bin/wg"]
        XCTAssertEqual(resolver.resolve(), "/opt/homebrew/bin/wg")
        XCTAssertEqual(fs.probeCount, 7)

        // Найденный путь теперь кэшируется — как в тесте hit-кэша:
        // один stat перепроверки, не обход всех кандидатов.
        XCTAssertEqual(resolver.resolve(), "/opt/homebrew/bin/wg")
        XCTAssertEqual(fs.probeCount, 8)
    }
}
