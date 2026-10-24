import Foundation
import CryptoKit

/// Pure encoder shared by the CGM callback and host-side contract tests.
enum ResearchObservation {
    static func record(syncIdentifier: String, eventAt: Date, receivedAt: Date, glucose: Double, isDisplayOnly: Bool, wasUserEntered: Bool, condition: String?, trend: String?) -> [String: Any] {
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let id = SHA256.hash(data: Data(("loop.dexcom-g6:" + syncIdentifier).utf8)).map { String(format: "%02x", $0) }.joined()
        let quality: [String: Any] = ["is_display_only": isDisplayOnly, "was_user_entered": wasUserEntered, "condition": condition as Any? ?? NSNull(), "trend": trend as Any? ?? NSNull()]
        return ["schema": "project-live.cgm-observation", "schema_version": 1, "id": id, "event_at": iso.string(from: eventAt), "received_at": iso.string(from: receivedAt), "source": "loop.dexcom-g6", "source_version": ResearchPolicy.sourceVersion, "unit": "mg/dL", "glucose": glucose, "quality": quality, "synthetic": false, "shadow_only": true, "may_actuate_insulin": false]
    }
}
