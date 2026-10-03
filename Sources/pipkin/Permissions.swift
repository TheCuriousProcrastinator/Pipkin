import AppKit
import CoreGraphics
import ScreenCaptureKit

enum Permissions {


    private final class ScreenRecordingRequestState: @unchecked Sendable {
        private let lock = NSLock()
        private var didRequest = false

        func beginRequestIfNeeded() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !didRequest else { return false }
            didRequest = true
            return true
        }
    }

    private static let screenRecordingRequestState = ScreenRecordingRequestState()

    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    ///
    @discardableResult
    private static func primeRegistration() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        Task.detached(priority: .utility) {
            _ = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        }
        return granted
    }

    ///
    @discardableResult
    static func ensureScreenRecording() -> Bool {
        if hasScreenRecording { return true }
        if screenRecordingRequestState.beginRequestIfNeeded() {
            _ = primeRegistration()
            return hasScreenRecording
        }
        showScreenRecordingGuide()
        return false
    }

    static func showScreenRecordingGuide() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = ("Screen Recording permission required")
        alert.informativeText = ("""
            Pipkin mirrors windows via the system ScreenCaptureKit framework, which requires the \
            "Screen & System Audio Recording" permission.

            1. Open System Settings → Privacy & Security → Screen & System Audio Recording
            2. Find Pipkin in the list and turn the switch on
            3. Relaunch Pipkin (macOS only applies the grant after a restart)

            If Pipkin is already listed and switched on, the entry is a stale record left by an \
            older build: click "Reset permission record", then relaunch — no need to remove it manually.

            Frames stay in local memory and are never saved or uploaded.
            """)
        alert.addButton(withTitle: ("Open System Settings"))
        alert.addButton(withTitle: ("Reset permission record"))
        alert.addButton(withTitle: ("Relaunch app"))
        alert.addButton(withTitle: ("Later"))
        activateForDialog()
        switch alert.runModal() {
        case .alertFirstButtonReturn: openScreenRecordingSettings()
        case .alertSecondButtonReturn: resetScreenRecordingRecordWithGuide()
        case .alertThirdButtonReturn: relaunch()
        default: break
        }
    }

    static func resetScreenRecordingRecordWithGuide() {
        let succeeded = resetScreenRecordingRecord()
        let alert = NSAlert()
        alert.alertStyle = succeeded ? .informational : .warning
        if succeeded {
            alert.messageText = ("Permission record cleared")
            alert.informativeText = ("""
                After relaunching Pipkin, macOS will ask for Screen Recording again — click Allow.

                Once granted, future updates will keep the permission.
                """)
            alert.addButton(withTitle: ("Relaunch app"))
            alert.addButton(withTitle: ("Later"))
            activateForDialog()
            if alert.runModal() == .alertFirstButtonReturn { relaunch() }
        } else {
            alert.messageText = ("Could not clear the permission record")
            alert.informativeText = ("""
                Please do it manually: open System Settings → Privacy & Security → \
                Screen & System Audio Recording, select Pipkin and remove it with −, \
                add it again with +, then relaunch the app.
                """)
            alert.addButton(withTitle: ("Open System Settings"))
            alert.addButton(withTitle: ("OK"))
            activateForDialog()
            if alert.runModal() == .alertFirstButtonReturn { openScreenRecordingSettings() }
        }
    }

    ///
    @discardableResult
    static func resetScreenRecordingRecord() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "ScreenCapture", bundleID]
        do {
            try process.run()
            process.waitUntilExit()
            let ok = process.terminationStatus == 0
            if !ok { Log.error("tccutil  \(process.terminationStatus)") }
            return ok
        } catch {
            Log.error("\(error.localizedDescription)")
            return false
        }
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            DispatchQueue.main.async {
                if let error {
                    Log.error("\(error.localizedDescription)")
                    let alert = NSAlert()
                    alert.messageText = ("Could not relaunch automatically")
                    alert.informativeText = ("Please quit and open Pipkin again manually.")
                    alert.addButton(withTitle: ("OK"))
                    alert.runModal()
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }


    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    static func showAccessibilityGuide() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = ("These features require Accessibility")
        alert.informativeText = ("""
            Accessibility is used to:
            · Switch to the exact source window when a PiP is clicked
            · Enable fn-based hotkeys and hover shortcuts (= - F D fn ⌫) in Enhanced mode

            Enable Pipkin in System Settings → Privacy & Security → Accessibility.

            Capture still works without it; clicking a PiP can only activate the source application, \
            which then chooses which window to show.
            """)
        alert.addButton(withTitle: ("Open System Settings"))
        alert.addButton(withTitle: ("Cancel"))
        activateForDialog()
        if alert.runModal() == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }


    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private static func activateForDialog() {
        NSApp.activate(ignoringOtherApps: true)
    }
}
