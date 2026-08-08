# Native Tab Window Replacement Implementation Plan

> Execute test-first. Each production change follows a test observed failing for the intended reason.

**Goal:** Keep one AeroSpace tile across positively identified native macOS tab ID changes.

**Architecture:** Detect multi-tab AX evidence on the focused window, combine it with a fresh on-screen ID snapshot and matching old/new AX frames, then replace the old `MacWindow` in place before ordinary registration.

---

### Task 1: Add native-tab evidence tests

**Files:**
- Modify: `Sources/AppBundleTests/DumpAxTabsTest.swift`
- Modify: `Sources/AppBundle/util/dumpAxTabs.swift`

1. Add tests proving a two-tab `AXTabGroup` is positive and a one-tab group is not.
2. Run the focused test and observe the missing detector failure.
3. Add the smallest bounded breadth-first detector using the existing AX reader.
4. Re-run the focused test.

### Task 2: Add conservative transition-decision tests

**Files:**
- Create: `Sources/AppBundleTests/tree/NativeTabWindowReplacementTest.swift`
- Modify: `Sources/AppBundle/tree/MacWindow.swift`

1. Add literal test cases for the positive transition and the three negative safeguards: no tab evidence, previous ID still on screen, and mismatched frames.
2. Run the focused test and observe the missing decision failure.
3. Implement the pure decision helper and re-run the test.

### Task 3: Add tree-replacement tests

**Files:**
- Modify: `Sources/AppBundleTests/tree/NativeTabWindowReplacementTest.swift`
- Modify: `Sources/AppBundle/tree/MacWindow.swift`

1. Add a test with a nested tiling container proving exact slot, adaptive weight, floating size, fullscreen flags, and cached layout rectangles survive replacement.
2. Run the focused test and observe the old/new nodes occupying separate slots.
3. Implement the smallest in-place tree replacement helper and re-run the test.

### Task 4: Wire live reconciliation

**Files:**
- Modify: `Sources/AppBundle/tree/MacApp.swift`
- Modify: `Sources/AppBundle/tree/MacWindow.swift`
- Modify: `Sources/AppBundle/windowLevelCache.swift`

1. Read multi-tab evidence with the focused AX element.
2. Build a fresh Core Graphics on-screen ID set.
3. Evaluate the decision against the previous same-app managed window and AX frames.
4. Pass the single confirmed replacement ID into `MacWindow.getOrRegister`.
5. Replace the old map/tree entry before ordinary registration and skip `on-window-detected` for replacements.

### Task 5: Verify

1. Run the focused AX and replacement test classes.
2. Run `./test.sh`.
3. Run `git diff --check` and inspect the final diff for scope.
4. Rebuild the debug app and perform a live Finder tab open/switch check.
5. Request a code review and address actionable findings.
