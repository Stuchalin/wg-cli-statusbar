import Foundation

/// Валидированная пара «конфиг wg-quick → интерфейс» из `/var/run/wireguard`.
public struct WireGuardRuntimePair: Hashable {
    /// Имя конфига wg-quick — basename файла `<конфиг>.name` без расширения.
    public let configName: String
    /// Имя интерфейса — содержимое `.name` (например `utun2`).
    public let interfaceName: String

    public init(configName: String, interfaceName: String) {
        self.configName = configName
        self.interfaceName = interfaceName
    }
}

/// Сканирует `/var/run/wireguard` и возвращает валидированные пары
/// «конфиг → utun». Извлечено из `WireGuardTunnelNamer`, чтобы тем же
/// правилом свежести пользовался и демон (запрос `state`).
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
/// Ридер без состояния и без кэша — каждый вызов читает каталог заново
/// (кэш остаётся только в namer'е; демон спрашивает состояние на каждый
/// запрос, и закэшированный ответ тихо врал бы о поднятом туннеле).
public struct WireGuardRuntimeReader {
    /// Допуск расхождения mtime пары `.name`/`.sock` — правило
    /// `get_real_interface` из darwin.bash (`diff -ge 2 || diff -le -2`
    /// → запись неактуальна).
    private static let pairMtimeTolerance: TimeInterval = 2

    private let directoryPath: String
    private let fileSystem: WireGuardTunnelNameFileSystem

    public init(
        directoryPath: String = "/var/run/wireguard",
        fileSystem: WireGuardTunnelNameFileSystem = FileManagerTunnelNameFileSystem()
    ) {
        self.directoryPath = directoryPath
        self.fileSystem = fileSystem
    }

    /// Полный скан каталога: валидные пары в порядке листинга. Битые
    /// и нечитаемые записи отбрасываются; отсутствующий или нечитаемый
    /// каталог — пустой результат. Два конфига на одном utun — конфликт
    /// на стороне данных (зависший `.name`); выбор победителя за вызывающим
    /// (namer сворачивает с last-wins, как и до извлечения ридера).
    public func readPairs() -> [WireGuardRuntimePair] {
        var pairs: [WireGuardRuntimePair] = []

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
                isPairConsistent(namePath: namePath, sockPath: sockPath)
            else { continue }

            pairs.append(WireGuardRuntimePair(configName: configName, interfaceName: interfaceName))
        }

        return pairs
    }

    /// Запись `<config>.name` ещё актуальна для этого интерфейса: файл
    /// читается, его содержимое указывает на интерфейс, рядом живой сокет,
    /// mtime пары согласованы. Валидация кэша namer'а — один файл и его
    /// сокет, без листинга каталога.
    public func isPairCurrent(configName: String, interfaceName: String) -> Bool {
        let namePath = directoryPath + "/" + configName + ".name"
        let sockPath = directoryPath + "/" + interfaceName + ".sock"
        guard
            let storedInterfaceName = fileSystem.contents(ofFile: namePath)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            storedInterfaceName == interfaceName,
            fileSystem.fileExists(atPath: sockPath)
        else { return false }
        return isPairConsistent(namePath: namePath, sockPath: sockPath)
    }

    /// Актуальную пару `.name`/`.sock` создаёт wireguard-go при подъёме
    /// туннеля, поэтому их mtime расходятся меньше чем на 2 секунды. Сокет
    /// персональный для интерфейса, а не для конфига: если utun занял другой
    /// конфиг, сокет пересоздаётся, и mtime зависшего `.name` расходится
    /// с ним — запись устарела, каким бы правильным ни было содержимое.
    private func isPairConsistent(namePath: String, sockPath: String) -> Bool {
        guard
            let nameDate = fileSystem.modificationDate(ofFile: namePath),
            let sockDate = fileSystem.modificationDate(ofFile: sockPath)
        else { return false }
        return abs(sockDate.timeIntervalSince(nameDate)) < Self.pairMtimeTolerance
    }
}
