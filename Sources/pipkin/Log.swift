import Foundation

///
enum Log {
    private static let prefix = "[Pipkin]"
    private static let maxLogBytes: UInt64 = 2 * 1024 * 1024
    private static let fileQueue = DispatchQueue(
        label: "com.thecuriousprocrastinator.Pipkin.log", qos: .utility
    )
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS Z"
        return f
    }()

    static let fileURL: URL = {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        return library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Pipkin", isDirectory: true)
            .appendingPathComponent("Pipkin.log")
    }()

    static var filePath: String { fileURL.path }

    private static func emit(_ level: String, _ items: [Any], persist: Bool) {
        let msg = items.map { "\($0)" }.joined(separator: " ")
        let line = "\(prefix)[\(formatter.string(from: Date()))][\(level)] \(msg)"
        print(line)
        guard persist else { return }
        fileQueue.async { appendToFile(line + "\n") }
    }

    private static func appendToFile(_ text: String) {
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try rotateIfNeeded(using: manager)
            if !manager.fileExists(atPath: fileURL.path) {
                try Data().write(to: fileURL, options: .atomic)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        } catch {
        }
    }

    private static func rotateIfNeeded(using manager: FileManager) throws {
        guard let attributes = try? manager.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? NSNumber,
              size.uint64Value >= maxLogBytes else { return }

        let previous = fileURL.deletingPathExtension().appendingPathExtension("previous.log")
        if manager.fileExists(atPath: previous.path) { try manager.removeItem(at: previous) }
        try manager.moveItem(at: fileURL, to: previous)
    }

    static func debug(_ items: Any...) {
        #if DEBUG
        emit("D", items, persist: false)
        #endif
    }

    static func info(_ items: Any...) { emit("I", items, persist: false) }
    static func warn(_ items: Any...) { emit("W", items, persist: true) }
    static func error(_ items: Any...) { emit("E", items, persist: true) }
}
