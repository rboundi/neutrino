import AppKit

// The first document controller created becomes the shared one, so make ours before AppKit does.
_ = DocumentController()

let app = NSApplication.shared
app.delegate = AppDelegate.shared
app.setActivationPolicy(.regular)
app.run()
