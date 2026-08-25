import Foundation

/// Пути поиска конфигов wg-quick для демона — `CONFIG_SEARCH_PATHS` из самого
/// скрипта wg-quick (строка 44, порядок сохранён: система, x86-Homebrew,
/// arm64-Homebrew), плюс MacPorts-префикс `/opt/local` для паритета с
/// `wgQuickBinarySearchPaths`. Отсутствующая директория просто пропускается.
public let tunnelConfigSearchPaths = [
    "/etc/wireguard",
    "/usr/local/etc/wireguard",
    "/opt/homebrew/etc/wireguard",
    "/opt/local/etc/wireguard",
]

/// Файловый слой `TunnelConfigStore`; инжектится для тестов
/// (поддельные директории, счётчики).
public protocol TunnelConfigFileSystem {
    /// Basenames файлов в каталоге; `nil` — каталог не читается.
    func contentsOfDirectory(atPath path: String) -> [String]?
    /// Каталог существует и является директорией.
    func isDirectory(atPath path: String) -> Bool
}

/// Продакшн-реализация поверх `FileManager`.
public struct FileManagerTunnelConfigFileSystem: TunnelConfigFileSystem {
    public init() {}

    public func contentsOfDirectory(atPath path: String) -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: path)
    }

    public func isDirectory(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

/// Каталог конфигов wg-quick на стороне демона: перечисление имён туннелей
/// и валидация имени перед `wg-quick up/down`. Вызывается демоном;
/// последовательный accept-loop — единственный клиент, блокировки не нужны
/// (как у `WGBinaryResolver`).
public struct TunnelConfigStore {
    /// Имя туннеля, каким его принимает сам wg-quick: скрипт передаёт
    /// аргумент дальше только при совпадении с этим regex (его строка 49),
    /// иначе трактует его как путь к конфигу. 15 символов — лимит имён
    /// интерфейсов. Проверяется один-в-один, без «улучшений»: всё, что
    /// отсюда прошло, примет и wg-quick; всё, что отсюда не прошло, wg-quick
    /// выполнил бы не как имя.
    static let wgQuickNamePattern = "^[a-zA-Z0-9_=+.-]{1,15}$"

    private let searchPaths: [String]
    private let fileSystem: TunnelConfigFileSystem

    /// - Parameters:
    ///   - searchPaths: директории конфигов в порядке приоритета.
    ///   - fileSystem: инжектируемый FS (`FileManager` в продакшне,
    ///     заглушка в тестах).
    public init(
        searchPaths: [String] = tunnelConfigSearchPaths,
        fileSystem: TunnelConfigFileSystem = FileManagerTunnelConfigFileSystem()
    ) {
        self.searchPaths = searchPaths
        self.fileSystem = fileSystem
    }

    /// Имена операбельных туннелей: basenames `*.conf` из существующих
    /// директорий поиска, отфильтрованные тем же regex, что и `validate`
    /// (неоперабельный конфиг — имя-не-интерфейс, пустой basename —
    /// в список не попадает вовсе), отсортированные, без дублей между
    /// путями. Каждый вызов сканирует заново: `list` приходит при открытии
    /// меню, пара листингов — бесплатно, кэш не завязан на время жизни.
    public func names() -> [String] {
        var seen = Set<String>()
        for path in searchPaths {
            guard
                fileSystem.isDirectory(atPath: path),
                let entries = fileSystem.contentsOfDirectory(atPath: path)
            else { continue }
            for entry in entries where entry.hasSuffix(".conf") {
                let name = String(entry.dropLast(".conf".count))
                guard isNameShapeValid(name), seen.insert(name).inserted else { continue }
            }
        }
        return seen.sorted()
    }

    /// Имя можно передавать в `wg-quick up <name>`: соответствует regex
    /// wg-quick (иначе скрипт трактует аргумент как путь к конфигу) И
    /// `.conf` с таким именем лежит в директориях поиска (`names()`).
    /// Оба условия обязательны: shape-проверка одна-в-один как у wg-quick,
    /// presence отсекает имена, для которых скрипт гарантированно умрёт
    /// с «No such file or directory».
    public func validate(_ name: String) -> Bool {
        isNameShapeValid(name) && names().contains(name)
    }

    private func isNameShapeValid(_ name: String) -> Bool {
        name.range(of: Self.wgQuickNamePattern, options: .regularExpression) != nil
    }
}
