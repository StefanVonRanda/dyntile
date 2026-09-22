import Foundation
import CoreGraphics

/// A binary space partition over one space's tiled windows.
///
/// New windows split the leaf that currently holds focus, along the longer axis of
/// that leaf, which is what makes the layout feel "dynamic" rather than fixed: the
/// shape of the tree follows where you were working. Ratios live on internal nodes
/// and survive insertions and removals elsewhere in the tree.
final class BSPTree {
    final class Node {
        var window: WindowID?
        var children: (Node, Node)?
        var ratio: CGFloat = 0.5
        var vertical: Bool = true       // true: children sit side by side
        weak var parent: Node?
        var lastFrame: CGRect = .zero

        init(window: WindowID?) { self.window = window }
        var isLeaf: Bool { children == nil }
    }

    private(set) var root: Node?

    var windows: [WindowID] {
        var out: [WindowID] = []
        func walk(_ n: Node?) {
            guard let n else { return }
            if let w = n.window { out.append(w) }
            if let (a, b) = n.children { walk(a); walk(b) }
        }
        walk(root)
        return out
    }

    func leaf(for window: WindowID) -> Node? {
        var found: Node?
        func walk(_ n: Node?) {
            guard let n, found == nil else { return }
            if n.isLeaf, n.window == window { found = n; return }
            if let (a, b) = n.children { walk(a); walk(b) }
        }
        walk(root)
        return found
    }

    /// Bring the tree in line with `desired`, splitting at `focused` for new windows.
    ///
    /// The layout area is needed here, not just in `frames`: a leaf picks its split axis
    /// from its own rectangle, so that rectangle has to be up to date *before* the
    /// insertion. Recomputing per insertion is cheap — a space holds a handful of windows.
    func reconcile(with desired: [WindowID], focused: WindowID?,
                   area: CGRect, params: LayoutParams) {
        let wanted = Set(desired)
        for existing in windows where !wanted.contains(existing) {
            remove(existing)
        }
        let present = Set(windows)
        for window in desired where !present.contains(window) {
            _ = frames(in: area, params: params)
            insert(window, near: focused)
        }
    }

    func insert(_ window: WindowID, near focused: WindowID?) {
        guard let root else {
            self.root = Node(window: window)
            return
        }
        let target = focused.flatMap { leaf(for: $0) } ?? rightmostLeaf(root)
        let moved = Node(window: target.window)
        let added = Node(window: window)
        moved.parent = target
        added.parent = target
        moved.lastFrame = target.lastFrame
        added.lastFrame = target.lastFrame
        // Split the long way, so tiles stay as square as the space allows.
        target.vertical = target.lastFrame.width >= target.lastFrame.height
        target.ratio = 0.5
        target.window = nil
        target.children = (moved, added)
    }

    func remove(_ window: WindowID) {
        guard let node = leaf(for: window) else { return }
        guard let parent = node.parent, let (a, b) = parent.children else {
            root = nil
            return
        }
        let sibling = (a === node) ? b : a
        // Collapse the parent into the surviving sibling, keeping the sibling's own shape.
        parent.window = sibling.window
        parent.children = sibling.children
        parent.ratio = sibling.ratio
        parent.vertical = sibling.vertical
        if let (c, d) = sibling.children { c.parent = parent; d.parent = parent }
    }

    func swap(_ a: WindowID, _ b: WindowID) {
        guard let na = leaf(for: a), let nb = leaf(for: b) else { return }
        (na.window, nb.window) = (nb.window, na.window)
    }

    /// Nudge the focused window's share of its parent split.
    func resize(_ window: WindowID, by delta: CGFloat) {
        guard let node = leaf(for: window), let parent = node.parent,
              let (first, _) = parent.children else { return }
        let signed = (first === node) ? delta : -delta
        parent.ratio = min(max(parent.ratio + signed, 0.1), 0.9)
    }

    /// Flip the split orientation of the focused window's parent.
    func rotate(_ window: WindowID) {
        guard let node = leaf(for: window), let parent = node.parent else { return }
        parent.vertical.toggle()
    }

    func frames(in area: CGRect, params: LayoutParams) -> [WindowID: CGRect] {
        var out: [WindowID: CGRect] = [:]
        guard let root else { return out }
        let rect = area.insetBy(dx: params.outerGap, dy: params.outerGap)
        func walk(_ node: Node, _ frame: CGRect) {
            node.lastFrame = frame
            if let window = node.window, node.isLeaf {
                out[window] = frame
                return
            }
            guard let (a, b) = node.children else { return }
            let (first, second) = Layout.cut(frame, ratio: node.ratio,
                                             gap: params.innerGap, vertical: node.vertical)
            walk(a, first)
            walk(b, second)
        }
        walk(root, rect)
        return out
    }

    private func rightmostLeaf(_ node: Node) -> Node {
        var current = node
        while let (_, b) = current.children { current = b }
        return current
    }
}
