import AppKit
import Carbon.HIToolbox

final class HotkeyRecorderView: NSView {

    var onChange: ((HotkeyConfig) -> Void)?

    var config: HotkeyConfig {
        didSet { needsDisplay = true }
    }

    private var isRecording = false {
        didSet { needsDisplay = true }
    }

    private var hintText: String?

    init(config: HotkeyConfig) {
        self.config = config
        super.init(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        wantsLayer = true
        setAccessibilityRole(.button)
        setAccessibilityLabel(("Shortcut recorder"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError(" xib") }

    override var intrinsicContentSize: NSSize { NSSize(width: 160, height: 24) }
    override var acceptsFirstResponder: Bool { true }


    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.16)
                     : NSColor.controlBackgroundColor).setFill()
        bg.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        bg.lineWidth = isRecording ? 1.5 : 1
        bg.stroke()

        let text: String
        if isRecording {
            text = hintText ?? ("Press a shortcut…")
        } else if !config.enabled {
            text = ("Not set")
        } else {
            text = config.displayString
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: isRecording ? .regular : .medium),
            .foregroundColor: isRecording ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attrs
        )
    }


    override func mouseDown(with event: NSEvent) {
        guard !isRecording else { return }
        hintText = nil
        isRecording = true
        window?.makeFirstResponder(self)
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        let keyCode = UInt32(event.keyCode)

        if keyCode == UInt32(kVK_Escape) {
            isRecording = false
            return
        }

        if keyCode == UInt32(kVK_Delete) {
            var cleared = config
            cleared.enabled = false
            config = cleared
            isRecording = false
            onChange?(cleared)
            return
        }

        let carbonModifiers = Self.carbonModifiers(from: event.modifierFlags)
        guard carbonModifiers != 0 else {
            hintText = ("Needs ⌃⌥⇧⌘")
            needsDisplay = true
            return
        }

        let candidate = HotkeyConfig(keyCode: keyCode, carbonModifiers: carbonModifiers, enabled: true)
        guard HotkeyManager.isAvailable(candidate) else {
            hintText = ("Already in use")
            needsDisplay = true
            return
        }

        config = candidate
        isRecording = false
        onChange?(candidate)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return false }
        keyDown(with: event)
        return true
    }


    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        return m
    }
}
