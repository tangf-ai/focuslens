import Foundation

@MainActor private final class SummaryFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("summary-" + UUID().uuidString)
    var now: Date
    var records: [ActivitySegment] = []
    var calls = 0
    var fail = false
    var delayed = false
    var tracker: AutomaticTracker!
    var summary: AutomaticSummaryController!
    init() throws {
        now = Calendar.current.date(bySettingHour: 11, minute: 0, second: 0, of: Date())!
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("automatic-activities"), withIntermediateDirectories: true)
        var config = AutomaticConfig(); config.ai = AISettings(baseURL: "http://127.0.0.1:9/v1", model: "summary-fixture")
        config.enabled = true; config.verifiedSignature = VisionService.signature(config); config.consentSignature = config.verifiedSignature
        try JSONEncoder().encode(config).write(to: directory.appendingPathComponent("automatic-settings.json"))
        try addRecord()
        tracker = AutomaticTracker(directory: directory, startClock: false, idleSeconds: { 0 }, now: { [unowned self] in self.now }, permission: { true }, sessionAvailable: { true }, foreground: { ForegroundContext(pid: 4, bundleID: "fake.editor", name: "示例编辑器") })
        tracker.reconcile()
        summary = AutomaticSummaryController(directory: directory, tracker: tracker, startClock: false, now: { [unowned self] in self.now }, keyProvider: { nil }, request: { [unowned self] settings, _, body, update in
            self.calls += 1
            let raw = String(decoding: body, as: UTF8.self)
            XCTAssertFalse(raw.contains("image_url")); XCTAssertFalse(raw.contains("fake.editor"))
            XCTAssertEqual(settings.model, "summary-fixture")
            update("部分文字")
            if self.delayed { try? await Task.sleep(for: .milliseconds(100)) }
            if self.fail { throw AIError.http(503) }
            return "仅依据文字记录的示例小结"
        })
    }
    func addRecord() throws {
        let start = now.addingTimeInterval(-Double(300 + records.count * 600))
        records.append(ActivitySegment(start: start, end: start.addingTimeInterval(120), category: .development, title: "示例活动 \(records.count)", app: "示例编辑器", bundleID: "fake.editor"))
        let formatter = DateFormatter(); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
        let groups = Dictionary(grouping: records, by: { formatter.string(from: $0.start) })
        for (day, items) in groups { try JSONEncoder().encode(items).write(to: directory.appendingPathComponent("automatic-activities/" + day + ".json")) }
    }
    func wait() async throws { for _ in 0..<50 { if !summary.isGenerating { return }; try await Task.sleep(for: .milliseconds(10)) }; XCTAssertFalse(summary.isGenerating) }
    func close() { summary.shutdown(); tracker.shutdown(); try? FileManager.default.removeItem(at: directory) }
}

extension FocusLensTests {
    @MainActor func testAutomaticOnlyMigrationFreezesAndArchivesWithoutInventingFeedback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("migration-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var original = AppData(); original.schemaVersion = 2
        original.activeRun = TimerRun(phase: .focus, goal: "旧任务", kind: .writing, seconds: 1500, now: Date().addingTimeInterval(-120))
        original.pendingFeedback = SessionDraft(run: original.activeRun!, endedAt: Date().addingTimeInterval(-60))
        original.sessions = [FocusSession(goal: "原记录", kind: .development, startedAt: origin, endedAt: origin.addingTimeInterval(100), focusSeconds: 100, plannedSeconds: 1500, interruptions: 0, outcome: .partial, rating: 4, note: "原备注")]
        let bytes = try JSONEncoder().encode(original)
        try bytes.write(to: directory.appendingPathComponent("focus-data.json"))
        let privateConfig = Data("original-config".utf8)
        try privateConfig.write(to: directory.appendingPathComponent("automatic-settings.json"))
        let store = FocusStore(directory: directory, startClock: false)
        XCTAssertNil(store.errorMessage); XCTAssertNil(store.data.activeRun); XCTAssertNil(store.data.pendingFeedback)
        XCTAssertEqual(store.data.sessions, original.sessions)
        let archive = try XCTUnwrap(store.data.legacyTransition)
        XCTAssertEqual(archive.activeRun?.goal, "旧任务"); XCTAssertEqual(archive.activeRun?.isPaused, true)
        XCTAssertEqual(archive.activeRun?.interruptions, 0)
        XCTAssertEqual(archive.activeRun?.elapsed(at: Date().addingTimeInterval(9000)) ?? 0, 120, accuracy: 5)
        XCTAssertEqual(archive.pendingFeedback?.id, original.pendingFeedback?.id)
        let backup = directory.appendingPathComponent("backups/" + archive.backupFolder)
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("focus-data.json")), bytes)
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("automatic-settings.json")), privateConfig)
        let reopened = FocusStore(directory: directory, startClock: false)
        XCTAssertEqual(reopened.data.legacyTransition?.migratedAt, archive.migratedAt)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("backups").path).count, 1)
    }

    @MainActor func testFutureSchemaIsProtectedAndExportFailsClosed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("future-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var future = AppData(); future.schemaVersion = 99
        let bytes = try JSONEncoder().encode(future)
        let file = directory.appendingPathComponent("focus-data.json"); try bytes.write(to: file)
        let store = FocusStore(directory: directory, startClock: false)
        XCTAssertNotNil(store.errorMessage); XCTAssertFalse(store.persist()); XCTAssertThrowsError(try store.exportBundle())
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    @MainActor func testMigrationAlsoBacksUpAutomaticOnlyInstallations() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("auto-migration-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = try JSONEncoder().encode(AutomaticConfig())
        try config.write(to: directory.appendingPathComponent("automatic-settings.json"))
        let store = FocusStore(directory: directory, startClock: false)
        let transition = try XCTUnwrap(store.data.legacyTransition)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("backups/" + transition.backupFolder + "/automatic-settings.json")), config)
        XCTAssertNil(transition.activeRun); XCTAssertNil(transition.pendingFeedback)
        XCTAssertEqual(store.data.schemaVersion, 3)
    }

    func testActivityDisplayMergesOnlyContinuousSameApplicationAndCategory() {
        let first = ActivitySegment(start: origin, end: origin.addingTimeInterval(60), category: .reading, title: "第一页", app: "浏览器", bundleID: "browser")
        var next = first; next.id = UUID(); next.start = first.end; next.end = next.start.addingTimeInterval(60); next.title = "第二页"
        var gap = next; gap.id = UUID(); gap.start = next.end.addingTimeInterval(300); gap.end = gap.start.addingTimeInterval(60)
        let source = [first, next, gap]
        let grouped = ActivityPresentation.coalesced(source)
        XCTAssertEqual(grouped.count, 2); XCTAssertEqual(grouped.last?.seconds, 120); XCTAssertEqual(grouped.last?.title, "第二页")
        XCTAssertEqual(source[0].seconds, 60)
        var other = next; other.bundleID = "other"
        XCTAssertEqual(ActivityPresentation.coalesced([first, other]).count, 2)
        XCTAssertEqual(ActivityCategory.unknown.rawValue, "待确认"); XCTAssertEqual(ActivityCategory.unknown.displayName, "未识别")
    }

    func testAutomaticWeeklyTotalsExcludeFutureAndSplitMidnight() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 12))!
        let midnight = cal.startOfDay(for: now)
        let item = ActivitySegment(start: midnight.addingTimeInterval(-60), end: midnight.addingTimeInterval(120), category: .reading, title: "跨日", app: "阅读器", bundleID: "reader")
        let days = ActivityPresentation.weeklyTotals([item], now: now, calendar: cal)
        XCTAssertEqual(days[0].seconds, 60); XCTAssertEqual(days[1].seconds, 120)
        XCTAssertTrue(days.dropFirst(2).allSatisfy { $0.seconds == nil })
    }

    func testSummaryPolicyCapsSlotsAndSkipsMissedSchedules() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 20))!
        XCTAssertEqual(SummaryPolicy.slot(at: now, reason: .scheduled, calendar: cal), "evening")
        let tomorrow = SummaryPolicy.nextWake(after: now, calendar: cal)
        XCTAssertEqual(cal.component(.day, from: tomorrow), 28); XCTAssertEqual(cal.component(.hour, from: tomorrow), 12)
        let attempts = ["opening", "midday", "evening"].map { SummaryAttempt(day: "2026-10-27", slot: $0, startedAt: now, state: .failed) }
        XCTAssertFalse(SummaryPolicy.allows(day: "2026-10-27", slot: "new", attempts: attempts))
        XCTAssertTrue(SummaryPolicy.allows(day: "2026-10-28", slot: "opening", attempts: attempts))
    }

    @MainActor func testSummaryNeedsIndependentConsentAndChangedEvidence() async throws {
        let f = try SummaryFixture(); defer { f.close() }
        f.summary.openedToday(); f.summary.reconcile(); XCTAssertEqual(f.calls, 0)
        XCTAssertFalse(f.summary.enable(consent: false))
        XCTAssertTrue(f.summary.enable(consent: true)); f.summary.openedToday(); try await f.wait()
        XCTAssertEqual(f.calls, 1); XCTAssertNotNil(f.summary.todayReport)
        f.summary.openedToday(); try await f.wait(); XCTAssertEqual(f.calls, 1)
        f.now = Calendar.current.date(bySettingHour: 13, minute: 0, second: 0, of: f.now)!
        f.summary.evaluate(reason: .scheduled); try await f.wait(); XCTAssertEqual(f.calls, 1)
        try f.addRecord(); f.summary.evaluate(reason: .scheduled); try await f.wait(); XCTAssertEqual(f.calls, 2)
        f.now = Calendar.current.date(bySettingHour: 19, minute: 0, second: 0, of: f.now)!
        try f.addRecord(); f.summary.evaluate(reason: .scheduled); try await f.wait(); XCTAssertEqual(f.calls, 3)
        try f.addRecord(); f.summary.openedToday(); f.summary.reconcile(); try await f.wait(); XCTAssertEqual(f.calls, 3)
        XCTAssertEqual(f.summary.archive.attempts.count, 3)
        try f.summary.clear()
        XCTAssertTrue(f.summary.archive.reports.isEmpty); XCTAssertFalse(f.summary.enabled)
        XCTAssertEqual(f.summary.archive.attempts.count, 3)
        XCTAssertTrue(f.summary.enable(consent: true)); f.summary.openedToday(); try await f.wait()
        XCTAssertEqual(f.calls, 3)
    }

    @MainActor func testSummaryFailureKeepsOldReportAndBudgetSurvivesRestart() async throws {
        let f = try SummaryFixture(); defer { f.close() }
        XCTAssertTrue(f.summary.enable(consent: true)); f.summary.openedToday(); try await f.wait()
        let original = try XCTUnwrap(f.summary.todayReport)
        f.now = Calendar.current.date(bySettingHour: 13, minute: 0, second: 0, of: f.now)!
        try f.addRecord(); f.fail = true; f.summary.reconcile(); try await f.wait()
        XCTAssertEqual(f.summary.latestAttempt?.state, .failed)
        XCTAssertEqual(f.summary.todayReport?.id, original.id)
        f.summary.reconcile(); try await f.wait(); XCTAssertEqual(f.calls, 2)
        let restored = AutomaticSummaryController(directory: f.directory, tracker: f.tracker, startClock: false, now: { f.now }, keyProvider: { nil }, request: { _, _, _, _ in XCTAssertTrue(false); return "不应请求" })
        restored.reconcile(); restored.openedToday()
        XCTAssertFalse(restored.isGenerating); XCTAssertEqual(restored.archive.attempts.count, 2)
        XCTAssertEqual(restored.todayReport?.content, original.content)
    }

    @MainActor func testSummaryCancellationAndServiceChangeNeverAcceptLateResults() async throws {
        let f = try SummaryFixture(); defer { f.close() }
        f.delayed = true
        XCTAssertTrue(f.summary.enable(consent: true)); f.summary.openedToday()
        try await Task.sleep(for: .milliseconds(20)); f.summary.disable()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(f.summary.enabled); XCTAssertNil(f.summary.todayReport)
        XCTAssertEqual(f.summary.latestAttempt?.state, .cancelled)
        XCTAssertTrue(f.summary.enable(consent: true))
        var config = f.tracker.config; config.ai.model = "different-service"
        XCTAssertTrue(f.tracker.saveConfig(config, newKey: nil)); f.summary.reconcile()
        XCTAssertFalse(f.summary.enabled); XCTAssertFalse(f.summary.enable(consent: true))
        XCTAssertEqual(f.calls, 1)
    }

    @MainActor func testSummaryCorruptAndUnwritableFilesNeverSend() async throws {
        let f = try SummaryFixture(); defer { f.close() }
        let file = f.directory.appendingPathComponent("automatic-summaries.json")
        let bytes = Data("broken-summaries".utf8); try bytes.write(to: file)
        let corrupt = AutomaticSummaryController(directory: f.directory, tracker: f.tracker, startClock: false, now: { f.now }, request: { _, _, _, _ in XCTAssertTrue(false); return "错误" })
        XCTAssertFalse(corrupt.dataReadable); XCTAssertFalse(corrupt.enable(consent: true)); corrupt.openedToday()
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        XCTAssertFalse(f.summary.enable(consent: true)); f.summary.openedToday()
        XCTAssertEqual(f.calls, 0)
    }

    @MainActor func testPausingRecordingCancelsSummaryAndDoesNotResetBudget() async throws {
        let f = try SummaryFixture(); defer { f.close() }
        f.delayed = true
        XCTAssertTrue(f.summary.enable(consent: true)); f.summary.openedToday()
        try await Task.sleep(for: .milliseconds(20))
        f.tracker.pause(); f.summary.reconcile()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(f.summary.isGenerating); XCTAssertNil(f.summary.todayReport)
        XCTAssertEqual(f.summary.latestAttempt?.state, .cancelled)
        f.tracker.resume(); f.summary.reconcile(); f.summary.openedToday()
        XCTAssertEqual(f.calls, 1)
        f.now = Calendar.current.date(bySettingHour: 13, minute: 0, second: 0, of: f.now)!
        f.tracker.setAway(true); f.summary.reconcile()
        XCTAssertEqual(f.calls, 1); XCTAssertEqual(f.summary.archive.attempts.count, 1)
    }

    @MainActor func testUnifiedExportIncludesOldFilesAndClearBacksUpWithoutDeletingLegacy() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("export-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FocusStore(directory: directory, startClock: false)
        store.data.sessions = [FocusSession(goal: "旧任务", kind: .other, startedAt: origin, endedAt: origin.addingTimeInterval(60), focusSeconds: 60, plannedSeconds: 300, interruptions: 0, outcome: .partial, note: "归档")]
        XCTAssertTrue(store.persist())
        let records = directory.appendingPathComponent("automatic-activities")
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        let old = ActivitySegment(start: origin, end: origin.addingTimeInterval(180), category: .reading, title: "旧活动", app: "阅读器", bundleID: "reader")
        let bytes = try JSONEncoder().encode([old]); try bytes.write(to: records.appendingPathComponent("2023-11-14.json"))
        XCTAssertEqual(try store.exportBundle().activities, [old])
        XCTAssertTrue(store.clearAutomaticData())
        XCTAssertEqual(store.data.sessions.count, 1); XCTAssertTrue(try store.exportBundle().activities.isEmpty)
        XCTAssertFalse(store.automatic.config.enabled); XCTAssertFalse(store.summary.enabled)
        let backups = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("backups"), includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0].appendingPathComponent("automatic-activities/2023-11-14.json")), bytes)
        try Data("broken".utf8).write(to: records.appendingPathComponent("old.json"))
        XCTAssertThrowsError(try store.exportBundle())
    }

    @MainActor func testSummaryRealHTTPUsesOnlyTextAndRejectsRedirects() async throws {
        let f = try SummaryFixture(); defer { f.close() }
        let port = ProcessInfo.processInfo.environment["FOCUSLENS_TEST_PORT"]!
        var config = f.tracker.config
        config.ai = AISettings(baseURL: "http://127.0.0.1:\(port)/json", model: "automatic-summary-http")
        config.verifiedSignature = VisionService.signature(config); config.consentSignature = config.verifiedSignature
        try JSONEncoder().encode(config).write(to: f.directory.appendingPathComponent("automatic-settings.json"))
        let tracker = AutomaticTracker(directory: f.directory, startClock: false, idleSeconds: { 0 }, now: { f.now }, permission: { true }, sessionAvailable: { true }, foreground: { ForegroundContext(pid: 4, bundleID: "fake.editor", name: "示例编辑器") })
        tracker.reconcile()
        let controller = AutomaticSummaryController(directory: f.directory, tracker: tracker, startClock: false, now: { f.now }, keyProvider: { "test-secret" })
        defer { controller.shutdown(); tracker.shutdown() }
        XCTAssertTrue(controller.enable(consent: true)); controller.openedToday()
        let deadline = Date().addingTimeInterval(5)
        while controller.isGenerating && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(controller.isGenerating)
        XCTAssertEqual(controller.todayReport?.content, "兼容服务的完整回复")
        let data = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/requests")!).0
        let requests = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let sent = requests.filter { ($0["body"] as? [String: Any])?["model"] as? String == "automatic-summary-http" }
        XCTAssertEqual(sent.count, 1); XCTAssertEqual(sent.first?["authorized"] as? Bool, true)
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: sent), as: UTF8.self)
        XCTAssertFalse(raw.contains("image_url")); XCTAssertFalse(raw.contains("fake.editor"))
        let settings = AISettings(baseURL: "http://127.0.0.1:\(port)/vision-redirect", model: "text-no-redirect")
        let body = try AIService.activityPayload(segments: f.records, interval: Period.today.interval(now: f.now), model: settings.model)
        do { _ = try await AIService.stream(settings: settings, key: "test-secret", body: body) { _ in }; XCTAssertTrue(false) }
        catch AIError.http(let status) { XCTAssertEqual(status, 307) }
    }
}
