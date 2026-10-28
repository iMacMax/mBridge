import Cocoa

// A small window like System Settings > Displays > Arrange: drag the PC next to your Mac.

/// A panel that can take keyboard focus even though the app has no Dock icon.
final class ArrangePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class ArrangeView: NSView {
    override var isFlipped: Bool { true }

    var mac = CGSize(width: 1512, height: 982)
    var pc = Bridge.defaultPCSize
    var pcName = "PC"
    var arrangement = Arrangement.standard { didSet { needsDisplay = true } }
    var onChange: ((Arrangement) -> Void)?

    private var dragging = false
    private var grab = CGPoint.zero

    /// Fits the Mac plus a PC on every side into the view.
    private var scale: CGFloat {
        min((bounds.width - 40) / (mac.width + 2 * pc.width), (bounds.height - 40) / (mac.height + 2 * pc.height))
    }
    private var origin: CGPoint {
        CGPoint(x: (bounds.width - mac.width * scale) / 2, y: (bounds.height - mac.height * scale) / 2)
    }

    private func viewRect(_ r: CGRect) -> CGRect {
        CGRect(x: origin.x + r.minX * scale, y: origin.y + r.minY * scale, width: r.width * scale, height: r.height * scale)
    }

    private var macRect: CGRect { viewRect(CGRect(origin: .zero, size: mac)) }
    private var pcRect: CGRect { viewRect(arrangement.pcRect(mac: CGRect(origin: .zero, size: mac), pc: pc)) }

    override func draw(_ dirtyRect: NSRect) {
        drawScreen(macRect, name: Bridge.macName, size: mac, fill: .tertiaryLabelColor)
        drawScreen(pcRect, name: pcName, size: pc, fill: .controlAccentColor)
    }

    private func drawScreen(_ rect: CGRect, name: String, size: CGSize, fill: NSColor) {
        let shape = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        fill.withAlphaComponent(0.35).setFill()
        shape.fill()
        fill.setStroke()
        shape.lineWidth = 2
        shape.stroke()

        let title = NSMutableParagraphStyle()
        title.alignment = .center
        title.lineBreakMode = .byTruncatingTail
        let text = NSMutableAttributedString(string: name + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor, .paragraphStyle: title])
        text.append(NSAttributedString(string: "\(Int(size.width)) × \(Int(size.height))", attributes: [
            .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: title]))
        let box = text.boundingRect(with: CGSize(width: rect.width - 8, height: rect.height), options: .usesLineFragmentOrigin)
        text.draw(in: CGRect(x: rect.minX + 4, y: rect.midY - box.height / 2, width: rect.width - 8, height: box.height))
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard pcRect.contains(p) else { return }
        dragging = true
        grab = CGPoint(x: p.x - pcRect.minX, y: p.y - pcRect.minY)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        let p = convert(event.locationInWindow, from: nil)
        // top-left of the dragged PC, in Mac points relative to the Mac's top-left
        let x = (p.x - grab.x - origin.x) / scale, y = (p.y - grab.y - origin.y) / scale
        arrangement = snapped(x: x, y: y)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        onChange?(arrangement)
    }

    /// Picks the side whose edge the PC is nearest to and slides it along that edge, clicking into
    /// top / middle / bottom (or left / middle / right) alignment when it is close.
    private func snapped(x: CGFloat, y: CGFloat) -> Arrangement {
        let nx = (x + pc.width / 2 - mac.width / 2) / ((mac.width + pc.width) / 2)
        let ny = (y + pc.height / 2 - mac.height / 2) / ((mac.height + pc.height) / 2)
        let horizontal = abs(nx) >= abs(ny)
        let side: Side = horizontal ? (nx > 0 ? .right : .left) : (ny > 0 ? .below : .above)

        let along = horizontal ? y : x
        let macLen = horizontal ? mac.height : mac.width
        let pcLen = horizontal ? pc.height : pc.width
        let keep = min(macLen, pcLen) / 3   // the screens must still share part of the edge
        var offset = min(max(along, -pcLen + keep), macLen - keep)
        for aligned in [0, (macLen - pcLen) / 2, macLen - pcLen] where abs(offset - aligned) < 12 / scale { offset = aligned }
        return Arrangement(side: side, offset: Double(offset))
    }
}

final class ArrangeWindow: NSObject, NSWindowDelegate {
    private let panel: ArrangePanel
    private let view = ArrangeView()

    override init() {
        panel = ArrangePanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        panel.title = "mBridge"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.delegate = self

        let hint = NSTextField(labelWithString: "Drag the PC to where it sits next to your Mac")
        hint.font = .systemFont(ofSize: 13, weight: .medium)
        hint.alignment = .center
        hint.frame = NSRect(x: 0, y: 324, width: 520, height: 20)
        view.frame = NSRect(x: 0, y: 0, width: 520, height: 316)
        panel.contentView?.addSubview(view)
        panel.contentView?.addSubview(hint)
    }

    func show(bridge: Bridge, pcName: String) {
        view.mac = macBounds().size
        view.pc = bridge.pcSize
        view.pcName = pcName
        view.arrangement = bridge.arrangement
        view.onChange = { [weak bridge] in
            bridge?.arrangement = $0
            bridge?.onChange?()
        }
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
}
