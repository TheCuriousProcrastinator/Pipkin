import AVFoundation
import AppKit
import CoreMedia


///
private final class PiPPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}


private final class PiPRootView: NSView {
    static let cornerRadius: CGFloat = 10

    private let highlightLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor

        highlightLayer.borderWidth = 3
        highlightLayer.borderColor = NSColor(calibratedRed: 0.29, green: 0.63, blue: 1, alpha: 1).cgColor
        highlightLayer.cornerRadius = Self.cornerRadius
        highlightLayer.opacity = 0
        highlightLayer.zPosition = 1000
        layer?.addSublayer(highlightLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("PiPRootView  xib/storyboard")
    }

    override func layout() {
        super.layout()
        highlightLayer.frame = bounds
        if highlightLayer.superlayer == nil { layer?.addSublayer(highlightLayer) }
    }

    func flash() {
        highlightLayer.removeAnimation(forKey: "flash")
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 0.0
        anim.toValue = 1.0
        anim.duration = 0.16
        anim.autoreverses = true
        anim.repeatCount = 2
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        highlightLayer.add(anim, forKey: "flash")
    }
}


///
///
private final class HintLabel: NSView {
    private static let cornerRadius: CGFloat = 6
    private static let hInset: CGFloat = 8
    private static let vInset: CGFloat = 5
    private static let measureSlack: CGFloat = 1
    private static let font = NSFont.systemFont(ofSize: 11)
    private static let ellipsis = "…"
    private static let background = NSColor.black.withAlphaComponent(0.82)

    private static let textAttributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("HintLabel  xib/storyboard")
    }

    var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            needsDisplay = true
        }
    }

    static func preferredSize(for text: String, maxWidth: CGFloat) -> CGSize {
        let measured = (text as NSString).size(withAttributes: textAttributes)
        let width = min(ceil(measured.width) + measureSlack + hInset * 2, max(0, maxWidth))
        return CGSize(width: ceil(max(0, width)), height: ceil(measured.height) + vInset * 2)
    }

    static func fitted(_ text: String, maxTextWidth: CGFloat) -> String {
        guard maxTextWidth > 0 else { return "" }
        guard width(of: text) > maxTextWidth else { return text }

        var chars = Array(text)
        while !chars.isEmpty {
            chars.removeLast()
            guard !chars.isEmpty else { break }
            let candidate = String(chars) + ellipsis
            if width(of: candidate) <= maxTextWidth { return candidate }
        }
        return ""
    }

    private static func width(of text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: textAttributes).width)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 1, bounds.height > 1 else { return }

        Self.background.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius).fill()

        let display = Self.fitted(text, maxTextWidth: bounds.width - Self.hInset * 2)
        guard !display.isEmpty else { return }
        let size = (display as NSString).size(withAttributes: Self.textAttributes)
        let origin = CGPoint(x: (bounds.minX + Self.hInset).rounded(),
                             y: (bounds.minY + (bounds.height - size.height) / 2).rounded())
        (display as NSString).draw(at: origin, withAttributes: Self.textAttributes)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}


///
final class PiPWindowController: NSObject, NSWindowDelegate, NSMenuDelegate {


    static let minWidth: CGFloat = 160
    static let edgeInset: CGFloat = 24
    private static let resizeDebounceInterval: TimeInterval = 0.25
    private static let alphaAnimationDuration: TimeInterval = 0.12
    private static let hintGap: CGFloat = 6
    private static let hintEdgeInset: CGFloat = 6
    private static let hintFadeInDuration: TimeInterval = 0.08
    private static let hintFadeOutDuration: TimeInterval = 0.12
    private static let hintMinWindowAlpha: CGFloat = 0.99
    private static let barHotZoneInset: CGFloat = 4
    private static let resizeHotZoneThickness: CGFloat = 10


    weak var delegate: PiPWindowDelegate?

    var window: NSPanel { panel }

    private(set) var runtimeState: SessionRuntimeState = .streaming

    var contentPointSize: CGSize { panel.contentRect(forFrameRect: panel.frame).size }

    var backingScale: CGFloat { panel.screen?.backingScaleFactor ?? panel.backingScaleFactor }

    var frameOrigin: CGPoint { panel.frame.origin }

    var autoHideResizeHotZoneThickness: CGFloat { Self.resizeHotZoneThickness }

    var isHoveringMouse: Bool {
        guard panel.isVisible else { return false }
        return panel.frame.contains(NSEvent.mouseLocation)
    }

    ///
    var barScreenFrame: CGRect? {
        guard panel.isVisible else { return nil }
        let bar = Self.overlayFrame(in: root.bounds)
        guard bar.width > 1, bar.height > 1 else { return nil }
        let inScreen = panel.convertToScreen(root.convert(bar, to: nil))
        return inScreen.insetBy(dx: 0, dy: -Self.barHotZoneInset)
    }


    private let panel: PiPPanel
    private let root = PiPRootView(frame: .zero)
    private let contentView = PiPContentView(frame: .zero)
    private let placeholder = PlaceholderView(frame: .zero)
    private let overlay = OverlayControlsView(frame: .zero)
    private let hint = HintLabel(frame: .zero)
    private let hintWindow = NSPanel(
        contentRect: CGRect(x: 0, y: 0, width: 10, height: 10),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )

    private(set) var aspect: CGSize
    private var titleText: String
    private var levelMode: WindowLevelMode
    private var lastState: PiPSessionState?

    private var resizeDebounce: DispatchWorkItem?
    private var lastReportedScale: CGFloat = 0
    private var screenObserver: NSObjectProtocol?

    private var hintText: String?
    private var hintAnchor: CGRect?
    private var hintDismissWork: DispatchWorkItem?
    private var alphaTarget: CGFloat = 1

    private let contextMenu = NSMenu()
    private let titleItem = NSMenuItem()
    private let pauseItem = NSMenuItem()
    private let zoomResetItem = NSMenuItem()
    private let autoHideItem = NSMenuItem()
    private let idleItem = NSMenuItem()
    private let clickActivateItem = NSMenuItem()
    private var fpsItems: [FPSStep: NSMenuItem] = [:]
    private var levelItems: [WindowLevelMode: NSMenuItem] = [:]
    private var opacityItems: [NSMenuItem] = []


    /// - Parameters:
    init(title: String, aspect: CGSize, initialWidth: CGFloat, origin: CGPoint?,
         levelMode: WindowLevelMode, cascadeIndex: Int = 0) {
        let safeAspect = Self.sanitized(aspect)
        self.aspect = safeAspect
        self.titleText = title
        self.levelMode = levelMode

        let frame = Self.initialFrame(aspect: safeAspect, width: initialWidth,
                                      origin: origin, cascadeIndex: cascadeIndex)
        panel = PiPPanel(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .borderless, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        super.init()

        configurePanel()
        buildViewHierarchy()
        configureHintWindow()
        buildMenu()
        setTitle(title)
        lastReportedScale = backingScale
        observeScreenParameters()
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        resizeDebounce?.cancel()
        hintDismissWork?.cancel()
    }

    static func cascadeOffset(index: Int) -> CGSize {
        let i = CGFloat(max(0, index))
        return CGSize(width: -32 * i, height: 32 * i)
    }

    private static func sanitized(_ aspect: CGSize) -> CGSize {
        guard aspect.width > 0, aspect.height > 0 else { return CGSize(width: 16, height: 9) }
        return aspect
    }

    private static func minSize(for aspect: CGSize) -> CGSize {
        CGSize(width: minWidth, height: max(90, (minWidth * aspect.height / aspect.width).rounded()))
    }

    private static func initialFrame(aspect: CGSize, width: CGFloat,
                                     origin: CGPoint?, cascadeIndex: Int) -> CGRect {
        let w = max(minWidth, width.rounded())
        let h = max(90, (w * aspect.height / aspect.width).rounded())
        let size = CGSize(width: w, height: h)

        if let origin {
            return Geo.constrainToVisibleScreens(CGRect(origin: origin, size: size))
        }
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let offset = cascadeOffset(index: cascadeIndex)
        let rect = CGRect(x: visible.maxX - edgeInset - size.width + offset.width,
                          y: visible.minY + edgeInset + offset.height,
                          width: size.width, height: size.height)
        return Geo.constrainToVisibleScreens(rect)
    }


    private func configurePanel() {
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.tabbingMode = .disallowed
        panel.acceptsMouseMovedEvents = true
        panel.aspectRatio = aspect
        panel.minSize = Self.minSize(for: aspect)
        panel.level = levelMode.windowLevel
        panel.collectionBehavior = levelMode.collectionBehavior
        panel.delegate = self
    }

    private func buildViewHierarchy() {
        panel.contentView = root

        contentView.frame = root.bounds
        contentView.autoresizingMask = [.width, .height]
        root.addSubview(contentView)

        placeholder.frame = root.bounds
        placeholder.autoresizingMask = [.width, .height]
        root.addSubview(placeholder)

        overlay.frame = Self.overlayFrame(in: root.bounds)
        root.addSubview(overlay)

        placeholder.setVisible(false, animated: false)
        overlay.setVisible(false, animated: false)

        placeholder.onOpenSettings = { Permissions.openScreenRecordingSettings() }

        contentView.onRequestZoom = { [weak self] zoom, anchor in
            self?.delegate?.pipRequestZoom(zoom, anchor: anchor)
        }
        contentView.onRequestSelection = { [weak self] normalizedRect in
            self?.delegate?.pipRequestSelection(normalizedRect)
        }
        contentView.onRequestPan = { [weak self] delta in
            self?.delegate?.pipRequestPan(by: delta)
        }
        contentView.onRequestZoomReset = { [weak self] in self?.delegate?.pipRequestZoomReset() }
        contentView.onRequestClose = { [weak self] in self?.delegate?.pipRequestClose() }
        contentView.onRequestCycleFPS = { [weak self] in self?.cycleFPS() }
        contentView.onRequestToggleIdleDetection = { [weak self] in
            self?.delegate?.pipRequestToggleIdleDetection()
        }
        contentView.onRequestTogglePause = { [weak self] in self?.delegate?.pipRequestTogglePause() }
        contentView.onRendererRecoveryExhausted = { [weak self] in
            self?.delegate?.pipRendererRecoveryExhausted()
        }
        contentView.onRendererIncidentRecovered = { [weak self] id in
            self?.delegate?.pipRendererDidRecover()
            self?.showHint(
                ("Picture recovered automatically (log ID \(id))"),
                near: nil,
                duration: 4.0
            )
        }
        contentView.onRequestActivateSource = { [weak self] in
            self?.delegate?.pipRequestActivateSource()
        }
        contentView.onResolveDraggedWindowFrame = { [weak self] proposed, flags in
            self?.delegate?.pipResolveDragFrame(proposed, modifierFlags: flags) ?? proposed
        }
        contentView.onDidDragWindow = { [weak self] in
            guard let self else { return }
            self.delegate?.pipDidMove()
            self.notifyIfScaleChanged()
        }

        overlay.onClose = { [weak self] in self?.delegate?.pipRequestClose() }
        overlay.onCycleFPS = { [weak self] in self?.cycleFPS() }
        overlay.onResetZoom = { [weak self] in self?.delegate?.pipRequestZoomReset() }
        overlay.onToggleAutoHide = { [weak self] in self?.delegate?.pipRequestToggleAutoHide() }
        overlay.onToggleIdleDetection = { [weak self] in self?.delegate?.pipRequestToggleIdleDetection() }
        overlay.onTogglePause = { [weak self] in self?.delegate?.pipRequestTogglePause() }

        overlay.onHintChange = { [weak self] payload in
            guard let self else { return }
            guard let payload else {
                self.showHint(nil, near: nil)
                return
            }
            self.showHint(payload.0, near: payload.1)
        }

        contentView.update(aspect: aspect)
    }

    private static func overlayFrame(in bounds: CGRect) -> CGRect {
        let inset: CGFloat = 6
        let height = OverlayControlsView.preferredHeight
        return CGRect(x: bounds.minX + inset,
                      y: max(bounds.minY, bounds.maxY - inset - height),
                      width: max(0, bounds.width - inset * 2),
                      height: min(height, bounds.height))
    }


    private func configureHintWindow() {
        hintWindow.isFloatingPanel = true
        hintWindow.becomesKeyOnlyIfNeeded = true
        hintWindow.hidesOnDeactivate = false
        hintWindow.backgroundColor = .clear
        hintWindow.isOpaque = false
        hintWindow.hasShadow = false
        hintWindow.ignoresMouseEvents = true
        hintWindow.sharingType = .none
        hintWindow.isReleasedWhenClosed = false
        hintWindow.animationBehavior = .none
        hintWindow.tabbingMode = .disallowed
        hintWindow.level = panel.level
        hintWindow.collectionBehavior = panel.collectionBehavior
        hintWindow.alphaValue = 0
        hintWindow.contentView = hint

        panel.addChildWindow(hintWindow, ordered: .above)
        hintWindow.orderOut(nil)
    }

    private func observeScreenParameters() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleScreenParametersChange()
        }
    }


    func show() {
        panel.orderFrontRegardless()
        if hintText == nil { hintWindow.orderOut(nil) }
        _ = panel.makeFirstResponder(contentView)
        refreshMenu()
    }

    func close() {
        resizeDebounce?.cancel()
        resizeDebounce = nil
        hintDismissWork?.cancel()
        hintDismissWork = nil
        hideHint(animated: false)
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        contentView.flushAndReset()
        panel.delegate = nil
        panel.removeChildWindow(hintWindow)
        hintWindow.orderOut(nil)
        panel.orderOut(nil)
        panel.close()
        hintWindow.close()
    }


    ///
    /// - Parameters:
    func showHint(_ text: String?, near anchorInScreen: CGRect?, duration: TimeInterval? = nil) {
        hintDismissWork?.cancel()
        hintDismissWork = nil

        guard let text, !text.isEmpty else {
            hideHint(animated: true)
            return
        }
        guard panel.isVisible, alphaTarget > Self.hintMinWindowAlpha else {
            hideHint(animated: false)
            return
        }

        let wasFullyVisible = hintWindow.isVisible && hintWindow.alphaValue > 0.999
        hintText = text
        hintAnchor = anchorInScreen
        hint.text = text
        layoutHint()
        if !hintWindow.isVisible {
            hintWindow.alphaValue = 0
            hintWindow.orderFrontRegardless()
        }
        if !wasFullyVisible { fadeHint(to: 1, duration: Self.hintFadeInDuration) }

        guard let duration, duration > 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.hintDismissWork = nil
            self?.hideHint(animated: true)
        }
        hintDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func hideHint(animated: Bool) {
        hintDismissWork?.cancel()
        hintDismissWork = nil
        hintText = nil
        hintAnchor = nil

        guard animated, hintWindow.isVisible, hintWindow.alphaValue > 0 else {
            hintWindow.alphaValue = 0
            hintWindow.orderOut(nil)
            return
        }
        fadeHint(to: 0, duration: Self.hintFadeOutDuration) { [weak self] in
            guard let self, self.hintText == nil else { return }
            self.hintWindow.orderOut(nil)
        }
    }

    private func fadeHint(to alpha: CGFloat, duration: TimeInterval,
                          completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.hintWindow.animator().alphaValue = alpha
        }, completionHandler: completion)
    }

    private func layoutHint() {
        guard let text = hintText, !text.isEmpty else { return }
        let anchor = hintAnchor ?? defaultHintAnchor()
        let available = hintAvailableRect(for: anchor)
        guard available.width > 1, available.height > 1 else { return }

        let size = HintLabel.preferredSize(for: text, maxWidth: available.width)
        guard size.width > 1, size.height > 1 else { return }
        hintWindow.setFrame(Self.hintFrame(size: size, anchor: anchor, available: available),
                            display: true)
        hint.needsDisplay = true
    }

    private func defaultHintAnchor() -> CGRect {
        let bar = Self.overlayFrame(in: root.bounds)
        return panel.convertToScreen(root.convert(bar, to: nil))
    }

    private func hintAvailableRect(for anchor: CGRect) -> CGRect {
        let center = CGPoint(x: anchor.midX, y: anchor.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(center) })
            ?? panel.screen
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return anchor.insetBy(dx: -240, dy: -60) }
        return visible.insetBy(dx: Self.hintEdgeInset, dy: Self.hintEdgeInset)
    }

    private static func hintFrame(size: CGSize, anchor: CGRect, available: CGRect) -> CGRect {
        var x = anchor.midX - size.width / 2
        x = min(max(x, available.minX), max(available.minX, available.maxX - size.width))

        let above = anchor.maxY + hintGap
        let below = anchor.minY - hintGap - size.height
        var y: CGFloat
        if above + size.height <= available.maxY {
            y = above
        } else if below >= available.minY {
            y = below
        } else {
            y = above
        }
        y = min(max(y, available.minY), max(available.minY, available.maxY - size.height))

        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }


    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard panel.isVisible else { return }
        contentView.enqueue(sampleBuffer)
    }

    func prepareForCaptureDiscontinuity(_ reason: String) {
        contentView.prepareForCaptureDiscontinuity(reason)
    }

    func recordRendererEvent(_ event: String) {
        contentView.recordDiagnosticEvent(event)
    }

    var debugEnqueuedFrameCount: UInt64 { contentView.debugEnqueuedFrameCount }
    var debugNotReadyDropCount: UInt64 { contentView.debugNotReadyDropCount }

    var debugWindowLevel: Int { panel.level.rawValue }
    var debugHintWindowLevel: Int { hintWindow.level.rawValue }


    func update(state: PiPSessionState) {
        lastState = state
        contentView.update(state: state, aspect: aspect)
        overlay.update(state: state)
        if runtimeState != .streaming {
            placeholder.update(runtimeState: runtimeState, source: state.source)
        }
        refreshMenu()
    }

    func update(runtimeState newState: SessionRuntimeState) {
        let changed = newState != runtimeState
        runtimeState = newState
        if let source = currentState?.source {
            placeholder.update(runtimeState: newState, source: source)
        } else {
            placeholder.setVisible(newState != .streaming, animated: changed)
        }
        switch newState {
        case .sourceLost, .permissionDenied, .failed:
            contentView.flushAndReset()
        case .streaming, .paused, .sourceOffscreen, .minimized, .waitingForSource, .reconnecting:
            break
        }
        refreshMenu()
    }

    func setTitle(_ title: String) {
        titleText = title
        panel.title = title
        contentView.setDiagnosticLabel(title)
        overlay.titleText = title
        titleItem.title = title
    }

    func setAspect(_ newAspect: CGSize) {
        let safe = Self.sanitized(newAspect)
        guard abs(safe.width / safe.height - aspect.width / aspect.height) > 0.0001 else { return }
        aspect = safe
        panel.aspectRatio = safe
        panel.minSize = Self.minSize(for: safe)
        contentView.update(aspect: safe)

        var frame = panel.frame
        let newHeight = max(Self.minSize(for: safe).height, (frame.width * safe.height / safe.width).rounded())
        guard abs(newHeight - frame.height) > 0.5 else { return }
        frame.origin.y = frame.maxY - newHeight
        frame.size.height = newHeight
        panel.setFrame(Geo.constrainToVisibleScreens(frame), display: true)
        scheduleResizeNotify()
    }

    func setLevelMode(_ mode: WindowLevelMode) {
        levelMode = mode
        panel.level = mode.windowLevel
        panel.collectionBehavior = mode.collectionBehavior
        hintWindow.level = mode.windowLevel
        hintWindow.collectionBehavior = mode.collectionBehavior
        refreshMenu()
    }

    func setClickThrough(_ enabled: Bool) {
        panel.ignoresMouseEvents = enabled
    }

    func setAlpha(_ alpha: CGFloat, animated: Bool) {
        let target = min(max(alpha, 0), 1)
        alphaTarget = target
        if target <= Self.hintMinWindowAlpha { hideHint(animated: false) }
        guard animated else {
            panel.alphaValue = target
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.alphaAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.panel.animator().alphaValue = target
        }
    }

    func setControlsVisible(_ visible: Bool, animated: Bool = true) {
        overlay.setVisible(visible, animated: animated)
    }


    func hideCompletely() {
        resizeDebounce?.cancel()
        resizeDebounce = nil
        hideHint(animated: false)
        contentView.flushAndReset()
        panel.orderOut(nil)
    }

    func restoreFromHidden() {
        panel.alphaValue = 1
        alphaTarget = 1
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        if hintText == nil { hintWindow.orderOut(nil) }
        _ = panel.makeFirstResponder(contentView)
    }

    func bringToFront() {
        panel.orderFrontRegardless()
    }

    func flashHighlight() {
        bringToFront()
        root.flash()
    }

    // MARK: - NSWindowDelegate

    func windowWillStartLiveResize(_ notification: Notification) {
        delegate?.pipWillStartLiveResize()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        delegate?.pipDidEndLiveResize()
        scheduleResizeNotify()
    }

    func windowDidResize(_ notification: Notification) {
        layoutHint()
        scheduleResizeNotify()
    }

    func windowDidMove(_ notification: Notification) {
        delegate?.pipDidMove()
        notifyIfScaleChanged()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        notifyIfScaleChanged()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        notifyIfScaleChanged()
    }


    private func scheduleResizeNotify() {
        resizeDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.notifyResize() }
        resizeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resizeDebounceInterval, execute: work)
    }

    private func notifyResize() {
        resizeDebounce = nil
        lastReportedScale = backingScale
        delegate?.pipDidResize(pointSize: contentPointSize, scale: lastReportedScale)
    }

    private func notifyIfScaleChanged() {
        let scale = backingScale
        guard abs(scale - lastReportedScale) > 0.01 else { return }
        Log.debug("scale \(lastReportedScale) → \(scale)")
        resizeDebounce?.cancel()
        resizeDebounce = nil
        notifyResize()
    }

    private func handleScreenParametersChange() {
        let corrected = Geo.constrainToVisibleScreens(panel.frame)
        if corrected != panel.frame {
            panel.setFrame(corrected, display: true)
            delegate?.pipDidMove()
        }
        notifyIfScaleChanged()
    }


    private var currentState: PiPSessionState? { delegate?.currentSessionState ?? lastState }

    private func buildMenu() {
        contextMenu.autoenablesItems = false
        contextMenu.delegate = self

        titleItem.title = titleText
        titleItem.isEnabled = false
        contextMenu.addItem(titleItem)
        contextMenu.addItem(.separator())

        pauseItem.title = ("Pause")
        pauseItem.target = self
        pauseItem.action = #selector(menuTogglePause)
        contextMenu.addItem(pauseItem)

        zoomResetItem.title = ("Reset Zoom")
        zoomResetItem.target = self
        zoomResetItem.action = #selector(menuResetZoom)
        contextMenu.addItem(zoomResetItem)

        let fpsItem = NSMenuItem(title: ("Frame Rate"), action: nil, keyEquivalent: "")
        let fpsMenu = NSMenu()
        fpsMenu.autoenablesItems = false
        for step in FPSStep.allCases {
            let item = NSMenuItem(title: step.label, action: #selector(menuPickFPS(_:)), keyEquivalent: "")
            item.target = self
            item.tag = step.rawValue
            fpsMenu.addItem(item)
            fpsItems[step] = item
        }
        fpsItem.submenu = fpsMenu
        contextMenu.addItem(fpsItem)

        contextMenu.addItem(.separator())

        autoHideItem.title = ("Auto-hide (click-through on hover)")
        autoHideItem.target = self
        autoHideItem.action = #selector(menuToggleAutoHide)
        contextMenu.addItem(autoHideItem)

        let opacityItem = NSMenuItem(title: ("Auto-hide opacity (global)"),
                                     action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu()
        opacityMenu.autoenablesItems = false
        for (index, step) in Preferences.autoHideOpacitySteps.enumerated() {
            let item = NSMenuItem(title: Preferences.opacityLabel(step),
                                  action: #selector(menuPickAutoHideOpacity(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            opacityMenu.addItem(item)
            opacityItems.append(item)
        }
        opacityMenu.addItem(.separator())
        let peekNote = NSMenuItem(title: ("Hold ⌥ to peek while faded"),
                                  action: nil, keyEquivalent: "")
        peekNote.isEnabled = false
        opacityMenu.addItem(peekNote)
        opacityItem.submenu = opacityMenu
        contextMenu.addItem(opacityItem)

        idleItem.title = ("Idle detection (drop FPS when static)")
        idleItem.target = self
        idleItem.action = #selector(menuToggleIdleDetection)
        contextMenu.addItem(idleItem)

        clickActivateItem.title = ("Click to switch to source window")
        clickActivateItem.target = self
        clickActivateItem.action = #selector(menuToggleClickToActivate)
        contextMenu.addItem(clickActivateItem)

        let levelItem = NSMenuItem(title: ("Window Level"), action: nil, keyEquivalent: "")
        let levelMenu = NSMenu()
        levelMenu.autoenablesItems = false
        for mode in WindowLevelMode.allCases {
            let item = NSMenuItem(title: mode.label, action: #selector(menuPickLevel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            levelMenu.addItem(item)
            levelItems[mode] = item
        }
        levelItem.submenu = levelMenu
        contextMenu.addItem(levelItem)

        contextMenu.addItem(.separator())

        let closeItem = NSMenuItem(title: ("Close This PiP"),
                                   action: #selector(menuClose), keyEquivalent: "")
        closeItem.target = self
        contextMenu.addItem(closeItem)

        root.menu = contextMenu
        contentView.menu = contextMenu
        placeholder.menu = contextMenu
        overlay.menu = contextMenu
    }

    private func refreshMenu() {
        let state = currentState
        titleItem.title = state?.source.displayTitle ?? titleText

        let paused = state?.isPaused ?? false
        pauseItem.title = paused ? ("Resume") : ("Pause")

        let zoom = state?.zoom ?? 1
        let cropped = state?.hasSelectionCrop ?? false
        if zoom > 1.01 {
            zoomResetItem.title = ("Reset Zoom (now \(String(format: "%.1f", zoom))×)")
        } else if cropped {
            zoomResetItem.title = ("Restore Full Frame & Aspect Ratio")
        } else {
            zoomResetItem.title = ("Reset Zoom")
        }
        zoomResetItem.isEnabled = zoom > 1.01 || cropped

        autoHideItem.state = (state?.autoHide ?? false) ? .on : .off
        idleItem.state = (state?.idleDetection ?? true) ? .on : .off
        clickActivateItem.state = Preferences.shared.clickToActivateSource ? .on : .off

        let opacity = Preferences.nearestOpacityStep(Preferences.shared.autoHideOpacity)
        for (index, item) in opacityItems.enumerated() {
            let step = Preferences.autoHideOpacitySteps[index]
            item.state = abs(step - opacity) < 0.001 ? .on : .off
        }

        let fps = state?.fps ?? Preferences.shared.defaultFPS
        for (step, item) in fpsItems { item.state = (step == fps) ? .on : .off }
        for (mode, item) in levelItems { item.state = (mode == levelMode) ? .on : .off }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === contextMenu else { return }
        delegate?.pipMenuWillOpen()
        refreshMenu()
    }


    @objc private func menuClose() {
        delegate?.pipRequestClose()
    }

    @objc private func menuTogglePause() {
        delegate?.pipRequestTogglePause()
    }

    @objc private func menuResetZoom() {
        delegate?.pipRequestZoomReset()
    }

    @objc private func menuPickFPS(_ sender: NSMenuItem) {
        guard let step = FPSStep(rawValue: sender.tag) else { return }
        delegate?.pipRequestFPS(step)
    }

    @objc private func menuToggleAutoHide() {
        delegate?.pipRequestToggleAutoHide()
    }

    @objc private func menuPickAutoHideOpacity(_ sender: NSMenuItem) {
        guard Preferences.autoHideOpacitySteps.indices.contains(sender.tag) else { return }
        delegate?.pipRequestAutoHideOpacity(Preferences.autoHideOpacitySteps[sender.tag])
    }

    @objc private func menuToggleIdleDetection() {
        delegate?.pipRequestToggleIdleDetection()
    }

    @objc private func menuToggleClickToActivate() {
        delegate?.pipRequestToggleClickToActivate()
    }

    @objc private func menuPickLevel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = WindowLevelMode(rawValue: raw) else { return }
        setLevelMode(mode)
        Preferences.shared.windowLevelMode = mode
    }

    private func cycleFPS() {
        let current = currentState?.fps ?? Preferences.shared.defaultFPS
        delegate?.pipRequestFPS(current.next())
    }
}
