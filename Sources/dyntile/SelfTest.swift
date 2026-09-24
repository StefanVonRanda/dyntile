import Foundation
import CoreGraphics

/// `dyntile --selftest` exercises the pure logic — layout maths, the BSP tree, the
/// config parser — in process. It lives in the binary rather than an XCTest bundle so
/// it runs anywhere Swift builds, including a machine with only the Command Line Tools.
enum SelfTest {
    private nonisolated(unsafe) static var failures: [String] = []
    private nonisolated(unsafe) static var checks = 0

    static func run() -> Int32 {
        layoutTests()
        bspTests()
        dragTests()
        configTests()
        keyTests()
        shortcutTests()
        commandTests()

        if failures.isEmpty {
            print("selftest: \(checks) checks passed")
            return 0
        }
        for failure in failures { print("FAIL \(failure)") }
        print("selftest: \(failures.count) of \(checks) checks failed")
        return 1
    }

    // MARK: - Harness

    private static func check(_ condition: Bool, _ message: @autoclosure () -> String,
                              line: Int = #line) {
        checks += 1
        if !condition { failures.append("line \(line): \(message())") }
    }

    private static func near(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 1.5,
                             _ label: String, line: Int = #line) {
        check(abs(a - b) <= tolerance, "\(label): \(a) != \(b)", line: line)
    }

    private static func disjoint(_ rects: [CGRect], within bounds: CGRect,
                                 _ label: String, line: Int = #line) {
        let slack = bounds.insetBy(dx: -2, dy: -2)
        for rect in rects {
            check(slack.contains(rect), "\(label): \(rect) escapes \(bounds)", line: line)
            check(rect.width > 0 && rect.height > 0, "\(label): empty tile \(rect)", line: line)
        }
        for (i, a) in rects.enumerated() {
            for b in rects.dropFirst(i + 1) {
                let overlap = a.intersection(b)
                check(overlap.isNull || overlap.width < 1 || overlap.height < 1,
                      "\(label): \(a) overlaps \(b)", line: line)
            }
        }
    }

    // MARK: - Layouts

    private static let area = CGRect(x: 0, y: 0, width: 1600, height: 1000)

    private static func params(ratio: CGFloat = 0.5, main: Int = 1,
                               inner: CGFloat = 10, outer: CGFloat = 20) -> LayoutParams {
        LayoutParams(mainRatio: ratio, mainCount: main, innerGap: inner, outerGap: outer)
    }

    private static func layoutTests() {
        let work = area.insetBy(dx: 20, dy: 20)

        // Equal splits keep their gaps and stay inside the strip.
        let columns = Layout.split(area, into: 4, gap: 10, vertical: true)
        check(columns.count == 4, "split returned \(columns.count) columns")
        near(columns.first!.minX, area.minX, 1, "first column starts at the edge")
        near(columns.last!.maxX, area.maxX, 1, "last column ends at the edge")
        for (a, b) in zip(columns, columns.dropFirst()) {
            near(b.minX - a.maxX, 10, 1, "inter-column gap")
        }
        disjoint(columns, within: area, "columns")

        // A lone window gets the whole work area.
        let single = Layout.frames(kind: .tall, count: 1, area: area, params: params())
        check(single.count == 1 && single[0].equalTo(work), "single window should fill \(work)")

        // Main ratio applies to the main column only.
        let three = Layout.frames(kind: .tall, count: 3, area: area, params: params(ratio: 0.6))
        check(three.count == 3, "tall/3 returned \(three.count)")
        near(three[0].width, (work.width - 10) * 0.6, 1.5, "main column width")
        near(three[0].height, work.height, 1.5, "main column height")
        near(three[1].minX, three[2].minX, 1, "stack windows share a column")
        disjoint(three, within: work, "tall/3")

        // With every window in main, the ratio is irrelevant.
        let allMain = Layout.frames(kind: .tall, count: 3, area: area, params: params(main: 3))
        for rect in allMain { near(rect.width, work.width, 1.5, "full-width main stack") }
        disjoint(allMain, within: work, "tall/all-main")

        // Wide is tall rotated a quarter turn.
        let wide = Layout.frames(kind: .wide, count: 4, area: area, params: params(ratio: 0.6))
        near(wide[0].width, work.width, 1.5, "wide main row spans the width")
        near(wide[0].height, (work.height - 10) * 0.6, 1.5, "wide main row height")
        disjoint(wide, within: work, "wide/4")

        // Every layout must place every window, at every count.
        for kind in LayoutKind.allCases where kind != .bsp {
            for count in 1...12 {
                let rects = Layout.frames(kind: kind, count: count, area: area, params: params())
                check(rects.count == count, "\(kind.rawValue)/\(count) returned \(rects.count)")
                if kind != .monocle && kind != .float {
                    disjoint(rects, within: work, "\(kind.rawValue)/\(count)")
                }
            }
        }

        // Monocle gives everyone the same rect.
        let monocle = Layout.frames(kind: .monocle, count: 3, area: area, params: params())
        check(monocle.allSatisfy { $0.equalTo(work) }, "monocle should stack on the work area")

        // A pathologically small display must not produce negative tiles.
        let tiny = Layout.frames(kind: .tall, count: 3,
                                 area: CGRect(x: 0, y: 0, width: 30, height: 30), params: params())
        check(tiny.count == 3 && tiny.allSatisfy { $0.width >= 0 && $0.height >= 0 },
              "degenerate area produced \(tiny)")
    }

    // MARK: - BSP

    private static func bspTests() {
        let tree = BSPTree()
        tree.reconcile(with: [1, 2, 3, 4], focused: nil, area: area, params: params())
        check(Set(tree.windows) == Set([1, 2, 3, 4]), "bsp holds \(tree.windows)")

        let work = area.insetBy(dx: 20, dy: 20)
        var frames = tree.frames(in: area, params: params())
        check(frames.count == 4, "bsp produced \(frames.count) frames")
        disjoint(Array(frames.values), within: work, "bsp/4")

        // Removing a window frees its space for its sibling; the rest keep their shape.
        tree.reconcile(with: [1, 2, 4], focused: 2, area: area, params: params())
        frames = tree.frames(in: area, params: params())
        check(frames.count == 3 && frames[3] == nil, "bsp kept a removed window")
        disjoint(Array(frames.values), within: work, "bsp/3")

        // Insertion splits the focused leaf, so the new window lands beside it.
        tree.reconcile(with: [1, 2, 4, 9], focused: 1, area: area, params: params())
        frames = tree.frames(in: area, params: params())
        check(frames[9] != nil, "bsp dropped the inserted window")
        let one = frames[1]!, nine = frames[9]!
        check(one.intersects(nine.insetBy(dx: -12, dy: -12)),
              "new window \(nine) should neighbour the focused one \(one)")
        disjoint(Array(frames.values), within: work, "bsp/insert")

        // Swapping exchanges positions, not shapes.
        let before = tree.frames(in: area, params: params())
        tree.swap(1, 4)
        let after = tree.frames(in: area, params: params())
        check(after[1]!.equalTo(before[4]!) && after[4]!.equalTo(before[1]!), "bsp swap failed")

        // Resizing moves the focused window's share of its parent split.
        let width = tree.frames(in: area, params: params())[1]!.width
        tree.resize(1, by: 0.1)
        let grown = tree.frames(in: area, params: params())[1]!
        check(grown.width > width || grown.height > area.insetBy(dx: 20, dy: 20).height * 0.5,
              "resize did not grow window 1 (\(width) -> \(grown.width))")

        // Ratios clamp, so a wall of resize presses can never zero a window out.
        for _ in 0..<50 { tree.resize(1, by: 0.1) }
        let clamped = tree.frames(in: area, params: params())
        disjoint(Array(clamped.values), within: work, "bsp/clamped")
        check(clamped.values.allSatisfy { $0.width > 1 && $0.height > 1 },
              "resize clamping let a window collapse")

        // Splits follow the shape of the leaf being split, from the very first window:
        // a wide area splits into columns, and each of those splits into rows.
        let axis = BSPTree()
        axis.reconcile(with: [1, 2], focused: nil, area: area, params: params())
        var two = axis.frames(in: area, params: params())
        check(two[1]!.width < work.width * 0.6 && two[1]!.height > work.height * 0.9,
              "a wide area should split into columns, got \(two[1]!)")
        axis.reconcile(with: [1, 2, 3], focused: 2, area: area, params: params())
        let three = axis.frames(in: area, params: params())
        check(three[2]!.height < work.height * 0.6 && three[3]!.height < work.height * 0.6,
              "a tall column should split into rows, got \(three[2]!) / \(three[3]!)")
        disjoint(Array(three.values), within: work, "bsp/axis")

        // The same holds the other way round on a portrait display.
        let portrait = CGRect(x: 0, y: 0, width: 1000, height: 1600)
        let tallTree = BSPTree()
        tallTree.reconcile(with: [1, 2], focused: nil, area: portrait, params: params())
        two = tallTree.frames(in: portrait, params: params())
        check(two[1]!.height < portrait.height * 0.6 && two[1]!.width > portrait.width * 0.9,
              "a tall area should split into rows, got \(two[1]!)")

        // Emptying and refilling must not leave stale nodes behind.
        tree.reconcile(with: [], focused: nil, area: area, params: params())
        check(tree.windows.isEmpty, "bsp left \(tree.windows) after emptying")
        tree.reconcile(with: [7], focused: nil, area: area, params: params())
        check(tree.frames(in: area, params: params())[7]!.equalTo(work),
              "a lone bsp window should fill the work area")
    }

    // MARK: - Resizing by hand

    /// A window dragged by its edge must end up exactly where it was dropped, not
    /// snapped back and not approximately right.
    private static func dragTests() {
        let work = area.insetBy(dx: 20, dy: 20)
        let gap: CGFloat = 10

        func twoUp() -> BSPTree {
            let tree = BSPTree()
            tree.reconcile(with: [1, 2], focused: nil, area: area, params: params())
            _ = tree.frames(in: area, params: params())
            return tree
        }

        // Dragging the main window's right edge outward.
        var tree = twoUp()
        var before = tree.frames(in: area, params: params())[1]!
        var dropped = CGRect(x: before.minX, y: before.minY,
                             width: 1080, height: before.height)   // right edge to x=1100
        tree.applyManualResize(1, from: before, to: dropped, gap: gap)
        var after = tree.frames(in: area, params: params())
        near(after[1]!.maxX, dropped.maxX, 1.5, "right-edge drag should land where dropped")
        near(after[2]!.minX, dropped.maxX + gap, 1.5, "the neighbour should close the gap")
        disjoint(Array(after.values), within: work, "drag/right-edge")

        // Dragging the *stack* window's left edge moves the same boundary.
        tree = twoUp()
        before = tree.frames(in: area, params: params())[2]!
        dropped = CGRect(x: 905, y: before.minY, width: before.maxX - 905, height: before.height)
        tree.applyManualResize(2, from: before, to: dropped, gap: gap)
        after = tree.frames(in: area, params: params())
        near(after[2]!.minX, 905, 1.5, "left-edge drag should land where dropped")
        near(after[1]!.maxX, 905 - gap, 1.5, "the main window should follow the boundary")

        // A vertical drag on a tree with no horizontal split must change nothing.
        tree = twoUp()
        before = tree.frames(in: area, params: params())[1]!
        let heights = tree.frames(in: area, params: params()).mapValues(\.height)
        tree.applyManualResize(1, from: before,
                               to: CGRect(x: before.minX, y: before.minY,
                                          width: before.width, height: before.height - 200),
                               gap: gap)
        after = tree.frames(in: area, params: params())
        check(after.allSatisfy { heights[$0.key] == $0.value.height },
              "a vertical drag with no horizontal split should be ignored")

        // Deeper trees: the edge belongs to the ancestor that actually owns it.
        let deep = BSPTree()
        deep.reconcile(with: [1, 2, 3], focused: 2, area: area, params: params())
        var frames = deep.frames(in: area, params: params())
        let two = frames[2]!
        deep.applyManualResize(2, from: two,
                               to: CGRect(x: two.minX, y: two.minY,
                                          width: two.width, height: two.height - 150), gap: gap)
        frames = deep.frames(in: area, params: params())
        near(frames[2]!.maxY, two.maxY - 150, 1.5, "nested bottom-edge drag")
        near(frames[3]!.minY, two.maxY - 150 + gap, 1.5, "nested neighbour should follow")
        disjoint(Array(frames.values), within: work, "drag/nested")

        // Dragging a window almost off the screen must not collapse its neighbour.
        tree = twoUp()
        before = tree.frames(in: area, params: params())[1]!
        tree.applyManualResize(1, from: before,
                               to: CGRect(x: before.minX, y: before.minY,
                                          width: 5, height: before.height), gap: gap)
        after = tree.frames(in: area, params: params())
        check(after.values.allSatisfy { $0.width > 100 }, "ratio clamp let a tile collapse: \(after)")

        // The same mapping for the main/stack boundary of the stacking layouts.
        near(Layout.ratio(forBoundary: work.minX + 0.75 * (work.width - gap), work: work,
                          gap: gap, vertical: true), 0.75, 0.001, "main ratio from a boundary")
        near(Layout.ratio(forBoundary: work.minY + 0.4 * (work.height - gap), work: work,
                          gap: gap, vertical: false), 0.4, 0.001, "wide ratio from a boundary")
        near(Layout.ratio(forBoundary: work.minX - 5000, work: work, gap: gap, vertical: true),
             0.1, 0.001, "main ratio clamps low")
        near(Layout.ratio(forBoundary: work.maxX + 5000, work: work, gap: gap, vertical: true),
             0.9, 0.001, "main ratio clamps high")

        // Round-trip: a tall layout resized by hand reproduces the dropped edge.
        let boundary = work.minX + 900
        let ratio = Layout.ratio(forBoundary: boundary, work: work, gap: gap, vertical: true)
        let tall = Layout.frames(kind: .tall, count: 3, area: area,
                                 params: params(ratio: ratio, inner: gap))
        near(tall[0].maxX, boundary, 1.5, "tall should reproduce the hand-dragged boundary")

        splitDragTests(work: work, gap: gap)
    }

    /// `columns`, `rows` and `grid` keep a hand-dragged edge the same way.
    private static func splitDragTests(work: CGRect, gap: CGFloat) {
        func layout(_ kind: LayoutKind, _ count: Int, _ weights: SplitWeights) -> [CGRect] {
            var p = params(inner: gap)
            p.weights = weights
            return Layout.frames(kind: kind, count: count, area: area, params: p)
        }
        func drag(_ kind: LayoutKind, _ count: Int, _ index: Int, _ weights: SplitWeights = .init(),
                  _ reshape: (CGRect) -> CGRect) -> (before: [CGRect], after: [CGRect], SplitWeights) {
            let before = layout(kind, count, weights)
            let fresh = Layout.resizeTile(kind: kind, count: count, index: index, from: before[index],
                                          to: reshape(before[index]), work: work, gap: gap,
                                          weights: weights)
            return (before, layout(kind, count, fresh), fresh)
        }

        // Unset weights reproduce the old equal split exactly.
        let equal = Layout.frames(kind: .columns, count: 3, area: area, params: params(inner: gap))
        check(equal == Layout.split(work, into: 3, gap: gap, vertical: true),
              "unweighted columns should be an equal split")

        // Middle column, right edge out to x=1100: only it and its right neighbour change.
        var (before, after, weights) = drag(.columns, 3, 1) { r in
            CGRect(x: r.minX, y: r.minY, width: 1100 - r.minX, height: r.height)
        }
        near(after[1].maxX, 1100, 1.5, "columns right-edge drag should land where dropped")
        near(after[2].minX, 1100 + gap, 1.5, "the right neighbour should close the gap")
        check(after[0] == before[0], "a column not touching the edge moved: \(before[0]) -> \(after[0])")
        near(after[2].maxX, work.maxX, 1, "the last column should still end at the edge")
        disjoint(after, within: work, "columns/drag")

        // Its left edge moves the boundary on the other side.
        (before, after, weights) = drag(.columns, 3, 1, weights) { r in
            CGRect(x: 400, y: r.minY, width: r.maxX - 400, height: r.height)
        }
        near(after[1].minX, 400, 1.5, "columns left-edge drag should land where dropped")
        near(after[0].maxX, 400 - gap, 1.5, "the left neighbour should follow")
        near(after[1].maxX, 1100, 1.5, "the earlier drag should survive")

        // Opening a window keeps the dragged sizes in proportion instead of resetting them.
        let four = layout(.columns, 4, weights)
        check(four[1].width > four[0].width, "a new window reset the columns: \(four)")
        disjoint(four, within: work, "columns/grown")

        // A drag against the screen edge has no neighbour to push, so nothing changes.
        (before, after, _) = drag(.columns, 3, 0) { r in
            CGRect(x: r.minX + 50, y: r.minY, width: r.width - 50, height: r.height)
        }
        check(after == before, "an outer edge drag should snap back")

        // Rows are the same thing on the other axis.
        (_, after, _) = drag(.rows, 3, 0) { r in
            CGRect(x: r.minX, y: r.minY, width: r.width, height: 450 - r.minY)
        }
        near(after[0].maxY, 450, 1.5, "rows bottom-edge drag should land where dropped")
        near(after[1].minY, 450 + gap, 1.5, "the row below should close the gap")
        disjoint(after, within: work, "rows/drag")

        // Grid: a corner drag moves the column boundary and the row boundary together,
        // and the other column's rows stay as they were.
        (before, after, _) = drag(.grid, 4, 0) { r in
            CGRect(x: r.minX, y: r.minY, width: 1000 - r.minX, height: 300 - r.minY)
        }
        near(after[0].maxX, 1000, 1.5, "grid right edge")
        near(after[0].maxY, 300, 1.5, "grid bottom edge")
        near(after[1].minY, 300 + gap, 1.5, "the tile below should follow")
        near(after[2].minX, 1000 + gap, 1.5, "the next column should follow")
        near(after[2].height, before[2].height, 1, "the other column's rows should not move")
        disjoint(after, within: work, "grid/drag")

        // Dragging a tile nearly shut is clamped, as tall's ratio is.
        (_, after, _) = drag(.columns, 2, 0) { r in
            CGRect(x: r.minX, y: r.minY, width: 5, height: r.height)
        }
        check(after.allSatisfy { $0.width > 100 }, "columns clamp let a tile collapse: \(after)")

        // The resize command grows the focused tile on every axis it can.
        let grown = layout(.grid, 4, Layout.growTile(kind: .grid, count: 4, index: 3, by: 0.1,
                                                      weights: .init()))
        let plain = layout(.grid, 4, .init())
        check(grown[3].width > plain[3].width + 50 && grown[3].height > plain[3].height + 50,
              "resize grow should enlarge the grid tile: \(plain[3]) -> \(grown[3])")
        disjoint(grown, within: work, "grid/grow")
        var shrunk = SplitWeights()
        for _ in 0..<50 {
            shrunk = Layout.growTile(kind: .rows, count: 3, index: 1, by: -0.1, weights: shrunk)
        }
        check(layout(.rows, 3, shrunk).allSatisfy { $0.height > 10 },
              "repeated shrinks should clamp, not collapse the row")
    }

    // MARK: - Config

    private static func withTempConfig(_ text: String, _ body: (String) throws -> Void) {
        let path = NSTemporaryDirectory() + "dyntile-selftest-\(UUID().uuidString).conf"
        defer { try? FileManager.default.removeItem(atPath: path) }
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            try body(path)
        } catch let error as ConfigError {
            failures.append("config: \(error.description)")
            checks += 1
        } catch {
            failures.append("config: \(error)")
            checks += 1
        }
    }

    private static func configTests() {
        withTempConfig("""
        # comment
        gaps-inner = 4
        gaps.outer = 12          # dots and dashes are both fine
        main-ratio = 0.7
        layouts = bsp, monocle
        default-layout = bsp
        float-app = com.apple.systempreferences
        float-title = ^Picture in Picture$
        bind alt-shift-h = move left
        bind ctrl-cmd-r = reload ; retile
        """) { path in
            let config = try Config.load(path: path)
            check(config.innerGap == 4 && config.outerGap == 12, "gaps parsed as \(config.innerGap)/\(config.outerGap)")
            check(config.mainRatio == 0.7, "main-ratio parsed as \(config.mainRatio)")
            check(config.layouts == [.bsp, .monocle], "layouts parsed as \(config.layouts)")
            check(config.ignoredBinds == 2, "expected 2 ignored binds, got \(config.ignoredBinds)")
            check(config.shouldFloat(bundleID: "com.apple.SystemPreferences", title: ""),
                  "float-app should match case-insensitively")
            check(config.shouldFloat(bundleID: "x", title: "Picture in Picture"),
                  "float-title regex should match")
            check(!config.shouldFloat(bundleID: "x", title: "Notes"), "float-title over-matched")
        }

        // Leftover binds from an old config load, even ones that never parsed.
        withTempConfig("bind alt-nope = teleport left\ngaps = 0\n") { path in
            let config = try Config.load(path: path)
            check(config.ignoredBinds == 1 && config.innerGap == 0, "old bind line broke the config")
        }

        // Errors must name the offending line.
        withTempConfig("gaps-inner = 4\nnonsense = 1\n") { path in
            do {
                _ = try Config.load(path: path)
                check(false, "unknown setting was accepted")
            } catch let error as ConfigError {
                check(error.description.contains(":2:"), "error should cite line 2: \(error.description)")
            }
        }
        // A missing file is not an error: the defaults are a working setup.
        do {
            let config = try Config.load(path: "/nonexistent/dyntile.conf")
            check(config.layouts == Config().layouts, "missing config should yield the defaults")
        } catch {
            check(false, "missing config threw \(error)")
        }

    }

    // MARK: - Keys and shortcuts

    private static func keyTests() {
        guard let parsed = try? Keycodes.parse("alt-shift-h") else {
            check(false, "alt-shift-h did not parse"); return
        }
        check(parsed.keyCode == 4, "h should be keycode 4, got \(parsed.keyCode)")
        check(parsed.mods == UInt32(2048 | 512), "alt-shift mask wrong: \(parsed.mods)")
        check((try? Keycodes.parse("CMD+Alt+K")) != nil, "separators and case should be flexible")
        check((try? Keycodes.parse("alt-kc:36"))?.keyCode == 36, "raw keycode escape hatch broken")
        check((try? Keycodes.parse("hyper-x")) == nil, "unknown modifier should fail")
        check((try? Keycodes.parse("")) == nil, "empty spec should fail")

        // `mod` is whatever the modifier is set to.
        let ctrlAlt = UInt32(4096 | 2048)
        check((try? Keycodes.parse("mod-shift-h", mod: ctrlAlt))?.mods == ctrlAlt | 512,
              "mod should expand to the configured modifier")
        check((try? Keycodes.parseModifiers("ctrl-alt")) == ctrlAlt, "ctrl-alt modifier parse")
        check((try? Keycodes.parseModifiers("fn")) == nil, "fn alone cannot be the modifier")

        // Writing a recorded combination back out, relative to the modifier.
        check(Keycodes.spec(keyCode: 4, mods: ctrlAlt | 512, mod: ctrlAlt) == "mod-shift-h",
              "spec should use mod: \(Keycodes.spec(keyCode: 4, mods: ctrlAlt | 512, mod: ctrlAlt))")
        check(Keycodes.spec(keyCode: 36, mods: 256, mod: 2048) == "cmd-enter",
              "spec without the modifier should spell it out")
        for code: UInt32 in [0, 36, 44, 123, 96, 999] {
            let spec = Keycodes.spec(keyCode: code, mods: 2048, mod: 2048)
            check((try? Keycodes.parse(spec))?.keyCode == code, "spec '\(spec)' does not round-trip")
        }
    }

    private static func shortcutTests() {
        // Every default must parse, and no two may claim the same combination.
        let defaults = Shortcuts()
        check(defaults.resolved.count == Shortcuts.defaults.filter { $0.spec != nil }.count,
              "a default shortcut does not parse")
        let combos = defaults.resolved.map { "\($0.mods)-\($0.keyCode)" }
        check(Set(combos).count == combos.count, "default shortcuts contain a duplicate combination")
        check(defaults.modifier == 2048, "the default modifier should be alt")
        check(defaults.text.split(separator: "\n").filter { !$0.hasPrefix("#") } == ["modifier = alt"],
              "an untouched keymap should save as just the modifier:\n\(defaults.text)")

        withTempConfig("""
            # comment
            modifier = ctrl-alt
            focus left = mod-y
            Float Toggle = none
            exec open -na Ghostty = mod-shift-enter
            reload; retile = mod-r
            """) { path in
            let s = try Shortcuts.load(path: path)
            check(s.modifier == UInt32(4096 | 2048), "modifier parsed as \(s.modifier)")
            func spec(_ name: String) -> String?? {
                s.entries.first { $0.name.lowercased() == name }.map(\.spec)
            }
            check(spec("focus left") == .some("mod-y"), "rebind lost")
            check(spec("float toggle") == .some(nil), "'none' should turn a default off (matched by command)")
            check(spec("exec open -na ghostty") == .some("mod-shift-enter"), "exec shortcut lost")
            check(s.entries.last?.commands == [.reload, .retile], "chained commands not parsed")
            check(s.resolved.first { $0.name == "focus left" }?.mods == UInt32(4096 | 2048),
                  "mod should resolve to ctrl-alt")

            // Saving and loading again gives the same keymap.
            try s.text.write(toFile: path, atomically: true, encoding: .utf8)
            let again = try Shortcuts.load(path: path)
            check(again.entries.map(\.spec) == s.entries.map(\.spec) && again.modifier == s.modifier,
                  "shortcuts do not round-trip:\n\(s.text)")
        }

        withTempConfig("focus left = alt-nope\n") { path in
            do {
                _ = try Shortcuts.load(path: path)
                check(false, "unknown key was accepted")
            } catch let error as ConfigError {
                check(error.description.contains(":1:") && error.description.contains("unknown key"),
                      "wrong error: \(error.description)")
            }
        }
        withTempConfig("teleport left = mod-h\n") { path in
            do {
                _ = try Shortcuts.load(path: path)
                check(false, "unknown command was accepted")
            } catch let error as ConfigError {
                check(error.description.contains("unknown command"), "wrong error: \(error.description)")
            }
        }
    }

    // MARK: - Commands

    private static func commandTests() {
        let cases: [(String, Command)] = [
            ("focus left", .focusDirection(.left)),
            ("focus next", .focusNext),
            ("move down", .moveDirection(.down)),
            ("move main", .moveMain),
            ("layout next", .layoutNext),
            ("layout monocle", .layoutSet("monocle")),
            ("resize grow", .resize(grow: true)),
            ("main inc", .mainCount(delta: 1)),
            ("float toggle", .floatToggle),
            ("gaps toggle", .gapsToggle),
            ("display move next", .displayMove(next: true)),
            ("display focus prev", .displayFocus(next: false)),
            ("reload", .reload),
            ("exec open -a Ghostty", .exec("open -a Ghostty")),
        ]
        for (text, expected) in cases {
            let parsed = try? Command.parse(text)
            check(parsed == expected, "'\(text)' parsed as \(String(describing: parsed))")
        }
        for bad in ["focus sideways", "layout spiral", "resize", "display move", "exec", ""] {
            check((try? Command.parse(bad)) == nil, "'\(bad)' should not parse")
        }
    }
}
