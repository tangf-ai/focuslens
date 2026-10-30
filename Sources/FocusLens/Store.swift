import AppKit
import Combine
import Foundation

@MainActor
final class ReviewStreamingState: ObservableObject {
    @Published var text = ""
}

@MainActor
final class FocusStore: ObservableObject {
    @Published var data = AppData()
    @Published var now = Date()
    @Published var errorMessage: String?
    @Published private(set) var hasVisibleWindow = true
    let directory: URL
    let appearance: AppearanceStore
    var openMainWindowAction: (() -> Void)?
    private let clockEnabled: Bool
    private var calendarTimer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var loadingFailed = false
    private var automaticInstance: AutomaticTracker?
    private var summaryInstance: AutomaticSummaryController?
    var automatic: AutomaticTracker {
        if let automaticInstance { return automaticInstance }
        let tracker = AutomaticTracker(directory: directory, startClock: clockEnabled && !loadingFailed, appearance: appearance)
        automaticInstance = tracker
        return tracker
    }
    var summary: AutomaticSummaryController {
        if let summaryInstance { return summaryInstance }
        let controller = AutomaticSummaryController(directory: directory, tracker: automatic, startClock: clockEnabled && !loadingFailed)
        summaryInstance = controller
        return controller
    }
    private var fileURL: URL { directory.appendingPathComponent("focus-data.json") }

    init(directory: URL? = nil, startClock: Bool = true) {
        clockEnabled = startClock
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FocusLens", isDirectory: true)
        appearance = AppearanceStore(directory: self.directory)
        load()
        if startClock { observeLifecycle(); armCalendarTimer() }
    }
    deinit {
        calendarTimer?.invalidate()
        for (center, token) in observers { center.removeObserver(token) }
    }

    private func armCalendarTimer() {
        calendarTimer?.invalidate()
        guard clockEnabled, let midnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) else { return }
        let timer = Timer(fire: midnight.addingTimeInterval(0.1), interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshAfterLifecycleChange() }
        }
        timer.tolerance = 1; RunLoop.main.add(timer, forMode: .common); calendarTimer = timer
    }
    private func observeLifecycle() {
        let center = NotificationCenter.default
        let termination = center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.summaryInstance?.shutdown(); self?.automaticInstance?.shutdown() }
        }
        observers.append((center, termination))
        for name in [NSApplication.didBecomeActiveNotification, NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     .NSSystemTimeZoneDidChange, Notification.Name("NSSystemClockDidChangeNotification")] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshAfterLifecycleChange() }
            }
            observers.append((center, token))
        }
        let workspace = NSWorkspace.shared.notificationCenter
        let token = workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshAfterLifecycleChange() }
        }
        observers.append((workspace, token))
    }
    private func refreshAfterLifecycleChange() {
        if let windows = NSApp?.windows {
            let visible = windows.contains { $0.identifier != ActivityFloatingController.identifier && $0.canBecomeMain && $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) }
            if visible != hasVisibleWindow { hasVisibleWindow = visible }
        }
        now = Date(); armCalendarTimer()
        summaryInstance?.reconcile()
    }

    func load() {
        do {
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                if FileManager.default.fileExists(atPath: directory.appendingPathComponent("automatic-settings.json").path) {
                    let backup = try backupData(label: "before-automatic-only")
                    data.legacyTransition = LegacyTransition(migratedAt: Date(), backupFolder: backup.lastPathComponent)
                    try write(data)
                }
                return
            }
            let original = try Data(contentsOf: fileURL)
            var loaded = try JSONDecoder().decode(AppData.self, from: original)
            guard (1...3).contains(loaded.schemaVersion) else { throw StoreError.unsupportedVersion }
            if loaded.schemaVersion < 3 {
                let migratedAt = Date()
                let backup = try backupData(label: "before-automatic-only")
                var run = loaded.activeRun
                // Freeze at upgrade time without inventing an outcome or adding archived time to activity statistics.
                if var active = run, !active.isPaused {
                    active.accumulatedSeconds = active.elapsed(at: migratedAt); active.resumedAt = nil; run = active
                }
                loaded.legacyTransition = LegacyTransition(migratedAt: migratedAt, activeRun: run,
                                                          pendingFeedback: loaded.pendingFeedback, backupFolder: backup.lastPathComponent)
                loaded.activeRun = nil; loaded.pendingFeedback = nil; loaded.schemaVersion = 3
                try write(loaded)
            }
            for index in loaded.reviews.indices {
                if loaded.reviews[index].state == .generating {
                    loaded.reviews[index].state = .cancelled
                    loaded.reviews[index].error = "旧版生成已中断，内容保留为只读归档。"
                }
                if var messages = loaded.reviews[index].messages {
                    for offset in messages.indices where messages[offset].state == .generating { messages[offset].state = .cancelled }
                    loaded.reviews[index].messages = messages
                }
            }
            data = loaded
        } catch {
            loadingFailed = true
            errorMessage = "本地记录读取或迁移失败，已停止写入。请先备份数据目录再检查 focus-data.json。\n\(error.localizedDescription)"
        }
    }
    private func write(_ value: AppData) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
    @discardableResult func persist() -> Bool {
        guard !loadingFailed else { return false }
        do { try write(data); return true }
        catch { errorMessage = "记录保存失败：\(error.localizedDescription)"; return false }
    }

    @discardableResult func backupData(label: String) throws -> URL {
        let backup = directory.appendingPathComponent("backups/\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backup.path)
        for name in ["focus-data.json", "automatic-settings.json", "appearance-settings.json", "automatic-idle-periods.json", "automatic-summaries.json", "recognition-diagnostics.json", "automatic-activities"] {
            let source = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: source.path) { try FileManager.default.copyItem(at: source, to: backup.appendingPathComponent(name)) }
        }
        return backup
    }

    func applyCompactMainWindow() {
        guard clockEnabled, !UserDefaults.standard.bool(forKey: "FocusLensAutomaticLayoutV1") else { return }
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.identifier != ActivityFloatingController.identifier && $0.canBecomeMain && !$0.styleMask.contains(.fullScreen) }) else { return }
            window.setContentSize(NSSize(width: 1080, height: 760))
            UserDefaults.standard.set(true, forKey: "FocusLensAutomaticLayoutV1")
        }
    }
    func restoreMainWindow() {
        if let window = NSApp.windows.first(where: { $0.identifier != ActivityFloatingController.identifier && $0.canBecomeMain }) {
            window.deminiaturize(nil); window.makeKeyAndOrderFront(nil)
        } else { openMainWindowAction?() }
        NSApp.activate()
    }

    struct ExportBundle: Codable {
        var exportedAt: Date
        var legacy: AppData
        var activities: [ActivitySegment]
        var summaries: [ActivitySummary]
        var idleArchive: [InactivityPeriod]
    }
    func exportBundle() throws -> ExportBundle {
        guard !loadingFailed, summary.dataReadable else { throw StoreError.protectedData }
        return ExportBundle(exportedAt: Date(), legacy: data, activities: try automatic.allSegments(),
                            summaries: summary.archive.reports, idleArchive: automatic.inactivityPeriods)
    }
    func exportAll() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "专注镜-全部记录.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(exportBundle()).write(to: url, options: .atomic)
        } catch { errorMessage = "导出失败，未导出不完整数据：\(error.localizedDescription)" }
    }
    @discardableResult func clearAutomaticData() -> Bool {
        guard !loadingFailed else { return false }
        do {
            summary.shutdown(); automatic.pause()
            _ = try backupData(label: "before-clear")
            try summary.clear()
            try automatic.clearActivities()
            return true
        } catch { errorMessage = "清除未完成，已保留备份；请检查数据目录：\(error.localizedDescription)"; return false }
    }
    func openDataDirectory() {
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); NSWorkspace.shared.open(directory) }
        catch { errorMessage = error.localizedDescription }
    }
}

enum StoreError: LocalizedError {
    case unsupportedVersion, protectedData
    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "此数据由更高版本创建，请使用匹配版本打开。"
        case .protectedData: "数据读取失败，已停止操作以保护原文件。"
        }
    }
}
