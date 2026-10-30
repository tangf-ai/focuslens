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
        XCTAssertEqual(appearance.preferences.width, 290)
        XCTAssertEqual(appearance.preferences.radius, 16)
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
        XCTAssertEqual(appearance.preferences.width, 290)
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
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("floating-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let appearance = AppearanceStore(directory: directory), view = FocusFloatingContent()
        view.title.stringValue = "开发 · 一个很长的活动描述，不应超出浮窗"
        view.time.stringValue = "约 18 分钟"
        for theme in FocusTheme.allCases {
            for width in [290.0, 332, 360] {
                appearance.update { $0.theme = theme; $0.width = width }
                view.apply(appearance: appearance, active: true)
                view.frame = NSRect(origin: .zero, size: view.desiredSize)
                view.layoutSubtreeIfNeeded()
                XCTAssertEqual(view.desiredSize.height, 220)
                for child in view.subviews { XCTAssertTrue(view.bounds.contains(child.frame)) }
                XCTAssertEqual(view.title.stringValue, "开发 · 一个很长的活动描述，不应超出浮窗")
            }
        }
    }

}

private extension TaskKind { static let readingTestKind = TaskKind(rawValue: "阅读") }
