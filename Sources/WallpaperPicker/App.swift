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

    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, user in
            guard let user else { return noErr }
            let me = Unmanaged<HotKey>.fromOpaque(user).takeUnretainedValue()
            DispatchQueue.main.async { me.action() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let id = EventHotKeyID(signature: OSType(0x5750_4B52), id: 1) // "WPKR"
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
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
    private var panel: PickerPanel?
    private var statusItem: NSStatusItem?
    private var hotKey: HotKey?
    private var loginItem: NSMenuItem?

    private let showOnLaunch: Bool

    init(show: Bool) {
        showOnLaunch = show
        library = Library()
        model = PickerModel(library: library)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.onClose = { [weak self] in self?.panel?.orderOut(nil) }
        model.onChooseFolder = { [weak self] in self?.chooseFolder() }
        buildMenu()
        // ⌃⌥W
        hotKey = HotKey(keyCode: kVK_ANSI_W, modifiers: controlKey | optionKey) { [weak self] in
            MainActor.assumeIsolated { self?.toggle() }
        }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(command(_:)), name: AppInfo.commandNotification, object: nil,
            suspensionBehavior: .deliverImmediately)
        if showOnLaunch { show() }
    }

    // Opening the app again (Finder, Spotlight, `open`) shows the picker.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show()
        return false
    }

    // `wallpaper-picker --dir=… --show` while the app is running.
    @objc private func command(_ note: Notification) {
        let info = note.userInfo as? [String: String] ?? [:]
        if let dir = info["dir"] {
            library.choose(folder: URL(fileURLWithPath: dir, isDirectory: true))
        }
        if info["show"] != nil { show() }
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

    // MARK: Menu bar

    private func buildMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "photo.on.rectangle.angled",
                                     accessibilityDescription: "Wallpaper Picker")
        let menu = NSMenu()
        menu.delegate = self

        let showItem = NSMenuItem(title: "Show Wallpaper Picker", action: #selector(show), keyEquivalent: "w")
        showItem.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(showItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Choose Folder…", action: #selector(chooseFolder), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Folder in Finder", action: #selector(revealFolder), keyEquivalent: ""))
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        menu.addItem(login)
        loginItem = login
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Wallpaper Picker", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        for entry in menu.items where entry.action != #selector(NSApplication.terminate(_:)) {
            entry.target = self
        }
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
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
