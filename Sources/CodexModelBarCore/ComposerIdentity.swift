import Foundation

/// An input can be replaced while Codex applies a setting. Only a live ancestor
/// exclusive to its composer can connect the old and new inputs; a shared window
/// or the other task's matching model is never enough.
public struct ComposerIdentity<Node> {
    public let input: Node
    public let scopeAncestors: [Node]

    public init(input: Node, scopeAncestors: [Node]) {
        self.input = input
        self.scopeAncestors = scopeAncestors
    }

    public func matches(_ candidate: Self, equals: (Node, Node) -> Bool) -> Bool {
        equals(input, candidate.input) || scopeAncestors.contains { old in
            candidate.scopeAncestors.contains { equals(old, $0) }
        }
    }
}
