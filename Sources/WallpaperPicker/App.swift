import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

// A full-screen borderless panel over everything, menu bar included. Keys
// and scrolling go straight to the picker.
final class PickerPanel: NSPanel {
    weak var model: PickerModel?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if let model {
            let handled = MainActor.assumeIsolated { () -> Bool in
                switch event.type {
                case .keyDown: return model.keyDown(event)
                case .keyUp: return model.keyUp(event)
                case .scrollWheel:
                    model.scroll(event)
                    return true
                default: return false
                }
            }
            if handled { return }
        }
        super.sendEvent(event)
    }
}

// A system-wide shortcut (Carbon's, which needs no permissions).
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    // False when Carbon turns the shortcut down. It doesn't when another
    // app has registered the same one (both succeed, one gets the keys),
    // so this catches only what Carbon itself refuses.
    private(set) var registered = false

    init(_ spec: HotKeySpec, action: @escaping () -> Void) {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, user in
            guard let user else { return noErr }
            let me = Unmanaged<HotKey>.fromOpaque(user).takeUnretainedValue()
            DispatchQueue.main.async { me.action() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let id = EventHotKeyID(signature: OSType(0x5750_4B52), id: 1) // "WPKR"
        let status = RegisterEventHotKey(UInt32(spec.keyCode), UInt32(spec.modifiers), id,
                                         GetApplicationEventTarget(), 0, &ref)
        registered = status == noErr
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private let library: Library
    private let model: PickerModel
    private let rotation: Rotation
    private var panel: PickerPanel?
    private var statusItem: NSStatusItem?
    private var hotKey: HotKey?
    private var hotKeySpec = HotKeySpec.saved

    private var showItem: NSMenuItem?
    private var conflictItem: NSMenuItem?
    private var loginItem: NSMenuItem?
    private var rotationItems: [RotationInterval: NSMenuItem] = [:]
    private var favouritesOnlyItem: NSMenuItem?
    private var shortcutMenu: NSMenu?

    // What the command line asked for when it started the app.
    private let launchCommand: [String: String]

    init(command: [String: String]) {
        launchCommand = command
        library = Library()
        model = PickerModel(library: library)
        rotation = Rotation(library: library)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.onClose = { [weak self] in self?.panel?.orderOut(nil) }
        model.onChooseFolder = { [weak self] in self?.chooseFolder() }
        model.onApplied = { [weak self] wp in self?.rotation.record(wp) }
        rotation.isPaused = { [weak self] in self?.model.isOpen ?? false }
        buildMenu()
        registerHotKey()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(command(_:)), name: AppInfo.commandNotification, object: nil,
            suspensionBehavior: .deliverImmediately)
        perform(launchCommand)
    }

    // Opening the app again (Finder, Spotlight, `open`) shows the picker.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show()
        return false
    }

    // `wallpaper-picker --dir=… --show …` while the app is running.
    @objc private func command(_ note: Notification) {
        perform(note.userInfo as? [String: String] ?? [:])
    }

    // A command from the command line (see `Options.command`).
    private func perform(_ info: [String: String]) {
        if let dir = info["dir"] {
            let url = URL(fileURLWithPath: dir, isDirectory: true)
            if url.standardizedFileURL != library.folder.standardizedFileURL { library.choose(folder: url) }
        }
        if let raw = info["hotkey"], let spec = HotKeySpec(raw) { setHotKey(spec) }
        if let raw = info["rotate"], let interval = RotationInterval(rawValue: raw) { rotation.interval = interval }
        if let path = info["set"] {
            if let wp = library.wallpaper(at: URL(fileURLWithPath: path)) {
                do {
                    try library.apply(wp)
                    rotation.record(wp)
                } catch {
                    report("Couldn't set the wallpaper", error)
                }
            }
        }
        if let which = info["random"] {
            do { try rotation.next(favouritesOnly: which == "favourites") } catch { report("Couldn't change the wallpaper", error) }
        }
        if info["show"] != nil { show() }
    }

    private func report(_ title: String, _ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc func toggle() {
        if model.isOpen { model.close() } else { show() }
    }

    @objc func show() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens.first
        else { return }
        let panel = self.panel ?? makePanel()
        panel.setFrame(screen.frame, display: false)
        // A new display link each time: an old one may not outlive the
        // screens sleeping or changing.
        model.motion.view = panel.contentView
        model.configure(size: screen.frame.size, scale: screen.backingScaleFactor)
        model.open()
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private func makePanel() -> PickerPanel {
        let panel = PickerPanel()
        let host = NSHostingView(rootView: PickerView(model: model))
        host.sizingOptions = []
        panel.contentView = host
        panel.model = model
        panel.delegate = self
        model.motion.view = host
        self.panel = panel
        return panel
    }

    // Clicking another app or screen puts the picker away.
    func windowDidResignKey(_ notification: Notification) {
        model.close()
    }

    // MARK: Shortcut

    private func registerHotKey() {
        hotKey = nil // let go of the old one first
        hotKey = HotKey(hotKeySpec) { [weak self] in
            MainActor.assumeIsolated { self?.toggle() }
        }
        updateShortcutItems()
    }

    private func setHotKey(_ spec: HotKeySpec) {
        guard spec != hotKeySpec else { return }
        hotKeySpec = spec
        spec.save()
        registerHotKey()
    }

    @objc private func chooseShortcut(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String, let spec = HotKeySpec(text) else { return }
        setHotKey(spec)
    }

    private func updateShortcutItems() {
        let works = hotKey?.registered ?? false
        showItem?.keyEquivalent = works ? hotKeySpec.keyEquivalent : ""
        showItem?.keyEquivalentModifierMask = works ? hotKeySpec.modifierFlags : []
        conflictItem?.title = "\(hotKeySpec.display) is in use by another app"
        conflictItem?.isHidden = works
        guard let menu = shortcutMenu else { return }
        menu.removeAllItems()
        var specs = HotKeySpec.presets
        if !specs.contains(hotKeySpec) { specs.append(hotKeySpec) }
        for spec in specs {
            let item = NSMenuItem(title: spec.display, action: #selector(chooseShortcut(_:)), keyEquivalent: "")
            item.representedObject = spec.text
            item.target = self
            item.state = spec == hotKeySpec ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let hint = NSMenuItem(title: "Others: wallpaper-picker --hotkey=…", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
    }

    // MARK: Menu bar

    private func buildMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "photo.on.rectangle.angled",
                                     accessibilityDescription: "Wallpaper Picker")
        let menu = NSMenu()
        menu.delegate = self

        menu.addItem(NSMenuItem(title: "About Wallpaper Picker", action: #selector(about), keyEquivalent: ""))
        menu.addItem(.separator())
        let showItem = NSMenuItem(title: "Show Wallpaper Picker", action: #selector(show), keyEquivalent: "")
        menu.addItem(showItem)
        self.showItem = showItem
        let conflict = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        conflict.isEnabled = false
        conflict.isHidden = true
        menu.addItem(conflict)
        conflictItem = conflict
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Next Wallpaper", action: #selector(nextWallpaper), keyEquivalent: ""))
        let rotationMenu = NSMenu()
        for interval in RotationInterval.allCases {
            let entry = NSMenuItem(title: interval.label, action: #selector(chooseRotation(_:)), keyEquivalent: "")
            entry.representedObject = interval.rawValue
            entry.target = self
            rotationMenu.addItem(entry)
            rotationItems[interval] = entry
        }
        rotationMenu.addItem(.separator())
        let favouritesOnly = NSMenuItem(title: "Favourites Only", action: #selector(toggleFavouritesOnly), keyEquivalent: "")
        favouritesOnly.target = self
        rotationMenu.addItem(favouritesOnly)
        favouritesOnlyItem = favouritesOnly
        let rotationItem = NSMenuItem(title: "Change Wallpaper", action: nil, keyEquivalent: "")
        rotationItem.submenu = rotationMenu
        menu.addItem(rotationItem)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Choose Folder…", action: #selector(chooseFolder), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Folder in Finder", action: #selector(revealFolder), keyEquivalent: ""))
        menu.addItem(.separator())
        let shortcutItem = NSMenuItem(title: "Shortcut", action: nil, keyEquivalent: "")
        let shortcuts = NSMenu()
        shortcutItem.submenu = shortcuts
        shortcutMenu = shortcuts
        menu.addItem(shortcutItem)
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        menu.addItem(login)
        loginItem = login
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Wallpaper Picker", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        for entry in menu.items where entry.action != nil && entry.action != #selector(NSApplication.terminate(_:)) {
            entry.target = self
        }
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        for (interval, entry) in rotationItems {
            entry.state = interval == rotation.interval ? .on : .off
        }
        favouritesOnlyItem?.state = rotation.favouritesOnly ? .on : .off
    }

    @objc func about() {
        model.closeNow()
        let credits = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        func add(_ text: String, link: URL? = nil) {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font, .paragraphStyle: centred, .foregroundColor: NSColor.secondaryLabelColor,
            ]
            if let link { attributes[.link] = link }
            credits.append(NSAttributedString(string: text, attributes: attributes))
        }
        add("github.com/pruzicka/wallpaper-picker", link: AppInfo.homepage)
        add("\nAfter ")
        add("qs-wallpaperpicker", link: URL(string: "https://github.com/dhrruvsharma/qs-wallpaperpicker"))
        add(" by u/dhruvsha")
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Wallpaper Picker",
            .applicationVersion: AppInfo.version,
            .version: "", // no build number in brackets
            .credits: credits,
        ])
    }

    @objc func nextWallpaper() {
        do { try rotation.next() } catch { report("Couldn't change the wallpaper", error) }
    }

    @objc private func chooseRotation(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let interval = RotationInterval(rawValue: raw) else { return }
        rotation.interval = interval
    }

    @objc private func toggleFavouritesOnly() {
        rotation.favouritesOnly.toggle()
    }
    @objc func chooseFolder() {
        model.closeNow()
        NSApp.activate(ignoringOtherApps: true)
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.allowsMultipleSelection = false
        open.canCreateDirectories = true
        open.directoryURL = library.folder
        open.prompt = "Use Folder"
        open.message = "Choose the folder your wallpapers are in"
        if open.runModal() == .OK, let url = open.url {
            library.choose(folder: url)
            show()
        }
    }

    @objc func revealFolder() {
        model.closeNow()
        NSWorkspace.shared.open(library.folder)
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn't change Open at Login"
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
