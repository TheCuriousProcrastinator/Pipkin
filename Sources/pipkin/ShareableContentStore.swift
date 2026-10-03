import AppKit
import ScreenCaptureKit


struct WindowGroup {
    let appName: String
    let bundleID: String?
    let icon: NSImage?
    let windows: [SCWindow]
}


///
///
final class ShareableContentStore: @unchecked Sendable {

    static let shared = ShareableContentStore()

    static let ttl: TimeInterval = 1.0
    static let minWindowSide: CGFloat = 80
    static let minUntitledArea: CGFloat = 200 * 200

    private init() {}


    private let lock = NSLock()
    private var candidatesCache: [SCWindow] = []
    private var allCache: [SCWindow] = []
    private var ownCache: [SCWindow] = []
    private var displaysCache: [SCDisplay] = []
    private var ordinalCache: [CGWindowID: Int] = [:]
    private var lastSuccessUptime: TimeInterval = -.greatestFiniteMagnitude

    private var isFetching = false
    private var pendingCompletions: [(Result<[SCWindow], Error>) -> Void] = []

    private static let ownProcessID: pid_t = ProcessInfo.processInfo.processIdentifier
    private static let ownBundleID: String? = Bundle.main.bundleIdentifier


    var cachedWindows: [SCWindow] {
        let snapshot = withLock { (candidatesCache, isExpiredLocked) }
        if snapshot.1 { refresh() }
        return snapshot.0
    }

    var cachedDisplays: [SCDisplay] {
        let snapshot = withLock { (displaysCache, isExpiredLocked) }
        if snapshot.1 { refresh() }
        return snapshot.0
    }

    var cachedOwnWindows: [SCWindow] {
        let snapshot = withLock { (ownCache, isExpiredLocked) }
        if snapshot.1 { refresh() }
        return snapshot.0
    }

    var isCacheExpired: Bool { withLock { isExpiredLocked } }


    func refresh(completion: ((Result<[SCWindow], Error>) -> Void)? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.refresh(completion: completion) }
            return
        }
        if let completion { pendingCompletions.append(completion) }
        guard !isFetching else { return }
        isFetching = true

        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    true, onScreenWindowsOnly: false
                )
                let snapshot = ContentSnapshot(content)
                DispatchQueue.main.async { self.finishRefresh(.success(snapshot)) }
            } catch {
                DispatchQueue.main.async { self.finishRefresh(.failure(error)) }
            }
        }
    }

    private struct ContentSnapshot: @unchecked Sendable {
        let windows: [SCWindow]
        let displays: [SCDisplay]
        init(_ content: SCShareableContent) {
            windows = content.windows
            displays = content.displays
        }
    }

    private func finishRefresh(_ result: Result<ContentSnapshot, Error>) {
        isFetching = false
        let completions = pendingCompletions
        pendingCompletions.removeAll()

        switch result {
        case let .success(snapshot):
            store(snapshot)
            let windows = withLock { candidatesCache }
            completions.forEach { $0(.success(windows)) }
        case let .failure(error):
            Log.warn("\(error.localizedDescription)")
            completions.forEach { $0(.failure(error)) }
        }
    }

    private func store(_ snapshot: ContentSnapshot) {
        var all: [SCWindow] = []
        var own: [SCWindow] = []
        var candidates: [SCWindow] = []
        var ordinals: [CGWindowID: Int] = [:]
        var counterByPID: [pid_t: Int] = [:]

        for window in snapshot.windows {
            if Self.isOwnWindow(window) {
                own.append(window)
                continue
            }
            all.append(window)
            let pid = window.owningApplication?.processID ?? -1
            let n = (counterByPID[pid] ?? 0) + 1
            counterByPID[pid] = n
            ordinals[window.windowID] = n
            if Self.isCandidate(window) { candidates.append(window) }
        }

        lock.lock()
        allCache = all
        ownCache = own
        candidatesCache = candidates
        displaysCache = snapshot.displays
        ordinalCache = ordinals
        lastSuccessUptime = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }


    func frontmostWindow(completion: @escaping (SCWindow?) -> Void) {
        withFreshCache { [weak self] in
            completion(self?.frontmostWindowFromCache())
        }
    }

    func grouped(completion: @escaping ([WindowGroup]) -> Void) {
        withFreshCache { [weak self] in
            completion(self?.groupsFromCache() ?? [])
        }
    }

    func window(id: CGWindowID, completion: @escaping (SCWindow?) -> Void) {
        withFreshCache { [weak self] in
            completion(self?.lookup(id: id))
        }
    }

    func cachedWindow(id: CGWindowID) -> SCWindow? { lookup(id: id) }

    func rematch(bundleID: String?, appName: String, title: String,
                 completion: @escaping (SCWindow?) -> Void) {
        withFreshCache { [weak self] in
            guard let self else { completion(nil); return }
            let candidates = self.cachedWindows.filter { window in
                guard let app = window.owningApplication else { return false }
                if let bundleID, !bundleID.isEmpty { return app.bundleIdentifier == bundleID }
                return app.applicationName.caseInsensitiveCompare(appName) == .orderedSame
            }
            completion(Self.bestMatch(in: candidates, title: title))
        }
    }

    func display(id: CGDirectDisplayID, completion: @escaping (SCDisplay?) -> Void) {
        withFreshCache { [weak self] in
            completion(self?.cachedDisplays.first { $0.displayID == id })
        }
    }


    func displayTitle(for window: SCWindow) -> String {
        let app = Self.appName(of: window)
        let title = Self.trimmedTitle(of: window)
        if title.isEmpty { return "\(app) – \(fallbackTitle(for: window))" }
        return "\(app) · \(title)"
    }

    func captureSource(for window: SCWindow) -> CaptureSource {
        .window(
            id: window.windowID,
            bundleID: window.owningApplication?.bundleIdentifier,
            appName: Self.appName(of: window),
            title: Self.trimmedTitle(of: window)
        )
    }

    func pixelSize(of window: SCWindow) -> CGSize {
        let frame = window.frame
        guard frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else {
            return .zero
        }
        let scale = Self.backingScale(forTopLeftRect: frame)
        return CGSize(width: frame.width * scale, height: frame.height * scale)
    }

    func backingScale(of window: SCWindow) -> CGFloat {
        Self.backingScale(forTopLeftRect: window.frame)
    }


    private func frontmostWindowFromCache() -> SCWindow? {
        let windows = withLock { candidatesCache }
        var byID: [CGWindowID: SCWindow] = [:]
        for window in windows { byID[window.windowID] = window }

        let orderedIDs = Self.orderedOnScreenWindowIDs()
        let orderedOnScreen = (orderedIDs ?? []).compactMap { byID[$0] }
            .filter(Self.hasMainWindowGeometry)

        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let pid = frontmostPID, pid != Self.ownProcessID {
            let matched = orderedOnScreen.filter { $0.owningApplication?.processID == pid }
            if !matched.isEmpty {
                let screenSizes = NSScreen.screens.map { $0.frame.size }
                if let screenFilling = matched
                    .filter({ Geo.isScreenFillingWindow(size: $0.frame.size, screenSizes: screenSizes) })
                    .max(by: { Self.area($0) < Self.area($1) }) {
                    return screenFilling
                }
                return matched[0]
            }
            if orderedIDs == nil {
                let fallbackMatched = windows.filter {
                    $0.owningApplication?.processID == pid && Self.isMainLike($0)
                }
                let screenSizes = NSScreen.screens.map { $0.frame.size }
                if let screenFilling = fallbackMatched
                    .filter({ Geo.isScreenFillingWindow(size: $0.frame.size, screenSizes: screenSizes) })
                    .max(by: { Self.area($0) < Self.area($1) }) {
                    return screenFilling
                }
                return fallbackMatched.first
            }
            return nil
        }

        if let frontmost = orderedOnScreen.first { return frontmost }
        guard orderedIDs == nil else { return nil }
        return windows.first(where: Self.isMainLike)
    }

    private func groupsFromCache() -> [WindowGroup] {
        let windows = withLock { candidatesCache }.filter { $0.windowLayer == 0 }
        var order: [pid_t] = []
        var byPID: [pid_t: [SCWindow]] = [:]
        for window in windows {
            let pid = window.owningApplication?.processID ?? -1
            if byPID[pid] == nil { order.append(pid) }
            byPID[pid, default: []].append(window)
        }

        let groups: [WindowGroup] = order.compactMap { pid in
            guard let list = byPID[pid], !list.isEmpty else { return nil }
            let sorted = list.sorted { lhs, rhs in
                let a = displayTitle(for: lhs), b = displayTitle(for: rhs)
                let cmp = a.localizedStandardCompare(b)
                return cmp == .orderedSame ? lhs.windowID < rhs.windowID : cmp == .orderedAscending
            }
            let app = list.first?.owningApplication
            return WindowGroup(
                appName: app?.applicationName ?? ("Unknown App"),
                bundleID: app?.bundleIdentifier,
                icon: pid > 0 ? NSRunningApplication(processIdentifier: pid)?.icon : nil,
                windows: sorted
            )
        }
        return groups.sorted { $0.appName.localizedStandardCompare($1.appName) == .orderedAscending }
    }

    private func lookup(id: CGWindowID) -> SCWindow? {
        withLock { allCache.first { $0.windowID == id } }
    }

    private func fallbackTitle(for window: SCWindow) -> String {
        let n = withLock { ordinalCache[window.windowID] } ?? 1
        return "\(("Window")) #\(n)"
    }


    private static func isOwnWindow(_ window: SCWindow) -> Bool {
        guard let app = window.owningApplication else { return false }
        if app.processID == ownProcessID { return true }
        if let ownBundleID, app.bundleIdentifier == ownBundleID { return true }
        return false
    }

    private static func isCandidate(_ window: SCWindow) -> Bool {
        guard window.windowLayer == 0,
              let owner = window.owningApplication,
              owner.processID > 0 else { return false }

        let title = trimmedTitle(of: window)
        guard let runningApp = NSRunningApplication(processIdentifier: owner.processID),
              !runningApp.isTerminated,
              !runningApp.isHidden else { return false }
        switch runningApp.activationPolicy {
        case .regular:
            break
        case .accessory:
            guard window.isOnScreen, !title.isEmpty else { return false }
        case .prohibited:
            return false
        @unknown default:
            guard window.isOnScreen, !title.isEmpty else { return false }
        }

        let frame = window.frame
        guard frame.width.isFinite, frame.height.isFinite else { return false }
        guard frame.width >= minWindowSide, frame.height >= minWindowSide else { return false }
        if !window.isOnScreen, title.isEmpty { return false }
        if title.isEmpty, area(window) < minUntitledArea { return false }
        return true
    }

    private static func isMainLike(_ window: SCWindow) -> Bool {
        window.isOnScreen && hasMainWindowGeometry(window)
    }

    private static func hasMainWindowGeometry(_ window: SCWindow) -> Bool {
        window.windowLayer == 0
            && window.frame.width > minWindowSide
            && window.frame.height > minWindowSide
    }

    private static func orderedOnScreenWindowIDs() -> [CGWindowID]? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        return list.compactMap { info in
            (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
    }

    private static func area(_ window: SCWindow) -> CGFloat {
        max(0, window.frame.width) * max(0, window.frame.height)
    }

    private static func appName(of window: SCWindow) -> String {
        let name = window.owningApplication?.applicationName ?? ""
        return name.isEmpty ? ("Unknown App") : name
    }

    private static func trimmedTitle(of window: SCWindow) -> String {
        (window.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func bestMatch(in candidates: [SCWindow], title: String) -> SCWindow? {
        guard !candidates.isEmpty else { return nil }
        let target = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let largest: ([SCWindow]) -> SCWindow? = { list in
            list.max { area($0) < area($1) }
        }
        guard !target.isEmpty else {
            return candidates.count == 1 ? candidates[0] : nil
        }
        if let hit = largest(candidates.filter { trimmedTitle(of: $0) == target }) { return hit }
        if let hit = largest(candidates.filter {
            let t = trimmedTitle(of: $0)
            return !t.isEmpty && (t.hasPrefix(target) || target.hasPrefix(t))
        }) { return hit }
        if let hit = largest(candidates.filter {
            let t = trimmedTitle(of: $0)
            return !t.isEmpty && (t.contains(target) || target.contains(t))
        }) { return hit }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private static func backingScale(forTopLeftRect rect: CGRect) -> CGFloat {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return 2.0 }
        let centerTopLeft = CGPoint(x: rect.midX, y: rect.midY)
        let center = CGPoint(x: centerTopLeft.x, y: Geo.primaryScreenMaxY - centerTopLeft.y)
        if let hit = screens.first(where: { $0.frame.contains(center) }) {
            return hit.backingScaleFactor
        }
        let appKitRect = CGRect(x: rect.minX, y: Geo.primaryScreenMaxY - rect.maxY,
                               width: rect.width, height: rect.height)
        let best = screens.max { lhs, rhs in
            let a = lhs.frame.intersection(appKitRect)
            let b = rhs.frame.intersection(appKitRect)
            return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
        }
        return best?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
    }


    private var isExpiredLocked: Bool {
        ProcessInfo.processInfo.systemUptime - lastSuccessUptime > Self.ttl
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func withFreshCache(_ body: @escaping () -> Void) {
        if !isCacheExpired {
            if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
            return
        }
        refresh { _ in body() }
    }
}
