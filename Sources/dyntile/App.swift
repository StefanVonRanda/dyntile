import Foundation
import AppKit

@main
enum Main {
    static func main() {
        var args = Array(CommandLine.arguments.dropFirst())

        if let first = args.first, first == "msg" || first == "-m" {
            let message = args.dropFirst().joined(separator: " ")
            guard !message.isEmpty else {
                FileHandle.standardError.write("usage: dyntile msg <command>\n".data(using: .utf8)!)
                exit(2)
            }
            do {
                let reply = try IPC.send(message)
                if !reply.isEmpty { print(reply) }
                exit(reply.hasPrefix("error:") ? 1 : 0)
            } catch {
                FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
                exit(1)
            }
        }

        var configPath = Config.defaultPath
        var verbose = false
        var checkOnly = false
        var dryRun = false

        while let arg = args.first {
            args.removeFirst()
            switch arg {
            case "-h", "--help":
                print(usage)
                exit(0)
            case "-v", "--verbose":
                verbose = true
            case "--check":
                checkOnly = true
            case "--selftest":
                exit(SelfTest.run())
            case "--dry-run":
                dryRun = true
                verbose = true
            case "-c", "--config":
                guard let path = args.first else {
                    FileHandle.standardError.write("--config needs a path\n".data(using: .utf8)!)
                    exit(2)
                }
                configPath = path
                args.removeFirst()
            case "--print-default-config":
                print(defaultConfigText)
                exit(0)
            default:
                FileHandle.standardError.write("unknown argument '\(arg)'\n\n\(usage)\n".data(using: .utf8)!)
                exit(2)
            }
        }

        let config: Config
        do {
            config = try Config.load(path: configPath)
        } catch {
            FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
            exit(1)
        }
        Log.verbose = verbose || config.verbose

        if checkOnly {
            print("\(configPath): ok — layouts: "
                  + config.layouts.map(\.rawValue).joined(separator: ", "))
            if config.ignoredBinds > 0 {
                print("note: \(config.ignoredBinds) 'bind' lines ignored — dyntile has no hotkeys")
            }
            exit(0)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate(config: config, dryRun: dryRun)
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    static let usage = """
    dyntile — dynamic window tiling for macOS, one layout per native desktop.

    usage:
      dyntile [-c <config>] [-v]      run the tiler
      dyntile msg <command>           send a command to the running tiler
      dyntile --check                 validate the config and exit
      dyntile --selftest              run the built-in logic tests
      dyntile --dry-run               log the layout it would apply, move nothing
      dyntile --print-default-config  write a starter config to stdout
      dyntile --help

    config: \(Config.defaultPath)
    """
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var config: Config
    private let wm: WindowManager
    private let engine: Engine
    private var server: IPC.Server?
    private var statusItem: NSStatusItem?
    private var layoutMenuItem: NSMenuItem?
    private var configWatcher: DispatchSourceFileSystemObject?
    private var mouseDownMonitor: Any?
    private var mouseUpMonitor: Any?
    private var mouseMoveMonitor: Any?
    private var reconcileTimer: Timer?

    init(config: Config, dryRun: Bool = false) {
        self.config = config
        self.wm = WindowManager(config: config)
        self.wm.dryRun = dryRun
        self.engine = Engine(wm: wm, config: config)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard AX.isTrusted(prompt: true) else {
            Log.error("""
                waiting for accessibility permission.
                Grant it in System Settings > Privacy & Security > Accessibility, and dyntile
                will start on its own — no need to relaunch. If dyntile is already listed,
                the grant is stale after a rebuild: remove the entry with (-) and add it again.
                """)
            waitForAccessibility(until: Date().addingTimeInterval(120))
            return
        }
        boot()
    }

    /// The permission prompt is not modal, and the grant does not reach a running process
    /// as a notification, so poll for it rather than making the user launch dyntile twice.
    private func waitForAccessibility(until deadline: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            if AX.isTrusted(prompt: false) {
                Log.info("accessibility granted")
                self.boot()
            } else if Date() < deadline {
                self.waitForAccessibility(until: deadline)
            } else {
                Log.error("gave up waiting for accessibility permission")
                NSApp.terminate(nil)
            }
        }
    }

    private func boot() {
        if !PrivateAPI.hasWindowIDLookup {
            Log.error("this macOS build does not expose _AXUIElementGetWindow; cannot continue")
            NSApp.terminate(nil)
            return
        }

        wm.onChange = { [weak self] reason in
            guard let self else { return }
            if reason == "focus changed" {
                self.engine.noteFocusChange()
            } else {
                self.engine.scheduleRetile(reason: reason)
            }
        }
        engine.onConfigReload = { [weak self] fresh in self?.adopt(fresh) }

        wm.start()

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(spaceChanged),
                       name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        installMouseMonitors()
        watchConfig()
        startServer()
        buildStatusItem()

        // Safety net: accessibility notifications are lossy, so reconcile periodically.
        reconcileTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.wm.refresh(reason: "periodic")
            self?.engine.flushDeferredRetile()
        }

        Log.info("dyntile running — config \(config.path ?? "(defaults)"), "
                 + "socket \(IPC.socketPath)")
        noteIgnoredBinds()
    }

    private func adopt(_ fresh: Config) {
        config = fresh
        wm.config = fresh
        Log.verbose = fresh.verbose
        noteIgnoredBinds()
        installMouseMonitors()
        updateStatusItem()
    }

    private func noteIgnoredBinds() {
        guard config.ignoredBinds > 0 else { return }
        Log.info("ignoring \(config.ignoredBinds) 'bind' lines in the config — dyntile has no hotkeys")
    }

    @objc private func spaceChanged() {
        // The new space's windows are not reported as on-screen instantly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.wm.refresh(reason: "space changed")
        }
    }

    @objc private func screensChanged() {
        wm.refresh(reason: "displays changed")
    }

    private func installMouseMonitors() {
        if let mouseDownMonitor { NSEvent.removeMonitor(mouseDownMonitor) }
        if let mouseUpMonitor { NSEvent.removeMonitor(mouseUpMonitor) }
        if let mouseMoveMonitor { NSEvent.removeMonitor(mouseMoveMonitor); self.mouseMoveMonitor = nil }

        // Down and up are watched as a pair: tiling is frozen for the whole time the
        // button is held, so a drag never has the layout pulling against it.
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) {
            [weak self] _ in
            self?.engine.mouseDidGoDown()
        }
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            guard let self else { return }
            let point = AX.flip(CGRect(origin: NSEvent.mouseLocation, size: .zero)).origin
            self.engine.handleDragEnd(at: point)
        }

        guard config.focusFollowsMouse else { return }
        var lastFocusAt = Date.distantPast
        mouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            guard let self, Date().timeIntervalSince(lastFocusAt) > 0.15 else { return }
            lastFocusAt = Date()
            self.focusWindowUnderMouse()
        }
    }

    private func focusWindowUnderMouse() {
        let point = AX.flip(CGRect(origin: NSEvent.mouseLocation, size: .zero)).origin
        let onScreen = wm.onScreenIDs()
        guard let hit = wm.order.reversed().first(where: { id in
            guard onScreen.contains(id), let window = wm.windows[id], window.isTileable else { return false }
            return window.frame.contains(point)
        }), let window = wm.windows[hit], wm.focused?.id != hit else { return }
        window.focus()
        engine.noteFocusChange()
    }

    private func watchConfig() {
        configWatcher?.cancel()
        guard let path = config.path else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            // Editors replace rather than rewrite; re-arm on the new inode.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                guard let self else { return }
                Log.info(self.engine.run(.reload))
                self.watchConfig()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        configWatcher = source
    }

    private func startServer() {
        let server = IPC.Server { [weak self] request in
            guard let self else { return "error: shutting down" }
            do {
                let command = try Command.parse(request)
                return self.engine.run(command)
            } catch {
                return "error: \(error)"
            }
        }
        do {
            try server.start()
            self.server = server
        } catch {
            Log.error("ipc: \(error)")
        }
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        // Enabled state is set explicitly in updateStatusItem; automatic validation would
        // override it and leave the layout item enabled while tiling is paused.
        menu.autoenablesItems = false

        // Every layout is offered, not just the ones in the `layouts` cycle: the cycle is
        // about what `layout next` steps through, not about what you are allowed to pick.
        let layoutItem = NSMenuItem(title: "Layout", action: nil, keyEquivalent: "")
        let layoutMenu = NSMenu()
        for kind in LayoutKind.allCases {
            let entry = NSMenuItem(title: kind.rawValue.capitalized,
                                   action: #selector(menuSetLayout(_:)), keyEquivalent: "")
            entry.representedObject = kind.rawValue
            entry.target = self
            layoutMenu.addItem(entry)
        }
        layoutItem.submenu = layoutMenu
        menu.addItem(layoutItem)
        self.layoutMenuItem = layoutItem

        menu.addItem(.separator())
        menu.addItem(withTitle: "Retile", action: #selector(menuRetile), keyEquivalent: "")
        menu.addItem(withTitle: "Float focused window", action: #selector(menuFloat),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Pause tiling", action: #selector(menuToggle), keyEquivalent: "")
        menu.addItem(withTitle: "Reload config", action: #selector(menuReload), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit dyntile", action: #selector(menuQuit), keyEquivalent: "")
        for entry in menu.items where entry.submenu == nil { entry.target = self }
        item.menu = menu
        statusItem = item
        updateStatusItem()
    }

    private func updateStatusItem() {
        statusItem?.button?.image = StatusIcon.image(paused: !engine.tilingEnabled)
        statusItem?.button?.toolTip = engine.tilingEnabled ? "dyntile" : "dyntile (paused)"
        let toggleTitle = engine.tilingEnabled ? "Pause tiling" : "Resume tiling"
        for existing in ["Pause tiling", "Resume tiling"] {
            statusItem?.menu?.item(withTitle: existing)?.title = toggleTitle
        }

        // Still selectable while paused: the choice simply takes effect on resume.
        let current = engine.currentLayoutName
        layoutMenuItem?.title = engine.tilingEnabled
            ? "Layout: \(current)"
            : "Layout: \(current) (paused)"
        for entry in layoutMenuItem?.submenu?.items ?? [] {
            entry.state = (entry.representedObject as? String) == current ? .on : .off
        }
    }

    @objc private func menuSetLayout(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let kind = LayoutKind(rawValue: name) else { return }
        engine.setLayout(kind)
        updateStatusItem()
    }

    @objc private func menuFloat() { engine.run(.floatToggle) }

    /// The layout can change over IPC, so refresh the title as the menu opens.
    func menuWillOpen(_ menu: NSMenu) { updateStatusItem() }

    @objc private func menuRetile() { engine.run(.retile) }
    @objc private func menuToggle() { engine.run(.tilingToggle); updateStatusItem() }
    @objc private func menuReload() { Log.info(engine.run(.reload)) }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
    }
}
