import Foundation

/// Свежесть последнего хендшейка пира.
///
/// Отображается точкой состояния в карточке:
/// `fresh` — green, `aging` — orange, `stale`/`never` — secondary.
public enum HandshakeFreshness: Equatable {
    case fresh
    case aging
    case stale
    case never

    /// Хендшейк не старше этого возраста считается свежим (green). Граница включительно.
    public static let freshThreshold: TimeInterval = 120
    /// Хендшейк не старше этого возраста ещё считается активностью (orange).
    /// Старше — `stale`. Граница включительно.
    public static let agingThreshold: TimeInterval = 600

    /// Пир считается активным (подключён), пока хендшейк `fresh` или `aging`.
    public var isActive: Bool {
        switch self {
        case .fresh, .aging: return true
        case .stale, .never: return false
        }
    }

    public static func freshness(date: Date?, now: Date = Date()) -> HandshakeFreshness {
        guard let date else { return .never }
        let age = now.timeIntervalSince(date)
        if age <= freshThreshold { return .fresh }
        if age <= agingThreshold { return .aging }
        return .stale
    }
}

/// Классификация маршрутизации пира по строке allowed ips из дампа.
public enum RouteScope: Equatable {
    /// Есть маршрут по умолчанию (`0.0.0.0/0` или `::/0`) — весь трафик через туннель.
    case fullTunnel
    /// Только подсети — сплит-туннелинг.
    case splitTunnel
    /// Маршрутов нет: строка пустая или placeholder `(none)`.
    case none

    /// Маршруты по умолчанию из allowed ips — единственное место определения.
    static let defaultRoutes: Set<String> = ["0.0.0.0/0", "::/0"]

    /// Непустые записи allowed ips: по запятой, без пробелов; `(none)` остаётся записью.
    static func entries(allowedIps: String?) -> [String] {
        (allowedIps ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public init(allowedIps: String?) {
        self.init(entries: Self.entries(allowedIps: allowedIps))
    }

    init(entries: [String]) {
        guard !entries.isEmpty, entries != ["(none)"] else {
            self = .none
            return
        }

        self = entries.contains { Self.defaultRoutes.contains($0) } ? .fullTunnel : .splitTunnel
    }
}
