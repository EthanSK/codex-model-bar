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
        var headers: [(String, [Node])] = []
        var options: [(Node, [Node])] = []
        var searchInputs: [(Node, [Node])] = []
        var count = 0
        while let (node, path, parentListBox) = stack.popLast() {
            count += 1
            guard count <= 30_000 else { return nil }
            if equals(node, composer) { composerPath = path }
            if let name = header(node) { headers.append((name, path)) }
            let inListBox = isWebArea(node) ? false : (parentListBox || isListBox(node))
            if inListBox && isOption(node) { options.append((node, path)) }
            if isSearchInput(node) { searchInputs.append((node, path)) }
            stack.append(contentsOf: children(node).reversed().map { ($0, path + [node], inListBox) })
        }
        guard let webArea = composerPath?.last(where: isWebArea) else { return nil }
        var sections: [(String, Node, [Node])] = []
        for (name, path) in headers {
            // An embedded browser may contain the same words; it cannot provide
            // the menu for an input in Codex's outer web area.
            guard let owner = path.last(where: isWebArea), equals(owner, webArea) else { continue }
            // Codex 26.1111 gives each section an items wrapper and ARIA options,
            // rather than direct buttons. Use its nearest listbox, not a header's
            // shortcut button or a matching phrase elsewhere in the transcript.
            if let index = path.lastIndex(where: isListBox), index + 1 < path.count {
                let section = path[index + 1]
                let entries = options.filter { _, ancestors in
                    ancestors.contains { equals($0, section) }
                        && ancestors.last(where: isListBox).map { equals($0, path[index]) } == true
                }.map(\.0)
                if !entries.isEmpty { sections.append((name, path[index], entries)) }
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
            guard let path = headers.first(where: { _, path in path.contains { equals($0, first.1) } })?.1,
                  let listIndex = path.firstIndex(where: { equals($0, first.1) }) else { return nil }
            for ancestor in path[..<listIndex].reversed() {
                if isWebArea(ancestor) { break }
                let inputs = searchInputs.filter { _, ancestors in
                    ancestors.contains { equals($0, ancestor) }
                        && ancestors.last(where: isWebArea).map { equals($0, webArea) } == true
                }
                guard inputs.count <= 1 else { return nil }
                if let input = inputs.first { searchInput = input.0; break }
            }
            guard searchInput != nil else { return nil }
        }
        return Menu(recent: sections.first(where: { $0.0 == "Recent models" })?.2 ?? [],
                    matching: sections.first(where: { $0.0 == "Matching models" })?.2 ?? [],
                    searchInput: searchInput)
    }
}
