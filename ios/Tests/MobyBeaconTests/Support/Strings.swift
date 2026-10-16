import Foundation

/// Builds a string from raw UTF-16 code units. It is the only way to make a
/// lone surrogate in Swift, because string literals cannot contain one.
func utf16String(_ units: [UInt16]) -> String {
    units.withUnsafeBufferPointer { buffer in
        NSString(characters: buffer.baseAddress!, length: buffer.count) as String
    }
}
