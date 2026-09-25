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

    public init(children: @escaping (Node) -> [Node], parent: @escaping (Node) -> Node?,
                isTextArea: @escaping (Node) -> Bool, isModelButton: @escaping (Node) -> Bool,
                equals: @escaping (Node, Node) -> Bool) {
        self.children = children
        self.parent = parent
        self.isTextArea = isTextArea
        self.isModelButton = isModelButton
        self.equals = equals
    }

    public func locate(in root: Node, focused: Node?, previousComposer: Node?) -> Located? {
        if let focused, isWithin(focused, root: root), let found = near(focused) { return found }
        // An unrecognised focused text area might be a different task whose model
        // is still loading. Never redirect its action to a remembered input.
        if let focused, isTextArea(focused) { return nil }
        // A native picker or a transcript click can temporarily own focus. Keep
        // the last input only if it still belongs to this window, and re-find its button.
        if let previousComposer, isWithin(previousComposer, root: root),
           let found = near(previousComposer) { return found }

        let scan = matching(in: root, limit: 30_000, maxMatches: Int.max, predicate: isModelButton)
        let candidates = scan.nodes.compactMap(pair)
        if let focused, let active = candidates.first(where: { isWithin(focused, root: $0.container) }) {
            return active
        }
        return scan.complete && candidates.count == 1 ? candidates[0] : nil
    }

    private func near(_ focused: Node) -> Located? {
        var ancestor = focused
        for _ in 0..<6 {
            let scan = matching(in: ancestor, limit: 200, maxMatches: 2, predicate: isModelButton)
            if scan.nodes.count > 1 { return nil }
            if scan.complete, let button = scan.nodes.first, let found = pair(button),
               isWithin(focused, root: found.container) { return found }
            guard let next = parent(ancestor), !equals(next, ancestor) else { return nil }
            ancestor = next
        }
        return nil
    }

    private func pair(_ button: Node) -> Located? {
        var ancestor = button
        for _ in 0..<6 {
            guard let next = parent(ancestor), !equals(next, ancestor) else { return nil }
            ancestor = next
            let scan = matching(in: ancestor, limit: 400, maxMatches: 2, predicate: isTextArea)
            if scan.nodes.count > 1 { return nil }
            if scan.complete, let input = scan.nodes.first {
                return Located(modelButton: button, composer: input, container: ancestor)
            }
        }
        return nil
    }

    private func isWithin(_ node: Node, root: Node) -> Bool {
        var current = node
        for _ in 0..<40 {
            if equals(current, root) { return true }
            guard let next = parent(current), !equals(next, current),
                  children(next).contains(where: { equals($0, current) }) else { return false }
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
