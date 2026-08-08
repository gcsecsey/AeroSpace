# `debug-windows --tabs` POC design

Date: 2026-08-08

## Context

AeroSpace's existing `debug-windows` output deliberately omits `AXChildren` and
`AXChildrenInNavigationOrder` because recursively printing them makes ordinary
window reports too large. That omission also hides native macOS tab structures,
including `AXTabGroup` and its `AXTabButton` descendants.

Before changing AeroSpace's window-management behavior, we need a focused,
repeatable way to observe what applications expose through the public
Accessibility API. The proposed proof of concept adds a one-shot tab inspection
mode to `debug-windows` without changing the existing general-purpose dump.

## Goals

- Inspect the focused window's Accessibility subtree for native tab structures
  with one command.
- Allow selecting a known AeroSpace-managed window by window ID.
- Capture enough raw evidence to compare native AppKit applications and
  applications with custom tab implementations.
- Make unsupported attributes and traversal truncation visible rather than
  silently treating missing data as an empty value.
- Keep the POC isolated from normal window discovery, event handling, and layout
  behavior.

## Non-goals

- Do not change how AeroSpace classifies, manages, or lays out windows.
- Do not merge several native tabs into one logical AeroSpace tile.
- Do not observe tab-selection events over time.
- Do not use hit-testing, Core Graphics window inventories, ScreenCaptureKit,
  private SkyLight APIs, or application-specific adapters.
- Do not promise a stable machine-readable interface. `debug-windows` remains a
  diagnostic command covered by its existing instability disclaimer.

## Command-line behavior

Add a boolean `--tabs` flag to `DebugWindowsCmdArgs`.

| Invocation | Behavior |
| --- | --- |
| `aerospace debug-windows` | Preserve the existing start/stop interactive recording session. |
| `aerospace debug-windows --window-id 123` | Preserve the existing one-shot general window dump. |
| `aerospace debug-windows --tabs` | Produce one tab-focused dump for the currently focused target window, then exit. |
| `aerospace debug-windows --tabs --window-id 123` | Produce one tab-focused dump for managed window `123`, then exit. |

When both flags are present, `--window-id` selects the target and `--tabs`
selects the dump format. Without `--window-id`, the command resolves the target
through the existing focused-target mechanism. If there is no focused window,
or an explicit window ID cannot be found, the command fails with the same style
of user-facing error as the existing command.

Tab mode is always one-shot. It must not start, stop, read, or clear the global
interactive recording state.

## Recommended implementation

Implement a dedicated tab dumper rather than adding an exception to
`dumpAxRecursive`.

The current generic dumper is useful precisely because it suppresses large,
cyclic child graphs. Giving it a mode flag would couple two different output
contracts and make future changes to either one riskier. A separate helper such
as `dumpAxTabInfo.swift` can traverse children intentionally, enforce its own
bounds, and emit a compact tab-specific representation.

The command obtains the selected `MacWindow`, then asks its `MacApp` to run the
Accessibility traversal in the same execution context used by the existing AX
dump. The command wraps the result with basic target context and prints it using
the existing pretty JSON encoder and window-prefix convention. It also prints
the existing `debug-windows` disclaimer.

The top-level diagnostic object is:

```text
Aero.axWindowId
Aero.App.appBundleId
Aero.App.pid
Aero.AXTabDump
  visitedNodeCount
  truncated
  truncationReasons
  groups
  failureCount
  omittedFailureCount
  failures
```

`Aero.AXTabDump.groups` is an array because a window may expose no tab group,
one tab group, or nested/multiple groups. An empty array is a successful result:
it means the bounded traversal did not find an element whose role is
`AXTabGroup`.

## Traversal

Start at the selected window's `AXUIElement`. Traverse `AXChildren` in
breadth-first order while preserving child order within each depth. This makes
window chrome observable before large document contents such as Finder file
rows consume the node budget. Use child-index paths such as `[0, 2, 1]` to
identify where a discovered group lives beneath the window root.

Apply both of these hard bounds:

- Maximum depth: 12 edges below the window root.
- Maximum visited elements: 500, including the root.

Stop descending a branch at the depth limit and stop the complete traversal at
the node limit. Set `truncated` to `true` and add a human-readable reason for
each reached bound. Keep a best-effort set of already visited AX elements to
avoid repeatedly traversing a cycle; the node limit remains the final safety
guard.

A non-leaf failure to read `AXChildren` from one element is recorded and does
not abort other branches. `noValue` and `attributeUnsupported` are ordinary
leaf results for the traversal relationship and are not recorded as failures;
other AX errors remain diagnostic failures.

## Captured tab evidence

For every element whose `AXRole` equals `AXTabGroup`, capture:

- its child-index `path` from the window root;
- containing window ID, when available;
- role, subrole, title, identifier, description, and value, when exposed;
- the names of all attributes advertised by the element;
- the names of all actions advertised by the element;
- summaries of values returned by `AXTabs` and `AXSelectedChildren`, when those
  attributes are advertised or readable;
- ordered summaries of its direct `AXChildren`.

For each referenced tab or direct child, capture:

- child index when it is a direct child;
- role, subrole, title, identifier, description, value, and selected state;
- containing window ID, when available;
- advertised attribute names;
- advertised action names.

AX elements returned by `AXTabs` or `AXSelectedChildren` should be correlated
with direct children when Accessibility element equality permits it. The output
records the matching child index; unmatched elements still receive their own
summary. This preserves evidence from applications whose tab relationship is
not represented only by `AXChildren`.

Scalar AX values use the existing `Json` representation where possible. AX
elements are summarized; they are never recursively expanded as attribute
values. Unknown values fall back to a textual description capped at 512
characters, with truncation made explicit, so a single attribute cannot create
an unbounded dump. Preserve group and child traversal order, but sort advertised
attribute names, action names, and failure records to keep otherwise equivalent
reports easy to compare.

## Failure representation

Accessibility failures are data in this diagnostic mode. Each failure records:

- the child-index path of the element being inspected;
- the operation, such as listing attributes, reading `AXChildren`, reading
  `AXTabs`, or listing actions;
- the relevant attribute name, when applicable;
- the symbolic `AXError` value.

A per-attribute failure must not abort the whole dump. Failure to access the
selected root window is fatal and follows the existing `debug-windows` bug
prompt path.

To keep reports usable for large accessibility trees, the dump includes the
total failure count but emits at most 20 sorted failure details. It reports how
many details were omitted. This bound affects only diagnostics, not traversal
or tab-group discovery.

## Code organization

Expected changes are intentionally narrow:

- Add `--tabs` parsing to `DebugWindowsCmdArgs`.
- Add tab-mode routing and output formatting to `DebugWindowsCommand`.
- Add a dedicated AX tab traversal/normalization helper under
  `Sources/AppBundle`.
- Add a `MacApp`/`MacWindow` entry point if needed to preserve current AX thread
  and cancellation conventions.
- Update generated command help inputs, shell grammar, and the
  `aerospace-debug-windows` manual page.
- Add focused parser and traversal tests.

The traversal logic should depend on a small internal reader abstraction rather
than calling every AX function directly from the tree-walking algorithm. The
production reader wraps `AXUIElement`; tests use synthetic elements. This keeps
the ordering, correlation, limit, cycle, and failure behavior testable without
requiring Accessibility permission or a particular foreground application.

## Testing

Automated tests should cover:

- parsing `--tabs` by itself and together with `--window-id`;
- preserving the existing modes when `--tabs` is absent;
- a direct `AXTabGroup` with ordered tab buttons and one selected button;
- a tab group nested beneath ordinary AX containers;
- no tab group;
- `AXTabs` or `AXSelectedChildren` containing elements not present in direct
  children;
- unsupported attributes and per-node AX failures;
- a cyclic graph;
- depth-limit and node-limit truncation;
- stable breadth-first ordering of groups, plus stable ordering of children,
  attributes, actions, and failures;
- ordinary leaf `AXChildren` results do not create failure noise;
- failure totals remain accurate when detail snapshots are capped.

Manual validation should run the built command against at least one native
AppKit-tabbed window and one non-tabbed window. The report should confirm that
the tabbed window exposes useful group/button evidence, the non-tabbed window
returns `groups: []`, and the existing two `debug-windows` modes still behave as
before.

## Licensing boundary

The implementation will be written independently from Apple's public
Accessibility APIs, AeroSpace's existing abstractions, and observations captured
with this diagnostic tool. AltTab's investigation may inform which facts to
verify, but no GPL-licensed AltTab implementation code will be copied or adapted
into AeroSpace's MIT-licensed source tree.

## Success criteria

The POC is successful when a contributor can run
`aerospace debug-windows --tabs` on a native tabbed application and receive a
bounded report that identifies any exposed `AXTabGroup`, its tab-like elements,
selection evidence, advertised relationships, window IDs, actions, and AX
failures. It must do so without changing AeroSpace's window-management behavior
or the existing `debug-windows` workflows.
