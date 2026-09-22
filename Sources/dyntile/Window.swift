import Foundation
import AppKit
import ApplicationServices

typealias WindowID = CGWindowID

/// One accessibility window dyntile knows about.
final class ManagedWindow {
    let id: WindowID
    let pid: pid_t
    let element: AXUIElement
    let bundleID: String
    let appName: String

    init(id: WindowID, pid: pid_t, element: AXUIElement, bundleID: String, appName: String) {
        self.id = id
        self.pid = pid
        self.element = element
        self.bundleID = bundleID
        self.appName = appName
    }

    var title: String { element.string(kAXTitleAttribute as String) ?? "" }
    var subrole: String { element.string(kAXSubroleAttribute as String) ?? "" }
    var isMinimized: Bool { element.bool(kAXMinimizedAttribute as String) ?? false }
    var frame: CGRect { element.frame ?? .zero }

    /// A window is a tiling candidate when it is a real, resizable, standard window.
    /// Sheets, popovers, palettes and fixed-size dialogs are left alone.
    var isTileable: Bool {
        guard subrole == (kAXStandardWindowSubrole as String) else { return false }
        guard element.string(kAXRoleAttribute as String) == (kAXWindowRole as String) else { return false }
        guard !isMinimized else { return false }
        guard element.isSettable else { return false }
        let f = frame
        return f.width > 50 && f.height > 50
    }

    func focus() {
        element.raise()
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [])
        }
    }
}

/// A display and its usable (menu-bar and Dock excluded) area, in AX coordinates.
struct Display {
    let id: CGDirectDisplayID
    let uuid: String
    let frame: CGRect        // AX coordinates
    let visibleFrame: CGRect // AX coordinates

    static func all() -> [Display] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            guard let cfuuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
            let uuid = CFUUIDCreateString(nil, cfuuid) as String
            return Display(id: id,
                           uuid: uuid,
                           frame: AX.flip(screen.frame),
                           visibleFrame: AX.flip(screen.visibleFrame))
        }
        // Left-to-right, then top-to-bottom: makes "display next" predictable.
        .sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
    }

    func contains(_ rect: CGRect) -> Bool {
        frame.contains(CGPoint(x: rect.midX, y: rect.midY))
    }
}
