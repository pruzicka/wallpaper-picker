import AppKit

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let options: Options
switch Options.parse(CommandLine.arguments) {
case .success(let parsed):
    options = parsed
case .failure(.help):
    print(Options.usage)
    exit(0)
case .failure(.message(let message)):
    fail(message + "\n\n" + Options.usage, code: 2)
}

let inBundle = Bundle.main.bundleIdentifier == AppInfo.bundleID

if inBundle && options.isCommand && !options.run {
    // Run from a terminal: hand the command to the app and return.
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: AppInfo.bundleID)
        .filter { $0.processIdentifier != getpid() }
    if !others.isEmpty {
        var info: [String: String] = [:]
        if let folder = options.folder { info["dir"] = folder.path }
        if options.show { info["show"] = "1" }
        DistributedNotificationCenter.default().postNotificationName(
            AppInfo.commandNotification, object: nil, userInfo: info, deliverImmediately: true)
        // Give the notification a moment to leave before exiting.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    } else {
        if let folder = options.folder { UserDefaults.standard.set(folder.path, forKey: "folder") }
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["--run"] + (options.show ? ["--show"] : [])
        config.activates = false
        let done = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, error in
            if let error { FileHandle.standardError.write(Data("Couldn't start the app: \(error.localizedDescription)\n".utf8)) }
            done.signal()
        }
        done.wait()
    }
    if let folder = options.folder { print("Wallpaper folder: \(folder.path)") }
    exit(0)
}

// The app itself (or a development build run straight from .build).
if let folder = options.folder {
    UserDefaults.standard.set(folder.path, forKey: "folder")
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate(show: options.show)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
