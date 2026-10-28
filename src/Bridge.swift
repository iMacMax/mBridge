import Cocoa

// The core: finds the PC, keeps the connection, and decides whether the keyboard and mouse
// drive the Mac or the PC. Push the cursor against the edge where the PC sits to cross over.

@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> Int32
@_silgen_name("CGSSetConnectionProperty")
func CGSSetConnectionProperty(_ cid: Int32, _ target: Int32, _ key: CFString, _ value: CFTypeRef) -> Int32

enum Mode { case mac, pc }

private func mouseDelta(_ event: CGEvent) -> CGPoint {
    CGPoint(x: Double(event.getIntegerValueField(.mouseEventDeltaX)), y: Double(event.getIntegerValueField(.mouseEventDeltaY)))
}

final class Bridge {
    static let macName = Host.current().localizedName ?? "Mac"
    static let defaultPCSize = CGSize(width: 1920, height: 1080)

    private(set) var peers: [String: Peer] = [:]
    private(set) var mode: Mode = .mac
    private(set) var connectedName: String?
    private(set) var status = "Looking for a PC…"
    var isConnected: Bool { link != nil }
    var onChange: (() -> Void)?

    /// The PC's screen size, remembered so the layout can be arranged before the PC is found.
    private(set) var pcSize: CGSize
    var arrangement: Arrangement {
        didSet {
            if let data = try? JSONEncoder().encode(arrangement) { defaults.set(data, forKey: "arrangement") }
        }
    }

    private let defaults = UserDefaults.standard
    private let discovery = Discovery()
    private var link: Link?
    private var connecting = false
    private var paused = false              // the user chose Disconnect: don't reconnect on our own
    private var lastAttempt = Date.distantPast
    private var lastPeerID: String?
    private(set) var manualHost: String?

    private var pcPos = CGPoint.zero        // where the cursor is on the PC (PC pixels)
    private var returnPoint = CGPoint.zero  // where the cursor goes on the Mac if the connection ends
    private var lastSwitch = Date.distantPast
    private var cursorHidden = false
    private var moveQueued = false
    private var pasteboardCount = NSPasteboard.general.changeCount
    private var ignoreMovesUntil = Date.distantPast   // moving the Mac cursor ourselves reports a fake jump

    /// Shared secret: the PC remembers the first Mac that shows it and refuses every other one.
    private let key: String

    init() {
        if let data = defaults.data(forKey: "arrangement"), let saved = try? JSONDecoder().decode(Arrangement.self, from: data) {
            arrangement = saved
        } else {
            arrangement = .standard
        }
        let w = defaults.double(forKey: "pcWidth"), h = defaults.double(forKey: "pcHeight")
        pcSize = w > 0 && h > 0 ? CGSize(width: w, height: h) : Bridge.defaultPCSize
        lastPeerID = defaults.string(forKey: "lastPeer")
        manualHost = defaults.string(forKey: "manualHost")
        if let saved = defaults.string(forKey: "pairKey") {
            key = saved
        } else {
            key = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
            defaults.set(key, forKey: "pairKey")
        }
    }

    func start() {
        CGAssociateMouseAndMouseCursorPosition(1)   // in case an earlier run left the cursor frozen
        discovery.start { [weak self] peer in self?.found(peer) }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.watchClipboard() }
        tick()
    }

    // MARK: Connecting

    private func found(_ peer: Peer) {
        peers[peer.id] = peer
        if peer.id == lastPeerID || lastPeerID == nil { learnSize(peer.size) }
        autoConnect()
        onChange?()
    }

    private func tick() {
        link?.send(".")
        if mode == .pc, link == nil { leavePC(to: returnPoint) }
        let before = peers.count
        peers = peers.filter { Date().timeIntervalSince($0.value.seen) < 5 }
        if link == nil, !connecting {
            autoConnect()
            if peers.isEmpty { status = manualHost.map { "Trying \($0)…" } ?? "Looking for a PC…" }
        }
        if peers.count != before { onChange?() }
    }

    private func autoConnect() {
        guard link == nil, !connecting, !paused, Date().timeIntervalSince(lastAttempt) > 3 else { return }
        if let peer = peers[lastPeerID ?? ""] ?? (lastPeerID == nil ? peers.values.first : nil) {
            connect(host: peer.host, port: peer.port, id: peer.id)
        } else if peers.isEmpty, let host = manualHost {
            connect(host: host, port: 24802, id: nil)
        }
    }

    /// The user picked a PC from the menu.
    func choose(_ peer: Peer) {
        lastPeerID = peer.id
        defaults.set(peer.id, forKey: "lastPeer")
        paused = false
        disconnect()
        connect(host: peer.host, port: peer.port, id: peer.id)
    }

    func connectManually(_ host: String) {
        manualHost = host
        defaults.set(host, forKey: "manualHost")
        paused = false
        disconnect()
        connect(host: host, port: 24802, id: nil)
    }

    func pause() {
        paused = true
        disconnect()
        status = "Disconnected"
        onChange?()
    }

    func resume() {
        paused = false
        lastAttempt = .distantPast
        autoConnect()
        onChange?()
    }

    var isPaused: Bool { paused }

    private func connect(host: String, port: UInt16, id: String?) {
        guard !connecting, link == nil else { return }
        connecting = true
        lastAttempt = Date()
        status = "Connecting to \(host)…"
        onChange?()
        let hello = "hi \(key) \(Bridge.macName)"
        DispatchQueue.global().async {
            let result = Link.open(host: host, port: port, hello: hello)
            DispatchQueue.main.async { self.opened(result, id: id, host: host) }
        }
    }

    private func opened(_ result: OpenResult, id: String?, host: String) {
        connecting = false
        switch result {
        case .failed:
            status = "Can't reach \(peers[id ?? ""]?.name ?? host)"
        case .denied:
            status = "PC is paired with another Mac"
        case .ok(let newLink, let size):
            link = newLink
            connectedName = peers[id ?? ""]?.name ?? host
            status = "Connected to \(connectedName!)"
            learnSize(size)
            newLink.send("hide")   // the PC's cursor stays out of sight until you cross over
            pasteboardCount = NSPasteboard.general.changeCount   // only copies made from now on are shared
            newLink.listen(onLine: { [weak self] in self?.received($0) }, onClose: { [weak self, weak newLink] in
                guard let self, let newLink else { return }
                self.closed(newLink)
            })
        }
        onChange?()
    }

    private func closed(_ closedLink: Link) {
        closedLink.finish()
        guard link === closedLink else { return }
        link = nil
        connectedName = nil
        status = "Connection lost"
        if mode == .pc { leavePC(to: returnPoint) }
        lastAttempt = Date()
        onChange?()
    }

    private func disconnect() {
        guard let old = link else { return }
        if mode == .pc { leavePC(to: returnPoint) }
        link = nil
        connectedName = nil
        old.finish()
    }

    private func learnSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != pcSize else { return }
        pcSize = size
        defaults.set(size.width, forKey: "pcWidth")
        defaults.set(size.height, forKey: "pcHeight")
    }

    // MARK: Switching

    /// Menu item: jump to the PC (or back) without touching the edge.
    func toggleFromMenu() {
        if mode == .pc { leavePC(to: returnPoint); return }
        guard isConnected else { return }
        let mac = macBounds()
        let r = arrangement.pcRect(mac: mac, pc: pcSize)
        let here = CGEvent(source: nil)?.location ?? CGPoint(x: mac.midX, y: mac.midY)
        enterPC(at: CGPoint(x: r.width / 2, y: r.height / 2), from: here)
    }

    private func enterPC(at entry: CGPoint, from macPoint: CGPoint) {
        let mac = macBounds()
        returnPoint = CGPoint(x: min(max(macPoint.x, mac.minX + 3), mac.maxX - 3),
                              y: min(max(macPoint.y, mac.minY + 3), mac.maxY - 3))
        pcPos = entry
        mode = .pc
        lastSwitch = Date()
        send("show")
        send("p \(Int(entry.x)) \(Int(entry.y))")
        // Hide first, then park the cursor mid-screen (away from the Dock and hot corners) and freeze it:
        // swallowing mouse events does not stop macOS from moving the cursor, only this does.
        setCursorHidden(true)
        let main = CGDisplayBounds(CGMainDisplayID())
        ignoreMovesUntil = Date().addingTimeInterval(0.1)
        CGWarpMouseCursorPosition(CGPoint(x: main.midX, y: main.midY))
        CGAssociateMouseAndMouseCursorPosition(0)
        onChange?()
    }

    private func leavePC(to point: CGPoint) {
        guard mode == .pc else { return }
        mode = .mac
        lastSwitch = Date()
        send("r")
        send("hide")
        CGAssociateMouseAndMouseCursorPosition(1)
        ignoreMovesUntil = Date().addingTimeInterval(0.1)
        CGWarpMouseCursorPosition(point)
        setCursorHidden(false)
        onChange?()
    }

    /// A background app can't normally hide the cursor; this connection property allows it.
    private func setCursorHidden(_ hide: Bool) {
        guard hide != cursorHidden else { return }
        cursorHidden = hide
        if hide {
            let cid = CGSMainConnectionID()
            _ = CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
            CGDisplayHideCursor(CGMainDisplayID())
        } else {
            CGDisplayShowCursor(CGMainDisplayID())
        }
    }

    /// The event listener was switched off by macOS: never stay on the PC with the keyboard and mouse stuck there.
    func failsafe() {
        if mode == .pc { leavePC(to: returnPoint) }
    }

    func shutDown() {
        if mode == .pc { leavePC(to: returnPoint) }
        CGAssociateMouseAndMouseCursorPosition(1)
        setCursorHidden(false)
        link?.finish()
    }

    // MARK: Clipboard

    /// Text you copy here is sent to the PC. Copies marked as secret (password managers) are never sent.
    private func watchClipboard() {
        let board = NSPasteboard.general
        guard board.changeCount != pasteboardCount else { return }
        pasteboardCount = board.changeCount
        let types = board.types?.map(\.rawValue) ?? []
        guard link != nil, !types.contains("org.nspasteboard.ConcealedType"), !types.contains("org.nspasteboard.TransientType"),
              let text = board.string(forType: .string), !text.isEmpty, text.utf8.count <= 256_000 else { return }
        send("c " + Data(text.utf8).base64EncodedString())
    }

    /// Text copied on the PC arrives as "c <base64>".
    private func received(_ line: String) {
        guard line.hasPrefix("c "), let data = Data(base64Encoded: String(line.dropFirst(2))),
              let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text.replacingOccurrences(of: "\r\n", with: "\n"), forType: .string)
        pasteboardCount = board.changeCount
    }

    // MARK: Events

    private func send(_ line: String) { link?.send(line) }

    /// Sends the newest cursor position a few milliseconds later, so a fast mouse doesn't flood the network.
    private func queueMove() {
        guard !moveQueued else { return }
        moveQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.004) { [weak self] in self?.flushMove() }
    }

    private func flushMove() {
        guard moveQueued else { return }
        moveQueued = false
        if mode == .pc { send("p \(Int(pcPos.x)) \(Int(pcPos.y))") }
    }

    /// Called for every key and mouse event. Returns true to swallow it (it went to the PC instead).
    func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        guard link != nil else { return false }
        if mode == .mac { return watchEdge(type, event) }
        forward(type, event)
        return true
    }

    private func watchEdge(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard NSEvent.pressedMouseButtons == 0, Date().timeIntervalSince(lastSwitch) > 0.25 else { return false }
            let delta = mouseDelta(event)
            let at = event.location
            if let entry = arrangement.entry(from: at, delta: delta, mac: macBounds(), pc: pcSize) {
                enterPC(at: entry, from: at)
                return true
            }
        default:
            break
        }
        return false
    }

    private func forward(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            move(by: mouseDelta(event))
        case .leftMouseDown: button(0, down: true)
        case .leftMouseUp: button(0, down: false)
        case .rightMouseDown: button(1, down: true)
        case .rightMouseUp: button(1, down: false)
        case .otherMouseDown: button(Int(event.getIntegerValueField(.mouseEventButtonNumber)), down: true)
        case .otherMouseUp: button(Int(event.getIntegerValueField(.mouseEventButtonNumber)), down: false)
        case .scrollWheel:
            flushMove()
            let dy = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
            let dx = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
            if dx != 0 || dy != 0 { send("w \(dx) \(dy)") }
        case .keyDown, .keyUp:
            key(event, down: type == .keyDown)
        case .flagsChanged:
            modifier(event)
        default:
            break
        }
    }

    private func move(by delta: CGPoint) {
        guard Date() > ignoreMovesUntil else { return }
        let mac = macBounds()
        var next = CGPoint(x: pcPos.x + delta.x, y: pcPos.y + delta.y)
        if let back = arrangement.exit(from: next, mac: mac, pc: pcSize) {
            leavePC(to: back)
            return
        }
        next.x = min(max(next.x, 0), pcSize.width - 1)
        next.y = min(max(next.y, 0), pcSize.height - 1)
        pcPos = next
        queueMove()
    }

    private func button(_ number: Int, down: Bool) {
        flushMove()
        send("b \(number) \(down ? 1 : 0)")
    }

    private func key(_ event: CGEvent, down: Bool) {
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        // Emergency exit: Control+Option+Command+Esc always brings the keyboard and mouse back to the Mac.
        if down, code == 53, event.flags.isSuperset(of: [.maskControl, .maskAlternate, .maskCommand]) {
            leavePC(to: returnPoint)
            return
        }
        guard let win = winKeys[code] else { return }
        flushMove()
        send("k \(win.vk) \(win.extended ? 1 : 0) \(down ? 1 : 0)")
    }

    private func modifier(_ event: CGEvent) {
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        flushMove()
        if code == capsLockKeyCode {   // Caps Lock is a toggle on both sides: tap it
            send("k \(capsLockKey.vk) 0 1")
            send("k \(capsLockKey.vk) 0 0")
        } else if let (win, flag) = winModifiers[code] {
            send("k \(win.vk) \(win.extended ? 1 : 0) \(event.flags.contains(flag) ? 1 : 0)")
        }
    }
}

