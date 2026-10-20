import Foundation
import AppKit
import Carbon.HIToolbox
import KatibCore

/// Registers a Carbon hotkey for every bound `WindowAction` and dispatches
/// presses to `WindowManager`. Bindings come from `AppSettings`; changing a
/// binding re-registers just that row.
///
/// Why Carbon and not the CGEvent tap: Carbon cleanly intercepts (so the
/// target app doesn't see the keystroke) and supports every modifier
/// permutation we care about. The dictation CGEvent tap is listen-only and
/// won't help here.
@MainActor
public final class WindowHotkeys {
    public static let shared = WindowHotkeys()

    private var registrations: [WindowAction: EventHotKeyRef] = [:]
    private var handlers: [UInt32: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private let signature: OSType = 0x4b545750 // "KTWP"
    private var nextID: UInt32 = 1000
    private var idToAction: [UInt32: WindowAction] = [:]

    private init() {
        installHandler()
    }

    /// Install the OS-level dispatch handler once. Per-action registrations
    /// happen via `bind(...)`.
    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                let me = Unmanaged<WindowHotkeys>.fromOpaque(userData).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                guard GetEventParameter(
                    event,
                    OSType(kEventParamDirectObject),
                    OSType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                ) == noErr else { return noErr }

                // Other Katib Carbon managers' handlers also receive this
                // event; filter by our signature so we only fire on our
                // own registrations.
                guard hotKeyID.signature == me.signature else { return noErr }
                guard let action = me.idToAction[hotKeyID.id] else {
                    Logger.shared.log("WindowHotkeys: fired for unknown id=\(hotKeyID.id)")
                    return noErr
                }
                Logger.shared.log("WindowHotkeys: fired for \(action.rawValue)")
                Task { @MainActor in
                    WindowManager.shared.perform(action)
                }
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        if status != noErr {
            Logger.shared.log("WindowHotkeys: event handler install failed (\(status))")
        }
    }

    /// Register a single hotkey for the given action. Pass `keyCode == 0` to
    /// unregister.
    public func bind(_ action: WindowAction, keyCode: UInt32, modifiers: UInt32) {
        unbind(action)
        guard keyCode > 0 else { return }

        let id = nextID
        nextID += 1
        var hotKeyID = EventHotKeyID(signature: signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else {
            Logger.shared.log("WindowHotkeys: register failed for \(action.rawValue) keyCode=\(keyCode) mods=\(modifiers) (err \(status))")
            return
        }
        registrations[action] = ref
        idToAction[id] = action
        Logger.shared.log("WindowHotkeys: bound \(action.rawValue) keyCode=\(keyCode) mods=\(modifiers)")
    }

    public func unbind(_ action: WindowAction) {
        if let ref = registrations.removeValue(forKey: action) {
            UnregisterEventHotKey(ref)
            idToAction = idToAction.filter { _, value in value != action }
        }
    }

    public func unbindAll() {
        for action in registrations.keys {
            unbind(action)
        }
    }

    public var boundActions: Set<WindowAction> {
        Set(registrations.keys)
    }
}
