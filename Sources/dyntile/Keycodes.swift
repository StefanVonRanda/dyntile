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

    static let modifiers: [String: UInt32] = [
        "cmd": UInt32(cmdKey), "command": UInt32(cmdKey), "super": UInt32(cmdKey),
        "shift": UInt32(shiftKey),
        "alt": UInt32(optionKey), "opt": UInt32(optionKey), "option": UInt32(optionKey),
        "ctrl": UInt32(controlKey), "control": UInt32(controlKey),
        "fn": 0,
    ]

    /// Parse "alt-shift-h" (or "cmd+alt+k", or "alt-kc:36") into Carbon (keycode, modifier mask).
    static func parse(_ spec: String) throws -> (keyCode: UInt32, mods: UInt32) {
        let parts = spec.lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "+" })
            .map(String.init)
        guard let keyPart = parts.last, !keyPart.isEmpty else {
            throw ConfigError("empty key binding")
        }
        var mods: UInt32 = 0
        for part in parts.dropLast() {
            guard let m = modifiers[part] else { throw ConfigError("unknown modifier '\(part)' in '\(spec)'") }
            mods |= m
        }
        if keyPart.hasPrefix("kc:"), let raw = UInt32(keyPart.dropFirst(3)) {
            return (raw, mods)
        }
        guard let code = byName[keyPart] else { throw ConfigError("unknown key '\(keyPart)' in '\(spec)'") }
        return (code, mods)
    }
}
