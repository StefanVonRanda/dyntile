import AppKit
import Carbon.HIToolbox

/// The Shortcuts window: pick the modifier, and rebind or turn off each action.
/// Every change is applied and saved at once, as in System Settings.
final class ShortcutsWindow: NSObject, NSWindowDelegate {
    private var shortcuts: Shortcuts
    private var failed: Set<String> = []
    /// Called with the edited keymap; the owner saves and re-registers it.
    private let onChange: (Shortcuts) -> Void
    /// Registered hotkeys would eat the very keys being recorded, so the owner lifts
    /// them while a recorder is listening.
    private let onRecording: (Bool) -> Void

    private var window: NSWindow?
    private var modifierBoxes: [NSButton] = []
    private var toggles: [NSButton] = []
    private var recorders: [ShortcutRecorder] = []
    private let grid = NSGridView()

    init(shortcuts: Shortcuts, onChange: @escaping (Shortcuts) -> Void,
         onRecording: @escaping (Bool) -> Void) {
        self.shortcuts = shortcuts
        self.onChange = onChange
        self.onRecording = onRecording
    }

    func show() {
        if window == nil { build() }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Take a keymap from outside (a reload) and the names that failed to register.
    func update(_ shortcuts: Shortcuts, failed: [String]) {
        self.shortcuts = shortcuts
        self.failed = Set(failed)
        if window != nil { refresh() }
    }

    // MARK: - Building

    private func build() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered,
                              defer: false)
        window.title = "dyntile Shortcuts"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 380, height: 300)

        let modifierRow = NSStackView()
        modifierRow.addArrangedSubview(NSTextField(labelWithString: "Modifier:"))
        for m in Keycodes.modifierOrder {
            let names = ["ctrl": "Control", "alt": "Option", "shift": "Shift", "cmd": "Command"]
            let box = NSButton(checkboxWithTitle: "\(m.glyph) \(names[m.name]!)", target: self,
                               action: #selector(modifierChanged(_:)))
            box.tag = Int(m.mask)
            modifierBoxes.append(box)
            modifierRow.addArrangedSubview(box)
        }

        grid.columnSpacing = 12
        grid.rowSpacing = 6
        grid.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(grid)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = document
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 4),
            grid.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            grid.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -4),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        let hint = NSTextField(wrappingLabelWithString:
            "Click a shortcut and press the new keys. ⌫ turns it off, ⎋ cancels. "
            + "Shortcuts using the modifier follow it when it changes.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let reset = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults))
        let footer = NSStackView(views: [hint, reset])
        footer.alignment = .centerY

        let stack = NSStackView(views: [modifierRow, scroll, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for view in [scroll, footer] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        window.contentView = stack
        window.delegate = self
        window.center()
        self.window = window
    }

    /// Closing mid-recording would leave the hotkeys lifted.
    func windowWillClose(_ notification: Notification) {
        window?.makeFirstResponder(nil)
    }

    private func rebuildRows() {
        while grid.numberOfRows > 0 { grid.removeRow(at: 0) }
        toggles = []
        recorders = []
        for index in shortcuts.entries.indices {
            let toggle = NSButton(checkboxWithTitle: shortcuts.entries[index].name, target: self,
                                  action: #selector(toggled(_:)))
            toggle.tag = index
            let recorder = ShortcutRecorder()
            recorder.tag = index
            recorder.onRecordingChange = { [weak self] on in self?.onRecording(on) }
            recorder.onRecord = { [weak self] combo in self?.record(combo, at: index) }
            recorder.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
            toggles.append(toggle)
            recorders.append(recorder)
            grid.addRow(with: [toggle, recorder])
        }
    }

    private func refresh() {
        if toggles.count != shortcuts.entries.count { rebuildRows() }
        for box in modifierBoxes {
            box.state = shortcuts.modifier & UInt32(box.tag) != 0 ? .on : .off
        }
        for (index, entry) in shortcuts.entries.enumerated() {
            toggles[index].state = entry.spec == nil ? .off : .on
            let recorder = recorders[index]
            let taken = failed.contains(entry.name) && entry.spec != nil
            recorder.taken = taken
            recorder.idleTitle = entry.spec.map { Keycodes.display($0, mod: shortcuts.modifier) }
                ?? "Set Shortcut"
            recorder.toolTip = taken ? "Another app already uses this shortcut" : nil
        }
    }

    // MARK: - Editing

    private func commit() {
        refresh()
        onChange(shortcuts)
    }

    @objc private func modifierChanged(_ sender: NSButton) {
        let mask = UInt32(sender.tag)
        let next = sender.state == .on ? shortcuts.modifier | mask : shortcuts.modifier & ~mask
        guard next != 0 else {
            NSSound.beep()
            sender.state = .on
            return
        }
        shortcuts.modifier = next
        commit()
    }

    @objc private func toggled(_ sender: NSButton) {
        let entry = shortcuts.entries[sender.tag]
        if sender.state == .off {
            shortcuts.entries[sender.tag].spec = nil
            commit()
        } else if let spec = entry.defaultSpec {
            assign(spec, at: sender.tag)
        } else {
            sender.state = .off  // nothing to turn back on yet: ask for keys
            recorders[sender.tag].startRecording()
        }
    }

    private func record(_ combo: (keyCode: UInt32, mods: UInt32)?, at index: Int) {
        guard let combo else {
            shortcuts.entries[index].spec = nil
            commit()
            return
        }
        assign(Keycodes.spec(keyCode: combo.keyCode, mods: combo.mods, mod: shortcuts.modifier), at: index)
    }

    /// One combination, one action: whatever held it before gives it up.
    private func assign(_ spec: String, at index: Int) {
        if let combo = try? Keycodes.parse(spec, mod: shortcuts.modifier) {
            for other in shortcuts.entries.indices where other != index {
                guard let otherSpec = shortcuts.entries[other].spec,
                      let otherCombo = try? Keycodes.parse(otherSpec, mod: shortcuts.modifier) else { continue }
                if otherCombo == combo { shortcuts.entries[other].spec = nil }
            }
        }
        shortcuts.entries[index].spec = spec
        commit()
    }

    @objc private func restoreDefaults() {
        var fresh = Shortcuts()
        fresh.path = shortcuts.path
        // Commands added by hand are kept, only their keys go.
        for entry in shortcuts.entries where !entry.builtIn {
            var kept = entry
            kept.spec = nil
            fresh.entries.append(kept)
        }
        shortcuts = fresh
        commit()
    }
}

/// Top-down coordinates, so the list starts at the top of the scroll view.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A button that, once clicked, turns the next key combination into a shortcut.
final class ShortcutRecorder: NSButton {
    var onRecord: (((keyCode: UInt32, mods: UInt32)?) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    var idleTitle = "" { didSet { if !recording { showIdle() } } }
    /// Registration failed: another app holds this combination.
    var taken = false
    private var recording = false

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(clicked)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }

    @objc private func clicked() { recording ? stopRecording() : startRecording() }

    func startRecording() {
        guard !recording else { return }
        recording = true
        title = "Type Shortcut…"
        window?.makeFirstResponder(self)
        onRecordingChange?(true)
    }

    private func stopRecording() {
        guard recording else { return }
        recording = false
        showIdle()
        onRecordingChange?(false)
    }

    private func showIdle() {
        title = idleTitle
        guard taken else { return }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        attributedTitle = NSAttributedString(string: idleTitle, attributes: [
            .foregroundColor: NSColor.systemRed, .font: font ?? .systemFont(ofSize: 0),
            .paragraphStyle: style,
        ])
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return super.keyDown(with: event) }
        capture(event)
    }

    /// ⌘ combinations arrive here rather than at keyDown.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, event.type == .keyDown, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        capture(event)
        return true
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    private func capture(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        let code = UInt32(event.keyCode)
        stopRecording()
        switch (code, mods) {
        case (53, 0): return                        // esc: cancel
        case (51, 0), (117, 0): onRecord?(nil)      // delete: turn off
        default: onRecord?((code, mods))
        }
    }
}
