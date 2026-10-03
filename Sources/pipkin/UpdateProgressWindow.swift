import AppKit

private enum UpdateProgressMetrics {
    static let panelWidth: CGFloat = 360
    static let panelMinHeight: CGFloat = 120
    static let padding: CGFloat = 16
    static let rowSpacing: CGFloat = 8

    static let titleFontSize: CGFloat = 13
    static let statusFontSize: CGFloat = 11

    static let updateThrottle: TimeInterval = 0.1
    static let autoCloseDelay: TimeInterval = 1.5
}

///
///
final class UpdateProgressWindow: NSObject, NSWindowDelegate {


    private static var shared: UpdateProgressWindow?

    static var isVisible: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return visibleState
    }

    static var percent: Int? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return percentState
    }

    /// - Parameters:
    static func show(version: String, onCancel: @escaping () -> Void) {
        onMain {
            if let existing = shared {
                existing.reuse(version: version, onCancel: onCancel)
                existing.present(center: false)
            } else {
                let window = UpdateProgressWindow(version: version, onCancel: onCancel)
                shared = window
                window.present(center: true)
            }
        }
    }

    static func update(bytesWritten: Int64, totalBytes: Int64) {
        onMain {
            guard let window = shared, isVisible else { return }
            window.apply(bytesWritten: bytesWritten, totalBytes: totalBytes)
        }
    }

    static func finish(message: String) {
        onMain {
            guard let window = shared, isVisible else { return }
            window.applyFinish(message: message)
        }
    }

    static func dismiss() {
        onMain {
            storePercent(nil)
            storeVisible(false)
            shared?.teardown()
        }
    }


    private static let stateLock = NSLock()
    private static var visibleState = false
    private static var percentState: Int?

    private static func storeVisible(_ value: Bool) {
        stateLock.lock()
        visibleState = value
        stateLock.unlock()
    }

    private static func storePercent(_ value: Int?) {
        stateLock.lock()
        percentState = value
        stateLock.unlock()
    }

    private static func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }


    private static let contentWidth = UpdateProgressMetrics.panelWidth - UpdateProgressMetrics.padding * 2

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    private let panel: NSPanel
    private let titleLabel: NSTextField
    private let progressBar: NSProgressIndicator
    private let statusLabel: NSTextField
    private let cancelButton: NSButton

    private var version: String
    private var onCancel: () -> Void

    private var didCancel = false
    private var isFinishing = false
    private var isIndeterminate = false

    private var lastRenderAt: CFAbsoluteTime = 0
    private var lastRenderedPercent: Int?

    private var autoCloseWork: DispatchWorkItem?

    private init(version: String, onCancel: @escaping () -> Void) {
        self.version = version
        self.onCancel = onCancel

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0,
                                width: UpdateProgressMetrics.panelWidth,
                                height: UpdateProgressMetrics.panelMinHeight),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        titleLabel = Self.makeLabel(Self.titleText(version: version),
                                    size: UpdateProgressMetrics.titleFontSize,
                                    bold: true, secondary: false)

        progressBar = NSProgressIndicator()
        progressBar.style = .bar
        progressBar.controlSize = .small
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.doubleValue = 0
        progressBar.usesThreadedAnimation = true

        statusLabel = Self.makeLabel(("Connecting…"),
                                     size: UpdateProgressMetrics.statusFontSize,
                                     bold: false, secondary: true)

        cancelButton = NSButton(title: ("Cancel"), target: nil, action: nil)
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .small

        super.init()

        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)

        configurePanel()
        buildContent()
        configureAccessibility()
    }


    private func configurePanel() {
        panel.title = ("Software Update")
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
    }

    private func buildContent() {
        let content = NSView(frame: NSRect(x: 0, y: 0,
                                           width: UpdateProgressMetrics.panelWidth,
                                           height: UpdateProgressMetrics.panelMinHeight))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = UpdateProgressMetrics.rowSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(progressBar)
        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(makeFooter())

        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true

        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor,
                                       constant: UpdateProgressMetrics.padding),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor,
                                           constant: UpdateProgressMetrics.padding),
        ])

        panel.contentView = content

        let needed = ceil(stack.fittingSize.height) + UpdateProgressMetrics.padding * 2
        panel.setContentSize(NSSize(width: UpdateProgressMetrics.panelWidth,
                                    height: max(UpdateProgressMetrics.panelMinHeight, needed)))
    }

    private func makeFooter() -> NSView {
        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(cancelButton)
        NSLayoutConstraint.activate([
            footer.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            cancelButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            cancelButton.topAnchor.constraint(equalTo: footer.topAnchor),
            cancelButton.bottomAnchor.constraint(equalTo: footer.bottomAnchor),
        ])
        return footer
    }

    private func configureAccessibility() {
        progressBar.setAccessibilityLabel(("Update download progress"))
        cancelButton.setAccessibilityLabel(("Cancel update download"))
    }


    private func present(center: Bool) {
        if center { panel.center() }
        panel.orderFrontRegardless()
        Self.storeVisible(true)
        Log.debug(" version=\(version) center=\(center)")
    }

    private func reuse(version newVersion: String, onCancel: @escaping () -> Void) {
        autoCloseWork?.cancel()
        autoCloseWork = nil

        self.onCancel = onCancel
        didCancel = false
        cancelButton.isHidden = false

        if isFinishing || newVersion != version {
            version = newVersion
            titleLabel.stringValue = Self.titleText(version: newVersion)
            resetProgress()
        }
        isFinishing = false
    }

    private func resetProgress() {
        setDeterminate(percent: 0)
        statusLabel.stringValue = ("Connecting…")
        lastRenderAt = 0
        lastRenderedPercent = nil
        Self.storePercent(nil)
    }

    private func teardown() {
        autoCloseWork?.cancel()
        autoCloseWork = nil
        stopIndeterminateIfNeeded()
        isFinishing = false
        if panel.isVisible {
            panel.orderOut(nil)
            Log.debug(" version=\(version)")
        }
    }


    private func apply(bytesWritten: Int64, totalBytes: Int64) {
        guard !isFinishing else { return }

        let written = max(0, bytesWritten)
        let pct: Int? = totalBytes > 0
            ? min(100, max(0, Int((Double(written) / Double(totalBytes) * 100).rounded(.down))))
            : nil

        if let pct, pct == lastRenderedPercent { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastRenderAt >= UpdateProgressMetrics.updateThrottle else { return }
        lastRenderAt = now
        lastRenderedPercent = pct

        if let pct {
            setDeterminate(percent: pct)
            statusLabel.stringValue =
                "\(Self.formatBytes(written)) / \(Self.formatBytes(totalBytes)) · \(pct)%"
            Self.storePercent(pct)
        } else {
            setIndeterminate()
            statusLabel.stringValue = ("Downloaded \(Self.formatBytes(written))")
            Self.storePercent(nil)
        }
        progressBar.setAccessibilityValueDescription(statusLabel.stringValue)
    }

    private func applyFinish(message: String) {
        autoCloseWork?.cancel()
        isFinishing = true

        setDeterminate(percent: 100)
        statusLabel.stringValue = message
        cancelButton.isHidden = true
        lastRenderedPercent = 100
        Self.storePercent(100)
        progressBar.setAccessibilityValueDescription(message)
        Log.debug("\(message)\(UpdateProgressMetrics.autoCloseDelay)s ")

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isFinishing else { return }
            UpdateProgressWindow.dismiss()
        }
        autoCloseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + UpdateProgressMetrics.autoCloseDelay,
                                      execute: work)
    }

    private func setDeterminate(percent: Int) {
        stopIndeterminateIfNeeded()
        progressBar.doubleValue = Double(percent)
    }

    private func setIndeterminate() {
        guard !isIndeterminate else { return }
        isIndeterminate = true
        progressBar.isIndeterminate = true
        progressBar.startAnimation(nil)
    }

    private func stopIndeterminateIfNeeded() {
        guard isIndeterminate else { return }
        isIndeterminate = false
        progressBar.stopAnimation(nil)
        progressBar.isIndeterminate = false
    }


    @objc private func cancelClicked() {
        Log.debug("")
        triggerCancel()
    }

    private func triggerCancel() {
        guard !didCancel else { return }
        didCancel = true
        let handler = onCancel
        UpdateProgressWindow.dismiss()
        handler()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isFinishing {
            UpdateProgressWindow.dismiss()
        } else {
            triggerCancel()
        }
        return false
    }


    private static func titleText(version: String) -> String {
        ("Downloading Pipkin \(version)")
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: bytes)
    }

    private static func makeLabel(_ text: String, size: CGFloat,
                                  bold: Bool, secondary: Bool) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = bold ? .systemFont(ofSize: size, weight: .semibold) : .systemFont(ofSize: size)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        return field
    }
}
