import Foundation

/// Форматтеры карточки статуса: трафик и возраст хендшейка.
public enum Formatters {
    /// Байты в человекочитаемую строку с бинарными единицами (B/KiB/MiB/GiB).
    ///
    /// Значение в выбранных единицах < 10 — один знак после запятой без хвостовых
    /// нулей («1.5 MiB», «3 GiB»), ≥ 10 — без дробной части («876 KiB»).
    public static func formatBytes(_ bytes: UInt64) -> String {
        guard bytes >= 1_024 else { return "\(bytes) B" }

        if bytes >= 1_073_741_824 {
            return unitString(Double(bytes) / 1_073_741_824) + " GiB"
        }
        if bytes >= 1_048_576 {
            return unitString(Double(bytes) / 1_048_576) + " MiB"
        }
        return unitString(Double(bytes) / 1_024) + " KiB"
    }

    /// Возраст хендшейка строкой «N назад»: крупнейшая единица, остаток отбрасывается.
    ///
    /// Секунды (< 1 мин), минуты (< 1 ч), часы (< 24 ч), далее дни.
    /// Даты из будущего (сдвиг часов) показываются как 0 секунд.
    public static func formatAgo(_ date: Date, now: Date = Date()) -> String {
        let age = max(0, now.timeIntervalSince(date))
        let seconds = Int(age)

        if seconds < 60 {
            return L10n.string("ago.seconds", String(seconds))
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return L10n.string("ago.minutes", String(minutes))
        }
        let hours = minutes / 60
        if hours < 24 {
            return L10n.string("ago.hours", String(hours))
        }
        return L10n.string("ago.days", String(hours / 24))
    }

    /// Число единиц в строку: < 10 — один знак с отбросом хвостовых нулей, ≥ 10 — 0 знаков.
    private static func unitString(_ value: Double) -> String {
        if value < 10 {
            let rounded = String(format: "%.1f", value)
            if rounded.hasSuffix(".0") {
                return String(rounded.dropLast(2))
            }
            return rounded
        }
        return String(format: "%.0f", value)
    }
}
