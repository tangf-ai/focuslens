import Foundation
import CoreGraphics

struct InactivitySettings: Codable, Equatable {
    var enabled = true
    var minutes = 5
    // Zero means continue recording without an inactivity timeout.
    var readingMinutes = 15
    var videoMinutes = 30
    static let intervals = [5, 10, 15, 20, 30, 60]
    mutating func normalize() {
        if !Self.intervals.contains(minutes) { minutes = 5 }
        if !([0] + Self.intervals).contains(readingMinutes) { readingMinutes = 15 }
        if !([0] + Self.intervals).contains(videoMinutes) { videoMinutes = 30 }
    }
    func timeout(for category: ActivityCategory) -> TimeInterval? {
        guard enabled else { return nil }
        let value = category == .reading ? readingMinutes : category == .video ? videoMinutes : minutes
        return value == 0 ? nil : TimeInterval(value * 60)
    }
}

enum SystemInactivity {
    static func seconds() -> TimeInterval {
        // Read only the session's idle duration, never keys, pointer positions or event contents.
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
    }
}

struct InactivityPeriod: Codable, Equatable, Identifiable {
    enum Resolution: String, Codable { case pending, present, away }
    var id = UUID()
    var start: Date
    var end: Date?
    var observedThrough: Date
    var category: ActivityCategory
    var title: String
    var app: String
    var bundleID: String
    var resolution: Resolution = .pending
    // Persist these IDs before writing the ledger, for idempotent crash recovery.
    var restoredSegments: [ActivitySegment] = []
    var applied: Bool?
    var seconds: TimeInterval { max(0, (end ?? observedThrough).timeIntervalSince(start)) }
    var presentLabel: String {
        switch category {
        case .reading: "刚才仍在阅读"
        case .video: "刚才仍在看视频"
        default: "刚才仍在专注"
        }
    }
    func segmentsForConfirmation() -> [ActivitySegment] {
        guard let end, end > start else { return [] }
        var result: [ActivitySegment] = [], cursor = start
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        // Files use UTC day boundaries, as does the existing automatic ledger.
        while cursor < end {
            let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: cursor))!
            let until = min(end, midnight)
            result.append(ActivitySegment(start: cursor, end: until, category: category, title: title,
                                          app: app, bundleID: bundleID, corrected: true))
            cursor = until
        }
        return result
    }
}
