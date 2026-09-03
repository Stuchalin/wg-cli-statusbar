import Foundation

/// Токен возможности one-shot raw-чтения: последнее слово ответа
/// `--capabilities`. Версируется отдельно от wire-протокола сокета — смена
/// формата one-shot-режима меняет токен, не протокол демона.
public let helperConfigRawCapabilityToken = "config-raw-v1"

/// Режим запуска бинаря хелпера, разобранный из argv (без argv[0]). Ядро
/// разбора живёт в Core и покрыто тестами исчерпывающе; `Sources/Helper/main.swift`
/// — тонкий исполнитель результата (конвенция тонких main-файлов).
public enum HelperLaunchMode: Equatable {
    /// Без аргументов — обычный старт демона (DaemonServer под launchd).
    case daemon
    /// Ровно `--capabilities`: побочных эффектов нет, только stdout-ответ.
    case capabilities
    /// Ровно `--print-config-raw <name>`: one-shot raw-чтение конфига.
    case printConfigRaw(String)
    /// Любая другая форма argv — отклоняется до какого-либо доступа к FS.
    case invalid
}

/// Разбор argv хелпера: строго три допустимые формы (без аргументов /
/// `--capabilities` / `--print-config-raw <name>` c непустым единственным
/// аргументом), всё прочее — `.invalid`, ещё до обращения к файловой системе.
/// Shape-валидация имени здесь не делается — это работа `TunnelConfigReader`
/// (общая с wg-quick), отказ fail-closed.
public func parseHelperArgv(_ arguments: [String]) -> HelperLaunchMode {
    switch arguments.count {
    case 0:
        return .daemon
    case 1:
        return arguments[0] == "--capabilities" ? .capabilities : .invalid
    case 2:
        guard arguments[0] == "--print-config-raw", !arguments[1].isEmpty else {
            return .invalid
        }
        return .printConfigRaw(arguments[1])
    default:
        return .invalid
    }
}

/// Точная строка ответа `--capabilities` (с завершающим `\n`):
/// `capabilities <протокол> <build> config-raw-v1\n`. Побочных эффектов нет —
/// ни файловой системы, ни сокета; приложение запускает её от обычного
/// пользователя как префлайт Reveal (привилегированный запуск — только после
/// успешной сверки).
public func helperCapabilitiesOutput() -> String {
    "capabilities \(helperProtocolVersion) \(helperBuildNumber) \(helperConfigRawCapabilityToken)\n"
}

/// Категории stderr one-shot-режима: фиксированные строки без имени, пути и
/// содержимого — их пишет сам root-бинарь, перехватывает osascript; наружу (в
/// приложение) они не идут и нигде не логируются с данными.
public enum HelperOneShotErrorCategory {
    /// Имя не прошло shape-проверку.
    public static let invalidName = "wgstatusbar: invalid tunnel name"
    /// Файл не найден, небезопасен, нечитаем, больше лимита или не UTF-8.
    public static let configUnavailable = "wgstatusbar: config unavailable"
}

/// Результат one-shot raw-чтения: чистое ядро без реальных дескрипторов —
/// `Sources/Helper/main.swift` пишет его в stdout/stderr и выходит с кодом.
public enum HelperOneShotOutcome: Equatable {
    /// Один `b64:`-конверт полного документа на stdout (терминатор конверта —
    /// обрамление транспорта; собственный завершающий `\n` файла живёт внутри
    /// base64 и сохраняется точно).
    case success(stdoutEnvelope: String)
    /// Фиксированная категория stderr + ненулевой код возврата; частичного
    /// содержимого не бывает — ридер либо прочитал файл целиком, либо ничем
    /// не отвечает.
    case failure(stderrLine: String, exitStatus: Int32)
}

/// One-shot raw-чтение конфига по имени: общий безопасный ридер (тот же
/// контракт, что у маскированного чтения демона — порядок каталогов,
/// O_NOFOLLOW, лимит 256 KiB, полный UTF-8-декод) → `b64:`-конверт. Ошибка
/// чтения — фиксированная категория без деталей.
public func runHelperOneShotRawRead(
    named name: String,
    reader: TunnelConfigReader = TunnelConfigReader()
) -> HelperOneShotOutcome {
    switch reader.readConfig(named: name) {
    case .success(let document):
        return .success(stdoutEnvelope: ConfigEnvelope.encode(document.text))
    case .failure(.invalidName):
        return .failure(stderrLine: HelperOneShotErrorCategory.invalidName, exitStatus: 2)
    case .failure:
        return .failure(stderrLine: HelperOneShotErrorCategory.configUnavailable, exitStatus: 1)
    }
}
