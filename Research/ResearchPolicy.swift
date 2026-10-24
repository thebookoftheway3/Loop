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

/// Operational counters only: no glucose, transmitter IDs or health timestamps.
struct ResearchRuntimeStatus: Encodable {
    let schema = "project-live.collection-status"
    let version = 1
    var journalCount = 0
    var backgroundCallbacks = 0
    var backgroundTimedSamples = 0
    var transportErrors = 0
    var foregroundActive = false
    var collectionEnabled = false
    var bluetooth = ""

    mutating func received(background: Bool, timedSamples: Int, transportError: Bool) {
        if background { backgroundCallbacks += 1; backgroundTimedSamples += max(0, timedSamples) }
        if transportError { transportErrors += 1 }
    }
}
