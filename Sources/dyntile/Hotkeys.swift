import Foundation
import Carbon.HIToolbox

/// Global hotkeys via Carbon's RegisterEventHotKey.
///
/// Deliberately not a CGEventTap: hot keys registered this way need no Input Monitoring
/// permission, cannot swallow unrelated keystrokes, and survive the system disabling
/// unresponsive event taps.
final class Hotkeys {
    private var refs: [EventHotKeyRef?] = []
    private var actions: [UInt32: [Command]] = [:]
    private var nextID: UInt32 = 1
    private var handler: EventHandlerRef?
    private let onCommand: ([Command]) -> Void

    private static let signature: OSType = 0x64797474 // 'dytt'

    init(onCommand: @escaping ([Command]) -> Void) {
        self.onCommand = onCommand
        install()
    }

    private func install() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, refcon -> OSStatus in
            guard let event, let refcon else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let hotkeys = Unmanaged<Hotkeys>.fromOpaque(refcon).takeUnretainedValue()
            hotkeys.fire(id: hotKeyID.id)
            return noErr
        }, 1, &spec, refcon, &handler)
    }

    private func fire(id: UInt32) {
        guard let commands = actions[id] else { return }
        onCommand(commands)
    }

    /// Replace every registration with the bindings from `config`.
    /// Returns the specs that could not be registered (already taken by another app).
    @discardableResult
    func rebind(_ binds: [(spec: String, commands: [Command])]) -> [String] {
        unregisterAll()
        var failed: [String] = []
        for bind in binds {
            guard let parsed = try? Keycodes.parse(bind.spec) else {
                failed.append(bind.spec)
                continue
            }
            let id = nextID
            nextID += 1
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Hotkeys.signature, id: id)
            let status = RegisterEventHotKey(parsed.keyCode, parsed.mods, hotKeyID,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, ref != nil {
                refs.append(ref)
                actions[id] = bind.commands
            } else {
                failed.append(bind.spec)
            }
        }
        return failed
    }

    func unregisterAll() {
        for ref in refs where ref != nil { UnregisterEventHotKey(ref!) }
        refs.removeAll()
        actions.removeAll()
    }

    deinit {
        unregisterAll()
        if let handler { RemoveEventHandler(handler) }
    }
}
