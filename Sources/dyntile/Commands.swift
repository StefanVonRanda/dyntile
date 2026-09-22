import Foundation

struct ConfigError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

enum Direction: String {
    case left, right, up, down

    var isHorizontal: Bool { self == .left || self == .right }
    var opposite: Direction {
        switch self {
        case .left: return .right
        case .right: return .left
        case .up: return .down
        case .down: return .up
        }
    }
}

enum Command: Equatable {
    case focusDirection(Direction)
    case focusNext
    case focusPrev
    case moveDirection(Direction)
    case moveNext
    case movePrev
    case moveMain
    case layoutNext
    case layoutPrev
    case layoutSet(String)
    case resize(grow: Bool)
    case mainCount(delta: Int)
    case floatToggle
    case tilingToggle
    case gaps(delta: Int)
    case gapsToggle
    case displayFocus(next: Bool)
    case displayMove(next: Bool)
    case reload
    case retile
    case exec(String)
    case query
    case quit

    /// Parse one command string, e.g. "focus left", "layout tall", "exec open -a Ghostty".
    static func parse(_ raw: String) throws -> Command {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw ConfigError("empty command") }
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let verb = parts[0].lowercased()
        let arg = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        let lowerArg = arg.lowercased()

        func direction() throws -> Direction {
            guard let d = Direction(rawValue: lowerArg) else {
                throw ConfigError("'\(verb)' expects left|right|up|down, got '\(arg)'")
            }
            return d
        }

        switch verb {
        case "focus":
            switch lowerArg {
            case "next": return .focusNext
            case "prev", "previous": return .focusPrev
            default: return .focusDirection(try direction())
            }
        case "move", "swap":
            switch lowerArg {
            case "next": return .moveNext
            case "prev", "previous": return .movePrev
            case "main", "master": return .moveMain
            default: return .moveDirection(try direction())
            }
        case "layout":
            switch lowerArg {
            case "next", "": return .layoutNext
            case "prev", "previous": return .layoutPrev
            default:
                guard LayoutKind(rawValue: lowerArg) != nil else {
                    throw ConfigError("unknown layout '\(arg)' (known: \(LayoutKind.allNames))")
                }
                return .layoutSet(lowerArg)
            }
        case "resize":
            switch lowerArg {
            case "grow", "+", "inc": return .resize(grow: true)
            case "shrink", "-", "dec": return .resize(grow: false)
            default: throw ConfigError("'resize' expects grow|shrink, got '\(arg)'")
            }
        case "main":
            switch lowerArg {
            case "inc", "+": return .mainCount(delta: 1)
            case "dec", "-": return .mainCount(delta: -1)
            default: throw ConfigError("'main' expects inc|dec, got '\(arg)'")
            }
        case "float":
            guard lowerArg == "toggle" || lowerArg.isEmpty else {
                throw ConfigError("'float' expects toggle")
            }
            return .floatToggle
        case "tiling":
            guard lowerArg == "toggle" || lowerArg.isEmpty else {
                throw ConfigError("'tiling' expects toggle")
            }
            return .tilingToggle
        case "gaps":
            switch lowerArg {
            case "inc", "+": return .gaps(delta: 2)
            case "dec", "-": return .gaps(delta: -2)
            case "toggle": return .gapsToggle
            default: throw ConfigError("'gaps' expects inc|dec|toggle, got '\(arg)'")
            }
        case "display", "monitor":
            let sub = lowerArg.split(separator: " ").map(String.init)
            guard sub.count == 2, ["focus", "move"].contains(sub[0]),
                  ["next", "prev", "previous"].contains(sub[1]) else {
                throw ConfigError("'display' expects 'focus next|prev' or 'move next|prev'")
            }
            let next = sub[1] == "next"
            return sub[0] == "focus" ? .displayFocus(next: next) : .displayMove(next: next)
        case "reload", "reload-config":
            return .reload
        case "retile":
            return .retile
        case "query", "status":
            return .query
        case "exec", "exec-and-forget":
            guard !arg.isEmpty else { throw ConfigError("'exec' needs a command") }
            return .exec(arg)
        case "quit", "exit":
            return .quit
        default:
            throw ConfigError("unknown command '\(verb)'")
        }
    }
}
