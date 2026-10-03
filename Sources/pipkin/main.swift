import AppKit

if SelfTest.shouldRun() {
    exit(SelfTest.run())
}

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.accessory)
app.run()
