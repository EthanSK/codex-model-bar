/// Finds the inline model-search sections in the composer's own web area.
/// Codex 26.924 puts this menu in a portal, outside the composer's ancestors.
public struct ModelMenuLocator<Node> {
    public struct Menu {
        public var recent: [Node]
        public var matching: [Node]
    }

    public let children: (Node) -> [Node]
    public let isWebArea: (Node) -> Bool
    public let isButton: (Node) -> Bool
    public let header: (Node) -> String?
    public let equals: (Node, Node) -> Bool

    public init(children: @escaping (Node) -> [Node], isWebArea: @escaping (Node) -> Bool,
                isButton: @escaping (Node) -> Bool, header: @escaping (Node) -> String?,
                equals: @escaping (Node, Node) -> Bool) {
        self.children = children
        self.isWebArea = isWebArea
        self.isButton = isButton
        self.header = header
        self.equals = equals
    }

    public func locate(in window: Node, composer: Node) -> Menu? {
        var stack: [(Node, [Node])] = [(window, [])]
        var composerPath: [Node]?
        var headers: [(String, [Node])] = []
        var count = 0
        while let (node, path) = stack.popLast() {
            count += 1
            guard count <= 30_000 else { return nil }
            if equals(node, composer) { composerPath = path }
            if let name = header(node) { headers.append((name, path)) }
            stack.append(contentsOf: children(node).reversed().map { ($0, path + [node]) })
        }
        guard let webArea = composerPath?.last(where: isWebArea) else { return nil }
        var sections: [(String, Node, [Node])] = []
        for (name, path) in headers {
            // An embedded browser may contain the same words; it cannot provide
            // the menu for an input in Codex's outer web area.
            guard let owner = path.last(where: isWebArea), equals(owner, webArea) else { continue }
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
        return Menu(recent: sections.first(where: { $0.0 == "Recent models" })?.2 ?? [],
                    matching: sections.first(where: { $0.0 == "Matching models" })?.2 ?? [])
    }
}
