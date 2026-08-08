# `debug-windows --tabs` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a bounded, one-shot `aerospace debug-windows --tabs [--window-id ID]` diagnostic that exposes native macOS Accessibility tab structures without changing window-management behavior.

**Architecture:** Keep the existing recursive AX dump unchanged. Add a testable, generic tab-tree walker with a live `AXUIElement` reader, run it on each application's AX thread, and route the new CLI flag to a small tab-specific JSON formatter. The walker uses ordered breadth-first traversal, element identity, depth/node limits, and bounded structured per-operation failures.

**Tech Stack:** Swift 6.2+, AppKit Accessibility (`AXUIElement`), Swift Package Manager, XCTest, AsciiDoc, AeroSpace's `CmdArgs` and `Json` types.

## Global Constraints

- Maximum traversal depth is 12 edges below the window root.
- Maximum visited element count is 500, including the root.
- Tab mode is one-shot and must not mutate the interactive debug recording state.
- Existing `debug-windows` and `debug-windows --window-id ID` behavior stays unchanged.
- An empty `groups` array is a successful no-tab result.
- Accessibility failures are recorded per operation; only failure to access the root window is fatal.
- Do not copy or adapt GPL-licensed AltTab implementation code.
- Do not add event observation, hit-testing, Core Graphics inventory, ScreenCaptureKit, private SkyLight APIs, or application-specific adapters.
- Traverse shallow AX nodes before deeper document contents.
- Treat `noValue` and `attributeUnsupported` from traversal `AXChildren` reads as ordinary leaves.
- Emit at most 20 failure details while retaining total and omitted counts.

---

### Task 1: Parse and select the tab diagnostic mode

**Files:**
- Create: `Sources/AppBundleTests/command/DebugWindowsCommandTest.swift`
- Modify: `Sources/Common/cmdArgs/impl/DebugWindowsCmdArgs.swift`
- Modify: `Sources/AppBundle/command/impl/DebugWindowsCommand.swift`

**Interfaces:**
- Produces: `DebugWindowsCmdArgs.tabs: Bool`, defaulting to `false` and set by `--tabs`.
- Produces: `DebugWindowsMode` with `.interactive`, `.window(UInt32)`, and `.tabs(UInt32?)` cases.
- Consumes: existing `trueBoolFlag`, `windowIdSubArgParser`, and `parseCommand` test helper.

- [ ] **Step 1: Write the failing parser and mode tests**

Create `DebugWindowsCommandTest.swift` with literal expectations:

```swift
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
```

The break these tests catch is dropping `--tabs`, allowing `--window-id` to override tab mode, or routing existing invocations to a new mode.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
swift test --filter DebugWindowsCommandTest
```

Expected: compilation fails because `tabs`, `mode`, and `DebugWindowsMode` do not exist.

- [ ] **Step 3: Add the minimal parser and mode implementation**

Add the flag and value:

```swift
"--tabs": trueBoolFlag(\.tabs),
public var tabs: Bool = false
```

Define mode selection in `DebugWindowsCommand.swift`:

```swift
enum DebugWindowsMode: Equatable {
    case interactive
    case window(UInt32)
    case tabs(UInt32?)
}

extension DebugWindowsCmdArgs {
    var mode: DebugWindowsMode {
        if tabs { return .tabs(windowId) }
        if let windowId { return .window(windowId) }
        return .interactive
    }
}
```

Switch the existing command over `args.mode` while retaining the current bodies for `.interactive` and `.window`. Leave `.tabs` temporarily returning the existing bug prompt so this task changes routing but not AX behavior.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run `swift test --filter DebugWindowsCommandTest` and expect all tests in the class to pass.

- [ ] **Step 5: Commit the parser and routing seam**

```bash
git add Sources/Common/cmdArgs/impl/DebugWindowsCmdArgs.swift Sources/AppBundle/command/impl/DebugWindowsCommand.swift Sources/AppBundleTests/command/DebugWindowsCommandTest.swift
git commit -m "Add debug-windows tabs mode"
```

### Task 2: Traverse and normalize AX tab structures

**Files:**
- Create: `Sources/AppBundle/util/dumpAxTabs.swift`
- Create: `Sources/AppBundleTests/DumpAxTabsTest.swift`
- Modify: `Sources/AppBundle/util/dumpAxRecursive.swift`

**Interfaces:**
- Produces: `AxTabRead<Value>` with `.success(Value)` and `.failure(String)`.
- Produces: `AxTabReading` with associated `Node: Hashable` and methods `attributeNames(of:)`, `actionNames(of:)`, `jsonValue(of:attribute:)`, `elements(of:attribute:)`, and `containingWindowId(of:)`.
- Produces: `AxTabDumpLimits(maxDepth:maxNodes:)`, defaulting to `(12, 500)`.
- Produces: `dumpAxTabs<Reader: AxTabReading>(root:reader:limits:) -> [String: Json]`.
- Produces: `dumpAxTabs(_ root: AXUIElement) -> [String: Json]` using the live reader.
- Consumes: `AXError.repr`, changed from `fileprivate` to module-internal access.

- [ ] **Step 1: Write a synthetic reader and the first failing group test**

In `DumpAxTabsTest.swift`, define an integer-node reader whose fixture contains literal scalar attributes, relationship arrays, actions, and failures. Add a test with root `0`, nested container `1`, and tab group `2` containing tab buttons `3` and `4`. Assert these hand-derived results:

```swift
let result = dumpAxTabs(root: 0, reader: reader)
assertEquals(result["visitedNodeCount"], .int(5))
assertEquals(result["truncated"], .bool(false))
assertEquals(result["truncationReasons"], .array([]))

let groups = result["groups"]?.asArrayOrDie ?? dieT()
assertEquals(groups.count, 1)
let group = groups[0].asDictOrDie
assertEquals(group["path"], .array([.int(0), .int(0)]))
assertEquals(group["role"], .string("AXTabGroup"))
assertEquals(group["windowId"], .int(99))
assertEquals(group["attributeNames"], .array([.string("AXChildren"), .string("AXRole"), .string("AXTabs")]))
assertEquals(group["actionNames"], .array([.string("AXShowMenu")]))
assertEquals(group["children"]?.asArrayOrDie.count, 2)
assertEquals(group["tabs"]?.asArrayOrDie.count, 2)
assertEquals(group["selectedChildren"]?.asArrayOrDie.first?.asDictOrDie["childIndex"], .int(1))
assertEquals(result["failures"], .array([]))
```

Add `Json.asArrayOrDie` as a test-only extension in this test file; do not change production `Json` solely for assertions.

The break this test catches is failing to search nested children, losing child order, missing tab relationships, or failing to correlate a selected element with a direct child.

- [ ] **Step 2: Run the traversal test and verify RED**

Run `swift test --filter DumpAxTabsTest`.

Expected: compilation fails because the reader protocol, result type, limits, and `dumpAxTabs` do not exist.

- [ ] **Step 3: Implement the smallest generic traversal that passes the group test**

Create the types named above. The walker must:

```text
enqueue root at path []
read AXRole and AXChildren from each dequeued node
when role == AXTabGroup, build a group snapshot
enqueue children breadth-first in their original order
summarize relationship elements and correlate them by Node equality
sort attribute and action names
emit visitedNodeCount, truncated, truncationReasons, groups, failureCount,
omittedFailureCount, and capped failures
```

Group snapshots use these exact keys: `path`, `windowId`, `role`, `subrole`, `title`, `identifier`, `description`, `value`, `attributeNames`, `actionNames`, `tabs`, `selectedChildren`, and `children`. Referenced/direct element snapshots use `childIndex`, `windowId`, `role`, `subrole`, `title`, `identifier`, `description`, `value`, `selected`, `attributeNames`, and `actionNames`. Missing optional values encode as `.null`.

- [ ] **Step 4: Run the traversal test and verify GREEN**

Run `swift test --filter DumpAxTabsTest` and expect the nested group test to pass.

- [ ] **Step 5: Add failing edge-case tests one behavior at a time**

Add and run each test before implementing its behavior:

```swift
func testNoTabGroupReturnsEmptyGroups()
func testRecordsAttributeAndActionFailuresWithoutAborting()
func testDoesNotVisitAnElementTwiceInACycle()
func testReportsDepthLimitOnlyWhenChildrenRemain()
func testStopsAtNodeLimit()
func testKeepsUnmatchedAXTabsWithNullChildIndex()
func testTruncatesUnknownScalarDescriptionsAt512Characters()
```

Use small literal fixtures: a two-node cycle, `maxDepth: 1`, `maxNodes: 2`, one injected `attributeUnsupported` failure, and a 513-character unknown value. Run `swift test --filter DumpAxTabsTest/<test-name>` after adding each test and confirm it fails for the named missing behavior.

- [ ] **Step 6: Implement each edge behavior and keep the class GREEN**

Represent a failure as:

```swift
[
    "path": .array(path.map(Json.int)),
    "operation": .string(operation),
    "attribute": .stringOrNull(attribute),
    "error": .string(error),
]
```

Deduplicate truncation reasons. Sort failures lexicographically by path, operation, attribute, and error. Preserve group breadth-first order and direct-child order. Skip already visited nodes. Treat `noValue` and `attributeUnsupported` from traversal `AXChildren` reads as leaves without recording failures. Cap failure details at 20 while retaining total and omitted counts. Cap fallback textual descriptions at 512 characters and append an explicit truncation marker.

- [ ] **Step 7: Add the live AX reader and verify compilation**

Wrap `AXUIElement` in a hashable node using `CFEqual` and `CFHash`. Implement reads with `AXUIElementCopyAttributeNames`, `AXUIElementCopyActionNames`, and `AXUIElementCopyAttributeValue`. Convert strings, booleans, and integer-like values to `Json`; summarize other values with the bounded fallback. Convert relationship values to one or more wrapped AX elements and report symbolic `AXError.repr` failures.

Run:

```bash
swift test --filter DumpAxTabsTest
swift build
```

Expected: all traversal tests pass and both application targets compile.

- [ ] **Step 8: Commit the traversal**

```bash
git add Sources/AppBundle/util/dumpAxTabs.swift Sources/AppBundle/util/dumpAxRecursive.swift Sources/AppBundleTests/DumpAxTabsTest.swift
git commit -m "Add bounded AX tab traversal"
```

### Task 3: Wire one-shot dumping to the selected window

**Files:**
- Modify: `Sources/AppBundle/tree/MacApp.swift`
- Modify: `Sources/AppBundle/tree/MacWindow.swift`
- Modify: `Sources/AppBundle/command/impl/DebugWindowsCommand.swift`
- Modify: `Sources/AppBundleTests/command/DebugWindowsCommandTest.swift`

**Interfaces:**
- Produces: `MacApp.dumpWindowAxTabInfo(windowId:_:) async throws -> [String: Json]`.
- Produces: `MacWindow.dumpAxTabInfo(_:) async throws -> [String: Json]`.
- Produces: tab JSON output containing `Aero.axWindowId`, `Aero.App.appBundleId`, `Aero.App.pid`, and `Aero.AXTabDump`.
- Consumes: `DebugWindowsMode.tabs(UInt32?)`, `CmdArgs.resolveTargetOrReportError`, `Window.get(byId:)`, and `dumpAxTabs(_:)`.

- [ ] **Step 1: Add a failing routing invariant test**

Extend `testModeSelection` to assert that `.tabs(nil)` and `.tabs(42)` are distinct from `.interactive` and `.window(42)`. This fails if the command's mode enum or precedence is collapsed during integration.

- [ ] **Step 2: Implement the MacApp and MacWindow entry points**

Use the existing AX-thread pattern:

```swift
func dumpWindowAxTabInfo(windowId: UInt32, _ cm: CancellationMode) async throws -> [String: Json] {
    try await withWindow(windowId, cm) { window, job in
        dumpAxTabs(window)
    } ?? [:]
}
```

Forward from `MacWindow.dumpAxTabInfo` just as `dumpAxInfo` forwards today.

- [ ] **Step 3: Implement one-shot command target resolution and formatting**

For `.tabs(windowId)`:

- If an ID is present, use `Window.get(byId:)` and preserve the existing not-found error wording.
- Otherwise call `args.resolveTargetOrReportError(env, io)` and require `target.windowOrNil`.
- Require a `MacWindow`; otherwise return the existing `bugPrompt` failure.
- Call a new `dumpWindowTabDebugInfo` formatter with `.nonCancellable`.
- Print the pretty JSON, then the existing disclaimer, and return success.
- Return before the interactive-state switch, so tab mode cannot change recording state.

The formatter emits:

```swift
[
    "Aero.axWindowId": .int(window.windowId),
    "Aero.App.appBundleId": .stringOrNull(window.app.rawAppBundleId),
    "Aero.App.pid": .int(Int(window.app.pid)),
    "Aero.AXTabDump": .dict(try await window.dumpAxTabInfo(cm)),
]
```

Encode and prefix the result using the same encoder and `<bundle-id>.<window-id> ||| ` convention as the existing dump.

- [ ] **Step 4: Run command and traversal tests**

Run:

```bash
swift test --filter DebugWindowsCommandTest
swift test --filter DumpAxTabsTest
```

Expected: both classes pass.

- [ ] **Step 5: Commit command integration**

```bash
git add Sources/AppBundle/tree/MacApp.swift Sources/AppBundle/tree/MacWindow.swift Sources/AppBundle/command/impl/DebugWindowsCommand.swift Sources/AppBundleTests/command/DebugWindowsCommandTest.swift
git commit -m "Expose native tabs in debug-windows"
```

### Task 4: Document, generate, and verify the POC

**Files:**
- Modify: `docs/aerospace-debug-windows.adoc`
- Modify: `grammar/commands-bnf-grammar.txt`
- Regenerate: `Sources/Common/cmdHelpGenerated.swift`
- Regenerate: `xcode/AeroSpace.xcodeproj/project.pbxproj`
- Regenerate if changed: `Sources/Cli/subcommandDescriptionsGenerated.swift`
- Regenerate if changed: `Sources/Common/versionGenerated.swift`
- Regenerate if changed: `Sources/Common/gitHashGenerated.swift`

**Interfaces:**
- Documents: `aerospace debug-windows [--tabs] [--window-id <window-id>]` and the focused-window default.
- Consumes: `./generate.sh`, `./build-debug.sh`, `./swift-test.sh`, and `./lint.sh`.

- [ ] **Step 1: Update user-facing command documentation and grammar**

Change the synopsis and grammar to accept `--tabs` and add this option text:

```text
--tabs::
Print a bounded Accessibility hierarchy report focused on native macOS tab groups.
Without `--window-id`, inspect the currently focused window.
This option is one-shot and does not start or stop interactive recording.
```

- [ ] **Step 2: Regenerate checked-in files**

Run `./generate.sh`. Review the diff and retain only generated changes caused by the new source file and command synopsis.

- [ ] **Step 3: Run fresh verification**

Run, in order:

```bash
swift test --filter DebugWindowsCommandTest
swift test --filter DumpAxTabsTest
./build-debug.sh -Xswiftc -warnings-as-errors
./swift-test.sh
./lint.sh
git diff --check
```

Run `./test.sh` as an additional integration check. Its final dirty-tree guard is expected to return 1 while implementation changes and the pre-existing untracked `dev-docs/native-tabs.md` are present; confirm all preceding build, test, format, lint, generation, and unused-code phases pass before that guard.

- [ ] **Step 4: Review requirements and final diff**

Confirm every global constraint and design success criterion against the diff. Confirm no changes to window discovery, layout, events, private APIs, or the existing generic `dumpAxRecursive` behavior beyond making `AXError.repr` reusable.

- [ ] **Step 5: Commit documentation and generated files**

```bash
git add docs/aerospace-debug-windows.adoc grammar/commands-bnf-grammar.txt Sources/Common/cmdHelpGenerated.swift xcode/AeroSpace.xcodeproj/project.pbxproj Sources/Cli/subcommandDescriptionsGenerated.swift Sources/Common/versionGenerated.swift Sources/Common/gitHashGenerated.swift
git commit -m "Document debug-windows tab diagnostics"
```

- [ ] **Step 6: Verify committed branch state**

Run `git status --short --branch` and `git log --oneline --decorate -5`. The only untracked path should be the pre-existing `dev-docs/native-tabs.md`; all POC changes should be committed on `gcsecsey/debug-windows-tabs-poc`.
