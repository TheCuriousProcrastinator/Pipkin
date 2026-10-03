import AppKit
import Carbon.HIToolbox

///
final class EventTapManager {
    static let shared = EventTapManager()

    enum HoverKey {
        case zoomIn, zoomOut, cycleFPS, toggleIdleDetection, toggleHidden, close
    }

    var onGlobalTrigger: ((HotkeyManager.Action) -> Void)?
    var onHoverKey: ((HoverKey, UUID) -> Void)?

    private(set) var isEnabled = false
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var fnDownAt: CFAbsoluteTime?
    private var fnCombinedWithKey = false
    private let fnTapMaxInterval: CFTimeInterval = 0.4

    private init() {}


    @discardableResult
    func syncWithPreferences() -> Bool {
        if Preferences.shared.enhancedMode {
            return enable()
        } else {
            disable()
            return false
        }
    }

    @discardableResult
    func enable() -> Bool {
        if isEnabled { return true }
        guard Permissions.hasAccessibility else {
            Log.warn("")
            return false
        }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.error("")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        runLoopSource = source
        isEnabled = true
        Log.info("fn  + ")
        return true
    }

    func disable() {
        guard isEnabled else { return }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        isEnabled = false
        fnDownAt = nil
        Log.info("")
    }

    fileprivate func reEnableAfterDisable() {
        guard let tap else { return }
        Log.warn("")
        CGEvent.tapEnable(tap: tap, enable: true)
    }


    fileprivate func handleKeyDown(keyCode: Int64, flags: CGEventFlags) -> Bool {
        fnCombinedWithKey = true

        let prefs = Preferences.shared
        if flags.contains(.maskSecondaryFn),
           !flags.contains(.maskCommand), !flags.contains(.maskControl), !flags.contains(.maskAlternate),
           UInt32(keyCode) == prefs.pipHotkey.keyCode {
            let action: HotkeyManager.Action = flags.contains(.maskShift) ? .region : .pip
            DispatchQueue.main.async { [weak self] in self?.onGlobalTrigger?(action) }
            return true
        }

        guard let hovered = HoverMonitor.shared.currentHovered(),
              !flags.contains(.maskCommand), !flags.contains(.maskControl),
              !flags.contains(.maskAlternate) else { return false }

        let key: HoverKey?
        switch Int(keyCode) {
        case kVK_ANSI_Equal, kVK_ANSI_KeypadPlus: key = .zoomIn
        case kVK_ANSI_Minus, kVK_ANSI_KeypadMinus: key = .zoomOut
        case kVK_ANSI_F: key = .cycleFPS
        case kVK_ANSI_D: key = .toggleIdleDetection
        case kVK_Delete, kVK_ForwardDelete: key = .close
        default: key = nil
        }
        guard let key else { return false }
        DispatchQueue.main.async { [weak self] in self?.onHoverKey?(key, hovered) }
        return true
    }

    fileprivate func handleFlagsChanged(keyCode: Int64, flags: CGEventFlags) {
        guard Int(keyCode) == kVK_Function else { return }
        if flags.contains(.maskSecondaryFn) {
            fnDownAt = CFAbsoluteTimeGetCurrent()
            fnCombinedWithKey = false
        } else {
            defer { fnDownAt = nil }
            guard let down = fnDownAt, !fnCombinedWithKey,
                  CFAbsoluteTimeGetCurrent() - down <= fnTapMaxInterval,
                  let hovered = HoverMonitor.shared.currentHovered() else { return }
            DispatchQueue.main.async { [weak self] in self?.onHoverKey?(.toggleHidden, hovered) }
        }
    }
}

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<EventTapManager>.fromOpaque(refcon).takeUnretainedValue()

    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        manager.reEnableAfterDisable()
        return nil
    case .keyDown:
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if manager.handleKeyDown(keyCode: keyCode, flags: event.flags) { return nil }
    case .flagsChanged:
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        manager.handleFlagsChanged(keyCode: keyCode, flags: event.flags)
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}
