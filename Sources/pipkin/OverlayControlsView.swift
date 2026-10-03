import AppKit

///
///
final class OverlayControlsView: NSView {


    var onClose: (() -> Void)?
    var onCycleFPS: (() -> Void)?
    var onResetZoom: (() -> Void)?
    var onToggleAutoHide: (() -> Void)?
    var onToggleIdleDetection: (() -> Void)?
    var onTogglePause: (() -> Void)?

    ///
    var onHintChange: (((String, CGRect)?) -> Void)?


    var titleText: String = "" {
        didSet {
            guard titleText != oldValue else { return }
            titleLabel.stringValue = titleText
            needsLayout = true
        }
    }

    static let preferredHeight: CGFloat = Metrics.height


    private enum Metrics {
        static let height: CGFloat = 30
        static let cornerRadius: CGFloat = 8
        static let button: CGFloat = 20
        static let gap: CGFloat = 4
        static let trailingInset: CGFloat = 6
        static let leadingInset: CGFloat = 8
        static let fade: TimeInterval = 0.12
        static let symbolPointSize: CGFloat = 11
        static let hoverPadding: CGFloat = 3
        static let hoverCornerRadius: CGFloat = 5
    }


    private static var activeTint: NSColor { .controlAccentColor }
    private static var inactiveTint: NSColor { .secondaryLabelColor }
    private static var disabledTint: NSColor { .tertiaryLabelColor }
    private static var hoverFill: NSColor { NSColor.white.withAlphaComponent(0.16) }

    private enum TintRole {
        case active
        case inactive
        case disabled
    }

    private static func tintColor(_ role: TintRole, hovered: Bool) -> NSColor {
        switch role {
        case .active: return hovered ? brightened(activeTint) : activeTint
        case .inactive: return hovered ? .labelColor : inactiveTint
        case .disabled: return disabledTint
        }
    }

    private static func brightened(_ color: NSColor, by fraction: CGFloat = 0.35) -> NSColor {
        if let highlighted = color.highlight(withLevel: fraction) { return highlighted }
        guard let rgb = color.usingColorSpace(.sRGB) else { return color }
        func mix(_ c: CGFloat) -> CGFloat { min(1, c + (1 - c) * fraction) }
        return NSColor(srgbRed: mix(rgb.redComponent), green: mix(rgb.greenComponent),
                       blue: mix(rgb.blueComponent), alpha: rgb.alphaComponent)
    }


    private let backdrop = NSVisualEffectView()
    private let hoverHighlight = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let zoomLabel = NSTextField(labelWithString: "")

    private let pauseButton = NSButton()
    private let fpsButton = NSButton()
    private let resetZoomButton = NSButton()
    private let autoHideButton = NSButton()
    private let idleButton = NSButton()
    private let closeButton = NSButton()

    private var buttonsRightToLeft: [NSButton] {
        [closeButton, idleButton, autoHideButton, resetZoomButton, fpsButton, pauseButton]
    }

    private var desiredVisible = false


    private enum HintTarget: Int, CaseIterable {
        case pause, fps, resetZoom, autoHide, idle, close, title
    }

    private static let hintTargetKey = "hintTarget"

    private var hintTexts: [ObjectIdentifier: String] = [:]
    private var tintRoles: [ObjectIdentifier: TintRole] = [:]
    private var hintTrackingAreas: [HintTarget: NSTrackingArea] = [:]
    private var activeHintTarget: HintTarget?
    private weak var hoveredButton: NSButton?
    private var fpsTitleText = "15f"


    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        autoresizingMask = [.width, .minYMargin]
        alphaValue = 0
        isHidden = true

        setupBackdrop()
        setupHoverHighlight()
        setupLabels()
        setupButtons()
        setupAccessibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("OverlayControlsView  xib / storyboard ")
    }

    private func setupBackdrop() {
        backdrop.material = .hudWindow
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = Metrics.cornerRadius
        backdrop.layer?.masksToBounds = true
        backdrop.autoresizingMask = [.width, .height]
        addSubview(backdrop)
    }

    private func setupHoverHighlight() {
        hoverHighlight.wantsLayer = true
        hoverHighlight.layer?.cornerRadius = Metrics.hoverCornerRadius
        hoverHighlight.layer?.backgroundColor = Self.hoverFill.cgColor
        hoverHighlight.autoresizingMask = []
        hoverHighlight.isHidden = true
        addSubview(hoverHighlight, positioned: .above, relativeTo: backdrop)
    }

    private func setupLabels() {
        titleLabel.font = .systemFont(ofSize: 11)
        titleLabel.textColor = Self.inactiveTint
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.usesSingleLineMode = true
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleLabel.alignment = .left
        addSubview(titleLabel)

        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        zoomLabel.textColor = Self.activeTint
        zoomLabel.usesSingleLineMode = true
        zoomLabel.isHidden = true
        addSubview(zoomLabel)
    }

    private func setupButtons() {
        configureIconButton(
            pauseButton, symbols: ["pause.fill"],
            hint: ("Pause"),
            accessibility: ("Pause"),
            action: #selector(handleTogglePause)
        )

        fpsButton.isBordered = false
        fpsButton.setButtonType(.momentaryChange)
        fpsButton.imagePosition = .noImage
        fpsButton.target = self
        fpsButton.action = #selector(handleCycleFPS)
        fpsButton.refusesFirstResponder = true
        setHintText(("Frame rate (click to cycle)"), for: fpsButton)
        fpsButton.setAccessibilityLabel(("Cycle frame rate"))
        addSubview(fpsButton)
        tintRoles[ObjectIdentifier(fpsButton)] = .inactive
        setFPSTitle("15f")

        configureIconButton(
            resetZoomButton, symbols: ["arrow.up.left.and.down.right.magnifyingglass"],
            hint: ("Reset zoom"),
            accessibility: ("Reset zoom"),
            action: #selector(handleResetZoom)
        )
        resetZoomButton.isEnabled = false
        setTintRole(.disabled, for: resetZoomButton)

        configureIconButton(
            autoHideButton, symbols: ["eye"],
            hint: ("Auto-hide (fade out on hover)"),
            accessibility: ("Auto-hide"),
            action: #selector(handleToggleAutoHide)
        )

        configureIconButton(
            idleButton, symbols: ["bolt.badge.clock", "zzz"],
            hint: ("Idle detection (drop frame rate when static)"),
            accessibility: ("Idle detection"),
            action: #selector(handleToggleIdleDetection)
        )

        configureIconButton(
            closeButton, symbols: ["xmark"],
            hint: ("Close picture-in-picture"),
            accessibility: ("Close picture-in-picture"),
            action: #selector(handleClose)
        )
    }

    private func setupAccessibility() {
        setAccessibilityRole(.group)
        setAccessibilityLabel(("Overlay controls"))
    }

    private func configureIconButton(_ button: NSButton, symbols: [String],
                                     hint: String, accessibility: String,
                                     action: Selector) {
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.image = Self.symbolImage(symbols, accessibility: accessibility)
        button.target = self
        button.action = action
        button.refusesFirstResponder = true
        setHintText(hint, for: button)
        button.setAccessibilityLabel(accessibility)
        addSubview(button)
        setTintRole(.inactive, for: button)
    }


    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        backdrop.frame = bounds

        let buttonY = ((bounds.height - Metrics.button) / 2).rounded()
        var x = bounds.maxX - Metrics.trailingInset

        for button in buttonsRightToLeft {
            let width = (button === fpsButton) ? fpsButtonWidth() : Metrics.button
            x -= width
            button.frame = CGRect(x: x.rounded(), y: buttonY, width: width, height: Metrics.button)
            x -= Metrics.gap
        }

        let textLeft = bounds.minX + Metrics.leadingInset
        let textRight = max(textLeft, x)
        let available = textRight - textLeft

        var zoomWidth: CGFloat = 0
        if !zoomLabel.isHidden {
            zoomWidth = min(ceil(zoomLabel.fittingSize.width) + 2, available)
        }
        let titleBudget = max(0, available - (zoomWidth > 0 ? zoomWidth + Metrics.gap : 0))
        let titleWidth = min(ceil(titleLabel.fittingSize.width), titleBudget)
        titleLabel.frame = CGRect(
            x: textLeft, y: verticalCenter(of: ceil(titleLabel.fittingSize.height)),
            width: titleWidth, height: ceil(titleLabel.fittingSize.height)
        )

        if zoomWidth > 0 {
            let h = ceil(zoomLabel.fittingSize.height)
            zoomLabel.frame = CGRect(
                x: titleLabel.frame.maxX + Metrics.gap, y: verticalCenter(of: h),
                width: zoomWidth, height: h
            )
        }

        rebuildHintTrackingAreas()
        refreshHoverHighlight()
        if let target = activeHintTarget { pushHint(for: target) }
    }

    private func verticalCenter(of height: CGFloat) -> CGFloat {
        ((bounds.height - height) / 2).rounded()
    }

    private func fpsButtonWidth() -> CGFloat {
        let measured = ceil(fpsButton.attributedTitle.size().width) + 8
        return max(22, measured)
    }


    func update(state: PiPSessionState) {
        setFPSTitle("\(state.fps.rawValue)f")
        setHintText(("Frame rate \(state.fps.rawValue) fps (click to cycle)"), for: fpsButton)
        fpsButton.setAccessibilityLabel(("Frame rate \(state.fps.rawValue) fps"))

        pauseButton.image = Self.symbolImage(
            [state.isPaused ? "play.fill" : "pause.fill"],
            accessibility: state.isPaused ? ("Resume") : ("Pause")
        )
        setTintRole(state.isPaused ? .active : .inactive, for: pauseButton)
        setHintText(state.isPaused ? ("Resume") : ("Pause"), for: pauseButton)
        pauseButton.setAccessibilityLabel(state.isPaused ? ("Resume") : ("Pause"))

        let zoomed = state.zoom > 1.001
        let resettable = zoomed || state.hasSelectionCrop
        resetZoomButton.isEnabled = resettable
        setTintRole(resettable ? .inactive : .disabled, for: resetZoomButton)
        let resetHint = state.hasSelectionCrop
            ? ("Restore full frame and original aspect ratio")
            : ("Reset zoom")
        setHintText(resetHint, for: resetZoomButton)
        resetZoomButton.setAccessibilityLabel(resetHint)

        autoHideButton.image = Self.symbolImage(
            [state.autoHide ? "eye.slash" : "eye"],
            accessibility: ("Auto-hide")
        )
        applyToggleStyle(
            autoHideButton, isOn: state.autoHide,
            onHint: ("Auto-hide: on (fades out on hover)"),
            offHint: ("Auto-hide: off"),
            onLabel: ("Auto-hide: on"),
            offLabel: ("Auto-hide: off")
        )

        applyToggleStyle(
            idleButton, isOn: state.idleDetection,
            onHint: ("Idle detection: on (drops to 1 fps when static)"),
            offHint: ("Idle detection: off"),
            onLabel: ("Idle detection: on"),
            offLabel: ("Idle detection: off")
        )

        if zoomed {
            zoomLabel.stringValue = String(format: "%.1f×", Double(state.zoom))
            zoomLabel.isHidden = false
        } else if state.hasSelectionCrop {
            zoomLabel.stringValue = ("Crop")
            zoomLabel.isHidden = false
        } else {
            zoomLabel.stringValue = ""
            zoomLabel.isHidden = true
        }

        if let target = activeHintTarget { pushHint(for: target) }
        refreshHoverHighlight()

        needsLayout = true
    }

    private func applyToggleStyle(_ button: NSButton, isOn: Bool,
                                  onHint: String, offHint: String,
                                  onLabel: String, offLabel: String) {
        setTintRole(isOn ? .active : .inactive, for: button)
        setHintText(isOn ? onHint : offHint, for: button)
        button.setAccessibilityLabel(isOn ? onLabel : offLabel)
    }

    private func setFPSTitle(_ text: String) {
        fpsTitleText = text
        applyTint(to: fpsButton)
    }

    private func renderFPSTitle(color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        fpsButton.attributedTitle = NSAttributedString(string: fpsTitleText, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: color,
            .paragraphStyle: style,
        ])
    }


    private func setTintRole(_ role: TintRole, for button: NSButton) {
        tintRoles[ObjectIdentifier(button)] = role
        applyTint(to: button)
    }

    private func applyTint(to button: NSButton) {
        let role = tintRoles[ObjectIdentifier(button)] ?? .inactive
        let color = Self.tintColor(role, hovered: hoveredButton === button)
        if button === fpsButton {
            renderFPSTitle(color: color)
        } else {
            button.contentTintColor = color
        }
    }


    func setVisible(_ visible: Bool, animated: Bool) {
        desiredVisible = visible
        if visible { isHidden = false }
        if !visible { clearHint() }

        guard animated else {
            alphaValue = visible ? 1 : 0
            isHidden = !visible
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Metrics.fade
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().alphaValue = visible ? 1 : 0
        }, completionHandler: { [weak self] in
            guard let self, !visible, !self.desiredVisible else { return }
            self.isHidden = true
        })
    }


    private func setHintText(_ text: String, for button: NSButton) {
        hintTexts[ObjectIdentifier(button)] = text
    }

    private func hintTargetView(_ target: HintTarget) -> NSView {
        switch target {
        case .pause: return pauseButton
        case .fps: return fpsButton
        case .resetZoom: return resetZoomButton
        case .autoHide: return autoHideButton
        case .idle: return idleButton
        case .close: return closeButton
        case .title: return titleLabel
        }
    }

    private func hintText(for target: HintTarget) -> String? {
        if target == .title { return titleText.isEmpty ? nil : titleText }
        let text = hintTexts[ObjectIdentifier(hintTargetView(target))]
        return (text?.isEmpty ?? true) ? nil : text
    }

    private func rebuildHintTrackingAreas() {
        for (target, area) in hintTrackingAreas {
            hintTargetView(target).removeTrackingArea(area)
        }
        hintTrackingAreas.removeAll(keepingCapacity: true)

        for target in HintTarget.allCases {
            let view = hintTargetView(target)
            guard !view.isHidden, hintText(for: target) != nil else { continue }
            let area = NSTrackingArea(
                rect: view.bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: [Self.hintTargetKey: target.rawValue]
            )
            view.addTrackingArea(area)
            hintTrackingAreas[target] = area
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        rebuildHintTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        guard let target = Self.hintTarget(of: event) else {
            super.mouseEntered(with: event)
            return
        }
        activeHintTarget = target
        pushHint(for: target)
        refreshHoverHighlight()
    }

    override func mouseExited(with event: NSEvent) {
        guard let target = Self.hintTarget(of: event) else {
            super.mouseExited(with: event)
            return
        }
        guard activeHintTarget == target else { return }
        clearHint()
    }

    private func pushHint(for target: HintTarget) {
        guard desiredVisible, !isHidden, let text = hintText(for: target) else { return }
        guard let rect = screenFrame(of: hintTargetView(target)) else { return }
        onHintChange?((text, rect))
    }

    private func screenFrame(of view: NSView) -> CGRect? {
        guard let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    private func clearHint() {
        activeHintTarget = nil
        refreshHoverHighlight()
        onHintChange?(nil)
    }

    private static func hintTarget(of event: NSEvent) -> HintTarget? {
        guard let raw = event.trackingArea?.userInfo?[hintTargetKey] as? Int else { return nil }
        return HintTarget(rawValue: raw)
    }


    private func refreshHoverHighlight() {
        let target = (desiredVisible && !isHidden) ? activeHintTarget : nil
        let button = target.flatMap { hoverableButton(for: $0) }

        if button !== hoveredButton {
            let previous = hoveredButton
            hoveredButton = button
            if let previous { applyTint(to: previous) }
            if let button { applyTint(to: button) }
        }

        guard let button else {
            hoverHighlight.isHidden = true
            return
        }
        hoverHighlight.frame = button.frame.insetBy(dx: -Metrics.hoverPadding, dy: -Metrics.hoverPadding)
        hoverHighlight.isHidden = false
    }

    private func hoverableButton(for target: HintTarget) -> NSButton? {
        guard let button = hintTargetView(target) as? NSButton,
              button.isEnabled, !button.isHidden else { return nil }
        return button
    }


    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.05 else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        for button in buttonsRightToLeft where button.isEnabled && !button.isHidden {
            if button.frame.insetBy(dx: -2, dy: -2).contains(local) { return button }
        }
        return nil
    }

    override var mouseDownCanMoveWindow: Bool { false }


    @objc private func handleClose() { onClose?() }
    @objc private func handleCycleFPS() { onCycleFPS?() }
    @objc private func handleResetZoom() { onResetZoom?() }
    @objc private func handleToggleAutoHide() { onToggleAutoHide?() }
    @objc private func handleToggleIdleDetection() { onToggleIdleDetection?() }
    @objc private func handleTogglePause() { onTogglePause?() }

    // MARK: - SF Symbol

    private static let symbolConfiguration = NSImage.SymbolConfiguration(
        pointSize: Metrics.symbolPointSize, weight: .semibold
    )

    private static func symbolImage(_ names: [String], accessibility: String) -> NSImage? {
        for name in names {
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: accessibility) else {
                continue
            }
            let configured = image.withSymbolConfiguration(symbolConfiguration) ?? image
            configured.isTemplate = true
            return configured
        }
        Log.warn("SF Symbol \(names.joined(separator: " / "))")
        return nil
    }
}
