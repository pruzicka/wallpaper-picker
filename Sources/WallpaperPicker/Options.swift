import AppKit

enum AppInfo {
    static let bundleID = "io.github.pruzicka.WallpaperPicker"
    // Commands from the command line to the copy already running.
    static let commandNotification = Notification.Name(bundleID + ".command")
}

// Command-line options, e.g. `wallpaper-picker --dir=~/Pictures/Wallpapers`.
struct Options {
    var folder: URL?
    var show = false
    // Set when the app launches itself to carry out a command.
    var run = false

    var isCommand: Bool { folder != nil || show }

    static let usage = """
        Usage: wallpaper-picker [--dir=PATH] [--show]

          --dir=PATH   Take wallpapers from PATH (remembered; ~ works, also in quotes)
          --show       Open the picker
          --help       Show this help
        """

    enum ParseError: Error {
        case help
        case message(String)
    }

    static func parse(_ arguments: [String]) -> Result<Options, ParseError> {
        var options = Options()
        var args = Array(arguments.dropFirst())[...]
        while let arg = args.popFirst() {
            switch arg {
            case "--help", "-h":
                return .failure(.help)
            case "--show":
                options.show = true
            case "--run":
                options.run = true
            case "--dir":
                guard let value = args.popFirst() else { return .failure(.message("--dir needs a folder")) }
                switch folder(value) {
                case .success(let url): options.folder = url
                case .failure(let error): return .failure(error)
                }
            case _ where arg.hasPrefix("--dir="):
                switch folder(String(arg.dropFirst("--dir=".count))) {
                case .success(let url): options.folder = url
                case .failure(let error): return .failure(error)
                }
            case _ where arg.hasPrefix("-psn_"):
                continue // added by older Finder launches
            default:
                return .failure(.message("Unknown option: \(arg)"))
            }
        }
        return .success(options)
    }

    private static func folder(_ raw: String) -> Result<URL, ParseError> {
        guard !raw.isEmpty else { return .failure(.message("--dir needs a folder")) }
        var path = (raw as NSString).expandingTildeInPath
        if !path.hasPrefix("/") {
            path = (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(path)
        }
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .failure(.message("No such folder: \(url.path)"))
        }
        guard isDirectory.boolValue else {
            return .failure(.message("Not a folder: \(url.path)"))
        }
        return .success(url)
    }
}
