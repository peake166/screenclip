import AppKit
import Carbon
import Foundation

enum CaptureHotKeyID {
    static let scrollCancel: UInt32 = 3
    static let translationCancel: UInt32 = 5
}

enum ShortcutAction: String, CaseIterable {
    case copy, scroll, translate
    var title: String {
        switch self { case .copy: return "截图并复制"; case .scroll: return "滚动截图"; case .translate: return "截图翻译" }
    }
    var hotKeyID: UInt32 {
        switch self { case .copy: return 1; case .scroll: return 2; case .translate: return 4 }
    }
    var symbolName: String {
        switch self { case .copy: return "viewfinder"; case .scroll: return "rectangle.portrait.on.rectangle.portrait"; case .translate: return "character.bubble" }
    }
}

struct Shortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String
    static let modifierMask = UInt32(cmdKey | optionKey | controlKey | shiftKey)
    static let defaults: [ShortcutAction: Shortcut] = [
        .copy: Shortcut(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(controlKey | optionKey | cmdKey), keyLabel: "4"),
        .scroll: Shortcut(keyCode: UInt32(kVK_ANSI_5), modifiers: UInt32(controlKey | optionKey | cmdKey), keyLabel: "5"),
        .translate: Shortcut(keyCode: UInt32(kVK_ANSI_6), modifiers: UInt32(controlKey | optionKey | cmdKey), keyLabel: "6")
    ]
    var isValid: Bool {
        let modifiersOnly: Set<UInt32> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        return keyCode < 128 && !modifiersOnly.contains(keyCode)
            && modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
            && modifiers & ~Self.modifierMask == 0 && !keyLabel.isEmpty && keyLabel.count <= 16
    }
    var display: String { Self.modifierSymbols(modifiers) + keyLabel }
    static func modifierSymbols(_ flags: UInt32) -> String {
        [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { flags & UInt32($0.0) != 0 }.map(\.1).joined()
    }
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        for (flag, value) in [(NSEvent.ModifierFlags.command, cmdKey), (.option, optionKey), (.control, controlKey), (.shift, shiftKey)] {
            if flags.contains(flag) { result |= UInt32(value) }
        }
        return result
    }
    static func from(_ event: NSEvent) -> Shortcut {
        let labels: [UInt16: String] = [
            0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",
            18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"-",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",
            36:"↩",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",48:"⇥",49:"空格",50:"`",51:"⌫",53:"⎋",
            64:"F17",65:".",67:"*",69:"+",71:"清除",75:"/",76:"⌤",78:"-",79:"F18",80:"F19",81:"=",82:"0",83:"1",84:"2",85:"3",86:"4",87:"5",88:"6",89:"7",90:"F20",91:"8",92:"9",
            96:"F5",97:"F6",98:"F7",99:"F3",100:"F8",101:"F9",103:"F11",105:"F13",106:"F16",107:"F14",109:"F10",111:"F12",113:"F15",114:"帮助",115:"↖",116:"⇞",117:"⌦",118:"F4",119:"↘",120:"F2",121:"⇟",122:"F1",123:"←",124:"→",125:"↓",126:"↑"
        ]
        let label = labels[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        return Shortcut(keyCode: UInt32(event.keyCode), modifiers: carbonModifiers(event.modifierFlags), keyLabel: label)
    }
    func matches(_ other: Shortcut) -> Bool { keyCode == other.keyCode && modifiers == other.modifiers }
}

final class ShortcutPreferences {
    private let defaults: UserDefaults
    private let apply: ([ShortcutAction: Shortcut]) -> Bool
    private(set) var bindings = Shortcut.defaults
    private static let storageKey = "captureShortcuts.v1"
    private struct Saved: Codable { let copy: Shortcut?; let scroll: Shortcut?; let translate: Shortcut?; let version: Int? }
    init(defaults: UserDefaults = .standard, apply: @escaping ([ShortcutAction: Shortcut]) -> Bool) {
        self.defaults = defaults; self.apply = apply
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            var translated = saved.translate
            if saved.version == nil, let proposed = Shortcut.defaults[.translate],
               ![saved.copy, saved.scroll].compactMap({ $0 }).contains(where: { $0.matches(proposed) }) { translated = proposed }
            let values = [saved.copy, saved.scroll, translated].compactMap { $0 }
            guard values.allSatisfy(\.isValid), !values.enumerated().contains(where: { index, value in values.dropFirst(index + 1).contains(where: { $0.matches(value) }) }) else { return }
            bindings = [:]
            bindings[.copy] = saved.copy; bindings[.scroll] = saved.scroll; bindings[.translate] = translated
        }
    }
    func change(_ action: ShortcutAction, to shortcut: Shortcut?) -> String? {
        if let shortcut {
            guard shortcut.isValid else { return "请搭配 ⌘、⌥ 或 ⌃ 使用" }
            if bindings.contains(where: { $0.key != action && $0.value.matches(shortcut) }) {
                return "操作之间不能使用相同快捷键"
            }
        }
        var proposed = bindings; proposed[action] = shortcut
        return commit(proposed)
    }
    func reset() -> String? { commit(Shortcut.defaults) }
    private func commit(_ proposed: [ShortcutAction: Shortcut]) -> String? {
        guard apply(proposed) else { return "快捷键已被占用，请换一组" }
        bindings = proposed
        if let data = try? JSONEncoder().encode(Saved(copy: proposed[.copy], scroll: proposed[.scroll], translate: proposed[.translate], version: 2)) {
            defaults.set(data, forKey: Self.storageKey)
        }
        return nil
    }
}
