import Cocoa

// What this Mac does when another computer controls it: the other computer's keyboard and mouse
// arrive as lines and are replayed here as real events. Needs the Accessibility permission.

final class Receiver {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var heldKeys = Set<Int>()        // Mac key codes currently down
    private var heldButtons = Set<Int>()
    private var flags: CGEventFlags = []     // modifiers currently down
    private var lastPoint = CGPoint.zero     // where we last put the cursor (global, top-left origin)
    private var scrollScale: Int32 = 1      // a Windows wheel notch is only about 10 pixels, which feels slow here
    private var click = (time: Date.distantPast, point: CGPoint.zero, button: -1, count: 0)

    /// Hides or shows the cursor (the controller hides it here while the mouse is on its own screen).
    var setCursorHidden: ((Bool) -> Void)?
    private var hiddenByController = false

    func handle(_ line: String) {
        let f = line.split(separator: " ")
        guard let command = f.first else { return }
        switch command {
        case "p" where f.count >= 3:
            if let x = Double(f[1]), let y = Double(f[2]) { move(toX: x, y: y) }
        case "b" where f.count >= 3:
            if let n = Int(f[1]), let down = Int(f[2]) { button(n, down: down == 1) }
        case "w" where f.count >= 3:
            if let dx = Int32(f[1]), let dy = Int32(f[2]) { scroll(dx: dx, dy: dy) }
        case "k" where f.count >= 4:
            if let vk = Int(f[1]), let ext = Int(f[2]), let down = Int(f[3]) { key(vk: vk, extended: ext == 1, down: down == 1) }
        case "plat" where f.count >= 2: scrollScale = f[1] == "win" ? 3 : 1
        case "r": releaseAll()
        case "hide": hiddenByController = true; lastPoint = currentLocation(); setCursorHidden?(true)
        case "show": hiddenByController = false; setCursorHidden?(false)
        default: break
        }
    }

    /// The controller took the cursor away; if this Mac's own mouse moves, the cursor comes back.
    func showCursorIfUserMovedMouse() {
        guard hiddenByController else { return }
        let here = currentLocation()
        if abs(here.x - lastPoint.x) > 3 || abs(here.y - lastPoint.y) > 3 {
            hiddenByController = false
            setCursorHidden?(false)
        }
    }

    /// Lets go of everything still held, so a key or button never gets stuck when the controller leaves.
    func releaseAll() {
        for code in heldKeys { post(keyCode: code, down: false) }
        heldKeys.removeAll()
        for number in heldButtons { post(button: number, down: false, at: lastPoint) }
        heldButtons.removeAll()
        flags = []
    }

    func reset() {
        releaseAll()
        hiddenByController = false
        setCursorHidden?(false)
    }

    private func currentLocation() -> CGPoint { CGEvent(source: nil)?.location ?? lastPoint }

    // MARK: Mouse

    private func move(toX x: Double, y: Double) {
        let screen = macBounds()
        let point = CGPoint(x: min(max(screen.minX + x, screen.minX), screen.maxX - 1),
                            y: min(max(screen.minY + y, screen.minY), screen.maxY - 1))
        let type: CGEventType = heldButtons.contains(0) ? .leftMouseDragged
            : heldButtons.contains(1) ? .rightMouseDragged
            : heldButtons.isEmpty ? .mouseMoved : .otherMouseDragged
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(point.x - lastPoint.x))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(point.y - lastPoint.y))
        event.post(tap: .cghidEventTap)
        lastPoint = point
    }

    private func button(_ number: Int, down: Bool) {
        if down {
            heldButtons.insert(number)
            // double and triple clicks: count clicks that follow each other closely in the same place
            let now = Date()
            if click.button == number, now.timeIntervalSince(click.time) < NSEvent.doubleClickInterval,
               abs(lastPoint.x - click.point.x) < 5, abs(lastPoint.y - click.point.y) < 5 {
                click.count += 1
            } else {
                click.count = 1
            }
            click.time = now
            click.point = lastPoint
            click.button = number
        } else {
            heldButtons.remove(number)
        }
        post(button: number, down: down, at: lastPoint)
    }

    private func post(button number: Int, down: Bool, at point: CGPoint) {
        let type: CGEventType
        let which: CGMouseButton
        switch number {
        case 0: type = down ? .leftMouseDown : .leftMouseUp; which = .left
        case 1: type = down ? .rightMouseDown : .rightMouseUp; which = .right
        default: type = down ? .otherMouseDown : .otherMouseUp; which = CGMouseButton(rawValue: UInt32(number)) ?? .center
        }
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: which) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(max(click.count, 1)))
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    private func scroll(dx: Int32, dy: Int32) {
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: dy * scrollScale, wheel2: dx * scrollScale, wheel3: 0) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    // MARK: Keyboard

    private func key(vk: Int, extended: Bool, down: Bool) {
        if let modifier = macModifiers[vk] {
            if down { flags.insert(modifier.flag) } else { flags.remove(modifier.flag) }
            if down { heldKeys.insert(modifier.code) } else { heldKeys.remove(modifier.code) }
            post(keyCode: modifier.code, down: down)
            return
        }
        guard let code = macKeys[vk | (extended ? 0x100 : 0)] ?? macKeys[vk] ?? macKeys[vk | 0x100] else { return }
        if down { heldKeys.insert(code) } else { heldKeys.remove(code) }
        post(keyCode: code, down: down)
    }

    private func post(keyCode: Int, down: Bool) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: down) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
}
