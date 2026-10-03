import AppKit
import CoreMedia
import ScreenCaptureKit

///
enum SelfTest {

    static func shouldRun() -> Bool {
        CommandLine.arguments.contains("--selftest") || CommandLine.arguments.contains("--diagnose")
    }

    static func run() -> Int32 {
        #if DEBUG
        Geo.runSelfChecks()
        print("")
        #endif
        print("Pipkin  v\(Updater.currentVersion)")
        print("\(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("\(machineArch())")
        print("", NSScreen.screens.map {
            "\(Int($0.frame.width))×\(Int($0.frame.height))@\($0.backingScaleFactor)x"
        }.joined(separator: ", "))
        print("\(Permissions.hasScreenRecording ? "" : "")")
        print("\(Permissions.hasAccessibility ? "" : "")")

        guard Permissions.hasScreenRecording else {
            print("→ ")
            print("   →  →  App ")
            return 2
        }

        var windows: [SCWindow] = []
        var enumerateDone = false
        ShareableContentStore.shared.refresh { result in
            if case let .success(list) = result { windows = list }
            enumerateDone = true
        }
        let enumerateDeadline = Date().addingTimeInterval(8)
        while !enumerateDone, Date() < enumerateDeadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        guard enumerateDone else {
            print("→ ")
            return 3
        }
        print("\(windows.count) ")
        let normalLayer = windows.filter { $0.windowLayer == 0 }
        let pool = normalLayer.isEmpty ? windows : normalLayer
        guard let target = pool.max(by: {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }) else {
            print("→ ")
            return 0
        }
        let title = ShareableContentStore.shared.displayTitle(for: target)
        print("\(title) [\(Int(target.frame.width))×\(Int(target.frame.height))]")

        let engine = CaptureEngine()
        let probe = FrameProbe()
        engine.delegate = probe
        let config = CaptureEngine.makeConfiguration(
            sourceRect: CGRect(origin: .zero, size: target.frame.size),
            pointSize: target.frame.size,
            scale: 1,
            fps: 15,
            showsCursor: false
        )
        do {
            try engine.start(filter: CaptureEngine.filter(for: target), configuration: config)
        } catch {
            print("→ \(error.localizedDescription)")
            return 4
        }
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline, probe.frameCount < 10 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        engine.stop()

        print("\(probe.frameCount) 2  / 15fps")
        if let size = probe.lastPixelSize {
            print("\(Int(size.width))×\(Int(size.height))")
        }
        if probe.frameCount == 0 {
            print("→ ")
            return 5
        }
        print("")
        return 0
    }

    private static func machineArch() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}

private final class FrameProbe: CaptureEngineDelegate {
    private let lock = NSLock()
    private var frames = 0
    private var size: CGSize?

    var frameCount: Int { lock.lock(); defer { lock.unlock() }; return frames }
    var lastPixelSize: CGSize? { lock.lock(); defer { lock.unlock() }; return size }

    func captureWillRestart() {}

    func captureDidOutput(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        frames += 1
        if let px = sampleBuffer.imageBuffer {
            size = CGSize(width: CVPixelBufferGetWidth(px), height: CVPixelBufferGetHeight(px))
        }
        lock.unlock()
    }

    func captureDidStop(error: Error?) {
        if let error { print("\(error.localizedDescription)") }
    }

    func captureDidStall() { print("") }
}
