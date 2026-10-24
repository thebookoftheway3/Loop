import Foundation

let forbidden = ["MockPump", "Omnipod", "OmnipodDash", "Minimed", "Medtrum", "Tandem", "", "DexG6Transmitter"]
for identifier in forbidden { precondition(!ResearchPolicy.permitsPump(identifier), "Pump capability must be absent") }
for identifier in ["MockCGM", "DexG5Transmitter", "DexShareClient", "G7Sensor", "", "DexG6Transmitter "] { precondition(!ResearchPolicy.permitsCGM(identifier), "Only exact G6 factory/restore identifier is permitted") }
precondition(ResearchPolicy.permitsCGM("DexG6Transmitter"))
let date = ISO8601DateFormatter().date(from: "2026-10-24T12:00:00Z")!
let row = ResearchObservation.record(syncIdentifier: "TEST-ONLY-NOT-A-REAL-TRANSMITTER 12345", eventAt: date, receivedAt: date.addingTimeInterval(10), glucose: 123, isDisplayOnly: false, wasUserEntered: false, condition: nil, trend: nil)
let quality = row["quality"] as! [String: Any]
precondition(quality["condition"] is NSNull && quality["trend"] is NSNull)
precondition((row["id"] as! String).count == 64)
precondition(row["may_actuate_insulin"] as? Bool == false)
let encoded = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
precondition(!String(decoding: encoded, as: UTF8.self).contains("TEST-ONLY-NOT-A-REAL-TRANSMITTER"))
// Test-only fixture of the real-observation wire format; never a captured sensor reading.
FileHandle.standardOutput.write(encoded + Data([10]))
FileHandle.standardError.write(Data("PASS: 8 pump rejections, 6 CGM rejections, exact G6 acceptance, wire/privacy invariants\n".utf8))
