@testable import AppBundle
import Common
import XCTest

final class DumpAxTabsTest: XCTestCase {
    func testFindsNestedTabGroupAndCorrelatesSelectedChild() {
        let reader = StubAxTabReader(nodes: [
            0: .init(
                attributes: [kAXRoleAttribute: .string(kAXWindowRole)],
                elements: [kAXChildrenAttribute: [1]],
            ),
            1: .init(
                attributes: [kAXRoleAttribute: .string(kAXGroupRole)],
                elements: [kAXChildrenAttribute: [2]],
            ),
            2: .init(
                attributes: [kAXRoleAttribute: .string(kAXTabGroupRole)],
                elements: [
                    kAXChildrenAttribute: [3, 4],
                    kAXTabsAttribute: [3, 4],
                    kAXSelectedChildrenAttribute: [4],
                ],
                attributeNames: [kAXTabsAttribute, kAXChildrenAttribute, kAXRoleAttribute],
                actionNames: [kAXShowMenuAction],
                windowId: 99,
            ),
            3: .init(
                attributes: [
                    kAXRoleAttribute: .string(kAXRadioButtonRole),
                    kAXTitleAttribute: .string("First"),
                    kAXSelectedAttribute: .bool(false),
                ],
                elements: [kAXChildrenAttribute: []],
            ),
            4: .init(
                attributes: [
                    kAXRoleAttribute: .string(kAXRadioButtonRole),
                    kAXTitleAttribute: .string("Second"),
                    kAXSelectedAttribute: .bool(true),
                ],
                elements: [kAXChildrenAttribute: []],
            ),
        ])

        let result = dumpAxTabs(root: 0, reader: reader)

        assertEquals(result["visitedNodeCount"], .int(5))
        assertEquals(result["truncated"], .bool(false))
        assertEquals(result["truncationReasons"], .array([]))

        let groups = result["groups"]?.asArrayOrDie ?? dieT()
        assertEquals(groups.count, 1)
        let group = groups[0].asDictOrDie
        assertEquals(group["path"], .array([.int(0), .int(0)]))
        assertEquals(group["role"], .string(kAXTabGroupRole))
        assertEquals(group["windowId"], .int(99))
        assertEquals(
            group["attributeNames"],
            .array([kAXChildrenAttribute, kAXRoleAttribute, kAXTabsAttribute].map(Json.string)),
        )
        assertEquals(group["actionNames"], .array([.string(kAXShowMenuAction)]))
        assertEquals(group["children"]?.asArrayOrDie.count, 2)
        assertEquals(group["tabs"]?.asArrayOrDie.count, 2)
        assertEquals(group["selectedChildren"]?.asArrayOrDie.first?.asDictOrDie["childIndex"], .int(1))
        assertEquals(result["failures"], .array([]))
    }

    func testStopsAtNodeLimit() {
        let reader = StubAxTabReader(nodes: [
            0: .init(
                attributes: [kAXRoleAttribute: .string(kAXWindowRole)],
                elements: [kAXChildrenAttribute: [1, 2]],
            ),
            1: .init(
                attributes: [kAXRoleAttribute: .string(kAXGroupRole)],
                elements: [kAXChildrenAttribute: []],
            ),
            2: .init(
                attributes: [kAXRoleAttribute: .string(kAXGroupRole)],
                elements: [kAXChildrenAttribute: []],
            ),
        ])

        let result = dumpAxTabs(root: 0, reader: reader, limits: .init(maxNodes: 2))

        assertEquals(result["visitedNodeCount"], .int(2))
        assertEquals(result["truncated"], .bool(true))
        assertEquals(result["truncationReasons"], .array([.string("maximum node count 2 reached")]))
    }

    func testDoesNotVisitAnElementTwiceInACycle() {
        let reader = StubAxTabReader(nodes: [
            0: .init(
                attributes: [kAXRoleAttribute: .string(kAXWindowRole)],
                elements: [kAXChildrenAttribute: [1]],
            ),
            1: .init(
                attributes: [kAXRoleAttribute: .string(kAXGroupRole)],
                elements: [kAXChildrenAttribute: [0]],
            ),
        ])

        let result = dumpAxTabs(root: 0, reader: reader)

        assertEquals(result["visitedNodeCount"], .int(2))
        assertEquals(result["truncated"], .bool(false))
    }

    func testReportsDepthLimitOnlyWhenChildrenRemain() {
        let reader = StubAxTabReader(nodes: [
            0: .init(
                attributes: [kAXRoleAttribute: .string(kAXWindowRole)],
                elements: [kAXChildrenAttribute: [1]],
            ),
            1: .init(
                attributes: [kAXRoleAttribute: .string(kAXGroupRole)],
                elements: [kAXChildrenAttribute: [2]],
            ),
            2: .init(
                attributes: [kAXRoleAttribute: .string(kAXGroupRole)],
                elements: [kAXChildrenAttribute: []],
            ),
        ])

        let result = dumpAxTabs(root: 0, reader: reader, limits: .init(maxDepth: 1))

        assertEquals(result["visitedNodeCount"], .int(2))
        assertEquals(result["truncated"], .bool(true))
        assertEquals(result["truncationReasons"], .array([.string("maximum depth 1 reached")]))

        let leafResult = dumpAxTabs(root: 2, reader: reader, limits: .init(maxDepth: 0))
        assertEquals(leafResult["visitedNodeCount"], .int(1))
        assertEquals(leafResult["truncated"], .bool(false))
    }

    func testRecordsAndSortsAttributeAndActionFailuresWithoutAborting() {
        let reader = StubAxTabReader(nodes: [
            0: .init(
                attributes: [kAXRoleAttribute: .string(kAXWindowRole)],
                elements: [kAXChildrenAttribute: [1]],
            ),
            1: .init(
                attributes: [kAXRoleAttribute: .string(kAXTabGroupRole)],
                elements: [
                    kAXChildrenAttribute: [],
                    kAXTabsAttribute: [],
                    kAXSelectedChildrenAttribute: [],
                ],
                attributeNamesError: "attributeUnsupported",
                actionNamesError: "cannotComplete",
            ),
        ])

        let result = dumpAxTabs(root: 0, reader: reader)

        assertEquals(result["groups"]?.asArrayOrDie.count, 1)
        assertEquals(
            result["failures"],
            .array([
                failureJson(path: [0], operation: "listActions", error: "cannotComplete"),
                failureJson(path: [0], operation: "listAttributes", error: "attributeUnsupported"),
            ]),
        )
    }

    func testTruncatesUnknownScalarDescriptionsAt512Characters() {
        let value = LongAxDescription()

        assertEquals(
            axTabJsonValue(value),
            .string(String(repeating: "x", count: 512) + "… [truncated]"),
        )
    }

    func testNoTabGroupReturnsEmptyGroups() {
        let reader = StubAxTabReader(nodes: [
            0: .init(
                attributes: [kAXRoleAttribute: .string(kAXWindowRole)],
                elements: [kAXChildrenAttribute: []],
            ),
        ])

        let result = dumpAxTabs(root: 0, reader: reader)

        assertEquals(result["visitedNodeCount"], .int(1))
        assertEquals(result["groups"], .array([]))
    }

    func testKeepsUnmatchedAXTabsWithNullChildIndex() {
        let reader = StubAxTabReader(nodes: [
            0: .init(
                attributes: [kAXRoleAttribute: .string(kAXTabGroupRole)],
                elements: [
                    kAXChildrenAttribute: [1],
                    kAXTabsAttribute: [2],
                    kAXSelectedChildrenAttribute: [],
                ],
            ),
            1: .init(
                attributes: [kAXRoleAttribute: .string(kAXRadioButtonRole)],
                elements: [kAXChildrenAttribute: []],
            ),
            2: .init(
                attributes: [
                    kAXRoleAttribute: .string(kAXRadioButtonRole),
                    kAXTitleAttribute: .string("Relationship only"),
                ],
                elements: [kAXChildrenAttribute: []],
            ),
        ])

        let result = dumpAxTabs(root: 0, reader: reader)
        let tab = result["groups"]?.asArrayOrDie.first?.asDictOrDie["tabs"]?.asArrayOrDie.first?.asDictOrDie

        assertEquals(tab?["childIndex"], .null)
        assertEquals(tab?["title"], .string("Relationship only"))
    }

    func testAttributesDirectChildFailuresToTheChildPath() {
        let reader = StubAxTabReader(nodes: [
            0: .init(
                attributes: [kAXRoleAttribute: .string(kAXTabGroupRole)],
                elements: [
                    kAXChildrenAttribute: [1],
                    kAXTabsAttribute: [],
                    kAXSelectedChildrenAttribute: [],
                ],
            ),
            1: .init(
                attributes: [kAXRoleAttribute: .string(kAXRadioButtonRole)],
                elements: [kAXChildrenAttribute: []],
                attributeNamesError: "cannotComplete",
            ),
        ])

        let result = dumpAxTabs(root: 0, reader: reader)

        assertEquals(
            result["failures"],
            .array([failureJson(path: [0], operation: "listAttributes", error: "cannotComplete")]),
        )
    }
}

private struct StubAxTabReader: AxTabReading {
    typealias Node = Int

    let nodes: [Int: StubAxNode]

    func attributeNames(of node: Int) -> AxTabRead<[String]> {
        let node = nodes[node].orDie()
        return node.attributeNamesError.map(AxTabRead.failure)
            ?? .success(node.attributeNames)
    }

    func actionNames(of node: Int) -> AxTabRead<[String]> {
        let node = nodes[node].orDie()
        return node.actionNamesError.map(AxTabRead.failure)
            ?? .success(node.actionNames)
    }

    func jsonValue(of node: Int, attribute: String) -> AxTabRead<Json> {
        nodes[node].orDie().attributes[attribute]
            .map(AxTabRead.success)
            ?? .failure("attributeUnsupported")
    }

    func elements(of node: Int, attribute: String) -> AxTabRead<[Int]> {
        nodes[node].orDie().elements[attribute]
            .map(AxTabRead.success)
            ?? .failure("attributeUnsupported")
    }

    func containingWindowId(of node: Int) -> UInt32? {
        nodes[node].orDie().windowId
    }
}

private struct StubAxNode {
    var attributes: [String: Json]
    var elements: [String: [Int]]
    var attributeNames: [String]
    var actionNames: [String]
    var windowId: UInt32?
    var attributeNamesError: String?
    var actionNamesError: String?

    init(
        attributes: [String: Json],
        elements: [String: [Int]],
        attributeNames: [String]? = nil,
        actionNames: [String] = [],
        windowId: UInt32? = nil,
        attributeNamesError: String? = nil,
        actionNamesError: String? = nil,
    ) {
        self.attributes = attributes
        self.elements = elements
        self.attributeNames = attributeNames ?? Array(attributes.keys) + Array(elements.keys)
        self.actionNames = actionNames
        self.windowId = windowId
        self.attributeNamesError = attributeNamesError
        self.actionNamesError = actionNamesError
    }
}

private func failureJson(path: [Int], operation: String, attribute: String? = nil, error: String) -> Json {
    .dict([
        "path": .array(path.map(Json.int)),
        "operation": .string(operation),
        "attribute": .stringOrNull(attribute),
        "error": .string(error),
    ])
}

private extension Json {
    var asArrayOrDie: [Json] {
        if case .array(let value) = self { return value }
        return dieT("\(self) is not an array")
    }
}

private final class LongAxDescription: NSObject {
    override var description: String { String(repeating: "x", count: 513) }
}
