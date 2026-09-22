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
            print("\(configPath): ok — \(config.binds.count) bindings, layouts: "
                  + config.layouts.map(\.rawValue).joined(separator: ", "))
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config: Config
    private let wm: WindowManager
    private let engine: Engine
    private var hotkeys: Hotkeys!
    private var server: IPC.Server?
    private var statusItem: NSStatusItem?
    private var configWatcher: DispatchSourceFileSystemObject?
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
                accessibility permission is required.
                Grant it in System Settings > Privacy & Security > Accessibility, then run dyntile again.
                """)
            // The prompt is modal-free; give the user time to grant it, then re-check.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                if AX.isTrusted(prompt: false) { self?.boot() } else { NSApp.terminate(nil) }
            }
            return
        }
        boot()
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

        hotkeys = Hotkeys { [weak self] commands in
            guard let self else { return }
            for command in commands {
                let result = self.engine.run(command)
                if result.hasPrefix("error:") { Log.debug("\(command): \(result)") }
            }
        }
        applyBindings()

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
        }

        Log.info("dyntile running — config \(config.path ?? "(defaults)"), "
                 + "\(config.binds.count) bindings, socket \(IPC.socketPath)")
    }

    private func adopt(_ fresh: Config) {
        config = fresh
        wm.config = fresh
        Log.verbose = fresh.verbose
        applyBindings()
        installMouseMonitors()
        updateStatusItem()
    }

    private func applyBindings() {
        let failed = hotkeys.rebind(config.binds)
        for spec in failed {
            Log.error("could not register hotkey '\(spec)' — another app already owns it")
        }
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
        if let mouseUpMonitor { NSEvent.removeMonitor(mouseUpMonitor) }
        if let mouseMoveMonitor { NSEvent.removeMonitor(mouseMoveMonitor); self.mouseMoveMonitor = nil }

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
        item.button?.title = "▦"
        let menu = NSMenu()
        menu.addItem(withTitle: "Retile", action: #selector(menuRetile), keyEquivalent: "")
        menu.addItem(withTitle: "Pause tiling", action: #selector(menuToggle), keyEquivalent: "")
        menu.addItem(withTitle: "Reload config", action: #selector(menuReload), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit dyntile", action: #selector(menuQuit), keyEquivalent: "q")
        for entry in menu.items { entry.target = self }
        item.menu = menu
        statusItem = item
        updateStatusItem()
    }

    private func updateStatusItem() {
        statusItem?.button?.title = engine.tilingEnabled ? "▦" : "▧"
        statusItem?.menu?.item(at: 1)?.title = engine.tilingEnabled ? "Pause tiling" : "Resume tiling"
    }

    @objc private func menuRetile() { engine.run(.retile) }
    @objc private func menuToggle() { engine.run(.tilingToggle); updateStatusItem() }
    @objc private func menuReload() { Log.info(engine.run(.reload)) }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        hotkeys?.unregisterAll()
    }
}
