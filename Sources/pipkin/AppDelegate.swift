import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        Geo.runSelfChecks()
        #endif
        Log.info(" Pipkin \(Updater.currentVersion)\("en")")

        statusBar = StatusBarController()
        statusBar?.onShowOnboarding = { [weak self] in
            self?.showOnboarding(markAsSeen: false)
        }
        wireHotkeys()
        wireSettings()
        observeSleepWake()

        if Preferences.shared.enhancedMode, !EventTapManager.shared.syncWithPreferences() {
            Preferences.shared.enhancedMode = false
            Log.warn("")
        }

        let hadScreenRecordingPermission = Permissions.hasScreenRecording
        if !hadScreenRecordingPermission {
            Permissions.ensureScreenRecording()
        }

        if hadScreenRecordingPermission, !Preferences.shared.hasSeenOnboarding {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.showOnboarding(markAsSeen: true)
            }
        }

        Updater.checkSilently { [weak self] info in
            self?.statusBar?.setPendingUpdate(info)
        }

        if CommandLine.arguments.contains("--smoke") { runSmokeTest() }
        if CommandLine.arguments.contains("--smoke-autohide") { runAutoHideRegression() }
        if CommandLine.arguments.contains("--smoke-bar") { runTopBarRegression() }
        if CommandLine.arguments.contains("--smoke-onboarding") { runOnboardingRegression() }
        if CommandLine.arguments.contains("--smoke-update") { runUpdateRegression() }
        if CommandLine.arguments.contains("--smoke-activate") { runActivateRegression() }
        if CommandLine.arguments.contains("--smoke-mc") { runMissionControlRegression() }
        if CommandLine.arguments.contains("--smoke-renderer") { runRendererRegression() }
        if CommandLine.arguments.contains("--smoke-level") { runWindowLevelRegression() }
    }

    private func runWindowLevelRegression() {
        Log.info("[level] ")
        let popUpMenu = NSWindow.Level.popUpMenu.rawValue
        let statusBar = NSWindow.Level.statusBar.rawValue
        let expectedGlobal = WindowLevelMode.globalLevel.rawValue
        var failed = false

        func expect(_ what: String, _ actual: Int, _ expected: Int) {
            let ok = actual == expected
            if !ok { failed = true }
            Log.info("[level] \(what)=\(actual) \(expected)\(ok ? "" : "")")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            SessionStore.shared.pipFrontmostWindow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard let session = SessionStore.shared.sessions.first else {
                Log.error("[level] ")
                NSApp.terminate(nil)
                return
            }
            let inRange = expectedGlobal > statusBar && expectedGlobal < popUpMenu
            if !inRange { failed = true }
            Log.info("""
                [level]  \(expectedGlobal)  statusBar(\(statusBar))  \
                popUpMenu(\(popUpMenu))  \(inRange ? "" : "")
                """)

            session.setLevelMode(.global)
            expect(" ", session.debugWindowLevel, expectedGlobal)
            expect(" ", session.debugHintWindowLevel, expectedGlobal)

            session.setLevelMode(.normal)
            expect(" ", session.debugWindowLevel, NSWindow.Level.floating.rawValue)
            expect(" ", session.debugHintWindowLevel, NSWindow.Level.floating.rawValue)

            session.setLevelMode(.global)
            expect(" ", session.debugWindowLevel, expectedGlobal)

            SessionStore.shared.closeAll()
            Log.info("[level] \(failed ? "" : "")")
            NSApp.terminate(nil)
        }
    }

    ///
    private func runRendererRegression() {
        Log.info("[renderer] ")

        var monitor = RendererStallMonitor(timeout: 2)
        var stateMachineOK = monitor.observeNotReady(at: 0) == .none
        stateMachineOK = stateMachineOK && monitor.observeNotReady(at: 1.99) == .none
        stateMachineOK = stateMachineOK && monitor.observeNotReady(at: 2) == .flush
        stateMachineOK = stateMachineOK && monitor.observeNotReady(at: 4) == .rebuildLayer
        stateMachineOK = stateMachineOK && monitor.observeNotReady(at: 6) == .restartCapture
        stateMachineOK = stateMachineOK && monitor.observeNotReady(at: 20) == .none
        let recovered = monitor.observeReady(at: 21)
        stateMachineOK = stateMachineOK && recovered != nil && !monitor.isTrackingStall
        var lowerBound = RendererStallMonitor(timeout: 0)
        stateMachineOK = stateMachineOK && lowerBound.timeout == 0.25
        stateMachineOK = stateMachineOK && lowerBound.requestImmediateFlush(at: 1) == .flush
        Log.info("""
            [renderer]  \(stateMachineOK ? "" : "") \
             none→flush→rebuildLayer→restartCaptureready
            """)

        var session: PiPSession?
        var beforeFlush: UInt64 = 0

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            SessionStore.shared.pipFrontmostWindow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            session = SessionStore.shared.sessions.first
            guard let session else {
                Log.error("[renderer] ")
                NSApp.terminate(nil)
                return
            }
            beforeFlush = session.debugEnqueuedFrameCount
            Log.info("[renderer] flush  \(beforeFlush) ")
            session.debugForceDiscontinuity("smoke")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
            guard let session else { return }
            let after = session.debugEnqueuedFrameCount
            let ok = after > beforeFlush
            Log.info("""
                [renderer] flush  \(after)  \(after - beforeFlush)\
                 \(session.debugNotReadyDropCount)\(ok ? "" : "flush ")
                """)
            SessionStore.shared.closeAll()
            Log.info("[renderer]  \(SessionStore.shared.sessions.count)")
            NSApp.terminate(nil)
        }
    }

    private func runMissionControlRegression() {
        Log.info("[mc] ")
        var session: PiPSession?
        var initial = CGRect.zero

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            SessionStore.shared.pipFrontmostWindow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            session = SessionStore.shared.sessions.first
            guard let session else {
                Log.error("[mc] ")
                NSApp.terminate(nil)
                return
            }
            initial = session.debugBaseRect
            Log.info("""
                [mc]  baseRect=\(Int(initial.width))×\(Int(initial.height)) \
                sourceRect=\(Self.describe(session.debugSourceRect))zoom=1  .zero
                """)
            Log.info("[mc] ")
            Self.toggleMissionControl()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            guard let session else { return }
            Log.info("[mc] ")
            session.debugProbeNow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            guard let session else { return }
            let now = session.debugBaseRect
            let ok = abs(now.width - initial.width) < 1 && abs(now.height - initial.height) < 1
            Log.info("""
                [mc]  baseRect=\(Int(now.width))×\(Int(now.height)) \
                \(ok ? "" : "")
                """)
            Log.info("[mc] ")
            Self.toggleMissionControl()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            guard let session else { return }
            let now = session.debugBaseRect
            let ok = abs(now.width - initial.width) < 1 && abs(now.height - initial.height) < 1
            Log.info("""
                [mc]  baseRect=\(Int(now.width))×\(Int(now.height)) \
                sourceRect=\(Self.describe(session.debugSourceRect)) \(ok ? "" : "")
                """)
            SessionStore.shared.closeAll()
            NSApp.terminate(nil)
        }
    }

    private static func describe(_ rect: CGRect) -> String {
        rect == .zero ? ".zero" : "\(Int(rect.width))×\(Int(rect.height))@(\(Int(rect.minX)),\(Int(rect.minY)))"
    }

    private static func toggleMissionControl() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Mission Control"]
        do { try process.run() } catch { Log.error("[mc] \(error)") }
    }

    private func runActivateRegression() {
        Log.info("[activate] ")
        Log.info("""
            [activate] AX  ID =\(SourceWindowActivator.isExactMatchAvailable ? "" : "") \
            =\(Permissions.hasAccessibility ? "" : "")
            """)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            SessionStore.shared.pipFrontmostWindow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard let session = SessionStore.shared.sessions.first,
                  let windowID = session.sourceWindowID else {
                Log.error("[activate] ")
                NSApp.terminate(nil)
                return
            }
            guard let pid = SourceWindowActivator.ownerPID(of: windowID) else {
                Log.error("[activate]  PID [windowID=\(windowID)]")
                NSApp.terminate(nil)
                return
            }
            let resolved = SourceWindowActivator.canResolveExactWindow(id: windowID, pid: pid)
            Log.info("""
                [activate] windowID=\(windowID) pid=\(pid) \
                AX =\(resolved ? "" : "")
                """)

            let before = session.title
            session.refreshSourceTitleNow()
            let cgName = SourceWindowActivator.windowInfo(of: windowID)?[
                kCGWindowName as String
            ] as? String
            Log.info("""
                [activate] =\(before) =\(session.title) \
                CGWindowName=\(cgName ?? "nil")
                """)

            SessionStore.shared.closeAll()
            Log.info("[activate]  \(SessionStore.shared.sessions.count)")
            NSApp.terminate(nil)
        }
    }

    private func runUpdateRegression() {
        Log.info("[update] \(Updater.downloadSessionDescription)")
        let started = Date()

        Updater.fetchLatest { result in
            switch result {
            case let .failure(error):
                Log.error("[update]  Release \(Updater.describe(error))")
                exit(2)
            case let .success(info):
                Log.info("[update]  \(info.version) \(Updater.currentVersion)"
                    + " dmg=\(info.dmgURL?.lastPathComponent ?? "nil")"
                    + " sha256=\(info.sha256URL?.lastPathComponent ?? "nil")")
                guard info.dmgURL != nil else {
                    Log.error("[update] Release  DMG ")
                    exit(3)
                }
                Self.runUpdateDownloadProbe(info, started: started)
            }
        }
    }

    private static func runUpdateDownloadProbe(_ info: ReleaseInfo, started: Date) {
        var lastBucket = -1
        Updater.startDownloadForProbe(
            info,
            onProgress: { written, total in
                guard total > 0 else { return }
                let bucket = Int(Double(written) / Double(total) * 10)
                guard bucket != lastBucket else { return }
                lastBucket = bucket
                let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
                Log.info("[update]  \(bucket * 10)%\(written)/\(total) \(elapsed)s")
            },
            onFinished: { result in
                let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
                switch result {
                case let .failure(error):
                    Log.error("[update] \(elapsed)s\(Updater.describe(error))")
                    exit(4)
                case let .success(file):
                    Log.info("[update] \(elapsed)s\(file.path)")
                    guard let shaURL = info.sha256URL else {
                        Log.warn("[update]  .sha256 ")
                        try? FileManager.default.removeItem(at: file)
                        Log.info("[update] ")
                        exit(0)
                    }
                    URLSession.shared.dataTask(with: shaURL) { data, _, _ in
                        let expected = data.flatMap { String(data: $0, encoding: .utf8) }?
                            .split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init)?
                            .lowercased() ?? ""
                        let actual = ((try? Updater.sha256(ofFileAt: file)) ?? "").lowercased()
                        Log.info("[update] SHA256 =\(expected.prefix(16))… =\(actual.prefix(16))…")
                        try? FileManager.default.removeItem(at: file)
                        if !expected.isEmpty, expected == actual {
                            Log.info("[update]  + ")
                            exit(0)
                        } else {
                            Log.error("[update] SHA256 ")
                            exit(5)
                        }
                    }.resume()
                }
            }
        )
    }

    private func runOnboardingRegression() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            let anchor = self?.statusBar?.statusItemScreenFrame
            Log.info("[onboarding] \(anchor.map { "\($0)" } ?? "")")
            self?.showOnboarding(markAsSeen: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            let visibleWindows = NSApp.windows.filter { $0.isVisible }.count
            Log.info("[onboarding] isVisible=\(OnboardingOverlay.isVisible) =\(visibleWindows) ≥ ")
            OnboardingOverlay.dismiss()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
            Log.info("[onboarding]  isVisible=\(OnboardingOverlay.isVisible) false"
                + "=\(NSApp.windows.filter { $0.isVisible }.count)")
            NSApp.terminate(nil)
        }
    }

    private func runTopBarRegression() {
        Log.info("[bar] ")
        var session: PiPSession?

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            SessionStore.shared.pipFrontmostWindow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            session = SessionStore.shared.sessions.first
            guard let session else {
                Log.error("[bar] ")
                NSApp.terminate(nil)
                return
            }
            session.toggleAutoHide()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                Self.warpMouse(to: CGPoint(x: session.debugWindowFrame.midX,
                                           y: session.debugWindowFrame.minY + 20))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
            guard let session else { return }
            Log.info("""
                [bar] alpha=\(String(format: "%.2f", session.debugAlpha)) \
                =\(session.debugClickThrough) +
                """)
            guard let bar = session.debugBarScreenFrame else {
                Log.error("[bar] ")
                return
            }
            Log.info("[bar] ")
            Self.warpMouse(to: CGPoint(x: bar.midX, y: bar.midY))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 11) {
            guard let session else { return }
            Log.info("""
                [bar] alpha=\(String(format: "%.2f", session.debugAlpha)) \
                =\(session.debugClickThrough) alpha=1.00 +
                """)
            let frame = session.debugWindowFrame
            Log.info("[bar] ")
            Self.warpMouse(to: CGPoint(x: max(4, frame.minX - 80), y: frame.midY))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 13) {
            guard let session else { return }
            Log.info("""
                [bar] alpha=\(String(format: "%.2f", session.debugAlpha)) \
                =\(session.debugClickThrough) alpha=1.00 +
                """)
            SessionStore.shared.closeAll()
            NSApp.terminate(nil)
        }
    }

    private func runAutoHideRegression() {
        Log.info("[autohide]  \(Preferences.shared.autoHideOpacity)")
        var session: PiPSession?

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            SessionStore.shared.pipFrontmostWindow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            session = SessionStore.shared.sessions.first
            guard let session else {
                Log.error("[autohide] ")
                NSApp.terminate(nil)
                return
            }
            session.toggleAutoHide()
            Log.info("[autohide] ")
            Self.warpMouse(to: CGPoint(x: session.debugWindowFrame.midX,
                                       y: session.debugWindowFrame.midY))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            guard let session else { return }
            Log.info("""
                [autohide] alpha=\(String(format: "%.2f", session.debugAlpha)) \
                =\(session.debugClickThrough) =\(session.debugAutoHideActive) \
                peek=\(session.debugPeeking)
                """)
            Log.info("[autohide] ")
            let frame = session.debugWindowFrame
            Self.warpMouse(to: CGPoint(x: max(4, frame.minX - 80), y: frame.midY))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            guard let session else { return }
            Log.info("""
                [autohide] alpha=\(String(format: "%.2f", session.debugAlpha)) \
                =\(session.debugClickThrough) =\(session.debugAutoHideActive)
                """)
            SessionStore.shared.closeAll()
            NSApp.terminate(nil)
        }
    }

    private static func warpMouse(to point: CGPoint) {
        let cg = CGPoint(x: point.x, y: Geo.primaryScreenMaxY - point.y)
        CGWarpMouseCursorPosition(cg)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private func runSmokeTest() {
        let args = CommandLine.arguments
        var duration: TimeInterval = 6
        if let i = args.firstIndex(of: "--smoke"), i + 1 < args.count,
           let seconds = Double(args[i + 1]), seconds > 1 {
            duration = seconds
        }
        Log.info("[smoke]  \(Int(duration))s")
        var sessionCount = 1
        if let i = args.firstIndex(of: "--smoke-sessions"), i + 1 < args.count,
           let n = Int(args[i + 1]), n > 0 {
            sessionCount = min(n, SessionStore.softLimit)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if sessionCount == 1 {
                SessionStore.shared.pipFrontmostWindow()
                return
            }
            ShareableContentStore.shared.refresh { result in
                guard case let .success(windows) = result else { return }
                let targets = windows
                    .filter { $0.windowLayer == 0 }
                    .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
                    .prefix(sessionCount)
                for window in targets { SessionStore.shared.pip(window: window) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            let sessions = SessionStore.shared.sessions
            Log.info("[smoke]  \(sessions.count)")
            for session in sessions {
                Log.info("[smoke] \(session.title) =\(session.runtimeState) =\(session.debugWindowFrame)")
            }
            SessionStore.shared.closeAll()
            Log.info("[smoke]  \(SessionStore.shared.sessions.count)")
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Updater.cancelDownload()
        SessionStore.shared.closeAll()
        EventTapManager.shared.disable()
        HotkeyManager.shared.unregisterAll()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }


    private func wireHotkeys() {
        HotkeyManager.shared.onTrigger = { action in
            switch action {
            case .pip: SessionStore.shared.pipFrontmostWindow()
            case .region: SessionStore.shared.beginRegionCapture()
            case .closeAll: SessionStore.shared.closeAll()
            }
        }
        HotkeyManager.shared.start()

        EventTapManager.shared.onGlobalTrigger = { action in
            switch action {
            case .pip: SessionStore.shared.pipFrontmostWindow()
            case .region: SessionStore.shared.beginRegionCapture()
            case .closeAll: SessionStore.shared.closeAll()
            }
        }
        EventTapManager.shared.onHoverKey = { key, sessionID in
            SessionStore.shared.handleHoverKey(key, sessionID: sessionID)
        }
    }

    private func wireSettings() {
        SettingsWindowController.shared.onLevelModeChanged = { mode in
            SessionStore.shared.applyLevelMode(mode)
        }
        SettingsWindowController.shared.onAutoHideOpacityChanged = { opacity in
            SessionStore.shared.applyAutoHideOpacity(opacity)
        }
    }

    private func showOnboarding(markAsSeen: Bool, retry: Bool = true) {
        let anchor = statusBar?.statusItemScreenFrame
        if anchor == nil, retry {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.showOnboarding(markAsSeen: markAsSeen, retry: false)
            }
            return
        }
        OnboardingOverlay.show(
            anchor: anchor,
            onOpenMenu: { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self?.statusBar?.openMenu()
                }
            },
            onDismiss: {
                if markAsSeen { Preferences.shared.hasSeenOnboarding = true }
            }
        )
    }

    private func observeSleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { _ in
            Log.debug("")
            SessionStore.shared.setAllPaused(true)
        }
        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Log.debug("")
            SessionStore.shared.setAllPaused(false)
        }
    }
}
