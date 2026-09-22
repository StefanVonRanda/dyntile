import Foundation
import AppKit
import ApplicationServices

/// Notifications dyntile subscribes to on each running application.
private let appNotifications = [
    kAXWindowCreatedNotification,
    kAXFocusedWindowChangedNotification,
    kAXWindowMiniaturizedNotification,
    kAXWindowDeminiaturizedNotification,
    kAXApplicationActivatedNotification,
    kAXApplicationHiddenNotification,
    kAXApplicationShownNotification,
] as [String]

/// Per-window notifications. These only arrive when registered on the window itself.
private let windowNotifications = [
    kAXUIElementDestroyedNotification,
    kAXWindowMovedNotification,
    kAXWindowResizedNotification,
] as [String]

private func observerCallback(_ observer: AXObserver,
                              _ element: AXUIElement,
                              _ notification: CFString,
                              _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let watcher = Unmanaged<AppWatcher>.fromOpaque(refcon).takeUnretainedValue()
    watcher.handle(notification: notification as String, element: element)
}

/// Accessibility observer bound to one application.
final class AppWatcher {
    let pid: pid_t
    let bundleID: String
    let appName: String
    let element: AXUIElement
    private var observer: AXObserver?
    private var watchedWindows: [WindowID: AXUIElement] = [:]
    private unowned let manager: WindowManager

    init?(app: NSRunningApplication, manager: WindowManager) {
        guard let pid = Optional(app.processIdentifier), pid > 0 else { return nil }
        self.pid = pid
        self.bundleID = app.bundleIdentifier ?? ""
        self.appName = app.localizedName ?? ""
        self.element = AXUIElementCreateApplication(pid)
        self.manager = manager

        var obs: AXObserver?
        guard AXObserverCreate(pid, observerCallback, &obs) == .success, let obs else { return nil }
        self.observer = obs

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for note in appNotifications {
            AXObserverAddNotification(obs, element, note as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
    }

    deinit {
        guard let observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    var windowElements: [AXUIElement] {
        element.elements(kAXWindowsAttribute as String)
    }

    func watch(window: AXUIElement, id: WindowID) {
        guard let observer, watchedWindows[id] == nil else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for note in windowNotifications {
            AXObserverAddNotification(observer, window, note as CFString, refcon)
        }
        watchedWindows[id] = window
    }

    func unwatch(id: WindowID) {
        guard let observer, let window = watchedWindows.removeValue(forKey: id) else { return }
        for note in windowNotifications {
            AXObserverRemoveNotification(observer, window, note as CFString)
        }
    }

    func handle(notification: String, element: AXUIElement) {
        manager.handle(notification: notification, element: element, watcher: self)
    }
}

/// Tracks every tileable window across every running application.
final class WindowManager {
    private(set) var windows: [WindowID: ManagedWindow] = [:]
    /// Global insertion order; per-space lists are filtered views of this.
    private(set) var order: [WindowID] = []
    private var watchers: [pid_t: AppWatcher] = [:]
    private var floating: Set<WindowID> = []

    var config: Config
    /// When set, dyntile computes layouts and logs them but never moves a window.
    var dryRun = false
    /// Called whenever the window set changed and the layout should be recomputed.
    var onChange: ((_ reason: String) -> Void)?
    /// Frames dyntile itself applied, so its own moves are not mistaken for user drags.
    private var suppressedFrames: [WindowID: CGRect] = [:]
    private var applying = false
    /// Set when a move/resize arrives that dyntile did not cause, i.e. a user drag.
    private var userMovedWindow: WindowID?

    init(config: Config) {
        self.config = config
    }

    // MARK: - Lifecycle

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(appLaunched(_:)),
                       name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(appTerminated(_:)),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(appActivated(_:)),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)

        for app in NSWorkspace.shared.runningApplications {
            add(app: app)
        }
        refresh(reason: "startup")
    }

    @objc private func appLaunched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        // Apps rarely have their windows up the instant they launch.
        add(app: app)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.add(app: app)
            self?.refresh(reason: "app launched")
        }
    }

    @objc private func appTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        let dead = windows.values.filter { $0.pid == pid }.map(\.id)
        for id in dead { forget(id, in: pid) }
        watchers.removeValue(forKey: pid)
        refresh(reason: "app terminated")
    }

    @objc private func appActivated(_ note: Notification) {
        refresh(reason: "app activated")
    }

    private func add(app: NSRunningApplication) {
        guard app.activationPolicy == .regular else { return }
        let pid = app.processIdentifier
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { return }
        guard watchers[pid] == nil else { return }
        guard let watcher = AppWatcher(app: app, manager: self) else {
            Log.debug("could not observe \(app.localizedName ?? "?") (\(pid))")
            return
        }
        watchers[pid] = watcher
    }

    // MARK: - Events

    func handle(notification: String, element: AXUIElement, watcher: AppWatcher) {
        switch notification {
        case kAXWindowCreatedNotification:
            refresh(reason: "window created")
        case kAXUIElementDestroyedNotification:
            refresh(reason: "window destroyed")
        case kAXWindowMiniaturizedNotification,
             kAXWindowDeminiaturizedNotification,
             kAXApplicationHiddenNotification,
             kAXApplicationShownNotification:
            refresh(reason: "visibility changed")
        case kAXFocusedWindowChangedNotification,
             kAXApplicationActivatedNotification:
            onChange?("focus changed")
        case kAXWindowMovedNotification,
             kAXWindowResizedNotification:
            guard !applying else { return }
            guard let id = PrivateAPI.windowID(of: element) else { return }
            if let expected = suppressedFrames[id], let actual = element.frame,
               expected.equalTo(actual) {
                return // our own change echoing back
            }
            userMovedWindow = id
            onChange?("window moved by user")
        default:
            break
        }
    }

    // MARK: - Discovery

    /// Rebuild the window table from the accessibility tree, then notify.
    func refresh(reason: String) {
        var seen: Set<WindowID> = []

        for (pid, watcher) in watchers {
            for element in watcher.windowElements {
                guard let id = PrivateAPI.windowID(of: element) else { continue }
                seen.insert(id)
                if windows[id] == nil {
                    let window = ManagedWindow(id: id, pid: pid, element: element,
                                               bundleID: watcher.bundleID, appName: watcher.appName)
                    guard window.isTileable || window.isMinimized else { continue }
                    windows[id] = window
                    order.append(id)
                    watcher.watch(window: element, id: id)
                    if config.shouldFloat(bundleID: window.bundleID, title: window.title) {
                        floating.insert(id)
                    }
                    Log.debug("+ \(window.appName): \(window.title) [\(id)]")
                }
            }
        }

        for id in windows.keys where !seen.contains(id) {
            if let pid = windows[id]?.pid { forget(id, in: pid) }
        }

        onChange?(reason)
    }

    private func forget(_ id: WindowID, in pid: pid_t) {
        watchers[pid]?.unwatch(id: id)
        windows.removeValue(forKey: id)
        order.removeAll { $0 == id }
        floating.remove(id)
        suppressedFrames.removeValue(forKey: id)
    }

    // MARK: - Queries

    /// Window IDs currently on screen, i.e. on the active Space of some display.
    /// This is what lets dyntile stay out of the Spaces business entirely: it tiles
    /// whatever macOS is already showing, and never moves a window between Spaces.
    func onScreenIDs() -> Set<WindowID> {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                              kCGNullWindowID) as? [[String: Any]] ?? []
        var out: Set<WindowID> = []
        for entry in info {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let number = entry[kCGWindowNumber as String] as? CGWindowID else { continue }
            out.insert(number)
        }
        return out
    }

    var focused: ManagedWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = appElement.element(kAXFocusedWindowAttribute as String),
              let id = PrivateAPI.windowID(of: window) else { return nil }
        return windows[id]
    }

    /// Consume the id of the window the user last dragged, if any.
    func takeUserMovedWindow() -> WindowID? {
        defer { userMovedWindow = nil }
        return userMovedWindow
    }

    func isFloating(_ id: WindowID) -> Bool { floating.contains(id) }

    func toggleFloat(_ id: WindowID) {
        if floating.contains(id) { floating.remove(id) } else { floating.insert(id) }
    }

    /// Rewrite the global order so that the slots held by `ids` now hold them in the
    /// given sequence. Windows on other spaces keep their positions untouched.
    func reorder(_ ids: [WindowID]) {
        let set = Set(ids)
        var iterator = ids.makeIterator()
        order = order.map { set.contains($0) ? (iterator.next() ?? $0) : $0 }
    }

    /// Apply frames without tripping the "user moved a window" detector.
    func apply(_ frames: [WindowID: CGRect]) {
        if dryRun {
            for (id, rect) in frames.sorted(by: { $0.key < $1.key }) {
                guard let window = windows[id] else { continue }
                Log.info(String(format: "would place %@ — %@ at (%.0f, %.0f) %.0fx%.0f",
                                window.appName, window.title.isEmpty ? "(untitled)" : window.title,
                                rect.minX, rect.minY, rect.width, rect.height))
            }
            return
        }
        applying = true
        for (id, rect) in frames {
            guard let window = windows[id] else { continue }
            let target = CGRect(x: rect.origin.x.rounded(), y: rect.origin.y.rounded(),
                                width: rect.width.rounded(), height: rect.height.rounded())
            if let current = window.element.frame, current.equalTo(target) { continue }
            window.element.setFrame(target)
            // Record what the window actually settled on: apps with size increments
            // (terminals especially) will not land exactly on the requested frame.
            suppressedFrames[id] = window.element.frame ?? target
        }
        applying = false
    }
}
