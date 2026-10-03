import AppKit
import Carbon.HIToolbox

///
final class HotkeyManager {
    static let shared = HotkeyManager()

    enum Action: UInt32 {
        case pip = 1
        case region = 2
        case closeAll = 3
    }

    var onTrigger: ((Action) -> Void)?

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private(set) var failedActions: Set<Action> = []

    private static let signature: OSType = 0x4D57_5049  // 'MWPI'

    private init() {}


    func start() {
        installHandlerIfNeeded()
        reload()
    }

    func reload() {
        unregisterAll()
        failedActions = []
        let prefs = Preferences.shared
        register(prefs.pipHotkey, for: .pip)
        register(prefs.regionHotkey, for: .region)
        register(prefs.closeAllHotkey, for: .closeAll)
    }

    func unregisterAll() {
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }


    @discardableResult
    private func register(_ config: HotkeyConfig, for action: Action) -> Bool {
        guard config.enabled else { return true }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: action.rawValue)
        let status = RegisterEventHotKey(
            config.keyCode,
            config.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            failedActions.insert(action)
            Log.warn("\(config.displayString) status=\(status)")
            return false
        }
        refs[action.rawValue] = ref
        Log.info("\(config.displayString) → \(action)")
        return true
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotkeyEventHandler,
            1,
            &spec,
            nil,
            &eventHandler
        )
        if status != noErr { Log.error("status=\(status)") }
    }

    fileprivate func handle(id: UInt32) {
        guard let action = Action(rawValue: id) else { return }
        Log.debug("\(action)")
        onTrigger?(action)
    }

    static func isAvailable(_ config: HotkeyConfig) -> Bool {
        var ref: EventHotKeyRef?
        let probeID = EventHotKeyID(signature: signature, id: 999)
        let status = RegisterEventHotKey(
            config.keyCode, config.carbonModifiers, probeID,
            GetApplicationEventTarget(), 0, &ref
        )
        if status == noErr, let ref {
            UnregisterEventHotKey(ref)
            return true
        }
        return false
    }
}

private func hotkeyEventHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    let id = hotKeyID.id
    DispatchQueue.main.async { HotkeyManager.shared.handle(id: id) }
    return noErr
}
