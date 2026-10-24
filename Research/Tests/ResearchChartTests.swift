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
    var failRemoval = false
    func append(_ samples: [NewGlucoseSample], receivedAt: Date) throws {}
    func export() throws {}
    func disableExport() throws { if failRemoval { throw CocoaError(.fileWriteNoPermission) } }
}

@MainActor
final class ResearchLifecycleTests: XCTestCase {
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
        XCTAssertFalse(probe.permitsAttempt(at: 460, active: true, consented: true))
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
        XCTAssertEqual(calls, [.control, .authentication])
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
