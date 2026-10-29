import Cocoa

// Mac key codes to Windows virtual-key codes, so the PC types what you press.
// Command acts as Ctrl (Cmd+C copies on the PC), Control as the Windows key, Option as Alt.

struct WinKey {
    let vk: Int
    let extended: Bool
    init(_ vk: Int, ext: Bool = false) { self.vk = vk; self.extended = ext }
}

let winKeys: [Int: WinKey] = [
    // letters
    0: WinKey(0x41), 11: WinKey(0x42), 8: WinKey(0x43), 2: WinKey(0x44), 14: WinKey(0x45), 3: WinKey(0x46),
    5: WinKey(0x47), 4: WinKey(0x48), 34: WinKey(0x49), 38: WinKey(0x4A), 40: WinKey(0x4B), 37: WinKey(0x4C),
    46: WinKey(0x4D), 45: WinKey(0x4E), 31: WinKey(0x4F), 35: WinKey(0x50), 12: WinKey(0x51), 15: WinKey(0x52),
    1: WinKey(0x53), 17: WinKey(0x54), 32: WinKey(0x55), 9: WinKey(0x56), 13: WinKey(0x57), 7: WinKey(0x58),
    16: WinKey(0x59), 6: WinKey(0x5A),
    // digits
    29: WinKey(0x30), 18: WinKey(0x31), 19: WinKey(0x32), 20: WinKey(0x33), 21: WinKey(0x34), 23: WinKey(0x35),
    22: WinKey(0x36), 26: WinKey(0x37), 28: WinKey(0x38), 25: WinKey(0x39),
    // punctuation
    27: WinKey(0xBD), 24: WinKey(0xBB), 33: WinKey(0xDB), 30: WinKey(0xDD), 42: WinKey(0xDC), 41: WinKey(0xBA),
    39: WinKey(0xDE), 43: WinKey(0xBC), 47: WinKey(0xBE), 44: WinKey(0xBF), 50: WinKey(0xC0),
    // editing
    36: WinKey(0x0D), 48: WinKey(0x09), 49: WinKey(0x20), 51: WinKey(0x08), 53: WinKey(0x1B),
    117: WinKey(0x2E, ext: true), 114: WinKey(0x2D, ext: true), 115: WinKey(0x24, ext: true),
    119: WinKey(0x23, ext: true), 116: WinKey(0x21, ext: true), 121: WinKey(0x22, ext: true),
    123: WinKey(0x25, ext: true), 126: WinKey(0x26, ext: true), 124: WinKey(0x27, ext: true), 125: WinKey(0x28, ext: true),
    // function keys
    122: WinKey(0x70), 120: WinKey(0x71), 99: WinKey(0x72), 118: WinKey(0x73), 96: WinKey(0x74), 97: WinKey(0x75),
    98: WinKey(0x76), 100: WinKey(0x77), 101: WinKey(0x78), 109: WinKey(0x79), 103: WinKey(0x7A), 111: WinKey(0x7B),
    105: WinKey(0x7C), 107: WinKey(0x7D), 113: WinKey(0x7E), 106: WinKey(0x7F), 64: WinKey(0x80), 79: WinKey(0x81),
    80: WinKey(0x82), 90: WinKey(0x83),
    // keypad
    82: WinKey(0x60), 83: WinKey(0x61), 84: WinKey(0x62), 85: WinKey(0x63), 86: WinKey(0x64), 87: WinKey(0x65),
    88: WinKey(0x66), 89: WinKey(0x67), 91: WinKey(0x68), 92: WinKey(0x69), 65: WinKey(0x6E), 67: WinKey(0x6A),
    69: WinKey(0x6B), 78: WinKey(0x6D), 75: WinKey(0x6F, ext: true), 76: WinKey(0x0D, ext: true), 71: WinKey(0x90),
]

/// Modifier keys arrive as flagsChanged events: key code -> (Windows key, flag that says it is down).
let winModifiers: [Int: (key: WinKey, flag: CGEventFlags)] = [
    56: (WinKey(0xA0), .maskShift), 60: (WinKey(0xA1), .maskShift),
    59: (WinKey(0x5B, ext: true), .maskControl), 62: (WinKey(0x5C, ext: true), .maskControl),
    58: (WinKey(0xA4), .maskAlternate), 61: (WinKey(0xA5, ext: true), .maskAlternate),
    55: (WinKey(0xA2), .maskCommand), 54: (WinKey(0xA3, ext: true), .maskCommand),
]
let capsLockKeyCode = 57
let capsLockKey = WinKey(0x14)

// The other way round, for when another computer controls this Mac: Windows key code -> Mac key code.
// Ctrl from the other side acts as Command, the Windows key as Control, Alt as Option (the same swap in reverse).

let macKeys: [Int: Int] = {
    var table = [Int: Int]()
    for (code, key) in winKeys { table[key.vk | (key.extended ? 0x100 : 0)] = code }
    return table
}()

/// Windows modifier key code -> (Mac modifier key code, the flag it sets).
let macModifiers: [Int: (code: Int, flag: CGEventFlags)] = [
    0xA0: (56, .maskShift), 0xA1: (60, .maskShift),
    0xA2: (55, .maskCommand), 0xA3: (54, .maskCommand),
    0x5B: (59, .maskControl), 0x5C: (62, .maskControl),
    0xA4: (58, .maskAlternate), 0xA5: (61, .maskAlternate),
]
