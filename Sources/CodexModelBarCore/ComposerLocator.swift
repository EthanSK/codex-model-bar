import Foundation

/// Resolves a model control and input as one composer. Focus wins over remembered
/// input; an ambiguous multi-composer window never falls back to its first input.
public struct ComposerLocator<Node> {
    public struct Located {
        public let modelButton: Node
        public let composer: Node
        public let container: Node
    }

    private let children: (Node) -> [Node]
    private let parent: (Node) -> Node?
    private let isTextArea: (Node) -> Bool
    private let isModelButton: (Node) -> Bool
    private let equals: (Node, Node) -> Bool
    private let diagnostic: (String) -> Void
    private let hasKeyboardFocus: (Node) -> Bool

    public init(children: @escaping (Node) -> [Node], parent: @escaping (Node) -> Node?,
                isTextArea: @escaping (Node) -> Bool, isModelButton: @escaping (Node) -> Bool,
                equals: @escaping (Node, Node) -> Bool, hasKeyboardFocus: @escaping (Node) -> Bool = { _ in false },
                diagnostic: @escaping (String) -> Void = { _ in }) {
        self.children = children
        self.parent = parent
        self.isTextArea = isTextArea
        self.isModelButton = isModelButton
        self.equals = equals
        self.diagnostic = diagnostic
        self.hasKeyboardFocus = hasKeyboardFocus
    }

    public func locate(in root: Node, focused: Node?, previousComposer: Node?) -> Located? {
        // Discover controls from the live window. Chromium's AXParent and
        // AXChildren are not necessarily reciprocal across flattened web groups.
        // Requiring that reciprocity rejects a valid focused side composer.
        let scan = matching(in: root, limit: 30_000, maxMatches: Int.max) { isModelButton($0) || isTextArea($0) }
        let buttons = scan.nodes.filter(isModelButton)
        let inputs = scan.nodes.filter(isTextArea)
        let candidates = buttons.compactMap { pair($0, in: root) }
        diagnostic("window-scan models=\(buttons.count) inputs=\(inputs.count) paired=\(candidates.count) complete=\(scan.complete)")
        let focusedInput = focused.map(isTextArea) ?? false
        if let focused, let active = candidates.first(where: {
            focusedInput ? equals(focused, $0.composer) : isWithin(focused, root: $0.container)
        }) {
            diagnostic("selected=focused-scan")
            return active
        }
        if focusedInput { diagnostic("rejected=unpaired-focused-input"); return nil }
        let flagged = inputs.filter(hasKeyboardFocus)
        if flagged.count == 1 {
            guard let selected = candidates.first(where: { equals($0.composer, flagged[0]) }) else {
                diagnostic("rejected=unpaired-focused-flag")
                return nil
            }
            diagnostic("selected=focused-flag")
            return selected
        }
        if flagged.count > 1 { diagnostic("rejected=multiple-focus-flags"); return nil }
        // Preserve input identity across a native picker, but only if the current
        // window scan still contains that same paired composer.
        if let previousComposer, let previous = candidates.first(where: { equals($0.composer, previousComposer) }) {
            diagnostic("selected=previous-live-composer")
            return previous
        }
        diagnostic(scan.complete && candidates.count == 1 ? "selected=sole-composer" : "rejected=ambiguous-or-missing")
        return scan.complete && candidates.count == 1 ? candidates[0] : nil
    }

    private func pair(_ button: Node, in root: Node) -> Located? {
        var ancestor = button
        for _ in 0..<6 {
            guard let next = parent(ancestor), !equals(next, ancestor) else { return nil }
            ancestor = next
            let scan = matching(in: ancestor, limit: 400, maxMatches: 2, predicate: isTextArea)
            if scan.nodes.count > 1 { diagnostic("pair=multiple-inputs"); return nil }
            if scan.complete, let input = scan.nodes.first {
                return Located(modelButton: button, composer: input, container: ancestor)
            }
            if equals(ancestor, root) { break }
        }
        diagnostic("pair=no-input-within-depth-or-budget")
        return nil
    }

    private func isWithin(_ node: Node, root: Node) -> Bool {
        var current = node
        for _ in 0..<40 {
            if equals(current, root) { return true }
            guard let next = parent(current), !equals(next, current) else {
                diagnostic("path=missing-parent")
                return false
            }
            current = next
        }
        return false
    }

    private func matching(in root: Node, limit: Int, maxMatches: Int,
                          predicate: (Node) -> Bool) -> (nodes: [Node], complete: Bool) {
        var stack = [root]
        var result: [Node] = []
        var visited = 0
        while let node = stack.popLast() {
            visited += 1
            guard visited <= limit else { return (result, false) }
            if predicate(node) {
                result.append(node)
                if result.count >= maxMatches { return (result, false) }
            }
            stack.append(contentsOf: children(node).reversed())
        }
        return (result, true)
    }
}
