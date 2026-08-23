import Foundation
import WGStatusBarCore

// Тонкая обёртка демона — юнит-тестами не покрывается (конвенция тонких
// main-файлов, как у Sources/App/main.swift). Вся логика — в WGStatusBarCore:
// сервер санитизирует дамп до отправки, исполнитель резолвит и запускает wg.

// Сокет демона — общий с приложением (`helperSocketPath` из Core, один
// источник: пути app и helper не могут разойтись); права 0660 root:admin
// ставит сервер при bind.
let server = DaemonServer(
    executor: WGShowExecutor(),
    socketPath: helperSocketPath
)

do {
    // Вечный accept-цикл; возвращается только по отмене задачи.
    try await server.run()
} catch {
    // Ошибки setup (bind и пр.) — фатальные: launchd поднимет бинарь заново
    // по KeepAlive, а stderr уходит в unified log для диагностики.
    FileHandle.standardError.write(Data("WGStatusBarHelper: \(error)\n".utf8))
    exit(1)
}
