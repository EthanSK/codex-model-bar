import XCTest
@testable import CodexModelBarCore

final class DiagnosticLogTests: XCTestCase {
    func testSurvivesRestartAndKeepsSingleLineEntries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("diagnostic.log")
        DiagnosticLog(url: url).append("attempt=first\nphase=start")
        DiagnosticLog(url: url).append("attempt=second")
        let lines = try String(contentsOf: url).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("attempt=first\\nphase=start"))
        XCTAssertTrue(lines[1].contains("attempt=second"))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testRotatesToOnePreviousFileWithinSizeLimit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("diagnostic.log")
        let log = DiagnosticLog(url: url, maximumBytes: 128)
        for index in 0..<20 { log.append("attempt=\(index) " + String(repeating: "x", count: 60)) }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(names, ["diagnostic.log", "diagnostic.log.previous"])
        for name in names { XCTAssertLessThanOrEqual(try Data(contentsOf: directory.appendingPathComponent(name)).count, 128) }
        XCTAssertTrue(try String(contentsOf: url).contains("attempt=19"))
    }
}
