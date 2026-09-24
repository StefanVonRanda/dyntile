import Foundation
import Carbon.HIToolbox

enum Keycodes {
    /// Names follow AeroSpace's vocabulary so an existing config translates directly.
    static let byName: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "equal": 24, "minus": 27, "rightsquarebracket": 30, "o": 31, "u": 32,
        "leftsquarebracket": 33, "i": 34, "p": 35, "l": 37, "j": 38, "quote": 39, "k": 40,
        "semicolon": 41, "backslash": 42, "comma": 43, "slash": 44, "n": 45, "m": 46,
        "period": 47, "backtick": 50, "grave": 50,

        "enter": 36, "return": 36, "tab": 48, "space": 49, "backspace": 51, "delete": 51,
        "esc": 53, "escape": 53, "forwarddelete": 117,

        "left": 123, "right": 124, "down": 125, "up": 126,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121,

        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113,
        "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90,

        "keypad0": 82, "keypad1": 83, "keypad2": 84, "keypad3": 85, "keypad4": 86,
        "keypad5": 87, "keypad6": 88, "keypad7": 89, "keypad8": 91, "keypad9": 92,
        "keypadclear": 71, "keypaddecimalmark": 65, "keypaddivide": 75, "keypadenter": 76,
        "keypadequal": 81, "keypadminus": 78, "keypadmultiply": 67, "keypadplus": 69,
        "sectionsign": 10,
    ]

    /// One name per keycode for writing specs back out; the alphabetically first alias wins
    /// ("backspace" over "delete", "enter" over "return").
    static let nameByCode: [UInt32: String] = byName.keys.sorted().reduce(into: [:]) { names, name in
        if names[byName[name]!] == nil { names[byName[name]!] = name }
    }

    static let modifiers: [String: UInt32] = [
        "cmd": UInt32(cmdKey), "command": UInt32(cmdKey), "super": UInt32(cmdKey),
        "shift": UInt32(shiftKey),
        "alt": UInt32(optionKey), "opt": UInt32(optionKey), "option": UInt32(optionKey),
        "ctrl": UInt32(controlKey), "control": UInt32(controlKey),
        "fn": 0,
    ]

    /// Modifier names in Apple's display order, with their glyphs.
    static let modifierOrder: [(name: String, mask: UInt32, glyph: String)] = [
        ("ctrl", UInt32(controlKey), "⌃"), ("alt", UInt32(optionKey), "⌥"),
        ("shift", UInt32(shiftKey), "⇧"), ("cmd", UInt32(cmdKey), "⌘"),
    ]

    private static func split(_ spec: String) -> [String] {
        spec.lowercased().split(whereSeparator: { $0 == "-" || $0 == "+" }).map(String.init)
    }

    /// Parse a modifier set such as "alt" or "ctrl-alt" into a Carbon mask.
    static func parseModifiers(_ spec: String) throws -> UInt32 {
        var mods: UInt32 = 0
        for part in split(spec) {
            guard let m = modifiers[part], m != 0 else {
                throw ConfigError("unknown modifier '\(part)' in '\(spec)'")
            }
            mods |= m
        }
        guard mods != 0 else { throw ConfigError("'modifier' needs at least one of cmd, alt, ctrl, shift") }
        return mods
    }

    /// Parse "alt-shift-h" (or "cmd+alt+k", or "alt-kc:36") into Carbon (keycode, modifier mask).
    /// `mod` stands for the configured main modifier.
    static func parse(_ spec: String, mod: UInt32 = UInt32(optionKey)) throws -> (keyCode: UInt32, mods: UInt32) {
        let parts = split(spec)
        guard let keyPart = parts.last, !keyPart.isEmpty else {
            throw ConfigError("empty key binding")
        }
        var mods: UInt32 = 0
        for part in parts.dropLast() {
            if part == "mod" { mods |= mod; continue }
            guard let m = modifiers[part] else { throw ConfigError("unknown modifier '\(part)' in '\(spec)'") }
            mods |= m
        }
        if keyPart.hasPrefix("kc:"), let raw = UInt32(keyPart.dropFirst(3)) {
            return (raw, mods)
        }
        guard let code = byName[keyPart] else { throw ConfigError("unknown key '\(keyPart)' in '\(spec)'") }
        return (code, mods)
    }

    /// The inverse of `parse`: a spec written relative to `mod` when the combination
    /// contains all of it, so changing the modifier later carries the shortcut along.
    static func spec(keyCode: UInt32, mods: UInt32, mod: UInt32) -> String {
        var parts: [String] = []
        var rest = mods
        if mods & mod == mod { parts.append("mod"); rest &= ~mod }
        for m in modifierOrder where rest & m.mask != 0 { parts.append(m.name) }
        parts.append(nameByCode[keyCode] ?? "kc:\(keyCode)")
        return parts.joined(separator: "-")
    }

    static func glyphs(_ mods: UInt32) -> String {
        modifierOrder.filter { mods & $0.mask != 0 }.map(\.glyph).joined()
    }

    /// "⌥⇧H" for display. Printable keys are labelled with what the current keyboard
    /// layout prints on them, so a Danish user sees "-" where a US layout has "/".
    static func display(_ spec: String, mod: UInt32) -> String {
        guard let (code, mods) = try? parse(spec, mod: mod) else { return spec }
        return glyphs(mods) + label(code)
    }

    private static let specialLabels: [UInt32: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦", 76: "⌤",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
    ]

    static func label(_ code: UInt32) -> String {
        if let special = specialLabels[code] { return special }
        let name = nameByCode[code] ?? "kc:\(code)"
        if name.hasPrefix("f"), Int(name.dropFirst()) != nil { return name.uppercased() }
        return layoutCharacter(code)?.uppercased() ?? name
    }

    private static func layoutCharacter(_ code: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { bytes in
            UCKeyTranslate(bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress, UInt16(code),
                           UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys,
                           chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: chars, count: length).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
