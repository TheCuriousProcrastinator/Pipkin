import Foundation

///
///
///
struct RendererStallMonitor {

    enum RecoveryAction: Equatable {
        case none
        case flush
        case rebuildLayer
        case restartCapture
    }

    private enum Phase: Equatable {
        case healthy
        case waiting(since: TimeInterval)
        case flushed(since: TimeInterval)
        case rebuilt(since: TimeInterval)
        case exhausted
    }

    let timeout: TimeInterval

    private var phase: Phase = .healthy
    private(set) var stallStartedAt: TimeInterval?

    init(timeout: TimeInterval) {
        self.timeout = max(0.25, timeout)
    }

    var isTrackingStall: Bool { phase != .healthy }

    mutating func observeReady(at now: TimeInterval) -> TimeInterval? {
        guard let started = stallStartedAt else {
            phase = .healthy
            return nil
        }
        let duration = max(0, now - started)
        reset()
        return duration
    }

    mutating func observeNotReady(at now: TimeInterval) -> RecoveryAction {
        switch phase {
        case .healthy:
            stallStartedAt = now
            phase = .waiting(since: now)
            return .none

        case let .waiting(since):
            guard elapsed(since, now) >= timeout else { return .none }
            phase = .flushed(since: now)
            return .flush

        case let .flushed(since):
            guard elapsed(since, now) >= timeout else { return .none }
            phase = .rebuilt(since: now)
            return .rebuildLayer

        case let .rebuilt(since):
            guard elapsed(since, now) >= timeout else { return .none }
            phase = .exhausted
            return .restartCapture

        case .exhausted:
            return .none
        }
    }

    mutating func requestImmediateFlush(at now: TimeInterval) -> RecoveryAction {
        switch phase {
        case .healthy, .waiting:
            if stallStartedAt == nil { stallStartedAt = now }
            phase = .flushed(since: now)
            return .flush
        case .flushed, .rebuilt, .exhausted:
            return .none
        }
    }

    mutating func reset() {
        phase = .healthy
        stallStartedAt = nil
    }

    private func elapsed(_ since: TimeInterval, _ now: TimeInterval) -> TimeInterval {
        max(0, now - since)
    }
}
