import Foundation
import Combine
import CryptoKit

struct ActivitySummary: Codable, Identifiable {
    var id = UUID()
    var day: String
    var updatedAt: Date
    var content: String
    var model: String
    var fingerprint: String
    var evidence: [ActivitySegment]
}

struct SummaryAttempt: Codable {
    var day: String
    var slot: String
    var startedAt: Date
    var state: ReviewState
    var error: String?
}

struct SummaryArchive: Codable {
    var version = 1
    var consentSignature: String?
    var attempts: [SummaryAttempt] = []
    var reports: [ActivitySummary] = []
}

enum SummaryPolicy {
    enum Reason { case opening, scheduled }
    static func slot(at now: Date, reason: Reason, calendar: Calendar = .current) -> String? {
        if reason == .opening { return "opening" }
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return minute >= 18 * 60 + 30 ? "evening" : minute >= 12 * 60 + 30 ? "midday" : nil
    }
    static func allows(day: String, slot: String, attempts: [SummaryAttempt]) -> Bool {
        let used = attempts.filter { $0.day == day }
        return used.count < 3 && !used.contains { $0.slot == slot }
    }
    static func nextWake(after now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        return [0, 1].flatMap { offset -> [Date] in
            let day = calendar.date(byAdding: .day, value: offset, to: today)!
            return [(12, 30), (18, 30)].compactMap { calendar.date(bySettingHour: $0.0, minute: $0.1, second: 0, of: day) }
        }.filter { $0 > now }.min()!
    }
    static func fingerprint(_ records: [ActivitySegment]) throws -> String {
        // Minute resolution avoids generating again solely because a live segment gained a few seconds.
        let stable = records.sorted { $0.start < $1.start }.map { record -> ActivitySegment in
            var item = record
            item.end = max(item.start, Date(timeIntervalSince1970: floor(item.end.timeIntervalSince1970 / 60) * 60))
            return item
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(stable)).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class AutomaticSummaryController: ObservableObject {
    @Published private(set) var archive = SummaryArchive()
    @Published private(set) var isGenerating = false
    @Published private(set) var errorMessage: String?
    let stream = ReviewStreamingState()
    private let tracker: AutomaticTracker
    private let file: URL
    private let clockEnabled: Bool
    private let clock: () -> Date
    private let request: (AISettings, String?, Data, @escaping @MainActor (String) -> Void) async throws -> String
    private let keyProvider: () throws -> String?
    private var writable = true
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var observation: AnyCancellable?
    private var requestToken = UUID()
    private var activeAttempt: Int?
    private var lastPrivacy: String = ""
    private var stopped = false
    var signature: String { "automatic-summary-v1:" + VisionService.signature(tracker.config) }
    var enabled: Bool { archive.consentSignature == signature }
    var hasConsent: Bool { archive.consentSignature != nil }
    var dataReadable: Bool { writable }
    var todayReport: ActivitySummary? { archive.reports.last { $0.day == ActivityPresentation.dayKey(clock()) } }
    var latestAttempt: SummaryAttempt? { archive.attempts.last { $0.day == ActivityPresentation.dayKey(clock()) } }
    var isStale: Bool {
        guard let report = todayReport,
              let records = try? tracker.readSegments(in: Period.today.interval(now: clock())),
              let fingerprint = try? SummaryPolicy.fingerprint(records) else { return false }
        return report.fingerprint != fingerprint
    }
    private var allowed: Bool {
        guard writable, enabled, tracker.config.enabled, tracker.verified, tracker.hasPermission,
              tracker.config.consentSignature == VisionService.signature(tracker.config) else { return false }
        switch tracker.status { case .off, .paused, .away, .inactive: return false; default: return true }
    }

    init(directory: URL, tracker: AutomaticTracker, startClock: Bool = true, now: @escaping () -> Date = Date.init,
         keyProvider: (() throws -> String?)? = nil,
         request: @escaping (AISettings, String?, Data, @escaping @MainActor (String) -> Void) async throws -> String = { settings, key, body, update in
             try await AIService.stream(settings: settings, key: key, body: body, onUpdate: update)
         }) {
        self.tracker = tracker; file = directory.appendingPathComponent("automatic-summaries.json")
        clockEnabled = startClock; clock = now; self.request = request
        self.keyProvider = keyProvider ?? { try tracker.visionAPIKey() }
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                archive = try JSONDecoder().decode(SummaryArchive.self, from: Data(contentsOf: file))
                guard archive.version == 1 else { throw StoreError.unsupportedVersion }
                var changed = false
                for index in archive.attempts.indices where archive.attempts[index].state == .generating {
                    archive.attempts[index].state = .cancelled
                    archive.attempts[index].error = "上次小结因退出中断，本时段不重复请求。"
                    changed = true
                }
                if changed { _ = persist() }
            }
        } catch { writable = false; errorMessage = "小结文件读取失败，已停止自动小结写入。请先备份 automatic-summaries.json。" }
        lastPrivacy = privacyState
        if startClock {
            observation = tracker.objectWillChange.sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.reconcile() }
            }
            reconcile()
        }
    }
    deinit { timer?.invalidate(); task?.cancel() }
    private var privacyState: String { signature + ":" + String(allowed) }
    @discardableResult private func persist() -> Bool {
        guard writable else { return false }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(archive).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return true
        } catch { writable = false; errorMessage = "小结保存失败，已停止发送请求；请检查磁盘空间和文件权限。"; return false }
    }
    @discardableResult func enable(consent: Bool) -> Bool {
        guard consent, writable, tracker.config.enabled, tracker.verified,
              tracker.config.consentSignature == VisionService.signature(tracker.config) else { return false }
        archive.consentSignature = signature
        guard persist() else { archive.consentSignature = nil; return false }
        stopped = false; reconcile(); return true
    }
    func disable() {
        cancel(); archive.consentSignature = nil; _ = persist(); timer?.invalidate(); timer = nil
    }
    func reconcile() {
        guard !stopped else { return }
        let privacy = privacyState
        if privacy != lastPrivacy { cancel(); lastPrivacy = privacy }
        guard allowed else { timer?.invalidate(); timer = nil; return }
        evaluate(reason: .scheduled)
        armTimer()
    }
    func openedToday() { evaluate(reason: .opening) }
    func evaluate(reason: SummaryPolicy.Reason) {
        guard !stopped, allowed, !isGenerating,
              let slot = SummaryPolicy.slot(at: clock(), reason: reason) else { return }
        let instant = clock(), day = ActivityPresentation.dayKey(instant)
        guard SummaryPolicy.allows(day: day, slot: slot, attempts: archive.attempts) else { return }
        do {
            let records = try tracker.readSegments(in: Period.today.interval(now: instant))
            guard records.reduce(0, { $0 + $1.seconds }) >= 60 else { return }
            let fingerprint = try SummaryPolicy.fingerprint(records)
            guard todayReport?.fingerprint != fingerprint else { return }
            let body = try AIService.activityPayload(segments: ActivityPresentation.coalesced(records), interval: DateInterval(start: Calendar.current.startOfDay(for: instant), end: instant), model: tracker.config.ai.model)
            let key = try keyProvider(), settings = tracker.config.ai, approved = signature
            archive.attempts.append(SummaryAttempt(day: day, slot: slot, startedAt: instant, state: .generating))
            guard persist() else { return }
            let index = archive.attempts.count - 1, token = UUID()
            activeAttempt = index; requestToken = token; isGenerating = true; stream.text = ""; errorMessage = nil
            task = Task { [weak self] in
                guard let self else { return }
                defer {
                    if self.requestToken == token { self.isGenerating = false; self.activeAttempt = nil; self.task = nil; self.stream.text = "" }
                }
                do {
                    let content = try await self.request(settings, key, body) { [weak self] text in
                        guard let self, self.requestToken == token else { return }
                        self.stream.text = text
                    }
                    try Task.checkCancellation()
                    guard self.requestToken == token, self.signature == approved, self.allowed else { return }
                    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.emptyResponse }
                    self.archive.reports.removeAll { $0.day == day }
                    self.archive.reports.append(ActivitySummary(day: day, updatedAt: self.clock(), content: content, model: settings.model, fingerprint: fingerprint, evidence: records))
                    self.archive.attempts[index].state = .complete
                } catch {
                    guard self.requestToken == token else { return }
                    self.archive.attempts[index].state = Task.isCancelled ? .cancelled : .failed
                    self.archive.attempts[index].error = error.localizedDescription
                }
                _ = self.persist()
            }
        } catch { errorMessage = "小结未发送：\(error.localizedDescription)" }
    }
    private func armTimer() {
        timer?.invalidate(); timer = nil
        guard clockEnabled, allowed else { return }
        let timer = Timer(fire: SummaryPolicy.nextWake(after: clock()), interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcile() }
        }
        timer.tolerance = 5; RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    private func cancel() {
        requestToken = UUID(); task?.cancel(); task = nil; isGenerating = false; stream.text = ""
        if let index = activeAttempt, archive.attempts.indices.contains(index) {
            archive.attempts[index].state = .cancelled; archive.attempts[index].error = "自动小结已停止，本时段不重试。"
            _ = persist()
        }
        activeAttempt = nil
    }
    func shutdown() { stopped = true; timer?.invalidate(); timer = nil; cancel() }
    func clear() throws {
        guard writable else { throw StoreError.protectedData }
        shutdown()
        let day = ActivityPresentation.dayKey(clock())
        // Clearing personal content must not silently reset today's request ceiling.
        let used = archive.attempts.filter { $0.day == day }.map { attempt -> SummaryAttempt in
            var value = attempt; value.error = nil; return value
        }
        archive = SummaryArchive(attempts: used)
        guard persist() else { throw StoreError.protectedData }
        stopped = false
    }
}
