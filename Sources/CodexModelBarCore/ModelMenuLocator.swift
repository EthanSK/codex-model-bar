/// Finds model-search sections and their query input in the composer's own web area.
/// Codex 26.924 puts this menu in a portal, outside the composer's ancestors.
public struct ModelMenuLocator<Node> {
    public struct Menu {
        public var recent: [Node]
        public var matching: [Node]
        public var searchInput: Node?
    }

    public let children: (Node) -> [Node]
    public let isWebArea: (Node) -> Bool
    public let isButton: (Node) -> Bool
    public let header: (Node) -> String?
    public let isListBox: (Node) -> Bool
    public let isOption: (Node) -> Bool
    public let isSearchInput: (Node) -> Bool
    public let equals: (Node, Node) -> Bool

    public init(children: @escaping (Node) -> [Node], isWebArea: @escaping (Node) -> Bool,
                isButton: @escaping (Node) -> Bool, header: @escaping (Node) -> String?,
                equals: @escaping (Node, Node) -> Bool,
                isListBox: @escaping (Node) -> Bool = { _ in false },
                isOption: @escaping (Node) -> Bool = { _ in false },
                isSearchInput: @escaping (Node) -> Bool = { _ in false }) {
        self.children = children
        self.isWebArea = isWebArea
        self.isButton = isButton
        self.header = header
        self.equals = equals
        self.isListBox = isListBox
        self.isOption = isOption
        self.isSearchInput = isSearchInput
    }

    public func locate(in window: Node, composer: Node) -> Menu? {
        var stack: [(Node, [Node], Bool)] = [(window, [], false)]
        var composerPath: [Node]?
        var headers: [(String, [Node], Int)] = []
        var options: [(Node, [Node], Int)] = []
        var searchInputs: [(Node, [Node])] = []
        var count = 0
        while let (node, path, parentListBox) = stack.popLast() {
            count += 1
            guard count <= 30_000 else { return nil }
            if equals(node, composer) { composerPath = path }
            if let name = header(node) { headers.append((name, path, count)) }
            let inListBox = isWebArea(node) ? false : (parentListBox || isListBox(node))
            if inListBox && isOption(node) { options.append((node, path, count)) }
            if isSearchInput(node) { searchInputs.append((node, path)) }
            stack.append(contentsOf: children(node).reversed().map { ($0, path + [node], inListBox) })
        }
        guard let webArea = composerPath?.last(where: isWebArea) else { return nil }
        var sections: [(String, Node, [Node])] = []
        for (name, path, order) in headers {
            // An embedded browser may contain the same words; it cannot provide
            // the menu for an input in Codex's outer web area.
            guard let owner = path.last(where: isWebArea), equals(owner, webArea) else { continue }
            // Accessibility removes anonymous section/items wrappers. Use the
            // listbox's reading order, as the real browser fixture does; do not
            // require DOM parentage or mistake the title's shortcut for an option.
            if let listBox = path.last(where: isListBox) {
                let end = headers.first { _, ancestors, nextOrder in
                    nextOrder > order && ancestors.last(where: isListBox).map { equals($0, listBox) } == true
                }?.2 ?? Int.max // The last section runs to the end of its own listbox.
                let entries = options.filter { _, ancestors, optionOrder in
                    optionOrder > order && optionOrder < end
                        && ancestors.last(where: isListBox).map { equals($0, listBox) } == true
                }.map(\.0)
                if !entries.isEmpty { sections.append((name, listBox, entries)) }
                continue
            }
            for index in path.indices.reversed().prefix(3) {
                let buttons = children(path[index]).filter(isButton)
                if !buttons.isEmpty {
                    guard index > 0 else { break }
                    sections.append((name, path[index - 1], buttons))
                    break
                }
            }
        }
        guard let first = sections.first,
              sections.allSatisfy({ equals($0.1, first.1) }),
              sections.filter({ $0.0 == "Recent models" }).count <= 1,
              sections.filter({ $0.0 == "Matching models" }).count <= 1 else { return nil }
        var searchInput: Node?
        if isListBox(first.1) {
            let inputs = searchInputs.filter { _, ancestors in
                ancestors.last(where: isWebArea).map { equals($0, webArea) } == true
            }
            switch inputs.count {
            case 0: searchInput = first.1 // Live Codex 26.1111 (2026-11-15) hides the popup's search field from Accessibility; keyboard focus sits on an option and typing still filters, so the listbox stands in for the field.
            case 1: searchInput = inputs[0].0 // The popup wrapper may also be ignored. CodexUI requires this exact field's focus and the labelled Model listbox.
            default: return nil
            }
        }
        return Menu(recent: sections.first(where: { $0.0 == "Recent models" })?.2 ?? [],
                    matching: sections.first(where: { $0.0 == "Matching models" })?.2 ?? [],
                    searchInput: searchInput)
    }
}
