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
        XCTAssertEqual(appearance.preferences.width, 250)
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
        XCTAssertEqual(appearance.preferences.width, 250)
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
            for width in [220.0, 250, 290, 332, 360] {
                appearance.update { $0.theme = theme; $0.width = width }
                view.apply(appearance: appearance, active: true)
                for mode in FloatingDisplayMode.allCases {
                    view.mode = mode
                    view.frame = NSRect(origin: .zero, size: view.desiredSize)
                    view.layoutSubtreeIfNeeded()
                    for child in view.subviews where !child.isHidden { XCTAssertTrue(view.bounds.contains(child.frame)) }
                }
                view.mode = .compact
                XCTAssertEqual(view.desiredSize, NSSize(width: 148, height: 32))
                XCTAssertEqual(view.title.stringValue, "开发 · 一个很长的活动描述，不应超出浮窗")
            }
        }
    }

    @MainActor func testCapsuleFocusAndEdgeGeometry() {
        let panel = FocusFloatingPanel(contentRect: NSRect(x: 200, y: 200, width: 148, height: 32),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        XCTAssertFalse(panel.canBecomeKey); XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        let left = NSRect(x: -1080, y: -200, width: 1080, height: 1920)
        let compact = NSRect(x: -1080, y: 500, width: 148, height: 32)
        XCTAssertEqual(FloatingPlacement.dockEdge(for: compact, in: left), .left)
        let expanded = FloatingPlacement.resized(compact, to: NSSize(width: 220, height: 144), edge: .left)
        XCTAssertEqual(expanded.minX, compact.minX); XCTAssertEqual(expanded.maxY, compact.maxY)
        let docked = FloatingPlacement.resized(expanded, to: NSSize(width: 8, height: 36), edge: .left)
        XCTAssertEqual(FloatingPlacement.recover(docked, screens: [left], margin: 0), docked)
        let right = NSRect(x: -148, y: 500, width: 148, height: 32)
        XCTAssertEqual(FloatingPlacement.dockEdge(for: right, in: left), .right)
        let fromRight = FloatingPlacement.resized(right, to: NSSize(width: 220, height: 144))
        XCTAssertEqual(fromRight.maxX, right.maxX); XCTAssertEqual(fromRight.maxY, right.maxY)
        XCTAssertNil(FloatingPlacement.dockEdge(for: NSRect(x: -500, y: 500, width: 148, height: 32), in: left))
    }

    @MainActor func testCapsuleControllerTransitionsAndActions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("capsule-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = AutomaticConfig(); config.enabled = true
        try JSONEncoder().encode(config).write(to: directory.appendingPathComponent("automatic-settings.json"))
        let tracker = AutomaticTracker(directory: directory, startClock: false, permission: { false })
        let controller = ActivityFloatingController(tracker: tracker)
        defer { controller.shutdown(); tracker.shutdown() }
        controller.present()
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier == ActivityFloatingController.identifier })
        let content = try XCTUnwrap(panel.contentView as? FocusFloatingContent)
        XCTAssertFalse(content.pause.needsPanelToBecomeKey)
        XCTAssertTrue(content.pause.acceptsFirstMouse(for: nil))
        XCTAssertEqual(panel.frame.size, NSSize(width: 148, height: 32))
        let keyWindow = NSApp.keyWindow
        content.onClick?()
        XCTAssertEqual(panel.frame.size, NSSize(width: 220, height: 144))
        XCTAssertTrue(NSApp.keyWindow === keyWindow)
        // Dispatch the real action without performClick's nested AppKit feedback run loop.
        NSApp.sendAction(content.pause.action!, to: content.pause.target, from: content.pause)
        XCTAssertEqual(tracker.status, .paused)
        controller.refresh()
        XCTAssertEqual(content.pause.title, "恢复")
        NSApp.sendAction(content.dock.action!, to: content.dock.target, from: content.dock)
        XCTAssertEqual(panel.frame.size, NSSize(width: 8, height: 36))
        XCTAssertEqual(content.mode, .docked)
        controller.refresh()
        XCTAssertEqual(content.mode, .docked)
        content.onClick?()
        XCTAssertEqual(panel.frame.size, NSSize(width: 148, height: 32))
        content.onClick?()
        var opened = false; tracker.openMain = { opened = true }
        NSApp.sendAction(content.open.action!, to: content.open.target, from: content.open); XCTAssertTrue(opened)
        NSApp.sendAction(content.close.action!, to: content.close.target, from: content.close); XCTAssertFalse(panel.isVisible)
        controller.refresh(); XCTAssertFalse(panel.isVisible)
        controller.present(); XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(content.mode, .compact)
        XCTAssertTrue(NSApp.keyWindow === keyWindow)
        controller.shutdown(); controller.refresh(); XCTAssertFalse(panel.isVisible)
    }

    @MainActor func testCapsuleHoverDelayCancellationAndRetraction() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("capsule-hover-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = AutomaticConfig(); config.enabled = true
        try JSONEncoder().encode(config).write(to: directory.appendingPathComponent("automatic-settings.json"))
        let tracker = AutomaticTracker(directory: directory, startClock: false, permission: { false })
        var pointer = NSPoint(x: -50000, y: -50000)
        let controller = ActivityFloatingController(tracker: tracker, pointerLocation: { pointer })
        defer { controller.shutdown(); tracker.shutdown() }
        controller.present()
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier == ActivityFloatingController.identifier })
        let content = try XCTUnwrap(panel.contentView as? FocusFloatingContent)
        pointer = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        content.onHover?(true)
        XCTAssertEqual(content.mode, .compact)
        try await Task.sleep(for: .milliseconds(420))
        XCTAssertEqual(content.mode, .expanded)
        // Moving within the expanded surface must not collapse it.
        pointer = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        content.onHover?(false)
        try await Task.sleep(for: .milliseconds(570))
        XCTAssertEqual(content.mode, .expanded)
        pointer = NSPoint(x: -50000, y: -50000)
        content.onHover?(false)
        try await Task.sleep(for: .milliseconds(570))
        XCTAssertEqual(content.mode, .compact)
        pointer = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        content.onHover?(true); content.onHover?(false)
        pointer = NSPoint(x: -50000, y: -50000)
        try await Task.sleep(for: .milliseconds(420))
        XCTAssertEqual(content.mode, .compact)
        content.onHover?(true)
        controller.shutdown()
        try await Task.sleep(for: .milliseconds(420))
        XCTAssertFalse(panel.isVisible)
    }

}

private extension TaskKind { static let readingTestKind = TaskKind(rawValue: "阅读") }
