import Foundation

/// The same allowlist gates both creation and restoration in this Loop variant.
enum ResearchPolicy {
    static let cgmIdentifier = "DexG6Transmitter"
    static func permitsCGM(_ identifier: String) -> Bool { identifier == cgmIdentifier }
    static func permitsPump(_ identifier: String) -> Bool { false }
    static let sourceVersion = "loop-g6-passive-v1"
}

/// Consented foreground collection. Success does not end collection; background/pause does.
/// Uses monotonic uptime, never health timestamps.
struct ResearchConnectionProbe {
    static let interval: TimeInterval = 1
    private(set) var startedAt: TimeInterval?
    mutating func start(at uptime: TimeInterval) { startedAt = uptime.isFinite ? uptime : nil }
    mutating func cancel() { startedAt = nil }
    mutating func permitsAttempt(at uptime: TimeInterval, active: Bool, consented: Bool) -> Bool {
        guard active, consented, let start = startedAt, uptime.isFinite,
              uptime >= start else {
            cancel()
            return false
        }
        return true
    }
}
