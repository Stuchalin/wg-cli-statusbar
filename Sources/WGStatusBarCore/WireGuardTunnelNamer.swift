import Foundation

/// Файловый слой `WireGuardTunnelNamer`; инжектится для тестов
/// (счётчики чтений, моки).
public protocol WireGuardTunnelNameFileSystem {
    /// Имена файлов в каталоге; пустой массив, если каталог не читается.
    func entries(inDirectory path: String) -> [String]
    /// Содержимое файла целиком; `nil`, если не удалось прочитать.
    func contents(ofFile path: String) -> String?
    func fileExists(atPath path: String) -> Bool
    /// mtime файла; `nil`, если не удалось получить.
    func modificationDate(ofFile path: String) -> Date?
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

    public func modificationDate(ofFile path: String) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return attributes?[.modificationDate] as? Date
    }
}

/// Резолвит сырое имя интерфейса (`utun2`) в имя конфига wg-quick (`work-vpn`).
///
/// Скан каталога и правило свежести пары `.name`/`.sock` — в
/// `WireGuardRuntimeReader`; namer добавляет поверх него кэш.
///
/// Кэш `utun → имя` под `NSLock`: вызовы идут из фонового refresh и с главного
/// потока (⌘R). Попадание в кэш валидируется по текущей паре `.name`/`.sock`
/// (чтение одного файла + проверка сокета и mtime, без листинга каталога):
/// macOS переиспользует номера utun, и за закэшированным именем может стоять
/// уже другой конфиг wg-quick. Невалидная запись — исключительный `rescan()`;
/// также рескан на первом вызове и по кнопке «Обновить».
public final class WireGuardTunnelNamer {
    private let reader: WireGuardRuntimeReader
    private let lock = NSLock()
    private var cache: [String: String] = [:]
    private var hasScanned = false

    public init(
        directoryPath: String = "/var/run/wireguard",
        fileSystem: WireGuardTunnelNameFileSystem = FileManagerTunnelNameFileSystem()
    ) {
        self.reader = WireGuardRuntimeReader(
            directoryPath: directoryPath,
            fileSystem: fileSystem
        )
    }

    /// Человекочитаемое имя туннеля; если не резолвится — само имя интерфейса.
    public func displayName(for interfaceName: String) -> String {
        lock.lock()
        defer { lock.unlock() }

        if let cached = cache[interfaceName] {
            guard reader.isPairCurrent(configName: cached, interfaceName: interfaceName) else {
                // Туннель снесли/переиспользовали utun под другой конфиг —
                // закэшированное имя устарело, перечитываем каталог.
                scanLocked()
                return cache[interfaceName] ?? interfaceName
            }
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

        // При конфликте двух конфигов на одном utun (зависший `.name`)
        // побеждает последний по листингу — как и до извлечения ридера.
        for pair in reader.readPairs() {
            resolved[pair.interfaceName] = pair.configName
        }

        cache = resolved
    }
}
