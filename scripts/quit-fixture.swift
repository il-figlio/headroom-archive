import AppKit

final class FixtureDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.count > 1 {
            try! String(getpid()).write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        CommandLine.arguments.contains("--refuse") ? .terminateCancel : .terminateNow
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = FixtureDelegate()
app.delegate = delegate
app.run()
