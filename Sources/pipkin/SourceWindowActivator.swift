import AppKit
import ApplicationServices
import Darwin

///
enum SourceWindowActivator {
    enum Result {
        case raised
        case applicationOnly
        case windowNotFound
        case activationFailed
        case applicationNotFound
    }

    private typealias GetWindowID = @convention(c) (
        AXUIElement, UnsafeMutablePointer<CGWindowID>
    ) -> AXError

    private static let getWindowID: GetWindowID? = {
        guard let handle = dlopen(nil, RTLD_LAZY),
              let symbol = dlsym(handle, "_AXUIElementGetWindow") else {
            Log.warn("AX  ID ")
            return nil
        }
        return unsafeBitCast(symbol, to: GetWindowID.self)
    }()

    static var isExactMatchAvailable: Bool { getWindowID != nil }

    private static let messagingTimeout: Float = 0.5

    private static func appElement(_ pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    static func windowInfo(of windowID: CGWindowID) -> [String: Any]? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID)
                as? [[String: Any]] else { return nil }
        return list.first {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID
        }
    }

    static func ownerPID(of windowID: CGWindowID) -> pid_t? {
        guard let number = windowInfo(of: windowID)?[kCGWindowOwnerPID as String] as? NSNumber
        else { return nil }
        return pid_t(number.int32Value)
    }

    static func lifecycleObservation(
        of windowID: CGWindowID,
        expectedPID: pid_t?
    ) -> SourceWindowObservation {
        let info = windowInfo(of: windowID)
        let actualPID = (info?[kCGWindowOwnerPID as String] as? NSNumber)
            .map { pid_t($0.int32Value) }
        let probePID = expectedPID ?? actualPID
        let processAlive = probePID.map(processIsAlive)
        let ownerPIDMatches: Bool? = {
            guard let expectedPID, let actualPID else { return nil }
            return expectedPID == actualPID
        }()
        let isOnScreen = (info?[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue
        let axMinimized: Bool? = {
            guard let actualPID,
                  expectedPID == nil || expectedPID == actualPID else { return nil }
            return minimizedState(of: windowID, pid: actualPID)
        }()
        return SourceWindowObservation(
            cgWindowExists: info != nil,
            processAlive: processAlive,
            ownerPIDMatches: ownerPIDMatches,
            isOnScreen: isOnScreen,
            axMinimized: axMinimized
        )
    }

    /// Returns AX minimized only when Accessibility can answer. No permission prompt.
    static func minimizedState(of windowID: CGWindowID) -> Bool? {
        guard let pid = ownerPID(of: windowID) else { return nil }
        return minimizedState(of: windowID, pid: pid)
    }

    private static func minimizedState(of windowID: CGWindowID, pid: pid_t) -> Bool? {
        guard Permissions.hasAccessibility else { return nil }
        let app = appElement(pid)
        guard let windows = windows(of: app),
              let target = exactWindow(id: windowID, in: windows) else { return nil }
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(target, kAXMinimizedAttribute as CFString, &raw) == .success
        else { return nil }
        return raw as? Bool
    }

    private static func processIsAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    static func activate(windowID: CGWindowID, pid: pid_t, fallbackTitle: String) -> Result {
        guard let runningApp = NSRunningApplication(processIdentifier: pid) else {
            return .applicationNotFound
        }

        guard Permissions.hasAccessibility else {
            return runningApp.activate() ? .applicationOnly : .activationFailed
        }

        let app = appElement(pid)
        guard let windows = windows(of: app),
              let target = exactWindow(id: windowID, in: windows)
                ?? uniqueWindow(titled: fallbackTitle, in: windows) else {
            _ = runningApp.activate()
            return .windowNotFound
        }

        AXUIElementSetAttributeValue(target, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
        let firstFocus = AXUIElementSetAttributeValue(
            app, kAXFocusedWindowAttribute as CFString, target
        )
        _ = runningApp.activate()
        let raised = AXUIElementPerformAction(target, kAXRaiseAction as CFString)
        let finalFocus = AXUIElementSetAttributeValue(
            app, kAXFocusedWindowAttribute as CFString, target
        )

        if raised == .success || firstFocus == .success || finalFocus == .success {
            return .raised
        }
        return .activationFailed
    }

    ///
    static func currentTitle(of windowID: CGWindowID) -> String? {
        guard let info = windowInfo(of: windowID) else { return nil }
        if let number = info[kCGWindowOwnerPID as String] as? NSNumber,
           let axTitle = currentTitle(of: windowID, pid: pid_t(number.int32Value)) {
            return axTitle
        }
        return info[kCGWindowName as String] as? String
    }

    static func canResolveExactWindow(id windowID: CGWindowID, pid: pid_t) -> Bool {
        guard Permissions.hasAccessibility,
              let windows = windows(of: appElement(pid)) else { return false }
        return exactWindow(id: windowID, in: windows) != nil
    }

    ///
    static func currentSize(of windowID: CGWindowID) -> CGSize? {
        guard Permissions.hasAccessibility,
              let number = windowInfo(of: windowID)?[kCGWindowOwnerPID as String] as? NSNumber
        else { return nil }
        let app = appElement(pid_t(number.int32Value))
        guard let windows = windows(of: app),
              let target = exactWindow(id: windowID, in: windows) else { return nil }

        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            target, kAXSizeAttribute as CFString, &raw
        ) == .success, let value = raw, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    static func currentTitle(of windowID: CGWindowID, pid: pid_t) -> String? {
        guard Permissions.hasAccessibility else { return nil }
        let app = appElement(pid)
        guard let windows = windows(of: app),
              let target = exactWindow(id: windowID, in: windows) else { return nil }

        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            target, kAXTitleAttribute as CFString, &raw
        ) == .success else { return nil }
        return raw as? String
    }

    private static func windows(of app: AXUIElement) -> [AXUIElement]? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app, kAXWindowsAttribute as CFString, &raw
        ) == .success else { return nil }
        return raw as? [AXUIElement]
    }

    private static func exactWindow(id: CGWindowID, in windows: [AXUIElement]) -> AXUIElement? {
        guard let getWindowID else { return nil }
        return windows.first { window in
            var candidate: CGWindowID = 0
            return getWindowID(window, &candidate) == .success && candidate == id
        }
    }

    private static func uniqueWindow(
        titled title: String, in windows: [AXUIElement]
    ) -> AXUIElement? {
        let wanted = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }

        let matches = windows.filter { window in
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                window, kAXTitleAttribute as CFString, &raw
            ) == .success,
                  let candidate = raw as? String else { return false }
            return candidate.trimmingCharacters(in: .whitespacesAndNewlines) == wanted
        }
        return matches.count == 1 ? matches[0] : nil
    }
}
