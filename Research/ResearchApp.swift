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
        let controller = ResearchController()
        // Restoration launches may have no foreground view appearance. Recreate
        // consented storage/CGM now so CoreBluetooth can deliver restored events.
        controller.loadViewIfNeeded()
        window?.rootViewController = UINavigationController(rootViewController: controller)
        window?.makeKeyAndVisible()
        return true
    }
}

/// Private append-only daily journals; seven-day retention. Export is separately consented.
protocol ResearchJournalStore: AnyObject {
    var records: [[String: Any]] { get }
    var chartValues: [GlucoseValue] { get }
    var evidenceRecords: [[String: Any]] { get }
    func appendEvidence(_ rows: [[String: Any]]) throws
    func append(_ samples: [NewGlucoseSample], receivedAt: Date) throws
    func export() throws
    func disableExport() throws
}

/// Original untimed packets and clock references stay outside timed observations/export.
final class ResearchEvidenceJournal {
    private let directory: URL
    private let fm = FileManager.default
    private(set) var records: [[String: Any]] = []
    private var ids = Set<String>()
    private(set) var duplicateCount = 0
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    init(directory: URL? = nil) throws {
        self.directory = directory ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("G6ResearchEvidence", isDirectory: true)
        try fm.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var flags = URLResourceValues(); flags.isExcludedFromBackup = true
        var url = self.directory; try url.setResourceValues(flags)
        for file in try fm.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "jsonl" {
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
        let day = String(iso.string(from: cutoff).prefix(10))
        for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "jsonl" && file.deletingPathExtension().lastPathComponent < day { try fm.removeItem(at: file) }
        records = records.filter { ($0["received_at"] as? String).flatMap(iso.date).map { $0 >= cutoff } ?? false }
        ids = Set(records.compactMap { $0["id"] as? String })
    }
    func append(_ rows: [[String: Any]]) throws {
        try prune()
        for row in rows {
            guard let id = row["id"] as? String, let receipt = row["received_at"] as? String, iso.date(from: receipt) != nil,
                  row["event_at"] is NSNull, ["project-live.cgm-untimed-packet", "project-live.cgm-clock-reference"].contains(row["schema"] as? String ?? "") else { throw CocoaError(.fileWriteInvalidFileName) }
            if ids.contains(id) { duplicateCount += 1; continue }
            let file = directory.appendingPathComponent(String(receipt.prefix(10)) + ".jsonl")
            if !fm.fileExists(atPath: file.path) { guard fm.createFile(atPath: file.path, contents: nil, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else { throw CocoaError(.fileWriteUnknown) } }
            let handle = try FileHandle(forWritingTo: file)
            do {
                try handle.seekToEnd()
                var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]); data.append(10)
                try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
            } catch { try? handle.close(); throw error }
            records.append(row); ids.insert(id)
        }
        try prune()
    }
}

final class ResearchJournal: ResearchJournalStore {
    private let fm = FileManager.default
    private let evidence: ResearchEvidenceJournal
    var evidenceRecords: [[String: Any]] { evidence.records }
    func appendEvidence(_ rows: [[String: Any]]) throws { try evidence.append(rows) }
    private let directory: URL
    let exportURL: URL
    private(set) var records: [[String: Any]] = []
    private var ids = Set<String>()
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    init(testRoot: URL? = nil) throws {
        evidence = try ResearchEvidenceJournal(directory: testRoot?.appendingPathComponent("Evidence", isDirectory: true))
        directory = testRoot?.appendingPathComponent("Timed", isDirectory: true) ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("G6Research", isDirectory: true)
        exportURL = testRoot?.appendingPathComponent("Export/observations-v1.jsonl") ?? fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("LIVE/observations-v1.jsonl")
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
    private let isApplicationActive: () -> Bool
    private let isApplicationInBackground: () -> Bool
    private(set) var runtimeStatus = ResearchRuntimeStatus()
    var isForegroundCollecting: Bool { retryTimer != nil && connectionProbe.startedAt != nil }
    var isResearchObserving: Bool { manager != nil }
    var researchStatus: String { status.text ?? "" }
    var researchReadout: String { lastObservation.text ?? "" }
    init(journalFactory: @escaping () throws -> ResearchJournalStore = { try ResearchJournal() },
         isApplicationActive: @escaping () -> Bool = { UIApplication.shared.applicationState == .active },
         isApplicationInBackground: @escaping () -> Bool = { UIApplication.shared.applicationState == .background }) {
        self.journalFactory = journalFactory
        self.isApplicationActive = isApplicationActive
        self.isApplicationInBackground = isApplicationInBackground
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Research UI does not use storyboards") }
    private let status = UILabel()
    private let lastObservation = UILabel()
    private let connectionDiagnostics = UILabel()
    private var connectionProbe = ResearchConnectionProbe()
    private var persistedEvidenceSnapshots = Set<UUID>()
    private let history = UITextView()
    private let chartView = ChartContainerView()
    private let glucoseChart = PredictedGlucoseChart()
    private var charts: ChartsManager!
    private var chartHeight: NSLayoutConstraint!
    private let setupButton = UIButton(type: .system)
    private let exportButton = UIButton(type: .system)
    private let collectionButton = UIButton(type: .system)
    private var exportEnabled = false
    private var retryTimer: Timer?
    private var displayTimer: Timer?
    deinit { retryTimer?.invalidate(); displayTimer?.invalidate(); NotificationCenter.default.removeObserver(self) }
    private let preference = DisplayGlucosePreference(displayGlucoseUnit: HKUnit(from: "mg/dL"))
    private let chartColors = ChartColorPalette(axisLine: .separator, axisLabel: .secondaryLabel, grid: .separator, glucoseTint: .systemBlue, insulinTint: .systemGray, carbTint: .systemGray)
    private var palette: LoopUIColorPalette { LoopUIColorPalette(guidanceColors: GuidanceColors(), carbTintColor: .gray, glucoseTintColor: .blue, insulinTintColor: .gray, loopStatusColorPalette: StateColorPalette(unknown: .gray, normal: .blue, warning: .orange, error: .red), chartColorPalette: chartColors) }

    override func viewDidLoad() {
        super.viewDidLoad(); NotificationCenter.default.addObserver(self, selector: #selector(stopForegroundProbe), name: UIApplication.willResignActiveNotification, object: nil); NotificationCenter.default.addObserver(self, selector: #selector(stopForegroundProbe), name: UIApplication.didEnterBackgroundNotification, object: nil); NotificationCenter.default.addObserver(self, selector: #selector(startForegroundCollection), name: UIApplication.didBecomeActiveNotification, object: nil); title = "Loop G6 Research"; view.backgroundColor = .systemBackground
        lastObservation.numberOfLines = 0; lastObservation.font = .preferredFont(forTextStyle: .caption1)
        connectionDiagnostics.numberOfLines = 0; connectionDiagnostics.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        status.numberOfLines = 0; status.text = "Read-only G6 research. No pump connection, dosing or treatment controls. Keep the G6 app and Basal-IQ operating independently."
        history.isEditable = false; history.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        setupButton.setTitle("Consent and configure G6", for: .normal); setupButton.addTarget(self, action: #selector(configure), for: .touchUpInside)
        exportButton.setTitle("Enable local research export", for: .normal); exportButton.addTarget(self, action: #selector(toggleExport), for: .touchUpInside)
        collectionButton.setTitle("Resume collection", for: .normal); collectionButton.addTarget(self, action: #selector(toggleCollection), for: .touchUpInside)
        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(scroll)
        let stack = UIStackView(arrangedSubviews: [status, lastObservation, setupButton, collectionButton, connectionDiagnostics, chartView, exportButton, history]); stack.axis = .vertical; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(stack)
        chartHeight = chartView.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor), stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 12), stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16), stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -12), stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -32), chartHeight, history.heightAnchor.constraint(equalToConstant: 180)])
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
    @objc func toggleCollection() {
        guard manager != nil else { return }
        let paused = !UserDefaults.standard.bool(forKey: "researchCollectionPaused")
        UserDefaults.standard.set(paused, forKey: "researchCollectionPaused")
        if paused {
            stopForegroundProbe()
            manager?.transmitter.stopScanning()
            status.text = "Research collection paused. Stored observations retained."
        } else { enableBackgroundObservation(); startForegroundCollection() }
        refreshConnectionDiagnostics()
        saveRuntimeStatus()
    }
    private func enableBackgroundObservation() {
        guard let manager, UserDefaults.standard.bool(forKey: "researchCollectionConsent"),
              !UserDefaults.standard.bool(forKey: "researchCollectionPaused") else { return }
        manager.transmitter.stayConnected = true
        saveRuntimeStatus()
    }
    private func saveRuntimeStatus() {
        runtimeStatus.journalCount = journal?.records.count ?? 0
        runtimeStatus.foregroundActive = isApplicationActive()
        runtimeStatus.collectionEnabled = manager != nil && UserDefaults.standard.bool(forKey: "researchCollectionConsent") && !UserDefaults.standard.bool(forKey: "researchCollectionPaused")
        runtimeStatus.bluetooth = manager?.transmitter.researchConnectionDiagnostics.summary ?? "observer stopped"
        // Local diagnostic snapshot is separate from observations and their export.
        // Failure to write diagnostics must not discard an otherwise stored sample.
        do {
            let fm = FileManager.default
            var directory = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("G6ResearchStatus", isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var flags = URLResourceValues(); flags.isExcludedFromBackup = true
            try directory.setResourceValues(flags)
            try JSONEncoder().encode(runtimeStatus).write(to: directory.appendingPathComponent("status-v1.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { /* Optional diagnostic snapshot; observation journal has its own fail-closed handling. */ }
    }
    @objc private func startForegroundCollection() {
        refresh() // A cold background launch may not have rendered the readout yet.
        guard let manager, isApplicationActive(),
              UserDefaults.standard.bool(forKey: "researchCollectionConsent"),
              !UserDefaults.standard.bool(forKey: "researchCollectionPaused") else { return }
        guard retryTimer == nil else { return }
        status.text = "Collection enabled. iOS connection events can resume observation in the background. Waiting for the existing G6 connection."
        connectionProbe.start(at: ProcessInfo.processInfo.systemUptime)
        manager.transmitter.stayConnected = true
        attemptExistingConnection()
        retryTimer = Timer.scheduledTimer(withTimeInterval: ResearchConnectionProbe.interval, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.attemptExistingConnection()
        }
    }
    @objc private func stopForegroundProbe() {
        retryTimer?.invalidate(); retryTimer = nil; connectionProbe.cancel()
        refreshConnectionDiagnostics()
        saveRuntimeStatus()
    }
    private func attemptExistingConnection() {
        guard let manager, connectionProbe.permitsAttempt(at: ProcessInfo.processInfo.systemUptime,
            active: isApplicationActive(),
            consented: UserDefaults.standard.bool(forKey: "researchCollectionConsent") && !UserDefaults.standard.bool(forKey: "researchCollectionPaused")) else {
            retryTimer?.invalidate(); retryTimer = nil; connectionProbe.cancel()
            refreshConnectionDiagnostics()
            return
        }
        // Lookup only: do not rebuild history/chart or drain journals on every timer tick.
        manager.transmitter.resumeScanning()
        refreshConnectionDiagnostics()
    }
    private func refreshConnectionDiagnostics() {
        collectionButton.isEnabled = manager != nil
        guard let manager else { connectionDiagnostics.text = nil; return }
        let paused = UserDefaults.standard.bool(forKey: "researchCollectionPaused")
        collectionButton.setTitle(paused ? "Resume collection" : "Pause collection", for: .normal)
        let probe = paused ? "Collection paused by owner." : (connectionProbe.startedAt == nil ? "Background observation armed; waiting for iOS Bluetooth events." : "Background observation armed; foreground lookup also active.")
        connectionDiagnostics.text = manager.transmitter.researchConnectionDiagnostics.summary + "\n" + probe
    }
    @objc private func configure() {
        if let manager { showManagerUI(manager.settingsViewController(bluetoothProvider: self, displayGlucosePreference: preference, colorPalette: palette, allowDebugFeatures: false)); return }
        let alert = UIAlertController(title: "Local G6 research collection", message: "This restricted Loop build collects G6 readings, including in the background when iOS permits, and stores up to seven days privately on this iPhone. It does not replace G6 alarms or Basal-IQ. Configure only after the owner has approved the coexistence test; do not unpair or change existing treatment.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Agree and configure G6", style: .default) { [weak self] _ in
            guard let self, ResearchPolicy.permitsCGM(G6CGMManager.pluginIdentifier) else { return }
            UserDefaults.standard.set(true, forKey: "researchCollectionConsent")
            UserDefaults.standard.set(false, forKey: "researchCollectionPaused")
            switch G6CGMManager.setupViewController(bluetoothProvider: self, displayGlucosePreference: self.preference, colorPalette: self.palette, allowDebugFeatures: false, prefersToSkipUserInteraction: false) {
            case .userInteractionRequired(let vc): self.showManagerUI(vc)
            case .createdAndOnboarded(let manager): self.cgmManagerOnboarding(didCreateCGMManager: manager)
            }
        }); present(alert, animated: true)
    }
    private func showManagerUI(_ controller: CGMManagerViewController) { var vc = controller; vc.cgmManagerOnboardingDelegate = self; vc.completionDelegate = self; present(vc, animated: true) }
    private func adopt(_ cgm: G6CGMManager) { guard journal != nil, UserDefaults.standard.bool(forKey: "researchCollectionConsent") else { cgm.transmitter.stopScanning(); return }; manager = cgm; cgm.delegateQueue = .main; cgm.cgmManagerDelegate = self; cgmManagerDidUpdateState(cgm); setupButton.setTitle("G6 settings", for: .normal); status.text = "Waiting for observed G6 data. No pump is configured. Simulator builds generate no glucose readings."; if UserDefaults.standard.bool(forKey: "researchCollectionPaused") { cgm.transmitter.stopScanning() }; enableBackgroundObservation(); startForegroundCollection(); refreshConnectionDiagnostics() }
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
        persistResearchEvidence()
        guard isApplicationActive() else { return } // Persist callbacks without chart/UI work during a Bluetooth wake.
        refreshConnectionDiagnostics()
        let values = journal?.chartValues ?? []; chartHeight.constant = values.isEmpty ? 0 : 220; glucoseChart.setGlucoseValues(values); charts.startDate = Date().addingTimeInterval(-6 * 3600); charts.maxEndDate = Date(); charts.prerender(); charts.invalidateChart(atIndex: 0); chartView.reloadChart()
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
        } else { lastObservation.text = "No timestamped G6 readings. Simulator-generated readings are disabled." }
        let untimed = (journal?.evidenceRecords ?? []).filter { $0["schema"] as? String == "project-live.cgm-untimed-packet" }.sorted { ($0["received_at"] as? String ?? "") < ($1["received_at"] as? String ?? "") }
        if let latest = untimed.last {
            let receipt = latest["received_at"] as? String ?? "unknown"
            let reliable = latest["quality_reliable"] as? Bool == true
            let value = reliable ? "G6 packet value: \(latest["glucose_raw"] ?? "?") mg/dL" : "G6 packet retained; quality flagged."
            if receipt >= (rows.compactMap { $0["received_at"] as? String }.max() ?? "") {
                lastObservation.text = value + "\nMeasurement time and currentness unknown.\nPhone receipt: " + receipt + "\nExcluded from timed chart, export and predictions."
            }
            history.text += "\nUntimed packets retained privately: \(untimed.count). Original receipt/device clocks preserved; no automatic time reconstruction."
        }

    }
    private func persistResearchEvidence() {
        guard let manager, let journal, UserDefaults.standard.bool(forKey: "researchCollectionConsent") else { return }
        let transmitter = manager.transmitter
        persistedEvidenceSnapshots.formIntersection(Set(transmitter.researchUntimedGlucose.map { $0.recordID } + transmitter.researchClockReferences.map { $0.recordID }))
        let newUntimed = transmitter.researchUntimedGlucose.filter { !persistedEvidenceSnapshots.contains($0.recordID) }
        let newClocks = transmitter.researchClockReferences.filter { !persistedEvidenceSnapshots.contains($0.recordID) }
        guard !newUntimed.isEmpty || !newClocks.isEmpty else { return }
        let untimed = newUntimed.map {
            ResearchObservation.untimedRecord(streamID: $0.streamID, packet: $0.rawPacket, receivedAt: $0.receivedAt, receivedUptime: $0.receivedUptime, transmitterUptime: $0.transmitterUptime, status: $0.status, sequence: $0.sequence, glucoseRaw: $0.glucoseRaw, state: $0.state, trend: $0.trend, isDisplayOnly: $0.isDisplayOnly, isReliable: $0.isReliable)
        }
        let clocks = newClocks.map {
            ResearchObservation.clockRecord(streamID: $0.streamID, packet: $0.rawPacket, receivedAt: $0.receivedAt, receivedUptime: $0.receivedUptime, transmitterUptime: $0.transmitterUptime, status: $0.status, sessionStartTime: $0.sessionStartTime)
        }
        do {
            try journal.appendEvidence(untimed + clocks)
            persistedEvidenceSnapshots.formUnion((newUntimed.map { $0.recordID }) + (newClocks.map { $0.recordID }))
            if !newUntimed.isEmpty { status.text = "Received G6 packet; measurement time unresolved. Stored privately and excluded from timed analysis." }
        }
        catch { stopResearchObservation(reason: "Research evidence storage failed; collection paused.") }
    }
    private func showError(_ error: Error) { status.text = "Research collection error: \(error.localizedDescription)" }
    func startDateToFilterNewData(for manager: CGMManager) -> Date? { nil }
    func cgmManager(_ manager: CGMManager, hasNew readingResult: CGMReadingResult) {
        guard manager === self.manager, UserDefaults.standard.bool(forKey: "researchCollectionConsent"), !UserDefaults.standard.bool(forKey: "researchCollectionPaused") else { return }
        guard let journal else { stopResearchObservation(reason: "Research journal unavailable; consent must be renewed after storage is repaired."); return }
        persistResearchEvidence()
        guard manager === self.manager else { return }
        var storedSamples = 0
        var transportError = false
        defer {
            runtimeStatus.received(background: isApplicationInBackground(), timedSamples: storedSamples, transportError: transportError)
            saveRuntimeStatus()
        }
        switch readingResult {
        case .newData(let samples): do { try journal.append(samples, receivedAt: Date()); storedSamples = samples.count; if exportEnabled { try journal.export() }; status.text = "Stored \(journal.records.count) timestamped G6 reading(s). Collection remains enabled; treatment stays independent."; refresh() } catch { stopResearchObservation(reason: "Research collection paused: \(error.localizedDescription). Repair storage and renew consent before resuming.") }
        case .unreliableData: status.text = "G6 reported unreliable data. No glucose observation added."
        case .noData: refresh()
        case .error(let error):
            transportError = true
            if let transport = error as? TransmitterError {
                switch transport {
                case .controlError: status.text = "G6 notification setup interrupted. Stored readings retained; waiting for the next existing G6 connection event."
                case .authenticationError: status.text = "G6 authentication observation failed. No authentication commands issued. Stored readings retained."
                case .observationError: status.text = "G6 observation could not be accepted. Stored readings retained; see packet diagnostics."
                }
            } else { showError(error) }
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
        retryTimer?.invalidate(); retryTimer = nil; connectionProbe.cancel()
        UserDefaults.standard.set(false, forKey: "researchCollectionConsent")
        self.manager?.cgmManagerDelegate = nil
        self.manager?.transmitter.stayConnected = false
        self.manager?.transmitter.stopScanning()
        self.manager = nil
        saveRuntimeStatus()
        persistedEvidenceSnapshots.removeAll()
        refreshConnectionDiagnostics()
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
