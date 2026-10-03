import Foundation

struct RendererIncidentTiming: Equatable {
    let stallDuration: TimeInterval
    let recoveryDuration: TimeInterval

    init(stallStartedAt: TimeInterval?, detectedAt: TimeInterval?, recoveredAt: TimeInterval,
         lastPhaseDuration: TimeInterval) {
        stallDuration = stallStartedAt.map { max(0, recoveredAt - $0) }
            ?? max(0, lastPhaseDuration)
        recoveryDuration = detectedAt.map { max(0, recoveredAt - $0) } ?? 0
    }
}

///
struct RendererDiagnostics {

    struct Event: Equatable {
        let uptime: TimeInterval
        let message: String
    }

    let capacity: Int
    private(set) var events: [Event] = []

    init(capacity: Int = 64) {
        self.capacity = max(1, capacity)
    }

    mutating func record(_ message: String, at uptime: TimeInterval) {
        events.append(Event(uptime: uptime, message: Self.singleLine(message)))
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
    }

    func incidentReport(id: String, label: String, at now: TimeInterval,
                        trigger: String, snapshot: String) -> String {
        let safeID = Self.singleLine(id, limit: 64)
        let safeLabel = Self.singleLine(label, limit: 512)
        let safeTrigger = Self.singleLine(trigger)
        let safeSnapshot = Self.singleLine(snapshot)
        let history: String
        if events.isEmpty {
            history = "  (no recent events)"
        } else {
            history = events.map { event in
                let offset = event.uptime - now
                return String(format: "  %+.3fs  %@", offset, event.message)
            }.joined(separator: "\n")
        }

        return """
        renderer incident \(safeID)
          source: \(safeLabel)
          trigger: \(safeTrigger)
          snapshot: \(safeSnapshot)
          recent events (oldest first):
        \(history)
        """
    }

    private static func singleLine(_ value: String, limit: Int = 2_048) -> String {
        let flattened = value.components(separatedBy: .newlines).joined(separator: " ")
        return String(flattened.prefix(limit))
    }
}
