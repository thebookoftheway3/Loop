import Foundation

/// The same allowlist gates both creation and restoration in this Loop variant.
enum ResearchPolicy {
    static let cgmIdentifier = "DexG6Transmitter"
    static func permitsCGM(_ identifier: String) -> Bool { identifier == cgmIdentifier }
    static func permitsPump(_ identifier: String) -> Bool { false }
    static let sourceVersion = "loop-g6-passive-v1"
}
