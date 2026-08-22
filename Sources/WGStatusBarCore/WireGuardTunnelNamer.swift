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
/// Механика darwin-скрипта wg-quick: `add_if` (через wireguard-go) пишет
/// фактическое имя интерфейса в `<каталог>/<имя_конфига>.name`, `del_if`
/// удаляет файл. Свежесть записи валидируется соседним `<utun>.sock`:
/// оба файла создаёт wireguard-go при подъёме туннеля, поэтому у актуальной
/// пары их mtime расходятся меньше чем на 2 секунды (правило зеркалит
/// `get_real_interface` из darwin.bash). Сокет привязан к интерфейсу,
/// а не к конфигу: при переиспользовании utun другим конфигом сокет
/// пересоздаётся, и mtime расходится с зависшим старым `.name`.
///
/// Кэш `utun → имя` под `NSLock`: вызовы идут из фонового refresh и с главного
/// потока (⌘R). Попадание в кэш валидируется по текущей паре `.name`/`.sock`
/// (чтение одного файла + проверка сокета и mtime, без листинга каталога):
/// macOS переиспользует номера utun, и за закэшированным именем может стоять
/// уже другой конфиг wg-quick. Невалидная запись — исключительный `rescan()`;
/// также рескан на первом вызове и по кнопке «Обновить».
public final class WireGuardTunnelNamer {
    /// Допуск расхождения mtime пары `.name`/`.sock` — правило
    /// `get_real_interface` из darwin.bash (`diff -ge 2 || diff -le -2`
    /// → запись неактуальна).
    private static let pairMtimeTolerance: TimeInterval = 2

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
            guard isEntryCurrentLocked(configName: cached, interfaceName: interfaceName) else {
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

    /// Запись `<config>.name` ещё актуальна для этого интерфейса: файл читается,
    /// его содержимое указывает на интерфейс, рядом живой сокет, mtime пары
    /// согласованы.
    // Вызывается только под lock.
    private func isEntryCurrentLocked(configName: String, interfaceName: String) -> Bool {
        let namePath = directoryPath + "/" + configName + ".name"
        let sockPath = directoryPath + "/" + interfaceName + ".sock"
        guard
            let storedInterfaceName = fileSystem.contents(ofFile: namePath)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            storedInterfaceName == interfaceName,
            fileSystem.fileExists(atPath: sockPath)
        else { return false }
        return isPairConsistentLocked(namePath: namePath, sockPath: sockPath)
    }

    /// Актуальную пару `.name`/`.sock` создаёт wireguard-go при подъёме
    /// туннеля, поэтому их mtime расходятся меньше чем на 2 секунды. Сокет
    /// персональный для интерфейса, а не для конфига: если utun занял другой
    /// конфиг, сокет пересоздаётся, и mtime зависшего `.name` расходится
    /// с ним — запись устарела, каким бы правильным ни было содержимое.
    // Вызывается только под lock.
    private func isPairConsistentLocked(namePath: String, sockPath: String) -> Bool {
        guard
            let nameDate = fileSystem.modificationDate(ofFile: namePath),
            let sockDate = fileSystem.modificationDate(ofFile: sockPath)
        else { return false }
        return abs(sockDate.timeIntervalSince(nameDate)) < Self.pairMtimeTolerance
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
            let namePath = directoryPath + "/" + entry
            guard
                let interfaceName = fileSystem.contents(ofFile: namePath)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !interfaceName.isEmpty
            else { continue }

            // Нет соседнего сокета или mtime пары разошлись — запись устарела:
            // туннель снесли мимо del_if, либо этот utun уже поднял другой
            // конфиг и сокет пересоздан.
            let sockPath = directoryPath + "/" + interfaceName + ".sock"
            guard
                fileSystem.fileExists(atPath: sockPath),
                isPairConsistentLocked(namePath: namePath, sockPath: sockPath)
            else { continue }

            resolved[interfaceName] = configName
        }

        cache = resolved
    }
}
