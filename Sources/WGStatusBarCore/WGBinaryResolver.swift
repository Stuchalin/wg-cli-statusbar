import Foundation

/// Пути поиска бинаря `wg` для демона: launchd не даёт пользовательский PATH
/// (Homebrew живёт в `/opt/homebrew` или `/usr/local`), поэтому демон ищет wg
/// сам. Порядок — как в шелле: arm64-Homebrew, x86-Homebrew, система.
public let wgBinarySearchPaths = [
    "/opt/homebrew/bin/wg",
    "/usr/local/bin/wg",
    "/usr/bin/wg",
]

/// Резолвит путь до бинаря `wg` для привилегированного демона: обходит пути
/// поиска и возвращает первый существующий. Вызывается демоном (не приложением);
/// последовательный accept-loop демона — единственный клиент, блокировки не нужны.
public struct WGBinaryResolver {
    private let searchPaths: [String]
    private let fileExists: (String) -> Bool
    private var cachedPath: String?

    /// - Parameters:
    ///   - searchPaths: кандидаты в порядке приоритета.
    ///   - fileExists: инжектируемая проверка существования файла
    ///     (`FileManager.fileExists` в продакшне, заглушка в тестах).
    public init(
        searchPaths: [String] = wgBinarySearchPaths,
        fileExists: @escaping (String) -> Bool
    ) {
        self.searchPaths = searchPaths
        self.fileExists = fileExists
    }

    /// Первый существующий путь поиска, `nil` — wg не найден. Кэшируется
    /// **только успешный** резолв, но перед возвратом из кэша путь
    /// перепроверяется: и `brew install` (промах не кэшируется), и
    /// `brew uninstall` (кэш протух) подхватываются без перезапуска демона
    /// (пара stat-ов раз в несколько секунд — бесплатно).
    public mutating func resolve() -> String? {
        if let cachedPath, fileExists(cachedPath) {
            return cachedPath
        }
        cachedPath = nil
        let hit = searchPaths.first { fileExists($0) }
        cachedPath = hit
        return hit
    }
}
