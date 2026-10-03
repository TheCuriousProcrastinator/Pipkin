import AppKit
import Darwin

///
enum SourceAppCompatibility {
    struct Profile: Equatable {
        let bundleID: String
        let appName: String
        let launchArguments: [String]
        let isVerified: Bool
    }

    struct RuntimeStatus: Equatable {
        let appName: String
        let pid: pid_t
        let isCompatible: Bool
    }

    struct BundleSignature: Equatable {
        let hasElectronFramework: Bool
        let hasElectronAsar: Bool
        let hasRendererHelper: Bool
        let hasResourcesPak: Bool
        let hasICUData: Bool
    }

    enum RelaunchDecision: Equatable {
        case skip
        case ask
        case relaunch
    }

    static func relaunchDecision(
        mode: ChromiumCompatibilityMode,
        isVerified: Bool
    ) -> RelaunchDecision {
        switch mode {
        case .off: return .skip
        case .ask: return .ask
        case .automatic: return isVerified ? .relaunch : .ask
        }
    }

    enum RestartError: LocalizedError {
        case applicationURLUnavailable
        case terminationRejected
        case terminationTimedOut
        case launchFailed(String)
        case compatibilityArgumentsNotApplied

        var errorDescription: String? {
            switch self {
            case .applicationURLUnavailable:
                return ("Could not locate the source application")
            case .terminationRejected:
                return ("The source application refused to quit")
            case .terminationTimedOut:
                return ("Timed out waiting for the source application to quit")
            case let .launchFailed(message):
                return message
            case .compatibilityArgumentsNotApplied:
                return ("The source app relaunched, but the Chromium compatibility argument was not applied")
            }
        }
    }

    private static let compatibilityArguments = ["--disable-backgrounding-occluded-windows"]

    private static let verifiedProfiles: [Profile] = [
        Profile(
            bundleID: "com.openai.codex",
            appName: "ChatGPT",
            launchArguments: compatibilityArguments,
            isVerified: true
        ),
        Profile(
            bundleID: "com.google.Chrome",
            appName: "Google Chrome",
            launchArguments: compatibilityArguments,
            isVerified: true
        ),
    ]

    private static var chromiumDetectionCache: [String: Bool] = [:]

    static var verifiedAppNames: [String] { verifiedProfiles.map(\.appName) }

    static func verifiedRuntimeStatuses() -> [RuntimeStatus] {
        verifiedProfiles.compactMap { profile in
            guard let application = NSRunningApplication.runningApplications(
                withBundleIdentifier: profile.bundleID
            ).first(where: { !$0.isTerminated }) else { return nil }
            let pid = application.processIdentifier
            return RuntimeStatus(
                appName: profile.appName,
                pid: pid,
                isCompatible: isKnownCompatibilityLaunch(profile, pid: pid)
            )
        }
    }

    static func profile(for bundleID: String?) -> Profile? {
        guard let bundleID else { return nil }
        return verifiedProfiles.first { $0.bundleID == bundleID }
    }

    static func profile(for application: NSRunningApplication) -> Profile? {
        guard let bundleID = application.bundleIdentifier else { return nil }
        if let verified = profile(for: bundleID) { return verified }
        guard let bundleURL = application.bundleURL,
              isChromiumLikeBundle(bundleURL, cacheKey: bundleID) else { return nil }
        return Profile(
            bundleID: bundleID,
            appName: application.localizedName
                ?? bundleURL.deletingPathExtension().lastPathComponent,
            launchArguments: compatibilityArguments,
            isVerified: false
        )
    }

    static func isChromiumLike(_ signature: BundleSignature) -> Bool {
        if signature.hasElectronFramework || signature.hasElectronAsar { return true }
        return signature.hasRendererHelper && signature.hasResourcesPak && signature.hasICUData
    }

    ///
    private static let bundleScanEntryLimit = 4000

    private static func isChromiumLikeBundle(_ bundleURL: URL, cacheKey: String) -> Bool {
        if let cached = chromiumDetectionCache[cacheKey] { return cached }
        let fm = FileManager.default
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let frameworks = contents.appendingPathComponent("Frameworks", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        let electronFramework = frameworks.appendingPathComponent("Electron Framework.framework")
        let electronAsar = resources.appendingPathComponent("electron.asar")

        var rendererHelper = false
        var resourcesPak = false
        var icuData = false
        if let enumerator = fm.enumerator(
            at: frameworks,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            var visited = 0
            for case let url as URL in enumerator {
                visited += 1
                switch url.lastPathComponent {
                case let name where name.hasSuffix("Helper (Renderer).app"):
                    rendererHelper = true
                case "resources.pak":
                    resourcesPak = true
                case "icudtl.dat":
                    icuData = true
                default:
                    break
                }
                if rendererHelper && resourcesPak && icuData { break }
                if visited >= bundleScanEntryLimit {
                    Log.debug("Chromium  \(bundleScanEntryLimit)")
                    break
                }
            }
        }

        let signature = BundleSignature(
            hasElectronFramework: fm.fileExists(atPath: electronFramework.path),
            hasElectronAsar: fm.fileExists(atPath: electronAsar.path),
            hasRendererHelper: rendererHelper,
            hasResourcesPak: resourcesPak,
            hasICUData: icuData
        )
        let result = isChromiumLike(signature)
        chromiumDetectionCache[cacheKey] = result
        return result
    }

    ///
    static func isKnownCompatibilityLaunch(_ profile: Profile, pid: pid_t) -> Bool {
        let defaults = UserDefaults.standard
        let key = compatibilityPIDKey(profile.bundleID)
        let legacyKey = legacyCompatibilityPIDKey(profile.bundleID)

        let hasArguments = processHasCompatibilityArguments(pid: pid, profile: profile)
        if hasArguments {
            defaults.set(Int(pid), forKey: key)
            defaults.removeObject(forKey: legacyKey)
            return true
        }

        if defaults.integer(forKey: key) == Int(pid) {
            defaults.removeObject(forKey: key)
        }
        if defaults.integer(forKey: legacyKey) == Int(pid) {
            defaults.removeObject(forKey: legacyKey)
        }
        return false
    }

    static func compatibleRunningApplication(_ profile: Profile) -> NSRunningApplication? {
        for application in NSRunningApplication.runningApplications(withBundleIdentifier: profile.bundleID)
            where !application.isTerminated {
            if isKnownCompatibilityLaunch(profile, pid: application.processIdentifier) {
                return application
            }
        }
        return nil
    }

    static func restart(
        application: NSRunningApplication,
        profile: Profile,
        completion: @escaping (Result<NSRunningApplication, Error>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let bundleURL = application.bundleURL else {
            completion(.failure(RestartError.applicationURLUnavailable))
            return
        }

        let oldPID = application.processIdentifier
        let launchArguments = launchArgumentsByAppendingCompatibility(
            processArguments: processArguments(pid: oldPID),
            compatibilityArguments: profile.launchArguments
        )
        guard application.terminate() else {
            completion(.failure(RestartError.terminationRejected))
            return
        }

        waitForTermination(pid: oldPID, deadline: .now() + 8) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-na", bundleURL.path, "--args"] + launchArguments
            do {
                try process.run()
            } catch {
                completion(.failure(RestartError.launchFailed(error.localizedDescription)))
                return
            }
            waitForStableCompatibleApplication(
                profile: profile,
                deadline: .now() + 12,
                candidatePID: nil,
                stableTicks: 0,
                completion: completion
            )
        } onTimeout: {
            completion(.failure(RestartError.terminationTimedOut))
        }
    }

    private static func waitForStableCompatibleApplication(
        profile: Profile,
        deadline: DispatchTime,
        candidatePID: pid_t?,
        stableTicks: Int,
        completion: @escaping (Result<NSRunningApplication, Error>) -> Void
    ) {
        if let application = compatibleRunningApplication(profile) {
            let pid = application.processIdentifier
            let ticks = pid == candidatePID ? stableTicks + 1 : 1
            if ticks >= 4 {
                UserDefaults.standard.set(Int(pid), forKey: compatibilityPIDKey(profile.bundleID))
                Log.debug("Chromium \(profile.appName) pid=\(pid)")
                completion(.success(application))
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                waitForStableCompatibleApplication(
                    profile: profile,
                    deadline: deadline,
                    candidatePID: pid,
                    stableTicks: ticks,
                    completion: completion
                )
            }
            return
        }

        guard DispatchTime.now() < deadline else {
            completion(.failure(RestartError.compatibilityArgumentsNotApplied))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            waitForStableCompatibleApplication(
                profile: profile,
                deadline: deadline,
                candidatePID: nil,
                stableTicks: 0,
                completion: completion
            )
        }
    }

    private static func processHasCompatibilityArguments(pid: pid_t, profile: Profile) -> Bool {
        guard let arguments = processArguments(pid: pid) else { return false }
        return profile.launchArguments.allSatisfy(arguments.contains)
    }

    static func launchArgumentsByAppendingCompatibility(
        processArguments: [String]?,
        compatibilityArguments: [String]
    ) -> [String] {
        var result = processArguments.map { Array($0.dropFirst()) } ?? []
        for argument in compatibilityArguments where !result.contains(argument) {
            result.append(argument)
        }
        return result
    }

    static func processArguments(pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: size_t = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return nil }

        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &bytes, &size, nil, 0) == 0 else { return nil }
        if size < bytes.count { bytes.removeSubrange(size..<bytes.count) }
        return parseProcessArgumentsBuffer(bytes)
    }

    static func parseProcessArgumentsBuffer(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count >= MemoryLayout<Int32>.size else { return nil }
        let argc: Int32 = bytes.withUnsafeBytes { raw in
            raw.loadUnaligned(as: Int32.self)
        }
        guard argc > 0, argc < 4096 else { return nil }

        var index = MemoryLayout<Int32>.size
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }

        var result: [String] = []
        result.reserveCapacity(Int(argc))
        while index < bytes.count, result.count < Int(argc) {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            guard index > start else { break }
            let slice = bytes[start..<index]
            guard let value = String(bytes: slice, encoding: .utf8) else { return nil }
            result.append(value)
            while index < bytes.count, bytes[index] == 0 { index += 1 }
        }
        return result.count == Int(argc) ? result : nil
    }

    private static func waitForTermination(
        pid: pid_t,
        deadline: DispatchTime,
        completion: @escaping () -> Void,
        onTimeout: @escaping () -> Void
    ) {
        if NSRunningApplication(processIdentifier: pid) == nil {
            completion()
            return
        }
        guard DispatchTime.now() < deadline else {
            onTimeout()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            waitForTermination(
                pid: pid,
                deadline: deadline,
                completion: completion,
                onTimeout: onTimeout
            )
        }
    }

    private static func compatibilityPIDKey(_ bundleID: String) -> String {
        "chromiumCompatibility.pid.\(bundleID)"
    }

    private static func legacyCompatibilityPIDKey(_ bundleID: String) -> String {
        "sourceCompatibility.pid.\(bundleID)"
    }
}
