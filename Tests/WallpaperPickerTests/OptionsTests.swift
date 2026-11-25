import Foundation
import Testing
@testable import WallpaperPicker

@Suite struct OptionsTests {
    let dir: URL
    let image: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wp-options-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        image = dir.appendingPathComponent("lake.jpg")
        try Data([0xff]).write(to: image)
    }

    func parse(_ args: String...) -> Result<Options, Options.ParseError> {
        Options.parse(["wallpaper-picker"] + args)
    }

    func error(_ args: String...) -> String? {
        if case .failure(.message(let m)) = Options.parse(["wallpaper-picker"] + args) { return m }
        return nil
    }

    @Test func nothingIsNoCommand() throws {
        let o = try parse().get()
        #expect(!o.isCommand)
        #expect(o.command.isEmpty)
    }

    @Test func dirBothForms() throws {
        #expect(try parse("--dir=\(dir.path)").get().folder?.path == dir.standardizedFileURL.path)
        #expect(try parse("--dir", dir.path).get().folder?.path == dir.standardizedFileURL.path)
    }

    @Test func dirTilde() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        #expect(try parse("--dir=~").get().folder?.path == home)
    }

    @Test func dirErrors() {
        #expect(error("--dir=") == "--dir needs a folder")
        #expect(error("--dir") == "--dir needs a folder")
        #expect(error("--dir=/no/such/folder")?.hasPrefix("No such folder") == true)
        #expect(error("--dir=\(image.path)")?.hasPrefix("Not a folder") == true)
    }

    @Test func set() throws {
        let o = try parse("--set=\(image.path)").get()
        #expect(o.setFile?.path == image.standardizedFileURL.path)
        #expect(o.command["set"] == image.standardizedFileURL.path)
        #expect(error("--set=\(dir.path)/missing.jpg")?.hasPrefix("No such file") == true)
        #expect(error("--set=\(dir.path)")?.hasPrefix("Not an image") == true)
        let text = dir.appendingPathComponent("notes.txt")
        FileManager.default.createFile(atPath: text.path, contents: Data())
        #expect(error("--set=\(text.path)")?.hasPrefix("Not an image") == true)
    }

    @Test func random() throws {
        #expect(try parse("--random").get().command["random"] == "all")
        #expect(try parse("--random", "--favourites").get().command["random"] == "favourites")
        #expect(try parse("--favorites", "--random").get().command["random"] == "favourites")
        #expect(error("--favourites") == "--favourites goes with --random")
        #expect(error("--random", "--set=\(image.path)") == "Use --set or --random, not both")
    }

    @Test func rotate() throws {
        #expect(try parse("--rotate=1h").get().rotate == .h1)
        #expect(try parse("--rotate", "OFF").get().rotate == .off)
        #expect(error("--rotate=2h") == "--rotate takes off, 15m, 1h, 3h or 1d")
    }

    @Test func hotkey() throws {
        #expect(try parse("--hotkey=ctrl+opt+space").get().command["hotkey"] == "ctrl+opt+space")
        #expect(error("--hotkey=w")?.hasPrefix("--hotkey takes") == true)
    }

    @Test func unknown() {
        #expect(error("--nope") == "Unknown option: --nope")
        if case .failure(.help) = parse("--help") {} else { Issue.record("--help") }
    }

    // A cold start gets the same command as a running app.
    @Test func launchArgumentsRoundTrip() throws {
        let o = try parse("--dir=\(dir.path)", "--show", "--random", "--favourites", "--rotate=3h", "--hotkey=cmd+f5").get()
        let again = try Options.parse(["x"] + o.launchArguments).get()
        #expect(again.command == o.command)
    }
}
