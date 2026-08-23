import Foundation

/// Ошибка исполнителя `wg show all dump`. Сервер демона переводит её в код
/// wire-протокола: `wgMissing` → `err wg-missing`, остальное → `err wg-failed`
/// с деталью (таймаут и ненулевой exit — оба `wg-failed`: других кодов в
/// протоколе нет).
public enum WGShowExecutorError: Error, Equatable {
    /// Резолвер не нашёл бинарь `wg`.
    case wgMissing
    /// wg не завершился за таймаут и убит.
    case timedOut
    /// Прочий сбой запуска: ненулевой exit, ошибка процесса.
    case wgFailed(String)
}

/// Исполнитель команды `wg show all dump` на стороне демона. Возвращает сырой
/// вывод (с секретами): санитизация — единственная ответственность
/// `DaemonServer`, не исполнителя. Инжектится в сервер; таймаут wg —
/// ответственность продакшн-исполнителя (структура — в задаче исполнителя),
/// не сервера.
public protocol WGShowExecuting {
    func runDump() async throws -> String
}
