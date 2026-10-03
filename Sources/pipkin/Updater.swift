import AppKit
import CryptoKit

struct ReleaseInfo {
    let version: String
    let tag: String
    let dmgURL: URL?
    let sha256URL: URL?
    let pageURL: URL?
}

///
enum Updater {
    static let repo = "TheCuriousProcrastinator/Pipkin"
    private static let appName = "Pipkin"

    static var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    }

    static var isDownloading: Bool { DownloadCoordinator.shared.isDownloading }
    static var downloadPercent: Int? { UpdateProgressWindow.percent }


    static func checkSilently(_ onNewVersion: @escaping (ReleaseInfo) -> Void) {
        fetchLatest { result in
            guard case let .success(info) = result,
                  isNewer(info.version, than: currentVersion) else { return }
            Log.info(" \(info.version) \(currentVersion)")
            onNewVersion(info)
        }
    }

    static func checkInteractive() {
        if isDownloading {
            showDownloadingNotice()
            return
        }
        fetchLatest { result in
            switch result {
            case let .failure(err):
                showAlert(
                    style: .warning,
                    title: ("Update check failed"),
                    message: describe(err)
                )
            case let .success(info):
                if isNewer(info.version, than: currentVersion) {
                    presentUpdate(info)
                } else {
                    showAlert(
                        style: .informational,
                        title: ("You're up to date"),
                        message: ("Current version \(currentVersion)")
                    )
                }
            }
        }
    }

    static func presentUpdate(_ info: ReleaseInfo) {
        if isDownloading {
            showDownloadingNotice()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = ("Version \(info.version) available")
        alert.informativeText = ("You have \(currentVersion). Progress is shown while downloading; the installer window opens "
                + "automatically afterwards — drag the app into Applications to replace it.")
        if info.dmgURL != nil {
            alert.addButton(withTitle: ("Download & install"))
        }
        if info.pageURL != nil {
            alert.addButton(withTitle: ("Release notes"))
        }
        alert.addButton(withTitle: ("Later"))

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        var index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue

        if info.dmgURL != nil {
            if index == 0 {
                startDownload(info)
                return
            }
            index -= 1
        }
        if let page = info.pageURL, index == 0 {
            NSWorkspace.shared.open(page)
        }
    }


    static func startDownload(_ info: ReleaseInfo) {
        guard let dmgURL = info.dmgURL else { return }
        guard !isDownloading else {
            showDownloadingNotice()
            return
        }

        UpdateProgressWindow.show(version: info.version) {
            cancelDownload()
        }

        DownloadCoordinator.shared.start(
            url: dmgURL,
            destinationDirectory: try? updatesDirectory(),
            onProgress: { written, total in
                UpdateProgressWindow.update(bytesWritten: written, totalBytes: total)
            },
            onFinished: { result in
                switch result {
                case let .failure(error):
                    if (error as NSError).code == NSURLErrorCancelled {
                        Log.info("")
                        UpdateProgressWindow.dismiss()
                        return
                    }
                    Log.error("\(describe(error))")
                    UpdateProgressWindow.dismiss()
                    presentFailure(info, error: error)
                case let .success(file):
                    verifyThenOpen(file, info: info)
                }
            }
        )
    }

    static func cancelDownload() {
        DownloadCoordinator.shared.cancel()
        UpdateProgressWindow.dismiss()
    }

    static func startDownloadForProbe(_ info: ReleaseInfo,
                                     onProgress: @escaping (Int64, Int64) -> Void,
                                     onFinished: @escaping (Result<URL, Error>) -> Void) {
        guard let dmgURL = info.dmgURL else {
            onFinished(.failure(makeError("no dmg asset")))
            return
        }
        DownloadCoordinator.shared.start(
            url: dmgURL,
            destinationDirectory: try? updatesDirectory(),
            onProgress: onProgress,
            onFinished: onFinished
        )
    }

    private static func verifyThenOpen(_ file: URL, info: ReleaseInfo) {
        guard let shaURL = info.sha256URL else {
            Log.debug("Release  .sha256 ")
            finish(file, info: info)
            return
        }
        UpdateProgressWindow.update(bytesWritten: 1, totalBytes: 1)
        var req = URLRequest(url: shaURL, timeoutInterval: 20)
        req.setValue(appName, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let expected = data.flatMap { String(data: $0, encoding: .utf8) }?
                .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
                .first
                .map(String.init)?
                .lowercased()

            DispatchQueue.main.async {
                guard let expected, expected.count == 64 else {
                    Log.warn(" SHA256")
                    finish(file, info: info)
                    return
                }
                let actual = (try? sha256(ofFileAt: file))?.lowercased()
                if actual == expected {
                    Log.info("SHA256 ")
                    finish(file, info: info)
                } else {
                    Log.error("SHA256  \(expected)  \(actual ?? "nil")")
                    try? FileManager.default.removeItem(at: file)
                    UpdateProgressWindow.dismiss()
                    presentFailure(info, error: makeError(
                        ("Downloaded file failed checksum verification — please retry")
                    ))
                }
            }
        }.resume()
    }

    private static func finish(_ file: URL, info: ReleaseInfo) {
        cleanupOldPackages(keeping: file)
        UpdateProgressWindow.finish(message: ("Download complete — opening the installer…"))

        if !NSWorkspace.shared.open(file) {
            Log.warn(" DMG  Finder ")
            NSWorkspace.shared.activateFileViewerSelecting([file])
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = ("\(info.version) downloaded")
        alert.informativeText = ("""
            Drag Pipkin into Applications in the window that just opened to replace the old version.

            The running copy can block the replacement — quitting first is recommended.
            """)
        alert.addButton(withTitle: ("Quit Pipkin"))
        alert.addButton(withTitle: ("Quit later"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
    }

    private static func presentFailure(_ info: ReleaseInfo, error: Error) {
        let ns = error as NSError
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = ("Download failed")
        var detail = describe(error)
        if ns.code == NSURLErrorTimedOut || ns.code == NSURLErrorNetworkConnectionLost {
            detail += ("\n\nGitHub downloads can be slow — retry, or use your browser instead.")
        }
        alert.informativeText = detail
        alert.addButton(withTitle: ("Retry"))
        if info.pageURL != nil {
            alert.addButton(withTitle: ("Download in browser"))
        }
        alert.addButton(withTitle: ("Cancel"))

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if index == 0 {
            startDownload(info)
        } else if index == 1, let page = info.pageURL {
            NSWorkspace.shared.open(page)
        }
    }


    static func fetchLatest(_ completion: @escaping (Result<ReleaseInfo, Error>) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            completion(.failure(makeError(("Invalid update URL"))))
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(appName, forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { data, resp, err in
            func done(_ r: Result<ReleaseInfo, Error>) { DispatchQueue.main.async { completion(r) } }
            if let err { done(.failure(err)); return }
            guard let http = resp as? HTTPURLResponse else {
                done(.failure(makeError(("No response")))); return
            }
            guard http.statusCode == 200, let data else {
                done(.failure(makeError("HTTP \(http.statusCode)"))); return
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String else {
                done(.failure(makeError(("Failed to parse release info")))); return
            }
            let page = (obj["html_url"] as? String).flatMap { URL(string: $0) }
            var dmg: URL?
            var sha: URL?
            if let assets = obj["assets"] as? [[String: Any]] {
                for asset in assets {
                    guard let name = asset["name"] as? String,
                          let link = (asset["browser_download_url"] as? String)
                              .flatMap({ URL(string: $0) }) else { continue }
                    if name.hasSuffix(".dmg"), dmg == nil { dmg = link }
                    if name.hasSuffix(".dmg.sha256"), sha == nil { sha = link }
                }
            }
            done(.success(ReleaseInfo(version: normalize(tag), tag: tag,
                                      dmgURL: dmg, sha256URL: sha, pageURL: page)))
        }.resume()
    }

    static func isNewer(_ latest: String, than current: String) -> Bool {
        let a = latest.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }


    private final class DownloadCoordinator: NSObject, URLSessionDownloadDelegate {
        static let shared = DownloadCoordinator()

        private var task: URLSessionDownloadTask?
        private var onProgress: ((Int64, Int64) -> Void)?
        private var onFinished: ((Result<URL, Error>) -> Void)?
        private var destinationDirectory: URL?
        private var movedFile: URL?

        var isDownloading: Bool { task != nil }

        private lazy var session: URLSession = {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 120
            cfg.timeoutIntervalForResource = 1800
            cfg.waitsForConnectivity = true
            cfg.allowsExpensiveNetworkAccess = true
            cfg.httpAdditionalHeaders = ["User-Agent": Updater.appName]
            return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        }()

        var sessionDescription: String {
            " \(Int(session.configuration.timeoutIntervalForRequest))s"
                + " \(Int(session.configuration.timeoutIntervalForResource))s"
                + " \(session.configuration.waitsForConnectivity)"
        }

        func start(url: URL, destinationDirectory: URL?,
                   onProgress: @escaping (Int64, Int64) -> Void,
                   onFinished: @escaping (Result<URL, Error>) -> Void) {
            cancel()
            self.onProgress = onProgress
            self.onFinished = onFinished
            self.destinationDirectory = destinationDirectory
            self.movedFile = nil
            let task = session.downloadTask(with: url)
            self.task = task
            Log.info("\(url.lastPathComponent)\(sessionDescription)")
            task.resume()
        }

        func cancel() {
            task?.cancel()
            task = nil
            onProgress = nil
            onFinished = nil
        }

        // MARK: URLSessionDownloadDelegate

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            let callback = onProgress
            DispatchQueue.main.async {
                callback?(totalBytesWritten, totalBytesExpectedToWrite)
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            guard let directory = destinationDirectory else {
                movedFile = nil
                return
            }
            let name = downloadTask.originalRequest?.url?.lastPathComponent ?? "\(Updater.appName).dmg"
            let dest = directory.appendingPathComponent(
                name.hasSuffix(".dmg") ? name : "\(Updater.appName).dmg"
            )
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.moveItem(at: location, to: dest)
                movedFile = dest
            } catch {
                Log.error("\(error.localizedDescription)")
                movedFile = nil
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let finished = onFinished
            let file = movedFile
            self.task = nil
            onProgress = nil
            onFinished = nil
            movedFile = nil

            DispatchQueue.main.async {
                if let error {
                    finished?(.failure(error))
                } else if let file {
                    finished?(.success(file))
                } else {
                    finished?(.failure(Updater.makeError(
                        ("Downloaded but could not save the file")
                    )))
                }
            }
        }
    }


    static func updatesDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("\(appName)/Updates", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cleanupOldPackages(keeping keep: URL) {
        guard let dir = try? updatesDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(
                  at: dir, includingPropertiesForKeys: nil) else { return }
        for file in files where file != keep && file.pathExtension == "dmg" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static var downloadSessionDescription: String { DownloadCoordinator.shared.sessionDescription }

    private static func normalize(_ tag: String) -> String {
        var s = tag
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        return s
    }

    static func makeError(_ msg: String) -> NSError {
        NSError(domain: "Updater", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == "Updater" { return ns.localizedDescription }
        return "\(ns.localizedDescription)\(ns.domain) \(ns.code)"
    }

    private static func showDownloadingNotice() {
        let percentText = downloadPercent.map { "\($0)%" } ?? ("in progress")
        showAlert(
            style: .informational,
            title: ("Update is downloading"),
            message: ("\(percentText) done — check or cancel it in the progress panel.")
        )
    }

    private static func showAlert(style: NSAlert.Style, title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: ("OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
