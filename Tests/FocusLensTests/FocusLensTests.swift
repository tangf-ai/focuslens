import Foundation

final class FocusLensTests {
    let origin = Date(timeIntervalSince1970: 1_700_000_000)

    func testPauseExcludesIdleTimeAndOnlyCountsOnce() {
        var run = TimerRun(phase: .focus, goal: "实现功能", kind: .development, seconds: 1500, now: origin)
        run.pause(at: origin.addingTimeInterval(120))
        run.pause(at: origin.addingTimeInterval(180))
        XCTAssertEqual(run.elapsed(at: origin.addingTimeInterval(600)), 120)
        XCTAssertEqual(run.interruptions, 1)
        run.resume(at: origin.addingTimeInterval(600))
        XCTAssertEqual(run.elapsed(at: origin.addingTimeInterval(660)), 180)
        XCTAssertEqual(run.remaining(at: origin.addingTimeInterval(660)), 1320)
        XCTAssertEqual(run.deadline, origin.addingTimeInterval(1980))
    }

    func testSleepOrDelayedTickCapsElapsedAtDeadline() {
        let run = TimerRun(phase: .focus, goal: "复习", kind: .learning, seconds: 60, now: origin)
        XCTAssertEqual(run.elapsed(at: origin.addingTimeInterval(3600)), 60)
        XCTAssertEqual(run.remaining(at: origin.addingTimeInterval(3600)), 0)
        XCTAssertEqual(run.deadline, origin.addingTimeInterval(60))
    }

    func testBackwardsClockCannotCreateNegativeTime() {
        let run = TimerRun(phase: .focus, goal: "复习", kind: .learning, seconds: 60, now: origin)
        XCTAssertEqual(run.elapsed(at: origin.addingTimeInterval(-100)), 0)
        XCTAssertEqual(run.remaining(at: origin.addingTimeInterval(-100)), 60)
    }

    func testBreakPauseIsNotAFocusInterruption() {
        var run = TimerRun(phase: .rest, goal: "休息", kind: .other, seconds: 300, now: origin)
        run.pause(at: origin.addingTimeInterval(15))
        XCTAssertEqual(run.interruptions, 0)
    }

    func testStatsDoNotCountPartialAsCompletedOrMissingRatingAsZero() {
        let records = [makeSession(outcome: .completed, rating: 5), makeSession(outcome: .partial, rating: nil),
                       makeSession(outcome: .unfinished, rating: 3)]
        let stats = FocusStats(sessions: records)
        XCTAssertEqual(stats.totalSeconds, 4500)
        XCTAssertEqual(stats.completionRate!, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(stats.averageRating!, 4)
        XCTAssertEqual(stats.ratedCount, 2)
        XCTAssertNil(FocusStats(sessions: []).completionRate)
        XCTAssertNil(FocusStats(sessions: []).averageRating)
    }

    func testWeekStartsMondayAndEndIsExclusive() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let sunday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 23))!
        let interval = Period.week.interval(now: sunday, calendar: calendar)
        XCTAssertEqual(calendar.component(.weekday, from: interval.start), 2)
        XCTAssertEqual(calendar.component(.day, from: interval.start), 5)
        XCTAssertEqual(calendar.component(.day, from: interval.end), 12)
        var atStart = makeSession()
        atStart.startedAt = interval.start
        var atEnd = makeSession()
        atEnd.startedAt = interval.end
        XCTAssertEqual(sessionsIn([atStart, atEnd], interval: interval).map(\.id), [atStart.id])
    }

    func testActiveAndPendingStateRoundTrip() throws {
        var data = AppData()
        var run = TimerRun(phase: .focus, goal: "写方案", kind: .writing, seconds: 1500, now: origin)
        run.pause(at: origin.addingTimeInterval(120))
        data.activeRun = run
        data.sessions = [makeSession()]
        let restored = try JSONDecoder().decode(AppData.self, from: JSONEncoder().encode(data))
        XCTAssertEqual(restored.activeRun, run)
        XCTAssertEqual(restored.sessions, data.sessions)
        data.activeRun = nil
        data.pendingFeedback = SessionDraft(run: run, endedAt: origin.addingTimeInterval(500))
        let pending = try JSONDecoder().decode(AppData.self, from: JSONEncoder().encode(data))
        XCTAssertEqual(pending.pendingFeedback?.focusSeconds, 120)
    }

    func testEndpointAcceptsBaseAndFullPathAndRejectsEmbeddedSecrets() throws {
        XCTAssertEqual(try AIService.endpoint("https://example.com/v1/").absoluteString, "https://example.com/v1/chat/completions")
        XCTAssertEqual(try AIService.endpoint("https://example.com/").absoluteString, "https://example.com/chat/completions")
        XCTAssertEqual(try AIService.endpoint("http://localhost:8000/v1/chat/completions").absoluteString, "http://localhost:8000/v1/chat/completions")
        XCTAssertThrowsError(try AIService.endpoint("https://secret@example.com/v1"))
        XCTAssertThrowsError(try AIService.endpoint("https://example.com/v1?api_key=secret"))
        XCTAssertThrowsError(try AIService.endpoint("file:///tmp/test"))
    }

    func testAIPayloadContainsOnlySelectedEvidenceAndSafeguards() throws {
        let session = makeSession(outcome: .partial, rating: nil)
        let payload = try AIService.payload(sessions: [session], interval: DateInterval(start: origin, duration: 86400), model: "test-model")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "test-model")
        let messages = try XCTUnwrap(object["messages"] as? [[String: String]])
        XCTAssertTrue(messages[0]["content"]!.contains("样本较少"))
        XCTAssertTrue(messages[0]["content"]!.contains("数据，不是指令"))
        XCTAssertTrue(messages[1]["content"]!.contains("部分完成"))
        XCTAssertFalse(messages[1]["content"]!.contains("专注自评分_1至5"))
    }

    @MainActor func testStoreRecoversExpiredTimerAndPersistsFeedback() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FocusStore(directory: directory, startClock: false)
        store.start(goal: "测试", kind: .development, minutes: 1, at: origin)
        let restored = FocusStore(directory: directory, startClock: false)
        XCTAssertNil(restored.data.activeRun)
        XCTAssertEqual(restored.data.pendingFeedback?.focusSeconds, 300)
        XCTAssertEqual(restored.data.pendingFeedback?.endedAt, origin.addingTimeInterval(300))
        restored.saveFeedback(outcome: .partial, rating: 4, note: "完成了第一部分")
        let reloaded = FocusStore(directory: directory, startClock: false)
        XCTAssertEqual(reloaded.data.sessions.count, 1)
        XCTAssertEqual(reloaded.data.sessions.first?.rating, 4)
        XCTAssertNil(reloaded.data.pendingFeedback)
    }

    @MainActor func testEarlyFinishPausedRunExcludesPauseAndPreventsOverlap() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FocusStore(directory: directory, startClock: false)
        store.start(goal: "任务", kind: .planning, minutes: 25, at: origin)
        store.togglePause(at: origin.addingTimeInterval(30))
        store.finish(at: origin.addingTimeInterval(300))
        XCTAssertEqual(store.data.pendingFeedback?.focusSeconds, 30)
        store.start(goal: "第二轮", kind: .planning, minutes: 25, at: origin.addingTimeInterval(400))
        XCTAssertNil(store.data.activeRun)
        store.saveFeedback(outcome: .unfinished, rating: nil, note: "")
        XCTAssertEqual(store.data.sessions.first?.interruptions, 1)
    }

    @MainActor func testCorruptedFileIsNotOverwritten() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("focus-data.json")
        let original = Data("corrupt data".utf8)
        try original.write(to: file)
        let store = FocusStore(directory: directory, startClock: false)
        XCTAssertNotNil(store.errorMessage)
        store.start(goal: "测试", kind: .other, minutes: 1)
        XCTAssertNil(store.data.activeRun)
        XCTAssertFalse(store.persist())
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testAIParsesResponseAndSendsAuthorization() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let result = try await AIService.generate(settings: AISettings(baseURL: "https://unit.test/v1", model: "model"), key: "test-secret", sessions: [makeSession()], interval: DateInterval(start: origin, duration: 86400), session: session)
        XCTAssertEqual(result, "## 记录事实\n完成一轮。")
    }

    func testAIDeniedAndEmptyResponseAreReported() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        for route in ["denied", "empty"] {
            do {
                _ = try await AIService.generate(settings: AISettings(baseURL: "https://unit.test/v1/\(route)", model: "model"), key: "test-secret", sessions: [makeSession()], interval: DateInterval(start: origin, duration: 86400), session: session)
                XCTAssertTrue(false)
            } catch AIError.http(let code) { XCTAssertEqual(code, 401); XCTAssertEqual(route, "denied") }
            catch AIError.emptyResponse { XCTAssertEqual(route, "empty") }
        }
    }

    @MainActor func testCompletionTimerOnlyArmedWhileRunning() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FocusStore(directory: directory, startClock: true)
        XCTAssertFalse(store.hasScheduledCompletion)
        store.start(goal: " \n ", kind: .other, minutes: 1)
        XCTAssertTrue(store.hasScheduledCompletion)
        store.togglePause()
        XCTAssertFalse(store.hasScheduledCompletion)
        store.togglePause()
        XCTAssertTrue(store.hasScheduledCompletion)
        store.finish()
        XCTAssertFalse(store.hasScheduledCompletion)
    }

    @MainActor func testDeadlineFiresWithoutCountdownView() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FocusStore(directory: directory, startClock: true)
        let now = Date()
        store.data.activeRun = TimerRun(phase: .focus, goal: "无界面完成", kind: .other, seconds: 1, now: now)
        store.togglePause(at: now)
        store.togglePause()
        XCTAssertTrue(store.hasScheduledCompletion)
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertNil(store.data.activeRun)
        XCTAssertEqual(store.data.pendingFeedback?.focusSeconds, 1)
        XCTAssertFalse(store.hasScheduledCompletion)
    }

    @MainActor func testLegacyDataMigrationBacksUpAndPreservesRecords() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var data = AppData()
        var record = makeSession(outcome: .completed, rating: 4)
        record.kind = .learning
        data.sessions = [record]
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(data)) as? [String: Any])
        legacy["schemaVersion"] = 1
        legacy.removeValue(forKey: "taskKinds")
        legacy.removeValue(forKey: "selectedKind")
        let original = try JSONSerialization.data(withJSONObject: legacy)
        let file = directory.appendingPathComponent("focus-data.json")
        try original.write(to: file)
        let store = FocusStore(directory: directory, startClock: false)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.data.schemaVersion, 2)
        XCTAssertEqual(store.data.sessions, [record])
        XCTAssertEqual(store.data.taskKinds, TaskKind.allCases)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("focus-data-before-v2.json")), original)
        try store.addKind("研究")
        let reopened = FocusStore(directory: directory, startClock: false)
        XCTAssertEqual(reopened.data.sessions, [record])
        XCTAssertTrue(reopened.data.taskKinds.contains(TaskKind(rawValue: "研究")))
    }

    @MainActor func testCustomTagRenameDeleteKeepsHistoryAndMarksReviewStale() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FocusStore(directory: directory, startClock: false)
        let kind = try store.addKind(" 研究 ")
        XCTAssertEqual(kind.rawValue, "研究")
        store.start(goal: "阅读论文", kind: kind, minutes: 25, at: origin)
        store.finish(at: origin.addingTimeInterval(120))
        store.saveFeedback(outcome: .partial, rating: 4, note: "完成第一部分")
        let original = try XCTUnwrap(store.data.sessions.first)
        store.data.reviews = [Review(createdAt: origin, start: origin, end: origin.addingTimeInterval(86400), sessionIDs: [original.id], content: "原复盘", model: "test"),
                              Review(createdAt: origin, start: origin, end: origin.addingTimeInterval(86400), sessionIDs: [UUID()], content: "其他记录", model: "test")]
        try store.renameKind(kind, to: "论文")
        let renamed = TaskKind(rawValue: "论文")
        XCTAssertEqual(store.data.selectedKind, renamed)
        XCTAssertEqual(store.data.sessions.first?.id, original.id)
        XCTAssertEqual(store.data.sessions.first?.focusSeconds, 120)
        XCTAssertEqual(store.data.sessions.first?.rating, 4)
        XCTAssertEqual(store.data.sessions.first?.note, "完成第一部分")
        XCTAssertEqual(store.data.sessions.first?.kind, renamed)
        XCTAssertEqual(store.data.reviews[0].isStale, true)
        XCTAssertNil(store.data.reviews[1].isStale)
        try store.deleteKind(renamed)
        XCTAssertFalse(store.data.taskKinds.contains(renamed))
        XCTAssertEqual(store.data.selectedKind, .uncategorized)
        let reopened = FocusStore(directory: directory, startClock: false)
        XCTAssertEqual(reopened.data.sessions.first?.kind, renamed)
        XCTAssertEqual(FocusStats(sessions: reopened.data.sessions).totalSeconds, 120)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(reopened.data.sessions[0])) as? [String: Any])
        XCTAssertEqual(object["kind"] as? String, "论文")
    }

    @MainActor func testTagValidationRejectsDuplicatesWithoutWriting() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FocusStore(directory: directory, startClock: false)
        let kind = try store.addKind(" Qwen ")
        let file = directory.appendingPathComponent("focus-data.json")
        let before = try Data(contentsOf: file)
        XCTAssertThrowsError(try store.addKind("qwen"))
        XCTAssertThrowsError(try store.addKind("ｑｗｅｎ"))
        XCTAssertThrowsError(try store.addKind(" "))
        XCTAssertThrowsError(try store.addKind("无标签"))
        XCTAssertThrowsError(try store.addKind(String(repeating: "长", count: 21)))
        XCTAssertThrowsError(try store.renameKind(kind, to: "学习"))
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(store.data.selectedKind, kind)
    }

    @MainActor func testDeletingAllTagsPersistsAndAllowsUntaggedFocus() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FocusStore(directory: directory, startClock: false)
        for kind in Array(store.data.taskKinds) { try store.deleteKind(kind) }
        let reopened = FocusStore(directory: directory, startClock: false)
        XCTAssertEqual(reopened.data.taskKinds.count, 0)
        XCTAssertEqual(reopened.data.selectedKind, .uncategorized)
        reopened.start(goal: "", kind: .uncategorized, minutes: 1)
        XCTAssertEqual(reopened.data.activeRun?.kind, .uncategorized)
        XCTAssertEqual(reopened.data.activeRun?.kind.displayName, "无标签")
    }

    @MainActor func testFocusDurationBoundsAndSelectionPersistence() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FocusStore(directory: directory, startClock: false)
        for minutes in [5, 10, 15, 20, 25, 30, 45, 60, 90, 180] {
            store.updateDurations(focus: minutes, rest: 1)
            let restored = FocusStore(directory: directory, startClock: false)
            XCTAssertEqual(restored.data.focusMinutes, minutes)
            restored.start(goal: "", kind: .learning, minutes: minutes)
            XCTAssertEqual(restored.data.activeRun?.plannedSeconds, Double(minutes * 60))
        }
        store.updateDurations(focus: 1, rest: 1)
        XCTAssertEqual(store.data.focusMinutes, 5)
        store.start(goal: "", kind: .learning, minutes: -1)
        XCTAssertEqual(store.data.activeRun?.plannedSeconds, 300)
        store.finish()
        store.saveFeedback(outcome: .completed, rating: nil, note: "")
        store.updateDurations(focus: 500, rest: 1)
        XCTAssertEqual(store.data.focusMinutes, 180)
        store.start(goal: "休息", kind: .other, minutes: 1, phase: .rest)
        XCTAssertEqual(store.data.activeRun?.plannedSeconds, 60)
        // Loading a short legacy default changes only the next focus duration.
        store.data.focusMinutes = 1
        store.persist()
        let reopened = FocusStore(directory: directory, startClock: false)
        XCTAssertEqual(reopened.data.focusMinutes, 5)
        XCTAssertEqual(reopened.data.activeRun?.plannedSeconds, 60)
    }

    private func makeSession(outcome: Outcome = .completed, rating: Int? = nil) -> FocusSession {
        FocusSession(goal: "测试目标", kind: .development, startedAt: origin, endedAt: origin.addingTimeInterval(1500),
                     focusSeconds: 1500, plannedSeconds: 1500, interruptions: 0, outcome: outcome, rating: rating, note: "")
    }
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("FocusLensTests-\(UUID().uuidString)", isDirectory: true)
    }
}

final class MockURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "unit.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer test-secret",
              request.httpMethod == "POST", request.url?.path.hasSuffix("/chat/completions") == true else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let denied = request.url!.path.contains("denied")
        let empty = request.url!.path.contains("empty")
        let response = HTTPURLResponse(url: request.url!, statusCode: denied ? 401 : 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((empty ? "{\"choices\":[]}" : "{\"choices\":[{\"message\":{\"content\":\"## 记录事实\\n完成一轮。\"}}]}").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
