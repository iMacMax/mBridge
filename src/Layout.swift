import Cocoa

// Where the PC sits next to the Mac, like two monitors in System Settings > Displays.

enum Side: String, Codable, CaseIterable {
    case left, right, above, below

    var title: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        case .above: return "Above"
        case .below: return "Below"
        }
    }
}

struct Arrangement: Codable, Equatable {
    var side: Side
    /// How far the PC is shifted along the shared edge, in Mac points (from the Mac's top or left edge).
    var offset: Double
    /// Lined up by proportion (centered): the cursor crosses at the same relative position even if the screens
    /// differ in size, and stays that way when either screen's resolution changes.
    var lined: Bool

    init(side: Side, offset: Double, lined: Bool = false) {
        self.side = side
        self.offset = offset
        self.lined = lined
    }

    /// Saved layouts from before this setting were centered when they were made.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        side = try c.decode(Side.self, forKey: .side)
        offset = try c.decode(Double.self, forKey: .offset)
        lined = try c.decodeIfPresent(Bool.self, forKey: .lined) ?? true
    }

    static let standard = Arrangement(side: .right, offset: 0)

    /// The PC's screen in the Mac's coordinate space (global, top-left origin like CGEvent locations).
    func pcRect(mac: CGRect, pc: CGSize) -> CGRect {
        switch side {
        case .right: return CGRect(x: mac.maxX, y: mac.minY + offset, width: pc.width, height: pc.height)
        case .left: return CGRect(x: mac.minX - pc.width, y: mac.minY + offset, width: pc.width, height: pc.height)
        case .below: return CGRect(x: mac.minX + offset, y: mac.maxY, width: pc.width, height: pc.height)
        case .above: return CGRect(x: mac.minX + offset, y: mac.minY - pc.height, width: pc.width, height: pc.height)
        }
    }

    /// The cursor is pushing against the Mac edge that touches the PC: returns where it appears on the PC (PC pixels).
    func entry(from p: CGPoint, delta d: CGPoint, mac: CGRect, pc: CGSize) -> CGPoint? {
        let r = pcRect(mac: mac, pc: pc)
        let fy = (p.y - mac.minY) / mac.height, fx = (p.x - mac.minX) / mac.width   // how far along the edge, 0...1
        switch side {
        case .right:
            guard p.x >= mac.maxX - 1, d.x > 0, lined || (p.y >= r.minY && p.y < r.maxY) else { return nil }
            return CGPoint(x: 0, y: lined ? fy * pc.height : p.y - r.minY)
        case .left:
            guard p.x <= mac.minX + 1, d.x < 0, lined || (p.y >= r.minY && p.y < r.maxY) else { return nil }
            return CGPoint(x: pc.width - 1, y: lined ? fy * pc.height : p.y - r.minY)
        case .below:
            guard p.y >= mac.maxY - 1, d.y > 0, lined || (p.x >= r.minX && p.x < r.maxX) else { return nil }
            return CGPoint(x: lined ? fx * pc.width : p.x - r.minX, y: 0)
        case .above:
            guard p.y <= mac.minY + 1, d.y < 0, lined || (p.x >= r.minX && p.x < r.maxX) else { return nil }
            return CGPoint(x: lined ? fx * pc.width : p.x - r.minX, y: pc.height - 1)
        }
    }

    /// The virtual PC cursor `v` went past the PC edge that touches the Mac: returns where it appears on the Mac.
    func exit(from v: CGPoint, mac: CGRect, pc: CGSize) -> CGPoint? {
        let r = pcRect(mac: mac, pc: pc)
        let alongY = lined ? mac.minY + v.y / pc.height * mac.height : v.y + r.minY
        let alongX = lined ? mac.minX + v.x / pc.width * mac.width : v.x + r.minX
        switch side {
        case .right:
            guard v.x < 0 else { return nil }
            return CGPoint(x: mac.maxX - 3, y: clamp(alongY, mac.minY + 3, mac.maxY - 3))
        case .left:
            guard v.x > pc.width - 1 else { return nil }
            return CGPoint(x: mac.minX + 3, y: clamp(alongY, mac.minY + 3, mac.maxY - 3))
        case .below:
            guard v.y < 0 else { return nil }
            return CGPoint(x: clamp(alongX, mac.minX + 3, mac.maxX - 3), y: mac.maxY - 3)
        case .above:
            guard v.y > pc.height - 1 else { return nil }
            return CGPoint(x: clamp(alongX, mac.minX + 3, mac.maxX - 3), y: mac.minY + 3)
        }
    }

    /// The same side, with the two screens centered on each other.
    func centered(mac: CGSize, pc: CGSize) -> Arrangement {
        let horizontal = side == .left || side == .right
        return Arrangement(side: side, offset: horizontal ? (mac.height - pc.height) / 2 : (mac.width - pc.width) / 2, lined: true)
    }
}

private func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, lo), hi) }

/// All Mac displays together, in global top-left coordinates.
func macBounds() -> CGRect {
    var count: UInt32 = 0
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    CGGetActiveDisplayList(16, &ids, &count)
    let rects = ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    return rects.reduce(CGRect.null) { $0.union($1) }
}
