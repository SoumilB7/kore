import Foundation

/// A short id that is the same for the same text in every run (FNV-1a, 64 bits), so a window's
/// id doesn't carry its folder's path.
package enum StableID {
    package static func of(_ text: String, prefix: String = "") -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return prefix + String(hash, radix: 16).leftPadded(16)
    }
}

extension String {
    fileprivate func leftPadded(_ width: Int) -> String {
        count >= width ? self : String(repeating: "0", count: width - count) + self
    }
}
