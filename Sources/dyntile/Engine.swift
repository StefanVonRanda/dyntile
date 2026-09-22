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

    func scheduleRetile(reason: String) {
        pendingRetile?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Log.debug("retile: \(reason)")
            self?.retile()
        }
        pendingRetile = work
        // Coalesce bursts (an app opening five windows at launch) into one pass.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
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
                outerGap: st.gapsEnabled ? config.outerGap : 0)

            if st.layout == .bsp {
                st.tree.reconcile(with: windows, focused: lastFocused[key])
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

        wm.apply(frames)
        if let focused = wm.focused, let space = currentSpace(), space.windows.contains(focused.id) {
            lastFocused[space.key] = focused.id
            // Monocle hides everything behind the focused window; keep it on top.
            if state(space.key).layout == .monocle { focused.element.raise() }
        }
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
            if st.layout == .bsp {
                guard let focused else { return "error: no focused window" }
                st.tree.resize(focused.id, by: delta)
            } else {
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

    /// Called on left-mouse-up. If the user dragged a tiled window, swap it with
    /// whatever tiled window is under the cursor; otherwise just snap the layout back.
    func handleDragEnd(at point: CGPoint) {
        guard tilingEnabled, config.mouseDrag == .swap else { retile(); return }
        guard let dragged = wm.takeUserMovedWindow(), let space = currentSpace(),
              space.windows.contains(dragged) else { retile(); return }
        if let target = topWindow(at: point, among: space.windows, excluding: dragged) {
            swap(dragged, target, in: space, state: state(space.key))
        } else {
            retile()
        }
    }

    private func topWindow(at point: CGPoint, among candidates: [WindowID],
                           excluding: WindowID) -> WindowID? {
        let allowed = Set(candidates).subtracting([excluding])
        for id in allowed {
            guard let frame = wm.windows[id]?.frame else { continue }
            if frame.contains(point) { return id }
        }
        return nil
    }
}

extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
