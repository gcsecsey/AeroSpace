import AppKit
import Common

struct NativeTabWindowIds {
    private var inactive: Set<UInt32> = []
    var requiresOnScreenWindowSnapshot: Bool { !inactive.isEmpty }

    mutating func didReplace(_ oldWindowId: UInt32, with focusedWindowId: UInt32) {
        inactive.insert(oldWindowId)
        inactive.remove(focusedWindowId)
    }

    mutating func didFocus(_ windowId: UInt32) {
        inactive.remove(windowId)
    }

    mutating func modelWindowIds(
        from aliveWindowIds: [UInt32],
        deadWindowIds: [UInt32],
        onScreenWindowIds: Set<UInt32>? = nil,
    ) -> [UInt32] {
        inactive.subtract(Set(deadWindowIds).subtracting(aliveWindowIds))
        if let onScreenWindowIds {
            inactive.subtract(Set(aliveWindowIds).intersection(onScreenWindowIds))
        }
        return aliveWindowIds.filter { !inactive.contains($0) }
    }
}

@MainActor
func isEligibleNativeTabReplacementWindow(_ window: Window, on focusedWorkspace: Workspace) -> Bool {
    guard let windowWorkspace = window.nodeWorkspace,
          windowWorkspace === focusedWorkspace
    else {
        return false
    }
    return switch window.windowParentCases {
        case .tilingContainer, .floatingWindowsContainer: true
        case .unbound, .macosMinimizedWindowsContainer, .macosHiddenAppsWindowsContainer,
             .macosFullscreenWindowsContainer, .macosPopupWindowsContainer: false
    }
}

@MainActor
func replaceNativeTabWindowInTree(_ oldWindow: Window, with replacement: Window) {
    check(oldWindow !== replacement)
    resetClosedWindowsCache()
    if replacement.isBound {
        replacement.unbindFromParent()
    }
    let bindingData = oldWindow.unbindFromParent()

    replacement.lastFloatingSize = oldWindow.lastFloatingSize
    replacement.isFullscreen = oldWindow.isFullscreen
    replacement.noOuterGapsInFullscreen = oldWindow.noOuterGapsInFullscreen
    replacement.layoutReason = oldWindow.layoutReason
    replacement.lastAppliedLayoutVirtualRect = oldWindow.lastAppliedLayoutVirtualRect
    replacement.lastAppliedLayoutPhysicalRect = oldWindow.lastAppliedLayoutPhysicalRect
    replacement.bind(
        to: bindingData.parent,
        adaptiveWeight: bindingData.adaptiveWeight,
        index: bindingData.index,
    )
}

func hasNativeWindowTabs(_ root: AXUIElement) -> Bool {
    hasNativeWindowTabs(
        root: root,
        role: { $0.get(Ax.roleAttr) },
        tabs: { readAxElements($0, attribute: kAXTabsAttribute) },
        children: { readAxElements($0, attribute: kAXChildrenAttribute) },
    )
}

func hasNativeWindowTabs<Node: Hashable>(
    root: Node,
    maxNodes: Int = 100,
    role: (Node) -> String?,
    tabs: (Node) -> [Node],
    children: (Node) -> [Node],
) -> Bool {
    guard maxNodes > 0 else { return false }
    var queue = [root]
    var scheduled: Set<Node> = [root]
    var nextIndex = 0

    while nextIndex < queue.count {
        let node = queue[nextIndex]
        nextIndex += 1
        if role(node) == kAXTabGroupRole, tabs(node).count >= 2 {
            return true
        }

        for child in children(node) where !scheduled.contains(child) {
            guard scheduled.count < maxNodes else { break }
            scheduled.insert(child)
            queue.append(child)
        }
    }
    return false
}

private func readAxElements(_ node: AXUIElement, attribute: String) -> [AXUIElement] {
    var raw: AnyObject?
    guard unsafe AXUIElementCopyAttributeValue(node, attribute as CFString, &raw) == .success,
          let raw
    else {
        return []
    }
    let values = raw as? [AnyObject] ?? [raw]
    return values.compactMap {
        CFGetTypeID($0) == AXUIElementGetTypeID()
            ? ($0 as! AXUIElement)
            : nil
    }
}

extension Rect {
    func isApproximatelyEqual(to other: Rect) -> Bool {
        let tolerance = CGFloat(2)
        return abs(topLeftX - other.topLeftX) <= tolerance &&
            abs(topLeftY - other.topLeftY) <= tolerance &&
            abs(width - other.width) <= tolerance &&
            abs(height - other.height) <= tolerance
    }
}
