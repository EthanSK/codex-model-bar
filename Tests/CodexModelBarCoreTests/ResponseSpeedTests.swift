import XCTest
@testable import CodexModelBarCore

final class ResponseSpeedTests: XCTestCase {
    func testSavedSpeedSurvivesNewMemoryInstancesAndStaysOneSmallFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("speed.txt")
        var memory = ResponseSpeedMemory()
        for _ in 0..<100 {
            for speed in ResponseSpeed.allCases {
                memory.speed = speed
                try memory.write(to: url)
                let restored = try ResponseSpeedMemory(contentsOf: url)
                XCTAssertEqual(restored.speed, speed)
                XCTAssertEqual(restored.toggle(for: .standard).command, speed.command)
                XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, 10)
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["speed.txt"])
    }

    func testMissingOrInvalidSavedSpeedDoesNotBecomeARealTier() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("speed.txt")
        XCTAssertThrowsError(try ResponseSpeedMemory(contentsOf: url))
        for value in ["", "Unknown", "Fast\nUltrafast", String(repeating: "a", count: 1_000)] {
            try Data(value.utf8).write(to: url)
            XCTAssertThrowsError(try ResponseSpeedMemory(contentsOf: url))
        }
        var memory = ResponseSpeedMemory()
        memory.recordPostedToggle(.fast)
        try memory.write(to: url)
        XCTAssertEqual(try ResponseSpeedMemory(contentsOf: url).speed, .fast)
    }

    func testStandardRepeatsTheLastPostedActiveToggle() {
        var memory = ResponseSpeedMemory()
        for tier in [ResponseSpeed.fast, .ultrafast] {
            memory.recordPostedToggle(tier)
            XCTAssertEqual(memory.toggle(for: .standard).command, tier.command)
            memory.recordPostedToggle(memory.toggle(for: .standard))
            XCTAssertEqual(memory.speed, .standard)
            XCTAssertNil(memory.toggle(for: .standard).command) // A second Standard click must not turn the tier back on.
        }
    }

    func testUnknownStandardUsesUltrafastAndAllowsAnotherClickToUndoTheGuess() {
        var memory = ResponseSpeedMemory()
        XCTAssertNil(memory.speed)
        XCTAssertEqual(memory.toggle(for: .standard).command, "/ultrafast")
        XCTAssertNil(memory.speed) // Resolving a command does not claim it was actually posted.
        memory.recordPostedToggle(memory.toggle(for: .standard))
        XCTAssertEqual(memory.toggle(for: .standard).command, "/ultrafast")
        memory.recordPostedToggle(memory.toggle(for: .standard))
        XCTAssertEqual(memory.speed, .standard)
        XCTAssertNil(memory.toggle(for: .standard).command)
    }

    func testSwitchingAndRepeatedWheelTogglesMatchCodexSemantics() {
        var memory = ResponseSpeedMemory()
        for (command, expected) in [(ResponseSpeed.fast, ResponseSpeed.fast), (.ultrafast, .ultrafast),
                                    (.ultrafast, .standard), (.fast, .fast), (.fast, .standard)] {
            memory.recordPostedToggle(command)
            XCTAssertEqual(memory.speed, expected)
        }
    }

    func testConfirmedCombinedAstraSpeedCanBeTurnedOff() {
        var memory = ResponseSpeedMemory()
        memory.speed = .ultrafast
        XCTAssertEqual(memory.toggle(for: .standard).command, "/ultrafast")
        memory.recordPostedToggle(.ultrafast)
        XCTAssertEqual(memory.speed, .standard)
    }

    func testCurrentCodexMoreUsageDescriptionStillIdentifiesFastAsOff() {
        XCTAssertEqual(SpeedCommandState.read(title: "Fast 1.5x speed, more usage", speed: .fast), .disabled)
        XCTAssertNil(SpeedCommandState.read(title: "Fast nanx speed, more usage", speed: .fast))
        XCTAssertNil(SpeedCommandState.read(title: "Fast 1.5x speed, more usage extra", speed: .fast))
    }

    func testExactSlashDescriptionsDistinguishCurrentTier() {
        XCTAssertEqual(SpeedCommandState.read(title: "Fast 1.5x speed, increased usage", speed: .fast), .disabled)
        XCTAssertEqual(SpeedCommandState.read(title: "/fast 2x speed, increased usage", speed: .fast), .disabled)
        XCTAssertEqual(SpeedCommandState.read(title: "Fast Turn off Fast and return to standard speed", speed: .fast), .enabled)
        XCTAssertEqual(SpeedCommandState.read(title: "Ultrafast The fastest available responses for latency-sensitive work", speed: .ultrafast), .disabled)
        XCTAssertEqual(SpeedCommandState.read(title: "Ultrafast Turn off Ultrafast and return to standard speed", speed: .ultrafast), .enabled)
        XCTAssertNil(SpeedCommandState.read(title: "Standard Default speed", speed: .standard))
    }

    func testOtherControlsCannotSupplyACommandState() {
        for title in ["Fast", "Speed Fast", "Fast model", "Fast nanx speed, increased usage", "Fast -1x speed, increased usage",
                      "Chat about Fast Turn off Fast and return to standard speed", "Fast Turn off Ultrafast and return to standard speed",
                      "Fast Turn off Fast and return to standard speed extra"] {
            XCTAssertNil(SpeedCommandState.read(title: title, speed: .fast), title)
        }
    }

    func testLiveUltrafastDescriptionWithFinalPeriodIsRecognized() {
        for prefix in ["Ultrafast", "/ultrafast"] {
            XCTAssertEqual(SpeedCommandState.read(
                title: "\(prefix) The fastest available responses for latency-sensitive work.",
                speed: .ultrafast), .disabled)
        }
    }

    func testUltrafastStillRequiresTheWholeCommandDescription() {
        for title in ["Ultrafast", "Ultrafast model", "Ultrafast The fastest available responses for latency-sensitive work. extra",
                      "Ultrafast The fastest available responses for latency-sensitive work..",
                      "Ultrafast Turn off Fast and return to standard speed"] {
            XCTAssertNil(SpeedCommandState.read(title: title, speed: .ultrafast), title)
        }
    }

    func testOnlyFastAndUltrafastHaveSlashCommands() {
        XCTAssertNil(ResponseSpeed.standard.command)
        XCTAssertEqual(ResponseSpeed.fast.command, "/fast")
        XCTAssertEqual(ResponseSpeed.ultrafast.command, "/ultrafast")
    }

    func testCatalogueSpeedTiersMapOnlyFasterTiers() {
        XCTAssertEqual(["fast", "ultrafast", "standard", "priority", "Fast", ""].compactMap(ResponseSpeed.init(speedTier:)),
                       [.fast, .ultrafast])
    }

    func testMissingModelButtonIconAlwaysMeansStandard() {
        var memory = ResponseSpeedMemory()
        for remembered in [nil, ResponseSpeed.standard, .fast, .ultrafast] {
            memory.speed = remembered
            for offered in [[], [ResponseSpeed.fast], [.fast, .ultrafast]] {
                XCTAssertEqual(memory.displayedSpeed(iconVisible: false, offered: offered, saved: remembered), .standard)
            }
        }
    }

    func testIconOnASingleTierModelIsThatTierWhateverTheBarRemembers() {
        var memory = ResponseSpeedMemory()
        for remembered in [nil, ResponseSpeed.standard, .fast, .ultrafast] {
            memory.speed = remembered
            XCTAssertEqual(memory.displayedSpeed(iconVisible: true, offered: [.fast], saved: .ultrafast), .fast) // GPT-6.1 Terra, Luna and older models offer only Fast.
        }
    }

    func testIconOnADualTierModelUsesTheBarsLastTierOrTheUltrafastAssumption() {
        var memory = ResponseSpeedMemory()
        let both: [ResponseSpeed] = [.fast, .ultrafast]
        XCTAssertEqual(memory.displayedSpeed(iconVisible: true, offered: both, saved: nil), .ultrafast)
        memory.speed = .fast
        XCTAssertEqual(memory.displayedSpeed(iconVisible: true, offered: both, saved: nil), .fast)
        XCTAssertEqual(memory.displayedSpeed(iconVisible: true, offered: [], saved: nil), .fast) // A catalogue saved before tiers were parsed.
        memory.speed = .standard
        XCTAssertEqual(memory.displayedSpeed(iconVisible: true, offered: both, saved: nil), .ultrafast) // The bar turned a tier off but Codex shows one on.
    }

    func testCodexsSavedChoiceOutranksTheBarsMemory() {
        var memory = ResponseSpeedMemory()
        let both: [ResponseSpeed] = [.fast, .ultrafast]
        memory.speed = .fast
        XCTAssertEqual(memory.displayedSpeed(iconVisible: true, offered: both, saved: .ultrafast), .ultrafast) // 2026-11-03: `/ultrafast` typed in Codex showed as Fast.
        memory.speed = .ultrafast
        XCTAssertEqual(memory.displayedSpeed(iconVisible: true, offered: both, saved: .fast), .fast)
        XCTAssertEqual(memory.displayedSpeed(iconVisible: true, offered: both, saved: .standard), .ultrafast) // Another chat turned speed off; this chat's icon still shows a tier.
        XCTAssertEqual(memory.displayedSpeed(iconVisible: false, offered: both, saved: .ultrafast), .standard)
    }

    func testCodexConfigServiceTierReadsOnlyTheTopLevelKey() {
        XCTAssertEqual(ResponseSpeed(codexConfig: "model = \"gpt-6.1-sol\"\nservice_tier = \"ultrafast\"\n\n[notice]\n"), .ultrafast)
        XCTAssertEqual(ResponseSpeed(codexConfig: "service_tier = \"priority\" # Fast\n"), .fast)
        XCTAssertEqual(ResponseSpeed(codexConfig: "  service_tier='default'"), .standard)
        XCTAssertNil(ResponseSpeed(codexConfig: "model = \"gpt-6.1-sol\"\n[profiles.work]\nservice_tier = \"ultrafast\"\n"))
        XCTAssertNil(ResponseSpeed(codexConfig: "service_tier_hint = \"ultrafast\"\nservice_tier = \"flex\"\n"))
        XCTAssertNil(ResponseSpeed(codexConfig: ""))
    }

}

final class NativeSpeedPlanTests: XCTestCase {
    func testEveryToggleAcrossBothTiersReachesTheExistingTarget() throws {
        for offered in [[ResponseSpeed.fast], [.ultrafast], [.fast, .ultrafast], [.ultrafast, .fast]] {
            let cycle = [ResponseSpeed.standard] + offered
            for current in cycle {
                for requested in cycle {
                    let plan = try XCTUnwrap(NativeSpeedPlan(requested: requested, current: current, offered: offered))
                    let target: ResponseSpeed = requested == .standard || requested == current ? .standard : requested
                    XCTAssertEqual(plan.target, target)
                    XCTAssertEqual(cycle[(cycle.firstIndex(of: current)! + plan.presses) % cycle.count], target)
                    XCTAssertTrue((0...2).contains(plan.presses))
                }
            }
        }
    }
    func testPartialPlansRecordEachPostedNativeStep() {
        XCTAssertEqual(NativeSpeedPlan(requested: .ultrafast, current: .standard,
                                       offered: [.fast, .ultrafast])?.steps, [.fast, .ultrafast])
        XCTAssertEqual(NativeSpeedPlan(requested: .fast, current: .fast,
                                       offered: [.fast, .ultrafast])?.steps, [.ultrafast, .standard])
    }
    func testUnsupportedTiersCannotBecomeAnotherSpeedAndMissingCurrentFollowsNativeFirstStep() {
        XCTAssertNil(NativeSpeedPlan(requested: .ultrafast, current: .standard, offered: [.fast]))
        XCTAssertEqual(NativeSpeedPlan(requested: .fast, current: .ultrafast, offered: [.fast])?.presses, 2)
        XCTAssertEqual(NativeSpeedPlan(requested: .standard, current: .ultrafast, offered: [])?.presses, 1)
        XCTAssertEqual(NativeSpeedPlan(requested: .standard, current: .standard, offered: [])?.presses, 0)
    }
}
