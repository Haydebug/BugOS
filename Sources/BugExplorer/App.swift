import AppKit
import BugOSKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    var windows: [ExplorerWindowController] = []
    private var openedWithFiles = false
    private var restoredTabs = false

    /// Folders macOS asked this copy to open before it handed itself to BugOS.
    private var handOffURLs: [URL] = []

    func applicationDidFinishLaunching(_ n: Notification) {
        // Inside BugOS, only BugOS may start File Explorer (so its permissions are BugOS's). Wait a
        // moment for any folders macOS is sending us, then pass them on.
        if BugOSChild.shouldHandOff {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
                BugOSChild.handOff(handOffURLs.isEmpty ? "start:explorer" : "open", paths: handOffURLs.map(\.path))
            }
            return
        }
        NSApp.mainMenu = buildMenu()
        Location.fallback = { AppDelegate.start }   // a reopened tab whose folder is gone: your start place
        Theme.applyAppearance()
        GlobalHotkey.onPress = { [weak self] in self?.hotkeyPressed() }
        GlobalHotkey.register()
        Bridge.shared.start()       // Save/Open dialogs from other apps open in File Explorer
        FinderRedirect.shared.start()   // folders that open in Finder open here instead
        // The BugOS page switched Save & Open takeover on or off.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.bugos.explorer.settings"),
                                                            object: nil, queue: .main) { n in
            CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
            if n.object as? String == "pause" { GlobalHotkey.unregister(); return }   // the page is recording a shortcut
            let on = UserDefaults.standard.object(forKey: "bridgeEnabled") as? Bool ?? true
            if on { Bridge.shared.start() } else { Bridge.shared.stop() }
            GlobalHotkey.reload()
            FinderRedirect.shared.reload()
            Icons.reset()
            Theme.reload()
            NotificationCenter.default.post(name: .settingsChanged, object: nil)   // open windows redraw
        }
        // Started at login: stay in the background until the hotkey, the Dock icon or a folder opens us.
        if CommandLine.arguments.contains("--background") { return }
        DispatchQueue.main.async { [self] in
            guard windows.isEmpty, !openedWithFiles else { return }
            openFirstWindow()
        }
    }

    /// Where new windows open (BugOS › File Explorer › Open new windows to).
    static var start: Location {
        let token = UserDefaults.standard.string(forKey: ExplorerSetting.startLocation) ?? "home:"
        if token != "home:", token != "thismac:", !FS.exists(URL(fileURLWithPath: token)) { return .home }   // that folder's gone
        return Location.from(token: token)
    }

    /// The first window of a session brings back the tabs you had open.
    private func openFirstWindow() {
        let restore = UserDefaults.standard.object(forKey: ExplorerSetting.restoreTabs) as? Bool ?? true
        let saved = restoredTabs || !restore ? [] : Settings.shared.savedTabs.map(Location.from(token:))
        restoredTabs = true
        newWindow(locations: saved.isEmpty ? [Self.start] : saved)
    }

    /// ⌥⌘E from anywhere: a fresh window at Home, like Win+E.
    private func hotkeyPressed() {
        if windows.isEmpty && !restoredTabs { openFirstWindow() } else { newWindow(locations: [Self.start]) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if BugOSChild.shouldHandOff { return false }
        if !hasVisibleWindows { if restoredTabs { newWindow(locations: [Self.start]) } else { openFirstWindow() } }
        return true
    }

    // MARK: Integration toggles (BugExplorer menu)

    @objc func toggleDefaultFolderApp(_ sender: Any?) {
        let makeDefault = !FolderHandler.isDefault
        FolderHandler.set(makeDefault) { err in
            if let err { showError("Couldn't change the default folder app.", info: err.localizedDescription, in: NSApp.keyWindow) }
        }
    }
    @objc func toggleBridge(_ sender: Any?) { Bridge.shared.enabled.toggle() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleDefaultFolderApp(_:)): item.state = FolderHandler.isDefault ? .on : .off
        case #selector(toggleBridge(_:)):
            item.state = Bridge.shared.enabled ? .on : .off
            item.title = Bridge.shared.enabled && !AXK.trusted ? "Use File Explorer for Save & Open (needs Accessibility)" : "Use File Explorer for Save & Open"
        default: break
        }
        return true
    }

    func applicationWillTerminate(_ n: Notification) {
        if let w = frontController { Settings.shared.savedTabs = w.tabs.map { $0.location.token } }
    }

    /// `open -a "File Explorer" <folder>` and "Open With › File Explorer".
    func application(_ app: NSApplication, open urls: [URL]) {
        if BugOSChild.shouldHandOff { handOffURLs += urls; return }
        openedWithFiles = true
        restoredTabs = true
        for u in urls {
            let loc: Location = FS.isDirectory(u) ? .folder(u) : .folder(u.deletingLastPathComponent())
            if let w = frontController { w.addTab(loc, select: true); w.window?.makeKeyAndOrderFront(nil) }
            else { newWindow(locations: [loc]) }
            if !FS.isDirectory(u) { frontController?.current?.reveal(u) }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    var frontController: ExplorerWindowController? {
        (NSApp.keyWindow?.windowController as? ExplorerWindowController)
            ?? (NSApp.mainWindow?.windowController as? ExplorerWindowController)
            ?? windows.last
    }

    @discardableResult
    func newWindow(locations: [Location]) -> ExplorerWindowController {
        let wc = ExplorerWindowController(locations: locations)
        windows.append(wc)
        wc.onClose = { [weak self, weak wc] in self?.windows.removeAll { $0 === wc } }
        if let front = windows.dropLast().last?.window {
            wc.window?.setFrameTopLeftPoint(NSPoint(x: front.frame.minX + 28, y: front.frame.maxY - 28))
        }
        wc.showWindow(nil)
        return wc
    }

    @objc func newWindowAction(_ sender: Any?) {
        let loc = frontController?.current?.location ?? Self.start   // ⌘N: the folder you're in, like Windows
        newWindow(locations: [loc])
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        func sub(_ title: String, _ items: [NSMenuItem]) {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            top.submenu = m
            main.addItem(top)
        }
        func item(_ t: String, _ sel: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command], tag: Int = 0) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.tag = tag
            return i
        }
        func fkey(_ code: Int) -> String { String(UnicodeScalar(UInt16(code)).map(Character.init) ?? " ") }

        sub("File Explorer", [
            item("About File Explorer", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            { let i = item("Open Folders with File Explorer", #selector(toggleDefaultFolderApp(_:))); i.target = self; return i }(),
            { let i = item("Use File Explorer for Save & Open", #selector(toggleBridge(_:))); i.target = self; return i }(),
            { let i = NSMenuItem(title: "New window from anywhere: ⌥⌘E", action: nil, keyEquivalent: ""); i.isEnabled = false; return i }(),
            .separator(),
            item("Hide File Explorer", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            .separator(),
            item("Quit File Explorer", #selector(NSApplication.terminate(_:)), "q"),
        ])
        let newWin = item("New Window", #selector(newWindowAction(_:)), "n"); newWin.target = self
        sub("File", [
            newWin,
            item("New Tab", #selector(ExplorerWindowController.newTab(_:)), "t"),
            item("New Folder", #selector(BrowserViewController.newFolder(_:)), "n", [.command, .shift]),
            item("New Text Document", #selector(BrowserViewController.newTextDocument(_:))),
            .separator(),
            item("Open", #selector(BrowserViewController.openSelection(_:)), "o"),
            item("Open in New Tab", #selector(BrowserViewController.openInNewTab(_:))),
            item("Open in New Window", #selector(BrowserViewController.openInNewWindow(_:))),
            item("Open in Terminal", #selector(BrowserViewController.openInTerminal(_:)), "t", [.command, .option]),
            .separator(),
            item("Properties", #selector(BrowserViewController.showProperties(_:)), "\r", [.option]),
            item("Compress to ZIP file", #selector(BrowserViewController.compress(_:))),
            item("Pin to Quick access", #selector(BrowserViewController.togglePin(_:))),
            .separator(),
            item("Close Tab", #selector(ExplorerWindowController.closeTab(_:)), "w"),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]),
        ])
        sub("Edit", [
            item("Undo", #selector(BrowserViewController.undoFileOperation(_:)), "z"),
            item("Redo", #selector(BrowserViewController.redoFileOperation(_:)), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Copy as path", #selector(BrowserViewController.copyAsPath(_:)), "c", [.command, .shift]),
            .separator(),
            item("Rename", #selector(BrowserViewController.renameSelection(_:)), fkey(NSF2FunctionKey), []),
            item("Delete", #selector(BrowserViewController.deleteSelection(_:)), "\u{8}"),
            item("Delete Permanently", #selector(BrowserViewController.deletePermanently(_:)), "\u{8}", [.command, .option]),
            .separator(),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            item("Select None", #selector(BrowserViewController.selectNone(_:)), "a", [.command, .shift]),
            item("Invert Selection", #selector(BrowserViewController.invertSelection(_:))),
            .separator(),
            item("Search", #selector(BrowserViewController.focusSearch(_:)), "f"),
        ])
        var viewItems: [NSMenuItem] = ViewMode.allCases.enumerated().map { (i, m) in
            item(m.title, #selector(BrowserViewController.setViewModeFromMenu(_:)), "\(i + 1)", [.command, .shift], tag: i)
        }
        viewItems += [
            .separator(),
            item("Navigation pane", #selector(BrowserViewController.toggleNavPane(_:))),
            item("Details pane", #selector(BrowserViewController.toggleDetailsPane(_:)), "p", [.option, .shift]),
            item("Preview pane", #selector(BrowserViewController.togglePreviewPane(_:)), "p", [.option]),
            .separator(),
            item("Hidden items", #selector(BrowserViewController.toggleHidden(_:)), ".", [.command, .shift]),
            item("File name extensions", #selector(BrowserViewController.toggleExtensions(_:))),
            item("Item check boxes", #selector(BrowserViewController.toggleCheckBoxes(_:))),
            .separator(),
            item("Refresh", #selector(BrowserViewController.refresh(_:)), "r"),
            item("Refresh ", #selector(BrowserViewController.refresh(_:)), fkey(NSF5FunctionKey), []),
        ]
        viewItems.last?.isAlternate = false
        viewItems.last?.isHidden = true
        viewItems.last?.allowsKeyEquivalentWhenHidden = true
        sub("View", viewItems)
        let addrF4 = item("Edit address ", #selector(BrowserViewController.focusAddress(_:)), fkey(NSF4FunctionKey), [])
        addrF4.isHidden = true; addrF4.allowsKeyEquivalentWhenHidden = true
        let addrD = item("Edit address  ", #selector(BrowserViewController.focusAddress(_:)), "d", [.option])
        addrD.isHidden = true; addrD.allowsKeyEquivalentWhenHidden = true
        sub("Go", [
            item("Back", #selector(BrowserViewController.goBack(_:)), "["),
            item("Forward", #selector(BrowserViewController.goForward(_:)), "]"),
            item("Up", #selector(BrowserViewController.goUp(_:)), String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!), [.command]),
            .separator(),
            item("Home", #selector(BrowserViewController.goPlace(_:)), "h", [.command, .shift], tag: 0),
            item("This Mac", #selector(BrowserViewController.goPlace(_:)), "c", [.command, .option], tag: 1),
            item("Desktop", #selector(BrowserViewController.goPlace(_:)), "d", [.command, .shift], tag: 2),
            item("Downloads", #selector(BrowserViewController.goPlace(_:)), "l", [.command, .option], tag: 3),
            item("Documents", #selector(BrowserViewController.goPlace(_:)), "o", [.command, .shift], tag: 4),
            item("Applications", #selector(BrowserViewController.goPlace(_:)), "a", [.command, .option], tag: 5),
            .separator(),
            item("Edit address", #selector(BrowserViewController.focusAddress(_:)), "l"),
            addrF4, addrD,
        ])
        let winMenu = NSMenu(title: "Window")
        [item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
         item("Zoom", #selector(NSWindow.performZoom(_:))),
         .separator(),
         item("Next Tab", #selector(ExplorerWindowController.nextTab(_:)), "\t", [.control]),
         item("Previous Tab", #selector(ExplorerWindowController.previousTab(_:)), "\t", [.control, .shift]),
         item("Next Tab ", #selector(ExplorerWindowController.nextTab(_:)), "}", [.command, .shift]),
         item("Previous Tab ", #selector(ExplorerWindowController.previousTab(_:)), "{", [.command, .shift]),
        ].forEach(winMenu.addItem)
        let winTop = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        winTop.submenu = winMenu
        main.addItem(winTop)
        NSApp.windowsMenu = winMenu
        return main
    }
}

