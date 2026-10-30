import AppKit
import Combine
import CryptoKit

@MainActor
final class AutomaticTracker: ObservableObject {
    let appearance: AppearanceStore
    @Published private(set) var config = AutomaticConfig()
    @Published private(set) var status: AutomaticStatus = .off
    @Published private(set) var ledger = ActivityLedger()
    @Published private(set) var lastIdentified: Date?
    @Published private(set) var isRecognizing = false
    @Published private(set) var recognitionStartedAt: Date?
    @Published private(set) var lastRecognitionDuration: TimeInterval?
    @Published private(set) var testing = false
    @Published private(set) var testMessage = "尚未测试图片理解"
    @Published var errorMessage: String?
    @Published private(set) var keyAvailable = false
    @Published private(set) var inactivityPeriods: [InactivityPeriod] = []
    @Published private(set) var recognitionDiagnostics: [RecognitionDiagnostic] = []
    @Published private(set) var diagnosticWarning: String?
    var openMain: (() -> Void)?
    private let directory: URL
    private let keyScope: String
    private let clockEnabled: Bool
    private var timer: Timer?
    private var inactivityTimer: Timer?
    private var inactiveID: UUID?
    private var observationStartedAt: Date?
    private var lastInactivityCheck: Date?
    private let idleSeconds: () -> TimeInterval
    private let clock: () -> Date
    private var task: Task<Void, Never>?
    private var testTask: Task<Void, Never>?
    private var revision = UUID()
    private var paused = false
    private var explicitlyAway = false
    private var lifecycleBlocks: Set<String> = []
    private var away: Bool { explicitlyAway || !lifecycleBlocks.isEmpty }
    private var front: ForegroundContext?
    private var frontWindow: CGWindowID?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var floating: ActivityFloatingController?
    private var lastFrameKey: String?
    private var lastFingerprint: Data?
    private var savedHashes: [String: String] = [:]
    private var writable = true
    private var storedDisplay: ActivitySegment?
    private var lastAttempt: Date?
    private var pendingWindowID: CGWindowID?
    private var consecutiveFailures = 0
    private var activeDiagnostic: RecognitionDiagnostic?
    private var diagnosticsWritable = true
    private let capture: (ForegroundContext) async throws -> MemoryScreenCapture.Frame
    private let analyze: (Data, AutomaticConfig, String?) async throws -> ActivityClassification
    private let permission: () -> Bool
    private let foreground: () -> ForegroundContext?
    private let foregroundWindowID: (ForegroundContext) -> CGWindowID?
    private let sessionAvailable: () -> Bool
    var display: ActivitySegment? { ledger.current ?? storedDisplay }
    var observationDate: Date { clock() }
    var current: ActivitySegment? { ledger.current }
    func liveSegment(at date: Date? = nil) -> ActivitySegment? {
        let date = date ?? clock()
        guard var item = ledger.current else { return storedDisplay }
        let until = inactivityBoundary(at: date, category: item.category).map { max(item.start, min(date, $0)) } ?? date
        if until >= item.end && until.timeIntervalSince(item.end) <= ledger.maximumGap { item.end = until }
        return item
    }
    var verified: Bool { config.verifiedSignature == VisionService.signature(config) }
    var hasPermission: Bool { permission() }
    func recognitionDetail(at date: Date? = nil) -> String {
        let date = date ?? clock()
        if case .error(let message) = status { return message }
        switch status { case .recording, .uncertain, .waiting, .recognizing: break; default: return status.detail }
        if isRecognizing, let start = recognitionStartedAt {
            let elapsed = max(0, Int(date.timeIntervalSince(start)))
            return status == .recording ? "后台更新中 · 已用 \(elapsed) 秒" : "正在识别\(front?.name ?? "当前窗口") · 已用 \(elapsed) 秒"
        }
        if status == .waiting { return "\(front?.name ?? "当前窗口") · 稍后自动更新" }
        guard let lastIdentified else { return status.detail }
        let seconds = max(0, Int(date.timeIntervalSince(lastIdentified)))
        let age = seconds < 60 ? "\(seconds) 秒前" : "\(seconds / 60) 分钟前"
        let duration = lastRecognitionDuration.map { " · 耗时 " + String(format: "%.1f", $0) + " 秒" } ?? ""
        return "最近识别 \(age)" + duration
    }
    func visionAPIKey() throws -> String? { try Keychain.read(scope: keyScope) }
    private var configURL: URL { directory.appendingPathComponent("automatic-settings.json") }
    private var recordsDirectory: URL { directory.appendingPathComponent("automatic-activities", isDirectory: true) }
    private var inactivityURL: URL { directory.appendingPathComponent("automatic-idle-periods.json") }
    private var diagnosticsURL: URL { directory.appendingPathComponent("recognition-diagnostics.json") }

    init(directory: URL, startClock: Bool = true,
         idleSeconds: @escaping () -> TimeInterval = SystemInactivity.seconds,
         now: @escaping () -> Date = Date.init,
         appearance: AppearanceStore? = nil,
         permission: @escaping () -> Bool = { MemoryScreenCapture.allowed },
         sessionAvailable: @escaping () -> Bool = { MemoryScreenCapture.sessionAvailable },
         foreground: @escaping () -> ForegroundContext? = { ForegroundContext.current() },
         foregroundWindowID: @escaping (ForegroundContext) -> CGWindowID? = { MemoryScreenCapture.currentWindowID($0) },
         capture: @escaping (ForegroundContext) async throws -> MemoryScreenCapture.Frame = { try await MemoryScreenCapture.capture($0) },
         analyze: @escaping (Data, AutomaticConfig, String?) async throws -> ActivityClassification = { try await VisionService.classify(image: $0, settings: $1.ai, key: $2, workBackground: $1.workBackground, rules: $1.classificationRules) }) {
        self.directory = directory; self.clockEnabled = startClock
        self.idleSeconds = idleSeconds; self.clock = now
        self.appearance = appearance ?? AppearanceStore(directory: directory)
        self.keyScope = "vision:" + directory.standardizedFileURL.path
        self.permission = permission; self.sessionAvailable = sessionAvailable; self.foreground = foreground; self.capture = capture; self.analyze = analyze
        self.foregroundWindowID = foregroundWindowID
        load()
        loadDiagnostics()
        paused = config.pausedByUser
        config.snoozeUntil = nil; config.reminders = false
        keyAvailable = (try? Keychain.read(scope: keyScope))?.isEmpty == false
        if verified { testMessage = "图片理解测试通过（已保存）" }
        if startClock { observe(); reconcile() }
    }

    deinit {
        timer?.invalidate(); inactivityTimer?.invalidate(); task?.cancel(); testTask?.cancel()
        for (center, token) in observers { center.removeObserver(token) }
    }

    private static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func loadDiagnostics() {
        guard FileManager.default.fileExists(atPath: diagnosticsURL.path) else { return }
        do {
            recognitionDiagnostics = Array(try JSONDecoder().decode([RecognitionDiagnostic].self, from: Data(contentsOf: diagnosticsURL)).suffix(200))
        } catch {
            diagnosticsWritable = false
            diagnosticWarning = "识别诊断文件无法读取，已停止覆盖；活动记录不受影响。"
        }
    }

    private func finishRecognition(_ outcome: RecognitionDiagnostic.Outcome, code: String? = nil) {
        guard var entry = activeDiagnostic else { return }
        activeDiagnostic = nil
        entry.endedAt = clock(); entry.outcome = outcome; entry.code = code
        recognitionDiagnostics.append(entry)
        recognitionDiagnostics = Array(recognitionDiagnostics.suffix(200))
        guard diagnosticsWritable else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(recognitionDiagnostics).write(to: diagnosticsURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: diagnosticsURL.path)
        } catch {
            diagnosticsWritable = false
            diagnosticWarning = "识别诊断暂无法保存；活动记录继续，请检查数据目录。"
        }
    }
    private func load() {
        do {
            if FileManager.default.fileExists(atPath: configURL.path) { config = try JSONDecoder().decode(AutomaticConfig.self, from: Data(contentsOf: configURL)) }
            config.intervalSeconds = config.intervalSeconds
            config.normalizeGuidance()
            config.reminderMinutes = max(5, min(120, config.reminderMinutes))
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            for offset in 0...8 {
                let date = calendar.date(byAdding: .day, value: -offset, to: clock())!
                let key = Self.dayKey(date), file = recordsDirectory.appendingPathComponent(key + ".json")
                if FileManager.default.fileExists(atPath: file.path) {
                    let data = try Data(contentsOf: file)
                    ledger.segments += try JSONDecoder().decode([ActivitySegment].self, from: data)
                    savedHashes[key] = Self.digest(data)
                }
            }
            ledger.segments.sort { $0.start < $1.start }
            guard ledger.segments.allSatisfy({ $0.end >= $0.start }) else { throw AutomaticError.invalidResponse }
            ledger.maximumGap = config.maximumObservationGap
            try loadInactivity()
        } catch { writable = false; errorMessage = "自动记录文件读取失败，已停止自动记录写入。请先备份并检查自动记录文件。" }
    }

    @discardableResult
    func persist() -> Bool {
        guard writable else { return false }
        do {
            try FileManager.default.createDirectory(at: recordsDirectory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: recordsDirectory.path)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(config).write(to: configURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
            for (key, segments) in Dictionary(grouping: ledger.segments, by: { Self.dayKey($0.start) }) {
                let bytes = try encoder.encode(segments)
                let hash = Self.digest(bytes)
                if savedHashes[key] != hash {
                    try bytes.write(to: recordsDirectory.appendingPathComponent(key + ".json"), options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordsDirectory.appendingPathComponent(key + ".json").path)
                    savedHashes[key] = hash
                }
            }
            var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
            let cutoff = utc.startOfDay(for: clock().addingTimeInterval(-9 * 86400))
            let currentID = ledger.currentID
            // Prune whole UTC files only; a partially retained day must never overwrite its history.
            ledger.segments.removeAll { $0.start < cutoff && $0.id != currentID }
            return true
        } catch {
            writable = false; config.enabled = false
            task?.cancel(); timer?.invalidate()
            inactivityTimer?.invalidate()
            status = .error("自动记录保存失败，已停止截图。请检查磁盘空间和文件权限。")
            errorMessage = status.detail
            return false
        }
    }

    func segments(in interval: DateInterval) -> [ActivitySegment] {
        (try? readSegments(in: interval)) ?? []
    }

    func readSegments(in interval: DateInterval) throws -> [ActivitySegment] {
        var stored: [ActivitySegment] = []
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var date = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: interval.start))!
        while date < interval.end {
            let file = recordsDirectory.appendingPathComponent(Self.dayKey(date) + ".json")
            if FileManager.default.fileExists(atPath: file.path) {
                let items = try JSONDecoder().decode([ActivitySegment].self, from: Data(contentsOf: file))
                guard items.allSatisfy({ $0.end >= $0.start }) else { throw AutomaticError.invalidResponse }
                stored += items
            }
            date = calendar.date(byAdding: .day, value: 1, to: date)!
        }
        var byID = Dictionary(stored.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        for segment in ledger.segments { byID[segment.id] = segment }
        return byID.values.compactMap { segment in
            var item = segment
            item.start = max(item.start, interval.start); item.end = min(item.end, interval.end)
            return item.end > item.start ? item : nil
        }.sorted { $0.start > $1.start }
    }

    func allSegments() throws -> [ActivitySegment] {
        var records: [UUID: ActivitySegment] = [:]
        if FileManager.default.fileExists(atPath: recordsDirectory.path) {
            for file in try FileManager.default.contentsOfDirectory(at: recordsDirectory, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                for segment in try JSONDecoder().decode([ActivitySegment].self, from: Data(contentsOf: file)) {
                    guard segment.end >= segment.start else { throw AutomaticError.invalidResponse }
                    records[segment.id] = segment
                }
            }
        }
        for segment in ledger.segments { records[segment.id] = segment }
        return records.values.sorted { $0.start < $1.start }
    }

    // The caller creates a complete backup before invoking this destructive operation.
    func clearActivities() throws {
        disable()
        guard writable else { throw AutomaticError.invalidResponse }
        for url in [recordsDirectory, inactivityURL, diagnosticsURL] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        ledger = ActivityLedger(); ledger.maximumGap = config.maximumObservationGap
        inactivityPeriods = []; inactiveID = nil; storedDisplay = nil
        savedHashes = [:]; lastFingerprint = nil; lastFrameKey = nil; lastIdentified = nil
        recognitionDiagnostics = []; diagnosticsWritable = true; diagnosticWarning = nil
        guard persist() else { throw AutomaticError.invalidResponse }
    }

    @discardableResult
    func saveGuidance(workBackground: String?, classificationRules: String?) -> Bool {
        guard writable else { return false }
        // Save only guidance, even if the model settings are not configured yet.
        var updated = config
        updated.workBackground = workBackground
        updated.classificationRules = classificationRules
        updated.normalizeGuidance()
        guard updated != config else { return true }
        cancelWork()
        finishInactivity(at: clock())
        guard writable else { return false }
        lastFingerprint = nil
        config = updated
        guard persist() else { return false }
        reconcile()
        return true
    }

    @discardableResult
    func saveConfig(_ draft: AutomaticConfig, newKey: String?) -> Bool {
        guard writable else { return false }
        do {
            _ = try AIService.endpoint(draft.ai.baseURL)
            guard !draft.ai.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AutomaticError.missingModel }
            cancelWork()
            finishInactivity(at: clock())
            var updated = draft
            updated.normalizeGuidance()
            updated.intervalSeconds = draft.intervalSeconds
            updated.ai.baseURL = draft.ai.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.ai.model = draft.ai.model.trimmingCharacters(in: .whitespacesAndNewlines)
            let keyUpdate = try VisionService.credentialUpdate(previous: config.ai, next: updated.ai, provided: newKey)
            let changedModel = updated.ai != config.ai || keyUpdate != nil
            updated.enabled = changedModel ? false : config.enabled
            updated.pausedByUser = config.pausedByUser; updated.snoozeUntil = config.snoozeUntil
            updated.verifiedSignature = changedModel ? nil : config.verifiedSignature
            updated.consentSignature = changedModel ? nil : config.consentSignature
            if let key = keyUpdate {
                if key.isEmpty { try Keychain.delete(scope: keyScope) } else { try Keychain.save(key, scope: keyScope) }
                updated.credentialRevision = UUID().uuidString
                keyAvailable = !key.isEmpty
            }
            // Re-analyze even an unchanged screenshot with the new instructions.
            if updated.workBackground != config.workBackground || updated.classificationRules != config.classificationRules {
                lastFingerprint = nil
            }
            config = updated
            ledger.maximumGap = config.maximumObservationGap
            testMessage = changedModel ? "配置已保存，需要重新测试图片理解并确认开启。" : (verified ? "图片理解测试通过" : "尚未测试图片理解")
            guard persist() else { return false }
            reconcile()
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func testVision() {
        guard !testing, writable else { return }
        do {
            guard !config.ai.model.isEmpty else { throw AutomaticError.missingModel }
            let challenge = try VisionChallenge.make()
            let settings = config.ai, key = try Keychain.read(scope: keyScope), signature = VisionService.signature(config)
            finishInactivity(at: clock()); setInactivityTimer(active: false)
            cancelWork(); testing = true; status = .paused
            testMessage = "正在使用随机示例图测试，不截取桌面…"
            testTask = Task { [weak self] in
                guard let self else { return }
                defer { self.testing = false; self.testTask = nil; self.reconcile() }
                do {
                    try await VisionService.test(settings: settings, key: key, challenge: challenge)
                    try Task.checkCancellation()
                    guard signature == VisionService.signature(self.config) else { return }
                    self.config.verifiedSignature = signature
                    self.testMessage = "图片理解测试通过"
                    self.persist()
                } catch { self.testMessage = "测试未通过：\(error.localizedDescription)" }
            }
        } catch { testMessage = error.localizedDescription }
    }

    func requestPermission() {
        _ = CGRequestScreenCaptureAccess()
        if !permission(), let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }

    func enable(consent: Bool) {
        guard writable else { return }
        guard verified else { errorMessage = AutomaticError.notVerified.localizedDescription; return }
        guard consent else { errorMessage = AutomaticError.noConsent.localizedDescription; return }
        guard permission() else { errorMessage = AutomaticError.permission.localizedDescription; return }
        config.consentSignature = VisionService.signature(config); config.enabled = true; paused = false
        config.pausedByUser = false; config.snoozeUntil = nil
        persist(); reconcile(); showFloating()
    }
    func disable() { cancelWork(); finishInactivity(at: clock()); config.snoozeUntil = nil; config.enabled = false; persist(); reconcile() }
    func pause() { finishInactivity(at: clock()); setInactivityTimer(active: false); paused = true; config.pausedByUser = true; cancelWork(); status = .paused; floating?.refresh() }
    func resume() { paused = false; config.pausedByUser = false; config.snoozeUntil = nil; persist(); reconcile() }
    func showFloating() { guard clockEnabled else { return }; if floating == nil { floating = ActivityFloatingController(tracker: self) }; floating?.present() }
    func moveFloatingToCurrentScreen() {
        guard config.enabled else { return }
        showFloating(); floating?.moveToCurrentScreen()
    }
    func installFloating() {
        if clockEnabled, floating == nil { floating = ActivityFloatingController(tracker: self); floating?.refresh() }
    }
    private func cancelWork(at date: Date? = nil, reason: String = "state_changed") {
        let date = date ?? clock()
        finishRecognition(.cancelled, code: reason)
        pendingWindowID = nil; consecutiveFailures = 0
        revision = UUID(); task?.cancel(); task = nil; timer?.invalidate(); timer = nil
        isRecognizing = false; recognitionStartedAt = nil
        ledger.stop(at: date); storedDisplay = ledger.segments.max { $0.end < $1.end }
        if config.enabled { persist() }
    }
    func shutdown() { finishInactivity(at: clock()); inactivityTimer?.invalidate(); cancelWork(); testTask?.cancel() }

    private func inactivityBoundary(at date: Date, category: ActivityCategory) -> Date? {
        guard let timeout = config.inactivitySettings.timeout(for: category) else { return nil }
        let elapsed = idleSeconds()
        guard elapsed.isFinite, elapsed >= timeout else { return nil }
        return date.addingTimeInterval(-(elapsed - timeout))
    }

    private func setInactivityTimer(active: Bool) {
        if !active { inactivityTimer?.invalidate(); inactivityTimer = nil; observationStartedAt = nil; lastInactivityCheck = nil; return }
        guard clockEnabled, inactivityTimer == nil else { return }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkInactivity() }
        }
        timer.tolerance = 1; RunLoop.main.add(timer, forMode: .common); inactivityTimer = timer
    }

    func checkInactivity() {
        guard config.enabled, config.inactivitySettings.enabled, writable, !testing else { return }
        if inactiveID != nil || inactivityBoundary(at: clock(), category: ledger.current?.category ?? .unknown) != nil {
            reconcile()
        } else {
            // Ordinary polls avoid view publication, record reads/writes and model work.
            lastInactivityCheck = clock()
        }
    }

    /// Reads an OS duration counter only. No keyboard hooks, screen capture, or AI calls.
    private func updateInactivity(at date: Date, app: ForegroundContext) -> Bool {
        defer { lastInactivityCheck = date }
        if let id = inactiveID, let index = inactivityPeriods.firstIndex(where: { $0.id == id }) {
            let period = inactivityPeriods[index]
            if date.timeIntervalSince(period.observedThrough) > config.maximumObservationGap {
                finishInactivity(at: period.observedThrough)
                observationStartedAt = date
                return updateInactivity(at: date, app: app)
            }
            if config.inactivitySettings.timeout(for: period.category) == nil || inactivityBoundary(at: date, category: period.category) == nil {
                let elapsed = idleSeconds()
                let lastInput = elapsed.isFinite && elapsed >= 0 ? date.addingTimeInterval(-elapsed) : date
                finishInactivity(at: max(period.start, lastInput))
                lastFingerprint = nil; lastAttempt = nil
                return false
            }
            if date.timeIntervalSince(period.observedThrough) >= 60 {
                inactivityPeriods[index].observedThrough = date
                persistInactivity()
            }
            return true
        }
        let snapshot = (ledger.current ?? storedDisplay).flatMap { $0.bundleID == app.bundleID ? $0 : nil }
        let category = snapshot?.category ?? .unknown
        guard let boundary = inactivityBoundary(at: date, category: category) else { return false }
        let missedChecks = lastInactivityCheck.map { date.timeIntervalSince($0) > config.maximumObservationGap } ?? false
        let start = max(missedChecks ? date : (observationStartedAt ?? date), max(snapshot?.start ?? date, boundary))
        ledger.stopAtInactivityBoundary(start)
        cancelWork(at: start)
        let period = InactivityPeriod(start: start, observedThrough: date, category: category,
                                      title: snapshot?.title ?? "无操作前的活动未识别", app: app.name, bundleID: app.bundleID, resolution: .away, applied: true)
        inactivityPeriods.append(period); inactiveID = period.id
        persistInactivity()
        return true
    }

    private func finishInactivity(at date: Date) {
        guard let id = inactiveID, let index = inactivityPeriods.firstIndex(where: { $0.id == id }) else { return }
        let observed = inactivityPeriods[index].observedThrough
        let safeEnd = date.timeIntervalSince(observed) > config.maximumObservationGap ? observed : date
        inactivityPeriods[index].end = max(inactivityPeriods[index].start, safeEnd)
        inactivityPeriods[index].observedThrough = inactivityPeriods[index].end!
        inactiveID = nil
        persistInactivity()
    }

    @discardableResult private func persistInactivity() -> Bool {
        guard writable else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(inactivityPeriods).write(to: inactivityURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: inactivityURL.path)
            return true
        } catch {
            writable = false; config.enabled = false; task?.cancel(); timer?.invalidate(); inactivityTimer?.invalidate()
            status = .error("空闲时段保存失败，已停止自动记录。请检查数据目录和磁盘空间。")
            errorMessage = status.detail
            return false
        }
    }

    private func loadInactivity() throws {
        guard FileManager.default.fileExists(atPath: inactivityURL.path) else { return }
        inactivityPeriods = try JSONDecoder().decode([InactivityPeriod].self, from: Data(contentsOf: inactivityURL))
        guard Set(inactivityPeriods.map(\.id)).count == inactivityPeriods.count,
              inactivityPeriods.allSatisfy({ $0.observedThrough >= $0.start && ($0.end ?? $0.observedThrough) >= $0.start }) else { throw AutomaticError.invalidResponse }
        var changed = false
        for index in inactivityPeriods.indices where inactivityPeriods[index].end == nil {
            // A crash/restart never fills time that the previous process did not observe.
            inactivityPeriods[index].end = inactivityPeriods[index].observedThrough
            changed = true
        }
        let replay = inactivityPeriods.indices.filter { inactivityPeriods[$0].resolution == .present && inactivityPeriods[$0].applied != true }
        for index in replay { try mergeConfirmedInactivity(inactivityPeriods[index]) }
        if !replay.isEmpty {
            guard persist() else { throw AutomaticError.invalidResponse }
            for index in replay { inactivityPeriods[index].applied = true }
            changed = true
        }
        if changed, !persistInactivity() { throw AutomaticError.invalidResponse }
    }

    private func mergeConfirmedInactivity(_ period: InactivityPeriod) throws {
        for segment in period.restoredSegments {
            let file = recordsDirectory.appendingPathComponent(Self.dayKey(segment.start) + ".json")
            if FileManager.default.fileExists(atPath: file.path) {
                let saved = try JSONDecoder().decode([ActivitySegment].self, from: Data(contentsOf: file))
                let existing = Set(ledger.segments.map(\.id))
                ledger.segments += saved.filter { !existing.contains($0.id) }
            }
            if !ledger.segments.contains(where: { $0.id == segment.id }) { ledger.segments.append(segment) }
        }
    }

    private func observe() {
        let center = NSWorkspace.shared.notificationCenter
        let activate = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        observers.append((center, activate))
        for (name, reason) in [(NSWorkspace.willSleepNotification,"sleep"), (NSWorkspace.screensDidSleepNotification,"screen"), (NSWorkspace.sessionDidResignActiveNotification,"session")] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.setLifecycleBlock(reason, blocked: true) } }
            observers.append((center, token))
        }
        for (name, reason) in [(NSWorkspace.didWakeNotification,"sleep"), (NSWorkspace.screensDidWakeNotification,"screen"), (NSWorkspace.sessionDidBecomeActiveNotification,"session")] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.setLifecycleBlock(reason, blocked: false) } }
            observers.append((center, token))
        }
        let distributed = DistributedNotificationCenter.default()
        for (name, value) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            let token = distributed.addObserver(forName: NSNotification.Name(name), object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.setLifecycleBlock("lock", blocked: value) } }
            observers.append((distributed, token))
        }
    }
    func setAway(_ value: Bool) { cancelWork(); explicitlyAway = value; reconcile() }
    func setLifecycleBlock(_ reason: String, blocked: Bool) {
        if blocked { lifecycleBlocks.insert(reason) } else { lifecycleBlocks.remove(reason) }
        cancelWork(); reconcile()
    }

    func reconcile() {
        guard !testing else { return }
        let app = foreground()
        let appChanged = app != front
        let blocked: AutomaticStatus?
        if !config.enabled || !verified || config.consentSignature != VisionService.signature(config) || !writable { blocked = .off }
        else if paused { blocked = .paused }
        else if away || !sessionAvailable() { blocked = .away }
        else if !permission() { blocked = .error(AutomaticError.permission.localizedDescription) }
        else if let app, app.bundleID == Bundle.main.bundleIdentifier { blocked = .excluded("专注镜") }
        else if let app, let name = config.excludedApps[app.bundleID] { blocked = .excluded(name) }
        else if app == nil { blocked = .away }
        else { blocked = nil }
        if let blocked {
            finishInactivity(at: clock()); setInactivityTimer(active: false)
            if ledger.currentID != nil || task != nil { cancelWork() }
            status = blocked; floating?.refresh(); return
        }
        let window = app.flatMap { foregroundWindowID($0) }
        let windowChanged = !appChanged && window != frontWindow
        let changed = appChanged || windowChanged
        if observationStartedAt == nil { observationStartedAt = clock() }
        setInactivityTimer(active: config.inactivitySettings.enabled)
        if let app, updateInactivity(at: clock(), app: app) {
            guard writable else { return }
            if status != .inactive { status = .inactive; floating?.refresh() }
            return
        }
        if changed {
            cancelWork(reason: appChanged ? "app_changed" : "window_changed")
            front = app; frontWindow = window; lastFingerprint = nil
        }
        if ledger.currentID == nil, let app {
            ledger.begin(ActivityClassification(category: .unknown, title: "\(app.name) · 等待识别"), app: app.name, bundleID: app.bundleID, at: clock(), unknownReason: .waiting)
            pendingWindowID = window
            status = .waiting
        }
        if task == nil && timer == nil {
            schedule(after: config.sampleDelay(sinceLastAttempt: lastAttempt.map { clock().timeIntervalSince($0) }, appChanged: changed))
        }
        floating?.refresh()
    }

    private func schedule(after seconds: TimeInterval) {
        timer?.invalidate(); timer = nil
        guard clockEnabled, config.enabled, writable else { return }
        let timer = Timer(timeInterval: max(0.2, seconds), repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.timer = nil; self?.sample() }
        }
        timer.tolerance = min(3, max(0.1, seconds / 10)); RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }

    func sample() {
        reconcile()
        guard config.enabled, !paused, !away, inactiveID == nil, !testing, task == nil,
              permission(), sessionAvailable(), let app = foreground(), app == front,
              app.bundleID != Bundle.main.bundleIdentifier, config.excludedApps[app.bundleID] == nil,
              verified, config.consentSignature == VisionService.signature(config), writable else { return }
        timer?.invalidate(); timer = nil
        lastAttempt = clock()
        activeDiagnostic = RecognitionDiagnostic(startedAt: clock())
        let token = revision, settings = config
        let key: String?
        do { key = try Keychain.read(scope: keyScope) } catch {
            pendingWindowID = nil; consecutiveFailures += 1
            finishRecognition(.failure, code: "keychain")
            ledger.begin(ActivityClassification(category: .unknown, title: "凭据读取失败"), app: app.name, bundleID: app.bundleID, at: clock(), unknownReason: .failure)
            status = .error(error.localizedDescription); persist()
            schedule(after: config.retryDelay(failures: consecutiveFailures))
            return
        }
        isRecognizing = true; recognitionStartedAt = clock()
        if ledger.current?.category != .unknown, ledger.current != nil { status = .recording }
        else { status = .recognizing }
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.revision == token {
                    self.task = nil; self.isRecognizing = false; self.recognitionStartedAt = nil
                    // Cadence starts at capture, so inference time does not add another full interval.
                    let elapsed = self.lastAttempt.map { self.clock().timeIntervalSince($0) }
                    let delay = self.consecutiveFailures > 0 ? self.config.retryDelay(failures: self.consecutiveFailures) : max(1, self.config.sampleDelay(sinceLastAttempt: elapsed))
                    self.schedule(after: delay)
                    self.floating?.refresh()
                }
            }
            var sampledAt = self.clock()
            do {
                let frame = try await self.capture(app)
                sampledAt = frame.capturedAt
                self.reconcile()
                guard self.revision == token, self.foreground() == app, self.permission(), self.sessionAvailable(), !Task.isCancelled else { return }
                if self.lastFrameKey == frame.contextKey, self.lastFingerprint == frame.fingerprint,
                   let last = self.lastIdentified, self.clock().timeIntervalSince(last) < 600,
                   self.ledger.current?.category != .unknown {
                    self.consecutiveFailures = 0
                    self.ledger.checkpoint(at: self.clock()); self.status = .recording
                    self.finishRecognition(.unchanged); self.persist(); return
                }
                self.activeDiagnostic?.stage = .classification
                let started = self.clock()
                let result = try await self.analyze(frame.jpeg, settings, key)
                self.reconcile()
                guard self.revision == token, self.foreground() == app, self.permission(), self.sessionAvailable(), !Task.isCancelled else { return }
                self.lastRecognitionDuration = self.clock().timeIntervalSince(started)
                let classification = result
                let reason: ActivityUnknownReason? = classification.category == .unknown ? .insufficientEvidence : nil
                if self.ledger.resolveShortWait(classification, capturedAt: frame.capturedAt, sameWindow: self.pendingWindowID != nil && self.pendingWindowID == frame.windowID && self.foregroundWindowID(app) == frame.windowID) {
                    // The result only absorbs a <=5s wait observed in this same live window.
                } else if self.lastFrameKey == frame.contextKey, let current = self.ledger.current,
                   current.bundleID == app.bundleID, current.category == classification.category, current.unknownReason == reason {
                    self.ledger.checkpoint(at: frame.capturedAt)
                    if let continuing = self.ledger.current { self.ledger.describe(id: continuing.id, title: classification.title) }
                    else { self.ledger.begin(classification, app: app.name, bundleID: app.bundleID, at: frame.capturedAt, unknownReason: reason) }
                } else { self.ledger.begin(classification, app: app.name, bundleID: app.bundleID, at: frame.capturedAt, unknownReason: reason) }
                self.ledger.checkpoint(at: self.clock())
                self.pendingWindowID = nil; self.consecutiveFailures = 0
                self.lastFrameKey = frame.contextKey; self.lastFingerprint = frame.fingerprint
                self.lastIdentified = frame.capturedAt
                self.status = classification.category == .unknown ? .uncertain : .recording
                self.finishRecognition(.success, code: classification.category == .unknown ? "insufficient_evidence" : nil)
                self.persist()
            } catch {
                self.reconcile()
                guard self.revision == token, !Task.isCancelled else { return }
                self.pendingWindowID = nil; self.consecutiveFailures += 1
                self.finishRecognition(.failure, code: RecognitionDiagnostic.errorCode(error))
                self.ledger.begin(ActivityClassification(category: .unknown, title: "识别未完成，保留为未识别"), app: app.name, bundleID: app.bundleID, at: sampledAt, unknownReason: .failure)
                self.ledger.checkpoint(at: self.clock())
                self.status = .error(error.localizedDescription)
                self.lastFingerprint = nil; self.persist()
            }
        }
    }
}
