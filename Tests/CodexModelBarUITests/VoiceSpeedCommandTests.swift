import CodexModelBarCore
import XCTest
@testable import CodexModelBar

final class VoiceSpeedCommandTests: XCTestCase {
    func testLocalRelayCorrelatesReplyAndNeverReplaysRequest() async throws {
        let name = "voice-speed-test.\(UUID())"
        let command = VoiceSpeedCommand(name: name) { request, reply in
            reply(VoiceSpeedReceipt(request, result: .applied,
                                   selected: CurrentSelection(modelID: "gpt-6.1-sol", effort: "xhigh"),
                                   displaySpeed: .ultrafast))
        }
        command.start()
        let id = UUID()
        let token = "\(UUID()):\(UUID()):108"
        let expires = Int64((Date().timeIntervalSince1970 + 15) * 1_000)
        let request = try JSONSerialization.data(withJSONObject: [
            "requestId": id.uuidString, "callToken": token, "expiresAtMs": expires,
            "speed": "ultrafast", "chatTitle": "A specific Voice chat"
        ])
        let returned = await Task.detached {
            let first = VoiceSpeedCommand.forward(request, remaining: 5, name: name)
            let second = VoiceSpeedCommand.forward(request, remaining: 5, name: name)
            return (first, second)
        }.value
        withExtendedLifetime(command) {}
        let first = try object(returned.0)
        XCTAssertEqual(first["requestId"] as? String, id.uuidString)
        XCTAssertEqual(first["callToken"] as? String, token)
        XCTAssertEqual(first["expiresAtMs"] as? Int64, expires)
        XCTAssertEqual(first["result"] as? String, "applied")
        XCTAssertEqual(first["selectedSpeed"] as? String, "ultrafast")
        XCTAssertEqual(first["displaySpeed"] as? String, "ultrafast")
        XCTAssertEqual(first["model"] as? String, "gpt-6.1-sol")
        XCTAssertEqual(first["reasoning"] as? String, "xhigh")
        let duplicate = try object(returned.1)
        XCTAssertEqual(duplicate["result"] as? String, "refused")
        XCTAssertEqual(duplicate["reason"] as? String, "duplicate-or-busy")
    }

    func testInvalidOrExpiredRequestsNeverReachThePicker() async throws {
        let name = "voice-speed-test.\(UUID())"
        let command = VoiceSpeedCommand(name: name) { request, reply in
            XCTFail("Invalid request reached the handler")
            reply(VoiceSpeedReceipt(request))
        }
        command.start()
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let token = "\(UUID()):\(UUID()):108"
        let data = try [
            (token, now - 1_000, "ultrafast"), (token, now + 90_000, "ultrafast"),
            (token, now + 15_000, "priority"), (token, now + 15_000, "default"),
            (token, now + 15_000, "Fast"), ("\(UUID()):\(UUID()):0", now + 15_000, "ultrafast")
        ].map { token, expiry, speed in
            try JSONSerialization.data(withJSONObject: [
                "requestId": UUID().uuidString, "callToken": token, "expiresAtMs": expiry,
                "speed": speed, "chatTitle": "A specific Voice chat"
            ])
        }
        let replies = await Task.detached {
            data.map { VoiceSpeedCommand.forward($0, remaining: 4, name: name) }
        }.value
        withExtendedLifetime(command) {}
        for response in replies {
            let receipt = try object(response)
            XCTAssertEqual(receipt["result"] as? String, "refused")
            XCTAssertEqual(receipt["reason"] as? String, "invalid-or-expired")
        }
    }

    func testVerificationIsASeparateReadOnlyRequest() async throws {
        let name = "voice-speed-test.\(UUID())"
        let command = VoiceSpeedCommand(name: name) { request, reply in
            XCTAssertEqual(request.verifyOnly, true)
            reply(VoiceSpeedReceipt(request, result: .alreadySelected,
                                    selected: CurrentSelection(modelID: "gpt-6.1-sol", effort: "high"),
                                    displaySpeed: .ultrafast))
        }
        command.start()
        let id = UUID()
        let request = try JSONSerialization.data(withJSONObject: [
            "requestId": id.uuidString, "callToken": "\(UUID()):\(UUID()):108",
            "expiresAtMs": Int64((Date().timeIntervalSince1970 + 15) * 1_000),
            "speed": "ultrafast", "chatTitle": "A specific Voice chat", "verifyOnly": true
        ])
        let response = await Task.detached { VoiceSpeedCommand.forward(request, remaining: 5, name: name) }.value
        withExtendedLifetime(command) {}
        let receipt = try object(response)
        XCTAssertEqual(receipt["requestId"] as? String, id.uuidString)
        XCTAssertEqual(receipt["result"] as? String, "already-selected")
    }

    func testGenericSpeedReceiptsEchoCanonicalSelectionAndIndicator() async throws {
        let name = "voice-speed-test.\(UUID())"
        let command = VoiceSpeedCommand(name: name) { request, reply in
            reply(VoiceSpeedReceipt(request, result: .alreadySelected,
                                    selected: CurrentSelection(modelID: "gpt-6.1-sol", effort: "high"),
                                    displaySpeed: request.requestedSpeed))
        }
        command.start()
        let speeds = ["standard", "fast", "ultrafast"]
        let requests = try speeds.map { speed in
            try JSONSerialization.data(withJSONObject: [
                "requestId": UUID().uuidString, "callToken": "\(UUID()):\(UUID()):108",
                "expiresAtMs": Int64((Date().timeIntervalSince1970 + 15) * 1_000),
                "speed": speed, "chatTitle": "A specific Voice chat", "verifyOnly": true
            ])
        }
        let responses = await Task.detached {
            requests.map { VoiceSpeedCommand.forward($0, remaining: 5, name: name) }
        }.value
        withExtendedLifetime(command) {}
        for (speed, data) in zip(speeds, responses) {
            let receipt = try object(data)
            XCTAssertEqual(receipt["selectedSpeed"] as? String, speed)
            XCTAssertEqual(receipt["displaySpeed"] as? String, speed)
            XCTAssertEqual(receipt["result"] as? String, "already-selected")
        }
    }

    private func object(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
    }
}
