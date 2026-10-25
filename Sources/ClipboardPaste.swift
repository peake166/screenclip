// Native paste events follow Maccy's/Clipy's published approach.
// Copyright (c) Alex Rodionov and contributors. MIT; see ThirdPartyLicenses/Maccy-LICENSE.txt.
import AppKit
import ApplicationServices
import Carbon

struct ClipboardPasteTarget {
    let application: NSRunningApplication
    private let focusedWindow: AXUIElement?
    private let focusedElement: AXUIElement?
    init(application: NSRunningApplication) {
        self.application = application
        focusedWindow = Self.attribute(kAXFocusedWindowAttribute, of: application.processIdentifier)
        focusedElement = Self.attribute(kAXFocusedUIElementAttribute, of: application.processIdentifier)
    }
    var name: String { application.localizedName ?? "原应用" }
    var windowStillMatches: Bool {
        let pid = application.processIdentifier
        if let focusedWindow {
            guard let current = Self.attribute(kAXFocusedWindowAttribute, of: pid), CFEqual(focusedWindow, current) else { return false }
        }
        if let focusedElement {
            guard let current = Self.attribute(kAXFocusedUIElementAttribute, of: pid), CFEqual(focusedElement, current) else { return false }
        }
        return true
    }
    private static func attribute(_ attribute: String, of pid: pid_t) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}

enum ClipboardPasteDecision: Equatable {
    case wait, send, permission, targetGone, targetChanged, secureInput, timedOut
}

/// A bounded, cancellable focus check. A successful event post is never retried automatically.
enum ClipboardPastePolicy {
    static func decide(trusted: Bool, targetRunning: Bool, targetFrontmost: Bool, previouslyFrontmost: Bool,
                       windowMatches: Bool, modifiersReleased: Bool, secureInput: Bool, elapsed: TimeInterval) -> ClipboardPasteDecision {
        guard trusted else { return .permission }
        guard targetRunning else { return .targetGone }
        guard windowMatches else { return .targetChanged }
        guard !secureInput else { return .secureInput }
        if previouslyFrontmost && !targetFrontmost { return .targetChanged }
        if elapsed >= 1.2 { return .timedOut }
        return targetFrontmost && modifiersReleased ? .send : .wait
    }
}

enum ClipboardPasteKeys {
    static func events() -> (CGEvent, CGEvent)? {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitSystemDefinedEvents],
                                                           state: .eventSuppressionStateSuppressionInterval)
        let code = keyCode()
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return nil }
        let flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x000008)
        down.flags = flags; up.flags = flags
        return (down, up)
    }
    private static func keyCode() -> CGKeyCode {
        // Translate with Command held, including layouts that switch to QWERTY for Command shortcuts.
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return CGKeyCode(kVK_ANSI_V) }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        let layout = UnsafeRawPointer(CFDataGetBytePtr(data)).assumingMemoryBound(to: UCKeyboardLayout.self)
        for key in UInt16(0)..<UInt16(128) {
            var dead: UInt32 = 0, length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, key, UInt16(kUCKeyActionDown), UInt32(cmdKey >> 8),
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, 4, &length, &chars)
            if status == noErr, length == 1, chars[0] == 118 || chars[0] == 86 { return key }
        }
        return CGKeyCode(kVK_ANSI_V)
    }
}

@MainActor
final class ClipboardPaster {
    enum Outcome { case sent, copiedOnly(String), needsPermission }
    private var task: Task<Void, Never>?
    func cancel() { task?.cancel(); task = nil }
    func paste(to target: ClipboardPasteTarget?, completion: @escaping (Outcome) -> Void) {
        cancel()
        guard let target, target.application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            completion(.copiedOnly("已复制 · 请到输入框按 ⌘V 粘贴")); return
        }
        guard AXIsProcessTrusted() else { completion(.needsPermission); return }
        target.application.activate(options: [])
        task = Task { [weak self] in
            let start = ProcessInfo.processInfo.systemUptime
            var previouslyFrontmost = false
            while !Task.isCancelled {
                let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == target.application.processIdentifier
                let modifiers = CGEventSource.flagsState(.combinedSessionState)
                    .intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
                let decision = ClipboardPastePolicy.decide(trusted: AXIsProcessTrusted(),
                    targetRunning: !target.application.isTerminated, targetFrontmost: frontmost,
                    previouslyFrontmost: previouslyFrontmost, windowMatches: frontmost && modifiers.isEmpty ? target.windowStillMatches : true,
                    modifiersReleased: modifiers.isEmpty, secureInput: IsSecureEventInputEnabled(),
                    elapsed: ProcessInfo.processInfo.systemUptime - start)
                previouslyFrontmost = previouslyFrontmost || frontmost
                switch decision {
                case .wait:
                    do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return }
                case .send:
                    guard !Task.isCancelled else { return }
                    guard let events = ClipboardPasteKeys.events() else {
                        self?.task = nil; completion(.copiedOnly("当前无法自动粘贴 · 内容已复制，可按 ⌘V 粘贴")); return
                    }
                    events.0.postToPid(target.application.processIdentifier)
                    events.1.postToPid(target.application.processIdentifier)
                    self?.task = nil; completion(.sent); return
                case .permission: self?.task = nil; completion(.needsPermission); return
                case .targetGone, .targetChanged:
                    self?.task = nil; completion(.copiedOnly("输入位置已改变 · 内容已复制，可按 ⌘V 粘贴")); return
                case .secureInput, .timedOut:
                    self?.task = nil; completion(.copiedOnly("当前无法自动粘贴 · 内容已复制，可按 ⌘V 粘贴")); return
                }
            }
        }
    }
}
