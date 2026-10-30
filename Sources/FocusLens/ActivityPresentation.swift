import Foundation

enum ActivityPresentation {
    struct DistributionItem: Identifiable {
        var category: ActivityCategory
        var reason: ActivityUnknownReason?
        var seconds: TimeInterval
        var id: String { reason?.rawValue ?? category.rawValue }
        var label: String { reason?.label ?? category.displayName }
    }
    static func distribution(_ records: [ActivitySegment]) -> [DistributionItem] {
        let known = ActivityCategory.allCases.filter { $0 != .unknown }.map { category in
            DistributionItem(category: category, seconds: records.filter { $0.category == category }.reduce(0) { $0 + $1.seconds })
        }
        let unresolved = ActivityUnknownReason.allCases.map { reason in
            DistributionItem(category: .unknown, reason: reason, seconds: records.filter { $0.unresolvedReason == reason }.reduce(0) { $0 + $1.seconds })
        }
        return (known + unresolved).filter { $0.seconds > 0 }
    }
    static func coalesced(_ records: [ActivitySegment]) -> [ActivitySegment] {
        var result: [ActivitySegment] = []
        for item in records.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, last.bundleID == item.bundleID, last.category == item.category, last.unresolvedReason == item.unresolvedReason,
               item.start.timeIntervalSince(last.end) >= 0, item.start.timeIntervalSince(last.end) <= 1 {
                result[result.count - 1].end = item.end
                result[result.count - 1].title = item.title
                result[result.count - 1].corrected = last.corrected || item.corrected
            } else { result.append(item) }
        }
        return result.reversed()
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    static func weeklyTotals(_ records: [ActivitySegment], now: Date, weekContaining: Date? = nil, calendar: Calendar = .current) -> [(date: Date, seconds: TimeInterval?)] {
        let interval = Period.week.interval(now: weekContaining ?? now, calendar: calendar)
        return (0..<7).map { offset in
            let day = calendar.date(byAdding: .day, value: offset, to: interval.start)!
            let next = calendar.date(byAdding: .day, value: 1, to: day)!
            let total = records.reduce(0.0) { $0 + max(0, min($1.end, next).timeIntervalSince(max($1.start, day))) }
            return (day, day > now ? nil : total)
        }
    }
}
