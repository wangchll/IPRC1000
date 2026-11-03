import CoreGraphics

enum RemoteKeyCode {
    static let syntheticMarker: Int64 = 0x49505243

    static func virtualKeyCode(for usage: UInt8) -> CGKeyCode? {
        switch usage {
        case 0x04: 0   // A
        case 0x05: 11  // B
        case 0x06: 8   // C
        case 0x07: 2   // D
        case 0x08: 14  // E
        case 0x09: 3   // F
        case 0x0A: 5   // G
        case 0x0B: 4   // H
        case 0x0C: 34  // I (spurious release report)
        case 0x0D: 38  // J
        case 0x10: 46  // M
        case 0x11: 45  // N
        case 0x16: 1   // S
        case 0x17: 17  // T
        case 0x19: 9   // V
        case 0x1F: 19  // 2
        case 0x20: 20  // 3
        case 0x28: 36  // Return
        case 0x31: 42  // Backslash
        case 0x36: 43  // Comma
        case 0x4F: 124 // Right
        case 0x50: 123 // Left
        case 0x51: 125 // Down
        case 0x52: 126 // Up
        default: nil
        }
    }
}
