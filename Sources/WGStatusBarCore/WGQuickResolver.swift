import Foundation

/// Пути поиска бинаря `wg-quick` для демона — тот же порядок, что у `wg`
/// (`wgBinarySearchPaths`): arm64-Homebrew, x86-Homebrew, MacPorts, система
/// (launchd не даёт пользовательский PATH, демон ищет бинарь сам).
public let wgQuickBinarySearchPaths = [
    "/opt/homebrew/bin/wg-quick",
    "/usr/local/bin/wg-quick",
    "/opt/local/bin/wg-quick",
    "/usr/bin/wg-quick",
]

/// Резолвит путь до бинаря `wg-quick` — тот же контракт, что у
/// `WGBinaryResolver`: кэшируется **только успешный** резолв, но перед
/// возвратом из кэша путь перепроверяется — и поздний `brew install`
/// (промах не кэшируется), и `brew uninstall` (кэш протух) подхватываются
/// без перезапуска демона. Вызывается демоном; последовательный accept-loop —
/// единственный клиент, блокировки не нужны.
public struct WGQuickResolver {
    private let searchPaths: [String]
    private let fileExists: (String) -> Bool
    private var cachedPath: String?

    /// - Parameters:
    ///   - searchPaths: кандидаты в порядке приоритета.
    ///   - fileExists: инжектируемая проверка существования файла
    ///     (`FileManager.fileExists` в продакшне, заглушка в тестах).
    public init(
        searchPaths: [String] = wgQuickBinarySearchPaths,
        fileExists: @escaping (String) -> Bool
    ) {
        self.searchPaths = searchPaths
        self.fileExists = fileExists
    }

    /// Первый существующий путь поиска, `nil` — wg-quick не найден.
    public mutating func resolve() -> String? {
        if let cachedPath, fileExists(cachedPath) {
            return cachedPath
        }
        cachedPath = nil
        let hit = searchPaths.first { fileExists($0) }
        cachedPath = hit
        return hit
    }

    /// Директории поиска в порядке приоритета — для сборки PATH ребёнка
    /// (`WGQuickExecutor.childPath`): директория найденного wg-quick обязана
    /// идти впереди системных путей.
    public var searchDirectories: [String] {
        searchPaths.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
    }
}
