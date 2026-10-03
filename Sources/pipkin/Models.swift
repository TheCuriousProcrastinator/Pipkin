import AppKit
import CoreMedia
import Foundation


enum CaptureSource: Equatable {
    case window(id: CGWindowID, bundleID: String?, appName: String, title: String)
    case region(displayID: CGDirectDisplayID, rect: CGRect)

    var preferenceKey: String {
        switch self {
        case let .window(_, bundleID, appName, _): return bundleID ?? "app:\(appName)"
        case .region: return Self.regionPreferenceKey
        }
    }

    static let regionPreferenceKey = "__region__"

    var windowID: CGWindowID? {
        if case let .window(id, _, _, _) = self { return id }
        return nil
    }

    var appName: String {
        switch self {
        case let .window(_, _, appName, _): return appName
        case .region: return ("Screen Region")
        }
    }

    var title: String {
        switch self {
        case let .window(_, _, _, title): return title
        case let .region(_, rect):
            return "\(Int(rect.width))×\(Int(rect.height))"
        }
    }

    var displayTitle: String {
        let t = title
        return t.isEmpty ? appName : "\(appName) · \(t)"
    }
}


///
enum PositionMemoryIdentity: Equatable {
    case window(appPreferenceKey: String, windowID: CGWindowID)
    case windowRegion(appPreferenceKey: String, windowID: CGWindowID, rect: CGRect)
    case displayRegion(displayID: CGDirectDisplayID, rect: CGRect)

    static let specificPreferencePrefix = "__window_position__:"

    var preferenceKey: String {
        switch self {
        case let .window(appKey, windowID):
            return "\(Self.specificPreferencePrefix)\(appKey):\(windowID)"
        case let .windowRegion(appKey, windowID, rect):
            return "\(Self.specificPreferencePrefix)region:\(appKey):\(windowID):\(Self.rectKey(rect))"
        case let .displayRegion(displayID, rect):
            return "\(Self.specificPreferencePrefix)display:\(displayID):\(Self.rectKey(rect))"
        }
    }

    var fallbackPreferenceKey: String {
        switch self {
        case let .window(appKey, _), let .windowRegion(appKey, _, _): return appKey
        case .displayRegion: return CaptureSource.regionPreferenceKey
        }
    }

    func retargetingWindow(to source: CaptureSource) -> PositionMemoryIdentity {
        guard case let .window(windowID, _, _, _) = source else { return self }
        switch self {
        case .window:
            return .window(appPreferenceKey: source.preferenceKey, windowID: windowID)
        case let .windowRegion(_, _, rect):
            return .windowRegion(
                appPreferenceKey: source.preferenceKey, windowID: windowID, rect: rect
            )
        case .displayRegion:
            return self
        }
    }

    static func isSpecificPreferenceKey(_ key: String) -> Bool {
        key.hasPrefix(specificPreferencePrefix)
    }

    private static func rectKey(_ rect: CGRect) -> String {
        [rect.minX, rect.minY, rect.width, rect.height]
            .map { String(Int(($0 * 16).rounded())) }
            .joined(separator: ",")
    }
}


enum FPSStep: Int, CaseIterable {
    case one = 1, five = 5, ten = 10, fifteen = 15, thirty = 30, sixty = 60

    var label: String { "\(rawValue) fps" }

    func next() -> FPSStep {
        let all = FPSStep.allCases
        let idx = all.firstIndex(of: self) ?? 3
        return all[(idx + 1) % all.count]
    }

    static func nearest(to value: Int) -> FPSStep {
        allCases.min { abs($0.rawValue - value) < abs($1.rawValue - value) } ?? .fifteen
    }
}

enum WindowLevelMode: String, CaseIterable {
    case global
    case normal

    static let globalLevel = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)

    var windowLevel: NSWindow.Level {
        switch self {
        case .global: return Self.globalLevel
        case .normal: return .floating
        }
    }

    var collectionBehavior: NSWindow.CollectionBehavior {
        switch self {
        case .global: return [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        case .normal: return [.managed, .fullScreenAuxiliary]
        }
    }

    var label: String {
        switch self {
        case .global: return ("Global (all Spaces, above full-screen)")
        case .normal: return ("Normal (current Space only)")
        }
    }
}

struct PiPSessionState {
    var source: CaptureSource
    var zoom: CGFloat = 1.0
    var anchor: CGPoint = CGPoint(x: 0.5, y: 0.5)
    var hasSelectionCrop: Bool = false
    var fps: FPSStep = .fifteen
    var autoHide: Bool = false
    var idleDetection: Bool = true
    var isPaused: Bool = false
    var isHidden: Bool = false

    static let minZoom: CGFloat = 1.0
    static let maxZoom: CGFloat = 20.0
}

struct SessionRequest {
    var source: CaptureSource
    var positionIdentity: PositionMemoryIdentity
    var baseSourceRect: CGRect
    var sourcePixelSize: CGSize
    var sourcePointSize: CGSize
    var fps: FPSStep
    var autoHide: Bool
    var idleDetection: Bool
}


struct IdleVerdict {
    var isIdle: Bool
    var suggestedFPS: Int
}


enum SessionRuntimeState: Equatable {
    case streaming
    case paused
    case sourceOffscreen
    case minimized
    case waitingForSource
    case reconnecting(attempt: Int)
    case sourceLost
    case permissionDenied
    case failed(message: String)
}

//

protocol CaptureEngineDelegate: AnyObject {
    func captureDidOutput(_ sampleBuffer: CMSampleBuffer)
    func captureWillRestart()
    func captureDidStop(error: Error?)
    func captureDidStall()
}

protocol PiPWindowDelegate: AnyObject {
    var currentSessionState: PiPSessionState { get }

    func pipRequestClose()
    func pipRequestZoom(_ zoom: CGFloat, anchor: CGPoint)
    func pipRequestSelection(_ normalizedRect: CGRect)
    func pipRequestPan(by delta: CGSize)
    func pipRequestZoomReset()
    func pipWillStartLiveResize()
    func pipDidEndLiveResize()
    func pipDidResize(pointSize: CGSize, scale: CGFloat)
    func pipRequestFPS(_ fps: FPSStep)
    func pipRequestToggleAutoHide()
    func pipRequestAutoHideOpacity(_ opacity: CGFloat)
    func pipRequestToggleIdleDetection()
    func pipRequestTogglePause()
    func pipRequestActivateSource()
    func pipRequestToggleClickToActivate()
    func pipRendererRecoveryExhausted()
    func pipRendererDidRecover()
    func pipMenuWillOpen()
    func pipResolveDragFrame(_ proposedFrame: CGRect,
                             modifierFlags: NSEvent.ModifierFlags) -> CGRect
    func pipDidMove()
}
