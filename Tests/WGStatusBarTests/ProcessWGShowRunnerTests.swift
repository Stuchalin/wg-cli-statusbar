import XCTest
@testable import WGStatusBarCore

/// Раннер против короткоживущих системных процессов: успешный вывод, классификация
/// exit-кодов, таймаут и дренаж каналов больше буфера пайпа. Команда и таймаут
/// инжектятся; `zsh -f` — без rc-файлов, чтобы вывод был предсказуем.
final class ProcessWGShowRunnerTests: XCTestCase {
    private func makeRunner(arguments: [String], timeout: TimeInterval = 5) -> ProcessWGShowRunner {
        ProcessWGShowRunner(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: arguments,
            timeout: timeout
        )
    }

    func testReturnsProcessStdout() async throws {
        let runner = makeRunner(arguments: ["-f", "-c", "printf hello"])

        let output = try await runner.runDump()

        XCTAssertEqual(output, "hello")
    }

    func testNonZeroExitWithoutStderrUsesLocalizedFailure() async throws {
        let runner = makeRunner(arguments: ["-f", "-c", "exit 3"])

        do {
            _ = try await runner.runDump()
            XCTFail("ненулевой exit code должен давать ошибку")
        } catch let error as NSError {
            XCTAssertEqual(error.code, 3)
            XCTAssertEqual(error.localizedDescription, L10n.string("error.wg_show_failed", "3"))
        }
    }

    func testNonZeroExitWithStderrSurfacesStderrText() async throws {
        let runner = makeRunner(arguments: ["-f", "-c", "echo boom 1>&2; exit 4"])

        do {
            _ = try await runner.runDump()
            XCTFail("ненулевой exit code должен давать ошибку")
        } catch let error as NSError {
            XCTAssertEqual(error.code, 4)
            XCTAssertEqual(error.localizedDescription, "boom", "текст stderr важнее локализованного шаблона")
        }
    }

    func testTimeoutTerminatesHangingProcess() async throws {
        let runner = makeRunner(arguments: ["-f", "-c", "sleep 5"], timeout: 0.3)

        do {
            _ = try await runner.runDump()
            XCTFail("зависший процесс должен падать по таймауту")
        } catch {
            XCTAssertEqual(error.localizedDescription, L10n.string("error.wg_show_timeout"))
        }
    }

    func testLargeOutputBeyondPipeBufferIsDrained() async throws {
        // 200 KB > буфера пайпа (~64 KiB): без параллельного чтения процесс
        // блокировался бы на записи и падал по таймауту вместо данных
        let runner = makeRunner(arguments: ["-f", "-c", "head -c 200000 /dev/zero | tr '\\0' x"])

        let output = try await runner.runDump()

        XCTAssertEqual(output.count, 200_000)
    }
}
