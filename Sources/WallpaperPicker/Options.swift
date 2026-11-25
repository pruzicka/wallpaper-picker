import AppKit

enum AppInfo {
    static let bundleID = "io.github.pruzicka.WallpaperPicker"
    // Commands from the command line to the copy already running.
    static let commandNotification = Notification.Name(bundleID + ".command")
}

// Command-line options, e.g. `wallpaper-picker --dir=~/Pictures/Wallpapers`.
struct Options: Equatable {
    var folder: URL?
    var show = false
    var setFile: URL?
    var random = false
    var favourites = false
    var rotate: RotationInterval?
    var hotkey: HotKeySpec?
    // Set when the app launches itself to carry out a command.
    var run = false

    var isCommand: Bool { !command.isEmpty }

    static let usage = """
        Usage: wallpaper-picker [--dir=PATH] [--show] [--set=FILE | --random [--favourites]]
                                [--rotate=INTERVAL] [--hotkey=KEYS]

          --dir=PATH         Take wallpapers from PATH (remembered; ~ works, also in quotes)
          --show             Open the picker
          --set=FILE         Set FILE as the wallpaper
          --random           Set a random wallpaper (not one shown lately)
          --favourites       With --random: only from the favourites
          --rotate=INTERVAL  Change the wallpaper by itself: off, 15m, 1h, 3h or 1d
          --hotkey=KEYS      The shortcut that opens the picker, e.g. ctrl+opt+w,
                             cmd+shift+space or f5 (ctrl, opt, shift, cmd; a-z, 0-9,
                             space, f1-f12)
          --help             Show this help
        """

    enum ParseError: Error, Equatable {
        case help
        case message(String)
    }

    static func parse(_ arguments: [String]) -> Result<Options, ParseError> {
        var options = Options()
        var args = Array(arguments.dropFirst())[...]
        // "--name=value" or "--name value"
        func value(_ arg: String, _ name: String) -> String?? {
            if arg == name { return .some(args.popFirst()) }
            if arg.hasPrefix(name + "=") { return .some(String(arg.dropFirst(name.count + 1))) }
            return .none
        }
        while let arg = args.popFirst() {
            switch arg {
            case "--help", "-h":
                return .failure(.help)
            case "--show":
                options.show = true
            case "--random":
                options.random = true
            case "--favourites", "--favorites":
                options.favourites = true
            case "--run":
                options.run = true
            case _ where arg.hasPrefix("-psn_"):
                continue // added by older Finder launches
            default:
                if let raw = value(arg, "--dir") {
                    guard let raw, !raw.isEmpty else { return .failure(.message("--dir needs a folder")) }
                    switch folder(raw) {
                    case .success(let url): options.folder = url
                    case .failure(let error): return .failure(error)
                    }
                } else if let raw = value(arg, "--set") {
                    guard let raw, !raw.isEmpty else { return .failure(.message("--set needs an image file")) }
                    switch image(raw) {
                    case .success(let url): options.setFile = url
                    case .failure(let error): return .failure(error)
                    }
                } else if let raw = value(arg, "--rotate") {
                    guard let raw, let interval = RotationInterval(rawValue: raw.lowercased()) else {
                        return .failure(.message("--rotate takes off, 15m, 1h, 3h or 1d"))
                    }
                    options.rotate = interval
                } else if let raw = value(arg, "--hotkey") {
                    guard let raw, let spec = HotKeySpec(raw) else {
                        return .failure(.message("--hotkey takes keys like ctrl+opt+w, cmd+shift+space or f5"))
                    }
                    options.hotkey = spec
                } else {
                    return .failure(.message("Unknown option: \(arg)"))
                }
            }
        }
        if options.setFile != nil && options.random {
            return .failure(.message("Use --set or --random, not both"))
        }
        if options.favourites && !options.random {
            return .failure(.message("--favourites goes with --random"))
        }
        return .success(options)
    }

    // What the running app is asked to do, as sent to it.
    var command: [String: String] {
        var info: [String: String] = [:]
        if let folder { info["dir"] = folder.path }
        if show { info["show"] = "1" }
        if let setFile { info["set"] = setFile.path }
        if random { info["random"] = favourites ? "favourites" : "all" }
        if let rotate { info["rotate"] = rotate.rawValue }
        if let hotkey { info["hotkey"] = hotkey.text }
        return info
    }

    // The same, as arguments for launching the app.
    var launchArguments: [String] {
        var args: [String] = []
        if let folder { args.append("--dir=\(folder.path)") }
        if show { args.append("--show") }
        if let setFile { args.append("--set=\(setFile.path)") }
        if random { args.append("--random") }
        if favourites { args.append("--favourites") }
        if let rotate { args.append("--rotate=\(rotate.rawValue)") }
        if let hotkey { args.append("--hotkey=\(hotkey.text)") }
        return args
    }

    private static func absolute(_ raw: String) -> URL {
        var path = (raw as NSString).expandingTildeInPath
        if !path.hasPrefix("/") {
            path = (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(path)
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private static func folder(_ raw: String) -> Result<URL, ParseError> {
        let url = URL(fileURLWithPath: absolute(raw).path, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .failure(.message("No such folder: \(url.path)"))
        }
        guard isDirectory.boolValue else {
            return .failure(.message("Not a folder: \(url.path)"))
        }
        return .success(url)
    }

    private static func image(_ raw: String) -> Result<URL, ParseError> {
        let url = absolute(raw)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .failure(.message("No such file: \(url.path)"))
        }
        guard !isDirectory.boolValue, Library.extensions.contains(url.pathExtension.lowercased()) else {
            return .failure(.message("Not an image it can use: \(url.path) (jpg, png, heic, webp, gif, tiff, bmp)"))
        }
        return .success(url)
    }
}
