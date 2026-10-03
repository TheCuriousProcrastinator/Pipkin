import AVFoundation
import AppKit
import CoreMedia
import CoreVideo

///
///
final class PiPContentView: NSView {


    var onRequestZoom: ((CGFloat, CGPoint) -> Void)?
    var onRequestSelection: ((CGRect) -> Void)?
    var onRequestPan: ((CGSize) -> Void)?
    var onRequestZoomReset: (() -> Void)?
    var onRequestClose: (() -> Void)?
    var onRequestCycleFPS: (() -> Void)?
    var onRequestToggleIdleDetection: (() -> Void)?
    var onRequestTogglePause: (() -> Void)?
    var onResolveDraggedWindowFrame: ((CGRect, NSEvent.ModifierFlags) -> CGRect)?
    var onRendererRecoveryExhausted: (() -> Void)?
    var onRendererIncidentRecovered: ((String) -> Void)?
    var onDidDragWindow: (() -> Void)?
    var onRequestActivateSource: (() -> Void)?


    private var displayLayer: AVSampleBufferDisplayLayer
    private var contentGeometry: FrameGate.ContentGeometry?
    private let selectionLayer = CAShapeLayer()
    private var didLogRenderFailure = false
    private var diagnosticLabel = "-"

    private static let rendererStallTimeout: TimeInterval = 2.0
    private var stallMonitor = RendererStallMonitor(timeout: rendererStallTimeout)
    private var flushToken = 0
    private var flushInFlightSince: TimeInterval?
    private var lastIncomingPTS: CMTime?
    private var lastPixelSize: CGSize?
    private var lastIncomingUptime: TimeInterval?
    private var lastEnqueuedUptime: TimeInterval?
    private var incomingFrameCount: UInt64 = 0
    private var enqueuedFrameCount: UInt64 = 0
    private var notReadyDropCount: UInt64 = 0
    private var rendererRecoveryCount: UInt64 = 0
    private var diagnostics = RendererDiagnostics()
    private var currentIncidentID: String?
    private var currentIncidentStallStartedAt: TimeInterval?
    private var currentIncidentDetectedAt: TimeInterval?
    private var lastRendererStateSignature: String?


    private var zoom: CGFloat = PiPSessionState.minZoom
    private var anchor = CGPoint(x: 0.5, y: 0.5)
    private var aspect = CGSize(width: 16, height: 9)


    private var selectionStart: CGPoint?
    private var isSelecting = false


    private var dragStartMouseInScreen: CGPoint?
    private var dragStartWindowOrigin: CGPoint?
    private var didDrag = false
    private static let dragThreshold: CGFloat = 3
    private static let activateBlockingFlags: NSEvent.ModifierFlags = [.command, .option, .control, .shift]


    private var pendingPan: CGSize = .zero
    private var pendingZoom: (zoom: CGFloat, anchor: CGPoint)?
    private var flushScheduled = false


    private var isMouseInside = false
    private var mouseTracking: NSTrackingArea?

    private static let keyboardZoomFactor: CGFloat = 1.25
    private static let preciseZoomUnit: CGFloat = 0.01
    private static let coarseZoomUnit: CGFloat = 0.1


    override init(frame frameRect: NSRect) {
        displayLayer = Self.makeDisplayLayer()
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        selectionLayer.fillColor = NSColor(calibratedWhite: 1, alpha: 0.16).cgColor
        selectionLayer.strokeColor = NSColor(calibratedRed: 0.29, green: 0.63, blue: 1, alpha: 0.95).cgColor
        selectionLayer.lineWidth = 1.5
        selectionLayer.isHidden = true

        attachLayersIfNeeded()
    }

    required init?(coder: NSCoder) {
        fatalError("PiPContentView  xib/storyboard")
    }


    override func layout() {
        super.layout()
        attachLayersIfNeeded()
        layoutDisplayLayer()
        selectionLayer.frame = bounds
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        displayLayer.contentsScale = scale
        selectionLayer.contentsScale = scale
    }

    private func attachLayersIfNeeded() {
        guard let root = layer else { return }
        root.backgroundColor = NSColor.black.cgColor
        if displayLayer.superlayer == nil { root.addSublayer(displayLayer) }
        if selectionLayer.superlayer == nil { root.addSublayer(selectionLayer) }
        selectionLayer.zPosition = 10
    }

    private static func makeDisplayLayer() -> AVSampleBufferDisplayLayer {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resize
        layer.backgroundColor = NSColor.black.cgColor
        return layer
    }

    private func layoutDisplayLayer() {
        let targetFrame: CGRect
        if let geometry = contentGeometry,
           let cropped = Geo.displayLayerFrame(
               bufferSize: geometry.bufferSize,
               visibleRectPixels: geometry.visibleRectPixels,
               in: bounds
           ) {
            targetFrame = cropped
        } else {
            targetFrame = bounds
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = targetFrame
        CATransaction.commit()
    }

    private func updateContentGeometry(from sampleBuffer: CMSampleBuffer, at now: TimeInterval) {
        guard let newGeometry = FrameGate.contentGeometry(sampleBuffer) else { return }
        guard contentGeometry != newGeometry else { return }
        contentGeometry = newGeometry
        if newGeometry.hasPadding {
            let v = newGeometry.visibleRectPixels
            diagnostics.record(
                "frame.content-padding buffer=\(Int(newGeometry.bufferSize.width))x\(Int(newGeometry.bufferSize.height)) "
                    + "visible=\(Int(v.minX)),\(Int(v.minY)),\(Int(v.width))x\(Int(v.height))",
                at: now
            )
        }
        layoutDisplayLayer()
    }


    func update(state: PiPSessionState, aspect: CGSize) {
        zoom = Geo.clampZoom(state.zoom)
        anchor = Geo.clampAnchor(state.anchor, zoom: zoom)
        update(aspect: aspect)
    }

    func update(aspect newAspect: CGSize) {
        guard newAspect.width > 0, newAspect.height > 0 else { return }
        aspect = newAspect
    }

    func setDiagnosticLabel(_ label: String) {
        let flattened = label.components(separatedBy: .newlines).joined(separator: " ")
        diagnosticLabel = flattened.isEmpty ? "-" : String(flattened.prefix(512))
        recordDiagnosticEvent("session.label \(diagnosticLabel)")
    }

    func recordDiagnosticEvent(_ event: String) {
        diagnostics.record(event, at: ProcessInfo.processInfo.systemUptime)
    }

    var debugEnqueuedFrameCount: UInt64 { enqueuedFrameCount }
    var debugNotReadyDropCount: UInt64 { notReadyDropCount }


    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }

        let now = ProcessInfo.processInfo.systemUptime
        incomingFrameCount &+= 1
        lastIncomingUptime = now
        updateContentGeometry(from: sampleBuffer, at: now)
        let renderer = displayLayer.sampleBufferRenderer
        recordRendererTransition(renderer, at: now)

        if let reason = incomingDiscontinuity(in: sampleBuffer) {
            diagnostics.record("frame.discontinuity \(reason)", at: now)
            var action = stallMonitor.requestImmediateFlush(at: now)
            if action == .none { action = stallMonitor.observeNotReady(at: now) }
            perform(action, at: now, reason: reason, planned: true)
            notReadyDropCount &+= 1
            return
        }

        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            if !didLogRenderFailure {
                didLogRenderFailure = true
                diagnostics.record("renderer.failure \(rendererState(renderer))", at: now)
                Log.warn("renderer  [\(diagnosticLabel)]\(renderer.error?.localizedDescription ?? "-")")
            }
            var action = stallMonitor.requestImmediateFlush(at: now)
            if action == .none { action = stallMonitor.observeNotReady(at: now) }
            perform(action, at: now, reason: "renderer failed")
            notReadyDropCount &+= 1
            return
        }
        didLogRenderFailure = false

        if flushInFlightSince != nil {
            notReadyDropCount &+= 1
            let action = stallMonitor.observeNotReady(at: now)
            perform(action, at: now, reason: "flush ")
            return
        }

        guard renderer.isReadyForMoreMediaData else {
            let wasTrackingStall = stallMonitor.isTrackingStall
            notReadyDropCount &+= 1
            let action = stallMonitor.observeNotReady(at: now)
            if !wasTrackingStall {
                diagnostics.record("renderer.not-ready.begin \(rendererState(renderer))", at: now)
                Log.debug("renderer  not-ready [\(diagnosticLabel)]")
            }
            perform(action, at: now, reason: " not-ready")
            return
        }

        if let stallDuration = stallMonitor.observeReady(at: now) {
            let message = "renderer  [\(diagnosticLabel)]not-ready \(String(format: "%.1f", stallDuration))s \(notReadyDropCount)"
            if stallDuration >= Self.rendererStallTimeout {
                Log.info(message)
            } else {
                Log.debug(message)
            }
            finishIncidentIfNeeded(at: now, stallDuration: stallDuration)
        }
        renderer.enqueue(sampleBuffer)
        enqueuedFrameCount &+= 1
        lastEnqueuedUptime = now
    }

    func prepareForCaptureDiscontinuity(_ reason: String) {
        let now = ProcessInfo.processInfo.systemUptime
        diagnostics.record("capture.discontinuity \(reason)", at: now)
        lastIncomingPTS = nil
        lastPixelSize = nil
        stallMonitor.reset()
        let action = stallMonitor.requestImmediateFlush(at: now)
        perform(action, at: now, reason: reason, planned: true)
    }

    func flushAndReset() {
        let now = ProcessInfo.processInfo.systemUptime
        diagnostics.record("renderer.reset removing-image=true", at: now)
        if let id = currentIncidentID {
            Log.warn("renderer incident \(id)  ready reset  [\(diagnosticLabel)]")
            currentIncidentID = nil
            currentIncidentStallStartedAt = nil
            currentIncidentDetectedAt = nil
        }
        flushToken &+= 1
        flushInFlightSince = nil
        displayLayer.sampleBufferRenderer.flush(
            removingDisplayedImage: true, completionHandler: nil
        )
        stallMonitor.reset()
        lastIncomingPTS = nil
        lastPixelSize = nil
        contentGeometry = nil
        layoutDisplayLayer()
        lastRendererStateSignature = nil
        cancelSelection()
        resetDragTracking()
        pendingPan = .zero
        pendingZoom = nil
        didLogRenderFailure = false
    }


    private func incomingDiscontinuity(in sampleBuffer: CMSampleBuffer) -> String? {
        var reason: String?

        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                              height: CVPixelBufferGetHeight(pixelBuffer))
            if let previous = lastPixelSize, previous != size {
                reason = " \(Int(previous.width))×\(Int(previous.height)) → \(Int(size.width))×\(Int(size.height))"
            }
            lastPixelSize = size
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if pts.isValid {
            if let previous = lastIncomingPTS, previous.isValid, CMTimeCompare(pts, previous) < 0 {
                reason = "PTS "
            }
            lastIncomingPTS = pts
        }
        return reason
    }

    private func perform(_ action: RendererStallMonitor.RecoveryAction,
                         at now: TimeInterval, reason: String, planned: Bool = false) {
        guard action != .none else { return }
        let isPlannedFlush = planned && action == .flush
        if !isPlannedFlush { beginIncidentIfNeeded(at: now, trigger: reason) }

        switch action {
        case .none:
            return
        case .flush:
            beginRendererFlush(at: now, reason: reason, planned: planned)
        case .rebuildLayer:
            diagnostics.record("recovery.rebuild-layer reason=\(reason)", at: now)
            rebuildDisplayLayer(reason: reason)
        case .restartCapture:
            diagnostics.record("recovery.restart-capture reason=\(reason)", at: now)
            Log.error("renderer  [\(diagnosticLabel)]\(reason)")
            onRendererRecoveryExhausted?()
        }
    }

    private func beginRendererFlush(at now: TimeInterval, reason: String, planned: Bool) {
        guard flushInFlightSince == nil else { return }
        flushToken &+= 1
        let token = flushToken
        flushInFlightSince = now
        diagnostics.record("recovery.flush.begin planned=\(planned) reason=\(reason)", at: now)
        if planned {
            Log.debug("renderer  [\(diagnosticLabel)]\(reason)")
        } else {
            rendererRecoveryCount &+= 1
            Log.warn("renderer  #\(rendererRecoveryCount) [\(diagnosticLabel)]flush=\(reason)=\(enqueuedFrameCount)not-ready =\(notReadyDropCount)")
        }

        displayLayer.sampleBufferRenderer.flush(
            removingDisplayedImage: false
        ) { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.flushToken == token else { return }
                let completedAt = ProcessInfo.processInfo.systemUptime
                self.diagnostics.record(
                    String(format: "recovery.flush.complete duration=%.3fs", completedAt - now),
                    at: completedAt
                )
                self.flushInFlightSince = nil
            }
        }
    }

    private func rebuildDisplayLayer(reason: String) {
        flushToken &+= 1
        flushInFlightSince = nil
        rendererRecoveryCount &+= 1

        let old = displayLayer
        old.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        old.removeFromSuperlayer()

        let replacement = Self.makeDisplayLayer()
        replacement.contentsScale = window?.backingScaleFactor ?? 2
        displayLayer = replacement
        layoutDisplayLayer()

        if let root = layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            root.insertSublayer(replacement, at: 0)
            CATransaction.commit()
        }
        lastIncomingPTS = nil
        lastPixelSize = nil
        lastRendererStateSignature = nil
        Log.warn("renderer  #\(rendererRecoveryCount) [\(diagnosticLabel)] display layer=\(reason)")
    }

    private func beginIncidentIfNeeded(at now: TimeInterval, trigger: String) {
        guard currentIncidentID == nil else { return }
        let id = "R-\(UUID().uuidString.prefix(8).uppercased())"
        currentIncidentID = id
        currentIncidentStallStartedAt = stallMonitor.stallStartedAt ?? now
        currentIncidentDetectedAt = now
        diagnostics.record("incident.begin id=\(id) trigger=\(trigger)", at: now)
        let report = diagnostics.incidentReport(
            id: id,
            label: diagnosticLabel,
            at: now,
            trigger: trigger,
            snapshot: rendererSnapshot(at: now)
        )
        Log.warn("\(report)\n  log file: \(Log.filePath)")
    }

    private func finishIncidentIfNeeded(at now: TimeInterval, stallDuration lastPhaseDuration: TimeInterval) {
        guard let id = currentIncidentID else { return }
        let timing = RendererIncidentTiming(
            stallStartedAt: currentIncidentStallStartedAt,
            detectedAt: currentIncidentDetectedAt,
            recoveredAt: now,
            lastPhaseDuration: lastPhaseDuration
        )
        diagnostics.record(
            String(
                format: "incident.recovered id=%@ stallDuration=%.3fs recoveryDuration=%.3fs",
                id, timing.stallDuration, timing.recoveryDuration
            ),
            at: now
        )
        Log.info(
            "renderer incident \(id)  [\(diagnosticLabel)] "
                + "\(String(format: "%.3f", timing.stallDuration))s "
                + "\(String(format: "%.3f", timing.recoveryDuration))s \(Log.filePath)"
        )
        currentIncidentID = nil
        currentIncidentStallStartedAt = nil
        currentIncidentDetectedAt = nil
        onRendererIncidentRecovered?(id)
    }

    private func recordRendererTransition(_ renderer: AVSampleBufferVideoRenderer,
                                          at now: TimeInterval) {
        let signature = rendererState(renderer)
        guard signature != lastRendererStateSignature else { return }
        lastRendererStateSignature = signature
        diagnostics.record("renderer.state \(signature)", at: now)
    }

    private func rendererSnapshot(at now: TimeInterval) -> String {
        let renderer = displayLayer.sampleBufferRenderer
        let pixel = lastPixelSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "-"
        let pts: String
        if let lastIncomingPTS, lastIncomingPTS.isValid {
            pts = String(format: "%.6f", CMTimeGetSeconds(lastIncomingPTS))
        } else {
            pts = "-"
        }
        let flushAge = age(since: flushInFlightSince, now: now)
        return "\(rendererState(renderer)) incoming=\(incomingFrameCount) enqueued=\(enqueuedFrameCount) dropped=\(notReadyDropCount) lastIncomingAge=\(age(since: lastIncomingUptime, now: now)) lastEnqueuedAge=\(age(since: lastEnqueuedUptime, now: now)) flushAge=\(flushAge) pixel=\(pixel) pts=\(pts)"
    }

    private func rendererState(_ renderer: AVSampleBufferVideoRenderer) -> String {
        let status: String
        switch renderer.status {
        case .unknown: status = "unknown"
        case .rendering: status = "rendering"
        case .failed: status = "failed"
        @unknown default: status = "future(\(renderer.status.rawValue))"
        }
        let error = renderer.error.map { String(describing: $0) } ?? "-"
        return "status=\(status) ready=\(renderer.isReadyForMoreMediaData) requiresFlush=\(renderer.requiresFlushToResumeDecoding) error=\(error)"
    }

    private func age(since uptime: TimeInterval?, now: TimeInterval) -> String {
        guard let uptime else { return "-" }
        return String(format: "%.3fs", max(0, now - uptime))
    }


    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var mouseDownCanMoveWindow: Bool { false }


    override func mouseDown(with event: NSEvent) {
        let isCommand = event.modifierFlags.contains(.command)

        if isCommand && event.clickCount >= 2 {
            cancelSelection()
            resetDragTracking()
            onRequestZoomReset?()
            return
        }

        if isCommand {
            resetDragTracking()
            selectionStart = convert(event.locationInWindow, from: nil)
            isSelecting = true
            selectionLayer.path = nil
            selectionLayer.isHidden = false
            return
        }

        cancelSelection()
        didDrag = false
        dragStartMouseInScreen = window?.convertPoint(toScreen: event.locationInWindow)
        dragStartWindowOrigin = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        if isSelecting, let start = selectionStart {
            let current = convert(event.locationInWindow, from: nil)
            selectionLayer.path = CGPath(rect: Self.rect(from: start, to: current), transform: nil)
            return
        }

        guard let window,
              let startMouse = dragStartMouseInScreen,
              let startOrigin = dragStartWindowOrigin else {
            super.mouseDragged(with: event)
            return
        }

        let current = window.convertPoint(toScreen: event.locationInWindow)
        let dx = current.x - startMouse.x
        let dy = current.y - startMouse.y
        if !didDrag {
            guard hypot(dx, dy) > Self.dragThreshold else { return }
            didDrag = true
        }

        var frame = window.frame
        frame.origin = CGPoint(x: (startOrigin.x + dx).rounded(), y: (startOrigin.y + dy).rounded())
        let resolved = onResolveDraggedWindowFrame?(frame, event.modifierFlags) ?? frame
        frame.origin = resolved.origin
        window.setFrameOrigin(Geo.constrainToVisibleScreens(frame).origin)
    }

    override func mouseUp(with event: NSEvent) {
        if isSelecting, let start = selectionStart {
            let selection = Self.rect(from: start, to: convert(event.locationInWindow, from: nil))
            cancelSelection()

            guard let normalized = Geo.visibleNormalizedRect(
                forSelection: selection,
                aspect: aspect,
                bounds: bounds
            ) else { return }
            zoom = PiPSessionState.minZoom
            anchor = CGPoint(x: 0.5, y: 0.5)
            pendingZoom = nil
            pendingPan = .zero
            onRequestSelection?(normalized)
            return
        }

        let wasTracking = dragStartMouseInScreen != nil
        let dragged = didDrag
        resetDragTracking()

        guard wasTracking else {
            super.mouseUp(with: event)
            return
        }
        if dragged {
            onDidDragWindow?()
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard event.clickCount == 1, flags.isDisjoint(with: Self.activateBlockingFlags) else { return }
        onRequestActivateSource?()
    }

    private func resetDragTracking() {
        didDrag = false
        dragStartMouseInScreen = nil
        dragStartWindowOrigin = nil
    }

    private func cancelSelection() {
        isSelecting = false
        selectionStart = nil
        selectionLayer.path = nil
        selectionLayer.isHidden = true
    }

    private static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y))
    }


    override func scrollWheel(with event: NSEvent) {
        let content = Geo.contentRect(aspect: aspect, in: bounds)
        guard content.width > 1, content.height > 1 else { return }

        if event.modifierFlags.contains(.command) {
            zoomByScroll(event)
        } else {
            panByScroll(event, content: content)
        }
    }

    private func zoomByScroll(_ event: NSEvent) {
        let unit = event.hasPreciseScrollingDeltas ? Self.preciseZoomUnit : Self.coarseZoomUnit
        let step = event.scrollingDeltaY * unit
        guard abs(step) > 0.0001 else { return }

        let baseZoom = pendingZoom?.zoom ?? zoom
        let baseAnchor = pendingZoom?.anchor ?? anchor
        let target = Geo.clampZoom(baseZoom * (1 + step))
        guard abs(target - baseZoom) > 0.0001 else { return }

        let point = convert(event.locationInWindow, from: nil)
        var pointerSource = baseAnchor
        if let visible = Geo.viewPointToVisibleNorm(point, aspect: aspect, bounds: bounds) {
            pointerSource = Geo.visibleNormToSourceNorm(visible, zoom: baseZoom, anchor: baseAnchor)
        }
        let newAnchor = Geo.anchor(zoomingFrom: baseAnchor, oldZoom: baseZoom,
                                   to: target, pointerNorm: pointerSource)
        pendingZoom = (target, newAnchor)
        scheduleFlush()
    }

    private func panByScroll(_ event: NSEvent, content: CGRect) {
        guard (pendingZoom?.zoom ?? zoom) > PiPSessionState.minZoom + 0.0001 else { return }

        let delta = CGSize(width: -event.scrollingDeltaX / content.width,
                           height: -event.scrollingDeltaY / content.height)
        guard abs(delta.width) > 0 || abs(delta.height) > 0 else { return }
        pendingPan.width += delta.width
        pendingPan.height += delta.height
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) { [weak self] in
            self?.flushPendingGestures()
        }
    }

    private func flushPendingGestures() {
        flushScheduled = false

        if let target = pendingZoom {
            pendingZoom = nil
            zoom = target.zoom
            anchor = target.anchor
            onRequestZoom?(target.zoom, target.anchor)
        }

        let pan = pendingPan
        pendingPan = .zero
        if abs(pan.width) > 1e-6 || abs(pan.height) > 1e-6 {
            anchor = Geo.anchor(anchor, pannedBy: pan, zoom: zoom)
            onRequestPan?(pan)
        }
    }


    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers?.lowercased() ?? "" {
        case "=", "+":
            stepZoom(Self.keyboardZoomFactor)
        case "-", "_":
            stepZoom(1 / Self.keyboardZoomFactor)
        case "f":
            onRequestCycleFPS?()
        case "d":
            onRequestToggleIdleDetection?()
        case " ":
            onRequestTogglePause?()
        case "\u{1B}":      // esc
            onRequestClose?()
        case "\u{7F}", "\u{8}", "\u{F728}":  // delete / backspace / forward delete
            onRequestClose?()
        default:
            super.keyDown(with: event)
        }
    }

    private func stepZoom(_ factor: CGFloat) {
        let baseZoom = pendingZoom?.zoom ?? zoom
        let baseAnchor = pendingZoom?.anchor ?? anchor
        let target = Geo.clampZoom(baseZoom * factor)
        guard abs(target - baseZoom) > 0.0001 else { return }
        pendingZoom = (target, Geo.clampAnchor(baseAnchor, zoom: target))
        scheduleFlush()
    }


    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = mouseTracking { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        mouseTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isMouseInside = true
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        isMouseInside = false
        NSCursor.arrow.set()
        super.mouseExited(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            NSCursor.crosshair.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        if isMouseInside && !isSelecting {
            if event.modifierFlags.contains(.command) {
                NSCursor.crosshair.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        super.flagsChanged(with: event)
    }
}
