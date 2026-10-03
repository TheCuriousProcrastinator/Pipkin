import Foundation

/// Pure lifecycle decision input. System queries should populate this object; policy must stay testable.
struct SourceWindowObservation: Equatable {
    let cgWindowExists: Bool?
    let processAlive: Bool?
    let ownerPIDMatches: Bool?
    let isOnScreen: Bool?
    let axMinimized: Bool?
}

enum SourceWindowHealth: Equatable {
    case onScreen
    case offScreenAlive
    case minimized
    case missing
    case unknown
}

/// Conservative source-window lifecycle classifier.
/// Unknown states intentionally preserve PiP rather than closing it.
func classifySourceWindowHealth(_ observation: SourceWindowObservation) -> SourceWindowHealth {
    if observation.processAlive == false {
        return .missing
    }
    if observation.ownerPIDMatches == false {
        return .missing
    }
    if observation.axMinimized == true {
        return .minimized
    }
    if observation.cgWindowExists == true {
        if observation.isOnScreen == true {
            return .onScreen
        }
        if observation.axMinimized == false || observation.processAlive == true {
            return .offScreenAlive
        }
    }
    if observation.cgWindowExists == false {
        return .missing
    }
    return .unknown
}
