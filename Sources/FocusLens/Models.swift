import Foundation

struct TaskKind: RawRepresentable, Codable, CaseIterable, Identifiable, Hashable {
    var rawValue: String
    var id: String { rawValue }
    var displayName: String { rawValue.isEmpty ? "无标签" : rawValue }
    init(rawValue: String) { self.rawValue = rawValue }
    static let development = TaskKind(rawValue: "开发")
    static let writing = TaskKind(rawValue: "写作")
    static let learning = TaskKind(rawValue: "学习")
    static let planning = TaskKind(rawValue: "规划")
    static let other = TaskKind(rawValue: "其他")
    static let uncategorized = TaskKind(rawValue: "")
    static let allCases: [TaskKind] = [.development, .writing, .learning, .planning, .other]
    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum Outcome: String, Codable, CaseIterable, Identifiable {
    case completed = "完成", partial = "部分完成", unfinished = "未完成"
    var id: String { rawValue }
}

enum RunPhase: String, Codable { case focus, rest }

struct FocusSession: Codable, Identifiable, Equatable {
    var id = UUID()
    var goal: String
    var kind: TaskKind
    var startedAt: Date
    var endedAt: Date
    var focusSeconds: TimeInterval
    var plannedSeconds: TimeInterval
    var interruptions: Int
    var outcome: Outcome
    var rating: Int?
    var note: String
}

struct TimerRun: Codable, Equatable {
    var id = UUID()
    var phase: RunPhase
    var goal: String
    var kind: TaskKind
    var startedAt: Date
    var plannedSeconds: TimeInterval
    var accumulatedSeconds: TimeInterval = 0
    var resumedAt: Date?
    var interruptions = 0

    init(phase: RunPhase, goal: String, kind: TaskKind, seconds: TimeInterval, now: Date) {
        self.phase = phase
        self.goal = goal
        self.kind = kind
        self.startedAt = now
        self.plannedSeconds = max(1, seconds)
        self.resumedAt = now
    }

    func elapsed(at now: Date) -> TimeInterval {
        min(plannedSeconds, max(0, accumulatedSeconds + (resumedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0)))
    }
    func remaining(at now: Date) -> TimeInterval { max(0, plannedSeconds - elapsed(at: now)) }
    var isPaused: Bool { resumedAt == nil }
    var deadline: Date? { resumedAt?.addingTimeInterval(max(0, plannedSeconds - accumulatedSeconds)) }

    mutating func pause(at now: Date) {
        guard resumedAt != nil else { return }
        accumulatedSeconds = elapsed(at: now)
        resumedAt = nil
        if phase == .focus && accumulatedSeconds < plannedSeconds { interruptions += 1 }
    }
    mutating func resume(at now: Date) {
        guard isPaused && accumulatedSeconds < plannedSeconds else { return }
        resumedAt = now
    }
}

struct SessionDraft: Codable, Identifiable {
    var id: UUID
    var goal: String
    var kind: TaskKind
    var startedAt: Date
    var endedAt: Date
    var focusSeconds: TimeInterval
    var plannedSeconds: TimeInterval
    var interruptions: Int

    init(run: TimerRun, endedAt: Date) {
        id = run.id
        goal = run.goal
        kind = run.kind
        startedAt = run.startedAt
        self.endedAt = endedAt
        focusSeconds = run.elapsed(at: endedAt)
        plannedSeconds = run.plannedSeconds
        interruptions = run.interruptions
    }
    func saved(outcome: Outcome, rating: Int?, note: String) -> FocusSession {
        FocusSession(id: id, goal: goal, kind: kind, startedAt: startedAt, endedAt: endedAt,
                     focusSeconds: focusSeconds, plannedSeconds: plannedSeconds,
                     interruptions: interruptions, outcome: outcome, rating: rating, note: note)
    }
}

struct AISettings: Codable, Equatable {
    var baseURL = "https://api.openai.com/v1"
    var model = ""
}

enum ReviewState: String, Codable { case generating, complete, cancelled, failed }

struct ReviewMessage: Codable, Identifiable {
    enum Role: String, Codable { case user, assistant }
    var id = UUID()
    var role: Role
    var content: String
    var state: ReviewState = .complete
    var error: String? = nil
    var model: String? = nil
}

struct Review: Codable, Identifiable {
    var id = UUID()
    var createdAt: Date
    var start: Date
    var end: Date
    var sessionIDs: [UUID]
    var content: String
    var model: String
    var isStale: Bool? = nil
    // Optional fields keep earlier review archives readable without a data migration.
    var evidence: [FocusSession]? = nil
    var activityEvidence: [ActivitySegment]? = nil
    var messages: [ReviewMessage]? = nil
    var state: ReviewState? = nil
    var error: String? = nil

    var canContinue: Bool { (state == nil || state == .complete) && !content.isEmpty }
    var transcript: String {
        func marker(_ state: ReviewState?, _ error: String?) -> String {
            guard let state, state != .complete else { return "" }
            return "\n（未完成：\(error ?? (state == .generating ? "正在生成" : "已停止"))）"
        }
        return ([content + marker(state, error)] + (messages ?? []).map {
            "\($0.role == .user ? "我" : "AI")：\n\($0.content)" + marker($0.state, $0.error)
        }).joined(separator: "\n\n")
    }
}

struct AppData: Codable {
    var schemaVersion = 2
    var sessions: [FocusSession] = []
    var activeRun: TimerRun?
    var pendingFeedback: SessionDraft?
    var focusMinutes = 25
    var restMinutes = 5
    var aiSettings = AISettings()
    var reviews: [Review] = []
    var taskKinds = TaskKind.allCases
    var selectedKind: TaskKind = .development

    init() { }
    enum CodingKeys: String, CodingKey {
        case schemaVersion, sessions, activeRun, pendingFeedback, focusMinutes, restMinutes, aiSettings, reviews, taskKinds, selectedKind
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        sessions = try values.decodeIfPresent([FocusSession].self, forKey: .sessions) ?? []
        activeRun = try values.decodeIfPresent(TimerRun.self, forKey: .activeRun)
        pendingFeedback = try values.decodeIfPresent(SessionDraft.self, forKey: .pendingFeedback)
        focusMinutes = try values.decodeIfPresent(Int.self, forKey: .focusMinutes) ?? 25
        restMinutes = try values.decodeIfPresent(Int.self, forKey: .restMinutes) ?? 5
        aiSettings = try values.decodeIfPresent(AISettings.self, forKey: .aiSettings) ?? AISettings()
        reviews = try values.decodeIfPresent([Review].self, forKey: .reviews) ?? []
        taskKinds = try values.decodeIfPresent([TaskKind].self, forKey: .taskKinds) ?? TaskKind.allCases
        let saved = try values.decodeIfPresent(TaskKind.self, forKey: .selectedKind) ?? .development
        selectedKind = taskKinds.contains(saved) ? saved : .uncategorized
    }
}

struct FocusStats {
    let sessions: [FocusSession]
    var totalSeconds: TimeInterval { sessions.reduce(0) { $0 + $1.focusSeconds } }
    var completed: Int { sessions.filter { $0.outcome == .completed }.count }
    var completionRate: Double? { sessions.isEmpty ? nil : Double(completed) / Double(sessions.count) }
    var interruptions: Int { sessions.reduce(0) { $0 + $1.interruptions } }
    var averageRating: Double? {
        let ratings = sessions.compactMap(\.rating)
        return ratings.isEmpty ? nil : Double(ratings.reduce(0, +)) / Double(ratings.count)
    }
    var ratedCount: Int { sessions.compactMap(\.rating).count }
    var days: Int { Set(sessions.map { Calendar.current.startOfDay(for: $0.startedAt) }).count }
}

enum Period: String, CaseIterable, Identifiable {
    case today = "今天", week = "本周"
    var id: String { rawValue }
    func interval(now: Date = Date(), calendar: Calendar = .current) -> DateInterval {
        var cal = calendar
        cal.firstWeekday = 2
        cal.minimumDaysInFirstWeek = 4
        let component: Calendar.Component = self == .today ? .day : .weekOfYear
        return cal.dateInterval(of: component, for: now)!
    }
}

func sessionsIn(_ sessions: [FocusSession], interval: DateInterval) -> [FocusSession] {
    sessions.filter { $0.startedAt >= interval.start && $0.startedAt < interval.end }
}

func durationText(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    if total < 60 { return "\(total) 秒" }
    let minutes = total / 60
    return minutes < 60 ? "\(minutes) 分钟" : "\(minutes / 60) 小时 \(minutes % 60) 分钟"
}

func clockText(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(ceil(seconds)))
    return String(format: "%02d:%02d", total / 60, total % 60)
}

func goalDisplayText(_ goal: String) -> String {
    goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未填写目标" : goal
}
