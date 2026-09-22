import Foundation
import ApplicationServices

/// Thin, dlsym-based bindings to the two private entry points every macOS tiler needs:
/// mapping an AXUIElement to a CGWindowID, and asking SkyLight which native Space is
/// current on each display. Both are resolved lazily and every call site has a fallback,
/// so a missing symbol degrades behaviour instead of crashing.
enum PrivateAPI {
    private typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias CGSMainConnectionIDFn = @convention(c) () -> Int32
    private typealias CGSCopyManagedDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CGSGetActiveSpaceFn = @convention(c) (Int32) -> UInt64

    private nonisolated(unsafe) static let selfHandle = dlopen(nil, RTLD_LAZY)
    private nonisolated(unsafe) static let skylight = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_LAZY)

    private static func sym<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, _ type: T.Type) -> T? {
        guard let handle, let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: type)
    }

    private static let axGetWindow =
        sym(selfHandle, "_AXUIElementGetWindow", AXGetWindowFn.self)
    private static let cgsMainConnectionID =
        sym(skylight, "CGSMainConnectionID", CGSMainConnectionIDFn.self)
    private static let cgsCopyManagedDisplaySpaces =
        sym(skylight, "CGSCopyManagedDisplaySpaces", CGSCopyManagedDisplaySpacesFn.self)
    private static let cgsGetActiveSpace =
        sym(skylight, "CGSGetActiveSpace", CGSGetActiveSpaceFn.self)

    static var hasWindowIDLookup: Bool { axGetWindow != nil }

    /// The CGWindowID behind an accessibility window element, or nil.
    static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let fn = axGetWindow else { return nil }
        var wid: CGWindowID = 0
        return fn(element, &wid) == .success && wid != 0 ? wid : nil
    }

    /// Map of display UUID string -> id of the Space currently shown on it.
    /// Empty when SkyLight is unavailable; callers then fall back to a per-display key.
    static func currentSpaceByDisplay() -> [String: UInt64] {
        guard let conn = cgsMainConnectionID, let copy = cgsCopyManagedDisplaySpaces else { return [:] }
        guard let displays = copy(conn())?.takeRetainedValue() as? [[String: Any]] else { return [:] }
        var result: [String: UInt64] = [:]
        for display in displays {
            guard let uuid = display["Display Identifier"] as? String else { continue }
            guard let current = display["Current Space"] as? [String: Any] else { continue }
            if let id = current["ManagedSpaceID"] as? UInt64 ?? current["id64"] as? UInt64 {
                result[uuid] = id
            }
        }
        return result
    }

    static func activeSpace() -> UInt64 {
        guard let conn = cgsMainConnectionID, let get = cgsGetActiveSpace else { return 0 }
        return get(conn())
    }
}
