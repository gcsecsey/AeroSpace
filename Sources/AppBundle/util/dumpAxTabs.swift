import AppKit
import Common

enum AxTabRead<Value> {
    case success(Value)
    case failure(String)
}

protocol AxTabReading {
    associatedtype Node: Hashable

    func attributeNames(of node: Node) -> AxTabRead<[String]>
    func actionNames(of node: Node) -> AxTabRead<[String]>
    func jsonValue(of node: Node, attribute: String) -> AxTabRead<Json>
    func elements(of node: Node, attribute: String) -> AxTabRead<[Node]>
    func containingWindowId(of node: Node) -> UInt32?
}

struct AxTabDumpLimits {
    let maxDepth: Int
    let maxNodes: Int

    init(maxDepth: Int = 12, maxNodes: Int = 500) {
        self.maxDepth = maxDepth
        self.maxNodes = maxNodes
    }
}

func dumpAxTabs<Reader: AxTabReading>(
    root: Reader.Node,
    reader: Reader,
    limits: AxTabDumpLimits = .init(),
) -> [String: Json] {
    var dumper = AxTabDumper(reader: reader, limits: limits)
    dumper.visit(root, path: [], depth: 0)
    return dumper.result
}

func dumpAxTabs(_ root: AXUIElement) -> [String: Json] {
    dumpAxTabs(root: LiveAxTabNode(root), reader: LiveAxTabReader())
}

func axTabJsonValue(_ value: Any?) -> Json {
    guard let value else { return .null }
    if let scalar = Json.newScalarOrNil(value) { return scalar }
    let description = String(describing: value)
    let prefix = String(description.prefix(512))
    return .string(description.count > 512 ? prefix + "… [truncated]" : prefix)
}

private struct LiveAxTabNode: Hashable {
    let element: AXUIElement

    init(_ element: AXUIElement) {
        self.element = element
    }

    static func == (lhs: LiveAxTabNode, rhs: LiveAxTabNode) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}

private struct LiveAxTabReader: AxTabReading {
    func attributeNames(of node: LiveAxTabNode) -> AxTabRead<[String]> {
        var raw: CFArray?
        let status = unsafe AXUIElementCopyAttributeNames(node.element, &raw)
        return status == .success
            ? .success(raw as? [String] ?? [])
            : .failure(status.repr)
    }

    func actionNames(of node: LiveAxTabNode) -> AxTabRead<[String]> {
        var raw: CFArray?
        let status = unsafe AXUIElementCopyActionNames(node.element, &raw)
        return status == .success
            ? .success(raw as? [String] ?? [])
            : .failure(status.repr)
    }

    func jsonValue(of node: LiveAxTabNode, attribute: String) -> AxTabRead<Json> {
        var raw: AnyObject?
        let status = unsafe AXUIElementCopyAttributeValue(node.element, attribute as CFString, &raw)
        return status == .success
            ? .success(axTabJsonValue(raw))
            : .failure(status.repr)
    }

    func elements(of node: LiveAxTabNode, attribute: String) -> AxTabRead<[LiveAxTabNode]> {
        var raw: AnyObject?
        let status = unsafe AXUIElementCopyAttributeValue(node.element, attribute as CFString, &raw)
        guard status == .success else { return .failure(status.repr) }
        guard let raw else { return .success([]) }
        let values = raw as? [AnyObject] ?? [raw]
        var elements: [LiveAxTabNode] = []
        for value in values {
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
                return .failure("unexpectedValue(\(type(of: value)))")
            }
            elements.append(LiveAxTabNode(value as! AXUIElement))
        }
        return .success(elements)
    }

    func containingWindowId(of node: LiveAxTabNode) -> UInt32? {
        node.element.containingWindowId()
    }
}

private struct AxTabDumper<Reader: AxTabReading> {
    let reader: Reader
    let limits: AxTabDumpLimits
    var observedNodes: Set<Reader.Node> = []
    var traversedNodes: Set<Reader.Node> = []
    var groups: [Json] = []
    var failures: [AxTabFailure] = []
    var truncationReasons: [String] = []

    var result: [String: Json] {
        [
            "visitedNodeCount": .int(observedNodes.count),
            "truncated": .bool(!truncationReasons.isEmpty),
            "truncationReasons": .array(truncationReasons.map(Json.string)),
            "groups": .array(groups),
            "failures": .array(failures.sorted(by: { $0.isBefore($1) }).map(\.json)),
        ]
    }

    mutating func visit(_ node: Reader.Node, path: [Int], depth: Int) {
        guard !traversedNodes.contains(node) else { return }
        guard observe(node) else { return }
        traversedNodes.insert(node)
        let role = readJson(node, attribute: kAXRoleAttribute, path: path)
        let children = readElements(node, attribute: kAXChildrenAttribute, path: path)
        if role == .string(kAXTabGroupRole) {
            groups.append(.dict(groupSnapshot(node, path: path, role: role, children: children)))
        }
        if depth >= limits.maxDepth {
            if !children.isEmpty {
                addTruncationReason("maximum depth \(limits.maxDepth) reached")
            }
            return
        }
        for (index, child) in children.enumerated() {
            visit(child, path: path + [index], depth: depth + 1)
            if observedNodes.count >= limits.maxNodes, index < children.indices.last.orDie() {
                addTruncationReason("maximum node count \(limits.maxNodes) reached")
                break
            }
        }
    }

    mutating func observe(_ node: Reader.Node) -> Bool {
        if observedNodes.contains(node) { return true }
        guard observedNodes.count < limits.maxNodes else {
            addTruncationReason("maximum node count \(limits.maxNodes) reached")
            return false
        }
        observedNodes.insert(node)
        return true
    }

    mutating func addTruncationReason(_ reason: String) {
        if !truncationReasons.contains(reason) {
            truncationReasons.append(reason)
        }
    }

    mutating func groupSnapshot(
        _ node: Reader.Node,
        path: [Int],
        role: Json,
        children: [Reader.Node],
    ) -> [String: Json] {
        let attributeNames = readAttributeNames(node, path: path)
        let actionNames = readActionNames(node, path: path)
        let tabs = readElements(node, attribute: kAXTabsAttribute, path: path)
        let selectedChildren = readElements(node, attribute: kAXSelectedChildrenAttribute, path: path)
        return [
            "path": .array(path.map(Json.int)),
            "windowId": reader.containingWindowId(of: node).map(Json.int) ?? .null,
            "role": role,
            "subrole": readOptionalJson(node, attribute: kAXSubroleAttribute, advertisedBy: attributeNames, path: path),
            "title": readOptionalJson(node, attribute: kAXTitleAttribute, advertisedBy: attributeNames, path: path),
            "identifier": readOptionalJson(node, attribute: kAXIdentifierAttribute, advertisedBy: attributeNames, path: path),
            "description": readOptionalJson(node, attribute: kAXDescriptionAttribute, advertisedBy: attributeNames, path: path),
            "value": readOptionalJson(node, attribute: kAXValueAttribute, advertisedBy: attributeNames, path: path),
            "attributeNames": .array(attributeNames.sorted().map(Json.string)),
            "actionNames": .array(actionNames.sorted().map(Json.string)),
            "tabs": .array(tabs.compactMap { referencedElementSnapshot($0, children: children, groupPath: path) }),
            "selectedChildren": .array(selectedChildren.compactMap { referencedElementSnapshot($0, children: children, groupPath: path) }),
            "children": .array(children.enumerated().compactMap {
                elementSnapshot($0.element, childIndex: $0.offset, path: path + [$0.offset]).map(Json.dict)
            }),
        ]
    }

    mutating func referencedElementSnapshot(
        _ node: Reader.Node,
        children: [Reader.Node],
        groupPath: [Int],
    ) -> Json? {
        let childIndex = children.firstIndex(of: node)
        let path = childIndex.map { groupPath + [$0] } ?? groupPath
        return elementSnapshot(node, childIndex: childIndex, path: path).map(Json.dict)
    }

    mutating func elementSnapshot(
        _ node: Reader.Node,
        childIndex: Int?,
        path: [Int],
    ) -> [String: Json]? {
        guard observe(node) else { return nil }
        let attributeNames = readAttributeNames(node, path: path)
        let actionNames = readActionNames(node, path: path)
        return [
            "childIndex": childIndex.map(Json.int) ?? .null,
            "windowId": reader.containingWindowId(of: node).map(Json.int) ?? .null,
            "role": readOptionalJson(node, attribute: kAXRoleAttribute, advertisedBy: attributeNames, path: path),
            "subrole": readOptionalJson(node, attribute: kAXSubroleAttribute, advertisedBy: attributeNames, path: path),
            "title": readOptionalJson(node, attribute: kAXTitleAttribute, advertisedBy: attributeNames, path: path),
            "identifier": readOptionalJson(node, attribute: kAXIdentifierAttribute, advertisedBy: attributeNames, path: path),
            "description": readOptionalJson(node, attribute: kAXDescriptionAttribute, advertisedBy: attributeNames, path: path),
            "value": readOptionalJson(node, attribute: kAXValueAttribute, advertisedBy: attributeNames, path: path),
            "selected": readOptionalJson(node, attribute: kAXSelectedAttribute, advertisedBy: attributeNames, path: path),
            "attributeNames": .array(attributeNames.sorted().map(Json.string)),
            "actionNames": .array(actionNames.sorted().map(Json.string)),
        ]
    }

    mutating func readOptionalJson(
        _ node: Reader.Node,
        attribute: String,
        advertisedBy attributeNames: [String],
        path: [Int],
    ) -> Json {
        attributeNames.contains(attribute)
            ? readJson(node, attribute: attribute, path: path)
            : .null
    }

    mutating func readAttributeNames(_ node: Reader.Node, path: [Int]) -> [String] {
        switch reader.attributeNames(of: node) {
            case .success(let value): return value
            case .failure(let error):
                failures.append(.init(path: path, operation: "listAttributes", attribute: nil, error: error))
                return []
        }
    }

    mutating func readActionNames(_ node: Reader.Node, path: [Int]) -> [String] {
        switch reader.actionNames(of: node) {
            case .success(let value): return value
            case .failure(let error):
                failures.append(.init(path: path, operation: "listActions", attribute: nil, error: error))
                return []
        }
    }

    mutating func readJson(_ node: Reader.Node, attribute: String, path: [Int]) -> Json {
        switch reader.jsonValue(of: node, attribute: attribute) {
            case .success(let value): return value
            case .failure(let error):
                failures.append(.init(path: path, operation: "readAttribute", attribute: attribute, error: error))
                return .null
        }
    }

    mutating func readElements(_ node: Reader.Node, attribute: String, path: [Int]) -> [Reader.Node] {
        switch reader.elements(of: node, attribute: attribute) {
            case .success(let value): return value
            case .failure(let error):
                failures.append(.init(path: path, operation: "readAttribute", attribute: attribute, error: error))
                return []
        }
    }
}

private struct AxTabFailure {
    let path: [Int]
    let operation: String
    let attribute: String?
    let error: String

    func isBefore(_ other: AxTabFailure) -> Bool {
        if path != other.path { return path.lexicographicallyPrecedes(other.path) }
        if operation != other.operation { return operation < other.operation }
        if attribute != other.attribute { return (attribute ?? "") < (other.attribute ?? "") }
        return error < other.error
    }

    var json: Json {
        .dict([
            "path": .array(path.map(Json.int)),
            "operation": .string(operation),
            "attribute": .stringOrNull(attribute),
            "error": .string(error),
        ])
    }
}
