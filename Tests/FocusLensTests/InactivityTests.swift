import Foundation

@MainActor private final class InactivityFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("inactivity-" + UUID().uuidString)
    var now = Date()
    var elapsed: TimeInterval = 0
    var captures = 0
    var category: ActivityCategory = .development
    var delayed = false
    var tracker: AutomaticTracker!
    init(policy: InactivitySettings = InactivitySettings()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var config = AutomaticConfig(); config.ai = AISettings(baseURL: "http://127.0.0.1:9/v1", model: "fixture")
        config.inactivitySettings = policy
        config.enabled = true; config.verifiedSignature = VisionService.signature(config); config.consentSignature = config.verifiedSignature
        try JSONEncoder().encode(config).write(to: directory.appendingPathComponent("automatic-settings.json"))
        tracker = AutomaticTracker(directory: directory, startClock: false, idleSeconds: { [unowned self] in self.elapsed }, now: { [unowned self] in self.now }, permission: { true }, sessionAvailable: { true }, foreground: {
            ForegroundContext(pid: 42, bundleID: "fixture.app", name: "虚构应用")
        }, capture: { [unowned self] _ in
            self.captures += 1
            return MemoryScreenCapture.Frame(jpeg: Data([1]), fingerprint: Data([1]), contextKey: "same-window", capturedAt: self.now)
        }, analyze: { [unowned self] _, _, _ in
            if self.delayed { try? await Task.sleep(for: .milliseconds(80)) }
            return ActivityClassification(category: self.category, title: "虚构活动")
        })
    }
    func sample(after seconds: TimeInterval = 0) async throws {
        now.addTimeInterval(seconds); elapsed += seconds
        tracker.sample(); try await Task.sleep(for: .milliseconds(20))
    }
    func close() { tracker.shutdown(); try? FileManager.default.removeItem(at: directory) }
    var total: TimeInterval { tracker.ledger.segments.reduce(0) { $0 + $1.seconds } }
}

extension FocusLensTests {
    func testInactivityDefaultsCompatibilityAndNativeCounter() throws {
        let old = try JSONEncoder().encode(AutomaticConfig())
        var config = try JSONDecoder().decode(AutomaticConfig.self, from: old)
        XCTAssertNil(config.inactivity)
        XCTAssertEqual(config.inactivitySettings.timeout(for: .development), 300)
        XCTAssertEqual(config.inactivitySettings.timeout(for: .reading), 900)
        XCTAssertEqual(config.inactivitySettings.timeout(for: .video), 1800)
        let signature = VisionService.signature(config)
        config.inactivitySettings.readingMinutes = 0
        config.inactivitySettings.videoMinutes = 0
        XCTAssertNil(config.inactivitySettings.timeout(for: .reading)); XCTAssertNil(config.inactivitySettings.timeout(for: .video))
        XCTAssertEqual(VisionService.signature(config), signature)
        config.inactivitySettings.enabled = false
        XCTAssertNil(config.inactivitySettings.timeout(for: .development))
        XCTAssertEqual(try JSONDecoder().decode(AutomaticConfig.self, from: JSONEncoder().encode(config)), config)
        config.inactivitySettings.minutes = 999
        XCTAssertEqual(config.inactivitySettings.minutes, 5)
        let elapsed = SystemInactivity.seconds()
        XCTAssertTrue(elapsed.isFinite && elapsed >= 0)
    }

    @MainActor func testInactivityPausesAtBoundaryResumesAndConfirmsOnce() async throws {
        let f = try InactivityFixture(); defer { f.close() }
        let start = f.now
        try await f.sample()
        for _ in 0..<4 { try await f.sample(after: 60) }
        XCTAssertEqual(f.tracker.current?.category, .development)
        try await f.sample(after: 65)
        XCTAssertEqual(f.tracker.status, .inactive); XCTAssertNil(f.tracker.current)
        XCTAssertEqual(f.total, 300, accuracy: 0.01)
        XCTAssertEqual(f.captures, 5)
        XCTAssertEqual(f.tracker.inactivityPeriods.first?.start, start.addingTimeInterval(300))
        try await f.sample(after: 60)
        XCTAssertEqual(f.captures, 5); XCTAssertEqual(f.total, 300, accuracy: 0.01)
        XCTAssertFalse(f.tracker.canRefresh)
        f.now.addTimeInterval(10); f.elapsed = 0; f.tracker.checkInactivity()
        XCTAssertEqual(f.tracker.status, .waiting)
        let period = try XCTUnwrap(f.tracker.pendingInactivityPeriods.first)
        XCTAssertEqual(period.seconds, 75, accuracy: 0.01)
        XCTAssertEqual(f.total, 300, accuracy: 0.01)
        try await f.sample()
        XCTAssertEqual(f.tracker.status, .recording)
        f.tracker.resolveInactivity(id: period.id, wasPresent: true)
        XCTAssertEqual(f.total, 375, accuracy: 0.01)
        f.tracker.resolveInactivity(id: period.id, wasPresent: true)
        XCTAssertEqual(f.total, 375, accuracy: 0.01)
        XCTAssertTrue(f.tracker.pendingInactivityPeriods.isEmpty)
        let restored = AutomaticTracker(directory: f.directory, startClock: false, idleSeconds: { 0 }, now: { f.now })
        XCTAssertEqual(restored.ledger.segments.reduce(0) { $0 + $1.seconds }, 375, accuracy: 0.01)
        XCTAssertTrue(restored.ledger.segments.contains { $0.corrected && $0.seconds == 75 })
    }

    @MainActor func testInactivityReadingVideoExemptionAndManualPause() async throws {
        var policy = InactivitySettings(); policy.readingMinutes = 0; policy.videoMinutes = 0
        let f = try InactivityFixture(policy: policy); defer { f.close() }
        f.category = .reading; try await f.sample()
        for _ in 0..<16 { try await f.sample(after: 60) }
        XCTAssertEqual(f.tracker.status, .recording); XCTAssertTrue(f.tracker.inactivityPeriods.isEmpty)
        XCTAssertEqual(f.total, 960, accuracy: 0.01)
        f.tracker.pause(); f.elapsed = 0; f.now.addTimeInterval(20); f.tracker.checkInactivity()
        XCTAssertEqual(f.tracker.status, .paused)
        f.tracker.resume(); try await f.sample()
        f.tracker.setManualBlocked(true, at: f.now)
        f.elapsed = 9999; f.tracker.reconcile(); f.tracker.sample()
        XCTAssertEqual(f.tracker.status, .manual); XCTAssertTrue(f.tracker.inactivityPeriods.isEmpty)
        // A disabled detector keeps recording even if the system counter is large.
        var draft = f.tracker.config; draft.inactivitySettings.enabled = false
        XCTAssertTrue(f.tracker.saveConfig(draft, newKey: nil))
        f.tracker.setManualBlocked(false, at: f.now); try await f.sample()
        XCTAssertEqual(f.tracker.status, .recording)
    }

    @MainActor func testInactivityReadingUsesLongerDefaultAndNoOfflineFill() async throws {
        let f = try InactivityFixture(); defer { f.close() }
        f.category = .reading; try await f.sample()
        for _ in 0..<14 { try await f.sample(after: 60) }
        XCTAssertEqual(f.tracker.status, .recording)
        try await f.sample(after: 65)
        XCTAssertEqual(f.tracker.status, .inactive)
        let first = try XCTUnwrap(f.tracker.inactivityPeriods.first)
        XCTAssertEqual(first.seconds, 5, accuracy: 0.01)
        f.now.addTimeInterval(7200); f.elapsed += 7200; f.tracker.checkInactivity()
        XCTAssertEqual(f.tracker.pendingInactivityPeriods.first?.seconds, 5)
        XCTAssertEqual(f.tracker.inactivityPeriods.last?.start, f.now)
        XCTAssertEqual(f.tracker.inactivityPeriods.last?.seconds, 0)
    }

    @MainActor func testInactivityLateResultLockAndAwayDecision() async throws {
        let f = try InactivityFixture(); defer { f.close() }
        try await f.sample()
        for _ in 0..<4 { try await f.sample(after: 60) }
        // Invalidate the image cache by saving guidance, then leave during inference.
        var draft = f.tracker.config; draft.workBackground = "虚构开发背景"
        XCTAssertTrue(f.tracker.saveConfig(draft, newKey: nil))
        f.delayed = true; f.tracker.sample()
        try await Task.sleep(for: .milliseconds(20))
        f.now.addTimeInterval(65); f.elapsed += 65; f.tracker.checkInactivity()
        XCTAssertEqual(f.tracker.status, .inactive)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(f.tracker.status, .inactive); XCTAssertNil(f.tracker.current)
        f.now.addTimeInterval(30); f.elapsed += 30; f.tracker.setLifecycleBlock("lock", blocked: true)
        XCTAssertEqual(f.tracker.status, .away)
        let gap = try XCTUnwrap(f.tracker.pendingInactivityPeriods.first)
        let before = f.total
        f.now.addTimeInterval(3600); f.elapsed = 0; f.tracker.setLifecycleBlock("lock", blocked: false)
        XCTAssertEqual(f.tracker.inactivityPeriods.first?.seconds, gap.seconds)
        f.tracker.resolveInactivity(id: gap.id, wasPresent: false)
        XCTAssertEqual(f.total, before, accuracy: 0.01)
        XCTAssertTrue(f.tracker.pendingInactivityPeriods.isEmpty)
    }

    @MainActor func testInactivityCrashRecoveryMidnightAndCorruptJournal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("idle-recovery-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let midnight = calendar.startOfDay(for: now)
        var period = InactivityPeriod(start: midnight.addingTimeInterval(-60), end: midnight.addingTimeInterval(60), observedThrough: midnight.addingTimeInterval(60), category: .reading, title: "书籍", app: "阅读器", bundleID: "reader")
        period.resolution = .present; period.restoredSegments = period.segmentsForConfirmation()
        XCTAssertEqual(period.restoredSegments.count, 2)
        var open = InactivityPeriod(start: now.addingTimeInterval(-120), observedThrough: now.addingTimeInterval(-60), category: .video, title: "课程", app: "播放器", bundleID: "video")
        open.end = nil
        let file = directory.appendingPathComponent("automatic-idle-periods.json")
        try JSONEncoder().encode([period, open]).write(to: file)
        let first = AutomaticTracker(directory: directory, startClock: false, idleSeconds: { 0 })
        XCTAssertNil(first.errorMessage)
        XCTAssertEqual(first.ledger.segments.reduce(0) { $0 + $1.seconds }, 120)
        XCTAssertEqual(first.pendingInactivityPeriods.first?.seconds, 60)
        let second = AutomaticTracker(directory: directory, startClock: false, idleSeconds: { 0 })
        XCTAssertEqual(second.ledger.segments.count, 2)
        XCTAssertEqual(second.ledger.segments.reduce(0) { $0 + $1.seconds }, 120)
        let corrupt = Data("broken-idle-journal".utf8); try corrupt.write(to: file)
        let broken = AutomaticTracker(directory: directory, startClock: false, idleSeconds: { 0 })
        XCTAssertNotNil(broken.errorMessage); XCTAssertFalse(broken.persist())
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }
}
