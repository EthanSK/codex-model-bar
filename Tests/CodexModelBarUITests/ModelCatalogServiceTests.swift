import Foundation
import XCTest
@testable import CodexModelBar
import CodexModelBarCore

final class ModelCatalogServiceTests: XCTestCase {
    func testPartialCacheCannotRemoveGPTButtonsOrComposerRecognitionEvenAfterRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("model-bar-catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let barCache = directory.appendingPathComponent("bar.json")
        let codexCache = directory.appendingPathComponent("codex.json")
        let full = [
            CodexModel(id: "gpt-6-astra", displayName: "GPT-6-Astra", supportedEfforts: ["low", "medium", "high", "xhigh", "max", "ultra"]),
            CodexModel(id: "gpt-6-sol", displayName: "GPT-6-Sol", supportedEfforts: ["low", "medium", "high", "xhigh", "max", "ultra"]),
            CodexModel(id: "claude-opus-5-5", displayName: "Opus 5.5"),
            CodexModel(id: "claude-fable-5-1", displayName: "Fable 5.1"),
        ]
        try JSONEncoder().encode(full).write(to: barCache)
        // Observed production rewrite omitted GPT-6 while the desktop still
        // displayed GPT-6 Sol High. The bar previously collapsed to two buttons.
        try Data("""
            {"models":[
                {"slug":"claude-opus-5-5","display_name":"Opus 5.5","visibility":"list"},
                {"slug":"claude-fable-5-1","display_name":"Fable 5.1","visibility":"list"}
            ]}
            """.utf8).write(to: codexCache)
        let service = ModelCatalogService(cacheURL: barCache, codexCacheURL: codexCache)
        XCTAssertEqual(service.loadCachedModels(), full)
        let refreshed = expectation(description: "Partial snapshot merged")
        service.refresh(codexAppURL: nil) { models in
            XCTAssertEqual(models, full)
            XCTAssertEqual(CurrentModelMatcher.selection(forButtonTitle: "GPT-6 Sol High", among: models ?? []),
                           CurrentSelection(modelID: "gpt-6-sol", effort: "high"))
            refreshed.fulfill()
        }
        wait(for: [refreshed], timeout: 5)
        let restarted = ModelCatalogService(cacheURL: barCache, codexCacheURL: codexCache)
        XCTAssertEqual(restarted.loadCachedModels(), full)
        XCTAssertEqual(try JSONDecoder().decode([CodexModel].self, from: Data(contentsOf: barCache)), full)
    }

    func testRefreshStillAppliesExplicitHidingAndUpdatedReasoningMetadata() {
        let saved = [CodexModel(id: "sol", displayName: "Sol", supportedEfforts: ["low", "high"]),
                     CodexModel(id: "old", displayName: "Old")]
        let observed = [CodexModel(id: "old", displayName: "Old", hidden: true),
                        CodexModel(id: "sol", displayName: "Sol", supportedEfforts: ["low", "high", "max"]),
                        CodexModel(id: "new", displayName: "New")]
        let merged = ModelCatalogService.merge(saved: saved, observed: observed)
        XCTAssertEqual(merged.map(\.id), ["sol", "old", "new"])
        XCTAssertEqual(merged[0].supportedEfforts, ["low", "high", "max"])
        XCTAssertTrue(merged[1].hidden)
    }

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
