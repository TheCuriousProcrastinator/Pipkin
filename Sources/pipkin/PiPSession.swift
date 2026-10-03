import AppKit
import CoreMedia
import ScreenCaptureKit

final class PiPSession: NSObject, CaptureEngineDelegate, PiPWindowDelegate {

    let id = UUID()
    private(set) var state: PiPSessionState
    private(set) var runtimeState: SessionRuntimeState = .streaming

    private var baseRect: CGRect
    private var selectedBaseRect: CGRect? = nil
    private var sourcePixelSize: CGSize
    private var positionIdentity: PositionMemoryIdentity

    private let engine = CaptureEngine()
    private let windowController: PiPWindowController
    private let idleDetector: IdleDetector

    var onClose: ((PiPSession) -> Void)?
    var onResolveDragFrame: ((CGRect, NSEvent.ModifierFlags) -> CGRect)?

    private var isAutoHidden = false
    private enum PeekReason: Equatable { case option, commandZoom, resize, bar }
    private var peekReason: PeekReason?
    private var isPeeking: Bool { peekReason != nil }
    private var isLiveResizing = false
    private var idleThrottled = false
    private var reconnectAttempt = 0
    private var reconnectWork: DispatchWorkItem?
    private var probeTimer: Timer?
    private var sourcePID: pid_t?
    private var isSourceProbeInFlight = false
    private var offscreenRetargetAttempted = false
    private var geometryRecheckWork: DispatchWorkItem?
    private var hiddenAutoCloseTimer: Timer?
    private var occlusionObserver: NSObjectProtocol?
    private var didExplainApplicationOnlyActivation = false
    private var lastTitleRefresh: Date?
    private var wasHovering = false
    private var isClosed = false
    private var rendererRestartTimes: [TimeInterval] = []

    private static let hiddenAutoCloseSeconds: TimeInterval = 60
    private static let maxReconnectAttempts = 3
    private static let sourceProbeQueue = DispatchQueue(
        label: "com.thecuriousprocrastinator.Pipkin.source-health",
        qos: .utility,
        attributes: .concurrent
    )
    private static let geometryRecheckDelay: TimeInterval = 1.2
    private static let titleRefreshThrottle: TimeInterval = 0.5
    private static let rendererRestartWindow: TimeInterval = 90
    private static let rendererRestartLimit = 2


    init(request: SessionRequest, initialOrigin: CGPoint?, cascadeIndex: Int) {
        state = PiPSessionState(
            source: request.source,
            fps: request.fps,
            autoHide: request.autoHide,
            idleDetection: request.idleDetection
        )
        baseRect = request.baseSourceRect
        sourcePixelSize = request.sourcePixelSize
        positionIdentity = request.positionIdentity
        sourcePID = request.source.windowID.flatMap { SourceWindowActivator.ownerPID(of: $0) }
        idleDetector = IdleDetector()

        let prefs = Preferences.shared
        let width = Geo.initialPiPWidth(
            sourceSize: request.sourcePointSize,
            rememberedWidth: prefs.preferredWidth(for: request.source.preferenceKey),
            screenSizes: NSScreen.screens.map { $0.frame.size },
            isWindowSource: request.source.windowID != nil
        )
        windowController = PiPWindowController(
            title: request.source.displayTitle,
            aspect: request.sourcePointSize,
            initialWidth: width,
            origin: initialOrigin,
            levelMode: prefs.windowLevelMode,
            cascadeIndex: cascadeIndex
        )

        super.init()

        windowController.delegate = self
        engine.delegate = self
        windowController.recordRendererEvent(
            "session.created id=\(id.uuidString.prefix(8)) source=\(request.source.displayTitle)"
        )
        windowController.show()
        windowController.update(state: state)
        registerHoverMonitor()
        observeOcclusion()
        startCapture()
    }

    deinit {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }

    func close() {
        guard !isClosed else { return }
        windowController.recordRendererEvent("session.close")
        isClosed = true
        reconnectWork?.cancel()
        geometryRecheckWork?.cancel()
        probeTimer?.invalidate()
        hiddenAutoCloseTimer?.invalidate()
        HoverMonitor.shared.unregister(id: id)
        engine.stop()
        persistGeometry()
        windowController.close()
        Log.info("\(state.source.displayTitle)")
        onClose?(self)
    }


    var sourceWindowID: CGWindowID? { state.source.windowID }
    var positionFallbackPreferenceKey: String { positionIdentity.fallbackPreferenceKey }
    var title: String { state.source.displayTitle }
    var isHidden: Bool { state.isHidden }
    var isPaused: Bool { state.isPaused }
    var windowFrame: CGRect { windowController.window.frame }
    var isVisibleForSnapping: Bool {
        let window = windowController.window
        return Self.canParticipateInSnapping(
            isHidden: state.isHidden,
            isWindowVisible: window.isVisible,
            isOcclusionVisible: window.occlusionState.contains(.visible)
        )
    }

    static func canParticipateInSnapping(isHidden: Bool, isWindowVisible: Bool,
                                          isOcclusionVisible: Bool) -> Bool {
        !isHidden && isWindowVisible && isOcclusionVisible
    }

    func bringToFront() { windowController.bringToFront() }
    func flashHighlight() { windowController.flashHighlight() }

    ///
    func refreshSourceTitle(_ title: String) {
        guard !isClosed,
              case let .window(windowID, bundleID, appName, oldTitle) = state.source else { return }
        let refreshed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !refreshed.isEmpty, refreshed != oldTitle else { return }
        state.source = .window(
            id: windowID, bundleID: bundleID, appName: appName, title: refreshed
        )
        windowController.setTitle(state.source.displayTitle)
        Log.debug("\(state.source.displayTitle)")
    }

    func refreshSourceTitleNow() {
        guard !isClosed, let windowID = state.source.windowID else { return }
        if let last = lastTitleRefresh,
           Date().timeIntervalSince(last) < Self.titleRefreshThrottle { return }
        lastTitleRefresh = Date()
        guard let title = SourceWindowActivator.currentTitle(of: windowID) else { return }
        refreshSourceTitle(title)
    }

    var debugWindowFrame: CGRect { windowController.window.frame }
    var debugAlpha: CGFloat { windowController.window.alphaValue }
    var debugClickThrough: Bool { windowController.window.ignoresMouseEvents }
    var debugAutoHideActive: Bool { isAutoHidden }
    var debugPeeking: Bool { isPeeking }
    var debugBarScreenFrame: CGRect? { windowController.barScreenFrame }
    var debugBaseRect: CGRect { baseRect }
    var debugSourceRect: CGRect { currentSourceRect() }
    func debugProbeNow() { probeSource() }
    var debugEnqueuedFrameCount: UInt64 { windowController.debugEnqueuedFrameCount }
    var debugNotReadyDropCount: UInt64 { windowController.debugNotReadyDropCount }
    func debugForceDiscontinuity(_ reason: String) {
        windowController.prepareForCaptureDiscontinuity(reason)
    }
    var debugWindowLevel: Int { windowController.debugWindowLevel }
    var debugHintWindowLevel: Int { windowController.debugHintWindowLevel }

    func setLevelMode(_ mode: WindowLevelMode) { windowController.setLevelMode(mode) }

    func setPaused(_ paused: Bool) {
        guard state.isPaused != paused else { return }
        state.isPaused = paused
        if paused {
            pauseCapture(reason: "")
            update(runtimeState: .paused)
        } else {
            resumeCapture(reason: "")
            update(runtimeState: .streaming)
        }
        windowController.update(state: state)
    }

    func setFPS(_ fps: FPSStep) {
        state.fps = fps
        Preferences.shared.setFPS(fps, for: state.source.preferenceKey)
        idleThrottled = false
        idleDetector.reset()
        retune(reason: " \(fps.rawValue)fps")
        windowController.update(state: state)
    }

    func refreshAutoHideOpacity() {
        guard !isClosed, isAutoHidden, !isPeeking else { return }
        windowController.setAlpha(Preferences.shared.autoHideOpacity, animated: true)
    }

    func applyZoom(_ zoom: CGFloat, anchor: CGPoint) {
        let z = Geo.clampZoom(zoom)
        state.zoom = z
        state.anchor = Geo.clampAnchor(anchor, zoom: z)
        retune(reason: " \(String(format: "%.3f", z))x")
        windowController.update(state: state)
    }

    func applySelection(_ normalizedRect: CGRect) {
        let visible = currentVisibleSourceRect()
        guard visible.width > 1, visible.height > 1 else { return }
        guard normalizedRect.width > 0.02, normalizedRect.height > 0.02,
              let selected = Geo.sourceRect(
                  fromNormalizedVisibleRect: normalizedRect,
                  within: visible
              ) else { return }

        selectedBaseRect = selected
        state.hasSelectionCrop = true
        state.zoom = 1
        state.anchor = CGPoint(x: 0.5, y: 0.5)
        windowController.setAspect(selected.size)
        retune(reason: " \(Int(selected.width))×\(Int(selected.height))")
        windowController.update(state: state)
    }

    func resetZoom() {
        selectedBaseRect = nil
        state.hasSelectionCrop = false
        state.zoom = 1
        state.anchor = CGPoint(x: 0.5, y: 0.5)
        windowController.setAspect(baseRect.size)
        retune(reason: "")
        windowController.update(state: state)
    }

    func toggleIdleDetection() {
        state.idleDetection.toggle()
        idleDetector.reset()
        if !state.idleDetection, idleThrottled {
            idleThrottled = false
            retune(reason: "")
        }
        windowController.update(state: state)
    }

    func toggleAutoHide() {
        state.autoHide.toggle()
        windowController.update(state: state)

        guard state.autoHide else {
            endAutoHide()
            return
        }

        windowController.showHint(
            ("Fades out on hover — hold ⌥ to peek, or turn it off from the menu bar"),
            near: nil, duration: 3.0
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            let modifiers = NSEvent.modifierFlags
            guard let self, !self.isClosed, self.state.autoHide, !self.state.isHidden,
                  HoverMonitor.shared.currentHovered() == self.id,
                  !modifiers.contains(.option), !modifiers.contains(.command) else { return }
            self.beginAutoHide()
        }
    }

    func setAutoHideOpacity(_ opacity: CGFloat) {
        let value = Preferences.clampOpacity(opacity)
        Preferences.shared.autoHideOpacity = value
        if isAutoHidden, !isPeeking {
            windowController.setAlpha(value, animated: true)
        }
        windowController.showHint(
            ("Auto-hide opacity \(Preferences.opacityLabel(value))"),
            near: nil, duration: 1.5
        )
        windowController.update(state: state)
    }

    func toggleHidden() {
        if state.isHidden { restoreFromHidden() } else { hideCompletely() }
    }

    func applyHoverKey(_ key: EventTapManager.HoverKey) {
        switch key {
        case .zoomIn: applyZoom(state.zoom * 1.25, anchor: state.anchor)
        case .zoomOut: applyZoom(state.zoom / 1.25, anchor: state.anchor)
        case .cycleFPS: setFPS(state.fps.next())
        case .toggleIdleDetection: toggleIdleDetection()
        case .toggleHidden: toggleHidden()
        case .close: close()
        }
    }


    private func hideCompletely() {
        state.isHidden = true
        pauseCapture(reason: "")
        windowController.hideCompletely()
        hiddenAutoCloseTimer?.invalidate()
        hiddenAutoCloseTimer = Timer.scheduledTimer(
            withTimeInterval: Self.hiddenAutoCloseSeconds, repeats: false
        ) { [weak self] _ in
            Log.debug("")
            self?.close()
        }
        windowController.update(state: state)
    }

    private func restoreFromHidden() {
        state.isHidden = false
        hiddenAutoCloseTimer?.invalidate()
        hiddenAutoCloseTimer = nil
        windowController.restoreFromHidden()
        if !state.isPaused { resumeCapture(reason: "") }
        windowController.update(state: state)
    }


    private var activeBaseRect: CGRect { selectedBaseRect ?? baseRect }

    private func currentVisibleSourceRect() -> CGRect {
        Geo.sourceRect(zoom: state.zoom, anchor: state.anchor, full: activeBaseRect)
    }

    private func currentSourceRect() -> CGRect {
        if selectedBaseRect == nil,
           case .window = state.source,
           state.zoom <= PiPSessionState.minZoom + 0.001,
           abs(baseRect.minX) < 0.5, abs(baseRect.minY) < 0.5 {
            return .zero
        }
        return currentVisibleSourceRect()
    }

    private func makeConfiguration(fps: Int? = nil) -> SCStreamConfiguration {
        CaptureEngine.makeConfiguration(
            sourceRect: currentSourceRect(),
            pointSize: windowController.contentPointSize,
            scale: windowController.backingScale,
            fps: fps ?? effectiveFPS,
            showsCursor: Preferences.shared.showsCursor
        )
    }

    private var effectiveFPS: Int {
        idleThrottled ? 1 : state.fps.rawValue
    }

    private func configurationSummary(_ configuration: SCStreamConfiguration) -> String {
        let rect = configuration.sourceRect
        let crop = rect.isEmpty ? "full" : String(
            format: "%.0f,%.0f %.0fx%.0f",
            rect.minX, rect.minY, rect.width, rect.height
        )
        return "output=\(configuration.width)x\(configuration.height) fps=\(CaptureEngine.fps(of: configuration)) crop=\(crop) backingScale=\(windowController.backingScale)"
    }

    private func retune(reason: String) {
        guard engine.isRunning else { return }
        let configuration = makeConfiguration()
        windowController.recordRendererEvent(
            "capture.retune reason=\(reason) \(configurationSummary(configuration))"
        )
        engine.retune(configuration)
    }

    private func pauseCapture(reason: String) {
        guard engine.isRunning, !engine.isPaused else { return }
        windowController.recordRendererEvent("capture.pause reason=\(reason)")
        engine.pause()
    }

    private func resumeCapture(reason: String) {
        guard engine.isPaused else { return }
        windowController.recordRendererEvent("capture.resume reason=\(reason)")
        windowController.prepareForCaptureDiscontinuity(reason)
        engine.resume()
    }

    private func restartCapture(reason: String) {
        windowController.recordRendererEvent("capture.restart.request reason=\(reason)")
        Log.debug("\(reason)")
        engine.restart()
    }

    private func startCapture() {
        switch state.source {
        case let .window(windowID, _, _, _):
            ShareableContentStore.shared.window(id: windowID) { [weak self] window in
                guard let self, !self.isClosed else { return }
                guard let window else {
                    self.handleSourceMissing()
                    return
                }
                self.syncBaseRectIfNeeded(with: window)
                self.startStream(filter: CaptureEngine.filter(for: window))
            }
        case let .region(displayID, _):
            ShareableContentStore.shared.display(id: displayID) { [weak self] display in
                guard let self, !self.isClosed else { return }
                guard let display else {
                    self.handleSourceMissing()
                    return
                }
                let own = ShareableContentStore.shared.cachedOwnWindows
                self.startStream(filter: CaptureEngine.filter(forDisplay: display,
                                                             excludingOwnWindows: own))
            }
        }
    }

    private func startStream(filter: SCContentFilter) {
        let configuration = makeConfiguration()
        windowController.recordRendererEvent("capture.start \(configurationSummary(configuration))")
        do {
            try engine.start(filter: filter, configuration: configuration)
            reconnectAttempt = 0
            update(runtimeState: state.isPaused ? .paused : .streaming)
        } catch {
            Log.error("\(error.localizedDescription)")
            if !Permissions.hasScreenRecording {
                update(runtimeState: .permissionDenied)
            } else {
                update(runtimeState: .failed(message: error.localizedDescription))
                scheduleReconnect()
            }
        }
    }

    ///
    private func syncBaseRectIfNeeded(with window: SCWindow) {
        guard case .window = state.source else { return }
        let isFullWindow = abs(baseRect.minX) < 0.5 && abs(baseRect.minY) < 0.5
        guard isFullWindow else { return }
        guard let size = trustedSize(of: window) else { return }
        guard abs(baseRect.width - size.width) > 1 || abs(baseRect.height - size.height) > 1 else { return }
        let oldBase = baseRect
        let newBase = CGRect(origin: .zero, size: size)
        if let selectedBaseRect {
            self.selectedBaseRect = Geo.remap(selectedBaseRect, from: oldBase, to: newBase)
            state.hasSelectionCrop = self.selectedBaseRect != nil
        }
        baseRect = newBase
        let scale = ShareableContentStore.shared.backingScale(of: window)
        sourcePixelSize = CGSize(width: size.width * scale, height: size.height * scale)
        windowController.setAspect((selectedBaseRect ?? baseRect).size)
        state.anchor = Geo.clampAnchor(state.anchor, zoom: state.zoom)
    }

    private func trustedSize(of window: SCWindow) -> CGSize? {
        let size = Geo.trustedSourceSize(
            sampled: window.frame.size,
            current: baseRect,
            axSize: SourceWindowActivator.currentSize(of: window.windowID)
        )
        if size == nil {
            Log.debug("""
                 \(Int(window.frame.width))×\(Int(window.frame.height)) \

                """)
        }
        return size
    }

    ///
    private func scheduleGeometryRecheck() {
        guard case let .window(windowID, _, _, _) = state.source else { return }
        geometryRecheckWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isClosed else { return }
            ShareableContentStore.shared.window(id: windowID) { [weak self] window in
                guard let self, !self.isClosed, let window else { return }
                let before = self.baseRect
                self.syncBaseRectIfNeeded(with: window)
                guard self.baseRect != before else { return }
                Log.debug("""
                    \(Int(before.width))×\(Int(before.height)) → \
                    \(Int(self.baseRect.width))×\(Int(self.baseRect.height))
                    """)
                self.retune(reason: "")
            }
        }
        geometryRecheckWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.geometryRecheckDelay, execute: work)
    }

    // MARK: - CaptureEngineDelegate

    func captureWillRestart() {
        windowController.recordRendererEvent("capture.restart.begin")
        windowController.prepareForCaptureDiscontinuity("")
    }

    func captureDidOutput(_ sampleBuffer: CMSampleBuffer) {
        if state.idleDetection,
           let verdict = idleDetector.feed(sampleBuffer, activeFPS: state.fps.rawValue) {
            DispatchQueue.main.async { [weak self] in self?.apply(verdict) }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isClosed else { return }
            self.offscreenRetargetAttempted = false
            if case .streaming = self.runtimeState {} else if !self.state.isPaused {
                self.update(runtimeState: .streaming)
                self.reconnectAttempt = 0
                self.probeTimer?.invalidate()
                self.probeTimer = nil
            }
            self.windowController.enqueue(sampleBuffer)
        }
    }

    func captureDidStop(error: Error?) {
        guard !isClosed else { return }
        guard let error else { return }
        windowController.recordRendererEvent("capture.stop error=\(error.localizedDescription)")
        Log.warn("\(error.localizedDescription)")
        if !Permissions.hasScreenRecording {
            update(runtimeState: .permissionDenied)
            return
        }
        scheduleReconnect()
    }

    func captureDidStall() {
        guard !isClosed, !state.isPaused, !state.isHidden, !isAutoHidden else { return }
        windowController.recordRendererEvent("capture.stall no-valid-frame")
        update(runtimeState: .sourceOffscreen)
        startProbeTimer()
    }

    private func apply(_ verdict: IdleVerdict) {
        guard !isClosed, state.idleDetection else { return }
        guard verdict.isIdle != idleThrottled else { return }
        idleThrottled = verdict.isIdle
        Log.debug("\(verdict.isIdle ? " 1fps" : " \(state.fps.rawValue)fps")")
        let configuration = makeConfiguration(fps: verdict.suggestedFPS)
        windowController.recordRendererEvent(
            "capture.retune reason=\(verdict.isIdle ? "" : "") \(configurationSummary(configuration))"
        )
        engine.retune(configuration)
    }


    private func startProbeTimer() {
        guard probeTimer == nil else { return }
        probeTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.probeSource()
        }
    }

    private func probeSource() {
        guard !isClosed, !isSourceProbeInFlight else { return }
        switch state.source {
        case let .window(windowID, _, _, _):
            isSourceProbeInFlight = true
            let expectedPID = sourcePID
            Self.sourceProbeQueue.async { [weak self] in
                let observation = SourceWindowActivator.lifecycleObservation(
                    of: windowID,
                    expectedPID: expectedPID
                )
                let health = classifySourceWindowHealth(observation)
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.isClosed else { return }
                    self.isSourceProbeInFlight = false
                    self.applySourceHealth(health, windowID: windowID)
                }
            }
        case .region:
            restartCapture(reason: "")
        }
    }

    private func applySourceHealth(_ health: SourceWindowHealth, windowID: CGWindowID) {
        switch health {
        case .onScreen:
            offscreenRetargetAttempted = false
            ShareableContentStore.shared.window(id: windowID) { [weak self] window in
                guard let self, !self.isClosed, let window else { return }
                self.resumeWindowCapture(
                    window,
                    reason: " Space",
                    syncGeometry: true,
                    recheckGeometry: true
                )
            }

        case .offScreenAlive:
            update(runtimeState: .sourceOffscreen)
            guard !offscreenRetargetAttempted else { return }
            offscreenRetargetAttempted = true
            ShareableContentStore.shared.window(id: windowID) { [weak self] window in
                guard let self, !self.isClosed, let window else { return }
                self.resumeWindowCapture(
                    window,
                    reason: " retarget",
                    syncGeometry: false,
                    recheckGeometry: false
                )
            }

        case .minimized:
            update(runtimeState: .minimized)

        case .missing:
            attemptRematch()

        case .unknown:
            update(runtimeState: .sourceOffscreen)
        }
    }

    private func resumeWindowCapture(
        _ window: SCWindow,
        reason: String,
        syncGeometry: Bool,
        recheckGeometry: Bool
    ) {
        Log.debug("\(reason)")
        probeTimer?.invalidate()
        probeTimer = nil
        if syncGeometry { syncBaseRectIfNeeded(with: window) }
        engine.retarget(CaptureEngine.filter(for: window))
        restartCapture(reason: reason)
        update(runtimeState: .streaming)
        if recheckGeometry { scheduleGeometryRecheck() }
    }

    private func scheduleReconnect() {
        guard !isClosed, reconnectAttempt < Self.maxReconnectAttempts else {
            attemptRematch()
            return
        }
        reconnectAttempt += 1
        let delay = pow(2.0, Double(reconnectAttempt - 1))   // 1s / 2s / 4s
        update(runtimeState: .reconnecting(attempt: reconnectAttempt))
        reconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isClosed else { return }
            Log.debug(" \(self.reconnectAttempt) ")
            self.windowController.recordRendererEvent(
                "capture.reconnect attempt=\(self.reconnectAttempt)"
            )
            self.windowController.prepareForCaptureDiscontinuity("")
            self.engine.stop()
            self.startCapture()
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func attemptRematch() {
        guard case let .window(_, bundleID, appName, title) = state.source else {
            handleSourceMissing()
            return
        }
        ShareableContentStore.shared.rematch(bundleID: bundleID, appName: appName, title: title) {
            [weak self] window in
            guard let self, !self.isClosed else { return }
            guard let window else {
                self.handleSourceMissing()
                return
            }
            Log.info("\(ShareableContentStore.shared.displayTitle(for: window))")
            self.adoptRematchedWindow(window, reason: "")
        }
    }

    private func adoptRematchedWindow(_ window: SCWindow, reason: String) {
        state.source = ShareableContentStore.shared.captureSource(for: window)
        positionIdentity = positionIdentity.retargetingWindow(to: state.source)
        sourcePID = window.owningApplication?.processID
        offscreenRetargetAttempted = false
        let size = trustedSize(of: window) ?? baseRect.size
        let oldBase = baseRect
        let newBase = CGRect(origin: .zero, size: size)
        if let selectedBaseRect {
            self.selectedBaseRect = Geo.remap(selectedBaseRect, from: oldBase, to: newBase)
            state.hasSelectionCrop = self.selectedBaseRect != nil
        }
        baseRect = newBase
        let scale = ShareableContentStore.shared.backingScale(of: window)
        sourcePixelSize = CGSize(width: size.width * scale, height: size.height * scale)
        windowController.setTitle(state.source.displayTitle)
        windowController.setAspect((selectedBaseRect ?? baseRect).size)
        probeTimer?.invalidate()
        probeTimer = nil
        reconnectWork?.cancel()
        reconnectWork = nil
        reconnectAttempt = 0
        windowController.recordRendererEvent("capture.rematch source=\(state.source.displayTitle) reason=\(reason)")
        windowController.prepareForCaptureDiscontinuity(reason)
        engine.stop()
        startStream(filter: CaptureEngine.filter(for: window))
    }

    private func handleSourceMissing() {
        guard !isClosed else { return }
        windowController.recordRendererEvent("capture.source-missing")
        update(runtimeState: .sourceLost)
        engine.stop()
        probeTimer?.invalidate()
        probeTimer = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.close() }
    }

    private func update(runtimeState newState: SessionRuntimeState) {
        guard runtimeState != newState else { return }
        windowController.recordRendererEvent(
            "session.runtime \(String(describing: runtimeState)) -> \(String(describing: newState))"
        )
        runtimeState = newState
        windowController.update(runtimeState: newState)
    }


    private func registerHoverMonitor() {
        HoverMonitor.shared.register(
            id: id,
            frameProvider: { [weak self] in
                guard let self, !self.isClosed, !self.state.isHidden else { return nil }
                return self.windowController.window.frame
            },
            hotZoneProvider: { [weak self] in
                guard let self, !self.isClosed, !self.state.isHidden else { return nil }
                return self.windowController.barScreenFrame
            },
            resizeZoneThicknessProvider: { [weak self] in
                guard let self, !self.isClosed, !self.state.isHidden, self.state.autoHide else { return 0 }
                return self.windowController.autoHideResizeHotZoneThickness
            },
            onChange: { [weak self] hover in
                self?.handleHover(hover)
            }
        )
    }

    ///
    private func handleHover(_ hover: HoverState) {
        guard !isClosed else { return }

        if hover.isHovering, !wasHovering { refreshSourceTitleNow() }
        wasHovering = hover.isHovering

        guard state.autoHide else {
            peekReason = nil
            windowController.setControlsVisible(hover.isHovering)
            return
        }

        if isLiveResizing {
            beginPeek(.resize)
            return
        }

        switch autoHideHoverIntent(for: hover) {
        case .leave:
            endAutoHide()
        case .resize:
            beginPeek(.resize)
        case .bar:
            beginPeek(.bar)
        case .command:
            beginPeek(.commandZoom)
        case .option:
            beginPeek(.option)
        case .fade:
            beginAutoHide()
        }
    }

    private func beginAutoHide() {
        guard !isAutoHidden || isPeeking else { return }
        isAutoHidden = true
        peekReason = nil
        windowController.showHint(nil, near: nil)
        windowController.setAlpha(Preferences.shared.autoHideOpacity, animated: true)
        windowController.setClickThrough(true)
        windowController.setControlsVisible(false)
        if !state.isPaused { pauseCapture(reason: "") }
    }

    private func beginPeek(_ reason: PeekReason) {
        guard peekReason != reason else { return }
        peekReason = reason
        isAutoHidden = true
        windowController.setAlpha(1, animated: true)
        windowController.setClickThrough(false)
        windowController.setControlsVisible(reason == .option || reason == .bar)
        if !state.isPaused, !state.isHidden { resumeCapture(reason: "") }
        switch reason {
        case .option:
            windowController.showHint(("Release ⌥ to fade again"), near: nil)
        case .commandZoom:
            windowController.showHint(nil, near: nil)
        case .resize:
            windowController.showHint(nil, near: nil)
        case .bar:
            windowController.showHint(("Leave the top bar to fade again"),
                                      near: nil, duration: 2.0)
        }
    }

    private func endAutoHide() {
        guard isAutoHidden || isPeeking else { return }
        isAutoHidden = false
        peekReason = nil
        windowController.showHint(nil, near: nil)
        windowController.setAlpha(1, animated: true)
        windowController.setClickThrough(false)
        windowController.setControlsVisible(false)
        if !state.isPaused, !state.isHidden { resumeCapture(reason: "") }
    }


    private func observeOcclusion() {
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: windowController.window,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.isClosed, !self.state.isPaused, !self.state.isHidden else { return }
            let visible = self.windowController.window.occlusionState.contains(.visible)
            if visible {
                self.resumeCapture(reason: "")
                self.scheduleGeometryRecheck()
            } else {
                self.pauseCapture(reason: "")
            }
            Log.debug("\(visible ? "" : "")")
        }
    }


    func handleScreenParametersChanged() {
        guard !isClosed else { return }
        retune(reason: "")
    }

    private func persistGeometry() {
        Preferences.shared.setPreferredWidth(
            windowController.contentPointSize.width, for: state.source.preferenceKey
        )
        persistOrigin()
    }

    private func persistOrigin() {
        Preferences.shared.setOrigin(windowController.frameOrigin, for: positionIdentity)
    }

    // MARK: - PiPWindowDelegate

    var currentSessionState: PiPSessionState { state }

    func pipRequestClose() { close() }

    func pipRequestZoom(_ zoom: CGFloat, anchor: CGPoint) { applyZoom(zoom, anchor: anchor) }

    func pipRequestSelection(_ normalizedRect: CGRect) { applySelection(normalizedRect) }

    func pipRequestPan(by delta: CGSize) {
        guard state.zoom > 1.001 else { return }
        state.anchor = Geo.anchor(state.anchor, pannedBy: delta, zoom: state.zoom)
        retune(reason: "")
    }

    func pipRequestZoomReset() { resetZoom() }

    func pipWillStartLiveResize() {
        guard !isClosed else { return }
        isLiveResizing = true
        if state.autoHide { beginPeek(.resize) }
    }

    func pipDidEndLiveResize() {
        guard !isClosed else { return }
        isLiveResizing = false
        guard state.autoHide else { return }
        handleHover(HoverMonitor.shared.currentState(for: id))
    }

    func pipDidResize(pointSize: CGSize, scale: CGFloat) {
        guard !isClosed else { return }
        Preferences.shared.setPreferredWidth(pointSize.width, for: state.source.preferenceKey)
        retune(reason: " \(Int(pointSize.width))x\(Int(pointSize.height)) scale=\(scale)")
    }

    func pipRequestFPS(_ fps: FPSStep) { setFPS(fps) }

    func pipRequestToggleAutoHide() { toggleAutoHide() }

    func pipRequestAutoHideOpacity(_ opacity: CGFloat) { setAutoHideOpacity(opacity) }

    func pipRequestToggleIdleDetection() { toggleIdleDetection() }

    func pipRequestTogglePause() { setPaused(!state.isPaused) }

    func pipRendererRecoveryExhausted() {
        guard !isClosed, !state.isPaused, !state.isHidden else { return }
        let now = ProcessInfo.processInfo.systemUptime
        rendererRestartTimes = rendererRestartTimes.filter { now - $0 < Self.rendererRestartWindow }
        guard rendererRestartTimes.count < Self.rendererRestartLimit else {
            Log.error("""
                renderer \(Self.rendererRestartWindow)s  \
                \(Self.rendererRestartLimit) \(state.source.displayTitle)
                """)
            windowController.showHint(
                ("Could not recover automatically — close and reopen this PiP"),
                near: nil,
                duration: 6.0
            )
            return
        }
        rendererRestartTimes.append(now)
        Log.warn("\(state.source.displayTitle)")
        restartCapture(reason: "renderer ")
    }

    func pipRendererDidRecover() { rendererRestartTimes.removeAll() }

    func pipRequestActivateSource() { activateSource() }

    func pipRequestToggleClickToActivate() {
        Preferences.shared.clickToActivateSource.toggle()
        let on = Preferences.shared.clickToActivateSource
        windowController.showHint(
            on ? ("Click the PiP to switch to the source window")
               : ("Click-to-switch is off"),
            near: nil, duration: 2.0
        )
        windowController.update(state: state)
    }


    ///
    func activateSource() {
        guard !isClosed else { return }
        guard Preferences.shared.clickToActivateSource else {
            windowController.bringToFront()
            return
        }

        switch state.source {
        case let .window(windowID, bundleID, appName, title):
            var pid = ShareableContentStore.shared.cachedWindow(id: windowID)?
                .owningApplication?.processID
                ?? SourceWindowActivator.ownerPID(of: windowID)
            if pid == nil, let bundleID, !bundleID.isEmpty {
                pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                    .first?.processIdentifier
            }
            guard let pid else {
                windowController.showHint(
                    ("The source app seems to have quit"),
                    near: nil, duration: 2.0
                )
                return
            }
            switch SourceWindowActivator.activate(
                windowID: windowID, pid: pid, fallbackTitle: title
            ) {
            case .raised:
                Log.debug("\(appName) [windowID=\(windowID)]")
            case .applicationOnly:
                if !didExplainApplicationOnlyActivation {
                    didExplainApplicationOnlyActivation = true
                    windowController.showHint(
                        ("Grant Accessibility to switch to this exact window"),
                        near: nil, duration: 3.0
                    )
                }
            case .windowNotFound:
                windowController.showHint(
                    ("Switched to the source app, but could not locate the exact window"),
                    near: nil, duration: 2.0
                )
                Log.warn(" AX \(appName) [windowID=\(windowID)]")
            case .activationFailed:
                windowController.showHint(
                    ("Could not activate the source window"),
                    near: nil, duration: 2.0
                )
            case .applicationNotFound:
                windowController.showHint(
                    ("The source app seems to have quit"),
                    near: nil, duration: 2.0
                )
            }

        case .region:
            windowController.showHint(
                ("This PiP captures a screen region — no source app to switch to"),
                near: nil, duration: 2.0
            )
        }
    }

    func pipMenuWillOpen() { refreshSourceTitleNow() }

    func pipResolveDragFrame(_ proposedFrame: CGRect,
                             modifierFlags: NSEvent.ModifierFlags) -> CGRect {
        onResolveDragFrame?(proposedFrame, modifierFlags) ?? proposedFrame
    }

    func pipDidMove() {
        persistOrigin()
    }
}
