import AppKit
import Observation

extension FocusLensTests {
    @MainActor func testAppearanceDefaultsPersistenceAndIsolation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("appearance-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data("original-focus-records".utf8)
        try original.write(to: directory.appendingPathComponent("focus-data.json"))
        let appearance = AppearanceStore(directory: directory)
        XCTAssertEqual(appearance.preferences.theme, .silver)
        XCTAssertEqual(appearance.preferences.style, .ring)
        XCTAssertEqual(appearance.preferences.width, 332)
        XCTAssertEqual(appearance.preferences.radius, 27)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("appearance-settings.json").path))
        appearance.update { $0.theme = .night; $0.style = .rail; $0.glow = false; $0.width = 360 }
        let restored = AppearanceStore(directory: directory)
        XCTAssertEqual(restored.preferences, appearance.preferences)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("focus-data.json")), original)
        let isolated = AppearanceStore(directory: directory.appendingPathComponent("isolated"))
        XCTAssertEqual(isolated.preferences.theme, .silver)
        let settings = try String(contentsOf: directory.appendingPathComponent("appearance-settings.json"), encoding: .utf8)
        XCTAssertFalse(settings.contains("baseURL")); XCTAssertFalse(settings.contains("apiKey"))
    }

    @MainActor func testAppearanceCorruptionAndObservation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("appearance-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let appearance = AppearanceStore(directory: directory)
        final class Flag { var changed = false }
        let flag = Flag()
        withObservationTracking { _ = Theme.accent } onChange: { flag.changed = true }
        appearance.update { $0.theme = .jade; $0.width = .nan; $0.radius = 500 }
        XCTAssertTrue(flag.changed)
        XCTAssertEqual(appearance.preferences.width, 332)
        XCTAssertEqual(appearance.preferences.radius, 36)
        let file = directory.appendingPathComponent("appearance-settings.json"), broken = Data("broken-file".utf8)
        try broken.write(to: file)
        let bad = AppearanceStore(directory: directory)
        XCTAssertTrue(bad.errorMessage != nil)
        bad.update { $0.theme = .lilac }
        XCTAssertEqual(try Data(contentsOf: file), broken)
    }

    func testDecorativeMotionPolicyAndThemeContrast() {
        var preferences = AppearancePreferences()
        XCTAssertTrue(preferences.animates(active: true, visible: true, reducedMotion: false, lowPower: false))
        for input in [(false,true,false,false),(true,false,false,false),(true,true,true,false),(true,true,false,true)] {
            XCTAssertFalse(preferences.animates(active: input.0, visible: input.1, reducedMotion: input.2, lowPower: input.3))
        }
        preferences.followsReducedMotion = false
        XCTAssertTrue(preferences.animates(active: true, visible: true, reducedMotion: true, lowPower: false))
        XCTAssertFalse(preferences.animates(active: true, visible: true, reducedMotion: true, lowPower: true))
        preferences.gentleMotion = false
        XCTAssertFalse(preferences.animates(active: true, visible: true, reducedMotion: false, lowPower: false))
        func luminance(_ hex: UInt32) -> Double {
            let channels = [Double((hex >> 16) & 255),Double((hex >> 8) & 255),Double(hex & 255)].map { $0 / 255 }.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
        }
        func contrast(_ a: UInt32, _ b: UInt32) -> Double { let x = luminance(a), y = luminance(b); return (max(x,y) + 0.05) / (min(x,y) + 0.05) }
        for theme in FocusTheme.allCases {
            XCTAssertTrue(contrast(theme.palette.ink, theme.palette.paper) > 7)
            XCTAssertTrue(contrast(theme.palette.muted, theme.palette.floating) >= 4.5)
            XCTAssertTrue(contrast(theme.palette.accentInk, theme.palette.accent) >= 4.5)
        }
    }

    @MainActor func testFloatingAppearanceLayoutsAndFrozenMotion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("appearance-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let appearance = AppearanceStore(directory: directory), view = FocusFloatingContent()
        view.time.stringValue = "约 18:42"; view.detail.stringValue = "后台更新中 · 已用 2 秒"
        for theme in FocusTheme.allCases {
            for style in FloatingStyle.allCases {
                for width in [290.0,332,360] {
                    for hasTitle in [false,true] {
                        appearance.update { $0.theme = theme; $0.style = style; $0.width = width }
                        view.title.stringValue = hasTitle ? "阅读 · 一个很长的目标描述，不应超出浮窗" : ""
                        view.apply(appearance: appearance, active: false, visible: true)
                        view.frame = NSRect(origin: .zero, size: view.desiredSize); view.needsLayout = true; view.layoutSubtreeIfNeeded()
                        for child in view.subviews where !child.isHidden { XCTAssertTrue(view.bounds.contains(child.frame)) }
                        XCTAssertFalse(view.decorating)
                        XCTAssertEqual(view.title.isHidden, !hasTitle)
                    }
                }
            }
        }
        view.apply(appearance: appearance, active: true, visible: false)
        XCTAssertFalse(view.decorating)
        view.apply(appearance: appearance, active: true, visible: true)
        let expected = appearance.preferences.animates(active: true, visible: true, reducedMotion: appearance.reducedMotion, lowPower: appearance.lowPower)
        XCTAssertEqual(view.decorating, expected)
        view.apply(appearance: appearance, active: false, visible: true)
        XCTAssertEqual(view.layer?.sublayers?.first?.speed, 0)
        view.setProgress(.nan, visible: true); XCTAssertEqual(view.ring.fraction, 0)
        view.setProgress(3, visible: true); XCTAssertEqual(view.ring.fraction, 1)
    }

    @MainActor func testFloatingControllerKeepsGoalAtFeedbackAndAppearanceChange() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("appearance-controller-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FocusStore(directory: directory, startClock: false)
        let floating = FloatingTimerController(store: store)
        store.start(goal: "验证目标保留", kind: .writing, minutes: 5)
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier == FloatingTimerController.identifier })
        defer { panel.close(); withExtendedLifetime(floating) {} }
        let view = try XCTUnwrap(panel.contentView as? FocusFloatingContent)
        XCTAssertEqual(view.title.stringValue, "验证目标保留")
        store.appearance.update { $0.theme = .night; $0.style = .rail }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(view.ring.isHidden)
        XCTAssertEqual(view.desiredSize.height, 300)
        store.finish()
        XCTAssertEqual(view.title.stringValue, "验证目标保留")
        XCTAssertTrue(view.status.stringValue.contains("写作"))
        XCTAssertTrue(view.pause.isHidden)
        store.saveFeedback(outcome: .completed, rating: nil, note: "")
        XCTAssertFalse(panel.isVisible)
        store.start(goal: "", kind: .readingTestKind, minutes: 5)
        XCTAssertTrue(view.title.isHidden)
        XCTAssertEqual(view.desiredSize.height, 276)
    }
}

private extension TaskKind { static let readingTestKind = TaskKind(rawValue: "阅读") }
