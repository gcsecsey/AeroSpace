@testable import AppBundle
import AppKit
import XCTest

final class NativeTabsTest: XCTestCase {
    func testFindsNestedGroupWithMultipleTabs() {
        let graph = NativeTabGraph(
            roles: [0: kAXWindowRole, 1: kAXGroupRole, 2: kAXTabGroupRole],
            children: [0: [1], 1: [2]],
            tabs: [2: [3, 4]],
        )

        XCTAssertTrue(graph.hasNativeWindowTabs())
    }

    func testSingleTabIsNotReplacementEvidence() {
        let graph = NativeTabGraph(
            roles: [0: kAXWindowRole, 1: kAXTabGroupRole],
            children: [0: [1]],
            tabs: [1: [2]],
        )

        XCTAssertFalse(graph.hasNativeWindowTabs())
    }

    func testTraversalIsBounded() {
        let graph = NativeTabGraph(
            roles: [0: kAXWindowRole, 1: kAXGroupRole, 2: kAXTabGroupRole],
            children: [0: [1, 2]],
            tabs: [2: [3, 4]],
        )

        XCTAssertFalse(graph.hasNativeWindowTabs(maxNodes: 2))
    }
}

private struct NativeTabGraph {
    let roles: [Int: String]
    let children: [Int: [Int]]
    let tabs: [Int: [Int]]

    func hasNativeWindowTabs(maxNodes: Int = 100) -> Bool {
        AppBundle.hasNativeWindowTabs(
            root: 0,
            maxNodes: maxNodes,
            role: { roles[$0] },
            tabs: { tabs[$0] ?? [] },
            children: { children[$0] ?? [] },
        )
    }
}
