import Cocoa
import ServiceManagement

// mBridge: a monitor icon in your menu bar. Use this Mac's keyboard and mouse on a PC on the same network.
// Push the cursor off the edge of the screen where the PC sits and it carries on over there.
//
// Permissions (System Settings > Privacy & Security): Input Monitoring to see the keys and mouse,
// Accessibility to take them over while you are on the PC.

let bridge = Bridge()

// MARK: - Event listener

var tap: CFMachPort?

let eventTypes: [CGEventType] = [
    .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged,
    .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel, .keyDown, .keyUp, .flagsChanged,
]

/// An active tap, so everything you do while on the PC is swallowed here instead of also happening on the Mac.
let callback: CGEventTapCallBack = { _, type, event, _ in
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        bridge.failsafe()
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    default:
        if bridge.handle(type, event) { return nil }
    }
    return Unmanaged.passUnretained(event)
}

func installTap() -> Bool {
    guard tap == nil else { return true }
    let mask = eventTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
    guard let newTap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: mask,
        callback: callback,
        userInfo: nil
    ) else { return false }
    tap = newTap
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, newTap, 0), .commonModes)
    CGEvent.tapEnable(tap: newTap, enable: true)
    return true
}

// MARK: - Menu

/// Remembers which PC a menu item belongs to.
final class Ref: NSObject {
    let peer: Peer
    init(_ peer: Peer) { self.peer = peer }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let arrange = ArrangeWindow()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let icon = NSImage(systemSymbolName: "display", accessibilityDescription: "mBridge")
        icon?.isTemplate = true
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = icon
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // first run: start mBridge at every login (it shows in System Settings > General > Login Items)
        if !UserDefaults.standard.bool(forKey: "loginSetupDone") {
            UserDefaults.standard.set(true, forKey: "loginSetupDone")
            try? SMAppService.mainApp.register()
        }

        if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        // Keep retrying until the permissions are granted; no restart is needed afterwards.
        if !installTap() {
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { timer in
                if installTap() { timer.invalidate() }
            }
        }

        bridge.onChange = { [weak self] in self?.refreshIcon() }
        bridge.start()
        refreshIcon()
    }

    func applicationWillTerminate(_ notification: Notification) { bridge.shutDown() }

    /// The icon is dim until a PC is connected, and solid while the keyboard and mouse are on the PC.
    private func refreshIcon() {
        statusItem.button?.appearsDisabled = !bridge.isConnected
        let name = bridge.mode == .pc ? "display.and.arrow.down" : "display"
        let icon = NSImage(systemSymbolName: name, accessibilityDescription: "mBridge") ?? NSImage(systemSymbolName: "display", accessibilityDescription: "mBridge")
        icon?.isTemplate = true
        statusItem.button?.image = icon
    }

    /// A row with the title and a gray value next to it, like mKeys.
    private func row(_ title: String, _ value: String, _ sub: NSMenu) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let label = NSMutableAttributedString(string: title)
        label.append(NSAttributedString(string: "   \(value)", attributes: [
            .foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.menuFont(ofSize: 12)]))
        parent.attributedTitle = label
        parent.submenu = sub
        return parent
    }

    /// Rebuilt every time the menu opens, so it always shows the current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if tap == nil {
            menu.addItem(item("Needs permission: click to open settings", #selector(openSettings)))
            menu.addItem(.separator())
        }

        let status = NSMenuItem(title: bridge.status, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        // PC
        let pcMenu = NSMenu(title: "PC")
        for peer in bridge.peers.values.sorted(by: { $0.name < $1.name }) {
            let entry = item(peer.name, #selector(choose(_:)), Ref(peer))
            entry.state = bridge.isConnected && bridge.connectedName == peer.name ? .on : .off
            pcMenu.addItem(entry)
        }
        if bridge.peers.isEmpty { pcMenu.addItem(NSMenuItem(title: "No PC found", action: nil, keyEquivalent: "")) }
        pcMenu.addItem(.separator())
        pcMenu.addItem(item("Enter Address…", #selector(enterAddress)))
        if bridge.isConnected || (!bridge.isPaused && bridge.manualHost != nil) {
            pcMenu.addItem(item("Disconnect", #selector(pause)))
        } else if bridge.isPaused {
            pcMenu.addItem(item("Connect", #selector(resume)))
        }
        menu.addItem(row("PC", bridge.connectedName ?? "none", pcMenu))

        // Position
        let positionMenu = NSMenu(title: "Position")
        for side in Side.allCases {
            let entry = item(side.title, #selector(setSide(_:)))
            entry.representedObject = side.rawValue
            entry.state = bridge.arrangement.side == side ? .on : .off
            positionMenu.addItem(entry)
        }
        positionMenu.addItem(.separator())
        positionMenu.addItem(item("Arrange…", #selector(openArrange)))
        menu.addItem(row("Position", "PC is \(bridge.arrangement.side.title.lowercased())", positionMenu))

        menu.addItem(.separator())
        let switchItem = item(bridge.mode == .pc ? "Back to Mac   ⌃⌥⌘⎋" : "Switch to PC", #selector(toggle))
        switchItem.isEnabled = bridge.isConnected
        menu.addItem(switchItem)

        menu.addItem(.separator())
        let login = item("Open at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit mBridge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector, _ ref: Ref? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        i.representedObject = ref
        return i
    }

    @objc func choose(_ sender: NSMenuItem) {
        if let ref = sender.representedObject as? Ref { bridge.choose(ref.peer) }
    }

    @objc func setSide(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let side = Side(rawValue: raw) else { return }
        bridge.arrangement = Arrangement(side: side, offset: 0).centered(mac: macBounds().size, pc: bridge.pcSize)
    }

    @objc func openArrange() {
        arrange.show(bridge: bridge, pcName: bridge.connectedName ?? bridge.peers.values.first?.name ?? "PC")
    }

    @objc func enterAddress() {
        let alert = NSAlert()
        alert.messageText = "PC address"
        alert.informativeText = "Only needed if the PC isn't found by itself. It's the PC's IP address, like 192.168.1.20."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = bridge.manualHost ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let host = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !host.isEmpty { bridge.connectManually(host) }
    }

    @objc func pause() { bridge.pause() }
    @objc func resume() { bridge.resume() }
    @objc func toggle() { bridge.toggleFromMenu() }

    @objc func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func toggleLogin() {
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() } else { try? SMAppService.mainApp.register() }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // menu bar only: no Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
