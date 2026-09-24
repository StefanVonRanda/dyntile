import Foundation
import Carbon.HIToolbox

/// The keymap: a built-in list of actions, each with a default shortcut, plus whatever
/// `shortcuts.conf` (next to dyntile.conf) changes. The Shortcuts window writes that file;
/// it stays hand-editable and holds only what differs from the defaults, so a later
/// default keymap still reaches everything you did not touch.
///
///     modifier = alt                   # what `mod` means below
///     focus left = mod-y               # rebind
///     float toggle = none              # turn off
///     exec open -na Ghostty = mod-shift-enter
struct Shortcuts {
    struct Entry {
        /// The command text, as shown in the window and written to the file.
        var name: String
        var commands: [Command]
        var spec: String?
        let defaultSpec: String?
        /// Built in, as opposed to added in the file; only these survive being turned off.
        let builtIn: Bool
    }

    struct Resolved {
        let name: String
        let keyCode: UInt32
        let mods: UInt32
        let commands: [Command]
    }

    static let defaultModifier = UInt32(optionKey)

    /// Mirrors AeroSpace's default hjkl bindings, minus anything workspace-related.
    static let defaults: [(command: String, spec: String?)] = [
        ("focus left", "mod-h"), ("focus down", "mod-j"),
        ("focus up", "mod-k"), ("focus right", "mod-l"),
        ("focus next", "mod-tab"), ("focus prev", "mod-shift-tab"),
        ("move left", "mod-shift-h"), ("move down", "mod-shift-j"),
        ("move up", "mod-shift-k"), ("move right", "mod-shift-l"),
        ("move main", "mod-enter"),
        ("resize shrink", "mod-minus"), ("resize grow", "mod-equal"),
        ("main dec", "mod-shift-comma"), ("main inc", "mod-shift-period"),
        ("layout next", "mod-slash"), ("layout prev", "mod-comma"),
        ("layout tall", "mod-t"), ("layout wide", nil), ("layout columns", nil),
        ("layout rows", nil), ("layout grid", nil), ("layout bsp", "mod-b"),
        ("layout monocle", "mod-m"), ("layout float", nil),
        ("float toggle", "mod-f"), ("tiling toggle", "mod-shift-space"),
        ("gaps toggle", "mod-g"), ("gaps inc", nil), ("gaps dec", nil),
        ("display focus prev", "mod-ctrl-left"), ("display focus next", "mod-ctrl-right"),
        ("display move prev", "mod-shift-left"), ("display move next", "mod-shift-right"),
        ("retile", nil), ("reload", "mod-shift-semicolon"),
    ]

    var modifier = defaultModifier
    var entries: [Entry]
    var path: String?

    init() {
        entries = Shortcuts.defaults.map { command, spec in
            Entry(name: command, commands: [try! Command.parse(command)], spec: spec,
                  defaultSpec: spec, builtIn: true)
        }
    }

    static func path(besideConfig configPath: String) -> String {
        ((configPath as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("shortcuts.conf")
    }

    /// Missing file yields the defaults.
    static func load(path: String) throws -> Shortcuts {
        var shortcuts = Shortcuts()
        shortcuts.path = path
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return shortcuts }

        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            // Whole-line comments only: an `exec` command may well contain a '#'.
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            do {
                // Split on the last '=': key specs never contain one, commands might.
                guard let eq = line.lastIndex(of: "=") else { throw ConfigError("expected '<command> = <keys>'") }
                let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if key.lowercased() == "modifier" {
                    shortcuts.modifier = try Keycodes.parseModifiers(value)
                    continue
                }
                let commands = try key.components(separatedBy: ";")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .map(Command.parse)
                guard !commands.isEmpty else { throw ConfigError("shortcut has no command") }
                let spec: String? = value.lowercased() == "none" ? nil : value
                if let spec { _ = try Keycodes.parse(spec) }  // fail fast on a bad key name
                if let i = shortcuts.entries.firstIndex(where: { $0.commands == commands }) {
                    shortcuts.entries[i].spec = spec
                } else {
                    shortcuts.entries.append(Entry(name: key, commands: commands, spec: spec,
                                                   defaultSpec: nil, builtIn: false))
                }
            } catch let error as ConfigError {
                throw ConfigError("\(path):\(index + 1): \(error.description)")
            }
        }
        return shortcuts
    }

    var modifierName: String {
        Keycodes.modifierOrder.filter { modifier & $0.mask != 0 }.map(\.name).joined(separator: "-")
    }

    var text: String {
        var lines = [
            "# dyntile shortcuts. The Shortcuts window writes this file; hand edits work too.",
            "# `<command> = <keys>`, or `= none` to turn one off. `mod` is the modifier below.",
            "# Anything not listed keeps its default.",
            "modifier = \(modifierName)",
        ]
        for entry in entries where !entry.builtIn || entry.spec != entry.defaultSpec {
            lines.append("\(entry.name) = \(entry.spec ?? "none")")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func save() throws {
        guard let path else { return }
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    var resolved: [Resolved] {
        entries.compactMap { entry in
            guard let spec = entry.spec, let (code, mods) = try? Keycodes.parse(spec, mod: modifier) else {
                return nil
            }
            return Resolved(name: entry.name, keyCode: code, mods: mods, commands: entry.commands)
        }
    }
}
