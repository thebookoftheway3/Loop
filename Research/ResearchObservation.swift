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

extension ResearchObservation {
    // Private evidence schemas. These are deliberately not v1 timed observations.
    private static func evidenceRecord(schema: String, streamID: UUID, packet: Data, receivedAt: Date, receivedUptime: TimeInterval, transmitterUptime: UInt32, status: UInt8) -> [String: Any] {
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var identity = Data((schema + ":" + streamID.uuidString).utf8); identity.append(packet)
        let id = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        return ["schema": schema, "schema_version": 1, "id": id, "stream_id": streamID.uuidString,
                "event_at": NSNull(), "received_at": iso.string(from: receivedAt), "received_uptime": receivedUptime,
                "transmitter_uptime": transmitterUptime, "transmitter_status": status, "packet_base64": packet.base64EncodedString(),
                "source": "loop.dexcom-g6", "source_version": ResearchPolicy.sourceVersion,
                "synthetic": false, "shadow_only": true, "may_actuate_insulin": false]
    }
    static func untimedRecord(streamID: UUID, packet: Data, receivedAt: Date, receivedUptime: TimeInterval, transmitterUptime: UInt32, status: UInt8, sequence: UInt32, glucoseRaw: UInt16, state: UInt8, trend: Int8, isDisplayOnly: Bool, isReliable: Bool) -> [String: Any] {
        var row = evidenceRecord(schema: "project-live.cgm-untimed-packet", streamID: streamID, packet: packet, receivedAt: receivedAt, receivedUptime: receivedUptime, transmitterUptime: transmitterUptime, status: status)
        row["sequence"] = sequence; row["unit"] = "mg/dL"; row["glucose_raw"] = glucoseRaw
        row["calibration_state"] = state; row["trend_raw"] = trend; row["is_display_only"] = isDisplayOnly
        row["quality_reliable"] = isReliable; row["measurement_time_status"] = "unresolved"
        row["eligible_for_timed_analysis"] = false
        return row
    }
    static func clockRecord(streamID: UUID, packet: Data, receivedAt: Date, receivedUptime: TimeInterval, transmitterUptime: UInt32, status: UInt8, sessionStartTime: UInt32) -> [String: Any] {
        var row = evidenceRecord(schema: "project-live.cgm-clock-reference", streamID: streamID, packet: packet, receivedAt: receivedAt, receivedUptime: receivedUptime, transmitterUptime: transmitterUptime, status: status)
        row["session_start_uptime"] = sessionStartTime
        return row
    }
}
