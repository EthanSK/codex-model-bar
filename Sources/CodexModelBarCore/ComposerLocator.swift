import Foundation

/// Resolves a model control and input as one composer. Focus wins over remembered
/// input; an ambiguous multi-composer window never falls back to its first input.
public struct ComposerLocator<Node> {
    public struct Located {
        public let modelButton: Node
        public let composer: Node
        public let container: Node
        /// Live ancestors shared by this input and its model control, containing
        /// no other input. A surviving ancestor can identify a replacement input.
        public var scopeAncestors: [Node] = []
    }

    private let children: (Node) -> [Node]
    private let parent: (Node) -> Node?
    private let isTextArea: (Node) -> Bool
    private let isModelButton: (Node) -> Bool
    private let equals: (Node, Node) -> Bool
    private let diagnostic: (String) -> Void
    private let hasKeyboardFocus: (Node) -> Bool
    private let isWebArea: (Node) -> Bool
    private let isConversationRegion: (Node) -> Bool
    private let isInterrupted: () -> Bool

    public init(children: @escaping (Node) -> [Node], parent: @escaping (Node) -> Node?,
                isTextArea: @escaping (Node) -> Bool, isModelButton: @escaping (Node) -> Bool,
                equals: @escaping (Node, Node) -> Bool, hasKeyboardFocus: @escaping (Node) -> Bool = { _ in false },
                isWebArea: @escaping (Node) -> Bool = { _ in false },
                isConversationRegion: @escaping (Node) -> Bool = { _ in false },
                isInterrupted: @escaping () -> Bool = { false },
                diagnostic: @escaping (String) -> Void = { _ in }) {
        self.children = children
        self.parent = parent
        self.isTextArea = isTextArea
        self.isModelButton = isModelButton
        self.equals = equals
        self.diagnostic = diagnostic
        self.hasKeyboardFocus = hasKeyboardFocus
        self.isWebArea = isWebArea
        self.isConversationRegion = isConversationRegion
        self.isInterrupted = isInterrupted
    }

    public func locate(in root: Node, focused: Node?, previousComposer: Node?) -> Located? {
        // Discover controls from the live window. Chromium's AXParent and
        // AXChildren are not necessarily reciprocal across flattened web groups.
        // Requiring that reciprocity rejects a valid focused side composer.
        let scan = matching(in: root, limit: 30_000, maxMatches: Int.max, capturePaths: true) {
            isModelButton($0) || isTextArea($0)
        }
        let buttons = scan.nodes.filter(isModelButton)
        let inputs = scan.nodes.filter(isTextArea)
        let candidates = buttons.compactMap { pair($0, in: root) }
        func scoped(_ candidate: Located) -> Located {
            var result = candidate
            guard scan.complete,
                  let inputIndex = scan.nodes.firstIndex(where: { equals($0, candidate.composer) }),
                  let buttonIndex = scan.nodes.firstIndex(where: { equals($0, candidate.modelButton) })
            else { return result }
            let otherInputPaths = scan.nodes.indices.filter { index in
                inputs.contains(where: { equals($0, scan.nodes[index]) }) && !equals(scan.nodes[index], candidate.composer)
            }.map { scan.paths[$0] }
            result.scopeAncestors = scan.paths[inputIndex].reversed().filter { ancestor in
                !equals(ancestor, root)
                    && scan.paths[buttonIndex].contains(where: { equals($0, ancestor) })
                    && !otherInputPaths.contains(where: { path in path.contains(where: { equals($0, ancestor) }) })
            }
            return result
        }
        diagnostic("window-scan nodes=\(scan.visited) models=\(buttons.count) inputs=\(inputs.count) paired=\(candidates.count) complete=\(scan.complete)")
        let focusedInput = focused.map(isTextArea) ?? false
        if let focused, let active = candidates.first(where: {
            focusedInput ? equals(focused, $0.composer) : isWithin(focused, root: $0.container)
        }) {
            diagnostic("selected=focused-scan")
            return scoped(active)
        }
        if focusedInput { diagnostic("rejected=unpaired-focused-input"); return nil }
        if let focused, !equals(focused, root) { // The click-to-focus helper measures a focused Conversation region above its composer; AXParent can omit that region (task 01a0d315-7d5e-7be0-bc08-80626ca0729b).
            let focusedInputs = scan.nodes.indices.filter { index in
                isTextArea(scan.nodes[index]) && scan.paths[index].contains(where: { equals($0, focused) })
            }
            if !focusedInputs.isEmpty || isConversationRegion(focused) { // A recognised Conversation may be empty while loading; it still identifies the clicked pane and must not borrow another chat's input.
                guard scan.complete, focusedInputs.count == 1,
                      let active = candidates.first(where: { candidate in
                          equals(candidate.composer, scan.nodes[focusedInputs[0]])
                              && scan.nodes.indices.contains(where: { index in
                                  equals(scan.nodes[index], candidate.modelButton)
                                      && scan.paths[index].contains(where: { equals($0, focused) })
                              })
                      }) else {
                    diagnostic("rejected=focused-region-ambiguous-or-loading")
                    return nil // A clicked pane with a missing or ambiguous composer must not send the action to the remembered other chat.
                }
                diagnostic("selected=focused-region")
                return scoped(active)
            }
        }
        let flagged = inputs.filter(hasKeyboardFocus)
        if flagged.count == 1 {
            guard let selected = candidates.first(where: { equals($0.composer, flagged[0]) }) else {
                diagnostic("rejected=unpaired-focused-flag")
                return nil
            }
            diagnostic("selected=focused-flag")
            return scoped(selected)
        }
        if flagged.count > 1 { diagnostic("rejected=multiple-focus-flags"); return nil }
        // Preserve input identity across a native picker, but only if the current
        // window scan still contains that same paired composer.
        if let previousComposer, let previous = candidates.first(where: { equals($0.composer, previousComposer) }) {
            diagnostic("selected=previous-live-composer")
            return scoped(previous)
        }
        diagnostic(scan.complete && candidates.count == 1 ? "selected=sole-composer" : "rejected=ambiguous-or-missing")
        return scan.complete && candidates.count == 1 ? scoped(candidates[0]) : nil
    }

    /// Accepts the exact focused input through a reciprocal path, without reading the chat transcript.
    public func focusedInput(in root: Node, focused: Node?) -> Node? {
        guard let focused, isTextArea(focused) else { return nil }
        var node = focused
        var foundConversation = false
        var webAreas = 0
        for _ in 0..<40 {
            if equals(node, root) { return foundConversation ? focused : nil }
            foundConversation = foundConversation || isConversationRegion(node)
            if isWebArea(node) { webAreas += 1 }
            guard webAreas <= 1, let ancestor = parent(node), !equals(ancestor, node) else { return nil }
            let siblings = children(ancestor)
            guard let index = siblings.firstIndex(where: { equals($0, node) }) else { return nil } // Chromium sometimes omits or flattens parents; only a complete reciprocal path can skip the existing child-tree lookup (task 01a0d315-7d5e-7be0-bc08-80626ca0729b).
            if !foundConversation, siblings[(index + 1)...].contains(where: { sibling in
                let later = matching(in: sibling, limit: 400, maxMatches: 1, insideWebArea: true, predicate: isTextArea)
                return !later.complete || !later.nodes.isEmpty
            }) { return nil } // An input with another input after it is a question card's answer box above the composer; posting /fast + Return there would submit it as the answer (2026-10-27 live Codex tree).
            node = ancestor
        }
        return nil
    }

    /// Returns the remembered composer when focus sits on the whole page and no Conversation surrounds that composer.
    /// Switching back from another app leaves Codex focus on its page; without a Conversation landmark the pane route cannot use the remembered input (2026-10-27 22:15:42 UTC).
    public func regionlessInput(_ input: Node, in root: Node, focused: Node) -> Node? {
        guard isWebArea(focused) || equals(focused, root) else { return nil } // A focused group or region identifies a pane; only page-level focus may reuse the remembered input, so a click on another pane is never redirected.
        var node = input
        var withinFocused = false
        for _ in 0..<40 {
            withinFocused = withinFocused || equals(node, focused)
            if equals(node, root) { return withinFocused ? input : nil }
            guard !isConversationRegion(node), let ancestor = parent(node), !equals(ancestor, node),
                  children(ancestor).contains(where: { equals($0, node) }) else { return nil } // With a Conversation the existing pane route already uses the remembered input; a detached input fails the reciprocal path.
            node = ancestor
        }
        return nil
    }

    /// Pins speed actions to a live Conversation, even before its model control or input mounts.
    public func conversation(in root: Node, focused: Node?, previousComposer: Node?) -> Node? {
        let scan = matching(in: root, limit: 30_000, maxMatches: Int.max, capturePaths: true) { node in
            isTextArea(node) || focused.map { equals(node, $0) } == true
        }
        guard scan.complete else { return nil }
        func region(at index: Int) -> Node? {
            guard let region = (scan.paths[index] + [scan.nodes[index]]).reversed().first(where: isConversationRegion) else { return nil }
            let inputs = scan.nodes.indices.filter { candidate in
                isTextArea(scan.nodes[candidate]) && scan.paths[candidate].contains(where: { equals($0, region) })
            }
            guard inputs.allSatisfy({ input in
                scan.paths[input].reversed().first(where: isConversationRegion).map { equals($0, region) } == true
            }) else { return nil } // A shared outer region cannot choose between or borrow its child chats. Several inputs of one chat are allowed: a pending question card adds an answer box above the composer (2026-10-27 "No task composer").
            return region
        }
        if let focused, let index = scan.nodes.firstIndex(where: { equals($0, focused) }) {
            if let region = region(at: index) { return region }
            if isTextArea(focused) || isConversationRegion(focused) { return nil } // A foreign input or ambiguous clicked pane must not borrow the previous chat.
        } else if let focused, isTextArea(focused) || isConversationRegion(focused) {
            return nil // A detached input or embedded browser cannot supply the target pane.
        }
        let flagged = scan.nodes.indices.filter { isTextArea(scan.nodes[$0]) && hasKeyboardFocus(scan.nodes[$0]) }
        if flagged.count == 1 { return region(at: flagged[0]) }
        guard flagged.isEmpty, let previousComposer,
              let index = scan.nodes.firstIndex(where: { equals($0, previousComposer) }) else { return nil }
        return region(at: index) // Preserve only the exact still-attached input when a native picker temporarily owns focus.
    }

    /// Reads only the captured pane and returns its composer, the pane's last input; no model metadata or other-pane fallback is involved.
    public func input(inConversation region: Node) -> Node? {
        guard isConversationRegion(region) else { return nil }
        let scan = matching(in: region, limit: 30_000, maxMatches: Int.max, capturePaths: true, insideWebArea: true, predicate: isTextArea)
        guard scan.complete,
              !scan.paths.contains(where: { path in path.contains(where: { !equals($0, region) && isConversationRegion($0) }) }) else { return nil } // Every web area or nested Conversation inside the captured pane belongs to a different surface.
        return scan.nodes.last // Codex draws question/form answer boxes above the composer, so the last input is the chat's own; Agent Flow's pane_focuser.py also searches last-child first.
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

    private func matching(in root: Node, limit: Int, maxMatches: Int, capturePaths: Bool = false, insideWebArea: Bool = false,
                          predicate: (Node) -> Bool) -> (nodes: [Node], paths: [[Node]], complete: Bool, visited: Int) {
        var stack: [(node: Node, path: [Node], insideWebArea: Bool)] = [(root, [], insideWebArea)]
        var result: [Node] = []
        var paths: [[Node]] = []
        var visited = 0
        while let (node, path, insideWebArea) = stack.popLast() {
            visited += 1
            guard visited <= limit, visited % 32 != 0 || !isInterrupted() else { return (result, paths, false, visited - 1) } // An interrupted walk reports itself incomplete, like the node-limit stop; checking every 32 nodes keeps the lock reads negligible.
            let webArea = isWebArea(node)
            if webArea && insideWebArea { continue } // Embedded browser pages cannot own the Codex composer; do not traverse their potentially huge or misleading control trees.
            if predicate(node) {
                result.append(node)
                paths.append(path)
                if result.count >= maxMatches { return (result, paths, false, visited) }
            }
            let nextPath = capturePaths ? path + [node] : []
            stack.append(contentsOf: children(node).reversed().map { ($0, nextPath, insideWebArea || webArea) })
        }
        return (result, paths, true, visited)
    }
}
