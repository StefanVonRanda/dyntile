import Foundation
import AppKit
import CoreGraphics

/// Identifies one native Space on one display. dyntile keeps layout state per key, so
/// each desktop remembers its own layout, ratio and main count — without ever creating,
/// naming or switching Spaces itself.
struct SpaceKey: Hashable {
    let display: String
    let space: UInt64
}

final class SpaceState {
    var layout: LayoutKind
    var mainRatio: CGFloat
    var mainCount: Int
    var gapsEnabled = true
    /// Hand-dragged tile sizes for `columns`, `rows` and `grid`, kept per layout so
    /// switching away and back restores them.
    var weights: [LayoutKind: SplitWeights] = [:]
    let tree = BSPTree()

    init(config: Config) {
        layout = config.defaultLayout
        mainRatio = config.mainRatio
        mainCount = config.mainCount
    }
}

final class Engine {
    private let wm: WindowManager
    private var config: Config
    private var states: [SpaceKey: SpaceState] = [:]
    private var lastFocused: [SpaceKey: WindowID] = [:]
    private(set) var tilingEnabled = true
    private var pendingRetile: DispatchWorkItem?
    /// The frames dyntile last computed, i.e. the tile geometry. Drop targets are
    /// hit-tested against this rather than against live window frames, which move
    /// around under the cursor mid-drag.
    private var lastFrames: [WindowID: CGRect] = [:]
    /// True from mouse-down to mouse-up. Nothing is retiled while it is set: a layout
    /// pass during a drag is what makes the window fight the cursor.
    private var mouseDown = false
    private var retileDeferredByDrag = false

    init(wm: WindowManager, config: Config) {
        self.wm = wm
        self.config = config
    }

    func update(config: Config) {
        self.config = config
        for state in states.values {
            if !config.layouts.contains(state.layout) { state.layout = config.defaultLayout }
        }
        retile()
    }

    // MARK: - Space model

    private func spaceKey(for display: Display, spaces: [String: UInt64]) -> SpaceKey {
        SpaceKey(display: display.uuid, space: spaces[display.uuid] ?? 0)
    }

    private func state(_ key: SpaceKey) -> SpaceState {
        if let existing = states[key] { return existing }
        let fresh = SpaceState(config: config)
        states[key] = fresh
        return fresh
    }

    /// The tileable windows of every visible space, grouped by space.
    private func visibleSpaces() -> [(key: SpaceKey, display: Display, windows: [WindowID])] {
        let onScreen = wm.onScreenIDs()
        let spaces = PrivateAPI.currentSpaceByDisplay()
        let displays = Display.all()
        guard !displays.isEmpty else { return [] }

        var buckets: [String: [WindowID]] = [:]
        for id in wm.order {
            guard onScreen.contains(id), let window = wm.windows[id], window.isTileable else { continue }
            guard !wm.isFloating(id) else { continue }
            let frame = window.frame
            // Assign by the display holding the window's centre, falling back to the
            // one with the largest overlap for windows straddling a bezel.
            let home = displays.first { $0.contains(frame) }
                ?? displays.max { a, b in
                    a.frame.intersection(frame).area < b.frame.intersection(frame).area
                }
            guard let home else { continue }
            buckets[home.uuid, default: []].append(id)
        }

        return displays.map { display in
            (spaceKey(for: display, spaces: spaces), display, buckets[display.uuid] ?? [])
        }
    }

    private func currentSpace() -> (key: SpaceKey, display: Display, windows: [WindowID])? {
        let spaces = visibleSpaces()
        if let focused = wm.focused, !wm.isFloating(focused.id),
           let match = spaces.first(where: { $0.windows.contains(focused.id) }) {
            return match
        }
        // No tiled window has focus: fall back to the display under the mouse.
        let point = AX.flip(CGRect(origin: NSEvent.mouseLocation, size: .zero)).origin
        return spaces.first { $0.display.frame.contains(point) } ?? spaces.first
    }

    // MARK: - Tiling

    /// Menu tracking and app switches can swallow the mouse-up that would have ended a
    /// drag. Rather than trust the event stream, confirm against the hardware state, so
    /// a missed event can never leave tiling frozen.
    private func syncMouseState() {
        if mouseDown && NSEvent.pressedMouseButtons & 1 == 0 { mouseDown = false }
    }

    /// Called from the reconcile timer: catches a drag whose mouse-up never arrived.
    func flushDeferredRetile() {
        syncMouseState()
        guard !mouseDown, retileDeferredByDrag else { return }
        retileDeferredByDrag = false
        retile()
    }

    func scheduleRetile(reason: String) {
        syncMouseState()
        guard !mouseDown else {
            // Hands off until the button comes up; handleDragEnd does the single pass.
            retileDeferredByDrag = true
            return
        }
        pendingRetile?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Log.debug("retile: \(reason)")
            self?.retile()
        }
        pendingRetile = work
        // Coalesce bursts (an app opening five windows at launch) into one pass. A window
        // being dragged by something other than the mouse — a trackpad three-finger drag,
        // an assistive device — never raises mouseDown, so give those longer to settle.
        let delay = reason == "window moved by user" ? 0.35 : 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func retile() {
        guard tilingEnabled else { return }
        var frames: [WindowID: CGRect] = [:]

        for (key, display, windows) in visibleSpaces() {
            let st = state(key)
            guard st.layout.tiles, !windows.isEmpty else { continue }
            let params = LayoutParams(
                mainRatio: st.mainRatio,
                mainCount: st.mainCount,
                innerGap: st.gapsEnabled ? config.innerGap : 0,
                outerGap: st.gapsEnabled ? config.outerGap : 0,
                weights: st.weights[st.layout] ?? SplitWeights())

            if st.layout == .bsp {
                st.tree.reconcile(with: windows, focused: lastFocused[key],
                                  area: display.visibleFrame, params: params)
                for (id, rect) in st.tree.frames(in: display.visibleFrame, params: params) {
                    frames[id] = rect
                }
            } else {
                let rects = Layout.frames(kind: st.layout, count: windows.count,
                                          area: display.visibleFrame, params: params)
                for (index, id) in windows.enumerated() where index < rects.count {
                    frames[id] = rects[index]
                }
            }
        }

        lastFrames = frames
        wm.apply(frames)
        if let focused = wm.focused, let space = currentSpace(), space.windows.contains(focused.id) {
            lastFocused[space.key] = focused.id
            // Monocle hides everything behind the focused window; keep it on top.
            if state(space.key).layout == .monocle { focused.element.raise() }
        }
    }

    /// Set the layout of the desktop the user is looking at. Unlike the `layout <name>`
    /// command this never toggles back, because picking the checked item in a menu
    /// should be a no-op rather than a switch to something else.
    @discardableResult
    func setLayout(_ kind: LayoutKind) -> String {
        guard let space = currentSpace() else { return "error: no display" }
        state(space.key).layout = kind
        retile()
        return kind.rawValue
    }

    /// The layout of the desktop the user is looking at, for the menu bar item.
    var currentLayoutName: String {
        guard let space = currentSpace() else { return "—" }
        return state(space.key).layout.rawValue
    }

    func noteFocusChange() {
        guard let focused = wm.focused, let space = currentSpace() else { return }
        if space.windows.contains(focused.id) { lastFocused[space.key] = focused.id }
    }

    // MARK: - Commands

    @discardableResult
    func run(_ command: Command) -> String {
        switch command {
        case .quit:
            NSApp.terminate(nil)
            return "ok"
        case .exec(let line):
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", line]
            do { try task.run() } catch { return "error: \(error.localizedDescription)" }
            return "ok"
        case .reload:
            return reloadConfig()
        case .retile:
            wm.refresh(reason: "manual retile")
            retile()
            return "ok"
        case .query:
            return describe()
        case .tilingToggle:
            tilingEnabled.toggle()
            if tilingEnabled { retile() }
            return tilingEnabled ? "tiling on" : "tiling off"
        default:
            break
        }

        guard let space = currentSpace() else { return "error: no display" }
        let st = state(space.key)
        let focused = wm.focused

        switch command {
        case .focusNext, .focusPrev:
            guard let focused, let index = space.windows.firstIndex(of: focused.id) else {
                space.windows.first.flatMap { wm.windows[$0] }?.focus()
                return "ok"
            }
            let count = space.windows.count
            let step = (command == .focusNext) ? 1 : count - 1
            focus(wm.windows[space.windows[(index + step) % count]])

        case .focusDirection(let direction):
            guard let target = neighbour(of: focused, in: direction, within: space.windows) else {
                return "error: no window \(direction.rawValue)"
            }
            focus(wm.windows[target])

        case .moveNext, .movePrev:
            guard let focused, let index = space.windows.firstIndex(of: focused.id),
                  space.windows.count > 1 else { return "error: nothing to move" }
            let count = space.windows.count
            let step = (command == .moveNext) ? 1 : count - 1
            swap(focused.id, space.windows[(index + step) % count], in: space, state: st)

        case .moveDirection(let direction):
            guard let focused else { return "error: no focused window" }
            guard let target = neighbour(of: focused, in: direction, within: space.windows) else {
                return "error: no window \(direction.rawValue)"
            }
            swap(focused.id, target, in: space, state: st)

        case .moveMain:
            guard let focused, let first = space.windows.first, first != focused.id else {
                return "error: already main"
            }
            swap(focused.id, first, in: space, state: st)

        case .layoutNext, .layoutPrev:
            guard !config.layouts.isEmpty else { return "error: no layouts configured" }
            let index = config.layouts.firstIndex(of: st.layout) ?? 0
            let count = config.layouts.count
            let step = (command == .layoutNext) ? 1 : count - 1
            st.layout = config.layouts[(index + step) % count]
            retile()
            return st.layout.rawValue

        case .layoutSet(let name):
            guard let kind = LayoutKind(rawValue: name) else { return "error: unknown layout" }
            // Pressing the same layout key twice returns to the previous one, so a
            // single binding works as a monocle/zoom toggle.
            st.layout = (st.layout == kind) ? (config.layouts.first { $0 != kind } ?? kind) : kind
            retile()
            return st.layout.rawValue

        case .resize(let grow):
            let delta = grow ? config.resizeStep : -config.resizeStep
            switch st.layout {
            case .bsp:
                guard let focused else { return "error: no focused window" }
                st.tree.resize(focused.id, by: delta)
            case .columns, .rows, .grid:
                guard let focused, let index = space.windows.firstIndex(of: focused.id) else {
                    return "error: no focused window"
                }
                st.weights[st.layout] = Layout.growTile(
                    kind: st.layout, count: space.windows.count, index: index, by: delta,
                    weights: st.weights[st.layout] ?? SplitWeights())
            default:
                // Growing a stack window means shrinking the main area.
                let inMain = focused.map { space.windows.prefix(st.mainCount).contains($0.id) } ?? true
                st.mainRatio = min(max(st.mainRatio + (inMain ? delta : -delta), 0.1), 0.9)
            }
            retile()

        case .mainCount(let delta):
            st.mainCount = max(1, min(st.mainCount + delta, max(1, space.windows.count)))
            retile()
            return "main \(st.mainCount)"

        case .gaps(let delta):
            config.innerGap = max(0, config.innerGap + CGFloat(delta))
            config.outerGap = max(0, config.outerGap + CGFloat(delta))
            retile()
            return "gaps \(Int(config.innerGap))/\(Int(config.outerGap))"

        case .gapsToggle:
            st.gapsEnabled.toggle()
            retile()

        case .floatToggle:
            guard let focused else { return "error: no focused window" }
            wm.toggleFloat(focused.id)
            if wm.isFloating(focused.id) {
                // Give it something reasonable to land on instead of a tile-shaped window.
                let area = space.display.visibleFrame
                let size = CGSize(width: area.width * 0.6, height: area.height * 0.6)
                focused.element.setFrame(CGRect(
                    x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                    width: size.width, height: size.height))
                focused.element.raise()
            }
            retile()
            return wm.isFloating(focused.id) ? "floating" : "tiled"

        case .displayFocus(let next):
            guard let target = adjacentDisplay(to: space.display, next: next) else {
                return "error: single display"
            }
            let spaces = visibleSpaces()
            let key = spaceKey(for: target, spaces: PrivateAPI.currentSpaceByDisplay())
            let candidate = lastFocused[key]
                ?? spaces.first { $0.display.uuid == target.uuid }?.windows.first
            if let candidate, let window = wm.windows[candidate] {
                focus(window)
            } else {
                warpMouse(to: target.visibleFrame)
            }

        case .displayMove(let next):
            guard let focused else { return "error: no focused window" }
            guard let target = adjacentDisplay(to: space.display, next: next) else {
                return "error: single display"
            }
            // Drop it in the middle of the target display; the next pass tiles it there.
            let area = target.visibleFrame
            let frame = focused.frame
            focused.element.setFrame(CGRect(
                x: area.midX - frame.width / 2, y: area.midY - frame.height / 2,
                width: min(frame.width, area.width), height: min(frame.height, area.height)))
            st.tree.remove(focused.id)
            retile()
            focus(focused)

        default:
            return "error: unhandled command"
        }
        return "ok"
    }

    /// Human-readable dump of what dyntile currently sees. Also the answer to
    /// "why isn't this window being tiled?".
    private func describe() -> String {
        var lines: [String] = ["tiling: \(tilingEnabled ? "on" : "off")"]
        let current = currentSpace()?.key
        for (key, display, windows) in visibleSpaces() {
            let st = state(key)
            let marker = key == current ? "*" : " "
            lines.append(String(format: "%@ display %@  %.0fx%.0f  space %llu  layout %@  "
                                + "ratio %.2f  main %d", marker, String(display.uuid.prefix(8)),
                                display.visibleFrame.width, display.visibleFrame.height,
                                key.space, st.layout.rawValue, st.mainRatio, st.mainCount))
            for (index, id) in windows.enumerated() {
                guard let window = wm.windows[id] else { continue }
                let flag = wm.focused?.id == id ? ">" : " "
                lines.append("   \(flag) \(index). \(window.appName) — "
                             + "\(window.title.isEmpty ? "(untitled)" : window.title)")
            }
            let floats = wm.order.filter { wm.isFloating($0) }
                .compactMap { wm.windows[$0]?.appName }
            if !floats.isEmpty && key == current {
                lines.append("     floating: \(floats.joined(separator: ", "))")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private func swap(_ a: WindowID, _ b: WindowID,
                      in space: (key: SpaceKey, display: Display, windows: [WindowID]),
                      state st: SpaceState) {
        guard a != b, let ia = space.windows.firstIndex(of: a),
              let ib = space.windows.firstIndex(of: b) else { return }
        var windows = space.windows
        windows.swapAt(ia, ib)
        wm.reorder(windows)
        st.tree.swap(a, b)
        retile()
    }

    private func focus(_ window: ManagedWindow?) {
        guard let window else { return }
        window.focus()
        if config.mouseFollowsFocus { warpMouse(to: window.frame) }
        noteFocusChange()
    }

    private func warpMouse(to rect: CGRect) {
        guard rect.width > 0 else { return }
        CGWarpMouseCursorPosition(CGPoint(x: rect.midX, y: rect.midY))
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private func adjacentDisplay(to current: Display, next: Bool) -> Display? {
        let displays = Display.all()
        guard displays.count > 1, let index = displays.firstIndex(where: { $0.uuid == current.uuid })
        else { return nil }
        let step = next ? 1 : displays.count - 1
        return displays[(index + step) % displays.count]
    }

    /// Nearest window in `direction`, preferring ones that overlap on the other axis.
    private func neighbour(of focused: ManagedWindow?, in direction: Direction,
                           within windows: [WindowID]) -> WindowID? {
        guard let focused else { return windows.first }
        let origin = focused.frame
        var best: (id: WindowID, score: CGFloat)?

        for id in windows where id != focused.id {
            guard let candidate = wm.windows[id]?.frame else { continue }
            let dx = candidate.midX - origin.midX
            let dy = candidate.midY - origin.midY
            let along: CGFloat
            let across: CGFloat
            switch direction {
            case .left:  along = -dx; across = abs(dy)
            case .right: along = dx;  across = abs(dy)
            case .up:    along = -dy; across = abs(dx)   // AX y grows downward
            case .down:  along = dy;  across = abs(dx)
            }
            guard along > 1 else { continue }
            let overlaps = direction.isHorizontal
                ? origin.minY < candidate.maxY && candidate.minY < origin.maxY
                : origin.minX < candidate.maxX && candidate.minX < origin.maxX
            // Overlapping neighbours always win; the penalty is larger than any
            // plausible on-screen distance.
            let score = along + across * 0.5 + (overlaps ? 0 : 100_000)
            if best == nil || score < best!.score { best = (id, score) }
        }
        return best?.id
    }

    // MARK: - Config reload

    var onConfigReload: ((Config) -> Void)?

    private func reloadConfig() -> String {
        guard let path = config.path else { return "error: no config path" }
        do {
            let fresh = try Config.load(path: path)
            config = fresh
            Log.verbose = fresh.verbose
            for state in states.values where !fresh.layouts.contains(state.layout) {
                state.layout = fresh.defaultLayout
            }
            onConfigReload?(fresh)
            retile()
            return "reloaded \(path)"
        } catch {
            return "error: \(error)"
        }
    }

    // MARK: - Mouse drag

    func mouseDidGoDown() {
        mouseDown = true
        retileDeferredByDrag = false
    }

    /// Called on left-mouse-up. A drag that changed the window's *size* becomes a split
    /// ratio; a drag that changed its *position* swaps it with the tile it was dropped
    /// on. Anything else just releases the layout pass that was held during the drag.
    func handleDragEnd(at point: CGPoint) {
        guard mouseDown else { return }   // not our drag: a stray up, or one already handled
        mouseDown = false
        let deferred = retileDeferredByDrag
        retileDeferredByDrag = false

        guard tilingEnabled else { return }
        guard let dragged = wm.takeUserMovedWindow() else {
            if deferred { retile() }
            return
        }
        guard let space = currentSpace(), space.windows.contains(dragged),
              let before = lastFrames[dragged], let window = wm.windows[dragged] else {
            retile()
            return
        }

        let after = window.frame
        let resized = abs(after.width - before.width) > 4 || abs(after.height - before.height) > 4

        if resized {
            guard config.mouseResize else { retile(); return }
            applyManualResize(dragged, from: before, to: after, space: space, state: state(space.key))
        } else if config.mouseDrag == .swap,
                  let target = tile(at: point, among: space.windows, excluding: dragged) {
            swap(dragged, target, in: space, state: state(space.key))
            return
        }
        retile()
    }

    /// Fold a hand-resized window back into the layout's own parameters.
    private func applyManualResize(_ id: WindowID, from old: CGRect, to new: CGRect,
                                   space: (key: SpaceKey, display: Display, windows: [WindowID]),
                                   state st: SpaceState) {
        let inner = st.gapsEnabled ? config.innerGap : 0
        let outer = st.gapsEnabled ? config.outerGap : 0
        let work = space.display.visibleFrame.insetBy(dx: outer, dy: outer)

        switch st.layout {
        case .bsp:
            st.tree.applyManualResize(id, from: old, to: new, gap: inner)

        case .tall, .wide:
            // Only the boundary between the main area and the stack is adjustable here.
            let inMain = space.windows.prefix(st.mainCount).contains(id)
            let vertical = st.layout == .tall
            let boundary: CGFloat = inMain
                ? (vertical ? new.maxX : new.maxY)
                : (vertical ? new.minX : new.minY) - inner
            st.mainRatio = Layout.ratio(forBoundary: boundary, work: work,
                                        gap: inner, vertical: vertical)

        case .columns, .rows, .grid:
            guard let index = space.windows.firstIndex(of: id) else { break }
            st.weights[st.layout] = Layout.resizeTile(
                kind: st.layout, count: space.windows.count, index: index, from: old, to: new,
                work: work, gap: inner, weights: st.weights[st.layout] ?? SplitWeights())

        default:
            break   // monocle and float have no split to move
        }
    }

    /// The tile under a point. Uses the geometry of the last layout pass, so the window
    /// being dragged does not shadow the tile it is hovering over.
    private func tile(at point: CGPoint, among candidates: [WindowID],
                      excluding: WindowID) -> WindowID? {
        var best: (id: WindowID, area: CGFloat)?
        for id in candidates where id != excluding {
            guard let frame = lastFrames[id] ?? wm.windows[id]?.frame, frame.contains(point) else {
                continue
            }
            // Overlapping tiles only happen in monocle; prefer the smallest, which is
            // the most specific target.
            if best == nil || frame.area < best!.area { best = (id, frame.area) }
        }
        return best?.id
    }

}

extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
