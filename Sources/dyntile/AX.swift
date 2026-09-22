import Foundation
import ApplicationServices
import AppKit

/// Convenience wrappers over the raw AXUIElement C API.
extension AXUIElement {
    func attribute<T>(_ name: String, as type: T.Type) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    func string(_ name: String) -> String? { attribute(name, as: String.self) }
    func bool(_ name: String) -> Bool? { attribute(name, as: Bool.self) }

    func element(_ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    func elements(_ name: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success,
              let array = value as? [AnyObject] else { return [] }
        return array.compactMap { obj -> AXUIElement? in
            CFGetTypeID(obj) == AXUIElementGetTypeID() ? (obj as! AXUIElement) : nil
        }
    }

    var isSettable: Bool {
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(self, kAXPositionAttribute as CFString, &settable)
        return settable.boolValue
    }

    var position: CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, kAXPositionAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        AXValueGetValue((value as! AXValue), .cgPoint, &point)
        return point
    }

    var size: CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, kAXSizeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        AXValueGetValue((value as! AXValue), .cgSize, &size)
        return size
    }

    /// Frame in Quartz/AX global coordinates (origin top-left of the primary display, y grows down).
    var frame: CGRect? {
        guard let position, let size else { return nil }
        return CGRect(origin: position, size: size)
    }

    @discardableResult
    func setPosition(_ point: CGPoint) -> Bool {
        var p = point
        guard let value = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(self, kAXPositionAttribute as CFString, value) == .success
    }

    @discardableResult
    func setSize(_ size: CGSize) -> Bool {
        var s = size
        guard let value = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(self, kAXSizeAttribute as CFString, value) == .success
    }

    /// Apply a frame. Size is set twice around the move because many apps clamp a
    /// resize against the display the window currently sits on; moving first and
    /// re-applying the size afterwards makes cross-display tiling land correctly.
    func setFrame(_ rect: CGRect) {
        setSize(rect.size)
        setPosition(rect.origin)
        setSize(rect.size)
    }

    func raise() {
        AXUIElementPerformAction(self, kAXRaiseAction as CFString)
    }
}

enum AX {
    /// Ask for accessibility trust, optionally showing the system prompt.
    static func isTrusted(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Convert a Cocoa rect (bottom-left origin) to AX/Quartz coordinates (top-left origin).
    static func flip(_ rect: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return rect }
        return CGRect(x: rect.minX,
                      y: primary.frame.maxY - rect.maxY,
                      width: rect.width,
                      height: rect.height)
    }
}
