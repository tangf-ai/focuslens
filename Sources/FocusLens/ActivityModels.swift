import Foundation

enum ActivityCategory: String, Codable, CaseIterable, Identifiable {
    case reading = "阅读", writing = "写作", development = "开发", communication = "沟通"
    case video = "视频", other = "其他", unknown = "待确认"
    var id: String { rawValue }
    // Keep the original raw value readable in historical JSON and model responses.
    var displayName: String { self == .unknown ? "未识别" : rawValue }
}

struct ActivitySegment: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Date
    var end: Date
    var category: ActivityCategory
    var title: String
    var app: String
    var bundleID: String
    var corrected = false
    var unknownReason: ActivityUnknownReason?
    var seconds: TimeInterval { max(0, end.timeIntervalSince(start)) }
    var unresolvedReason: ActivityUnknownReason? {
        guard category == .unknown else { return nil }
        if let unknownReason { return unknownReason }
        // Historical titles are only used for display; saved evidence is never rewritten.
        guard !corrected else { return .legacy }
        if title == "等待识别当前活动" || title.hasSuffix(" · 活动待确认") || title.hasSuffix(" · 活动未识别") { return .waiting }
        if ["识别未完成，可补充分类", "识别未完成，保留为未识别", "识别持续不稳定，活动待确认"].contains(title) { return .failure }
        return .legacy
    }
    var categoryLabel: String { unresolvedReason?.label ?? category.displayName }
}

enum ActivityUnknownReason: String, Codable, CaseIterable, Identifiable {
    case waiting, failure, insufficientEvidence, legacy
    var id: String { rawValue }
    var label: String {
        switch self {
        case .waiting: "等待识别"
        case .failure: "识别异常"
        case .insufficientEvidence: "证据不足"
        case .legacy: "历史未识别"
        }
    }
}

struct AutomaticConfig: Codable, Equatable {
    var ai = AISettings()
    // Optional so older settings decode without a migration or a model reset.
    var workBackground: String?
    var classificationRules: String?
    var inactivity: InactivitySettings?
    var inactivitySettings: InactivitySettings {
        get { var value = inactivity ?? InactivitySettings(); value.normalize(); return value }
        set { var value = newValue; value.normalize(); inactivity = value }
    }
    static let backgroundLimit = 1000
    static let rulesLimit = 2000
    static func guidanceText(_ value: String?, limit: Int) -> String {
        String((value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }
    mutating func normalizeGuidance() {
        let background = Self.guidanceText(workBackground, limit: Self.backgroundLimit)
        let rules = Self.guidanceText(classificationRules, limit: Self.rulesLimit)
        workBackground = background.isEmpty ? nil : background
        classificationRules = rules.isEmpty ? nil : rules
    }
    var intervalMinutes = 2
    // Optional for compatibility with settings saved before second-based sampling.
    var samplingSeconds: Int?
    static let samplingIntervals = [5, 10, 15, 30, 60, 120, 180, 300]
    var intervalSeconds: Int {
        get {
            if let samplingSeconds, Self.samplingIntervals.contains(samplingSeconds) { return samplingSeconds }
            return [1,2,3,5].contains(intervalMinutes) ? intervalMinutes * 60 : 120
        }
        set {
            samplingSeconds = Self.samplingIntervals.contains(newValue) ? newValue : 120
            intervalMinutes = max(1, (samplingSeconds ?? 120) / 60)
        }
    }
    var intervalLabel: String { intervalSeconds < 60 ? "\(intervalSeconds) 秒" : "\(intervalSeconds / 60) 分钟" }
    var maximumObservationGap: TimeInterval { Double(max(180, intervalSeconds + 120)) }
    func sampleDelay(sinceLastAttempt elapsed: TimeInterval?, appChanged: Bool = false) -> TimeInterval {
        // App switches debounce briefly, without inheriting a multi-minute polling delay.
        let spacing = appChanged ? min(5, intervalSeconds) : intervalSeconds
        return max(appChanged ? 1.5 : 0.2, elapsed.map { Double(spacing) - max(0, $0) } ?? 0)
    }
    func retryDelay(failures: Int) -> TimeInterval {
        min(Double(intervalSeconds), min(60, 5 * pow(2, Double(max(0, min(4, failures - 1))))))
    }
    var reminderMinutes = 25
    var reminders = false
    var enabled = false
    var pausedByUser = false
    var snoozeUntil: Date?
    var credentialRevision = UUID().uuidString
    var verifiedSignature: String?
    var consentSignature: String?
    var excludedApps: [String: String] = [
        "com.apple.keychainaccess": "钥匙串访问", "com.1password.1password": "1Password",
        "com.agilebits.onepassword7": "1Password 7", "com.apple.systempreferences": "系统设置"
    ]
}

struct ActivityClassification: Equatable {
    var category: ActivityCategory
    var title: String
}

/// Only observed, awake intervals are extended. A restart never extends a saved segment.
struct ActivityLedger {
    var segments: [ActivitySegment] = []
    private(set) var currentID: UUID?
    var maximumGap: TimeInterval = 180
    var current: ActivitySegment? { segments.first { $0.id == currentID } }

    mutating func checkpoint(at date: Date, calendar: Calendar = .current) {
        guard let index = segments.firstIndex(where: { $0.id == currentID }) else { return }
        let previous = segments[index]
        guard date >= previous.end else { return }
        guard date.timeIntervalSince(previous.end) <= maximumGap else { currentID = nil; return }
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: previous.start))!
        if date >= midnight {
            segments[index].end = midnight
            var next = previous
            next.id = UUID(); next.start = midnight; next.end = date
            segments.append(next); currentID = next.id
        } else { segments[index].end = date }
    }

    mutating func begin(_ classification: ActivityClassification, app: String, bundleID: String, at date: Date, unknownReason: ActivityUnknownReason? = nil) {
        checkpoint(at: date)
        let reason = classification.category == .unknown ? unknownReason : nil
        if let current, current.bundleID == bundleID,
           current.category == classification.category && current.title == classification.title && current.unknownReason == reason { return }
        let segment = ActivitySegment(start: date, end: date, category: classification.category,
                                      title: classification.title, app: app, bundleID: bundleID, unknownReason: reason)
        segments.append(segment); currentID = segment.id
    }

    /// Only a fresh, same-window observation may absorb its short initial debounce.
    mutating func resolveShortWait(_ classification: ActivityClassification, capturedAt: Date, sameWindow: Bool, calendar: Calendar = .current) -> Bool {
        guard sameWindow, classification.category != .unknown,
              let index = segments.firstIndex(where: { $0.id == currentID }),
              segments[index].category == .unknown, segments[index].unknownReason == .waiting,
              !segments[index].corrected,
              capturedAt >= segments[index].start, capturedAt.timeIntervalSince(segments[index].start) <= 5,
              calendar.isDate(capturedAt, inSameDayAs: segments[index].start) else { return false }
        segments[index].category = classification.category
        segments[index].title = classification.title
        segments[index].unknownReason = nil
        checkpoint(at: capturedAt)
        return true
    }

    mutating func stop(at date: Date) { checkpoint(at: date); currentID = nil }

    mutating func stopAtInactivityBoundary(_ date: Date) {
        if let index = segments.firstIndex(where: { $0.id == currentID }) {
            segments[index].end = max(segments[index].start, min(segments[index].end, date))
        }
        stop(at: date)
    }

    mutating func describe(id: UUID, title: String) {
        guard let index = segments.firstIndex(where: { $0.id == id }), !segments[index].corrected else { return }
        segments[index].title = String(title.prefix(100))
    }

}

enum AutomaticStatus: Equatable {
    case off, paused, away, inactive, excluded(String), waiting, recognizing, recording, uncertain, error(String)
    var label: String {
        switch self {
        case .off: "自动记录未启用"
        case .paused: "记录已暂停"
        case .away: "已离开电脑"
        case .inactive: "可能已离开"
        case .excluded: "此应用不记录"
        case .waiting: "等待更新"
        case .recognizing: "识别中"
        case .recording: "自动记录中"
        case .uncertain: "当前活动未识别"
        case .error: "识别暂不可用"
        }
    }
    var detail: String {
        switch self {
        case .off: "配置视觉模型、授权并确认后开启。"
        case .paused: "暂停期间不截图、不分析、不累计。"
        case .away: "锁屏或睡眠期间不记录，回来后重新识别。"
        case .inactive: "持续无操作，已暂停累计与截图；恢复操作后自动继续，空闲时段不补记。"
        case .excluded(let name): "正在使用\(name)，离开后恢复识别。"
        case .waiting: "当前窗口等待下一次采样，尚未发送识别请求。"
        case .recognizing: "等待新结果；显示的时间为自动估算。"
        case .recording: "根据间隔采样估算，不代表实际专注程度。"
        case .uncertain: "证据不足，保留为未识别，不推测具体活动，也无需补填。"
        case .error(let message): message
        }
    }
}

enum AutomaticError: LocalizedError {
    case permission, noWindow, imageTooLarge, invalidResponse, capability, missingModel, notVerified, noConsent
    var errorDescription: String? {
        switch self {
        case .permission: "需要允许专注镜的屏幕录制权限。"
        case .noWindow: "没有可识别的前台窗口，当前时段暂不分类。"
        case .imageTooLarge: "图片未能压缩到内存预算内，已跳过本次识别。"
        case .invalidResponse: "视觉服务没有返回有效分类，当前时间保留为未识别。"
        case .capability: "图片理解测试未通过，请检查服务是否支持图片输入。"
        case .missingModel: "请先填写视觉模型的接口地址和模型名称。"
        case .notVerified: "请先通过当前配置的图片理解测试。"
        case .noConsent: "需要确认将截图发送至当前模型服务后才能开启。"
        }
    }
}
