import Foundation
import XCTest
@testable import CodexModelBar
import CodexModelBarCore

final class ModelCatalogServiceTests: XCTestCase {
    func testCodexCacheReplacesOlderGPTOnlyBarSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-bar-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let barCache = directory.appendingPathComponent("bar.json")
        let codexCache = directory.appendingPathComponent("codex.json")
        try JSONEncoder().encode([
            CodexModel(id: "gpt-6-sol", displayName: "GPT-6-Sol"),
            CodexModel(id: "gpt-5.6-sol", displayName: "GPT-5.6-Sol"),
        ]).write(to: barCache)
        try Data("""
            {"models":[
                {"slug":"gpt-6-sol","display_name":"GPT-6-Sol","visibility":"list"},
                {"slug":"gpt-5.6-sol","display_name":"GPT-5.6-Sol","visibility":"hide"},
                {"slug":"claude-opus-5-5","display_name":"Opus 5.5","visibility":"list"},
                {"slug":"claude-fable-5-1","display_name":"Fable 5.1","visibility":"list"}
            ]}
            """.utf8).write(to: codexCache)

        let service = ModelCatalogService(cacheURL: barCache, codexCacheURL: codexCache)
        XCTAssertEqual(service.loadCachedModels().filter { !$0.hidden }.map(\.id),
                       ["gpt-6-sol", "claude-opus-5-5", "claude-fable-5-1"])

        let refreshed = expectation(description: "Codex cache refresh")
        service.refresh(codexAppURL: nil) { models in
            XCTAssertEqual(models?.filter { !$0.hidden }.map(\.id),
                           ["gpt-6-sol", "claude-opus-5-5", "claude-fable-5-1"])
            refreshed.fulfill()
        }
        wait(for: [refreshed], timeout: 5)
        XCTAssertEqual(try JSONDecoder().decode([CodexModel].self, from: Data(contentsOf: barCache))
            .filter { !$0.hidden }.map(\.id),
            ["gpt-6-sol", "claude-opus-5-5", "claude-fable-5-1"])
    }
}
