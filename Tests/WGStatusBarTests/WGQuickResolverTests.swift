import XCTest
@testable import WGStatusBarCore

/// Резолвер wg-quick — структурный клон `WGBinaryResolver` (тот же контракт
/// кэш-с-ревалидацией), поэтому и тесты зеркалят `WGBinaryResolverTests`.
final class WGQuickResolverTests: XCTestCase {
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
        "/opt/homebrew/bin/wg-quick",
        "/usr/local/bin/wg-quick",
        "/opt/local/bin/wg-quick",
        "/usr/bin/wg-quick",
    ]

    // MARK: - первый существующий

    func testResolveReturnsFirstExistingPath() {
        let cases: [(existing: Set<String>, expected: String)] = [
            (["/opt/homebrew/bin/wg-quick"], "/opt/homebrew/bin/wg-quick"),
            (["/usr/local/bin/wg-quick"], "/usr/local/bin/wg-quick"),
            (["/opt/local/bin/wg-quick"], "/opt/local/bin/wg-quick"),
            (["/usr/bin/wg-quick"], "/usr/bin/wg-quick"),
            (["/usr/local/bin/wg-quick", "/usr/bin/wg-quick"], "/usr/local/bin/wg-quick"),
            (["/opt/homebrew/bin/wg-quick", "/usr/local/bin/wg-quick", "/usr/bin/wg-quick"],
             "/opt/homebrew/bin/wg-quick"),
        ]
        for testCase in cases {
            let fs = FakeFileSystem()
            fs.existingPaths = testCase.existing
            var resolver = WGQuickResolver(searchPaths: searchPaths, fileExists: fs.fileExists)
            XCTAssertEqual(
                resolver.resolve(),
                testCase.expected,
                "для \(testCase.existing.sorted()) ожидался \(testCase.expected)"
            )
        }
    }

    func testResolveReturnsNilWhenNothingExists() {
        let fs = FakeFileSystem()
        var resolver = WGQuickResolver(searchPaths: searchPaths, fileExists: fs.fileExists)

        XCTAssertNil(resolver.resolve())
        XCTAssertEqual(fs.probeCount, 4, "промах проверяет все пути поиска")
    }

    // MARK: - кэш только hit

    func testResolveCachesSuccessfulHit() {
        let fs = FakeFileSystem()
        fs.existingPaths = ["/opt/homebrew/bin/wg-quick"]
        var resolver = WGQuickResolver(searchPaths: searchPaths, fileExists: fs.fileExists)

        XCTAssertEqual(resolver.resolve(), "/opt/homebrew/bin/wg-quick")
        XCTAssertEqual(fs.probeCount, 1)

        // Повторный вызов — кэш с перепроверкой существования: один stat
        // закэшированного пути, не полный обход всех кандидатов.
        XCTAssertEqual(resolver.resolve(), "/opt/homebrew/bin/wg-quick")
        XCTAssertEqual(fs.probeCount, 2, "кэш перепроверяет только закэшированный путь")
    }

    func testResolveCachedHitIsInvalidatedWhenQuickDisappears() {
        // brew uninstall после успешного резолва: закэшированный путь мёртв —
        // резолвер обязан увидеть удаление и снова найти wg-quick после
        // переустановки — без перезапуска демона.
        let fs = FakeFileSystem()
        fs.existingPaths = ["/opt/homebrew/bin/wg-quick"]
        var resolver = WGQuickResolver(searchPaths: searchPaths, fileExists: fs.fileExists)

        XCTAssertEqual(resolver.resolve(), "/opt/homebrew/bin/wg-quick")

        fs.existingPaths = []
        XCTAssertNil(resolver.resolve(), "удалённый wg-quick — снова промах, а не мёртвый кэш")

        fs.existingPaths = ["/opt/homebrew/bin/wg-quick"]
        XCTAssertEqual(resolver.resolve(), "/opt/homebrew/bin/wg-quick")
    }

    func testResolveMissIsNotCached() {
        let fs = FakeFileSystem()
        var resolver = WGQuickResolver(searchPaths: searchPaths, fileExists: fs.fileExists)

        // Промах: nil без кэша — каждый вызов перепроверяет FS.
        XCTAssertNil(resolver.resolve())
        XCTAssertNil(resolver.resolve(), "промах не кэшируется — пути перепроверяются")

        fs.existingPaths = ["/usr/bin/wg-quick"]
        XCTAssertEqual(resolver.resolve(), "/usr/bin/wg-quick")
    }

    // MARK: - директории для PATH ребёнка

    func testSearchDirectoriesMapPathsToDirectoriesInOrder() {
        // Директории для сборки PATH ребёнка: dirname каждого кандидата,
        // порядок приоритета сохраняется.
        var resolver = WGQuickResolver(searchPaths: searchPaths, fileExists: { _ in false })

        XCTAssertEqual(
            resolver.searchDirectories,
            ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]
        )
    }
}
