import XCTest
import HealthKit
import LoopKit
@testable import Loop
@testable import CGMBLEKit

@MainActor
final class ResearchChartTests: XCTestCase {
    func testEmptyHistoryDoesNotConstructChartAxes() {
        let controller = ResearchController()
        controller.loadViewIfNeeded()
        XCTAssertNil(controller.renderGlucoseChart([], frame: CGRect(x: 0, y: 0, width: 350, height: 220)))
    }

    func testOneObservationHasNonemptyAxes() {
        let controller = ResearchController()
        controller.loadViewIfNeeded()
        let sample = SimpleGlucoseValue(startDate: Date().addingTimeInterval(-60), quantity: HKQuantity(unit: HKUnit(from: "mg/dL"), doubleValue: 123))
        XCTAssertNotNil(controller.renderGlucoseChart([sample], frame: CGRect(x: 0, y: 0, width: 350, height: 220)))
    }

    func testBackfilledObservationCanBeRendered() {
        let controller = ResearchController()
        controller.loadViewIfNeeded()
        let now = Date()
        let samples = [0.0, -300.0].map { SimpleGlucoseValue(startDate: now.addingTimeInterval($0), quantity: HKQuantity(unit: HKUnit(from: "mg/dL"), doubleValue: 123)) }
        XCTAssertNotNil(controller.renderGlucoseChart(samples, frame: CGRect(x: 0, y: 0, width: 350, height: 220)))
    }

    func testNoPumpAndOnlyExactG6Identifier() {
        for id in ["MockPump", "Tandem", "Omnipod", "Minimed", "DexG6Transmitter", ""] { XCTAssertFalse(ResearchPolicy.permitsPump(id)) }
        for id in ["MockCGM", "DexG5Transmitter", "DexShareClient", "G7", ""] { XCTAssertFalse(ResearchPolicy.permitsCGM(id)) }
        XCTAssertTrue(ResearchPolicy.permitsCGM("DexG6Transmitter"))
    }
}

private final class TestResearchJournal: ResearchJournalStore {
    var records: [[String: Any]] = []
    var chartValues: [GlucoseValue] = []
    var evidenceRecords: [[String: Any]] = []
    func appendEvidence(_ rows: [[String: Any]]) throws { evidenceRecords.append(contentsOf: rows) }
    var failRemoval = false
    var appendCount = 0
    func append(_ samples: [NewGlucoseSample], receivedAt: Date) throws { appendCount += samples.count }
    func export() throws {}
    func disableExport() throws { if failRemoval { throw CocoaError(.fileWriteNoPermission) } }
}

@MainActor
final class ResearchLifecycleTests: XCTestCase {
    func testRepeatedReadingsAndTransportFailureKeepAutomaticCollectionRunning() throws {
        let defaults = UserDefaults.standard
        let keys = ["researchCollectionConsent", "researchCGM", "researchCollectionPaused"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        defaults.set(true, forKey: "researchCollectionConsent")
        defaults.set(false, forKey: "researchCollectionPaused")
        defaults.removeObject(forKey: "researchCGM")
        let journal = TestResearchJournal()
        var active = true
        let controller = ResearchController(journalFactory: { journal }, isApplicationActive: { active })
        controller.loadViewIfNeeded()
        let manager = try XCTUnwrap(G6CGMManager(rawState: ["transmitterID": "000000"]))
        controller.cgmManagerOnboarding(didCreateCGMManager: manager)
        defer { controller.stopResearchObservation(reason: "Test complete") }
        XCTAssertTrue(controller.isForegroundCollecting)
        let sample = NewGlucoseSample(date: Date(), quantity: HKQuantity(unit: HKUnit(from: "mg/dL"), doubleValue: 123), condition: nil, trend: nil, trendRate: nil, isDisplayOnly: false, wasUserEntered: false, syncIdentifier: "synthetic-repeat")
        for _ in 0..<3 {
            controller.cgmManager(manager, hasNew: .newData([sample]))
            XCTAssertTrue(controller.isForegroundCollecting, "A successful reading must not stop collection")
            controller.cgmManager(manager, hasNew: .error(TransmitterError.controlError("synthetic subscription failure")))
            XCTAssertTrue(controller.isForegroundCollecting)
            XCTAssertTrue(controller.researchStatus.contains("notification setup interrupted"))
        }
        XCTAssertEqual(journal.appendCount, 3)
        controller.toggleCollection()
        XCTAssertFalse(controller.isForegroundCollecting)
        XCTAssertFalse(manager.transmitter.stayConnected)
        controller.cgmManager(manager, hasNew: .newData([sample]))
        XCTAssertEqual(journal.appendCount, 3, "Paused collection must reject queued data")
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertFalse(controller.isForegroundCollecting, "Owner pause survives foreground activation")
        controller.toggleCollection()
        XCTAssertTrue(controller.isForegroundCollecting)
        active = false
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        XCTAssertFalse(controller.isForegroundCollecting)
        active = true
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertTrue(controller.isForegroundCollecting, "Foreground return needs no manual retry")
        controller.stopResearchObservation(reason: "Revoked")
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertFalse(controller.isForegroundCollecting)
    }

    func testStorageFailureRevokesConsentBeforeRestoringG6() {
        let defaults = UserDefaults.standard
        let oldConsent = defaults.object(forKey: "researchCollectionConsent")
        let oldState = defaults.object(forKey: "researchCGM")
        defer { defaults.set(oldConsent, forKey: "researchCollectionConsent"); defaults.set(oldState, forKey: "researchCGM") }
        defaults.set(true, forKey: "researchCollectionConsent")
        defaults.set(["identifier": "DexG6Transmitter", "state": ["transmitterID": "000000"]], forKey: "researchCGM")
        let controller = ResearchController(journalFactory: { throw CocoaError(.fileReadCorruptFile) })
        controller.loadViewIfNeeded()
        XCTAssertFalse(controller.isResearchObserving)
        XCTAssertFalse(defaults.bool(forKey: "researchCollectionConsent"))
        XCTAssertTrue(controller.researchStatus.contains("error"))
    }

    func testExportRemovalFailureIsNotOverwrittenBySuccess() {
        let journal = TestResearchJournal()
        let controller = ResearchController(journalFactory: { journal })
        controller.loadViewIfNeeded()
        journal.failRemoval = true
        controller.stopResearchObservation(reason: "Owner revoked observation.")
        XCTAssertFalse(controller.isResearchObserving)
        XCTAssertTrue(controller.researchStatus.contains("could not be removed"))
        XCTAssertFalse(controller.researchStatus.contains("local export removed"))
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "researchCollectionConsent"))
    }
}

final class ResearchConnectionProbeTests: XCTestCase {
    func testExistingConnectionWindowBeyondOldOneMinuteLimitIsChecked() {
        var probe = ResearchConnectionProbe()
        probe.start(at: 100)
        XCTAssertTrue(probe.permitsAttempt(at: 195, active: true, consented: true))
        XCTAssertTrue(probe.permitsAttempt(at: 459, active: true, consented: true))
        XCTAssertTrue(probe.permitsAttempt(at: 460, active: true, consented: true))
        XCTAssertTrue(probe.permitsAttempt(at: 3700, active: true, consented: true))
    }
    func testShortExistingConnectionWindowCanBeObservedAfterNinetyFiveSeconds() {
        var probe = ResearchConnectionProbe()
        probe.start(at: 100)
        var observed = false
        for uptime in stride(from: 100.0, through: 459.0, by: ResearchConnectionProbe.interval) {
            if probe.permitsAttempt(at: uptime, active: true, consented: true), (195.0...195.5).contains(uptime) {
                observed = true
            }
        }
        XCTAssertTrue(observed, "The old 10-second/one-minute retry misses this synthetic connection window")
    }
    func testBackgroundOrRevocationStopsProbeUntilOwnerRestarts() {
        for revoked in [false, true] {
            var probe = ResearchConnectionProbe()
            probe.start(at: 100)
            XCTAssertFalse(probe.permitsAttempt(at: 101, active: revoked, consented: !revoked))
            XCTAssertFalse(probe.permitsAttempt(at: 102, active: true, consented: true))
            probe.start(at: 103)
            XCTAssertTrue(probe.permitsAttempt(at: 104, active: true, consented: true))
        }
    }
    func testClockAnomalyStopsProbe() {
        var probe = ResearchConnectionProbe()
        probe.start(at: 100)
        XCTAssertFalse(probe.permitsAttempt(at: 99, active: true, consented: true))
        probe.start(at: .nan)
        XCTAssertFalse(probe.permitsAttempt(at: 101, active: true, consented: true))
    }
}

final class ResearchPassiveSubscriptionTests: XCTestCase {
    private enum Failure: Error { case rejected }
    func testLateAttachmentSubscribesToControlWithoutAuthenticationEvent() throws {
        var calls: [CGMServiceCharacteristicUUID] = []
        try ResearchPassiveSubscriptions.subscribe(stillObserving: { true }) { calls.append($0) }
        XCTAssertEqual(calls, [.control], "Authentication subscription is not required for control data")
    }
    func testReconnectsNeverAttemptFailingAuthenticationSubscription() throws {
        var controlRequests = 0
        for _ in 0..<3 {
            try ResearchPassiveSubscriptions.subscribe(stillObserving: { true }) {
                if $0 == .authentication { throw Failure.rejected }
                controlRequests += 1
            }
        }
        XCTAssertEqual(controlRequests, 3)
    }
    func testRevokedObserverSubscribesToNothing() throws {
        var calls: [CGMServiceCharacteristicUUID] = []
        try ResearchPassiveSubscriptions.subscribe(stillObserving: { false }) { calls.append($0) }
        XCTAssertTrue(calls.isEmpty)
    }
    func testRevocationAfterFirstSubscriptionStopsNextSubscription() throws {
        var observing = true
        var calls: [CGMServiceCharacteristicUUID] = []
        try ResearchPassiveSubscriptions.subscribe(stillObserving: { observing }) {
            calls.append($0); observing = false
        }
        XCTAssertEqual(calls, [.control])
    }
    func testControlSubscriptionFailureDoesNotFallBackToAuthentication() {
        var calls: [CGMServiceCharacteristicUUID] = []
        XCTAssertThrowsError(try ResearchPassiveSubscriptions.subscribe(stillObserving: { true }) {
            calls.append($0); throw Failure.rejected
        })
        XCTAssertEqual(calls, [.control])
    }
    func testAlreadyEnabledNotificationsDoNotIssueAnotherRequest() throws {
        var changes = 0
        ResearchPassiveSubscriptions.updateNotification(current: true, requested: true) { changes += 1 }
        XCTAssertEqual(changes, 0)
        ResearchPassiveSubscriptions.updateNotification(current: false, requested: true) { changes += 1 }
        XCTAssertEqual(changes, 1)
    }
    func testNotificationChangeErrorPropagatesWithoutFallback() {
        XCTAssertThrowsError(try ResearchPassiveSubscriptions.updateNotification(current: false, requested: true) { throw Failure.rejected })
    }
}

@MainActor
final class ResearchUntimedEvidenceTests: XCTestCase {
    private let packet = Data([0x31, 0, 0x68, 0x0a, 0, 0, 0x8a, 0x71, 0x57, 0, 0xcc, 0, 6, 0xff, 0xc4, 0x2a])
    private let clock = Data([0x25, 0, 0x47, 2, 0x72, 0, 0x7c, 0xff, 0x71, 0, 1, 0, 0, 0, 0xfa, 0x1d])
    private func row(_ sample: ResearchUntimedGlucose) -> [String: Any] {
        ResearchObservation.untimedRecord(streamID: sample.streamID, packet: sample.rawPacket, receivedAt: sample.receivedAt, receivedUptime: sample.receivedUptime, transmitterUptime: sample.transmitterUptime, status: sample.status, sequence: sample.sequence, glucoseRaw: sample.glucoseRaw, state: sample.state, trend: sample.trend, isDisplayOnly: sample.isDisplayOnly, isReliable: sample.isReliable)
    }
    func testValidPacketRetainsReceiptAndUnknownMeasurementTime() throws {
        var buffer = ResearchEvidenceBuffer()
        let receipt = Date()
        guard case .untimed = buffer.observeGlucose(packet, receivedAt: receipt, receivedUptime: 50, hasClock: false) else { return XCTFail("Valid packet must be retained untimed") }
        let sample = try XCTUnwrap(buffer.untimed.first)
        XCTAssertEqual(sample.receivedAt, receipt); XCTAssertEqual(sample.receivedUptime, 50)
        XCTAssertEqual(sample.rawPacket, packet); XCTAssertEqual(sample.transmitterUptime, 5730698)
        XCTAssertEqual(sample.glucoseRaw, 204); XCTAssertTrue(sample.isReliable)
        let record = row(sample)
        XCTAssertTrue(record["event_at"] is NSNull)
        XCTAssertEqual(record["eligible_for_timed_analysis"] as? Bool, false)
        XCTAssertEqual(record["schema"] as? String, "project-live.cgm-untimed-packet")
        XCTAssertNil(record["transmitter_id"])
    }
    func testInvalidCRCDoesNotProducePrivateGlucoseEvidence() {
        var broken = packet; broken[10] ^= 1
        var buffer = ResearchEvidenceBuffer()
        guard case .invalid = buffer.observeGlucose(broken, receivedAt: Date(), receivedUptime: 50, hasClock: false) else { return XCTFail("CRC mutation must fail") }
        XCTAssertTrue(buffer.untimed.isEmpty)
    }
    func testLaterClockDoesNotRewriteOrPromoteOriginalEvidence() throws {
        var buffer = ResearchEvidenceBuffer()
        let receipt = Date()
        _ = buffer.observeGlucose(packet, receivedAt: receipt, receivedUptime: 50, hasClock: false)
        let before = try JSONSerialization.data(withJSONObject: row(XCTUnwrap(buffer.untimed.first)), options: [.sortedKeys])
        XCTAssertNotNil(buffer.observeClock(clock, receivedAt: receipt.addingTimeInterval(60), receivedUptime: 110))
        let after = try JSONSerialization.data(withJSONObject: row(XCTUnwrap(buffer.untimed.first)), options: [.sortedKeys])
        XCTAssertEqual(before, after); XCTAssertEqual(buffer.clocks.count, 1)
        guard case .timed = buffer.observeGlucose(packet, receivedAt: receipt.addingTimeInterval(61), receivedUptime: 111, hasClock: true) else { return XCTFail("New anchored packet can use the existing timed path") }
        XCTAssertEqual(buffer.untimed.count, 1)
    }
    func testBoundedBufferReportsOverflow() {
        var buffer = ResearchEvidenceBuffer()
        for i in 0..<25 { _ = buffer.observeGlucose(packet, receivedAt: Date(), receivedUptime: Double(i), hasClock: false) }
        XCTAssertEqual(buffer.untimed.count, 24); XCTAssertEqual(buffer.untimedOverflowCount, 1)
    }
    func testEvidenceStoreDeduplicatesWithoutReplacingFirstReceipt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ResearchEvidenceJournal(directory: directory)
        var buffer = ResearchEvidenceBuffer()
        let receipt = Date()
        _ = buffer.observeGlucose(packet, receivedAt: receipt, receivedUptime: 50, hasClock: false)
        _ = buffer.observeGlucose(packet, receivedAt: receipt.addingTimeInterval(1), receivedUptime: 51, hasClock: false)
        let first = row(try XCTUnwrap(buffer.untimed.first))
        try store.append(buffer.untimed.map(row))
        XCTAssertEqual(store.records.count, 1); XCTAssertEqual(store.duplicateCount, 1)
        XCTAssertEqual(store.records.first?["received_at"] as? String, first["received_at"] as? String)
        XCTAssertTrue(store.records.first?["event_at"] is NSNull)
        let reopened = try ResearchEvidenceJournal(directory: directory)
        XCTAssertEqual(reopened.records.count, 1)
        XCTAssertEqual(reopened.records.first?["packet_base64"] as? String, packet.base64EncodedString())
    }
    func testUntimedReadoutDoesNotCreateTimedChartValues() throws {
        var buffer = ResearchEvidenceBuffer()
        _ = buffer.observeGlucose(packet, receivedAt: Date(), receivedUptime: 50, hasClock: false)
        let journal = TestResearchJournal()
        journal.evidenceRecords = [row(try XCTUnwrap(buffer.untimed.first))]
        let controller = ResearchController(journalFactory: { journal })
        controller.loadViewIfNeeded()
        XCTAssertTrue(controller.researchReadout.contains("Measurement time and currentness unknown"))
        XCTAssertTrue(controller.researchReadout.contains("204"))
        XCTAssertTrue(journal.records.isEmpty); XCTAssertTrue(journal.chartValues.isEmpty)
    }
    func testFlaggedQualityIsRetainedWithoutCallingItReliable() throws {
        for (offset, value) in [(12, UInt8(2)), (11, UInt8(0x40)), (1, UInt8(0xff))] {
            var altered = packet; altered[offset] = value
            altered = Data(altered.dropLast(2)).appendingCRC()
            var buffer = ResearchEvidenceBuffer()
            guard case .untimed = buffer.observeGlucose(altered, receivedAt: Date(), receivedUptime: 50, hasClock: false) else { return XCTFail("Valid flagged packet must be preserved") }
            XCTAssertFalse(try XCTUnwrap(buffer.untimed.first).isReliable)
        }
    }
    func testProductionTimedExportExcludesUntimedAndClockEvidence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try ResearchJournal(testRoot: directory)
        var buffer = ResearchEvidenceBuffer()
        _ = buffer.observeGlucose(packet, receivedAt: Date(), receivedUptime: 50, hasClock: false)
        _ = buffer.observeClock(clock, receivedAt: Date(), receivedUptime: 51)
        let reference = try XCTUnwrap(buffer.clocks.first)
        let clockRow = ResearchObservation.clockRecord(streamID: reference.streamID, packet: reference.rawPacket, receivedAt: reference.receivedAt, receivedUptime: reference.receivedUptime, transmitterUptime: reference.transmitterUptime, status: reference.status, sessionStartTime: reference.sessionStartTime)
        try journal.appendEvidence([row(try XCTUnwrap(buffer.untimed.first)), clockRow])
        try journal.export()
        XCTAssertEqual(journal.evidenceRecords.count, 2)
        XCTAssertTrue(journal.records.isEmpty); XCTAssertTrue(journal.chartValues.isEmpty)
        XCTAssertTrue(try Data(contentsOf: journal.exportURL).isEmpty)
    }

}
