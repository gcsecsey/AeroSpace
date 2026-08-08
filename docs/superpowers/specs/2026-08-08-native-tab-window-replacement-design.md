# Native Tab Window Replacement Design

## Goal

Prevent a native macOS tab transition from adding another AeroSpace tile. The active physical window ID may change when a tab opens or becomes selected, but the logical AeroSpace window must keep its workspace, tree slot, weight, and cached layout state.

## Scope

This change only reconciles the active physical window ID. It does not model inactive tabs, expose tab commands, or try to map every tab to a WindowServer ID.

## Positive evidence

A transition is eligible only when all of these are true:

- the focused AX window contains an `AXTabGroup` whose `AXTabs` attribute has at least two elements;
- the app's previously focused window ID is a different, currently managed window from the same app;
- a fresh Core Graphics on-screen inventory contains the new ID but not the previous ID; and
- the old and new AX frames match within a small tolerance.

If any evidence is absent or ambiguous, AeroSpace keeps its existing behavior. In particular, switching between two visible windows of the same app must not merge them.

## Reconciliation

Before ordinary new-window registration, replace the previous `MacWindow` with the focused `MacWindow` in the exact tree slot. Preserve adaptive weight, floating size, fullscreen/layout flags, cached physical and virtual layout rectangles, and hidden-window position state. A replacement is the same logical window, so it must not run `on-window-detected` again.

The old AX object may remain in the application's AX cache because inactive Finder tabs remain valid AX windows. Only the AeroSpace tree and `MacWindow` ID map are reconciled.

## Tests

- AX detection requires a multi-tab `AXTabGroup`.
- A positive transition selects the previous off-screen ID only when frames match.
- Missing AX evidence, an on-screen previous ID, or mismatched frames does not replace anything.
- Tree replacement preserves the nested slot, adaptive weight, and cached window layout state.

## Non-goals

- Cleaning up every inactive tab already registered before this fix.
- Guessing when the previous focused window is unavailable.
- App-specific allowlists or private macOS APIs.
