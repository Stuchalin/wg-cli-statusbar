import Darwin
import Foundation

/// Исход одного открытия конфига через open(2) с O_NOFOLLOW — сразу по
/// дескриптору, без отдельного lstat-шага: между проверкой пути и открытием
/// файл мог подменить симлинк, и только open с O_NOFOLLOW закрывает эту
/// гонку (lstat+open её не закрывают).
public enum TunnelConfigOpenOutcome {
    /// ENOENT — файла нет; поиск продолжается ниже по приоритету каталогов.
    case notFound
    /// ELOOP — путь оказался симлинком (в т.ч. подменённым после листинга).
    case symlink
    /// Открыть не удалось (права, race, спецфайл) — fail-closed, без
    /// молчаливого прохода к дублю из каталога ниже приоритетом.
    case unreadable
    /// Файл открыт; дальше — fstat и чтение по дескриптору.
    case opened(TunnelConfigReaderFileHandle)
}

/// Результат одного read(2) по дескриптору.
public enum TunnelConfigReadChunk {
    /// Прочитано `Int` байт (0 здесь не кодируется — это `endOfFile`).
    case bytes(Int)
    /// EOF.
    case endOfFile
    /// EINTR — чтение прервано сигналом, повторить.
    case interrupted
    /// Ошибка чтения.
    case failed
}

/// Открытый дескриптор конфига. Класс (не структура): смещение чтения
/// мутирует. Инжектится для тестов — фейк моделирует содержимое кусками,
/// EOF, прерванные и падающие чтения, нерегулярность по fstat.
public protocol TunnelConfigReaderFileHandle: AnyObject {
    /// fstat(2) по уже открытому дескриптору: обычный ли это файл.
    /// Проверка после open обязательна: O_NOFOLLOW страхует только симлинк
    /// на последнем компоненте пути, класс самого файла подтверждает fstat.
    var isRegularFile: Bool { get }
    /// Один read(2): записывает не более `maxLength` байт в `buffer`.
    func read(into buffer: UnsafeMutableRawPointer, maxLength: Int) -> TunnelConfigReadChunk
    /// close(2). Ридер вызывает ровно один раз на любом исходе чтения.
    func close()
}

/// Файловый слой `TunnelConfigReader`; в продакшне — POSIX open/fstat/read.
public protocol TunnelConfigReaderFileSystem {
    /// open(2) с O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC по точному
    /// пути `<dir>/<name>.conf`. O_NONBLOCK нужен, чтобы open FIFO не
    /// заблокировал навсегда последовательный accept-loop демона (на обычных
    /// файлах флаг на семантику чтения не влияет, а нерегулярные файлы
    /// отбрасываются fstat-проверкой сразу после открытия).
    func openFileNoFollow(atPath path: String) -> TunnelConfigOpenOutcome
}

/// Продакшн-реализация файлового слоя ридера поверх POSIX.
public struct PosixTunnelConfigReaderFileSystem: TunnelConfigReaderFileSystem {
    public init() {}

    public func openFileNoFollow(atPath path: String) -> TunnelConfigOpenOutcome {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT: return .notFound
            case ELOOP: return .symlink
            default: return .unreadable
            }
        }
        return .opened(PosixTunnelConfigFileHandle(descriptor: descriptor))
    }
}

/// Обёртка над настоящим fd: fstat/read/close без промежуточных путей.
private final class PosixTunnelConfigFileHandle: TunnelConfigReaderFileHandle {
    private let descriptor: Int32

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    var isRegularFile: Bool {
        var status = stat()
        return fstat(descriptor, &status) == 0 && (status.st_mode & S_IFMT) == S_IFREG
    }

    func read(into buffer: UnsafeMutableRawPointer, maxLength: Int) -> TunnelConfigReadChunk {
        let readBytes = Darwin.read(descriptor, buffer, maxLength)
        if readBytes >= 0 {
            return readBytes == 0 ? .endOfFile : .bytes(Int(readBytes))
        }
        return errno == EINTR ? .interrupted : .failed
    }

    func close() {
        _ = Darwin.close(descriptor)
    }
}

/// Ошибки чтения конфига — типизированные, без ассоциированных данных:
/// ни путь, ни содержимое файла не могут утечь вместе с ошибкой.
public enum TunnelConfigReaderError: Error, Equatable {
    /// Имя не проходит shape-проверку wg-quick (общую с `TunnelConfigStore`).
    case invalidName
    /// `<name>.conf` нет ни в одном каталоге поиска.
    case notFound
    /// Первый по приоритету матч — симлинк.
    case symlink
    /// Открытый дескриптор по fstat — не обычный файл (FIFO, устройство…).
    case notRegularFile
    /// Открытие или чтение не удалось (права, ошибка I/O).
    case unreadable
    /// Файл больше `TunnelConfigReader.maxSizeBytes`.
    case tooLarge
    /// Содержимое не декодируется в UTF-8 целиком.
    case invalidUTF8
}

/// Целиком прочитанный конфиг: точный текст файла, как он лежит на диске, —
/// включая наличие или отсутствие завершающего перевода строки. Обрамление
/// (base64-конверт, терминатор строки протокола) — задача вызывающих;
/// результат ридера они не изменяют. Один контракт и для маскированного
/// чтения демона, и для raw-чтения one-shot-помощника.
public struct TunnelConfigDocument: Equatable {
    /// Точное содержимое файла (пустая строка — пустой файл).
    public let text: String

    public init(text: String) {
        self.text = text
    }

    /// Есть ли у файла завершающий `\n` — транспорт обязан это сохранить.
    public var hasFinalNewline: Bool {
        text.hasSuffix("\n")
    }
}

/// Общий ридер конфигов wg-quick: резолвит `<name>.conf` по порядку
/// `tunnelConfigSearchPaths` (первый существующий матч), открывает его
/// дескриптор-безопасно и читает целиком с лимитом.
public struct TunnelConfigReader {
    /// Верхний предел размера: 256 KiB. Ридер читает максимум лимит+1 байт —
    /// ровно лимит+1 прочитанных байт означает «файл больше», без попыток
    /// дочитать хвост.
    public static let maxSizeBytes = 256 * 1024

    /// Потолок подряд идущих прерванных чтений (EINTR): каждый retry — новый
    /// read, но вечный EINTR не должен подвешивать последовательный цикл
    /// демона.
    private static let maxConsecutiveInterruptedReads = 1024

    /// Размер буфера одного read-вызова.
    private static let chunkBufferSize = 4096

    private let searchPaths: [String]
    private let fileSystem: TunnelConfigReaderFileSystem

    /// - Parameters:
    ///   - searchPaths: каталоги конфигов в порядке приоритета
    ///     (по умолчанию — общий `tunnelConfigSearchPaths`).
    ///   - fileSystem: инжектируемый FS (POSIX в продакшне, фейк в тестах).
    public init(
        searchPaths: [String] = tunnelConfigSearchPaths,
        fileSystem: TunnelConfigReaderFileSystem = PosixTunnelConfigReaderFileSystem()
    ) {
        self.searchPaths = searchPaths
        self.fileSystem = fileSystem
    }

    /// Читает конфиг туннеля целиком. Небезопасный первый по приоритету
    /// матч (симлинк, недоступный файл) — ошибка, а не проход к дублю из
    /// каталога ниже приоритетом: wg-quick взял бы именно первый, показывать
    /// пользователю другой файл нельзя.
    public func readConfig(named name: String) -> Result<TunnelConfigDocument, TunnelConfigReaderError> {
        guard TunnelConfigStore.isNameShapeValid(name) else {
            return .failure(.invalidName)
        }
        for directory in searchPaths {
            let path = directory + "/" + name + ".conf"
            switch fileSystem.openFileNoFollow(atPath: path) {
            case .notFound:
                continue
            case .symlink:
                return .failure(.symlink)
            case .unreadable:
                return .failure(.unreadable)
            case .opened(let handle):
                return Self.readAll(from: handle)
            }
        }
        return .failure(.notFound)
    }

    /// Чтение по открытому дескриптору: fstat-проверка, лимит+1 байт,
    /// полный UTF-8-декод без частичного результата. Дескриптор
    /// закрывается на каждом исходе.
    private static func readAll(from handle: TunnelConfigReaderFileHandle) -> Result<TunnelConfigDocument, TunnelConfigReaderError> {
        defer { handle.close() }
        guard handle.isRegularFile else {
            return .failure(.notRegularFile)
        }

        var remaining = maxSizeBytes + 1
        var collected: [UInt8] = []
        collected.reserveCapacity(chunkBufferSize)
        var buffer = [UInt8](repeating: 0, count: chunkBufferSize)
        var interruptedStreak = 0

        while true {
            let wanted = min(buffer.count, remaining)
            let chunk = buffer.withUnsafeMutableBytes { raw in
                handle.read(into: raw.baseAddress!, maxLength: wanted)
            }
            switch chunk {
            case .endOfFile:
                guard let text = String(bytes: collected, encoding: .utf8) else {
                    return .failure(.invalidUTF8)
                }
                return .success(TunnelConfigDocument(text: text))
            case .interrupted:
                interruptedStreak += 1
                guard interruptedStreak <= maxConsecutiveInterruptedReads else {
                    return .failure(.unreadable)
                }
            case .failed:
                return .failure(.unreadable)
            case .bytes(let count):
                // Контракт дескриптора — не больше maxLength; его нарушение —
                // ошибка чтения, а не выход за границы буфера.
                guard (0...wanted).contains(count) else {
                    return .failure(.unreadable)
                }
                interruptedStreak = 0
                collected.append(contentsOf: buffer[0..<count])
                remaining -= count
                if remaining == 0 {
                    // Прочитан ровно лимит+1 байт — файл гарантированно
                    // больше лимита.
                    return .failure(.tooLarge)
                }
            }
        }
    }
}
