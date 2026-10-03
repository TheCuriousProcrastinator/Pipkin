import AppKit

struct HoverState: Equatable {
    var isHovering: Bool
    var isOverHotZone: Bool
    var isOverResizeZone: Bool
    var optionHeld: Bool
    var commandHeld: Bool

    static let none = HoverState(
        isHovering: false,
        isOverHotZone: false,
        isOverResizeZone: false,
        optionHeld: false,
        commandHeld: false
    )
}

enum AutoHideHoverIntent: Equatable {
    case leave
    case resize
    case bar
    case command
    case option
    case fade
}

func autoHideHoverIntent(for state: HoverState) -> AutoHideHoverIntent {
    guard state.isHovering else { return .leave }
    if state.commandHeld { return .command }
    if state.optionHeld { return .option }
    if state.isOverResizeZone { return .resize }
    if state.isOverHotZone { return .bar }
    return .fade
}

func isInResizeHotZone(point: CGPoint, frame: CGRect, thickness: CGFloat) -> Bool {
    guard frame.width > 1, frame.height > 1, thickness > 0 else { return false }
    let expanded = frame.insetBy(dx: -thickness, dy: -thickness)
    guard expanded.contains(point) else { return false }

    let distance = min(
        abs(point.x - frame.minX), abs(point.x - frame.maxX),
        abs(point.y - frame.minY), abs(point.y - frame.maxY)
    )
    return distance <= thickness
}

///
final class HoverMonitor {
    static let shared = HoverMonitor()

    private struct Entry {
        let frameProvider: () -> CGRect?
        let hotZoneProvider: () -> CGRect?
        let resizeZoneThicknessProvider: () -> CGFloat
        let onChange: (HoverState) -> Void
        var lastState: HoverState
    }

    private var entries: [UUID: Entry] = [:]
    private var timer: Timer?
    private(set) var hoveredID: UUID?

    var interval: TimeInterval = 0.1

    private init() {}

    var mouseLocation: CGPoint { NSEvent.mouseLocation }


    /// - Parameters:
    func register(id: UUID, frameProvider: @escaping () -> CGRect?,
                  hotZoneProvider: @escaping () -> CGRect? = { nil },
                  resizeZoneThicknessProvider: @escaping () -> CGFloat = { 0 },
                  onChange: @escaping (HoverState) -> Void) {
        entries[id] = Entry(
            frameProvider: frameProvider,
            hotZoneProvider: hotZoneProvider,
            resizeZoneThicknessProvider: resizeZoneThicknessProvider,
            onChange: onChange,
            lastState: .none
        )
        startIfNeeded()
    }

    func currentState(for id: UUID) -> HoverState { entries[id]?.lastState ?? .none }

    func unregister(id: UUID) {
        entries.removeValue(forKey: id)
        if hoveredID == id { hoveredID = nil }
        stopIfIdle()
    }

    func currentHovered() -> UUID? { hoveredID }


    private func startIfNeeded() {
        guard timer == nil, !entries.isEmpty else { return }
        let t = Timer(timeInterval: interval, target: self, selector: #selector(tick),
                      userInfo: nil, repeats: true)
        t.tolerance = interval / 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Log.debug("HoverMonitor  \(interval)s")
    }

    private func stopIfIdle() {
        guard entries.isEmpty else { return }
        timer?.invalidate()
        timer = nil
        Log.debug("HoverMonitor ")
    }

    @objc private func tick() {
        let mouse = NSEvent.mouseLocation
        let modifiers = NSEvent.modifierFlags
        let optionHeld = modifiers.contains(.option)
        let commandHeld = modifiers.contains(.command)

        var hit: (id: UUID, area: CGFloat)?
        var resizeHits: [UUID: Bool] = [:]
        for (id, entry) in entries {
            guard let frame = entry.frameProvider() else { continue }
            let resizeHit = isInResizeHotZone(
                point: mouse,
                frame: frame,
                thickness: max(0, entry.resizeZoneThicknessProvider())
            )
            resizeHits[id] = resizeHit
            guard frame.contains(mouse) || resizeHit else { continue }
            let area = frame.width * frame.height
            if hit == nil || area < hit!.area { hit = (id, area) }
        }
        hoveredID = hit?.id

        for (id, entry) in entries {
            let hovering = id == hoveredID
            let overHotZone = hovering && (entry.hotZoneProvider()?.contains(mouse) ?? false)
            let state = HoverState(
                isHovering: hovering,
                isOverHotZone: overHotZone,
                isOverResizeZone: hovering && (resizeHits[id] ?? false),
                optionHeld: hovering ? optionHeld : false,
                commandHeld: hovering ? commandHeld : false
            )
            guard state != entry.lastState else { continue }
            entries[id]?.lastState = state
            entry.onChange(state)
        }
    }
}
