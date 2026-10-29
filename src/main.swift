import Cocoa
import ServiceManagement

// mBridge: a monitor icon in your menu bar. Use this Mac's keyboard and mouse on another Mac or a PC on the same
// network, and the other way round. Push the cursor off the edge of the screen where the other computer sits.
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

/// Remembers which computer a menu item belongs to.
final class Ref: NSObject {
    let peer: Peer
    init(_ peer: Peer) { self.peer = peer }
}

/// The small logo shown next to a computer: an Apple for a Mac, four panes for Windows.
func platformIcon(_ platform: String) -> NSImage {
    if platform == "mac", let apple = NSImage(systemSymbolName: "applelogo", accessibilityDescription: "Mac") {
        apple.isTemplate = true
        return apple
    }
    let size = NSSize(width: 14, height: 14)
    let image = NSImage(size: size, flipped: false) { _ in
        NSColor.black.setFill()
        let gap: CGFloat = 1.5, pane = (size.width - gap) / 2
        for column in 0..<2 {
            for row in 0..<2 {
                NSBezierPath(rect: NSRect(x: CGFloat(column) * (pane + gap), y: CGFloat(row) * (pane + gap), width: pane, height: pane)).fill()
            }
        }
        return true
    }
    image.isTemplate = true
    return image
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

    /// The icon is dim until a computer is connected, and shows an arrow while the keyboard and mouse are on the other one.
    private func refreshIcon() {
        statusItem.button?.appearsDisabled = !(bridge.isConnected || bridge.isControlled)
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

        // Computers: click one to control it, click it again to let go.
        for peer in bridge.peers.values.sorted(by: { $0.name < $1.name }) {
            let entry = item(peer.name, #selector(choose(_:)), Ref(peer))
            entry.image = platformIcon(peer.platform)
            entry.state = bridge.isConnected && bridge.connectedID == peer.id ? .on : .off
            menu.addItem(entry)
        }
        if bridge.peers.isEmpty {
            let none = NSMenuItem(title: "No other computers found", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.addItem(item("Enter Address…", #selector(enterAddress)))

        if let controller = bridge.controllerName {
            menu.addItem(.separator())
            menu.addItem(item("Stop Being Controlled by \(controller)", #selector(releaseController)))
        }

        // Position
        if bridge.isConnected {
            menu.addItem(.separator())
            let positionMenu = NSMenu(title: "Position")
            for side in Side.allCases {
                let entry = item(side.title, #selector(setSide(_:)))
                entry.representedObject = side.rawValue
                entry.state = bridge.arrangement.side == side ? .on : .off
                positionMenu.addItem(entry)
            }
            positionMenu.addItem(.separator())
            positionMenu.addItem(item("Arrange…", #selector(openArrange)))
            menu.addItem(row("Position", "\(bridge.connectedName ?? "It") is \(bridge.arrangement.side.title.lowercased())", positionMenu))

            let other = bridge.connectedName ?? "Computer"
            menu.addItem(item(bridge.mode == .pc ? "Back to This Mac   ⌃⌥⌘⎋" : "Switch to \(other)", #selector(toggle)))
        }

        menu.addItem(.separator())
        menu.addItem(item("Forget Paired Computer", #selector(forgetPaired)))
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
        guard let ref = sender.representedObject as? Ref else { return }
        if bridge.isConnected && bridge.connectedID == ref.peer.id { bridge.pause() } else { bridge.choose(ref.peer) }
    }

    @objc func releaseController() { bridge.releaseController() }
    @objc func forgetPaired() { Pairing.forget() }

    @objc func setSide(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let side = Side(rawValue: raw) else { return }
        bridge.arrangement = Arrangement(side: side, offset: 0).centered(mac: macBounds().size, pc: bridge.pcSize)
    }

    @objc func openArrange() {
        arrange.show(bridge: bridge, pcName: bridge.connectedName ?? bridge.peers.values.first?.name ?? "Computer")
    }

    @objc func enterAddress() {
        let alert = NSAlert()
        alert.messageText = "Computer address"
        alert.informativeText = "Only needed if the other computer isn't found by itself. It's the other computer's IP address, like 192.168.1.20."
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
