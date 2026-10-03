import AppKit
import Carbon.HIToolbox

struct HotkeyConfig: Equatable, Codable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var enabled: Bool = true

    static let pipDefault = HotkeyConfig(
        keyCode: UInt32(kVK_ANSI_P), carbonModifiers: UInt32(controlKey | optionKey)
    )
    static let regionDefault = HotkeyConfig(
        keyCode: UInt32(kVK_ANSI_P), carbonModifiers: UInt32(controlKey | optionKey | shiftKey)
    )
    static let closeAllDefault = HotkeyConfig(
        keyCode: UInt32(kVK_ANSI_Backslash), carbonModifiers: UInt32(controlKey | optionKey)
    )

    var displayString: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        s += KeyCodeNames.name(for: keyCode)
        return s
    }

    var eventModifiers: NSEvent.ModifierFlags {
        var f = NSEvent.ModifierFlags()
        if carbonModifiers & UInt32(controlKey) != 0 { f.insert(.control) }
        if carbonModifiers & UInt32(optionKey) != 0 { f.insert(.option) }
        if carbonModifiers & UInt32(shiftKey) != 0 { f.insert(.shift) }
        if carbonModifiers & UInt32(cmdKey) != 0 { f.insert(.command) }
        return f
    }
}

enum KeyCodeNames {
    private static let table: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
        UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
        UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
        UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
        UInt32(kVK_ANSI_9): "9",
        UInt32(kVK_ANSI_Backslash): "\\", UInt32(kVK_ANSI_Slash): "/",
        UInt32(kVK_ANSI_Comma): ",", UInt32(kVK_ANSI_Period): ".",
        UInt32(kVK_ANSI_Semicolon): ";", UInt32(kVK_ANSI_Quote): "'",
        UInt32(kVK_ANSI_LeftBracket): "[", UInt32(kVK_ANSI_RightBracket): "]",
        UInt32(kVK_ANSI_Minus): "-", UInt32(kVK_ANSI_Equal): "=",
        UInt32(kVK_ANSI_Grave): "`",
        UInt32(kVK_Space): "Space", UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥",
        UInt32(kVK_Escape): "⎋", UInt32(kVK_Delete): "⌫",
        UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
    ]

    static func name(for keyCode: UInt32) -> String {
        table[keyCode] ?? "Key\(keyCode)"
    }
}

///
enum ChromiumCompatibilityMode: String, CaseIterable {
    case off
    case ask
    case automatic

    var label: String {
        switch self {
        case .off: return ("Off")
        case .ask: return ("Ask")
        case .automatic: return ("Automatic (verified apps only)")
        }
    }
}

final class Preferences {
    static let shared = Preferences(defaults: .standard)
    private let d: UserDefaults
    private let now: () -> TimeInterval

    private enum K {
        static let fpsByApp = "fpsByApp"
        static let widthByApp = "widthByApp"
        static let originByApp = "originByApp"
        static let windowOriginLastUsed = "windowOriginLastUsed"
        static let hotkeyPiP = "hotkey.pip"
        static let hotkeyRegion = "hotkey.region"
        static let hotkeyCloseAll = "hotkey.closeAll"
        static let enhancedMode = "enhancedMode"
        static let defaultFPS = "defaultFPS"
        static let autoHideDefault = "autoHideDefault"
        static let autoHideOpacity = "autoHideOpacity"
        static let idleDetectionDefault = "idleDetectionDefault"
        static let windowLevelMode = "windowLevelMode"
        static let launchAtLogin = "launchAtLogin"
        static let showsCursor = "showsCursor"
        static let hasSeenOnboarding = "hasSeenOnboarding"
        static let clickToActivateSource = "clickToActivateSource"
        static let chromiumCompatibilityMode = "chromiumCompatibilityMode"
    }

    init(defaults: UserDefaults = .standard,
         now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        d = defaults
        self.now = now
        d.register(defaults: [
            K.defaultFPS: FPSStep.fifteen.rawValue,
            K.autoHideDefault: false,
            K.autoHideOpacity: Double(Self.defaultAutoHideOpacity),
            K.idleDetectionDefault: true,
            K.enhancedMode: false,
            K.windowLevelMode: WindowLevelMode.global.rawValue,
            K.showsCursor: false,
            K.hasSeenOnboarding: false,
            K.clickToActivateSource: true,
            K.chromiumCompatibilityMode: ChromiumCompatibilityMode.off.rawValue,
        ])
    }


    var defaultFPS: FPSStep {
        get { FPSStep(rawValue: d.integer(forKey: K.defaultFPS)) ?? .fifteen }
        set { d.set(newValue.rawValue, forKey: K.defaultFPS) }
    }

    var autoHideDefault: Bool {
        get { d.bool(forKey: K.autoHideDefault) }
        set { d.set(newValue, forKey: K.autoHideDefault) }
    }

    static let minAutoHideOpacity: CGFloat = 0.05
    static let maxAutoHideOpacity: CGFloat = 0.95
    static let defaultAutoHideOpacity: CGFloat = 0.35
    static let autoHideOpacitySteps: [CGFloat] = (1...19).map { CGFloat($0) * 0.05 }

    var autoHideOpacity: CGFloat {
        get { Self.clampOpacity(CGFloat(d.double(forKey: K.autoHideOpacity))) }
        set { d.set(Double(Self.clampOpacity(newValue)), forKey: K.autoHideOpacity) }
    }

    static func clampOpacity(_ value: CGFloat) -> CGFloat {
        guard value.isFinite, value > 0 else { return defaultAutoHideOpacity }
        return min(max(value, minAutoHideOpacity), maxAutoHideOpacity)
    }

    static func nearestOpacityStep(_ value: CGFloat) -> CGFloat {
        let clamped = clampOpacity(value)
        return autoHideOpacitySteps.min { abs($0 - clamped) < abs($1 - clamped) } ?? defaultAutoHideOpacity
    }

    static func opacityLabel(_ value: CGFloat) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    var idleDetectionDefault: Bool {
        get { d.bool(forKey: K.idleDetectionDefault) }
        set { d.set(newValue, forKey: K.idleDetectionDefault) }
    }

    var enhancedMode: Bool {
        get { d.bool(forKey: K.enhancedMode) }
        set { d.set(newValue, forKey: K.enhancedMode) }
    }

    var windowLevelMode: WindowLevelMode {
        get { WindowLevelMode(rawValue: d.string(forKey: K.windowLevelMode) ?? "") ?? .global }
        set { d.set(newValue.rawValue, forKey: K.windowLevelMode) }
    }

    var launchAtLogin: Bool {
        get { d.bool(forKey: K.launchAtLogin) }
        set { d.set(newValue, forKey: K.launchAtLogin) }
    }

    var showsCursor: Bool {
        get { d.bool(forKey: K.showsCursor) }
        set { d.set(newValue, forKey: K.showsCursor) }
    }

    var hasSeenOnboarding: Bool {
        get { d.bool(forKey: K.hasSeenOnboarding) }
        set { d.set(newValue, forKey: K.hasSeenOnboarding) }
    }

    var clickToActivateSource: Bool {
        get { d.bool(forKey: K.clickToActivateSource) }
        set { d.set(newValue, forKey: K.clickToActivateSource) }
    }

    var chromiumCompatibilityMode: ChromiumCompatibilityMode {
        get {
            ChromiumCompatibilityMode(
                rawValue: d.string(forKey: K.chromiumCompatibilityMode) ?? ""
            ) ?? .off
        }
        set { d.set(newValue.rawValue, forKey: K.chromiumCompatibilityMode) }
    }


    var pipHotkey: HotkeyConfig {
        get { hotkey(K.hotkeyPiP) ?? .pipDefault }
        set { setHotkey(newValue, K.hotkeyPiP) }
    }

    var regionHotkey: HotkeyConfig {
        get { hotkey(K.hotkeyRegion) ?? .regionDefault }
        set { setHotkey(newValue, K.hotkeyRegion) }
    }

    var closeAllHotkey: HotkeyConfig {
        get { hotkey(K.hotkeyCloseAll) ?? .closeAllDefault }
        set { setHotkey(newValue, K.hotkeyCloseAll) }
    }

    func resetHotkeys() {
        pipHotkey = .pipDefault
        regionHotkey = .regionDefault
        closeAllHotkey = .closeAllDefault
    }

    private func hotkey(_ key: String) -> HotkeyConfig? {
        guard let data = d.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(HotkeyConfig.self, from: data)
    }

    private func setHotkey(_ cfg: HotkeyConfig, _ key: String) {
        guard let data = try? JSONEncoder().encode(cfg) else { return }
        d.set(data, forKey: key)
    }


    func fps(for prefKey: String) -> FPSStep {
        if let dict = d.dictionary(forKey: K.fpsByApp) as? [String: Int],
           let v = dict[prefKey], let step = FPSStep(rawValue: v) {
            return step
        }
        if Self.lowFPSHeuristicKeys.contains(where: { prefKey.lowercased().contains($0) }) {
            return .five
        }
        return defaultFPS
    }

    func setFPS(_ fps: FPSStep, for prefKey: String) {
        var dict = (d.dictionary(forKey: K.fpsByApp) as? [String: Int]) ?? [:]
        dict[prefKey] = fps.rawValue
        d.set(dict, forKey: K.fpsByApp)
    }

    func preferredWidth(for prefKey: String) -> CGFloat? {
        guard let dict = d.dictionary(forKey: K.widthByApp) as? [String: Double],
              let v = dict[prefKey] else { return nil }
        return CGFloat(v)
    }

    func setPreferredWidth(_ width: CGFloat, for prefKey: String) {
        var dict = (d.dictionary(forKey: K.widthByApp) as? [String: Double]) ?? [:]
        dict[prefKey] = Double(width)
        d.set(dict, forKey: K.widthByApp)
    }

    func origin(for identity: PositionMemoryIdentity) -> CGPoint? {
        storedOrigin(for: identity.preferenceKey, touch: true)
    }

    func fallbackOrigin(for identity: PositionMemoryIdentity) -> CGPoint? {
        storedOrigin(for: identity.fallbackPreferenceKey, touch: false)
    }

    private func storedOrigin(for prefKey: String, touch: Bool) -> CGPoint? {
        guard let dict = d.dictionary(forKey: K.originByApp) as? [String: [Double]],
              let v = dict[prefKey], v.count == 2 else { return nil }
        if touch { touchPositionOriginIfNeeded(prefKey) }
        return CGPoint(x: v[0], y: v[1])
    }

    func setOrigin(_ origin: CGPoint, for identity: PositionMemoryIdentity) {
        var dict = (d.dictionary(forKey: K.originByApp) as? [String: [Double]]) ?? [:]
        let value = [Double(origin.x), Double(origin.y)]
        dict[identity.preferenceKey] = value
        dict[identity.fallbackPreferenceKey] = value
        if PositionMemoryIdentity.isSpecificPreferenceKey(identity.preferenceKey) {
            var lastUsed = (d.dictionary(forKey: K.windowOriginLastUsed) as? [String: Double]) ?? [:]
            lastUsed[identity.preferenceKey] = now()
            prunePositionOrigins(&dict, lastUsed: &lastUsed)
            d.set(lastUsed, forKey: K.windowOriginLastUsed)
        }
        d.set(dict, forKey: K.originByApp)
    }

    private static let maxRememberedPositionOrigins = 128

    private func touchPositionOriginIfNeeded(_ key: String) {
        guard PositionMemoryIdentity.isSpecificPreferenceKey(key) else { return }
        var lastUsed = (d.dictionary(forKey: K.windowOriginLastUsed) as? [String: Double]) ?? [:]
        lastUsed[key] = now()
        d.set(lastUsed, forKey: K.windowOriginLastUsed)
    }

    private func prunePositionOrigins(_ origins: inout [String: [Double]],
                                      lastUsed: inout [String: Double]) {
        let positionKeys = origins.keys.filter {
            PositionMemoryIdentity.isSpecificPreferenceKey($0)
        }
        guard positionKeys.count > Self.maxRememberedPositionOrigins else { return }
        let stale = positionKeys.sorted {
            (lastUsed[$0] ?? 0) < (lastUsed[$1] ?? 0)
        }.prefix(positionKeys.count - Self.maxRememberedPositionOrigins)
        for key in stale {
            origins.removeValue(forKey: key)
            lastUsed.removeValue(forKey: key)
        }
    }

    private static let lowFPSHeuristicKeys = [
        "terminal", "iterm", "warp", "alacritty", "kitty", "wezterm", "tabby", "ghostty",
        "console", "activitymonitor", "xcode", "vscode", "code", "sublime", "jetbrains",
        "intellij", "pycharm", "goland", "webstorm", "cursor", "zed",
    ]
}
