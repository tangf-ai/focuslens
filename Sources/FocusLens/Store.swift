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
    @Published var isGenerating = false
    let reviewStream = ReviewStreamingState()
    var streamingText: String { reviewStream.text }
    @Published private(set) var generatingReviewID: UUID?
    @Published private(set) var generatingMessageID: UUID?
    @Published var focusMode = false
    @Published var keyAvailable = false
    @Published private(set) var hasVisibleWindow = true
    let directory: URL
    var openMainWindowAction: (() -> Void)?
    private var floatingTimer: FloatingTimerController?
    private var automaticInstance: AutomaticTracker?
    var automatic: AutomaticTracker {
        if let automaticInstance { return automaticInstance }
        let tracker = AutomaticTracker(directory: directory, startClock: clockEnabled)
        tracker.setManualBlocked(data.activeRun != nil || data.pendingFeedback != nil)
        automaticInstance = tracker
        return tracker
    }
    func reviewAPIKey() throws -> String? { try aiKeyProvider() }
    private let clockEnabled: Bool
    private var completionTimer: Timer?
    private var calendarTimer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var loadingFailed = false
    private var aiTask: Task<Void, Never>?
    private let aiKeyProvider: () throws -> String?
    private let keychainScope: String?
    private weak var fullscreenWindow: NSWindow?
    private var enteredFullscreen = false
    private var fileURL: URL { directory.appendingPathComponent("focus-data.json") }

    init(directory: URL? = nil, startClock: Bool = true, aiKeyProvider: (() throws -> String?)? = nil) {
        clockEnabled = startClock
        let scope = directory?.standardizedFileURL.path
        keychainScope = scope
        self.aiKeyProvider = aiKeyProvider ?? { try Keychain.read(scope: scope) }
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FocusLens", isDirectory: true)
        load()
        keyAvailable = (try? Keychain.read(scope: keychainScope))?.isEmpty == false
        tick()
        if startClock {
            observeLifecycle()
            armCompletionTimer()
            armCalendarTimer()
        }
    }

    deinit {
        completionTimer?.invalidate()
        calendarTimer?.invalidate()
        for (center, observer) in observers { center.removeObserver(observer) }
    }

    // Only the countdown face refreshes once a second. The store has no periodic polling.
    var hasScheduledCompletion: Bool { completionTimer?.isValid == true }

    private func armCompletionTimer() {
        completionTimer?.invalidate()
        completionTimer = nil
        guard clockEnabled, let deadline = data.activeRun?.deadline else { return }
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
                self?.armCompletionTimer()
            }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        completionTimer = timer
    }

    private func armCalendarTimer() {
        calendarTimer?.invalidate()
        guard clockEnabled,
              let midnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) else { return }
        let timer = Timer(fire: midnight.addingTimeInterval(0.1), interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshAfterLifecycleChange() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        calendarTimer = timer
    }

    private func observeLifecycle() {
        let center = NotificationCenter.default
        let termination = center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelReview(); self?.automaticInstance?.shutdown() }
        }
        observers.append((center, termination))
        for name in [NSApplication.didBecomeActiveNotification, NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     .NSSystemTimeZoneDidChange, Notification.Name("NSSystemClockDidChangeNotification")] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshAfterLifecycleChange() }
            }
            observers.append((center, observer))
        }
        let workspace = NSWorkspace.shared.notificationCenter
        let wake = workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshAfterLifecycleChange() }
        }
        observers.append((workspace, wake))
    }

    private func refreshAfterLifecycleChange() {
        if let windows = NSApp?.windows {
            let visible = windows.contains { $0.identifier != FloatingTimerController.identifier && $0.identifier != ActivityFloatingController.identifier && $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) }
            if visible != hasVisibleWindow { hasVisibleWindow = visible }
        }
        tick()
        armCompletionTimer()
        armCalendarTimer()
    }

    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let original = try Data(contentsOf: fileURL)
            var loaded = try JSONDecoder().decode(AppData.self, from: original)
            guard (1...2).contains(loaded.schemaVersion) else { throw StoreError.unsupportedVersion }
            if loaded.schemaVersion == 1 {
                let backup = directory.appendingPathComponent("focus-data-before-v2.json")
                if !FileManager.default.fileExists(atPath: backup.path) {
                    try original.write(to: backup, options: .atomic)
                }
                loaded.schemaVersion = 2
            }
            loaded.focusMinutes = min(180, max(5, loaded.focusMinutes))
            for index in loaded.reviews.indices {
                if loaded.reviews[index].state == .generating {
                    loaded.reviews[index].state = .cancelled
                    loaded.reviews[index].error = "上次生成因应用退出而中断，请重新生成。"
                }
                if var messages = loaded.reviews[index].messages {
                    for offset in messages.indices where messages[offset].state == .generating {
                        messages[offset].state = .cancelled
                        messages[offset].error = "上次回复因应用退出而中断，请重新提问。"
                    }
                    loaded.reviews[index].messages = messages
                }
            }
            data = loaded
        } catch {
            loadingFailed = true
            errorMessage = "本地记录读取或升级失败，已停止写入以保护原文件。请在设置中打开数据文件夹，备份后检查 focus-data.json。\n\(error.localizedDescription)"
        }
    }

    @discardableResult
    func persist() -> Bool {
        guard !loadingFailed else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(data).write(to: fileURL, options: .atomic)
            return true
        } catch {
            errorMessage = "记录保存失败，请检查磁盘空间或文件夹权限。\n\(error.localizedDescription)"
            return false
        }
    }

    func tick(at instant: Date = Date()) {
        now = instant
        guard let run = data.activeRun, !run.isPaused, run.remaining(at: instant) <= 0 else { return }
        finish(at: run.deadline ?? instant)
    }

    func start(goal: String, kind: TaskKind, minutes: Int, phase: RunPhase = .focus, at instant: Date = Date()) {
        guard !loadingFailed, data.activeRun == nil, data.pendingFeedback == nil else { return }
        automaticInstance?.setManualBlocked(true, at: instant)
        let cleanGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        now = instant
        data.activeRun = TimerRun(phase: phase, goal: cleanGoal, kind: kind, seconds: TimeInterval(max(phase == .focus ? 5 : 1, min(180, minutes)) * 60), now: instant)
        armCompletionTimer()
        persist()
    }

    func togglePause(at instant: Date = Date()) {
        tick(at: instant)
        guard var run = data.activeRun else { return }
        if run.isPaused { run.resume(at: instant) } else { run.pause(at: instant) }
        data.activeRun = run
        armCompletionTimer()
        persist()
    }

    func finish(at instant: Date = Date()) {
        guard let run = data.activeRun else { return }
        let endedAt = min(instant, run.deadline ?? instant)
        now = instant
        data.activeRun = nil
        armCompletionTimer()
        if run.phase == .focus { data.pendingFeedback = SessionDraft(run: run, endedAt: endedAt) }
        automaticInstance?.setManualBlocked(data.pendingFeedback != nil)
        exitFocusMode()
        persist()
    }

    func saveFeedback(outcome: Outcome, rating: Int?, note: String) {
        guard let draft = data.pendingFeedback else { return }
        let safeRating = rating.flatMap { (1...5).contains($0) ? $0 : nil }
        data.sessions.append(draft.saved(outcome: outcome, rating: safeRating, note: String(note.prefix(1000))))
        data.pendingFeedback = nil
        automaticInstance?.setManualBlocked(false)
        persist()
    }

    func deleteSession(_ id: UUID) {
        data.sessions.removeAll { $0.id == id }
        persist()
    }

    func selectKind(_ kind: TaskKind) {
        guard !loadingFailed, kind == .uncategorized || data.taskKinds.contains(kind), data.selectedKind != kind else { return }
        var updated = data
        updated.selectedKind = kind
        try? saveTagChange(updated)
    }

    @discardableResult
    func addKind(_ name: String) throws -> TaskKind {
        let kind = try validatedKind(name)
        var updated = data
        updated.taskKinds.append(kind)
        updated.selectedKind = kind
        try saveTagChange(updated)
        return kind
    }

    func renameKind(_ old: TaskKind, to name: String) throws {
        guard data.taskKinds.contains(old) else { throw TagError.missing }
        let replacement = try validatedKind(name, excluding: old)
        guard replacement != old else { return }
        var updated = data
        updated.taskKinds = updated.taskKinds.map { $0 == old ? replacement : $0 }
        if updated.selectedKind == old { updated.selectedKind = replacement }
        if updated.activeRun?.kind == old { updated.activeRun?.kind = replacement }
        if updated.pendingFeedback?.kind == old { updated.pendingFeedback?.kind = replacement }
        let changedIDs = Set(updated.sessions.filter { $0.kind == old }.map(\.id))
        for index in updated.sessions.indices where updated.sessions[index].kind == old {
            updated.sessions[index].kind = replacement
        }
        for index in updated.reviews.indices where !changedIDs.isDisjoint(with: updated.reviews[index].sessionIDs) {
            updated.reviews[index].isStale = true
        }
        try saveTagChange(updated)
    }

    func deleteKind(_ kind: TaskKind) throws {
        guard data.taskKinds.contains(kind) else { throw TagError.missing }
        var updated = data
        updated.taskKinds.removeAll { $0 == kind }
        if updated.selectedKind == kind { updated.selectedKind = .uncategorized }
        try saveTagChange(updated)
    }

    private func validatedKind(_ input: String, excluding: TaskKind? = nil) throws -> TaskKind {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 20, name.rangeOfCharacter(from: .controlCharacters) == nil else { throw TagError.invalidName }
        guard name != "无标签" else { throw TagError.reservedName }
        guard !data.taskKinds.contains(where: { $0 != excluding && $0.rawValue.compare(name, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame }) else { throw TagError.duplicate }
        return TaskKind(rawValue: name)
    }

    private func saveTagChange(_ updated: AppData) throws {
        guard !loadingFailed else { throw TagError.cannotSave }
        let previous = data
        data = updated
        guard persist() else { data = previous; throw TagError.cannotSave }
    }

    func applyCompactMainWindow() {
        guard !UserDefaults.standard.bool(forKey: "FocusLensCompactLayoutV1") else { return }
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.identifier != FloatingTimerController.identifier && $0.canBecomeMain && !$0.styleMask.contains(.fullScreen) }) else { return }
            window.setContentSize(NSSize(width: 960, height: 680))
            UserDefaults.standard.set(true, forKey: "FocusLensCompactLayoutV1")
        }
    }

    func updateDurations(focus: Int, rest: Int) {
        data.focusMinutes = min(180, max(5, focus))
        data.restMinutes = min(60, max(1, rest))
        persist()
    }

    func updateAI(settings: AISettings, newKey: String?) throws {
        _ = try AIService.endpoint(settings.baseURL)
        if let key = newKey {
            if key.isEmpty { try Keychain.delete(scope: keychainScope) } else { try Keychain.save(key, scope: keychainScope) }
        }
        data.aiSettings = settings
        keyAvailable = (try? Keychain.read(scope: keychainScope))?.isEmpty == false
        persist()
    }

    func deleteAIKey() throws {
        try Keychain.delete(scope: keychainScope)
        keyAvailable = false
    }

    func setFocusMode(_ enabled: Bool) {
        if enabled {
            guard data.activeRun != nil else { return }
            focusMode = true
            fullscreenWindow = NSApp.keyWindow
            if let window = fullscreenWindow, !window.styleMask.contains(.fullScreen) {
                enteredFullscreen = true
                window.toggleFullScreen(nil)
            }
        } else { exitFocusMode() }
    }

    func exitFocusMode() {
        focusMode = false
        if enteredFullscreen, let window = fullscreenWindow, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        enteredFullscreen = false
        fullscreenWindow = nil
    }

    func stats(_ period: Period) -> FocusStats {
        FocusStats(sessions: sessionsIn(data.sessions, interval: period.interval(now: now)))
    }

    @discardableResult
    func generateReview(period: Period) -> UUID? {
        guard !isGenerating, !loadingFailed else { return nil }
        let interval = period.interval(now: now)
        let sessions = sessionsIn(data.sessions, interval: interval)
        guard !sessions.isEmpty else { errorMessage = "这个时间范围还没有专注记录。完成一轮并保存反馈后再生成复盘。"; return nil }
        let settings = data.aiSettings
        guard !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "请先在设置中填写 AI 模型名称和接口地址。"; return nil
        }
        do {
            let body = try AIService.payload(sessions: sessions, interval: interval, model: settings.model, stream: true)
            let key = try aiKeyProvider()
            let review = Review(createdAt: Date(), start: interval.start, end: interval.end,
                sessionIDs: sessions.map(\.id), content: "", model: settings.model, evidence: sessions,
                messages: [], state: .generating)
            data.reviews.insert(review, at: 0)
            data.reviews = Array(data.reviews.prefix(50))
            guard persist() else {
                data.reviews[0].state = .failed
                data.reviews[0].error = "复盘无法保存，请检查本地数据目录后重试。"
                return nil
            }
            beginReviewRequest(reviewID: review.id, messageID: nil, body: body, settings: settings, key: key)
            return review.id
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    var activityReviewSettings: AISettings { data.aiSettings.model.isEmpty ? automatic.config.ai : data.aiSettings }
    @discardableResult
    func generateActivityReview(period: Period) -> UUID? {
        guard !isGenerating, !loadingFailed else { return nil }
        let interval = period.interval(now: Date()), segments = automatic.segments(in: period.interval(now: Date()))
        guard !segments.isEmpty else { errorMessage = "所选范围还没有自动活动记录。"; return nil }
        let settings = activityReviewSettings
        do {
            guard !settings.model.isEmpty else { throw AutomaticError.missingModel }
            let body = try AIService.activityPayload(segments: segments, interval: interval, model: settings.model)
            let key = try data.aiSettings.model.isEmpty ? automatic.visionAPIKey() : aiKeyProvider()
            let review = Review(createdAt: Date(), start: interval.start, end: interval.end, sessionIDs: segments.map(\.id),
                                content: "", model: settings.model, activityEvidence: segments, messages: [], state: .generating)
            data.reviews.insert(review, at: 0); data.reviews = Array(data.reviews.prefix(50))
            guard persist() else { data.reviews[0].state = .failed; data.reviews[0].error = "无法保存复盘，未发送请求。"; return nil }
            beginReviewRequest(reviewID: review.id, messageID: nil, body: body, settings: settings, key: key)
            return review.id
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    @discardableResult
    func sendReviewQuestion(reviewID: UUID, question: String) -> Bool {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isGenerating, !loadingFailed, !question.isEmpty,
              let index = data.reviews.firstIndex(where: { $0.id == reviewID }), data.reviews[index].canContinue else { return false }
        let automaticReview = data.reviews[index].activityEvidence != nil
        let settings = automaticReview ? activityReviewSettings : data.aiSettings
        guard !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "请先在设置中填写 AI 模型名称和接口地址。"; return false
        }
        do {
            let body = try AIService.conversationPayload(review: data.reviews[index], question: question, model: settings.model)
            let key = try automaticReview && data.aiSettings.model.isEmpty ? automatic.visionAPIKey() : aiKeyProvider()
            let assistant = ReviewMessage(role: .assistant, content: "", state: .generating, model: settings.model)
            var messages = data.reviews[index].messages ?? []
            messages.append(ReviewMessage(role: .user, content: question))
            messages.append(assistant)
            data.reviews[index].messages = messages
            guard persist() else {
                data.reviews[index].messages?[messages.count - 1].state = .failed
                data.reviews[index].messages?[messages.count - 1].error = "对话无法保存，请检查本地数据目录后重试。"
                return false
            }
            beginReviewRequest(reviewID: reviewID, messageID: assistant.id, body: body, settings: settings, key: key)
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    private func beginReviewRequest(reviewID: UUID, messageID: UUID?, body: Data, settings: AISettings, key: String?) {
        isGenerating = true
        reviewStream.text = ""
        generatingReviewID = reviewID
        generatingMessageID = messageID
        aiTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isGenerating = false
                self.generatingReviewID = nil
                self.generatingMessageID = nil
                self.reviewStream.text = ""
                self.aiTask = nil
            }
            var state: ReviewState = .complete
            var failure: String?
            do {
                let content = try await AIService.stream(settings: settings, key: key, body: body) { [weak self] text in
                    self?.reviewStream.text = text
                }
                try Task.checkCancellation()
                self.reviewStream.text = content
            } catch is CancellationError { state = .cancelled
            } catch let error as URLError where error.code == .cancelled {
                state = .cancelled
            } catch { state = .failed; failure = error.localizedDescription }
            guard let index = self.data.reviews.firstIndex(where: { $0.id == reviewID }) else { return }
            if let messageID, let offset = self.data.reviews[index].messages?.firstIndex(where: { $0.id == messageID }) {
                self.data.reviews[index].messages?[offset].content = self.streamingText
                self.data.reviews[index].messages?[offset].state = state
                self.data.reviews[index].messages?[offset].error = failure
            } else if messageID == nil {
                self.data.reviews[index].content = self.streamingText
                self.data.reviews[index].state = state
                self.data.reviews[index].error = failure
                if let evidence = self.data.reviews[index].evidence {
                    let interval = DateInterval(start: self.data.reviews[index].start, end: self.data.reviews[index].end)
                    self.data.reviews[index].isStale = sessionsIn(self.data.sessions, interval: interval) != evidence
                }
            }
            self.persist()
        }
    }

    func cancelReview() {
        aiTask?.cancel()
        // Save synchronously as well, so quitting the app preserves the visible partial reply.
        guard isGenerating, let id = generatingReviewID, let index = data.reviews.firstIndex(where: { $0.id == id }) else { return }
        if let messageID = generatingMessageID, let offset = data.reviews[index].messages?.firstIndex(where: { $0.id == messageID }) {
            data.reviews[index].messages?[offset].content = streamingText
            data.reviews[index].messages?[offset].state = .cancelled
        } else if generatingMessageID == nil {
            data.reviews[index].content = streamingText
            data.reviews[index].state = .cancelled
        }
        persist()
    }

    func enableFloatingTimer() {
        guard clockEnabled, floatingTimer == nil else { return }
        floatingTimer = FloatingTimerController(store: self)
    }

    func showFloatingTimer() {
        enableFloatingTimer()
        floatingTimer?.present()
    }

    func moveFloatingTimerToCurrentScreen() {
        enableFloatingTimer()
        floatingTimer?.moveToCurrentScreen()
    }

    func restoreMainWindow() {
        let window = NSApp.windows.first { $0.identifier != FloatingTimerController.identifier && $0.canBecomeMain }
        if let window {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        } else { openMainWindowAction?() }
        NSApp.activate()
    }

    func exportSessions() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "专注记录-\(Date().formatted(.iso8601.year().month().day())) .json".replacingOccurrences(of: " .", with: ".")
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(data.sessions).write(to: url, options: .atomic)
        } catch { errorMessage = "导出失败：\(error.localizedDescription)" }
    }

    func openDataDirectory() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
        } catch { errorMessage = error.localizedDescription }
    }
}

enum StoreError: LocalizedError {
    case unsupportedVersion
    var errorDescription: String? { "此数据由更高版本创建，请使用匹配版本打开。" }
}

enum TagError: LocalizedError {
    case invalidName, duplicate, reservedName, missing, cannotSave
    var errorDescription: String? {
        switch self {
        case .invalidName: "标签名称需要 1–20 个字符，且不能包含换行。"
        case .duplicate: "已存在同名标签，请换一个名称。"
        case .reservedName: "“无标签”是默认选项，请使用其他名称。"
        case .missing: "这个标签已不存在，请重新选择。"
        case .cannotSave: "标签未能保存，请先处理本地记录文件的保存问题。"
        }
    }
}
