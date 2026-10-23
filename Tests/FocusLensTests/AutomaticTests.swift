import AppKit
import Foundation

extension FocusLensTests {
    func testActivityLedgerBoundariesAndRestart() {
        let now = Date()
        var ledger = ActivityLedger()
        let reading = ActivityClassification(category: .reading, title: "文档")
        ledger.begin(reading, app: "浏览器", bundleID: "browser", at: now)
        ledger.checkpoint(at: now.addingTimeInterval(60))
        ledger.begin(reading, app: "浏览器", bundleID: "browser", at: now.addingTimeInterval(120))
        XCTAssertEqual(ledger.segments.count, 1)
        XCTAssertEqual(ledger.current?.seconds, 120)
        ledger.stop(at: now.addingTimeInterval(150))
        XCTAssertNil(ledger.currentID)
        ledger.begin(reading, app: "浏览器", bundleID: "browser", at: now.addingTimeInterval(3600))
        XCTAssertEqual(ledger.segments.count, 2)
        XCTAssertEqual(ledger.segments.reduce(0) { $0 + $1.seconds }, 150)
        ledger.checkpoint(at: now.addingTimeInterval(7000))
        XCTAssertNil(ledger.currentID)
        XCTAssertEqual(ledger.segments.reduce(0) { $0 + $1.seconds }, 150)
    }

    func testActivityMidnightAndCorrection() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 23, minute: 59))!
        var ledger = ActivityLedger()
        ledger.begin(ActivityClassification(category: .reading, title: "书"), app: "浏览器", bundleID: "browser", at: start)
        ledger.checkpoint(at: start.addingTimeInterval(60), calendar: calendar)
        ledger.checkpoint(at: start.addingTimeInterval(120), calendar: calendar)
        XCTAssertEqual(ledger.segments.count, 2)
        XCTAssertEqual(ledger.segments.map(\.seconds), [60,60])
        let previous = try XCTUnwrap(ledger.current)
        ledger.correct(id: previous.id, category: .writing, title: "笔记")
        ledger.checkpoint(at: start.addingTimeInterval(150), calendar: calendar)
        ledger.restoreClassification(previous)
        XCTAssertEqual(ledger.current?.category, .reading)
        XCTAssertEqual(ledger.current?.seconds, 90)
    }

    func testVisionParsingAndTextOnlyRejection() throws {
        XCTAssertEqual(try VisionService.parse("```json\n{\"category\":\"阅读\",\"title\":\"读书\",\"confidence\":\"low\"}\n```").category, .unknown)
        XCTAssertEqual(try VisionService.parse("{\"category\":\"开发\",\"title\":\"写代码\",\"confidence\":\"high\"}").category, .development)
        for text in ["我在看图", "{\"category\":\"高效\",\"title\":\"任务\",\"confidence\":\"high\"}", "{\"category\":\"阅读\",\"title\":\"书\"}"] {
            XCTAssertThrowsError(try VisionService.parse(text))
        }
        var config = AutomaticConfig(); let signature = VisionService.signature(config)
        config.intervalMinutes = 5
        XCTAssertEqual(VisionService.signature(config), signature)
        config.ai.model = "another-model"
        XCTAssertTrue(VisionService.signature(config) != signature)
        let old = AISettings(baseURL: "https://one.example/v1", model: "one")
        let next = AISettings(baseURL: "http://127.0.0.1/v1", model: "two")
        XCTAssertEqual(try VisionService.credentialUpdate(previous: old, next: next, provided: nil), "")
        XCTAssertNil(try VisionService.credentialUpdate(previous: old, next: old, provided: nil))
        XCTAssertEqual(try VisionService.credentialUpdate(previous: old, next: next, provided: "explicit-test-key"), "explicit-test-key")
    }

    @MainActor func testMemoryImageEncodingAndRequest() throws {
        let challenge = try VisionChallenge.make(code: "7314", color: "blue")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: challenge.image))
        let jpeg = try MemoryScreenCapture.encode(try XCTUnwrap(bitmap.cgImage))
        XCTAssertTrue(jpeg.count <= 1_100_000)
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xff,0xd8])
        let body = try VisionService.payload(image: jpeg, mime: "image/jpeg", prompt: "识别", model: "vision")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        let parts = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        let image = try XCTUnwrap(parts[1]["image_url"] as? [String: String])
        XCTAssertTrue(image["url"]!.hasPrefix("data:image/jpeg;base64,"))
        XCTAssertThrowsError(try VisionService.payload(image: Data(repeating: 0, count: 1_100_001), mime: "image/jpeg", prompt: "", model: "vision"))
    }

    @MainActor func testAutomaticConsentAndPrivacyGates() async throws {
        let directory = automaticDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        var config = AutomaticConfig(); config.ai = AISettings(baseURL: "http://127.0.0.1/v1", model: "vision")
        config.verifiedSignature = VisionService.signature(config)
        try writeAutomatic(config, directory: directory)
        let app = ForegroundContext(pid: 42, bundleID: "test.browser", name: "浏览器")
        var calls = 0
        let denied = AutomaticTracker(directory: directory, startClock: false, permission: { false }, foreground: { app }, capture: { _ in calls += 1; throw AutomaticError.noWindow })
        denied.enable(consent: false); denied.sample()
        XCTAssertFalse(denied.config.enabled)
        denied.enable(consent: true); denied.sample()
        XCTAssertFalse(denied.config.enabled)
        XCTAssertEqual(calls, 0)
        config.enabled = true; config.consentSignature = VisionService.signature(config); config.excludedApps[app.bundleID] = "浏览器"
        try writeAutomatic(config, directory: directory)
        let excluded = AutomaticTracker(directory: directory, startClock: false, permission: { true }, sessionAvailable: { true }, foreground: { app }, capture: { _ in calls += 1; throw AutomaticError.noWindow })
        excluded.reconcile(); excluded.resume(); excluded.sample()
        XCTAssertEqual(excluded.status, .excluded("浏览器"))
        XCTAssertEqual(calls, 0)
    }

    @MainActor func testAutomaticSingleFlightCancellationAndMemoryOnly() async throws {
        let directory = automaticDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        var config = AutomaticConfig(); config.ai = AISettings(baseURL: "http://127.0.0.1/v1", model: "vision")
        config.verifiedSignature = VisionService.signature(config); config.consentSignature = config.verifiedSignature; config.enabled = true
        try writeAutomatic(config, directory: directory)
        var app = ForegroundContext(pid: 42, bundleID: "test.browser", name: "浏览器")
        var captures = 0, analyses = 0
        let privateImage = Data("PRIVATE_IMAGE_BYTES_MUST_NOT_BE_SAVED".utf8)
        let tracker = AutomaticTracker(directory: directory, startClock: false, permission: { true }, sessionAvailable: { true }, foreground: { app }, capture: { _ in
            captures += 1
            return MemoryScreenCapture.Frame(jpeg: privateImage, fingerprint: Data([1,2,3]), contextKey: "page", capturedAt: Date())
        }, analyze: { _, _, _ in analyses += 1; try? await Task.sleep(for: .milliseconds(70)); return ActivityClassification(category: .reading, title: "阅读文档") })
        tracker.sample(); tracker.sample()
        try await Task.sleep(for: .milliseconds(140))
        XCTAssertEqual(captures, 1); XCTAssertEqual(analyses, 1)
        XCTAssertEqual(tracker.current?.category, .reading)
        tracker.sample(); try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(captures, 2); XCTAssertEqual(analyses, 1)
        tracker.pause(); tracker.sample(); XCTAssertEqual(captures, 2)
        let restored = AutomaticTracker(directory: directory, startClock: false, permission: { true }, sessionAvailable: { true }, foreground: { app })
        restored.reconcile(); XCTAssertEqual(restored.status, .paused)
        tracker.resume(); app = ForegroundContext(pid: 43, bundleID: "test.editor", name: "编辑器"); tracker.reconcile(); tracker.sample()
        tracker.setAway(true)
        try await Task.sleep(for: .milliseconds(140))
        XCTAssertEqual(tracker.status, .away)
        XCTAssertNil(tracker.current)
        tracker.setAway(false); tracker.setManualBlocked(true); tracker.sample()
        XCTAssertEqual(tracker.status, .manual)
        tracker.setManualBlocked(false)
        tracker.setLifecycleBlock("lock", blocked: true)
        tracker.setLifecycleBlock("screen", blocked: true)
        tracker.setLifecycleBlock("screen", blocked: false)
        tracker.resume(); tracker.sample()
        XCTAssertEqual(tracker.status, .away)
        tracker.setLifecycleBlock("lock", blocked: false)
        let paths: [URL] = { (FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL]) ?? [] }()
        for file in paths {
            if file.pathExtension == "json" {
                let raw = try Data(contentsOf: file)
                XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains(String(decoding: privateImage, as: UTF8.self)))
                XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains(privateImage.base64EncodedString()))
            }
            XCTAssertFalse(["png","jpg","jpeg","tiff"].contains(file.pathExtension.lowercased()))
        }
    }

    @MainActor func testAutomaticFailureAndHistoricalSafety() async throws {
        let directory = automaticDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        var config = AutomaticConfig(); config.ai = AISettings(baseURL: "http://127.0.0.1/v1", model: "vision")
        config.enabled = true; config.verifiedSignature = VisionService.signature(config); config.consentSignature = config.verifiedSignature
        try writeAutomatic(config, directory: directory)
        let app = ForegroundContext(pid: 42, bundleID: "test.browser", name: "浏览器")
        let tracker = AutomaticTracker(directory: directory, startClock: false, permission: { true }, sessionAvailable: { true }, foreground: { app }, capture: { _ in
            MemoryScreenCapture.Frame(jpeg: Data([1]), fingerprint: Data([2]), contextKey: "context", capturedAt: Date())
        }, analyze: { _,_,_ in throw AutomaticError.invalidResponse })
        tracker.sample(); try await Task.sleep(for: .milliseconds(100))
        if case .error = tracker.status {} else { XCTAssertTrue(false) }
        XCTAssertEqual(tracker.current?.category, .unknown)
        tracker.shutdown()
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let old = utc.startOfDay(for: Date().addingTimeInterval(-12 * 86400)).addingTimeInterval(3600)
        let first = ActivitySegment(start: old, end: old.addingTimeInterval(300), category: .reading, title: "old", app: "浏览器", bundleID: "browser")
        var second = first; second.id = UUID(); second.start = old.addingTimeInterval(400); second.end = old.addingTimeInterval(500)
        let formatter = DateFormatter(); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
        let file = directory.appendingPathComponent("automatic-activities/" + formatter.string(from: old) + ".json")
        try JSONEncoder().encode([first,second]).write(to: file)
        tracker.editingSegment = first; tracker.correct(id: first.id, category: .writing, title: "corrected")
        tracker.persist()
        let items = try JSONDecoder().decode([ActivitySegment].self, from: Data(contentsOf: file))
        XCTAssertEqual(items.count, 2); XCTAssertEqual(items[1], second)
        XCTAssertEqual(items[0].category, .writing)
        tracker.undoCorrection()
        let undone = try JSONDecoder().decode([ActivitySegment].self, from: Data(contentsOf: file))
        XCTAssertEqual(undone, [first,second])
    }

    func testAutomaticReviewNeverInventsCompletion() throws {
        let segment = ActivitySegment(start: Date(), end: Date().addingTimeInterval(100), category: .unknown, title: "浏览网页", app: "浏览器", bundleID: "private.bundle")
        let body = try AIService.activityPayload(segments: [segment], interval: Period.today.interval(), model: "mock")
        let raw = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(raw.contains("不得计算完成率"))
        XCTAssertFalse(raw.contains("private.bundle"))
        XCTAssertFalse(raw.contains("image_url"))
        let review = Review(createdAt: Date(), start: Date(), end: Date().addingTimeInterval(86400), sessionIDs: [segment.id], content: "观察", model: "mock", activityEvidence: [segment])
        let followup = try AIService.conversationPayload(review: review, question: "建议", model: "mock")
        XCTAssertTrue(String(decoding: followup, as: UTF8.self).contains("自动活动记录"))
    }

    @MainActor func testVisionWireCapabilityContract() async throws {
        let port = ProcessInfo.processInfo.environment["FOCUSLENS_TEST_PORT"]!
        let settings = AISettings(baseURL: "http://127.0.0.1:\(port)/vision", model: "vision-contract")
        let image = try VisionChallenge.make(code: "7314", color: "blue")
        try await VisionService.test(settings: settings, key: "test-secret", challenge: image)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: image.image))
        let jpeg = try MemoryScreenCapture.encode(try XCTUnwrap(bitmap.cgImage))
        let result = try await VisionService.classify(image: jpeg, settings: settings, key: "test-secret")
        XCTAssertEqual(result.category, .reading)
        do {
            let wrong = try VisionChallenge.make(code: "1234", color: "red")
            try await VisionService.test(settings: settings, key: "test-secret", challenge: wrong)
            XCTAssertTrue(false)
        } catch AutomaticError.capability { }
    }

    @MainActor func testVisionRedirectNeverForwardsImage() async throws {
        let port = ProcessInfo.processInfo.environment["FOCUSLENS_TEST_PORT"]!
        let settings = AISettings(baseURL: "http://127.0.0.1:\(port)/vision-redirect", model: "redirect-check")
        let sample = try VisionChallenge.make(code: "7314", color: "blue")
        do {
            try await VisionService.test(settings: settings, key: nil, challenge: sample)
            XCTAssertTrue(false)
        } catch AIError.http(let code) { XCTAssertEqual(code, 307) }
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/requests")!)
        let items = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        XCTAssertEqual(items.filter { ($0["body"] as? [String: Any])?["model"] as? String == "redirect-check" }.count, 1)
    }

    private func automaticDirectory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("auto-check-" + UUID().uuidString) }
    private func writeAutomatic(_ config: AutomaticConfig, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(config).write(to: directory.appendingPathComponent("automatic-settings.json"))
    }
}
