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
        configTests()
        keyTests()
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
        tree.reconcile(with: [1, 2, 3, 4], focused: nil)
        check(Set(tree.windows) == Set([1, 2, 3, 4]), "bsp holds \(tree.windows)")

        let work = area.insetBy(dx: 20, dy: 20)
        var frames = tree.frames(in: area, params: params())
        check(frames.count == 4, "bsp produced \(frames.count) frames")
        disjoint(Array(frames.values), within: work, "bsp/4")

        // Removing a window frees its space for its sibling; the rest keep their shape.
        tree.reconcile(with: [1, 2, 4], focused: 2)
        frames = tree.frames(in: area, params: params())
        check(frames.count == 3 && frames[3] == nil, "bsp kept a removed window")
        disjoint(Array(frames.values), within: work, "bsp/3")

        // Insertion splits the focused leaf, so the new window lands beside it.
        tree.reconcile(with: [1, 2, 4, 9], focused: 1)
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

        // Emptying and refilling must not leave stale nodes behind.
        tree.reconcile(with: [], focused: nil)
        check(tree.windows.isEmpty, "bsp left \(tree.windows) after emptying")
        tree.reconcile(with: [7], focused: nil)
        check(tree.frames(in: area, params: params())[7]!.equalTo(work),
              "a lone bsp window should fill the work area")
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
            check(config.binds.count == 2, "expected 2 binds, got \(config.binds.count)")
            check(config.binds.last?.commands == [.reload, .retile], "chained commands not parsed")
            check(config.shouldFloat(bundleID: "com.apple.SystemPreferences", title: ""),
                  "float-app should match case-insensitively")
            check(config.shouldFloat(bundleID: "x", title: "Picture in Picture"),
                  "float-title regex should match")
            check(!config.shouldFloat(bundleID: "x", title: "Notes"), "float-title over-matched")
        }

        // A config with no binds at all keeps the built-in keymap.
        withTempConfig("gaps = 0\n") { path in
            let config = try Config.load(path: path)
            check(!config.binds.isEmpty, "default binds should survive a config with no binds")
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
        withTempConfig("bind alt-nope = focus left\n") { path in
            do {
                _ = try Config.load(path: path)
                check(false, "unknown key was accepted")
            } catch let error as ConfigError {
                check(error.description.contains("unknown key"), "wrong error: \(error.description)")
            }
        }
        withTempConfig("bind alt-h = teleport left\n") { path in
            do {
                _ = try Config.load(path: path)
                check(false, "unknown command was accepted")
            } catch let error as ConfigError {
                check(error.description.contains("unknown command"), "wrong error: \(error.description)")
            }
        }

        // A missing file is not an error: the defaults are a working setup.
        do {
            let config = try Config.load(path: "/nonexistent/dyntile.conf")
            check(!config.binds.isEmpty, "missing config should fall back to default binds")
        } catch {
            check(false, "missing config threw \(error)")
        }

        // Every default binding must parse as a real key combination.
        for bind in Config.defaultBinds() {
            check((try? Keycodes.parse(bind.spec)) != nil, "default bind '\(bind.spec)' does not parse")
        }
        // ...and no two defaults may claim the same combination.
        let specs = Config.defaultBinds().compactMap { try? Keycodes.parse($0.spec) }
            .map { "\($0.mods)-\($0.keyCode)" }
        check(Set(specs).count == specs.count, "default binds contain a duplicate combination")
    }

    // MARK: - Keys and commands

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
    }

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
