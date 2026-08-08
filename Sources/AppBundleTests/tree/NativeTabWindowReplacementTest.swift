@testable import AppBundle
import AppKit
import XCTest

@MainActor
final class NativeTabWindowReplacementTest: XCTestCase {
    private let matchingRect = Rect(topLeftX: 30, topLeftY: 34, width: 1668, height: 1082)

    override func setUp() async throws {
        setUpWorkspacesForTests()
        resetClosedWindowsCache()
    }

    func testInactiveTabIdStaysOutOfModelRefresh() {
        var ids = NativeTabWindowIds()
        ids.didReplace(10, with: 20)

        assertEquals(ids.modelWindowIds(from: [10, 20], deadWindowIds: []), [20])
        assertEquals(ids.modelWindowIds(from: [10, 20], deadWindowIds: [10]), [20])
        XCTAssertTrue(ids.requiresOnScreenWindowSnapshot)
    }

    func testInactiveTabReturnsWhenFocusedOrDetached() {
        var focusedIds = NativeTabWindowIds()
        focusedIds.didReplace(10, with: 20)
        focusedIds.didFocus(10)
        assertEquals(focusedIds.modelWindowIds(from: [10, 20], deadWindowIds: []), [10, 20])

        var detachedIds = NativeTabWindowIds()
        detachedIds.didReplace(10, with: 20)
        assertEquals(
            detachedIds.modelWindowIds(
                from: [10, 20],
                deadWindowIds: [],
                onScreenWindowIds: [10, 20],
            ),
            [10, 20],
        )
    }

    func testDestroyedInactiveTabIsForgotten() {
        var ids = NativeTabWindowIds()
        ids.didReplace(10, with: 20)
        _ = ids.modelWindowIds(from: [20], deadWindowIds: [10])

        XCTAssertFalse(ids.requiresOnScreenWindowSnapshot)
        assertEquals(ids.modelWindowIds(from: [10, 20], deadWindowIds: []), [10, 20])
    }

    func testNativeTabReplacementFramesMustApproximatelyMatch() {
        XCTAssertTrue(matchingRect.isApproximatelyEqual(to: matchingRect))
        XCTAssertFalse(matchingRect.isApproximatelyEqual(
            to: Rect(topLeftX: 30, topLeftY: 34, width: 1200, height: 900),
        ))
    }

    func testOnlyConventionalWindowOnFocusedWorkspaceIsEligibleForReplacement() {
        let focusedWorkspace = Workspace.get(byName: name)
        let tiled = TestWindow.new(id: 1, parent: focusedWorkspace.rootTilingContainer)
        let floating = TestWindow.new(id: 2, parent: focusedWorkspace.floatingWindowsContainer)
        let minimized = TestWindow.new(id: 3, parent: macosMinimizedWindowsContainer)
        let fullscreen = TestWindow.new(id: 4, parent: focusedWorkspace.macOsNativeFullscreenWindowsContainer)
        let otherWorkspace = Workspace.get(byName: "other")
        let elsewhere = TestWindow.new(id: 5, parent: otherWorkspace.rootTilingContainer)

        XCTAssertTrue(isEligibleNativeTabReplacementWindow(tiled, on: focusedWorkspace))
        XCTAssertTrue(isEligibleNativeTabReplacementWindow(floating, on: focusedWorkspace))
        XCTAssertFalse(isEligibleNativeTabReplacementWindow(minimized, on: focusedWorkspace))
        XCTAssertFalse(isEligibleNativeTabReplacementWindow(fullscreen, on: focusedWorkspace))
        XCTAssertFalse(isEligibleNativeTabReplacementWindow(elsewhere, on: focusedWorkspace))
    }

    func testTreeReplacementPreservesSlotWeightAndLayoutState() {
        let root = Workspace.get(byName: name).rootTilingContainer
        let container = TilingContainer.newHTiles(parent: root, adaptiveWeight: 1)
        TestWindow.new(id: 1, parent: container)
        let oldWindow = TestWindow.new(id: 2, parent: container, adaptiveWeight: 3)
        TestWindow.new(id: 3, parent: container)
        let replacement = TestWindow.new(id: 4, parent: container, adaptiveWeight: 9)
        oldWindow.lastFloatingSize = CGSize(width: 640, height: 480)
        oldWindow.isFullscreen = true
        oldWindow.layoutReason = .macos(prevParentKind: .floatingWindowsContainer)
        oldWindow.lastAppliedLayoutVirtualRect = Rect(topLeftX: 1, topLeftY: 2, width: 3, height: 4)

        replaceNativeTabWindowInTree(oldWindow, with: replacement)

        assertEquals(container.layoutDescription, .h_tiles([.window(1), .window(4), .window(3)]))
        assertEquals(replacement.getWeight(.h), 3)
        assertEquals(replacement.lastFloatingSize, CGSize(width: 640, height: 480))
        XCTAssertTrue(replacement.isFullscreen)
        assertEquals(replacement.layoutReason, .macos(prevParentKind: .floatingWindowsContainer))
        assertEquals(replacement.lastAppliedLayoutVirtualRect?.topLeftX, 1)
        XCTAssertFalse(oldWindow.isBound)
    }

    func testTreeReplacementPreservesUnknownFloatingSize() {
        let root = Workspace.get(byName: name).rootTilingContainer
        let oldWindow = TestWindow.new(id: 1, parent: root)
        let replacement = TestWindow.new(id: 2, parent: root)
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
}
