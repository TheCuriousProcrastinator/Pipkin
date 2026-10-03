import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit

///
///
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {


    static let queueLabel = "com.thecuriousprocrastinator.Pipkin.capture"
    private static let retuneThrottle: TimeInterval = 0.1
    private static let restartCoalesce: TimeInterval = 0.3
    static let maxOutputPixels = 4096


    weak var delegate: CaptureEngineDelegate?

    private(set) var currentFPS: Int = FPSStep.fifteen.rawValue
    private(set) var isRunning = false
    private(set) var isPaused = false


    private var stream: SCStream?
    private var filter: SCContentFilter?
    private var configuration: SCStreamConfiguration?

    private var pendingConfiguration: SCStreamConfiguration?
    private var retuneFlushScheduled = false
    private var lastRetuneUptime: TimeInterval = -.greatestFiniteMagnitude
    private var lastRestartUptime: TimeInterval = -.greatestFiniteMagnitude
    private let frameQueue = DispatchQueue(label: CaptureEngine.queueLabel, qos: .userInitiated)


    private let stallLock = NSLock()
    private var lastFrameUptime: TimeInterval = 0
    private var stallReported = false
    private var stallTimer: DispatchSourceTimer?


    override init() {
        super.init()
    }

    deinit {
        stallTimer?.cancel()
        stallTimer = nil
        stream?.stopCapture { _ in }
        stream = nil
    }


    static func filter(for window: SCWindow) -> SCContentFilter {
        SCContentFilter(desktopIndependentWindow: window)
    }

    ///
    static func filter(forDisplay display: SCDisplay,
                       excludingOwnWindows ownWindows: [SCWindow]) -> SCContentFilter {
        var apps: [SCRunningApplication] = []
        for window in ownWindows {
            guard let app = window.owningApplication else { continue }
            if !apps.contains(where: { $0.processID == app.processID }) { apps.append(app) }
        }
        if !apps.isEmpty {
            return SCContentFilter(display: display, excludingApplications: apps, exceptingWindows: [])
        }
        return SCContentFilter(display: display, excludingWindows: ownWindows)
    }

    /// - Parameters:
    static func makeConfiguration(sourceRect: CGRect, pointSize: CGSize, scale: CGFloat,
                                  fps: Int, showsCursor: Bool) -> SCStreamConfiguration {
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = sanitizedSourceRect(sourceRect)
        let px = Geo.pixelSize(points: pointSize, scale: max(1, scale))
        cfg.width = px.width
        cfg.height = px.height
        let clampedFPS = min(max(fps, 1), 60)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(clampedFPS))
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.queueDepth = 3
        cfg.scalesToFit = true
        cfg.preservesAspectRatio = true
        cfg.showsCursor = showsCursor
        cfg.capturesAudio = false
        cfg.ignoreShadowsSingleWindow = true
        if #available(macOS 14.2, *) {
            cfg.includeChildWindows = false
        }
        return cfg
    }

    static func fps(of configuration: SCStreamConfiguration) -> Int {
        let seconds = CMTimeGetSeconds(configuration.minimumFrameInterval)
        guard seconds.isFinite, seconds > 0 else { return FPSStep.sixty.rawValue }
        return min(max(Int((1.0 / seconds).rounded()), 1), 60)
    }

    private static func sanitizedSourceRect(_ rect: CGRect) -> CGRect {
        guard rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite,
              rect.width >= 1, rect.height >= 1 else { return .zero }
        return CGRect(x: rect.minX.rounded(), y: rect.minY.rounded(),
                      width: rect.width.rounded(), height: rect.height.rounded())
    }


    func start(filter: SCContentFilter, configuration: SCStreamConfiguration) throws {
        tearDownStream()
        self.filter = filter
        self.configuration = configuration
        currentFPS = Self.fps(of: configuration)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)
        self.stream = stream
        isRunning = true
        isPaused = false
        startStallWatchdog()

        stream.startCapture { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async {
                guard let self, self.stream === stream else { return }
                Log.error("\(error.localizedDescription)")
                self.tearDownStream()
                self.delegate?.captureDidStop(error: error)
            }
        }
        Log.debug("\(configuration.width)×\(configuration.height) @ \(currentFPS)fps")
    }

    func stop() {
        onMain { [weak self] in
            guard let self else { return }
            self.pendingConfiguration = nil
            self.tearDownStream()
            self.isPaused = false
        }
    }

    func pause() {
        onMain { [weak self] in
            guard let self, self.isRunning, !self.isPaused else { return }
            self.tearDownStream()
            self.isPaused = true
            Log.debug("")
        }
    }

    func resume() {
        onMain { [weak self] in
            guard let self, self.isPaused else { return }
            self.isPaused = false
            guard let filter = self.filter, let configuration = self.configuration else { return }
            do {
                try self.start(filter: filter, configuration: configuration)
                Log.debug("")
            } catch {
                Log.error("\(error.localizedDescription)")
                self.delegate?.captureDidStop(error: error)
            }
        }
    }


    func retune(_ configuration: SCStreamConfiguration) {
        onMain { [weak self] in
            guard let self else { return }
            self.configuration = configuration
            self.currentFPS = Self.fps(of: configuration)

            let now = ProcessInfo.processInfo.systemUptime
            if !self.retuneFlushScheduled, now - self.lastRetuneUptime >= Self.retuneThrottle {
                self.lastRetuneUptime = now
                self.pendingConfiguration = nil
                self.applyConfiguration(configuration)
                return
            }
            self.pendingConfiguration = configuration
            guard !self.retuneFlushScheduled else { return }
            self.retuneFlushScheduled = true
            let delay = max(0, Self.retuneThrottle - (now - self.lastRetuneUptime))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.retuneFlushScheduled = false
                guard let pending = self.pendingConfiguration else { return }
                self.pendingConfiguration = nil
                self.lastRetuneUptime = ProcessInfo.processInfo.systemUptime
                self.applyConfiguration(pending)
            }
        }
    }

    func retarget(_ filter: SCContentFilter) {
        onMain { [weak self] in
            guard let self else { return }
            self.filter = filter
            guard let stream = self.stream else { return }
            stream.updateContentFilter(filter) { [weak self] error in
                guard let error else { return }
                Log.warn("updateContentFilter \(error.localizedDescription)")
                DispatchQueue.main.async { self?.restart() }
            }
        }
    }

    func restart() {
        onMain { [weak self] in
            guard let self else { return }
            guard let filter = self.filter, let configuration = self.configuration else {
                Log.warn("restart  filter/configuration")
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            if now - self.lastRestartUptime < Self.restartCoalesce {
                Log.debug("restart  \(Self.restartCoalesce)s")
                return
            }
            self.delegate?.captureWillRestart()
            self.lastRestartUptime = now
            self.pendingConfiguration = nil
            do {
                try self.start(filter: filter, configuration: configuration)
                Log.debug("")
            } catch {
                Log.error("\(error.localizedDescription)")
                self.delegate?.captureDidStop(error: error)
            }
        }
    }

    private func applyConfiguration(_ configuration: SCStreamConfiguration) {
        guard let stream else { return }
        stream.updateConfiguration(configuration) { [weak self] error in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.stream === stream else { return }
                guard let error else { return }
                Log.warn("updateConfiguration \(error.localizedDescription)")
                self.restart()
            }
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
        guard FrameGate.accept(sampleBuffer) else { return }
        noteFrameArrived()
        delegate?.captureDidOutput(sampleBuffer)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            Log.warn("\(error.localizedDescription)")
            self.tearDownStream()
            self.delegate?.captureDidStop(error: error)
        }
    }


    private func startStallWatchdog() {
        stallLock.lock()
        lastFrameUptime = ProcessInfo.processInfo.systemUptime
        stallReported = false
        stallLock.unlock()

        guard stallTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.checkStall() }
        stallTimer = timer
        timer.resume()
    }

    private func stopStallWatchdog() {
        stallTimer?.cancel()
        stallTimer = nil
    }

    private func checkStall() {
        guard isRunning else { return }
        let threshold = max(2.0, 3.0 / Double(max(1, currentFPS)))
        stallLock.lock()
        let elapsed = ProcessInfo.processInfo.systemUptime - lastFrameUptime
        let alreadyReported = stallReported
        let shouldReport = elapsed >= threshold && !alreadyReported
        if shouldReport { stallReported = true }
        stallLock.unlock()

        guard shouldReport else { return }
        Log.debug("\(String(format: "%.1f", elapsed))s ")
        delegate?.captureDidStall()
    }

    private func noteFrameArrived() {
        stallLock.lock()
        lastFrameUptime = ProcessInfo.processInfo.systemUptime
        stallReported = false
        stallLock.unlock()
    }


    private func tearDownStream() {
        stopStallWatchdog()
        isRunning = false
        guard let stream else { return }
        self.stream = nil
        try? stream.removeStreamOutput(self, type: .screen)
        stream.stopCapture { error in
            if let error { Log.debug("\(error.localizedDescription)") }
        }
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }
}
