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
case .failure(.version):
    print("Wallpaper Picker \(AppInfo.version)")
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
        DistributedNotificationCenter.default().postNotificationName(
            AppInfo.commandNotification, object: nil, userInfo: options.command, deliverImmediately: true)
        // Give the notification a moment to leave before exiting.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    } else {
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["--run"] + options.launchArguments
        config.activates = false
        let done = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, error in
            if let error { FileHandle.standardError.write(Data("Couldn't start the app: \(error.localizedDescription)\n".utf8)) }
            done.signal()
        }
        done.wait()
    }
    if let folder = options.folder { print("Wallpaper folder: \(folder.path)") }
    if let file = options.setFile { print("Wallpaper: \(file.path)") }
    if let rotate = options.rotate { print("Changes by itself: \(rotate.label.lowercased())") }
    if let hotkey = options.hotkey { print("Shortcut: \(hotkey.display)") }
    exit(0)
}

// The app itself (or a development build run straight from .build). The
// folder is read before anything else starts.
if let folder = options.folder {
    UserDefaults.standard.set(folder.path, forKey: "folder")
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate(command: options.command)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
