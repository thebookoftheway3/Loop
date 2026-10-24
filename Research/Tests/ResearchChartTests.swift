import XCTest
import HealthKit
import LoopKit
@testable import Loop

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
