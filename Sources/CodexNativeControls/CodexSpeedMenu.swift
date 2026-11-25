import ApplicationServices
import CodexModelBarCore
import Foundation

/// An explicit tier selection through Codex's native model pop-up. Reading the
/// selected Speed row does not type into the composer or run a command. — GPT-6.2 Sol
public enum CodexSpeedMenu {
    public enum Result: Equatable {
        case applied
        case alreadySelected
        case refused(String)
    }

    public static func select(_ speed: ResponseSpeed, in window: AXUIElement, trigger: @escaping () -> AXUIElement?,
                              readOnly: Bool, ownsComposer: @escaping () -> Bool,
                              maySelect: @escaping () -> Bool, stillCurrent: @escaping () -> Bool) -> Result {
        let menu = Menu<AXUIElement>(
            items: { items(in: window).map { $0.map { (CodexAX.title($0), $0) } } },
            press: { CodexAX.press($0) }, trigger: trigger,
            ownsComposer: ownsComposer, maySelect: maySelect, stillCurrent: stillCurrent
        )
        return run(menu, speed: speed, readOnly: readOnly)
    }

    struct Menu<Item> {
        let items: () -> [(title: String, item: Item)]?
        let press: (Item) -> Bool
        let trigger: () -> Item?
        let ownsComposer: () -> Bool
        let maySelect: () -> Bool
        let stillCurrent: () -> Bool
    }

    static func run<Item>(_ menu: Menu<Item>, speed: ResponseSpeed, readOnly: Bool) -> Result {
        guard menu.stillCurrent(), menu.ownsComposer(), menu.items()?.isEmpty == true,
              let trigger = menu.trigger(), menu.press(trigger) else { return .refused("speed-menu-unavailable") }

        let result = choose(speed, in: menu, readOnly: readOnly)
        // Closing a menu we opened is allowed on expiry only while we still own
        // the same composer and no physical input has intervened. — GPT-6.2 Sol
        guard menu.ownsComposer(), let remaining = menu.items() else { return .refused("speed-menu-cleanup-unconfirmed") }
        if !remaining.isEmpty {
            guard let trigger = menu.trigger(), menu.press(trigger),
                  wait(menu, allowsExpiry: true, for: { menu.items()?.isEmpty == true ? true : nil }) == true
            else { return .refused("speed-menu-cleanup-unconfirmed") }
        }
        return result
    }

    private static func choose<Item>(_ speed: ResponseSpeed, in menu: Menu<Item>, readOnly: Bool) -> Result {
        func tierRow() -> (tier: ResponseSpeed, item: Item)? {
            guard let entries = menu.items() else { return nil }
            let tiers = entries.compactMap { entry in
                ResponseSpeed.allCases.first(where: { entry.title == "Speed " + $0.rawValue })
                    .map { (tier: $0, item: entry.item) }
            }
            return tiers.count == 1 ? tiers.first : nil
        }
        guard let row = wait(menu, for: tierRow) else { return .refused("speed-selection-unreadable") }
        if row.tier == speed { return .alreadySelected }
        let requested = speed.rawValue.lowercased()
        if readOnly { return .refused("\(requested)-not-selected") }
        guard menu.stillCurrent(), menu.ownsComposer(), menu.press(row.item),
              let option = wait(menu, for: { () -> Item? in
            let matches = menu.items()?.filter { $0.title == speed.rawValue || $0.title.hasPrefix(speed.rawValue + " ") }
            return matches?.count == 1 ? matches?.first?.item : nil
        }), menu.maySelect(), menu.stillCurrent(), menu.ownsComposer(), menu.press(option) else {
            return .refused("\(requested)-selection-refused")
        }

        var reopened = false
        let confirmed: Bool? = wait(menu) {
            if tierRow()?.tier == speed { return true }
            if !reopened, menu.items()?.isEmpty == true, let trigger = menu.trigger() {
                reopened = true
                _ = menu.press(trigger)
            }
            return nil
        }
        return confirmed == true ? .applied : .refused("\(requested)-selection-unconfirmed")
    }

    private static func wait<Item, Value>(_ menu: Menu<Item>, allowsExpiry: Bool = false,
                                          for read: () -> Value?) -> Value? {
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        repeat {
            guard (allowsExpiry || menu.stillCurrent()), menu.ownsComposer() else { return nil }
            if let value = read() { return value }
            Thread.sleep(forTimeInterval: 0.04)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return nil
    }

    private static func items(in window: AXUIElement) -> [AXUIElement]? {
        let ax = CodexAX.self
        var stack = [window], result: [AXUIElement] = [], visited = 0
        while let node = stack.popLast() {
            visited += 1
            guard visited <= 3_000 else { return nil }
            let role = ax.role(node)
            if role == kAXMenuItemRole as String {
                if !ax.title(node).isEmpty { result.append(node) }
                continue
            }
            if [kAXListRole, kAXOutlineRole, kAXStaticTextRole, kAXImageRole, kAXButtonRole, kAXPopUpButtonRole,
                kAXTextAreaRole].contains(role)
                || ["AXLandmarkNavigation", "AXLandmarkComplementary"].contains(ax.string(node, kAXSubroleAttribute)) {
                continue
            }
            stack.append(contentsOf: ax.children(node))
        }
        return result
    }
}
