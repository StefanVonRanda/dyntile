import Foundation

/// dyntile's config is a flat, line-oriented file: `key = value` and `#` comments.
/// No sections, no TOML dependency, and every error names its line number.
struct Config {
    var innerGap: CGFloat = 8
    var outerGap: CGFloat = 8
    var layouts: [LayoutKind] = [.tall, .bsp, .monocle]
    var defaultLayout: LayoutKind = .tall
    var mainRatio: CGFloat = 0.55
    var mainCount: Int = 1
    var resizeStep: CGFloat = 0.03
    var focusFollowsMouse = false
    var mouseFollowsFocus = false
    /// What a mouse drag of a tiled window does on release.
    var mouseDrag: MouseDrag = .swap
    /// Whether resizing a tiled window by its edge adjusts the split it sits on.
    var mouseResize = true
    var verbose = false
    var floatBundleIDs: [String] = []
    var floatTitlePatterns: [NSRegularExpression] = []
    /// `bind` lines left over from older versions. Shortcuts now live in shortcuts.conf;
    /// these are skipped rather than rejected, so an old config still loads.
    var ignoredBinds = 0
    var path: String?

    enum MouseDrag: String { case swap, off }

    static var defaultPath: String {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".config")
        return (base as NSString).appendingPathComponent("dyntile/dyntile.conf")
    }

    func shouldFloat(bundleID: String, title: String) -> Bool {
        if floatBundleIDs.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame }) {
            return true
        }
        let range = NSRange(title.startIndex..., in: title)
        return floatTitlePatterns.contains { $0.firstMatch(in: title, range: range) != nil }
    }

    /// Parse a config file. Missing file yields the defaults, which are usable as-is.
    static func load(path: String) throws -> Config {
        var config = Config()
        config.path = path
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return config
        }

        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let lineNo = index + 1
            var line = rawLine
            if let hash = line.firstIndex(of: "#") { line = String(line[line.startIndex..<hash]) }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            guard let eq = line.firstIndex(of: "=") else {
                throw ConfigError("\(path):\(lineNo): expected 'key = value'")
            }
            let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)

            do {
                if key.lowercased().hasPrefix("bind ") {
                    config.ignoredBinds += 1
                } else {
                    try config.set(key: key.lowercased().replacingOccurrences(of: ".", with: "-"),
                                   value: value)
                }
            } catch let error as ConfigError {
                throw ConfigError("\(path):\(lineNo): \(error.description)")
            }
        }

        if !config.layouts.contains(config.defaultLayout) {
            config.defaultLayout = config.layouts.first ?? .tall
        }
        return config
    }

    private mutating func set(key: String, value: String) throws {
        func number() throws -> CGFloat {
            guard let d = Double(value) else { throw ConfigError("'\(key)' needs a number, got '\(value)'") }
            return CGFloat(d)
        }
        func flag() throws -> Bool {
            switch value.lowercased() {
            case "true", "yes", "on", "1": return true
            case "false", "no", "off", "0": return false
            default: throw ConfigError("'\(key)' needs true or false, got '\(value)'")
            }
        }

        switch key {
        case "gaps-inner", "inner-gap": innerGap = max(0, try number())
        case "gaps-outer", "outer-gap": outerGap = max(0, try number())
        case "gaps":
            let g = max(0, try number()); innerGap = g; outerGap = g
        case "main-ratio": mainRatio = min(max(try number(), 0.1), 0.9)
        case "main-count": mainCount = max(1, Int(try number()))
        case "resize-step": resizeStep = min(max(try number(), 0.005), 0.5)
        case "focus-follows-mouse": focusFollowsMouse = try flag()
        case "mouse-follows-focus": mouseFollowsFocus = try flag()
        case "verbose": verbose = try flag()
        case "mouse-resize":
            switch value.lowercased() {
            case "ratio", "true", "yes", "on", "1": mouseResize = true
            case "off", "false", "no", "0": mouseResize = false
            default: throw ConfigError("'mouse-resize' expects ratio|off, got '\(value)'")
            }
        case "mouse-drag":
            guard let m = MouseDrag(rawValue: value.lowercased()) else {
                throw ConfigError("'mouse-drag' expects swap|off, got '\(value)'")
            }
            mouseDrag = m
        case "layouts":
            let names = value.split(whereSeparator: { $0 == "," || $0 == " " }).map {
                String($0).trimmingCharacters(in: .whitespaces).lowercased()
            }
            var parsed: [LayoutKind] = []
            for name in names where !name.isEmpty {
                guard let kind = LayoutKind(rawValue: name) else {
                    throw ConfigError("unknown layout '\(name)' (known: \(LayoutKind.allNames))")
                }
                if !parsed.contains(kind) { parsed.append(kind) }
            }
            guard !parsed.isEmpty else { throw ConfigError("'layouts' is empty") }
            layouts = parsed
        case "default-layout":
            guard let kind = LayoutKind(rawValue: value.lowercased()) else {
                throw ConfigError("unknown layout '\(value)' (known: \(LayoutKind.allNames))")
            }
            defaultLayout = kind
        case "float-app":
            floatBundleIDs.append(value)
        case "float-title":
            guard let re = try? NSRegularExpression(pattern: value) else {
                throw ConfigError("'float-title' is not a valid regex: \(value)")
            }
            floatTitlePatterns.append(re)
        default:
            throw ConfigError("unknown setting '\(key)'")
        }
    }
}
