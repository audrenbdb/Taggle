import Cocoa
import Carbon
import UserNotifications

// MARK: - Private CoreGraphics APIs (loaded dynamically)

typealias CGSMainConnectionIDFunc = @convention(c) () -> Int32
// enabled param as Int32 (0/1) instead of Bool to match C ABI
typealias CGSConfigureDisplayEnabledFunc = @convention(c) (Int32, CGDirectDisplayID, Int32) -> CGError

let cgHandle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)

let _CGSMainConnectionID: CGSMainConnectionIDFunc? = {
    guard let h = cgHandle, let sym = dlsym(h, "CGSMainConnectionID") else { return nil }
    return unsafeBitCast(sym, to: CGSMainConnectionIDFunc.self)
}()

let _CGSConfigureDisplayEnabled: CGSConfigureDisplayEnabledFunc? = {
    guard let h = cgHandle, let sym = dlsym(h, "CGSConfigureDisplayEnabled") else { return nil }
    return unsafeBitCast(sym, to: CGSConfigureDisplayEnabledFunc.self)
}()

// MARK: - Shortcut Recording

class ShortcutField: NSTextField {
    var onShortcutCaptured: ((UInt32, UInt32) -> Void)?
    private var monitor: Any?

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            self.stringValue = "Press shortcut..."
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self = self else { return event }
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard !modifiers.isEmpty else { return nil } // require at least one modifier

                let keyCode = UInt32(event.keyCode)
                let carbonMods = self.carbonModifiers(from: modifiers)
                self.stringValue = self.shortcutString(keyCode: event.keyCode, modifiers: modifiers)
                self.onShortcutCaptured?(keyCode, carbonMods)
                self.window?.makeFirstResponder(nil)
                return nil
            }
        }
        return result
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        return mods
    }

    func shortcutString(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("Ctrl") }
        if modifiers.contains(.option) { parts.append("Opt") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        if modifiers.contains(.command) { parts.append("Cmd") }
        parts.append(keyName(keyCode))
        return parts.joined(separator: "+")
    }

    func keyName(_ keyCode: UInt16) -> String {
        let names: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
            11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
            20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
            29: "0", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N",
            46: "M", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\", 43: ",", 44: "/", 47: ".",
            50: "`",
            // Function keys
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
            100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            // Special keys
            36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape",
            123: "Left", 124: "Right", 125: "Down", 126: "Up",
        ]
        return names[keyCode] ?? "Key\(keyCode)"
    }
}

// MARK: - Preferences

struct TagglePrefs {
    static let suite = UserDefaults.standard
    static let keyDisplayID = "selectedDisplayID"
    static let keyHotKeyCode = "hotKeyCode"
    static let keyHotKeyMods = "hotKeyModifiers"

    static var displayID: CGDirectDisplayID {
        get { UInt32(suite.integer(forKey: keyDisplayID)) }
        set { suite.set(Int(newValue), forKey: keyDisplayID) }
    }

    static var hotKeyCode: UInt32 {
        get {
            let v = suite.integer(forKey: keyHotKeyCode)
            return v == 0 ? 122 : UInt32(v) // default F1
        }
        set { suite.set(Int(newValue), forKey: keyHotKeyCode) }
    }

    static var hotKeyModifiers: UInt32 {
        get {
            let v = suite.integer(forKey: keyHotKeyMods)
            return v == 0 ? UInt32(cmdKey | shiftKey) : UInt32(v)
        }
        set { suite.set(Int(newValue), forKey: keyHotKeyMods) }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var externalEnabled = true
    var hotKeyRef: EventHotKeyRef?
    var prefsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        setupStatusItem()
        registerHotKey()
    }

    // MARK: - Menu Bar

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()
        rebuildMenu()
    }

    func rebuildMenu() {
        let menu = NSMenu()

        // Display selection submenu
        let displayMenu = NSMenu()
        let displays = getDisplayList()
        let selectedID = TagglePrefs.displayID

        for (id, name) in displays {
            let item = NSMenuItem(title: name, action: #selector(selectDisplay(_:)), keyEquivalent: "")
            item.tag = Int(id)
            item.target = self
            if id == selectedID { item.state = .on }
            displayMenu.addItem(item)
        }

        let displayItem = NSMenuItem(title: "Target Display", action: nil, keyEquivalent: "")
        displayItem.submenu = displayMenu
        menu.addItem(displayItem)

        // Toggle
        menu.addItem(NSMenuItem(title: "Toggle Display", action: #selector(toggleDisplay), keyEquivalent: ""))

        menu.addItem(NSMenuItem.separator())

        // Shortcut config
        menu.addItem(NSMenuItem(title: "Change Shortcut...", action: #selector(openPrefs), keyEquivalent: ""))

        // Current shortcut display
        let currentShortcut = shortcutLabel(code: TagglePrefs.hotKeyCode, mods: TagglePrefs.hotKeyModifiers)
        let infoItem = NSMenuItem(title: "Shortcut: \(currentShortcut)", action: nil, keyEquivalent: "")
        infoItem.isEnabled = false
        menu.addItem(infoItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Taggle", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    func updateIcon() {
        if let button = statusItem.button {
            button.title = externalEnabled ? "⬜" : "⬛"
        }
    }

    // MARK: - Display Management

    func getDisplayList() -> [(CGDirectDisplayID, String)] {
        let maxDisplays: UInt32 = 8
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var count: UInt32 = 0
        CGGetOnlineDisplayList(maxDisplays, &displays, &count)

        NSLog("Taggle: found \(count) online display(s)")
        var result: [(CGDirectDisplayID, String)] = []
        for i in 0..<Int(count) {
            let id = displays[i]
            let w = CGDisplayPixelsWide(id)
            let h = CGDisplayPixelsHigh(id)
            let builtin = CGDisplayIsBuiltin(id) != 0
            NSLog("Taggle:   display \(id): \(w)x\(h), builtin=\(builtin)")
            if builtin { continue }
            let name = "Display \(id) (\(w)x\(h))"
            result.append((id, name))
        }
        return result
    }

    func resolveTargetDisplay() -> CGDirectDisplayID? {
        let saved = TagglePrefs.displayID
        let displays = getDisplayList()

        // If saved display is still connected, use it
        if saved != 0, displays.contains(where: { $0.0 == saved }) {
            return saved
        }
        // Fallback: first external display
        if let first = displays.first {
            TagglePrefs.displayID = first.0
            rebuildMenu()
            return first.0
        }
        return nil
    }

    @objc func selectDisplay(_ sender: NSMenuItem) {
        TagglePrefs.displayID = UInt32(sender.tag)
        rebuildMenu()
    }

    @objc func toggleDisplay() {
        guard let extID = resolveTargetDisplay() else {
            notify("No external display found")
            return
        }

        guard let getConn = _CGSMainConnectionID, let configDisplay = _CGSConfigureDisplayEnabled else {
            notify("CGS APIs not available on this macOS version")
            return
        }

        externalEnabled.toggle()
        let cid = getConn()
        let enabledVal: Int32 = externalEnabled ? 1 : 0
        NSLog("Taggle: about to call CGSConfigureDisplayEnabled(cid=\(cid), display=\(extID), enabled=\(enabledVal))")
        fflush(stdout)
        let err = configDisplay(cid, extID, enabledVal)
        NSLog("Taggle: call returned \(err.rawValue)")

        if err != .success {
            externalEnabled.toggle()
            notify("Failed to toggle display (error \(err.rawValue))")
        } else {
            notify(externalEnabled ? "Display ON" : "Display OFF")
        }
        updateIcon()
    }

    // MARK: - Preferences Window

    @objc func openPrefs() {
        if let w = prefsWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        w.title = "Change Shortcut"
        w.center()
        w.isReleasedWhenClosed = false

        let view = NSView(frame: w.contentView!.bounds)

        let label = NSTextField(labelWithString: "Click below, then press your shortcut:")
        label.frame = NSRect(x: 20, y: 70, width: 320, height: 20)
        view.addSubview(label)

        let field = ShortcutField(frame: NSRect(x: 20, y: 30, width: 320, height: 28))
        field.stringValue = shortcutLabel(code: TagglePrefs.hotKeyCode, mods: TagglePrefs.hotKeyModifiers)
        field.alignment = .center
        field.isEditable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.onShortcutCaptured = { [weak self] keyCode, mods in
            TagglePrefs.hotKeyCode = keyCode
            TagglePrefs.hotKeyModifiers = mods
            self?.registerHotKey()
            self?.rebuildMenu()
        }
        view.addSubview(field)

        w.contentView = view
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        prefsWindow = w
    }

    // MARK: - Global Hotkey

    func registerHotKey() {
        // Unregister previous
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }

        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x5447474C) // "TGGL"
        hotKeyID.id = 1

        var eventType = EventTypeSpec()
        eventType.eventClass = OSType(kEventClassKeyboard)
        eventType.eventKind = UInt32(kEventHotKeyPressed)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { (_, _, userData) -> OSStatus in
            guard let userData = userData else { return OSStatus(eventNotHandledErr) }
            let d = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            d.toggleDisplay()
            return noErr
        }, 1, &eventType, selfPtr, nil)

        RegisterEventHotKey(
            TagglePrefs.hotKeyCode,
            TagglePrefs.hotKeyModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    // MARK: - Helpers

    func notify(_ text: String) {
        let content = UNMutableNotificationContent()
        content.title = "Taggle"
        content.body = text
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func shortcutLabel(code: UInt32, mods: UInt32) -> String {
        var parts: [String] = []
        if mods & UInt32(controlKey) != 0 { parts.append("Ctrl") }
        if mods & UInt32(optionKey) != 0 { parts.append("Opt") }
        if mods & UInt32(shiftKey) != 0 { parts.append("Shift") }
        if mods & UInt32(cmdKey) != 0 { parts.append("Cmd") }
        parts.append(ShortcutField(frame: .zero).keyName(UInt16(code)))
        return parts.joined(separator: "+")
    }
}

// MARK: - Launch

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
