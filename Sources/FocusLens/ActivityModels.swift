import Foundation

enum ActivityCategory: String, Codable, CaseIterable, Identifiable {
    case reading = "阅读", writing = "写作", development = "开发", communication = "沟通"
    case video = "视频", other = "其他", unknown = "待确认"
    var id: String { rawValue }
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
    var seconds: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

struct AutomaticConfig: Codable, Equatable {
    var ai = AISettings()
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
    var reminderMinutes = 25
    var reminders = true
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

    mutating func begin(_ classification: ActivityClassification, app: String, bundleID: String, at date: Date) {
        checkpoint(at: date)
        if let current, current.bundleID == bundleID,
           current.category == classification.category && current.title == classification.title { return }
        let segment = ActivitySegment(start: date, end: date, category: classification.category,
                                      title: classification.title, app: app, bundleID: bundleID)
        segments.append(segment); currentID = segment.id
    }

    mutating func stop(at date: Date) { checkpoint(at: date); currentID = nil }

    mutating func correct(id: UUID, category: ActivityCategory, title: String) {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[index].category = category
        segments[index].title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        segments[index].corrected = true
    }
    mutating func describe(id: UUID, title: String) {
        guard let index = segments.firstIndex(where: { $0.id == id }), !segments[index].corrected else { return }
        segments[index].title = String(title.prefix(100))
    }
    mutating func restoreClassification(_ previous: ActivitySegment) {
        guard let index = segments.firstIndex(where: { $0.id == previous.id }) else { return }
        segments[index].category = previous.category; segments[index].title = previous.title; segments[index].corrected = previous.corrected
    }
}

enum AutomaticStatus: Equatable {
    case off, paused, away, manual, excluded(String), waiting, recognizing, recording, uncertain, error(String), resting(Date)
    var label: String {
        switch self {
        case .off: "自动记录未启用"
        case .paused: "记录已暂停"
        case .away: "已离开电脑"
        case .manual: "手动计时期间暂挂"
        case .excluded: "此应用不记录"
        case .waiting: "等待更新"
        case .recognizing: "识别中"
        case .recording: "自动记录中"
        case .uncertain: "活动待确认"
        case .error: "识别暂不可用"
        case .resting: "休息中"
        }
    }
    var detail: String {
        switch self {
        case .off: "配置视觉模型、授权并确认后开启。"
        case .paused: "暂停期间不截图、不分析、不累计。"
        case .away: "锁屏或睡眠期间不记录，回来后重新识别。"
        case .manual: "保留手动计时，避免重复记录。"
        case .excluded(let name): "正在使用\(name)，离开后恢复识别。"
        case .waiting: "当前窗口等待下一次采样，尚未发送识别请求。"
        case .recognizing: "等待新结果；显示的时间为自动估算。"
        case .recording: "根据间隔采样估算，不代表实际专注程度。"
        case .uncertain: "先保留时间，可以手动修正分类。"
        case .error(let message): message
        case .resting: "休息结束后恢复识别，也可提前恢复。"
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
        case .invalidResponse: "视觉服务没有返回有效分类，当前时间保留为待确认。"
        case .capability: "图片理解测试未通过，请检查服务是否支持图片输入。"
        case .missingModel: "请先填写视觉模型的接口地址和模型名称。"
        case .notVerified: "请先通过当前配置的图片理解测试。"
        case .noConsent: "需要确认将截图发送至当前模型服务后才能开启。"
        }
    }
}
