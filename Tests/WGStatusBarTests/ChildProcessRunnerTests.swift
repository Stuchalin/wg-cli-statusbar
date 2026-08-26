import XCTest
@testable import WGStatusBarCore

/// Табличный тест целострочной сверки маркера — чистая функция раннера,
/// без спавна процессов. Продакшн-форма маркера в stderr wg-quick: перед ним
/// идут строки-эхо хуков `[#] …`, сам маркер печатается отдельной строкой;
/// подстрока внутри чужой строки сигналом завершения настройки не считается
/// (ранний KILL по подстроке отвечал бы ложным ok на полуподнятом туннеле).
final class ChildProcessRunnerTests: XCTestCase {
    func testStderrContainsLineMatchesWholeLinesOnly() {
        let marker = Data("MARK".utf8)
        let cases: [(name: String, data: String, expected: Bool)] = [
            ("маркер — единственная строка", "MARK\n", true),
            ("маркер первой из нескольких строк", "MARK\n[#] echo hi\n", true),
            (
                "маркер после чужих строк (продакшн-форма: эхо хуков до маркера)",
                "[#] PreUp = echo setup\nMARK\n",
                true
            ),
            ("чужая строка после маркера не мешает", "MARK\n[#] x\n", true),
            ("эхо хука с маркером внутри кавычек", "[#] echo \"MARK\n", false),
            ("маркер внутри чужой строки", "setup: MARK\n", false),
            ("маркер вплотную к тексту без границы строки", "xMARK\n", false),
            ("маркер без завершающего \\n не сверяется", "MARK", false),
            ("маркер без \\n после чужой строки", "junk\nMARK", false),
            (
                "первое вхождение внутри чужой строки, второе — целой строкой",
                "y MARK\nMARK\n",
                true
            ),
            ("пустой поток", "", false),
        ]

        for testCase in cases {
            XCTAssertEqual(
                stderrContainsLine(Data(testCase.data.utf8), line: marker),
                testCase.expected,
                testCase.name
            )
        }
    }
}
