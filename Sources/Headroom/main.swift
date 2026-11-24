import AppKit
import HeadroomCore

if ScreenshotExport.active {
    do {
        let index = CommandLine.arguments.firstIndex(of: "--screenshots")!
        let path = CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : "docs"
        try ScreenshotExport.run(directory: URL(fileURLWithPath: path, isDirectory: true))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Screenshot error: \(error.localizedDescription)\n".utf8)); exit(1)
    }
}

if CommandLine.arguments.contains("--check-for-updates") {
    do {
        print(try GitHubUpdates.fetch()?.tag_name ?? "No stable releases published")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Update check: \(error.localizedDescription)\n".utf8)); exit(1)
    }
}

if CommandLine.arguments.contains("--history-dir") {
    print(HistoryStore.defaultDirectory.path); exit(0)
}
if CommandLine.arguments.contains("--scan") {
    do {
        let store = try HistoryStore()
        let result = ConsumerScanner().scan { done, total in
            FileHandle.standardError.write(Data("Scanning \(done)/\(total)\r".utf8))
        }
        guard !result.cancelled else { exit(2) }
        try store.saveConsumers(result.consumers, localSnapshots: result.localSnapshots)
        try store.writeLog(summary: store.summary())
        print(store.logURL.path)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Scan error: \(error.localizedDescription)\n".utf8)); exit(1)
    }
}

if CommandLine.arguments.contains("--capture") || CommandLine.arguments.contains("--report") {
    do {
        let store = try HistoryStore()
        if CommandLine.arguments.contains("--capture") {
            let apps = AppGrouping.group(apps: MemoryMonitor.identities(), processes: ProcessMemory.read())
            // A newly opened store's first record() always writes log.md (unless disk is nearly full).
            _ = try store.record(memory: .read(), apps: ObservedApp.from(apps), disk: .read())
        } else { try store.writeLog(summary: store.summary()) }
        print(store.logURL.path)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("History error: \(error.localizedDescription)\n".utf8)); exit(1)
    }
}

if CommandLine.arguments.contains("--diagnose") {
    struct Diagnostic: Codable {
        let memory: SystemMemory
        let disk: DiskSpace
        let apps: [AppMemory]
        let notchAvailable: Bool
    }
    let output = Diagnostic(memory: .read(), disk: .read(), apps: AppGrouping.group(apps: MemoryMonitor.identities(), processes: ProcessMemory.read()),
                            notchAvailable: NSScreen.screens.contains { $0.safeAreaInsets.top > 0 })
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(output))
    exit(output.memory.valid ? 0 : 1)
}

// Integration harness can only act on the dedicated, disposable test fixture.
if let index = CommandLine.arguments.firstIndex(of: "--test-quit-fixture"), CommandLine.arguments.count > index + 1 {
    guard let pid = Int32(CommandLine.arguments[index + 1]),
          let app = NSRunningApplication(processIdentifier: pid),
          app.bundleIdentifier == "org.headroom.testfixture" else { exit(2) }
    let identity = AppIdentity(pid: pid, name: app.localizedName ?? "Fixture", bundlePath: app.bundleURL?.path ?? "",
                               bundleIdentifier: app.bundleIdentifier, launchDate: app.launchDate)
    let result = AppTermination.request(identity, force: CommandLine.arguments.contains("--force"))
    print(result ? "Quit request accepted" : "Quit request rejected")
    exit(result ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
