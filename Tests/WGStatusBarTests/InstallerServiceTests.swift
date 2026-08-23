import XCTest
@testable import WGStatusBarCore

/// Тестируются чистые части установщика: сборка argv osascript (install и
/// uninstall — два вызова одной функции, пути с пробелами), интерпретация
/// кода возврата (успех / отмена промпта / сбой со stderr) и резолв скрипта
/// из бандла. Сам запуск osascript с системным промптом не автоматизируется
/// (Testing Strategy) — фейковый .app-бандл в tmp повторяет структуру
/// настоящего: Contents/Info.plist + Contents/Resources/<скрипт>.
final class InstallerServiceTests: XCTestCase {
    // MARK: - osascriptCommand

    func testOsascriptCommandInstallQuotesPathsWithSpaces() {
        // Путь с пробелами обёрнут одинарными кавычками внутри двойных кавычек
        // AppleScript — пробелы не рвут ни строку AppleScript, ни shell-команду.
        let command = InstallerService.osascriptCommand(
            scriptPath: "/tmp/WG Status Bar.app/Contents/Resources/install-daemon.sh",
            binaryPath: "/tmp/WG Status Bar.app/Contents/MacOS/WGStatusBarHelper"
        )

        XCTAssertEqual(command, [
            "/usr/bin/osascript",
            "-e",
            "do shell script \"'/tmp/WG Status Bar.app/Contents/Resources/install-daemon.sh' --binary '/tmp/WG Status Bar.app/Contents/MacOS/WGStatusBarHelper'\" with administrator privileges"
        ])
    }

    func testOsascriptCommandUninstallOmitsBinary() {
        // Uninstall — та же чистая функция без --binary: скрипту удаления
        // путь бинаря не нужен.
        let command = InstallerService.osascriptCommand(
            scriptPath: "/tmp/WG Status Bar.app/Contents/Resources/uninstall-daemon.sh",
            binaryPath: nil
        )

        XCTAssertEqual(command, [
            "/usr/bin/osascript",
            "-e",
            "do shell script \"'/tmp/WG Status Bar.app/Contents/Resources/uninstall-daemon.sh'\" with administrator privileges"
        ])
    }

    // MARK: - interpret

    func testInterpretZeroExitCodeIsSuccess() {
        XCTAssertEqual(InstallerService.interpret(exitCode: 0, stderr: ""), .success)
    }

    func testInterpretUserCanceledPromptIsSilentCancel() {
        // Отмена промпта пароль/Touch ID: osascript завершается ненулевым
        // кодом со «User canceled» в stderr — это тихий no-op, не ошибка.
        XCTAssertEqual(
            InstallerService.interpret(
                exitCode: 1,
                stderr: "35:104: execution error: User canceled. (-128)\n"
            ),
            .cancelled
        )
    }

    func testInterpretFailureCarriesTrimmedStderr() {
        XCTAssertEqual(
            InstallerService.interpret(exitCode: 2, stderr: "install-daemon.sh: cp failed\n"),
            .failure("install-daemon.sh: cp failed")
        )
    }

    // MARK: - installScriptPath

    func testInstallScriptPathResolvesFromAppBundleBundle() throws {
        let appURL = try makeFakeAppBundle(withScripts: true)
        defer { try? FileManager.default.removeItem(at: appURL) }
        let bundle = try XCTUnwrap(Bundle(url: appURL), "структура .app должна инициализироваться как Bundle")

        XCTAssertEqual(
            InstallerService.installScriptPath(bundle: bundle),
            appURL.appendingPathComponent("Contents/Resources/install-daemon.sh").path
        )
        XCTAssertEqual(
            InstallerService.uninstallScriptPath(bundle: bundle),
            appURL.appendingPathComponent("Contents/Resources/uninstall-daemon.sh").path
        )
    }

    func testInstallScriptPathIsNilWithoutScript() throws {
        // Dev-запуск голого бинаря: бандла-структуры со скриптом нет — резолв nil.
        let appURL = try makeFakeAppBundle(withScripts: false)
        defer { try? FileManager.default.removeItem(at: appURL) }
        let bundle = try XCTUnwrap(Bundle(url: appURL))

        XCTAssertNil(InstallerService.installScriptPath(bundle: bundle))
        XCTAssertNil(InstallerService.uninstallScriptPath(bundle: bundle))
    }

    func testCommandWithoutScriptFailsWithLocalizedMessageBeforeOsaScript() {
        // nil-скрипт не доходит до osascript: понятная локализованная ошибка
        // собирается чистой функцией — проверяем её текст.
        let result = InstallerService.command(scriptPath: nil, binaryPath: nil)

        switch result {
        case .failure(let message):
            XCTAssertEqual(message, L10n.string("error.install_script_missing"))
        case .argv:
            XCTFail("без скрипта команда собираться не должна")
        }
    }

    func testCommandWithScriptBuildsOsaScriptArgv() {
        let result = InstallerService.command(
            scriptPath: "/tmp/app/Contents/Resources/install-daemon.sh",
            binaryPath: "/tmp/app/Contents/MacOS/WGStatusBarHelper"
        )

        XCTAssertEqual(
            result,
            .argv([
                "/usr/bin/osascript",
                "-e",
                "do shell script \"'/tmp/app/Contents/Resources/install-daemon.sh' --binary '/tmp/app/Contents/MacOS/WGStatusBarHelper'\" with administrator privileges"
            ])
        )
    }

    // MARK: - Фикстура фейкового .app

    /// Собирает в tmp структуру настоящего .app: Contents/Info.plist и, по
    /// флагу, оба скрипта в Contents/Resources — туда их кладёт build-app.sh.
    private func makeFakeAppBundle(withScripts: Bool) throws -> URL {
        let appURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstallerServiceTests-\(UUID().uuidString).app")
        let contentsURL = appURL.appendingPathComponent("Contents")
        let resourcesURL = contentsURL.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

        let plistData = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.test.wgstatusbar-fixture"],
            format: .xml,
            options: 0
        )
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"))

        if withScripts {
            for name in ["install-daemon.sh", "uninstall-daemon.sh"] {
                try "#!/bin/sh\n".data(using: .utf8)?
                    .write(to: resourcesURL.appendingPathComponent(name))
            }
        }
        return appURL
    }
}
