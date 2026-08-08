@testable import AppBundle
import XCTest

@MainActor
final class NativeTabWindowReplacementTest: XCTestCase {
    private let matchingRect = Rect(topLeftX: 30, topLeftY: 34, width: 1668, height: 1082)

    override func setUp() async throws {
        setUpWorkspacesForTests()
        resetClosedWindowsCache()
    }

    func testReplacedPhysicalTabIdStaysOutOfModelRefresh() {
        var ids = NativeTabWindowIds()
        XCTAssertFalse(ids.requiresOnScreenWindowSnapshot)

        ids.didReplace(10, with: 20)

        XCTAssertTrue(ids.requiresOnScreenWindowSnapshot)
        assertEquals(ids.modelWindowIds(from: [10, 20], deadWindowIds: []), [20])
    }

    func testFocusedTabIdReturnsToModel() {
        var ids = NativeTabWindowIds()
        ids.didReplace(10, with: 20)

        ids.didFocus(10)

        assertEquals(ids.modelWindowIds(from: [10, 20], deadWindowIds: []), [10, 20])
    }

    func testDestroyedTabIdIsForgotten() {
        var ids = NativeTabWindowIds()
        ids.didReplace(10, with: 20)
        _ = ids.modelWindowIds(from: [20], deadWindowIds: [10])

        XCTAssertFalse(ids.requiresOnScreenWindowSnapshot)
        assertEquals(ids.modelWindowIds(from: [10, 20], deadWindowIds: []), [10, 20])
    }

    func testTabIdReportedAliveAndDeadRemainsSuppressed() {
        var ids = NativeTabWindowIds()
        ids.didReplace(10, with: 20)

        assertEquals(ids.modelWindowIds(from: [10, 20], deadWindowIds: [10]), [20])
    }

    func testVisibleDetachedTabReturnsToModelWithoutFocus() {
        var ids = NativeTabWindowIds()
        ids.didReplace(10, with: 20)

        assertEquals(
            ids.modelWindowIds(
                from: [10, 20],
                deadWindowIds: [],
                onScreenWindowIds: [10, 20],
            ),
            [10, 20],
        )
    }

    func testMissingOnScreenSnapshotKeepsInactiveTabSuppressed() {
        var ids = NativeTabWindowIds()
        ids.didReplace(10, with: 20)

        assertEquals(
            ids.modelWindowIds(
                from: [10, 20],
                deadWindowIds: [],
                onScreenWindowIds: nil,
            ),
            [20],
        )
    }

    func testTreeReplacementPreservesExactSlotWeightAndLayoutState() {
        let root = Workspace.get(byName: name).rootTilingContainer
        let container = TilingContainer.newHTiles(parent: root, adaptiveWeight: 1)
        let replacement = TestWindow.new(id: 4, parent: container, adaptiveWeight: 9)
        TestWindow.new(id: 1, parent: container)
        let oldWindow = TestWindow.new(id: 2, parent: container, adaptiveWeight: 3)
        TestWindow.new(id: 3, parent: container)
        oldWindow.lastFloatingSize = CGSize(width: 640, height: 480)
        oldWindow.isFullscreen = true
        oldWindow.noOuterGapsInFullscreen = true
        oldWindow.layoutReason = .macos(prevParentKind: .floatingWindowsContainer)
        oldWindow.lastAppliedLayoutVirtualRect = Rect(topLeftX: 1, topLeftY: 2, width: 3, height: 4)
        oldWindow.lastAppliedLayoutPhysicalRect = Rect(topLeftX: 5, topLeftY: 6, width: 7, height: 8)

        replaceNativeTabWindowInTree(oldWindow, with: replacement)

        assertEquals(container.layoutDescription, .h_tiles([.window(1), .window(4), .window(3)]))
        assertEquals(replacement.getWeight(.h), 3)
        assertEquals(replacement.lastFloatingSize, CGSize(width: 640, height: 480))
        XCTAssertTrue(replacement.isFullscreen)
        XCTAssertTrue(replacement.noOuterGapsInFullscreen)
        assertEquals(replacement.layoutReason, .macos(prevParentKind: .floatingWindowsContainer))
        assertEquals(replacement.lastAppliedLayoutVirtualRect?.topLeftX, 1)
        assertEquals(replacement.lastAppliedLayoutVirtualRect?.height, 4)
        assertEquals(replacement.lastAppliedLayoutPhysicalRect?.topLeftX, 5)
        assertEquals(replacement.lastAppliedLayoutPhysicalRect?.height, 8)
        XCTAssertFalse(oldWindow.isBound)
    }

    func testTreeReplacementPreservesUnknownFloatingSize() {
        let root = Workspace.get(byName: name).rootTilingContainer
        let oldWindow = TestWindow.new(id: 1, parent: root)
        let replacement = TestWindow.new(id: 2, parent: root)
        oldWindow.lastFloatingSize = nil
        replacement.lastFloatingSize = CGSize(width: 640, height: 480)

        replaceNativeTabWindowInTree(oldWindow, with: replacement)

        XCTAssertNil(replacement.lastFloatingSize)
    }

    func testTreeReplacementInvalidatesClosedWindowsCache() async throws {
        let root = Workspace.get(byName: name).rootTilingContainer
        let oldWindow = TestWindow.new(id: 1, parent: root)
        cacheClosedWindowIfNeeded()
        let replacement = TestWindow.new(id: 2, parent: root)

        replaceNativeTabWindowInTree(oldWindow, with: replacement)

        let oldWindowDetectedAgain = TestWindow.new(id: 1, parent: root)
        let restored = try await restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: oldWindowDetectedAgain)
        XCTAssertFalse(restored)
    }

    func testSelectsPreviousOffScreenWindowWhenNativeTabFramesMatch() {
        let result = nativeTabReplacementWindowId(
            focusedWindowId: 20,
            previousFocusedWindowId: 10,
            hasNativeWindowTabs: true,
            onScreenWindowIds: [20],
            focusedRect: matchingRect,
            previousRect: matchingRect,
        )

        XCTAssertEqual(result, 10)
    }

    func testDoesNotReplaceWithoutNativeTabEvidence() {
        let result = nativeTabReplacementWindowId(
            focusedWindowId: 20,
            previousFocusedWindowId: 10,
            hasNativeWindowTabs: false,
            onScreenWindowIds: [20],
            focusedRect: matchingRect,
            previousRect: matchingRect,
        )

        XCTAssertNil(result)
    }

    func testDoesNotReplaceASeparateOnScreenWindow() {
        let result = nativeTabReplacementWindowId(
            focusedWindowId: 20,
            previousFocusedWindowId: 10,
            hasNativeWindowTabs: true,
            onScreenWindowIds: [10, 20],
            focusedRect: matchingRect,
            previousRect: matchingRect,
        )

        XCTAssertNil(result)
    }

    func testAllowsMinorFrameRoundingDifferences() {
        let result = nativeTabReplacementWindowId(
            focusedWindowId: 20,
            previousFocusedWindowId: 10,
            hasNativeWindowTabs: true,
            onScreenWindowIds: [20],
            focusedRect: matchingRect,
            previousRect: Rect(topLeftX: 31, topLeftY: 33, width: 1667, height: 1083),
        )

        XCTAssertEqual(result, 10)
    }

    func testDoesNotReplaceWhenWindowFramesDiffer() {
        let result = nativeTabReplacementWindowId(
            focusedWindowId: 20,
            previousFocusedWindowId: 10,
            hasNativeWindowTabs: true,
            onScreenWindowIds: [20],
            focusedRect: matchingRect,
            previousRect: Rect(topLeftX: 31, topLeftY: 34, width: 1200, height: 900),
        )

        XCTAssertNil(result)
    }
}
