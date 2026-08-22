import Foundation

/// Файловый слой `WireGuardTunnelNamer`; инжектится для тестов
/// (счётчики чтений, моки).
public protocol WireGuardTunnelNameFileSystem {
    /// Имена файлов в каталоге; пустой массив, если каталог не читается.
    func entries(inDirectory path: String) -> [String]
    /// Содержимое файла целиком; `nil`, если не удалось прочитать.
    func contents(ofFile path: String) -> String?
    func fileExists(atPath path: String) -> Bool
}

/// Продакшн-реализация поверх `FileManager`.
public struct FileManagerTunnelNameFileSystem: WireGuardTunnelNameFileSystem {
    public init() {}

    public func entries(inDirectory path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }

    public func contents(ofFile path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

/// Резолвит сырое имя интерфейса (`utun2`) в имя конфига wg-quick (`work-vpn`).
///
/// Механика darwin-скрипта wg-quick: `add_if` пишет фактическое имя интерфейса
/// в `<каталог>/<имя_конфига>.name`, `del_if` удаляет файл. Свежесть записи
/// валидируется соседним `<utun>.sock`.
///
/// Кэш `utun → имя` под `NSLock`: вызовы идут из фонового refresh и с главного
/// потока (⌘R). Повторный `displayName(for:)` файловую систему не читает;
/// ленивое сканирование — только на первом вызове, дальше исключительный
/// `rescan()` (новый незнакомый utun, кнопка «Обновить»).
public final class WireGuardTunnelNamer {
    private let directoryPath: String
    private let fileSystem: WireGuardTunnelNameFileSystem
    private let lock = NSLock()
    private var cache: [String: String] = [:]
    private var hasScanned = false

    public init(
        directoryPath: String = "/var/run/wireguard",
        fileSystem: WireGuardTunnelNameFileSystem = FileManagerTunnelNameFileSystem()
    ) {
        self.directoryPath = directoryPath
        self.fileSystem = fileSystem
    }

    /// Человекочитаемое имя туннеля; если не резолвится — само имя интерфейса.
    public func displayName(for interfaceName: String) -> String {
        lock.lock()
        defer { lock.unlock() }

        if let cached = cache[interfaceName] {
            return cached
        }
        if !hasScanned {
            scanLocked()
            return cache[interfaceName] ?? interfaceName
        }
        return interfaceName
    }

    /// Принудительное пересканирование каталога (замещает кэш целиком).
    public func rescan() {
        lock.lock()
        defer { lock.unlock() }

        scanLocked()
    }

    // Вызывается только под lock.
    private func scanLocked() {
        hasScanned = true
        var resolved: [String: String] = [:]

        for entry in fileSystem.entries(inDirectory: directoryPath) where entry.hasSuffix(".name") {
            let configName = String(entry.dropLast(".name".count))
            guard !configName.isEmpty else { continue }

            // Содержимое читается целиком, переводы строк обрезаются —
            // длина имени интерфейса не фиксируется.
            guard
                let interfaceName = fileSystem.contents(ofFile: directoryPath + "/" + entry)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !interfaceName.isEmpty
            else { continue }

            // Нет соседнего сокета — запись устарела (туннель снесли мимо del_if).
            guard fileSystem.fileExists(atPath: directoryPath + "/" + interfaceName + ".sock") else {
                continue
            }

            resolved[interfaceName] = configName
        }

        cache = resolved
    }
}
