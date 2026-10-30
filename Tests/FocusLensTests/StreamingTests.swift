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
        XCTAssertFalse(restored.summary.isGenerating)
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

    private func streamSettings(_ route: String, model: String = "stream-test") -> AISettings {
        let port = ProcessInfo.processInfo.environment["FOCUSLENS_TEST_PORT"]!
        return AISettings(baseURL: "http://127.0.0.1:\(port)/\(route)", model: model)
    }
    private func streamSample() -> FocusSession {
        FocusSession(goal: "演示目标", kind: .learning, startedAt: Date(), endedAt: Date(), focusSeconds: 1500,
            plannedSeconds: 1500, interruptions: 0, outcome: .completed, rating: 4, note: "演示反馈")
    }
}
