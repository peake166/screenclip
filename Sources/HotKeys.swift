import AppKit
import Carbon

final class HotKeys {
    private var handler: EventHandlerRef?
    private var references: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var combinations: [UInt32: (UInt32, UInt32)] = [:]

    init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            guard result == noErr else { return result }
            let owner = Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue()
            owner.actions[key.id]?()
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    @discardableResult
    func register(id: UInt32, key: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        if let existing = combinations[id], existing.0 == key, existing.1 == modifiers {
            actions[id] = action
            return true
        }
        var reference: EventHotKeyRef?
        let result = RegisterEventHotKey(key, modifiers, EventHotKeyID(signature: 0x53434C50, id: id),
                                        GetApplicationEventTarget(), 0, &reference)
        guard result == noErr, let reference else { return false }
        if let previous = references[id] { UnregisterEventHotKey(previous) }
        references[id] = reference; actions[id] = action
        combinations[id] = (key, modifiers)
        return true
    }

    func unregister(_ id: UInt32) {
        if let reference = references.removeValue(forKey: id) { UnregisterEventHotKey(reference) }
        actions.removeValue(forKey: id)
        combinations.removeValue(forKey: id)
    }
    deinit {
        for ref in references.values { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
