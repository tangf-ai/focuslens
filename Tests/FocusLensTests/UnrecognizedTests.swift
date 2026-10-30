import Foundation

@MainActor private final class RecognitionFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recognition-" + UUID().uuidString)
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var app = ForegroundContext(pid: 42, bundleID: "test.reader", name: "阅读器")
    var window: UInt32? = 7
    var captureError: Error?
    var analysisError: Error?
    var category: ActivityCategory = .reading
    var delay: Duration = .zero
    var tracker: AutomaticTracker!
    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var config = AutomaticConfig(); config.ai = AISettings(baseURL: "http://127.0.0.1:9/v1", model: "synthetic")
        config.enabled = true; config.intervalSeconds = 15
        config.verifiedSignature = VisionService.signature(config); config.consentSignature = config.verifiedSignature
        try JSONEncoder().encode(config).write(to: directory.appendingPathComponent("automatic-settings.json"))
    }
    func start() {
        tracker = AutomaticTracker(directory: directory, startClock: false, idleSeconds: { 0 }, now: { self.now }, permission: { true }, sessionAvailable: { true }, foreground: { self.app }, foregroundWindowID: { _ in self.window }, capture: { _ in
            if let error = self.captureError { throw error }
            return MemoryScreenCapture.Frame(jpeg: Data("PRIVATE_IMAGE".utf8), fingerprint: Data([1]), contextKey: "window-\(self.window ?? 0)", capturedAt: self.now, windowID: self.window)
        }, analyze: { _, _, _ in
            try? await Task.sleep(for: self.delay)
            if let error = self.analysisError { throw error }
            self.now.addTimeInterval(1)
            return ActivityClassification(category: self.category, title: "虚构阅读活动")
        })
    }
    func sample() async throws { tracker.sample(); try await Task.sleep(for: .milliseconds(30)) }
    func close() { tracker?.shutdown(); tracker = nil; try? FileManager.default.removeItem(at: directory) }
}

extension FocusLensTests {
    func testUnknownReasonCompatibilityAndHonestDistribution() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var record = ActivitySegment(start: start, end: start.addingTimeInterval(60), category: .unknown, title: "浏览器 · 活动待确认", app: "浏览器", bundleID: "test")
        let legacy = try JSONEncoder().encode(record)
        XCTAssertFalse(String(decoding: legacy, as: UTF8.self).contains("unknownReason"))
        let restored = try JSONDecoder().decode(ActivitySegment.self, from: legacy)
        XCTAssertNil(restored.unknownReason); XCTAssertEqual(restored.unresolvedReason, .waiting)
        var records = [restored]
        record.id = UUID(); record.start = record.end; record.end.addTimeInterval(60)
        record.title = "识别未完成，保留为未识别"; records.append(record)
        record.id = UUID(); record.start = record.end; record.end.addTimeInterval(60)
        record.title = "浏览器空白页面"; records.append(record)
        XCTAssertEqual(record.unresolvedReason, .legacy) // Do not invent historical confidence.
        record.id = UUID(); record.start = record.end; record.end.addTimeInterval(60)
        record.unknownReason = .insufficientEvidence; records.append(record)
        XCTAssertEqual(try JSONDecoder().decode(ActivitySegment.self, from: JSONEncoder().encode(record)), record)
        let items = ActivityPresentation.distribution(records)
        XCTAssertEqual(items.map(\.label), ["等待识别", "识别异常", "证据不足", "历史未识别"])
        XCTAssertEqual(items.reduce(0) { $0 + $1.seconds }, 240)
        XCTAssertEqual(ActivityPresentation.coalesced(records).count, 4)
        record.corrected = true; record.unknownReason = nil; record.title = "浏览器 · 活动待确认"
        XCTAssertEqual(record.unresolvedReason, .legacy)
        record.category = .reading; record.unknownReason = .failure
        XCTAssertNil(record.unresolvedReason); XCTAssertEqual(record.categoryLabel, "阅读")
        let payload = try AIService.activityPayload(segments: records, interval: DateInterval(start: start, duration: 300), model: "mock")
        let raw = String(decoding: payload, as: UTF8.self)
        XCTAssertTrue(raw.contains("等待识别")); XCTAssertTrue(raw.contains("识别异常"))
        XCTAssertTrue(raw.contains("不能当作用户活动"))
    }

    func testShortWaitResolutionIsBoundedAndNeverRewritesHistory() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let known = ActivityClassification(category: .reading, title: "阅读文档")
        func waiting(_ reason: ActivityUnknownReason? = .waiting) -> ActivityLedger {
            var ledger = ActivityLedger()
            ledger.begin(ActivityClassification(category: .unknown, title: "等待识别"), app: "阅读器", bundleID: "test", at: start, unknownReason: reason)
            return ledger
        }
        var ledger = waiting(); let id = ledger.currentID
        XCTAssertTrue(ledger.resolveShortWait(known, capturedAt: start.addingTimeInterval(5), sameWindow: true))
        XCTAssertEqual(ledger.currentID, id); XCTAssertEqual(ledger.current?.seconds, 5)
        XCTAssertEqual(ledger.current?.category, .reading); XCTAssertNil(ledger.current?.unknownReason)
        for reason: ActivityUnknownReason? in [.failure, .insufficientEvidence, .legacy, nil] {
            var old = waiting(reason); let snapshot = old.segments
            XCTAssertFalse(old.resolveShortWait(known, capturedAt: start.addingTimeInterval(2), sameWindow: true))
            XCTAssertEqual(old.segments, snapshot)
        }
        for (elapsed, sameWindow) in [(5.01,true), (-1,true), (2,false)] {
            var old = waiting(); let snapshot = old.segments
            XCTAssertFalse(old.resolveShortWait(known, capturedAt: start.addingTimeInterval(elapsed), sameWindow: sameWindow))
            XCTAssertEqual(old.segments, snapshot)
        }
        var unknown = waiting()
        XCTAssertFalse(unknown.resolveShortWait(ActivityClassification(category: .unknown, title: "不确定"), capturedAt: start.addingTimeInterval(1), sameWindow: true))
        var stopped = waiting(); stopped.stop(at: start.addingTimeInterval(2))
        XCTAssertFalse(stopped.resolveShortWait(known, capturedAt: start.addingTimeInterval(3), sameWindow: true))
        var corrected = waiting(); corrected.segments[0].corrected = true
        XCTAssertFalse(corrected.resolveShortWait(known, capturedAt: start.addingTimeInterval(2), sameWindow: true))
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let midnight = calendar.startOfDay(for: start)
        var crossing = ActivityLedger()
        crossing.begin(ActivityClassification(category: .unknown, title: "等待识别"), app: "阅读器", bundleID: "test", at: midnight.addingTimeInterval(-1), unknownReason: .waiting)
        XCTAssertFalse(crossing.resolveShortWait(known, capturedAt: midnight.addingTimeInterval(1), sameWindow: true, calendar: calendar))
    }

    func testRecognitionRetryAndSanitizedErrorCodes() throws {
        var config = AutomaticConfig(); config.intervalSeconds = 300
        XCTAssertEqual((1...7).map { config.retryDelay(failures: $0) }, [5,10,20,40,60,60,60])
        config.intervalSeconds = 15
        XCTAssertEqual((1...4).map { config.retryDelay(failures: $0) }, [5,10,15,15])
        let privateValue = "PRIVATE_SECRET_URL_OR_BODY"
        let error = URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: privateValue])
        XCTAssertEqual(RecognitionDiagnostic.errorCode(error), "network_-1001")
        XCTAssertEqual(RecognitionDiagnostic.errorCode(AIError.http(429)), "http_429")
        XCTAssertEqual(RecognitionDiagnostic.errorCode(AutomaticError.noWindow), "no_window")
        XCTAssertEqual(RecognitionDiagnostic.errorCode(AutomaticError.invalidResponse), "invalid_response")
        XCTAssertEqual(RecognitionDiagnostic.errorCode(NSError(domain: privateValue, code: 123)), "other")
        let entry = RecognitionDiagnostic(startedAt: Date(), endedAt: Date(), stage: .classification, outcome: .failure, code: RecognitionDiagnostic.errorCode(error))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(entry), as: UTF8.self).contains(privateValue))
    }

    @MainActor func testSameWindowShortWaitIsAbsorbedWithoutLosingTime() async throws {
        let f = try RecognitionFixture(); defer { f.close() }; f.start()
        f.tracker.reconcile(); let start = f.now
        f.now.addTimeInterval(2); try await f.sample()
        XCTAssertEqual(f.tracker.current?.start, start)
        XCTAssertEqual(f.tracker.ledger.segments.count, 1)
        XCTAssertEqual(f.tracker.current?.category, .reading)
        XCTAssertEqual(f.tracker.current?.seconds, 3)
        XCTAssertEqual(f.tracker.recognitionDiagnostics.last?.outcome, .success)
    }

    @MainActor func testChangedWindowAndLongWaitAreNotBackfilled() async throws {
        for changeWindow in [true, false] {
            let f = try RecognitionFixture(); defer { f.close() }; f.start()
            f.tracker.reconcile()
            if changeWindow { f.window = 8; f.now.addTimeInterval(2) }
            else { f.now.addTimeInterval(6) }
            let capturedAt = f.now; try await f.sample()
            XCTAssertEqual(f.tracker.current?.start, capturedAt)
            XCTAssertEqual(f.tracker.ledger.segments.first?.unknownReason, .waiting)
            XCTAssertEqual(f.tracker.ledger.segments.count, 2)
        }
        let f = try RecognitionFixture(); defer { f.close() }; f.start()
        f.tracker.reconcile(); f.now.addTimeInterval(2); f.delay = .milliseconds(70)
        f.tracker.sample(); try await Task.sleep(for: .milliseconds(10))
        // The application is unchanged, but the window changes before the reply arrives.
        f.window = 9
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(f.tracker.ledger.segments.first?.unknownReason, .waiting)
        XCTAssertEqual(f.tracker.ledger.segments.count, 2)
        XCTAssertEqual(f.tracker.current?.category, .unknown)
        XCTAssertEqual(f.tracker.recognitionDiagnostics.last?.code, "window_changed")
    }

    @MainActor func testFailureRecoveryPreservesFailureAndSeparatesModelUncertainty() async throws {
        let f = try RecognitionFixture(); defer { f.close() }; f.start()
        f.tracker.reconcile(); f.now.addTimeInterval(2)
        f.analysisError = AutomaticError.invalidResponse; try await f.sample()
        XCTAssertEqual(f.tracker.current?.unknownReason, .failure)
        XCTAssertEqual(f.tracker.recognitionDiagnostics.last?.stage, .classification)
        XCTAssertEqual(f.tracker.recognitionDiagnostics.last?.code, "invalid_response")
        f.analysisError = nil; f.now.addTimeInterval(5); let recovered = f.now
        try await f.sample()
        XCTAssertEqual(f.tracker.current?.start, recovered)
        XCTAssertTrue(f.tracker.ledger.segments.contains { $0.unknownReason == .failure && $0.seconds == 5 })
        f.app = ForegroundContext(pid: 43, bundleID: "test.blank", name: "空白页")
        f.tracker.reconcile(); f.now.addTimeInterval(2); f.category = .unknown
        try await f.sample()
        XCTAssertEqual(f.tracker.current?.unknownReason, .insufficientEvidence)
        XCTAssertEqual(f.tracker.recognitionDiagnostics.last?.outcome, .success)
        XCTAssertEqual(f.tracker.recognitionDiagnostics.last?.code, "insufficient_evidence")
    }

    @MainActor func testCancelledAttemptNeverClassifiesAnotherAppOrLeaksContent() async throws {
        let f = try RecognitionFixture(); defer { f.close() }; f.start()
        f.tracker.reconcile(); f.now.addTimeInterval(2); f.delay = .milliseconds(70)
        f.tracker.sample(); try await Task.sleep(for: .milliseconds(10))
        f.app = ForegroundContext(pid: 43, bundleID: "test.other", name: "另一个应用")
        f.now.addTimeInterval(1); f.tracker.reconcile()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(f.tracker.ledger.segments.contains { $0.category == .reading })
        XCTAssertEqual(f.tracker.recognitionDiagnostics.count, 1)
        XCTAssertEqual(f.tracker.recognitionDiagnostics.last?.outcome, .cancelled)
        XCTAssertEqual(f.tracker.recognitionDiagnostics.last?.code, "app_changed")
        let file = f.directory.appendingPathComponent("recognition-diagnostics.json")
        let raw = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        for secret in ["PRIVATE_IMAGE", Data("PRIVATE_IMAGE".utf8).base64EncodedString(), "test.reader", "阅读器", "http", "虚构阅读活动"] { XCTAssertFalse(raw.contains(secret)) }
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    @MainActor func testDiagnosticRetentionAndCorruptionDoNotDamageActivities() async throws {
        let f = try RecognitionFixture(); defer { f.close() }
        let file = f.directory.appendingPathComponent("recognition-diagnostics.json")
        let entries = (0..<205).map { _ in RecognitionDiagnostic(startedAt: f.now, endedAt: f.now, outcome: .success) }
        try JSONEncoder().encode(entries).write(to: file); f.start()
        XCTAssertEqual(f.tracker.recognitionDiagnostics.count, 200)
        f.captureError = AutomaticError.noWindow; try await f.sample()
        XCTAssertEqual(f.tracker.recognitionDiagnostics.count, 200)
        XCTAssertEqual(f.tracker.recognitionDiagnostics.last?.stage, .capture)
        XCTAssertEqual(f.tracker.recognitionDiagnostics.last?.code, "no_window")
        XCTAssertEqual(try JSONDecoder().decode([RecognitionDiagnostic].self, from: Data(contentsOf: file)).count, 200)
        f.tracker.shutdown(); f.tracker = nil
        let corrupt = Data("CORRUPT_DO_NOT_OVERWRITE".utf8); try corrupt.write(to: file)
        f.captureError = nil; f.start(); try await f.sample()
        XCTAssertNotNil(f.tracker.diagnosticWarning); XCTAssertTrue(f.tracker.config.enabled)
        XCTAssertEqual(f.tracker.current?.category, .reading)
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
        let store = FocusStore(directory: f.directory, startClock: false)
        let backup = try store.backupData(label: "test")
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("recognition-diagnostics.json")), corrupt)
        try f.tracker.clearActivities()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path)); XCTAssertTrue(f.tracker.recognitionDiagnostics.isEmpty)
    }
}
