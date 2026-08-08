@testable import AppBundle
import Common
import XCTest

@MainActor
final class DebugWindowsCommandTest: XCTestCase {
    func testParseTabs() {
        testParseSingleCommandSucc(
            "debug-windows --tabs",
            DebugWindowsCmdArgs(rawArgs: []).copy(\.tabs, true),
        )
        testParseSingleCommandSucc(
            "debug-windows --tabs --window-id 42",
            DebugWindowsCmdArgs(rawArgs: [])
                .copy(\.tabs, true)
                .copy(\.windowId, 42),
        )
    }

    func testModeSelection() {
        assertEquals(DebugWindowsCmdArgs(rawArgs: []).mode, .interactive)
        assertEquals(DebugWindowsCmdArgs(rawArgs: []).copy(\.windowId, 42).mode, .window(42))
        assertEquals(DebugWindowsCmdArgs(rawArgs: []).copy(\.tabs, true).mode, .tabs(nil))
        assertEquals(
            DebugWindowsCmdArgs(rawArgs: []).copy(\.tabs, true).copy(\.windowId, 42).mode,
            .tabs(42),
        )
    }
}
