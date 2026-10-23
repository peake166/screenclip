import AppKit
import Carbon

final class ShortcutRecorder: NSControl {
    var shortcut: Shortcut? { didSet { updateLabel() } }
    private(set) var isRecording = false { didSet { updateLabel() } }
    private var heldModifiers: UInt32 = 0 { didSet { updateLabel() } }
    private let label = NSTextField(labelWithString: "未设置")
    var onBegin: (() -> Bool)?
    var onEnd: (() -> Void)?
    var onApply: ((Shortcut?) -> String?)?
    var onError: ((String?) -> Void)?

    init() {
        super.init(frame: .zero)
        focusRingType = .none
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("修改快捷键")
        toolTip = "点击录制；Esc 取消，Delete 清除"
        setAccessibilityHelp("按下组合键以修改，Esc 取消，Delete 清除")
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 154).isActive = true
        heightAnchor.constraint(equalToConstant: 32).isActive = true
        label.alignment = .center; label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityElement(false); addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        updateLabel()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var acceptsFirstResponder: Bool { true }
    override func accessibilityValue() -> Any? { isRecording ? "正在录制快捷键" : shortcut?.display ?? "未设置" }
    override func accessibilityPerformPress() -> Bool { beginRecording(); return true }
    override func mouseDown(with event: NSEvent) { beginRecording() }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    private func updateLabel() {
        label.stringValue = isRecording ? (heldModifiers == 0 ? "按下组合键…" : Shortcut.modifierSymbols(heldModifiers) + "…") : shortcut?.display ?? "未设置"
        label.font = .systemFont(ofSize: isRecording ? 12 : 13, weight: .medium)
        label.textColor = isRecording ? .screenClipAccent : (shortcut == nil ? .tertiaryLabelColor : .labelColor)
        needsDisplay = true
    }

    func beginRecording() {
        guard !isRecording else { return }
        window?.makeFirstResponder(self)
        guard onBegin?() ?? true else { return }
        isRecording = true; heldModifiers = 0
        onError?(nil); needsDisplay = true
    }
    func cancelRecording() {
        guard isRecording else { return }
        onError?(nil); endRecording()
    }
    private func endRecording() {
        guard isRecording else { return }
        isRecording = false; heldModifiers = 0
        needsDisplay = true; onEnd?()
    }
    override func resignFirstResponder() -> Bool {
        cancelRecording()
        return super.resignFirstResponder()
    }
    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return }
        heldModifiers = Shortcut.carbonModifiers(event.modifierFlags)
        needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        guard !event.isARepeat else { return }
        let modifiers = Shortcut.carbonModifiers(event.modifierFlags)
        if event.keyCode == UInt16(kVK_Escape), modifiers == 0 { cancelRecording(); return }
        let clear = (event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete)) && modifiers == 0
        let proposal = clear ? nil : Shortcut.from(event)
        if let proposal, !proposal.isValid { onError?("请搭配 ⌘、⌥ 或 ⌃ 使用"); return }
        if let error = onApply?(proposal) { onError?(error); return }
        shortcut = proposal; onError?(nil); endRecording()
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isRecording { keyDown(with: event); return true }
        return super.performKeyEquivalent(with: event)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let focus = window?.firstResponder === self
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        (isRecording ? NSColor.screenClipAccent.withAlphaComponent(0.09) : NSColor.controlBackgroundColor.withAlphaComponent(0.7)).setFill()
        shape.fill()
        (isRecording || focus ? NSColor.screenClipAccent : NSColor.separatorColor.withAlphaComponent(0.6)).setStroke()
        shape.lineWidth = isRecording || focus ? 1.5 : 0.7; shape.stroke()
    }
}
