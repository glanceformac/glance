import AppKit
import Carbon.HIToolbox

/// Global hotkeys via Carbon RegisterEventHotKey (no Accessibility permission needed).
@MainActor
enum HotKeyCenter {
    private static var refs: [UInt32: EventHotKeyRef] = [:]
    private static var actions: [UInt32: () -> Void] = [:]
    private static var handler: EventHandlerRef?

    static func register(id: UInt32, keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        installHandler()
        unregister(id: id)
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x49534C44), id: id) // 'ISLD'
        if RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hkID, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
            refs[id] = ref
            actions[id] = action
        } else {
            NSLog("Glance: hotkey \(id) is taken by another app")
        }
    }

    static func unregister(id: UInt32) {
        if let r = refs.removeValue(forKey: id) { UnregisterEventHotKey(r) }
        actions[id] = nil
    }

    fileprivate static func fire(_ id: UInt32) { actions[id]?() }

    private static func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeyCenter.fire(id) } }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}

/// ⌃⌥Y allow, ⌃⌥N deny, registered only while a Claude request is on screen.
@MainActor
enum PermissionHotKeys {
    static func update(active: Bool) {
        if active {
            HotKeyCenter.register(id: 1, keyCode: kVK_ANSI_Y, modifiers: controlKey | optionKey) {
                IslandModel.shared.answerCurrent(allow: true)
            }
            HotKeyCenter.register(id: 2, keyCode: kVK_ANSI_N, modifiers: controlKey | optionKey) {
                IslandModel.shared.answerCurrent(allow: false)
            }
        } else {
            HotKeyCenter.unregister(id: 1)
            HotKeyCenter.unregister(id: 2)
        }
    }
}

/// ⌃⌥V opens the Clipboard tab.
@MainActor
enum ClipboardHotKey {
    static func update() {
        if AppSettings.shared.prefs.clipboardHotkey {
            HotKeyCenter.register(id: 3, keyCode: kVK_ANSI_V, modifiers: controlKey | optionKey) {
                IslandModel.shared.toggleClipboardFromHotkey()
            }
        } else {
            HotKeyCenter.unregister(id: 3)
        }
    }
}
