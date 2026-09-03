import Foundation

/// Маскирует значения канонических назначений ключей в тексте конфига
/// wg-quick: у строк-назначений, чей ключ (слева от первого `=`, без краевых
/// пробелов) регистронезависимо равен `PrivateKey` или `PresharedKey`,
/// значение заменяется на `(hidden)`; ключ сохраняется как написан, форма
/// вывода стабильна — `<ключ> = (hidden)`.
///
/// Всё остальное проходит без изменений: комментарии, пустые строки, секции,
/// неизвестные директивы, хуки Pre/PostUp/Down (их значения могут содержать
/// слово PrivateKey — это не назначение ключа). Документированное ограничение
/// намеренное: секрет в комментарии, хуке или нестандартной директиве надёжно
/// распознать нельзя, и он остаётся видимым в полном тексте по умолчанию.
public func sanitizeWGQuickConfig(_ config: String) -> String {
    config
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(sanitizeWGQuickConfigLine)
        .joined(separator: "\n")
}

/// Маскирование одной строки: пустые строки и комментарии (`#` первым
/// непробельным символом) — не назначения и проходят как есть; строка без
/// `=` — тоже. Разделитель — первый `=` строки, `=` внутри значения
/// (base64-ключи заканчиваются на `=`) в ключ не попадает.
private func sanitizeWGQuickConfigLine(_ line: some StringProtocol) -> String {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
        return String(line)
    }
    guard let assignment = line.firstIndex(of: "=") else {
        return String(line)
    }
    let key = line[..<assignment].trimmingCharacters(in: .whitespaces)
    switch key.lowercased() {
    case "privatekey", "presharedkey":
        return "\(key) = (hidden)"
    default:
        return String(line)
    }
}
