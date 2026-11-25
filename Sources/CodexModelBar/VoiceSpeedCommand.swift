import ApplicationServices
import AppKit
import CoreFoundation
import CodexModelBarCore
import os

/// H Chat submits this after the exact new Voice chat has opened. The bar applies
/// the selection; H Chat's existing transaction owns any default restoration. — GPT-6.2 Sol
struct VoiceSpeedRequest: Decodable {
    let requestId: UUID
    let callToken: String
    let expiresAtMs: Int64
    let speed: String
    let chatTitle: String
    let verifyOnly: Bool?

    struct Call: Equatable {
        let thread: UUID
        let session: UUID
        let pid: pid_t

        init?(_ token: String) {
            let fields = token.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count == 3, let thread = UUID(uuidString: String(fields[0])),
                  let session = UUID(uuidString: String(fields[1])),
                  let pid = pid_t(fields[2]), pid > 0 else { return nil }
            self.thread = thread
            self.session = session
            self.pid = pid
        }
    }

    var remaining: TimeInterval { Double(expiresAtMs) / 1_000 - Date().timeIntervalSince1970 }

    var requestedSpeed: ResponseSpeed? {
        ResponseSpeed.allCases.first { $0.rawValue.lowercased() == speed }
    }

    var isCurrent: Bool {
        let time = remaining
        return time > 0 && time <= 30 && requestedSpeed != nil && Call(callToken) != nil
            && !chatTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && chatTitle.utf8.count <= 1_024
    }
}

struct VoiceSpeedReceipt: Encodable {
    enum Result: String, Encodable { case applied, alreadySelected = "already-selected", refused }

    let requestId: UUID
    let callToken: String
    let expiresAtMs: Int64
    let result: Result
    let selectedSpeed: String?
    let displaySpeed: String?
    let model: String?
    let reasoning: String?
    let reason: String?

    init(_ request: VoiceSpeedRequest, result: Result = .refused, selected: CurrentSelection? = nil,
         displaySpeed: ResponseSpeed? = nil, reason: String? = nil) {
        requestId = request.requestId
        callToken = request.callToken
        expiresAtMs = request.expiresAtMs
        self.result = result
        selectedSpeed = selected == nil ? nil : request.requestedSpeed?.rawValue.lowercased()
        self.displaySpeed = displaySpeed?.rawValue.lowercased()
        model = selected?.modelID
        reasoning = selected?.effort
        self.reason = reason
    }
}

/// Local, versioned request/reply relay to the bar that owns its live window state. — GPT-6.2 Sol
final class VoiceSpeedCommand {
    typealias Handler = (VoiceSpeedRequest, @escaping (VoiceSpeedReceipt) -> Void) -> Void
    static let argument = "--voice-speed-v1"
    private static let portName = "com.ethansk.codex-model-bar.voice-speed-v1.\(getuid())"
    private static let byteLimit = 4_096
    private let name: String
    private let handler: Handler
    private var port: CFMessagePort?
    private var accepted: [UUID: Int64] = [:] // Accessed only on the port's serial queue.

    init(name: String? = nil, handler: @escaping Handler) {
        self.name = name ?? Self.portName
        self.handler = handler
    }

    func start() {
        var context = CFMessagePortContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        port = CFMessagePortCreateLocal(nil, name as CFString, { _, _, bytes, info in
            guard let info, let bytes,
                  let result = Unmanaged<VoiceSpeedCommand>.fromOpaque(info).takeUnretainedValue().receive(bytes as Data)
            else { return nil }
            return Unmanaged.passRetained(result as CFData)
        }, &context, nil)
        if let port { CFMessagePortSetDispatchQueue(port, DispatchQueue(label: name)) }
        else { Log.info("voice-speed relay unavailable") }
    }

    deinit { if let port { CFMessagePortInvalidate(port) } }

    static func runClient() -> Int32 {
        let input = FileHandle.standardInput
        var bytes = Data()
        while bytes.count <= byteLimit {
            let part = input.readData(ofLength: byteLimit + 1 - bytes.count)
            if part.isEmpty { break }
            bytes.append(part)
        }
        guard let request = decode(bytes) else { return 2 }
        func refuse(_ why: String) -> Int32 {
            if let reply = try? JSONEncoder().encode(VoiceSpeedReceipt(request, reason: why)) {
                FileHandle.standardOutput.write(reply + Data([10]))
            }
            return 1
        }
        guard request.isCurrent else { return refuse("invalid-or-expired") }
        guard let data = forward(bytes, remaining: request.remaining) else { return refuse("bar-or-completion-unavailable") }
        FileHandle.standardOutput.write(data + Data([10]))
        return 0
    }

    static func forward(_ data: Data, remaining: TimeInterval, name: String? = nil) -> Data? {
        guard remaining > 0, remaining <= 30,
              let remote = CFMessagePortCreateRemote(nil, (name ?? portName) as CFString) else { return nil }
        var response: Unmanaged<CFData>?
        let sent = CFMessagePortSendRequest(remote, 1, data as CFData, 0.5, remaining + 0.25,
                                           RunLoop.Mode.default.rawValue as CFString, &response)
        guard sent == kCFMessagePortSuccess, let reply = response?.takeRetainedValue() else { return nil }
        return reply as Data
    }

    private static func decode(_ data: Data) -> VoiceSpeedRequest? {
        guard data.count <= byteLimit else { return nil }
        return try? JSONDecoder().decode(VoiceSpeedRequest.self, from: data)
    }

    private func receive(_ data: Data) -> Data? {
        guard let request = Self.decode(data) else { return nil }
        let encoder = JSONEncoder()
        guard request.isCurrent else { return try? encoder.encode(VoiceSpeedReceipt(request, reason: "invalid-or-expired")) }
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        accepted = accepted.filter { $0.value > now }
        guard accepted[request.requestId] == nil, accepted.count < 32 else {
            return try? encoder.encode(VoiceSpeedReceipt(request, reason: "duplicate-or-busy"))
        }
        accepted[request.requestId] = request.expiresAtMs
        let completion = DispatchSemaphore(value: 0)
        let receipt = OSAllocatedUnfairLock<VoiceSpeedReceipt?>(initialState: nil)
        DispatchQueue.main.async { [handler] in
            handler(request) { result in
                receipt.withLock { $0 = result }
                completion.signal()
            }
        }
        _ = completion.wait(timeout: .now() + max(0, request.remaining))
        let result = receipt.withLock { $0 } ?? VoiceSpeedReceipt(request, reason: "completion-unconfirmed")
        Log.info("voice-speed request=\(request.requestId) result=\(result.result.rawValue) reason=\(result.reason ?? "none")")
        return try? encoder.encode(result)
    }
}

enum HChatVoiceIdentity {
    /// Call H Chat's public read-only command without depending on its private mailbox. — GPT-6.2 Sol
    static func matches(_ request: VoiceSpeedRequest) -> Bool {
        guard request.isCurrent, let expected = VoiceSpeedRequest.Call(request.callToken),
              let bundle = Bundle(url: HChatShowVoice.installedApp),
              bundle.bundleIdentifier == "com.ethansk.HeyChat", let executable = bundle.executableURL else { return false }
        let id = UUID()
        let envelope: [String: Any] = [
            "version": 1, "id": id.uuidString, "expiresAt": Date().timeIntervalSince1970 + 5,
            "operation": "voice.identity", "arguments": [:]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope) else { return false }
        let process = Process(), input = Pipe(), output = Pipe()
        let completion = DispatchSemaphore(value: 0)
        process.executableURL = executable
        process.arguments = ["--agent-control-v1"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in completion.signal() }
        do {
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: data)
            try input.fileHandleForWriting.close()
        } catch {
            if process.isRunning { process.terminate() }
            return false
        }
        guard completion.wait(timeout: .now() + min(2, max(0, request.remaining))) == .success else {
            if process.isRunning { process.terminate() }
            return false
        }
        guard process.terminationStatus == 0,
              let bytes = try? output.fileHandleForReading.read(upToCount: 4_096),
              let reply = try? JSONDecoder().decode(IdentityReceipt.self, from: bytes),
              reply.version == 1, reply.id == id, reply.state == "confirmed", reply.result.status == "active",
              let token = reply.result.call, VoiceSpeedRequest.Call(token) == expected else { return false }
        return request.isCurrent
    }

    struct IdentityReceipt: Decodable {
        struct Identity: Decodable { let status: String; let call: String? }
        let version: Int
        let id: UUID
        let state: String
        let result: Identity
    }
}
