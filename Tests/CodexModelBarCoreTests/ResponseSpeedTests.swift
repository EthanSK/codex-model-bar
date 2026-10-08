import XCTest
@testable import CodexModelBarCore

final class ResponseSpeedTests: XCTestCase {
    func testNativeSpeedChoicesAndCurrentTier() {
        XCTAssertEqual(ResponseSpeed.controlValue(title: "Speed Standard"), .standard)
        XCTAssertEqual(ResponseSpeed.controlValue(title: "Speed Fast"), .fast)
        XCTAssertEqual(ResponseSpeed.controlValue(title: "Speed Ultrafast"), .ultrafast)
        XCTAssertEqual(ResponseSpeed.menuValue(title: "Standard Default speed"), .standard)
        XCTAssertEqual(ResponseSpeed.menuValue(title: "Fast 1.5x speed, more usage"), .fast)
        XCTAssertEqual(ResponseSpeed.menuValue(title: "Fast 2x speed, more usage"), .fast)
        XCTAssertEqual(ResponseSpeed.menuValue(title: "Ultrafast The fastest available responses for latency-sensitive work"), .ultrafast)
        for speed in ResponseSpeed.allCases {
            XCTAssertEqual(ResponseSpeed.menuValue(title: speed.rawValue), speed)
        }
    }

    func testOtherControlsAndToggleCommandsCannotSelectASpeed() {
        for title in ["GPT-6 Astra High Ultrafast", "Fast model", "Standard project",
                      "Ultrafast Turn off Ultrafast and return to Standard speed", "/fast", "Speed", "Speed Turbo",
                      "Fast nanx speed, more usage", "Fast -1x speed, more usage"] {
            XCTAssertNil(ResponseSpeed.controlValue(title: title), title)
            XCTAssertNil(ResponseSpeed.menuValue(title: title), title)
        }
    }
}
