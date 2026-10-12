import Foundation

enum TaskKind: String, Codable, CaseIterable, Identifiable {
    case development = "开发", writing = "写作", learning = "学习", planning = "规划", other = "其他"
    var id: String { rawValue }
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

struct Review: Codable, Identifiable {
    var id = UUID()
    var createdAt: Date
    var start: Date
    var end: Date
    var sessionIDs: [UUID]
    var content: String
    var model: String
}

struct AppData: Codable {
    var schemaVersion = 1
    var sessions: [FocusSession] = []
    var activeRun: TimerRun?
    var pendingFeedback: SessionDraft?
    var focusMinutes = 25
    var restMinutes = 5
    var aiSettings = AISettings()
    var reviews: [Review] = []
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
