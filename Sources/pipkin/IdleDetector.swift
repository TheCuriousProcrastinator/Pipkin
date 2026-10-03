import CoreMedia
import Foundation

///
final class IdleDetector {

    static let idleFPS = 1

    private let idleSeconds: TimeInterval
    private let sampleEveryNFrames: Int

    private var lastFingerprint: UInt64?
    private var lastChangeUptime: TimeInterval
    private var frameIndex = 0

    private(set) var isIdle = false

    init(idleSeconds: TimeInterval = 3.0, sampleEveryNFrames: Int = 4) {
        self.idleSeconds = max(0.5, idleSeconds)
        self.sampleEveryNFrames = max(1, sampleEveryNFrames)
        self.lastChangeUptime = ProcessInfo.processInfo.systemUptime
    }

    func feed(_ sb: CMSampleBuffer, activeFPS: Int) -> IdleVerdict? {
        frameIndex &+= 1
        let now = ProcessInfo.processInfo.systemUptime

        if !isIdle, sampleEveryNFrames > 1, frameIndex % sampleEveryNFrames != 0 {
            if let dirty = FrameGate.dirtyRectCount(sb), dirty > 0 { lastChangeUptime = now }
            return nil
        }

        guard let fingerprint = FrameGate.fingerprint(sb) else {
            lastChangeUptime = now
            lastFingerprint = nil
            return isIdle ? wake(activeFPS: activeFPS) : nil
        }

        if let last = lastFingerprint, last == fingerprint {
            guard !isIdle, now - lastChangeUptime >= idleSeconds else { return nil }
            isIdle = true
            guard activeFPS > Self.idleFPS else {
                Log.debug(" \(activeFPS) fps")
                return nil
            }
            Log.debug("\(String(format: "%.1f", now - lastChangeUptime))s → \(Self.idleFPS) fps")
            return IdleVerdict(isIdle: true, suggestedFPS: Self.idleFPS)
        }

        lastFingerprint = fingerprint
        lastChangeUptime = now
        return isIdle ? wake(activeFPS: activeFPS) : nil
    }

    func reset() {
        lastFingerprint = nil
        lastChangeUptime = ProcessInfo.processInfo.systemUptime
        frameIndex = 0
        if isIdle { Log.debug("") }
        isIdle = false
    }

    private func wake(activeFPS: Int) -> IdleVerdict {
        isIdle = false
        let fps = min(max(activeFPS, 1), 60)
        Log.debug(" → \(fps) fps")
        return IdleVerdict(isIdle: false, suggestedFPS: fps)
    }
}
