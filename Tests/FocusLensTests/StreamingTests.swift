import Foundation
import Combine
import AppKit

extension FocusLensTests {
    func testStreamParserSupportsSSEFraming() throws {
        var parser = ReviewStreamParser()
        XCTAssertNil(try parser.consume(": ping"))
        XCTAssertNil(try parser.consume(""))
        XCTAssertNil(try parser.consume("data: {\"choices\": [{\"index\": 0,"))
        XCTAssertNil(try parser.consume("data: \"delta\": {\"content\": \"中文\"}, \"finish_reason\": null}]}"))
        XCTAssertEqual(try parser.consume("")?.text, "中文")
        _ = try parser.consume("data: {\"choices\":[],\"usage\":{}}")
        XCTAssertNil(try parser.consume(""))
        _ = try parser.consume("data: [DONE]")
        XCTAssertTrue(try XCTUnwrap(parser.consume("")).finished)
        _ = try parser.consume("data: not-json")
        XCTAssertThrowsError(try parser.consume(""))
        _ = try parser.consume("event: error")
        _ = try parser.consume("data: {\"error\":{\"message\":\"failure\"}}")
        XCTAssertThrowsError(try parser.consume(""))
    }

    func testConversationSnapshotAndIncompleteTurns() throws {
        XCTAssertEqual(Keychain.account(scope: nil), "ai-api-key")
        XCTAssertTrue(Keychain.account(scope: "/test-one") != Keychain.account(scope: nil))
        XCTAssertTrue(Keychain.account(scope: "/test-one") != Keychain.account(scope: "/test-two"))
        let session = streamSample()
        var review = Review(createdAt: Date(), start: session.startedAt, end: session.startedAt.addingTimeInterval(86400),
            sessionIDs: [session.id], content: "初始分析", model: "test", evidence: [session], messages: [
                ReviewMessage(role: .user, content: "有效问题"), ReviewMessage(role: .assistant, content: "有效回复"),
                ReviewMessage(role: .user, content: "中断问题"), ReviewMessage(role: .assistant, content: "未完成文字", state: .cancelled)])
        let body = try AIService.conversationPayload(review: review, question: "新的问题", model: "test")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: String]])
        XCTAssertEqual(object["stream"] as? Bool, true)
        XCTAssertEqual(messages.map { $0["role"]! }, ["system", "user", "assistant", "user", "assistant", "user"])
        XCTAssertTrue(messages[1]["content"]!.contains("演示目标"))
        XCTAssertEqual(messages.last?["content"], "新的问题")
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("中断问题"))
        XCTAssertTrue(review.transcript.contains("（未完成："))
        review.evidence = nil
        let legacy = try AIService.conversationPayload(review: review, question: "继续", model: "test")
        XCTAssertTrue(String(decoding: legacy, as: UTF8.self).contains("未保存原始记录快照"))
        XCTAssertThrowsError(try AIService.conversationPayload(review: review, question: String(repeating: "字", count: 2001), model: "test"))
        review.messages = (0..<20).flatMap { _ in [ReviewMessage(role: .user, content: "问"), ReviewMessage(role: .assistant, content: "答")] }
        XCTAssertThrowsError(try AIService.conversationPayload(review: review, question: "继续", model: "test"))
    }

    @MainActor func testReviewArchiveCompatibilityAndInterruptedRecovery() throws {
        let sample = streamSample()
        let review = Review(createdAt: Date(), start: sample.startedAt, end: sample.startedAt.addingTimeInterval(86400),
            sessionIDs: [sample.id], content: "已生成文字", model: "test", evidence: [sample],
            messages: [ReviewMessage(role: .user, content: "问题"), ReviewMessage(role: .assistant, content: "", state: .generating)])
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(review)) as! [String: Any]
        for key in ["evidence", "messages", "state", "error"] { object.removeValue(forKey: key) }
        let old = try JSONDecoder().decode(Review.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(old.canContinue)
        XCTAssertNil(old.messages)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FocusStore(directory: directory, startClock: false)
        store.data.reviews = [review]
        store.persist()
        let original = try Data(contentsOf: directory.appendingPathComponent("focus-data.json"))
        let restored = FocusStore(directory: directory, startClock: false)
        XCTAssertFalse(restored.isGenerating)
        XCTAssertEqual(restored.data.reviews[0].messages?[1].state, .cancelled)
        XCTAssertEqual(restored.data.reviews[0].evidence, [sample])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("focus-data.json")), original)
    }

    @MainActor func testRealStreamingTransportAndFailures() async throws {
        let settings = streamSettings("stream")
        let body = try AIService.payload(sessions: [streamSample()], interval: Period.today.interval(), model: settings.model, stream: true)
        var updates: [String] = []
        let answer = try await AIService.stream(settings: settings, key: "test-secret", body: body) { updates.append($0) }
        XCTAssertTrue(updates.count >= 2)
        XCTAssertTrue(updates.first!.count < answer.count)
        XCTAssertTrue(answer.contains("已专注 25 分钟"))
        XCTAssertFalse(answer.contains("�"))
        let fallback = try await AIService.stream(settings: streamSettings("json"), key: "test-secret", body: body) { _ in }
        XCTAssertEqual(fallback, "兼容服务的完整回复")
        for route in ["denied", "broken", "error", "length", "empty"] {
            var partial = ""
            do {
                _ = try await AIService.stream(settings: streamSettings(route), key: "test-secret", body: body) { partial = $0 }
                XCTAssertTrue(false)
            } catch let error as AIError {
                switch (route, error) {
                case ("denied", .http(401)), ("broken", .incompleteResponse), ("error", .invalidStream),
                     ("length", .outputLimit), ("empty", .emptyResponse): break
                default: XCTAssertTrue(false)
                }
            }
            if ["broken", "error", "length"].contains(route) { XCTAssertTrue(!partial.isEmpty) }
        }
    }

    @MainActor func testStreamingCancellationRetainsText() async throws {
        var text = ""
        let settings = streamSettings("slow")
        let body = try AIService.payload(sessions: [streamSample()], interval: Period.today.interval(), model: settings.model, stream: true)
        let task = Task { try await AIService.stream(settings: settings, key: "test-secret", body: body) { text = $0 } }
        let deadline = Date().addingTimeInterval(3)
        while text.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(!text.isEmpty)
        task.cancel()
        do { _ = try await task.value; XCTAssertTrue(false) }
        catch is CancellationError { }
        catch let error as URLError { XCTAssertEqual(error.code, .cancelled) }
        XCTAssertTrue(!text.isEmpty)
    }

    @MainActor func testStoreStreamingConversationPersistence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FocusStore(directory: directory, startClock: false, aiKeyProvider: { "test-secret" })
        store.data.sessions = [streamSample()]
        store.data.aiSettings = streamSettings("stream", model: "conversation-check")
        let id = try XCTUnwrap(store.generateReview(period: .today))
        var unrelatedUpdates = 0
        let observation = store.objectWillChange.sink { unrelatedUpdates += 1 }
        defer { observation.cancel() }
        let deadline = Date().addingTimeInterval(5)
        while store.streamingText.isEmpty && store.isGenerating && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(store.isGenerating && !store.streamingText.isEmpty)
        XCTAssertEqual(unrelatedUpdates, 0)
        // Chunk updates live in memory, not in the JSON file.
        let inFlight = try JSONDecoder().decode(AppData.self, from: Data(contentsOf: directory.appendingPathComponent("focus-data.json")))
        XCTAssertEqual(inFlight.reviews[0].content, "")
        try await awaitReview(store)
        XCTAssertEqual(store.data.reviews[0].state, .complete)
        XCTAssertEqual(store.data.reviews[0].evidence, store.data.sessions)
        let originalGoal = store.data.sessions[0].goal
        store.data.sessions[0].goal = "生成后修改的目标"
        XCTAssertTrue(store.sendReviewQuestion(reviewID: id, question: "下一轮如何安排？"))
        try await awaitReview(store)
        XCTAssertTrue(store.sendReviewQuestion(reviewID: id, question: "把建议拆成两个步骤"))
        try await awaitReview(store)
        let restored = FocusStore(directory: directory, startClock: false)
        XCTAssertEqual(restored.data.reviews[0].messages?.count, 4)
        XCTAssertEqual(restored.data.reviews[0].messages?.last?.state, .complete)
        let url = URL(string: streamSettings("stream").baseURL)!.deletingLastPathComponent().appendingPathComponent("requests")
        let (data, _) = try await URLSession.shared.data(from: url)
        let records = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let conversations = records.filter { ($0["body"] as? [String: Any])?["model"] as? String == "conversation-check" }
        XCTAssertEqual(conversations.count, 3)
        XCTAssertTrue(conversations.allSatisfy { $0["authorized"] as? Bool == true })
        let last = try XCTUnwrap(conversations.last?["body"] as? [String: Any])
        let messages = try XCTUnwrap(last["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 6)
        guard messages.count == 6 else { return }
        XCTAssertTrue(messages[1]["content"]!.contains(originalGoal))
        XCTAssertFalse(messages[1]["content"]!.contains("生成后修改的目标"))
        XCTAssertEqual(messages[3]["content"], "下一轮如何安排？")
        store.data.aiSettings = streamSettings("slow")
        XCTAssertTrue(store.sendReviewQuestion(reviewID: id, question: "停止这次回复"))
        let stopDeadline = Date().addingTimeInterval(3)
        while store.streamingText.isEmpty && store.isGenerating && Date() < stopDeadline { try await Task.sleep(for: .milliseconds(20)) }
        store.cancelReview()
        let stopped = try JSONDecoder().decode(AppData.self, from: Data(contentsOf: directory.appendingPathComponent("focus-data.json")))
        XCTAssertEqual(stopped.reviews[0].messages?.last?.state, .cancelled)
        XCTAssertTrue(!(stopped.reviews[0].messages?.last?.content ?? "").isEmpty)
        try await awaitReview(store)
        XCTAssertEqual(store.data.reviews[0].messages?.last?.state, .cancelled)
        XCTAssertTrue(!(store.data.reviews[0].messages?.last?.content ?? "").isEmpty)
        let ending = FocusStore(directory: directory, startClock: true, aiKeyProvider: { "test-secret" })
        XCTAssertTrue(ending.sendReviewQuestion(reviewID: id, question: "退出期间保存"))
        let exitDeadline = Date().addingTimeInterval(3)
        while ending.streamingText.isEmpty && ending.isGenerating && Date() < exitDeadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(!ending.streamingText.isEmpty)
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        let exiting = try JSONDecoder().decode(AppData.self, from: Data(contentsOf: directory.appendingPathComponent("focus-data.json")))
        XCTAssertEqual(exiting.reviews[0].messages?.last?.state, .cancelled)
        XCTAssertTrue(!(exiting.reviews[0].messages?.last?.content ?? "").isEmpty)
        try await awaitReview(ending)
    }

    @MainActor private func awaitReview(_ store: FocusStore) async throws {
        let deadline = Date().addingTimeInterval(8)
        while store.isGenerating && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(store.isGenerating)
    }
    private func streamSettings(_ route: String, model: String = "stream-test") -> AISettings {
        let port = ProcessInfo.processInfo.environment["FOCUSLENS_TEST_PORT"]!
        return AISettings(baseURL: "http://127.0.0.1:\(port)/\(route)", model: model)
    }
    private func streamSample() -> FocusSession {
        FocusSession(goal: "演示目标", kind: .learning, startedAt: Date(), endedAt: Date(), focusSeconds: 1500,
            plannedSeconds: 1500, interruptions: 0, outcome: .completed, rating: 4, note: "演示反馈")
    }
}
