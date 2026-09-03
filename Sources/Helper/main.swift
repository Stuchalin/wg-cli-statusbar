import Foundation
import WGStatusBarCore

// Тонкий диспетчер бинаря хелпера — юнит-тестами не покрывается (конвенция
// тонких main-файлов, как у Sources/App/main.swift). Выбор режима — чистый
// парсер Core (`parseHelperArgv`, исчерпывающе тестируется); здесь — только
// исполнение результата:
//   без аргументов          — демон (DaemonServer на общем сокете, launchd);
//   --capabilities          — побочный-эффект-свободный ответ возможностей;
//   --print-config-raw <n>  — one-shot raw-чтение конфига в `b64:`-конверте;
//   любое другое argv       — фиксированная категория stderr, код 2, до
//                             какого-либо доступа к файловой системе.
switch parseHelperArgv(Array(CommandLine.arguments.dropFirst())) {
case .daemon:
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
        // Ошибки setup (bind и пр.) — фатальные: launchd поднимет бинарь
        // заново по KeepAlive; stderr пишется в /var/log/wgstatusbar-helper.log
        // (StandardErrorPath в plist из install-daemon.sh) и доступен для
        // диагностики циклических падений.
        FileHandle.standardError.write(Data("WGStatusBarHelper: \(error)\n".utf8))
        exit(1)
    }
case .capabilities:
    FileHandle.standardOutput.write(Data(helperCapabilitiesOutput().utf8))
case .printConfigRaw(let name):
    switch runHelperOneShotRawRead(named: name) {
    case .success(let envelope):
        FileHandle.standardOutput.write(Data(envelope.utf8))
    case .failure(let stderrLine, let exitStatus):
        FileHandle.standardError.write(Data((stderrLine + "\n").utf8))
        exit(exitStatus)
    }
case .invalid:
    FileHandle.standardError.write(Data("wgstatusbar: invalid arguments\n".utf8))
    exit(2)
}
