import AppKit

///
final class PlaceholderView: NSView {

    var onOpenSettings: (() -> Void)?


    private enum Metrics {
        static let iconBox: CGFloat = 34
        static let iconPointSize: CGFloat = 28
        static let titleFontSize: CGFloat = 13
        static let subtitleFontSize: CGFloat = 11
        static let spacing: CGFloat = 6
        static let horizontalPadding: CGFloat = 12
        static let fade: TimeInterval = 0.12
        static let subtitleMinHeight: CGFloat = 92
        static let iconMinHeight: CGFloat = 56
    }


    private let iconView = SpinningIconView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton()
    private let stack = NSStackView()

    private var runtimeState: SessionRuntimeState = .streaming
    private var wantsSubtitle = false
    private var wantsActionButton = false
    private var desiredVisible = false


    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        autoresizingMask = [.width, .height]
        alphaValue = 0
        isHidden = true

        setupSubviews()
        setAccessibilityRole(.group)
        setAccessibilityLabel(("Overlay status"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PlaceholderView  xib / storyboard ")
    }

    private func setupSubviews() {
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .labelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: Metrics.titleFontSize, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.usesSingleLineMode = true

        subtitleLabel.font = .systemFont(ofSize: Metrics.subtitleFontSize)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        subtitleLabel.usesSingleLineMode = false
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 3
        subtitleLabel.cell?.truncatesLastVisibleLine = true

        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .small
        actionButton.font = .systemFont(ofSize: Metrics.subtitleFontSize)
        actionButton.target = self
        actionButton.action = #selector(handleAction)
        actionButton.isHidden = true

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Metrics.spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setViews([iconView, titleLabel, subtitleLabel, actionButton], in: .leading)
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor,
                                           constant: Metrics.horizontalPadding),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor,
                                            constant: -Metrics.horizontalPadding),
            iconView.widthAnchor.constraint(equalToConstant: Metrics.iconBox),
            iconView.heightAnchor.constraint(equalToConstant: Metrics.iconBox),
        ])
    }


    func update(runtimeState: SessionRuntimeState, source: CaptureSource) {
        self.runtimeState = runtimeState

        guard runtimeState != .streaming, runtimeState != .sourceOffscreen else {
            setVisible(false, animated: true)
            return
        }

        let content = Self.content(for: runtimeState, source: source)
        apply(content)
        setVisible(true, animated: true)
    }

    private struct Content {
        var symbols: [String]
        var title: String
        var subtitle: String
        var isAlert: Bool = false
        var spins: Bool = false
        var actionTitle: String?
    }

    private static func content(for state: SessionRuntimeState, source: CaptureSource) -> Content {
        switch state {
        case .streaming:
            return Content(symbols: ["pause.circle"], title: "", subtitle: "")

        case .paused:
            return Content(
                symbols: ["pause.circle"],
                title: ("Paused"),
                subtitle: ("Click the window or the controls to resume")
            )

        case .sourceOffscreen:
            return Content(symbols: [], title: "", subtitle: "")

        case .minimized:
            return Content(
                symbols: ["arrow.down.right.and.arrow.up.left.circle"],
                title: ("Source window minimized"),
                subtitle: ("Restore \(source.displayTitle) to resume automatically")
            )

        case .waitingForSource:
            return Content(
                symbols: ["arrow.down.right.and.arrow.up.left.circle",
                          "arrow.down.right.and.arrow.up.left"],
                title: ("Source window minimized"),
                subtitle: ("Restore \(source.displayTitle) to resume automatically")
            )

        case let .reconnecting(attempt):
            return Content(
                symbols: ["arrow.triangle.2.circlepath"],
                title: ("Reconnecting… (attempt \(attempt))"),
                subtitle: ("Trying to reattach to \(source.displayTitle)"),
                spins: true
            )

        case .sourceLost:
            return Content(
                symbols: ["xmark.circle"],
                title: ("Source window closed"),
                subtitle: ("\(source.displayTitle) is no longer available. This window will close shortly."),
                isAlert: true
            )

        case .permissionDenied:
            return Content(
                symbols: ["lock.circle"],
                title: ("Screen Recording permission required"),
                subtitle: ("Turn Pipkin on in System Settings → Privacy & Security → Screen & System Audio Recording, then relaunch"),
                isAlert: true,
                actionTitle: ("Open System Settings")
            )

        case let .failed(message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return Content(
                symbols: ["exclamationmark.triangle"],
                title: ("Capture failed"),
                subtitle: detail.isEmpty
                    ? ("Cannot keep capturing \(source.displayTitle)")
                    : detail,
                isAlert: true
            )
        }
    }

    private func apply(_ content: Content) {
        iconView.image = Self.symbolImage(content.symbols, accessibility: content.title)
        iconView.contentTintColor = content.isAlert ? .systemOrange : .labelColor

        titleLabel.stringValue = content.title

        subtitleLabel.stringValue = content.subtitle
        wantsSubtitle = !content.subtitle.isEmpty

        if let actionTitle = content.actionTitle, onOpenSettings != nil {
            actionButton.title = actionTitle
            actionButton.setAccessibilityLabel(actionTitle)
            wantsActionButton = true
        } else {
            wantsActionButton = false
        }

        setAccessibilityLabel([content.title, content.subtitle]
            .filter { !$0.isEmpty }.joined(separator: ""))

        needsLayout = true
        syncSpinning()
    }


    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()

        let wrapWidth = max(80, bounds.width - Metrics.horizontalPadding * 2)
        if abs(subtitleLabel.preferredMaxLayoutWidth - wrapWidth) > 0.5 {
            subtitleLabel.preferredMaxLayoutWidth = wrapWidth
        }

        let compactSubtitle = bounds.height < Metrics.subtitleMinHeight
        let compactIcon = bounds.height < Metrics.iconMinHeight
        iconView.isHidden = compactIcon
        subtitleLabel.isHidden = !wantsSubtitle || compactSubtitle
        actionButton.isHidden = !wantsActionButton || compactSubtitle
    }


    func setVisible(_ visible: Bool, animated: Bool) {
        desiredVisible = visible
        if visible { isHidden = false }
        syncSpinning()

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

    private func syncSpinning() {
        var spins = false
        if case .reconnecting = runtimeState { spins = true }
        if spins && desiredVisible && window != nil {
            iconView.startSpinning()
        } else {
            iconView.stopSpinning()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncSpinning()
    }


    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.05 else { return nil }
        guard !actionButton.isHidden else { return nil }
        let local = convert(point, from: superview)
        let buttonRect = actionButton.convert(actionButton.bounds, to: self)
        return buttonRect.insetBy(dx: -2, dy: -2).contains(local) ? actionButton : nil
    }

    override var mouseDownCanMoveWindow: Bool { false }

    @objc private func handleAction() { onOpenSettings?() }

    // MARK: - SF Symbol

    private static let symbolConfiguration = NSImage.SymbolConfiguration(
        pointSize: Metrics.iconPointSize, weight: .regular
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


private final class SpinningIconView: NSImageView {
    private static let animationKey = "mwp.spin"
    private var isSpinning = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SpinningIconView  xib / storyboard ")
    }

    override func layout() {
        super.layout()
        guard let layer else { return }
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.bounds = CGRect(origin: .zero, size: frame.size)
        layer.position = CGPoint(x: frame.midX, y: frame.midY)
    }

    func startSpinning() {
        guard !isSpinning, let layer else { return }
        isSpinning = true
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: frame.midX, y: frame.midY)

        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = -Double.pi * 2
        rotation.duration = 1.1
        rotation.repeatCount = .infinity
        rotation.isRemovedOnCompletion = false
        layer.add(rotation, forKey: Self.animationKey)
    }

    func stopSpinning() {
        guard isSpinning else { return }
        isSpinning = false
        layer?.removeAnimation(forKey: Self.animationKey)
    }
}
