import Carbon.HIToolbox
import Foundation

/// System-wide hot key via Carbon's RegisterEventHotKey: public, needs no
/// Accessibility or Input Monitoring permission, and only observes the one
/// registered key combination (no keyboard tap).
final class HotKey {
    private static var registry: [UInt32: HotKey] = [:]
    private static var handlerInstalled = false
    private static var nextID: UInt32 = 1

    private var ref: EventHotKeyRef?
    private let id: UInt32
    private let action: () -> Void

    /// Default emergency shortcut: Control-Option-Command-E.
    static let emergencyKeyCode = UInt32(kVK_ANSI_E)
    static let emergencyModifiers = UInt32(controlKey | optionKey | cmdKey)
    static let emergencyDisplay = "⌃⌥⌘E"
    /// Quick start: focus the frontmost window for the default duration.
    static let quickStartKeyCode = UInt32(kVK_ANSI_F)
    static let quickStartDisplay = "⌃⌥⌘F"

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        id = HotKey.nextID
        HotKey.nextID += 1
        self.action = action
        HotKey.installHandler()
        let hkID = EventHotKeyID(signature: OSType(0x454B_4743), id: id) // 'EKGC'
        if RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref) == noErr {
            HotKey.registry[id] = self
        }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.registry[id] = nil
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            if status == noErr {
                let id = hkID.id
                DispatchQueue.main.async { HotKey.registry[id]?.action() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
