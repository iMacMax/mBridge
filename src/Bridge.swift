import Cocoa

// The core: finds other computers, keeps the connection, and decides whether the keyboard and mouse
// drive this Mac or the computer you are controlling. Push the cursor against the edge where the other
// computer sits to cross over. Any computer can also be controlled by another one (see Receiver).

@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> Int32
@_silgen_name("CGSSetConnectionProperty")
func CGSSetConnectionProperty(_ cid: Int32, _ target: Int32, _ key: CFString, _ value: CFTypeRef) -> Int32

enum Mode { case mac, pc }

private func mouseDelta(_ event: CGEvent) -> CGPoint {
    CGPoint(x: Double(event.getIntegerValueField(.mouseEventDeltaX)), y: Double(event.getIntegerValueField(.mouseEventDeltaY)))
}

final class Bridge {
    static let macName = (Host.current().localizedName ?? "Mac").replacingOccurrences(of: "|", with: "/")
    static let defaultPCSize = CGSize(width: 1920, height: 1080)

    let selfID: String
    private(set) var peers: [String: Peer] = [:]
    private(set) var mode: Mode = .mac
    private(set) var connectedName: String?
    private(set) var connectedID: String?
    private(set) var connectedPlatform = "win"
    private(set) var controllerName: String?   // the computer that is controlling this Mac, if any
    private(set) var status = "Looking for a computer…"
    var isConnected: Bool { link != nil }
    var isControlled: Bool { incoming != nil }
    var onChange: (() -> Void)?

    /// The layout and screen size are remembered for each computer, so they can be arranged before it is found.
    private var arrangements: [String: Arrangement] = [:]
    private var sizes: [String: CGSize] = [:]
    private var targetKey: String { connectedID ?? lastPeerID ?? "default" }

    var arrangement: Arrangement {
        get { arrangements[targetKey] ?? arrangements["default"] ?? Arrangement.standard.centered(mac: macBounds().size, pc: pcSize) }
        set {
            arrangements[targetKey] = newValue
            if let data = try? JSONEncoder().encode(arrangements) { defaults.set(data, forKey: "arrangements") }
        }
    }

    /// The other computer's screen size.
    var pcSize: CGSize { sizes[targetKey] ?? sizes["default"] ?? Bridge.defaultPCSize }

    private let defaults = UserDefaults.standard
    private let discovery = Discovery()
    private let beacon = Beacon()
    private let server = Server()
    let receiver = Receiver()
    private var link: Link?                 // the computer we are controlling
    private var incoming: Link?             // the computer controlling us
    private var connecting = false
    private var paused = false              // the user chose Disconnect: don't reconnect on our own
    private var lastAttempt = Date.distantPast
    private var lastPeerID: String?
    private(set) var manualHost: String?

    private var pcPos = CGPoint.zero        // where the cursor is on the other computer (its pixels)
    private var returnPoint = CGPoint.zero  // where the cursor goes on this Mac if the connection ends
    private var lastSwitch = Date.distantPast
    private var cursorHidden = false
    private var moveQueued = false
    private var pasteboardCount = NSPasteboard.general.changeCount
    private var ignoreMovesUntil = Date.distantPast   // moving the Mac cursor ourselves reports a fake jump

    /// Shared secret: the other computer remembers the first one that shows it and refuses every other one.
    private let key: String

    init() {
        if let data = defaults.data(forKey: "arrangements"),
           let saved = try? JSONDecoder().decode([String: Arrangement].self, from: data) {
            arrangements = saved
        } else if let data = defaults.data(forKey: "arrangement"), let old = try? JSONDecoder().decode(Arrangement.self, from: data) {
            arrangements["default"] = old   // from before there was more than one computer
        }
        let w = defaults.double(forKey: "pcWidth"), h = defaults.double(forKey: "pcHeight")
        if w > 0, h > 0 { sizes["default"] = CGSize(width: w, height: h) }
        if let data = defaults.data(forKey: "sizes"), let saved = try? JSONDecoder().decode([String: CGSize].self, from: data) {
            sizes.merge(saved) { _, new in new }
        }
        lastPeerID = defaults.string(forKey: "lastPeer")
        manualHost = defaults.string(forKey: "manualHost")
        if let saved = defaults.string(forKey: "selfID") {
            selfID = saved
        } else {
            selfID = "mac-" + (0..<4).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
            defaults.set(selfID, forKey: "selfID")
        }
        if let saved = defaults.string(forKey: "pairKey") {
            key = saved
        } else {
            key = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
            defaults.set(key, forKey: "pairKey")
        }
        receiver.setCursorHidden = { [weak self] in self?.setCursorHidden($0) }
    }

    func start() {
        CGAssociateMouseAndMouseCursorPosition(1)   // in case an earlier run left the cursor frozen
        discovery.start(selfID: selfID) { [weak self] peer in self?.found(peer) }
        beacon.start { [selfID] in
            let screen = macBounds().size
            return "mBridge|\(selfID)|\(Bridge.macName)|\(Int(screen.width))|\(Int(screen.height))|\(Server.port)|mac"
        }
        server.start(size: { macBounds().size }) { [weak self] name, newLink in self?.accepted(name, newLink) }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.watchClipboard() }
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.receiver.showCursorIfUserMovedMouse() }
        tick()
    }

    // MARK: Connecting

    private func found(_ peer: Peer) {
        peers[peer.id] = peer
        learnSize(peer.size, for: peer.id)
        autoConnect()
        onChange?()
    }

    private func tick() {
        link?.send(".")
        incoming?.send(".")
        if mode == .pc, link == nil { leavePC(to: returnPoint) }
        let before = peers.count
        peers = peers.filter { Date().timeIntervalSince($0.value.seen) < 5 }
        if link == nil, incoming == nil, !connecting {
            autoConnect()
            if peers.isEmpty { status = manualHost.map { "Trying \($0)…" } ?? "Looking for a computer…" }
        }
        if peers.count != before { onChange?() }
    }

    private func autoConnect() {
        guard link == nil, incoming == nil, !connecting, !paused, Date().timeIntervalSince(lastAttempt) > 3 else { return }
        if let peer = peers[lastPeerID ?? ""] ?? (lastPeerID == nil && peers.count == 1 ? peers.values.first : nil) {
            connect(host: peer.host, port: peer.port, id: peer.id)
        } else if peers.isEmpty, let host = manualHost {
            connect(host: host, port: Server.port, id: nil)
        }
    }

    /// The user picked a computer from the menu: take control of it.
    func choose(_ peer: Peer) {
        lastPeerID = peer.id
        defaults.set(peer.id, forKey: "lastPeer")
        paused = false
        disconnect()
        incoming?.hangUp()   // one role at a time: stop being controlled while we control
        connect(host: peer.host, port: peer.port, id: peer.id)
    }

    func connectManually(_ host: String) {
        manualHost = host
        defaults.set(host, forKey: "manualHost")
        paused = false
        disconnect()
        incoming?.hangUp()
        connect(host: host, port: Server.port, id: nil)
    }

    func pause() {
        paused = true
        disconnect()
        status = "Disconnected"
        onChange?()
    }

    var isPaused: Bool { paused }

    /// Lets the computer that is controlling this Mac go.
    func releaseController() { incoming?.hangUp() }

    private func connect(host: String, port: UInt16, id: String?) {
        guard !connecting, link == nil else { return }
        connecting = true
        lastAttempt = Date()
        status = "Connecting to \(peers[id ?? ""]?.name ?? host)…"
        onChange?()
        let hello = "hi \(key) \(Bridge.macName)\nplat mac"
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
            status = "\(peers[id ?? ""]?.name ?? host) is paired with another computer"
        case .ok(let newLink, let size):
            guard link == nil, incoming == nil else { newLink.finish(); break }   // something else won in the meantime
            link = newLink
            connectedID = id ?? host
            connectedName = peers[id ?? ""]?.name ?? host
            connectedPlatform = peers[id ?? ""]?.platform ?? "win"
            status = "Connected to \(connectedName!)"
            learnSize(size, for: connectedID!)
            newLink.send("hide")   // the other computer's cursor stays out of sight until you cross over
            pasteboardCount = NSPasteboard.general.changeCount   // only copies made from now on are shared
            newLink.listen(onLine: { [weak self] in self?.receivedFromTarget($0) }, onClose: { [weak self, weak newLink] in
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
        connectedID = nil
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
        connectedID = nil
        old.finish()
    }

    private func learnSize(_ size: CGSize, for id: String) {
        guard size.width > 0, size.height > 0, sizes[id] != size else { return }
        sizes[id] = size
        if let data = try? JSONEncoder().encode(sizes) { defaults.set(data, forKey: "sizes") }
    }

    // MARK: Being controlled

    /// Another computer wants to control this Mac.
    private func accepted(_ name: String, _ newLink: Link) {
        incoming?.hangUp()
        if link != nil || mode == .pc {   // one role at a time: stop controlling while we are controlled
            paused = true
            disconnect()
        }
        incoming = newLink
        controllerName = name
        status = "Controlled by \(name)"
        pasteboardCount = NSPasteboard.general.changeCount
        newLink.listen(onLine: { [weak self] in self?.receivedAsReceiver($0) }, onClose: { [weak self, weak newLink] in
            guard let self, let newLink else { return }
            self.controllerClosed(newLink)
        })
        onChange?()
    }

    private func controllerClosed(_ closedLink: Link) {
        closedLink.finish()
        guard incoming === closedLink else { return }
        incoming = nil
        controllerName = nil
        receiver.reset()
        status = "Looking for a computer…"
        onChange?()
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
    func setCursorHidden(_ hide: Bool) {
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
        receiver.reset()
        link?.finish()
        incoming?.finish()
    }

    // MARK: Clipboard

    /// Text you copy here is sent to the other computer, whichever way you are connected.
    /// Copies marked as secret (password managers) are never sent.
    private func watchClipboard() {
        let board = NSPasteboard.general
        guard board.changeCount != pasteboardCount else { return }
        pasteboardCount = board.changeCount
        let types = board.types?.map(\.rawValue) ?? []
        guard link != nil || incoming != nil, !types.contains("org.nspasteboard.ConcealedType"),
              !types.contains("org.nspasteboard.TransientType"),
              let text = board.string(forType: .string), !text.isEmpty, text.utf8.count <= 256_000 else { return }
        let line = "c " + Data(text.utf8).base64EncodedString()
        link?.send(line)
        incoming?.send(line)
    }

    /// Text copied on the other computer arrives as "c <base64>".
    private func applyClipboard(_ line: String) {
        guard line.hasPrefix("c "), let data = Data(base64Encoded: String(line.dropFirst(2))),
              let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text.replacingOccurrences(of: "\r\n", with: "\n"), forType: .string)
        pasteboardCount = board.changeCount
    }

    /// Lines from the computer we are controlling: only clipboard text (and its heartbeat).
    private func receivedFromTarget(_ line: String) { applyClipboard(line) }

    /// Lines from the computer controlling us: clipboard text, or input to replay here.
    private func receivedAsReceiver(_ line: String) {
        if line.hasPrefix("c ") { applyClipboard(line) } else { receiver.handle(line) }
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
