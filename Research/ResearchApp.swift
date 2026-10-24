import UIKit
import SwiftUI
import HealthKit
import CryptoKit
import CoreBluetooth
import LoopKit
import LoopKitUI
import CGMBLEKit
import CGMBLEKitUI
import SwiftCharts

#if !LIVE_READ_ONLY
#error("The restricted Loop entrypoint requires LIVE_READ_ONLY in every research dependency")
#endif

@main
final class ResearchApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = UINavigationController(rootViewController: ResearchController())
        window?.makeKeyAndVisible()
        return true
    }
}

/// Private append-only daily journals; seven-day retention. Export is separately consented.
protocol ResearchJournalStore: AnyObject {
    var records: [[String: Any]] { get }
    var chartValues: [GlucoseValue] { get }
    func append(_ samples: [NewGlucoseSample], receivedAt: Date) throws
    func export() throws
    func disableExport() throws
}

final class ResearchJournal: ResearchJournalStore {
    private let fm = FileManager.default
    private let directory: URL
    let exportURL: URL
    private(set) var records: [[String: Any]] = []
    private var ids = Set<String>()
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    init() throws {
        directory = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("G6Research", isDirectory: true)
        exportURL = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("LIVE/observations-v1.jsonl")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        var d = directory; try d.setResourceValues(excluded)
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "jsonl" {
            let modified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            if modified < cutoff { try fm.removeItem(at: file); continue }
            for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n") {
                guard let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let id = row["id"] as? String else { throw CocoaError(.fileReadCorruptFile) }
                records.append(row); ids.insert(id)
            }
        }
        try prune()
    }
    private func prune(now: Date = Date()) throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let cutoff = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))!
        let cutoffDay = String(iso.string(from: cutoff).prefix(10))
        for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "jsonl" && file.deletingPathExtension().lastPathComponent < cutoffDay { try fm.removeItem(at: file) }
        records = records.filter { row in (row["received_at"] as? String).flatMap(iso.date).map { $0 >= cutoff } ?? false }
        ids = Set(records.compactMap { $0["id"] as? String })
    }
    func append(_ samples: [NewGlucoseSample], receivedAt: Date) throws {
        try prune(now: receivedAt)
        let day = String(iso.string(from: receivedAt).prefix(10))
        let file = directory.appendingPathComponent(day + ".jsonl")
        if !fm.fileExists(atPath: file.path) { guard fm.createFile(atPath: file.path, contents: nil, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else { throw CocoaError(.fileWriteUnknown) } }
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.seekToEnd()
        for sample in samples {
            let row = ResearchObservation.record(syncIdentifier: sample.syncIdentifier, eventAt: sample.date, receivedAt: receivedAt, glucose: sample.quantity.doubleValue(for: HKUnit(from: "mg/dL")), isDisplayOnly: sample.isDisplayOnly, wasUserEntered: sample.wasUserEntered, condition: sample.condition?.rawValue, trend: sample.trend.map { String(describing: $0) })
            let id = row["id"] as! String
            if ids.contains(id), let old = records.first(where: { $0["id"] as? String == id }) {
                var prior = old; prior.removeValue(forKey: "received_at")
                var incoming = row; incoming.removeValue(forKey: "received_at")
                guard try JSONSerialization.data(withJSONObject: prior, options: [.sortedKeys]) == JSONSerialization.data(withJSONObject: incoming, options: [.sortedKeys]) else { throw NSError(domain: "ProjectLIVE.Journal", code: 2, userInfo: [NSLocalizedDescriptionKey: "Conflicting G6 observation identifier; research collection paused"]) }
                continue
            }
            var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]); data.append(10)
            try handle.write(contentsOf: data); try handle.synchronize()
            records.append(row); ids.insert(id)
        }
    }
    func export() throws {
        try prune()
        let folder = exportURL.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var data = Data()
        for row in records { data.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])); data.append(10) }
        try data.write(to: exportURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        var folderURL = folder; try folderURL.setResourceValues(excluded)
    }
    func disableExport() throws { if fm.fileExists(atPath: exportURL.path) { try fm.removeItem(at: exportURL) } }
    var chartValues: [GlucoseValue] {
        records.compactMap { row in
            guard let date = (row["event_at"] as? String).flatMap(iso.date), let value = row["glucose"] as? Double else { return nil }
            return SimpleGlucoseValue(startDate: date, quantity: HKQuantity(unit: HKUnit(from: "mg/dL"), doubleValue: value))
        }.sorted { $0.startDate < $1.startDate }
    }
}

final class ResearchController: UIViewController, CGMManagerDelegate, CGMManagerOnboardingDelegate, CompletionDelegate, BluetoothProvider {
    private var manager: G6CGMManager?
    private var journal: ResearchJournalStore?
    private let journalFactory: () throws -> ResearchJournalStore
    var isResearchObserving: Bool { manager != nil }
    var researchStatus: String { status.text ?? "" }
    init(journalFactory: @escaping () throws -> ResearchJournalStore = { try ResearchJournal() }) {
        self.journalFactory = journalFactory
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Research UI does not use storyboards") }
    private let status = UILabel()
    private let lastObservation = UILabel()
    private let history = UITextView()
    private let chartView = ChartContainerView()
    private let glucoseChart = PredictedGlucoseChart()
    private var charts: ChartsManager!
    private let setupButton = UIButton(type: .system)
    private let exportButton = UIButton(type: .system)
    private var exportEnabled = false
    private var retryTimer: Timer?
    private var displayTimer: Timer?
    deinit { retryTimer?.invalidate(); displayTimer?.invalidate() }
    private let preference = DisplayGlucosePreference(displayGlucoseUnit: HKUnit(from: "mg/dL"))
    private let chartColors = ChartColorPalette(axisLine: .separator, axisLabel: .secondaryLabel, grid: .separator, glucoseTint: .systemBlue, insulinTint: .systemGray, carbTint: .systemGray)
    private var palette: LoopUIColorPalette { LoopUIColorPalette(guidanceColors: GuidanceColors(), carbTintColor: .gray, glucoseTintColor: .blue, insulinTintColor: .gray, loopStatusColorPalette: StateColorPalette(unknown: .gray, normal: .blue, warning: .orange, error: .red), chartColorPalette: chartColors) }

    override func viewDidLoad() {
        super.viewDidLoad(); title = "Loop G6 Research"; view.backgroundColor = .systemBackground
        lastObservation.numberOfLines = 0; lastObservation.font = .preferredFont(forTextStyle: .caption1)
        status.numberOfLines = 0; status.text = "Read-only G6 research. No pump connection, dosing or treatment controls. Keep the G6 app and Basal-IQ operating independently."
        history.isEditable = false; history.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        setupButton.setTitle("Consent and configure G6", for: .normal); setupButton.addTarget(self, action: #selector(configure), for: .touchUpInside)
        exportButton.setTitle("Enable local research export", for: .normal); exportButton.addTarget(self, action: #selector(toggleExport), for: .touchUpInside)
        let retry = UIButton(type: .system); retry.setTitle("Retry existing G6 connection", for: .normal); retry.addTarget(self, action: #selector(retryExistingConnection), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [status, lastObservation, setupButton, retry, chartView, exportButton, history]); stack.axis = .vertical; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12), stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16), stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12), chartView.heightAnchor.constraint(equalToConstant: 220)])
        charts = ChartsManager(colors: chartColors, settings: ChartSettings(), charts: [glucoseChart], traitCollection: traitCollection)
        // Axis bounds describe the display, never fabricated sensor samples.
        glucoseChart.glucoseDisplayRange = HKQuantity(unit: HKUnit(from: "mg/dL"), doubleValue: 40)...HKQuantity(unit: HKUnit(from: "mg/dL"), doubleValue: 400)
        chartView.chartGenerator = { [weak self] frame in
            guard let self else { return nil }
            return self.renderGlucoseChart(self.journal?.chartValues ?? [], frame: frame)
        }
        do { journal = try journalFactory(); try journal?.disableExport(); refresh() }
        catch {
            UserDefaults.standard.set(false, forKey: "researchCollectionConsent")
            showError(error); setupButton.isEnabled = false; exportButton.isEnabled = false
            return // Never construct or restore a CGM without a usable journal.
        }
        displayTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
        // Never restore a generic manager or read the treatment app's shared defaults.
        if UserDefaults.standard.bool(forKey: "researchCollectionConsent"), let state = UserDefaults.standard.dictionary(forKey: "researchCGM"), let identifier = state["identifier"] as? String, ResearchPolicy.permitsCGM(identifier), let raw = state["state"] as? [String: Any], let restored = G6CGMManager(rawState: raw) { adopt(restored) }
    }
    @objc private func retryExistingConnection() {
        guard let manager else { status.text = "Configure G6 after consent before retrying an existing connection."; return }
        status.text = "Looking only for the existing iOS G6 connection. No scanning or pairing fallback."
        retryTimer?.invalidate()
        var remaining = 6
        func attempt() {
            guard self.manager === manager, UserDefaults.standard.bool(forKey: "researchCollectionConsent") else { return }
            manager.fetchNewDataIfNeeded { [weak self] result in self?.cgmManager(manager, hasNew: result) }
        }
        attempt()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] timer in
            guard let self, UIApplication.shared.applicationState == .active, remaining > 0 else { timer.invalidate(); return }
            remaining -= 1; attempt()
        }
    }
    @objc private func configure() {
        if let manager { showManagerUI(manager.settingsViewController(bluetoothProvider: self, displayGlucosePreference: preference, colorPalette: palette, allowDebugFeatures: false)); return }
        let alert = UIAlertController(title: "Local G6 research collection", message: "This restricted Loop build stores up to seven days of G6 readings privately on this iPhone. It does not replace G6 alarms or Basal-IQ. Configure only after the owner has approved the coexistence test; do not unpair or change existing treatment.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Agree and configure G6", style: .default) { [weak self] _ in
            guard let self, ResearchPolicy.permitsCGM(G6CGMManager.pluginIdentifier) else { return }
            UserDefaults.standard.set(true, forKey: "researchCollectionConsent")
            switch G6CGMManager.setupViewController(bluetoothProvider: self, displayGlucosePreference: self.preference, colorPalette: self.palette, allowDebugFeatures: false, prefersToSkipUserInteraction: false) {
            case .userInteractionRequired(let vc): self.showManagerUI(vc)
            case .createdAndOnboarded(let manager): self.cgmManagerOnboarding(didCreateCGMManager: manager)
            }
        }); present(alert, animated: true)
    }
    private func showManagerUI(_ controller: CGMManagerViewController) { var vc = controller; vc.cgmManagerOnboardingDelegate = self; vc.completionDelegate = self; present(vc, animated: true) }
    private func adopt(_ cgm: G6CGMManager) { guard journal != nil, UserDefaults.standard.bool(forKey: "researchCollectionConsent") else { cgm.transmitter.stopScanning(); return }; manager = cgm; cgm.delegateQueue = .main; cgm.cgmManagerDelegate = self; cgmManagerDidUpdateState(cgm); setupButton.setTitle("G6 settings", for: .normal); status.text = "Waiting for observed G6 data. No pump is configured. Simulator builds generate no glucose readings." }
    func cgmManagerOnboarding(didCreateCGMManager cgm: CGMManagerUI) { guard ResearchPolicy.permitsCGM(type(of: cgm).pluginIdentifier), let g6 = cgm as? G6CGMManager else { return }; adopt(g6) }
    func cgmManagerOnboarding(didOnboardCGMManager cgm: CGMManagerUI) { cgmManagerOnboarding(didCreateCGMManager: cgm) }
    func completionNotifyingDidComplete(_ object: CompletionNotifying) { dismiss(animated: true) }
    @objc private func toggleExport() {
        guard let journal else { showError(CocoaError(.fileWriteUnknown)); return }
        if exportEnabled {
            exportEnabled = false
            do { try journal.disableExport(); status.text = "Future export stopped and the local export file removed." }
            catch { status.text = "Future export stopped, but the existing export file could not be removed: \(error.localizedDescription)" }
            exportButton.setTitle("Enable local research export", for: .normal); return
        }
        let alert = UIAlertController(title: "Enable local export?", message: "Create LIVE/observations-v1.jsonl in this app's Documents for an owner-initiated USB/Finder copy. It contains glucose and timestamps, never pump data or the raw transmitter ID. No upload is performed.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); alert.addAction(UIAlertAction(title: "Enable", style: .default) { [weak self] _ in guard let self, let journal = self.journal else { return }; do { try journal.export(); self.exportEnabled = true; self.exportButton.setTitle("Disable local export", for: .normal) } catch { self.showError(error) } }); present(alert, animated: true)
    }
    func renderGlucoseChart(_ values: [GlucoseValue], frame: CGRect) -> UIView? {
        guard !values.isEmpty else { return nil }
        glucoseChart.setGlucoseValues(values)
        charts.prerender(); charts.invalidateChart(atIndex: 0)
        return charts.chart(atIndex: 0, frame: frame)?.view
    }
    private func refresh() {
        let values = journal?.chartValues ?? []; glucoseChart.setGlucoseValues(values); charts.startDate = Date().addingTimeInterval(-6 * 3600); charts.maxEndDate = Date(); charts.prerender(); charts.invalidateChart(atIndex: 0); chartView.reloadChart()
        let rows = (journal?.records ?? []).sorted { ($0["event_at"] as? String ?? "") < ($1["event_at"] as? String ?? "") }
        history.text = rows.suffix(100).reversed().map { row in
            let quality = row["quality"] as? [String: Any] ?? [:]
            let condition = quality["condition"] as? String ?? "none reported"
            let trend = quality["trend"] as? String ?? "unknown"
            let flags = [quality["is_display_only"] as? Bool == true ? "display-only" : nil, quality["was_user_entered"] as? Bool == true ? "user-entered" : nil].compactMap { $0 }.joined(separator: ", ")
            return "Measured: \(row["event_at"] as? String ?? "unknown")\nReceived: \(row["received_at"] as? String ?? "unknown")\n\(row["glucose"] ?? "?") mg/dL · condition: \(condition) · trend: \(trend) \(flags)"
        }.joined(separator: "\n\n")
        if let latest = values.last {
            let seconds = Date().timeIntervalSince(latest.startDate)
            let age = seconds < 0 ? "timestamp is in the future" : "\(Int(seconds)) seconds old"
            let receipt = rows.compactMap { $0["received_at"] as? String }.max() ?? "unknown"
            lastObservation.text = "Last measurement: \(latest.startDate.formatted()) (\(age))\nLast receipt: \(receipt)\nResearch readout; consult the independent G6 app for treatment alarms."
        } else { lastObservation.text = "No observed G6 readings. Simulator-generated readings are disabled." }

    }
    private func showError(_ error: Error) { status.text = "Research collection error: \(error.localizedDescription)" }
    func startDateToFilterNewData(for manager: CGMManager) -> Date? { nil }
    func cgmManager(_ manager: CGMManager, hasNew readingResult: CGMReadingResult) {
        guard manager === self.manager, UserDefaults.standard.bool(forKey: "researchCollectionConsent") else { return }
        guard let journal else { stopResearchObservation(reason: "Research journal unavailable; consent must be renewed after storage is repaired."); return }
        switch readingResult {
        case .newData(let samples): do { retryTimer?.invalidate(); try journal.append(samples, receivedAt: Date()); if exportEnabled { try journal.export() }; status.text = "Observed \(samples.count) G6 reading(s). Research only; treatment remains independent."; refresh() } catch { stopResearchObservation(reason: "Research collection paused: \(error.localizedDescription). Repair storage and renew consent before resuming.") }
        case .unreliableData: status.text = "G6 reported unreliable data. No glucose observation added."
        case .noData: break
        case .error(let error): showError(error)
        }
    }
    func cgmManager(_ manager: CGMManager, hasNew events: [PersistedCgmEvent]) {}
    func cgmManager(_ manager: CGMManager, didUpdate status: CGMManagerStatus) {}
    func cgmManagerDidUpdateState(_ manager: CGMManager) { guard manager === self.manager else { return }; UserDefaults.standard.set(["identifier": ResearchPolicy.cgmIdentifier, "state": manager.rawState], forKey: "researchCGM") }
    func cgmManagerWantsDeletion(_ manager: CGMManager) {
        guard manager === self.manager else { return }
        stopResearchObservation(reason: "Local G6 research observation stopped. Existing treatment remains independent.")
    }
    func stopResearchObservation(reason: String) {
        retryTimer?.invalidate(); retryTimer = nil
        UserDefaults.standard.set(false, forKey: "researchCollectionConsent")
        self.manager?.cgmManagerDelegate = nil
        self.manager?.transmitter.stayConnected = false
        self.manager?.transmitter.stopScanning()
        self.manager = nil
        UserDefaults.standard.removeObject(forKey: "researchCGM")
        exportEnabled = false
        exportButton.setTitle("Enable local research export", for: .normal)
        setupButton.setTitle("Consent and configure G6", for: .normal)
        do { try journal?.disableExport(); status.text = reason + " Future export stopped; local export removed." }
        catch { status.text = reason + " Future export stopped, but the existing export file could not be removed: " + error.localizedDescription }
    }
    func credentialStoragePrefix(for manager: CGMManager) -> String { "org.projectlive.loop.g6research" }
    func deviceManager(_ manager: DeviceManager, logEventForDeviceIdentifier deviceIdentifier: String?, type: DeviceLogEntryType, message: String, completion: ((Error?) -> Void)?) { completion?(nil) }
    func issueAlert(_ alert: LoopKit.Alert) { status.text = "G6 research status changed. Check the independent G6 app for treatment alarms." }
    func retractAlert(identifier: LoopKit.Alert.Identifier) {}
    func doesIssuedAlertExist(identifier: LoopKit.Alert.Identifier, completion: @escaping (Result<Bool, Error>) -> Void) { completion(.success(false)) }
    func lookupAllUnretracted(managerIdentifier: String, completion: @escaping (Result<[PersistedAlert], Error>) -> Void) { completion(.success([])) }
    func lookupAllUnacknowledgedUnretracted(managerIdentifier: String, completion: @escaping (Result<[PersistedAlert], Error>) -> Void) { completion(.success([])) }
    func recordRetractedAlert(_ alert: LoopKit.Alert, at date: Date) {}
    var bluetoothAuthorization: BluetoothAuthorization { .notDetermined }
    var bluetoothState: BluetoothState { .unknown }
    func authorizeBluetooth(_ completion: @escaping (BluetoothAuthorization) -> Void) { completion(.notDetermined) }
    func addBluetoothObserver(_ observer: BluetoothObserver, queue: DispatchQueue) {}
    func removeBluetoothObserver(_ observer: BluetoothObserver) {}
}
