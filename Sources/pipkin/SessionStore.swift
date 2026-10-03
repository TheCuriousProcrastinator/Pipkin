import AppKit
import ScreenCaptureKit

final class SessionStore {
    static let shared = SessionStore()

    private(set) var sessions: [PiPSession] = []
    var onChange: (() -> Void)?

    static let softLimit = 6

    private var screenObserver: NSObjectProtocol?

    private init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Log.debug("")
            self?.sessions.forEach { $0.handleScreenParametersChanged() }
        }
    }


    var hasSessions: Bool { !sessions.isEmpty }

    func session(id: UUID) -> PiPSession? { sessions.first { $0.id == id } }

    func session(windowID: CGWindowID) -> PiPSession? {
        sessions.first { $0.sourceWindowID == windowID }
    }

    func refreshSourceTitles() {
        sessions.forEach { $0.refreshSourceTitleNow() }
    }


    func pipFrontmostWindow() {
        guard Permissions.ensureScreenRecording() else { return }
        ShareableContentStore.shared.frontmostWindow { [weak self] window in
            guard let window else {
                self?.notify(
                    title: ("No window found"),
                    message: ("Bring the window you want to mirror to the front, then press the hotkey.")
                )
                return
            }
            self?.pip(window: window)
        }
    }

    func pip(window: SCWindow) {
        pip(window: window, checkCompatibility: true, checkSoftLimit: true)
    }

    private func pip(window: SCWindow, checkCompatibility: Bool, checkSoftLimit: Bool) {
        guard Permissions.ensureScreenRecording() else { return }

        let store = ShareableContentStore.shared
        let source = store.captureSource(for: window)

        if let existing = session(windowID: window.windowID),
           existing.positionFallbackPreferenceKey == source.preferenceKey {
            existing.bringToFront()
            existing.flashHighlight()
            return
        }
        if checkSoftLimit, !confirmIfOverLimit() { return }
        if checkCompatibility, handleCompatibilityIfNeeded(for: window) { return }

        _ = createWindowSession(window)
    }

    @discardableResult
    private func createWindowSession(_ window: SCWindow) -> PiPSession? {
        let store = ShareableContentStore.shared
        let source = store.captureSource(for: window)
        let size = window.frame.size
        guard size.width > 1, size.height > 1 else { return nil }
        let positionIdentity = PositionMemoryIdentity.window(
            appPreferenceKey: source.preferenceKey, windowID: window.windowID
        )

        let request = SessionRequest(
            source: source,
            positionIdentity: positionIdentity,
            baseSourceRect: CGRect(origin: .zero, size: size),
            sourcePixelSize: store.pixelSize(of: window),
            sourcePointSize: size,
            fps: Preferences.shared.fps(for: source.preferenceKey),
            autoHide: Preferences.shared.autoHideDefault,
            idleDetection: Preferences.shared.idleDetectionDefault
        )
        let session = PiPSession(
            request: request,
            initialOrigin: initialOrigin(for: positionIdentity),
            cascadeIndex: sessions.count
        )
        add(session)
        Log.info(" PiP\(source.displayTitle) @ \(request.fps.label)")
        return session
    }

    private func handleCompatibilityIfNeeded(for window: SCWindow) -> Bool {
        guard let owner = window.owningApplication,
              let application = NSRunningApplication(processIdentifier: owner.processID),
              let profile = SourceAppCompatibility.profile(for: application),
              !SourceAppCompatibility.isKnownCompatibilityLaunch(
                  profile, pid: application.processIdentifier
              ) else { return false }

        switch SourceAppCompatibility.relaunchDecision(
            mode: Preferences.shared.chromiumCompatibilityMode,
            isVerified: profile.isVerified
        ) {
        case .skip:
            return false
        case .relaunch:
            startCompatibilityRelaunch(application: application, profile: profile)
            return true
        case .ask:
            break
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = ("\(profile.appName) may need Chromium compatibility mode")
        alert.informativeText = profile.isVerified
            ? ("Pipkin has verified that relaunching \(profile.appName) in Chromium compatibility mode keeps live updates capturable on other Spaces. Relaunching will quit the current \(profile.appName) process and close its existing PiP windows; PiP will not be recreated automatically. Save any unfinished work first.")
            : ("\(profile.appName) appears to use a Chromium / Electron runtime. Compatibility mode relaunches it with the known Chromium background-rendering switch so it can keep repainting on other Spaces. Existing PiP windows for the app are closed and are not recreated automatically. Save any unfinished work first.")
        alert.addButton(withTitle: ("Relaunch in Chromium Compatibility Mode"))
        alert.addButton(withTitle: ("Create PiP Anyway"))
        alert.addButton(withTitle: ("Cancel"))
        NSApp.activate(ignoringOtherApps: true)

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            startCompatibilityRelaunch(application: application, profile: profile)
            return true
        case .alertSecondButtonReturn:
            return false
        default:
            return true
        }
    }

    private func startCompatibilityRelaunch(
        application: NSRunningApplication,
        profile: SourceAppCompatibility.Profile
    ) {
        closeWindowSessions(bundleID: profile.bundleID)
        Log.debug(" Chromium  PiP\(profile.appName)")

        SourceAppCompatibility.restart(application: application, profile: profile) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(relaunched):
                self.notify(
                    title: ("Chromium compatibility mode is active"),
                    message: ("\(profile.appName) relaunched (PID \(relaunched.processIdentifier)). Create a new PiP when you need it.")
                )
            case let .failure(error):
                self.notify(
                    title: ("Chromium compatibility relaunch failed"),
                    message: error.localizedDescription
                )
            }
        }
    }

    private func closeWindowSessions(bundleID: String) {
        let matching = sessions.filter { session in
            guard case let .window(_, sessionBundleID, _, _) = session.state.source else { return false }
            return sessionBundleID == bundleID
        }
        matching.forEach { $0.close() }
    }

    func beginRegionCapture() {
        guard Permissions.ensureScreenRecording() else { return }
        guard !RegionSelectionController.shared.isActive else { return }
        RegionSelectionController.shared.begin { [weak self] result in
            guard let self, let result else { return }
            self.createRegionSession(result)
        }
    }

    private func createRegionSession(_ result: RegionSelectionController.Result) {
        guard confirmIfOverLimit() else { return }
        let store = ShareableContentStore.shared
        let scale = result.screen.backingScaleFactor

        if let windowID = result.hitWindowID,
           let frameTopLeft = result.hitWindowFrameTopLeft,
           let window = store.cachedWindow(id: windowID) {
            let local = Geo.windowLocalRect(
                fromScreenRect: result.screenRect,
                windowFrameTopLeft: frameTopLeft,
                primaryScreenMaxY: Geo.primaryScreenMaxY
            ).intersection(CGRect(origin: .zero, size: frameTopLeft.size))
            if local.width >= 40, local.height >= 40 {
                let source = store.captureSource(for: window)
                let positionIdentity = PositionMemoryIdentity.windowRegion(
                    appPreferenceKey: source.preferenceKey, windowID: window.windowID, rect: local
                )
                let request = SessionRequest(
                    source: source,
                    positionIdentity: positionIdentity,
                    baseSourceRect: local,
                    sourcePixelSize: CGSize(width: local.width * scale, height: local.height * scale),
                    sourcePointSize: local.size,
                    fps: Preferences.shared.fps(for: source.preferenceKey),
                    autoHide: Preferences.shared.autoHideDefault,
                    idleDetection: Preferences.shared.idleDetectionDefault
                )
                add(PiPSession(
                    request: request,
                    initialOrigin: initialOrigin(for: positionIdentity),
                    cascadeIndex: sessions.count
                ))
                Log.info(" PiP\(source.displayTitle) \(Int(local.width))×\(Int(local.height))")
                return
            }
        }

        let local = Geo.sckRect(fromScreenRect: result.screenRect, on: result.screen)
        let source = CaptureSource.region(displayID: result.displayID, rect: result.screenRect)
        let positionIdentity = PositionMemoryIdentity.displayRegion(
            displayID: result.displayID, rect: result.screenRect
        )
        let request = SessionRequest(
            source: source,
            positionIdentity: positionIdentity,
            baseSourceRect: local,
            sourcePixelSize: CGSize(width: local.width * scale, height: local.height * scale),
            sourcePointSize: local.size,
            fps: Preferences.shared.fps(for: source.preferenceKey),
            autoHide: Preferences.shared.autoHideDefault,
            idleDetection: Preferences.shared.idleDetectionDefault
        )
        add(PiPSession(
            request: request,
            initialOrigin: initialOrigin(for: positionIdentity),
            cascadeIndex: sessions.count
        ))
        Log.info(" PiP\(Int(local.width))×\(Int(local.height)) @ display \(result.displayID)")
    }


    func closeAll() {
        for session in sessions.reversed() { session.close() }
    }

    func setAllPaused(_ paused: Bool) {
        sessions.forEach { $0.setPaused(paused) }
        onChange?()
    }

    var allPaused: Bool { !sessions.isEmpty && sessions.allSatisfy { $0.isPaused } }

    func applyLevelMode(_ mode: WindowLevelMode) {
        sessions.forEach { $0.setLevelMode(mode) }
    }

    func applyAutoHideOpacity(_ opacity: CGFloat) {
        Preferences.shared.autoHideOpacity = opacity
        sessions.forEach { $0.refreshAutoHideOpacity() }
    }

    func handleHoverKey(_ key: EventTapManager.HoverKey, sessionID: UUID) {
        session(id: sessionID)?.applyHoverKey(key)
        onChange?()
    }


    private func initialOrigin(for identity: PositionMemoryIdentity) -> CGPoint? {
        let prefs = Preferences.shared
        let exact = prefs.origin(for: identity)
        let hasActiveSibling = sessions.contains {
            $0.positionFallbackPreferenceKey == identity.fallbackPreferenceKey
        }
        return Self.selectInitialOrigin(
            exactOrigin: exact,
            fallbackOrigin: prefs.fallbackOrigin(for: identity),
            hasActiveSibling: hasActiveSibling
        )
    }

    static func selectInitialOrigin(exactOrigin: CGPoint?, fallbackOrigin: CGPoint?,
                                    hasActiveSibling: Bool) -> CGPoint? {
        if let exactOrigin { return exactOrigin }
        return hasActiveSibling ? nil : fallbackOrigin
    }

    private func add(_ session: PiPSession) {
        session.onResolveDragFrame = { [weak self, weak session] proposed, flags in
            guard let self, let session else { return proposed }
            return self.resolveDragFrame(for: session, proposed: proposed, modifierFlags: flags)
        }
        session.onClose = { [weak self] closed in
            guard let self else { return }
            self.sessions.removeAll { $0 === closed }
            self.onChange?()
        }
        sessions.append(session)
        onChange?()
    }

    private func resolveDragFrame(for moving: PiPSession, proposed: CGRect,
                                  modifierFlags: NSEvent.ModifierFlags) -> CGRect {
        guard !modifierFlags.contains(.control),
              let screen = targetScreen(for: proposed) else { return proposed }
        let visibleFrame = screen.visibleFrame
        let siblings = sessions.compactMap { session -> CGRect? in
            guard session !== moving, session.isVisibleForSnapping else { return nil }
            let frame = session.windowFrame
            guard let siblingScreen = targetScreen(for: frame),
                  isSameDisplay(siblingScreen, screen) else { return nil }
            return frame
        }
        return Geo.snappedWindowFrame(proposed, in: visibleFrame, siblings: siblings)
    }

    private func targetScreen(for frame: CGRect) -> NSScreen? {
        let screens = NSScreen.screens
        guard let index = Geo.indexOfScreen(
            containing: frame,
            screenFrames: screens.map(\.frame)
        ) else { return nil }
        return screens[index]
    }

    private func isSameDisplay(_ lhs: NSScreen, _ rhs: NSScreen) -> Bool {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let left = (lhs.deviceDescription[key] as? NSNumber)?.uint32Value,
           let right = (rhs.deviceDescription[key] as? NSNumber)?.uint32Value {
            return left == right
        }
        return lhs.frame == rhs.frame
    }

    private func confirmIfOverLimit() -> Bool {
        guard sessions.count >= Self.softLimit else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = ("\(sessions.count) PiP windows are already open")
        alert.informativeText = ("Adding more will noticeably increase CPU and memory usage. Consider closing some or lowering the frame rate.")
        alert.addButton(withTitle: ("Create anyway"))
        alert.addButton(withTitle: ("Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func notify(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: ("OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
