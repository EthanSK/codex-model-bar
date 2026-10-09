import XCTest
@testable import CodexModelBarCore

final class ResponseSpeedTests: XCTestCase {
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
}
