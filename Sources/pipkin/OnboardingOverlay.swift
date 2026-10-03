import AppKit

private enum OnboardingMetrics {
    static let maskAlpha: CGFloat = 0.38

    static let holePadding: CGFloat = 6
    static let holeCornerRadius: CGFloat = 6
    static let holeStrokeWidth: CGFloat = 2
    static let holeHitSlop: CGFloat = 4

    static let breathPeriod: CFTimeInterval = 1.5
    static let breathMinAlpha: CGFloat = 0.45
    static let breathMaxAlpha: CGFloat = 1.0
    static let breathTick: TimeInterval = 1.0 / 30

    static let cardWidth: CGFloat = 380
    static let cardCornerRadius: CGFloat = 12
    static let cardGap: CGFloat = 90
    static let screenInset: CGFloat = 24

    static let arrowLineWidth: CGFloat = 2.5
    static let arrowHeadLength: CGFloat = 11
    static let arrowHeadHalfWidth: CGFloat = 5.5
    static let arrowGap: CGFloat = 6
    static let arrowEdgeInset: CGFloat = 24

    static let fallbackTopGap: CGFloat = 56
    static let fallbackTipInset: CGFloat = 34
}

///
///
///
final class OnboardingOverlay {


    private static var current: OnboardingOverlay?

    static var isVisible: Bool { current != nil }

    /// - Parameters:
    static func show(anchor: CGRect?,
                     onOpenMenu: @escaping () -> Void,
                     onDismiss: @escaping () -> Void) {
        dismiss()

        let overlay = OnboardingOverlay(anchor: anchor, onOpenMenu: onOpenMenu, onDismiss: onDismiss)
        guard overlay.present() else {
            onDismiss()
            return
        }
        current = overlay
    }

    static func dismiss() { current?.close() }


    private let anchor: CGRect?
    private var onOpenMenu: (() -> Void)?
    private var onDismiss: (() -> Void)?

    private var windows: [OnboardingOverlayWindow] = []
    private var maskViews: [OnboardingMaskView] = []

    private var breathTimer: Timer?
    private var breathStart: CFTimeInterval = 0
    private var screenObserver: NSObjectProtocol?

    private var isFinished = false

    private init(anchor: CGRect?,
                 onOpenMenu: @escaping () -> Void,
                 onDismiss: @escaping () -> Void) {
        self.anchor = Self.sanitize(anchor)
        self.onOpenMenu = onOpenMenu
        self.onDismiss = onDismiss
    }


    private func present() -> Bool {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            Log.warn("")
            return false
        }

        let anchorScreen = anchor.flatMap { Self.screen(containing: $0) } ?? NSScreen.main ?? screens[0]
        var keyWindow: OnboardingOverlayWindow?

        for screen in screens {
            let mask = OnboardingMaskView(frame: CGRect(origin: .zero, size: screen.frame.size))
            mask.onDismiss = { [weak self] in self?.close() }

            if screen === anchorScreen {
                mask.onOpenMenu = { [weak self] in self?.openMenuThenClose() }
                configureGuidance(on: mask, screen: screen)
            }

            let window = OnboardingOverlayWindow(screen: screen, content: mask)
            window.orderFrontRegardless()
            windows.append(window)
            maskViews.append(mask)
            if screen === anchorScreen { keyWindow = window }
        }

        NSApp.activate(ignoringOtherApps: true)
        if let keyWindow {
            keyWindow.makeKey()
            if let content = keyWindow.contentView {
                keyWindow.makeFirstResponder(content)
            }
        }

        startBreathing()
        observeScreenChanges()
        Log.info(" \(windows.count)anchor=\(anchor.map { "\($0)" } ?? "nil")")
        return true
    }

    private func configureGuidance(on mask: OnboardingMaskView, screen: NSScreen) {
        let card = OnboardingCardView(width: OnboardingMetrics.cardWidth)
        card.onPrimary = { [weak self] in self?.openMenuThenClose() }
        card.onSecondary = { [weak self] in self?.close() }

        let shift = screen.frame.origin
        let limit = screen.visibleFrame.insetBy(dx: OnboardingMetrics.screenInset,
                                                dy: OnboardingMetrics.screenInset)
        let cardSize = card.frame.size

        var cardRect: CGRect
        var tip: CGPoint
        var hole: CGRect?

        if let anchor {
            let punched = anchor.insetBy(dx: -OnboardingMetrics.holePadding,
                                        dy: -OnboardingMetrics.holePadding)
                .intersection(screen.frame)
            if !punched.isNull, punched.width > 2, punched.height > 2 {
                hole = punched
            }

            let holeRect = hole ?? anchor
            cardRect = CGRect(x: holeRect.midX - cardSize.width / 2,
                              y: holeRect.minY - OnboardingMetrics.cardGap - cardSize.height,
                              width: cardSize.width, height: cardSize.height)
            cardRect = Self.clamp(cardRect, in: limit)
            tip = CGPoint(x: holeRect.midX, y: holeRect.minY - OnboardingMetrics.arrowGap)
        } else {
            cardRect = CGRect(x: limit.midX - cardSize.width / 2,
                              y: screen.visibleFrame.maxY - OnboardingMetrics.fallbackTopGap - cardSize.height,
                              width: cardSize.width, height: cardSize.height)
            cardRect = Self.clamp(cardRect, in: limit)
            tip = CGPoint(x: screen.frame.maxX - OnboardingMetrics.fallbackTipInset,
                          y: screen.frame.maxY - 12)
        }

        let startX: CGFloat
        if anchor != nil {
            startX = min(max(tip.x, cardRect.minX + OnboardingMetrics.arrowEdgeInset),
                         cardRect.maxX - OnboardingMetrics.arrowEdgeInset)
        } else {
            startX = cardRect.maxX - OnboardingMetrics.arrowEdgeInset
        }
        let start = CGPoint(x: startX, y: cardRect.maxY + OnboardingMetrics.arrowGap)

        card.setFrameOrigin(CGPoint(x: cardRect.minX - shift.x, y: cardRect.minY - shift.y))
        mask.addSubview(card)
        mask.cardFrame = card.frame
        mask.holeRect = hole.map { CGRect(x: $0.minX - shift.x, y: $0.minY - shift.y,
                                          width: $0.width, height: $0.height) }
        mask.arrowStart = CGPoint(x: start.x - shift.x, y: start.y - shift.y)
        mask.arrowTip = CGPoint(x: tip.x - shift.x, y: tip.y - shift.y)
    }


    private func startBreathing() {
        guard maskViews.contains(where: { $0.holeRect != nil }) else { return }
        breathStart = CACurrentMediaTime()
        let timer = Timer(timeInterval: OnboardingMetrics.breathTick, repeats: true) { [weak self] _ in
            self?.tickBreathing()
        }
        RunLoop.main.add(timer, forMode: .common)
        breathTimer = timer
    }

    private func tickBreathing() {
        let elapsed = CACurrentMediaTime() - breathStart
        let phase = elapsed.truncatingRemainder(dividingBy: OnboardingMetrics.breathPeriod)
            / OnboardingMetrics.breathPeriod
        let wave = CGFloat((1 - cos(2 * Double.pi * phase)) / 2)
        let alpha = OnboardingMetrics.breathMinAlpha
            + (OnboardingMetrics.breathMaxAlpha - OnboardingMetrics.breathMinAlpha) * wave
        for mask in maskViews { mask.updateStrokeAlpha(alpha) }
    }


    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Log.debug("")
            self?.close()
        }
    }


    private func openMenuThenClose() {
        let open = onOpenMenu
        onOpenMenu = nil
        close()
        guard let open else { return }
        DispatchQueue.main.async { open() }
    }

    private func close() {
        guard !isFinished else { return }
        isFinished = true

        breathTimer?.invalidate()
        breathTimer = nil

        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil

        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        maskViews.removeAll()

        if OnboardingOverlay.current === self { OnboardingOverlay.current = nil }

        let dismissed = onDismiss
        onDismiss = nil
        onOpenMenu = nil
        Log.info("")
        dismissed?()
    }


    private static func sanitize(_ anchor: CGRect?) -> CGRect? {
        guard let anchor, anchor.width > 1, anchor.height > 1,
              anchor.origin.x.isFinite, anchor.origin.y.isFinite else { return nil }
        guard NSScreen.screens.contains(where: { $0.frame.intersects(anchor) }) else {
            Log.warn(" \(anchor) ")
            return nil
        }
        return anchor
    }

    private static func screen(containing rect: CGRect) -> NSScreen? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let hit = NSScreen.screens.first(where: { $0.frame.contains(center) }) { return hit }
        return NSScreen.screens.max { overlap($0.frame, rect) < overlap($1.frame, rect) }
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height
    }

    private static func clamp(_ rect: CGRect, in limit: CGRect) -> CGRect {
        var r = rect
        if limit.width >= r.width {
            r.origin.x = min(max(r.minX, limit.minX), limit.maxX - r.width)
        } else {
            r.origin.x = limit.midX - r.width / 2
        }
        if limit.height >= r.height {
            r.origin.y = min(max(r.minY, limit.minY), limit.maxY - r.height)
        } else {
            r.origin.y = limit.midY - r.height / 2
        }
        return r
    }
}


private final class OnboardingOverlayWindow: NSWindow {
    init(screen: NSScreen, content: NSView) {
        super.init(contentRect: screen.frame, styleMask: [.borderless],
                   backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        sharingType = .none
        animationBehavior = .none
        isReleasedWhenClosed = false
        content.frame = CGRect(origin: .zero, size: screen.frame.size)
        contentView = content
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}


private final class OnboardingMaskView: NSView {

    var onOpenMenu: (() -> Void)?
    var onDismiss: (() -> Void)?

    var holeRect: CGRect? {
        didSet { needsDisplay = true }
    }
    var cardFrame: CGRect?
    var arrowStart: CGPoint?
    var arrowTip: CGPoint?

    private var strokeAlpha: CGFloat = OnboardingMetrics.breathMaxAlpha

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func updateStrokeAlpha(_ alpha: CGFloat) {
        guard let hole = holeRect, abs(alpha - strokeAlpha) > 0.005 else { return }
        strokeAlpha = alpha
        let slop = OnboardingMetrics.holeStrokeWidth + 2
        setNeedsDisplay(hole.insetBy(dx: -slop, dy: -slop))
    }

    override func resetCursorRects() {
        guard let hole = holeRect else { return }
        addCursorRect(hole, cursor: .pointingHand)
    }


    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(OnboardingMetrics.maskAlpha).setFill()
        bounds.fill()

        if let hole = holeRect { drawHole(hole) }
        drawArrow()
    }

    private func drawHole(_ hole: CGRect) {
        let radius = min(OnboardingMetrics.holeCornerRadius, min(hole.width, hole.height) / 2)
        let path = NSBezierPath(roundedRect: hole, xRadius: radius, yRadius: radius)

        if let ctx = NSGraphicsContext.current {
            ctx.saveGraphicsState()
            ctx.compositingOperation = .copy
            NSColor.clear.setFill()
            path.fill()
            ctx.restoreGraphicsState()
        }

        NSColor.white.withAlphaComponent(0.02).setFill()
        path.fill()

        let inset = OnboardingMetrics.holeStrokeWidth / 2
        let ring = NSBezierPath(roundedRect: hole.insetBy(dx: -inset, dy: -inset),
                                xRadius: radius + inset, yRadius: radius + inset)
        ring.lineWidth = OnboardingMetrics.holeStrokeWidth
        NSColor.controlAccentColor.withAlphaComponent(strokeAlpha).setStroke()
        ring.stroke()
    }

    private func drawArrow() {
        guard let start = arrowStart, let tip = arrowTip else { return }
        let dx = tip.x - start.x
        let dy = tip.y - start.y
        guard abs(dx) + abs(dy) > 16 else { return }

        let lateral = max(26, abs(dx) * 0.3) * (dx >= 0 ? 1 : -1)
        let cp1 = CGPoint(x: start.x + lateral, y: start.y + dy * 0.45)
        let cp2 = CGPoint(x: tip.x - lateral * 0.35, y: tip.y - dy * 0.5)

        let angle = atan2(tip.y - cp2.y, tip.x - cp2.x)
        let base = CGPoint(x: tip.x - cos(angle) * OnboardingMetrics.arrowHeadLength,
                           y: tip.y - sin(angle) * OnboardingMetrics.arrowHeadLength)

        let curve = NSBezierPath()
        curve.move(to: start)
        curve.curve(to: base, controlPoint1: cp1, controlPoint2: cp2)
        curve.lineWidth = OnboardingMetrics.arrowLineWidth
        curve.lineCapStyle = .round
        NSColor.controlAccentColor.setStroke()
        curve.stroke()

        let perp = angle + CGFloat.pi / 2
        let half = OnboardingMetrics.arrowHeadHalfWidth
        let head = NSBezierPath()
        head.move(to: tip)
        head.line(to: CGPoint(x: base.x + cos(perp) * half, y: base.y + sin(perp) * half))
        head.line(to: CGPoint(x: base.x - cos(perp) * half, y: base.y - sin(perp) * half))
        head.close()
        NSColor.controlAccentColor.setFill()
        head.fill()
    }


    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if let cardFrame, cardFrame.contains(point) { return }

        let slop = OnboardingMetrics.holeHitSlop
        if let hole = holeRect, hole.insetBy(dx: -slop, dy: -slop).contains(point),
           let onOpenMenu {
            onOpenMenu()
            return
        }
        onDismiss?()
    }

    override func rightMouseDown(with event: NSEvent) { onDismiss?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDismiss?() } else { super.keyDown(with: event) }
    }
}


private final class OnboardingCardView: NSView {

    private enum Pad {
        static let horizontal: CGFloat = 18
        static let top: CGFloat = 16
        static let bottom: CGFloat = 14
        static let titleToBody: CGFloat = 8
        static let bodyToShortcut: CGFloat = 10
        static let shortcutToButtons: CGFloat = 14
        static let buttonSpacing: CGFloat = 10
        static let minButtonWidth: CGFloat = 78
        static let minButtonHeight: CGFloat = 24
    }

    var onPrimary: (() -> Void)?
    var onSecondary: (() -> Void)?

    private let backdrop = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let primaryButton = NSButton()
    private let secondaryButton = NSButton()

    private var titleHeight: CGFloat = 0
    private var bodyHeight: CGFloat = 0
    private var shortcutHeight: CGFloat = 0
    private var buttonHeight: CGFloat = Pad.minButtonHeight
    private var accessibilitySummary = ""

    init(width: CGFloat) {
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: width))

        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        layer?.cornerRadius = OnboardingMetrics.cardCornerRadius
        layer?.masksToBounds = true

        setupBackdrop()
        let contentWidth = width - Pad.horizontal * 2
        setupLabels(contentWidth: contentWidth)
        setupButtons()

        let height = Pad.top + titleHeight + Pad.titleToBody + bodyHeight
            + Pad.bodyToShortcut + shortcutHeight + Pad.shortcutToButtons
            + buttonHeight + Pad.bottom
        setFrameSize(CGSize(width: width, height: ceil(height)))

        setAccessibilityRole(.group)
        setAccessibilityLabel(accessibilitySummary)
        positionSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("OnboardingCardView  xib / storyboard ")
    }


    private func setupBackdrop() {
        backdrop.material = .hudWindow
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = OnboardingMetrics.cardCornerRadius
        backdrop.layer?.masksToBounds = true
        backdrop.layer?.borderWidth = 1
        backdrop.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        backdrop.autoresizingMask = [.width, .height]
        addSubview(backdrop)
    }

    private func setupLabels(contentWidth: CGFloat) {
        let titleFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
        let bodyFont = NSFont.systemFont(ofSize: 12)
        let shortcutFont = NSFont.systemFont(ofSize: 11)

        let title = ("Pipkin is running in the background")
        let body = ("It lives in the menu bar and has no main window. "
                           + "Click the icon → Choose Window to mirror any window.")
        let prefs = Preferences.shared
        let pipKeys = prefs.pipHotkey.displayString
        let regionKeys = prefs.regionHotkey.displayString
        let shortcut = ("""
            \(pipKeys) PiP the frontmost window\(regionKeys) Capture a region
            Zoom in: Cmd-drag to select an area, Cmd-scroll to adjust, Cmd-double-click to reset.
            The top bar's "Reset zoom" only lights up once zoomed — it resets the zoom factor, \
            not the window size.
            """)

        configure(titleLabel, text: title, font: titleFont, color: .labelColor, width: contentWidth)
        configure(bodyLabel, text: body, font: bodyFont, color: .labelColor, width: contentWidth)
        configure(shortcutLabel, text: shortcut, font: shortcutFont,
                  color: .secondaryLabelColor, width: contentWidth)

        titleHeight = Self.height(of: title, font: titleFont, width: contentWidth)
        bodyHeight = Self.height(of: body, font: bodyFont, width: contentWidth)
        shortcutHeight = Self.height(of: shortcut, font: shortcutFont, width: contentWidth)

        accessibilitySummary = [title, body, shortcut].joined(separator: (". "))
    }

    private func configure(_ label: NSTextField, text: String, font: NSFont,
                           color: NSColor, width: CGFloat) {
        label.stringValue = text
        label.font = font
        label.textColor = color
        label.alignment = .left
        label.usesSingleLineMode = false
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = width
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        addSubview(label)
    }

    private func setupButtons() {
        let primaryTitle = ("Open Menu")
        let secondaryTitle = ("Got it")

        primaryButton.bezelStyle = .rounded
        primaryButton.title = primaryTitle
        primaryButton.keyEquivalent = "\r"
        primaryButton.target = self
        primaryButton.action = #selector(handlePrimary)
        primaryButton.setAccessibilityLabel(primaryTitle)
        addSubview(primaryButton)

        secondaryButton.bezelStyle = .rounded
        secondaryButton.title = secondaryTitle
        secondaryButton.target = self
        secondaryButton.action = #selector(handleSecondary)
        secondaryButton.setAccessibilityLabel(secondaryTitle)
        addSubview(secondaryButton)

        buttonHeight = max(Pad.minButtonHeight, ceil(primaryButton.fittingSize.height))
    }


    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        positionSubviews()
    }

    override func layout() {
        super.layout()
        positionSubviews()
    }

    private func positionSubviews() {
        backdrop.frame = bounds
        let contentWidth = max(0, bounds.width - Pad.horizontal * 2)

        var y = bounds.maxY - Pad.top - titleHeight
        titleLabel.frame = CGRect(x: Pad.horizontal, y: y, width: contentWidth, height: titleHeight)

        y -= Pad.titleToBody + bodyHeight
        bodyLabel.frame = CGRect(x: Pad.horizontal, y: y, width: contentWidth, height: bodyHeight)

        y -= Pad.bodyToShortcut + shortcutHeight
        shortcutLabel.frame = CGRect(x: Pad.horizontal, y: y, width: contentWidth, height: shortcutHeight)

        let primaryWidth = max(Pad.minButtonWidth, ceil(primaryButton.fittingSize.width))
        let secondaryWidth = max(Pad.minButtonWidth, ceil(secondaryButton.fittingSize.width))
        let buttonY = bounds.minY + Pad.bottom
        primaryButton.frame = CGRect(x: bounds.maxX - Pad.horizontal - primaryWidth, y: buttonY,
                                     width: primaryWidth, height: buttonHeight)
        secondaryButton.frame = CGRect(x: primaryButton.frame.minX - Pad.buttonSpacing - secondaryWidth,
                                       y: buttonY, width: secondaryWidth, height: buttonHeight)
    }

    private static func height(of text: String, font: NSFont, width: CGFloat) -> CGFloat {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: style]
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        )
        return ceil(rect.height) + 2
    }


    @objc private func handlePrimary() { onPrimary?() }
    @objc private func handleSecondary() { onSecondary?() }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
}
