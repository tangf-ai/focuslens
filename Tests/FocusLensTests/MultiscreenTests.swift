import AppKit

extension FocusLensTests {
    func testPortraitDisplayAndRemovedDisplayRecovery() {
        let main = NSRect(x: 0, y: 81, width: 1920, height: 969)
        let left = NSRect(x: -1080, y: -401, width: 1080, height: 1920)
        let saved = NSRect(x: -1040, y: 1100, width: 320, height: 268)
        XCTAssertEqual(FloatingPlacement.recover(saved, screens: [main, left], preferred: main), saved)
        let recovered = FloatingPlacement.recover(saved, screens: [main], preferred: main)
        XCTAssertTrue(main.contains(recovered))
        XCTAssertEqual(recovered.size, saved.size)
        XCTAssertEqual(FloatingPlacement.recover(recovered, screens: [main]), recovered)
        let reconnected = FloatingPlacement.recover(recovered, screens: [main, left])
        XCTAssertEqual(reconnected, recovered)
    }

    func testPanelPlacementUsesDominantDisplayAndPoints() {
        let main = NSRect(x: 0, y: 24, width: 1440, height: 850)
        let left = NSRect(x: -1080, y: -200, width: 1080, height: 1920)
        let straddling = NSRect(x: -300, y: 300, width: 320, height: 268)
        let moved = FloatingPlacement.recover(straddling, screens: [main, left], preferred: main)
        XCTAssertTrue(left.contains(moved))
        let onRetina = FloatingPlacement.topRight(size: NSSize(width: 320, height: 268), in: left)
        XCTAssertEqual(onRetina.size, NSSize(width: 320, height: 268))
        XCTAssertTrue(left.contains(onRetina))
        let shifted = NSRect(x: 2100, y: -900, width: 1680, height: 1050)
        let movedAgain = FloatingPlacement.recover(onRetina, screens: [main, shifted], preferred: shifted)
        XCTAssertTrue(shifted.contains(movedAgain))
        XCTAssertEqual(FloatingPlacement.recover(movedAgain, screens: []), movedAgain)
    }

    func testCaptureSelectsFrontWindowAcrossDisplays() {
        let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let left = CGRect(x: -1080, y: -400, width: 1080, height: 1920)
        let onMain = captureWindow(id: 1, pid: 42, frame: CGRect(x: 100, y: 100, width: 800, height: 600))
        let onLeft = captureWindow(id: 2, pid: 42, frame: CGRect(x: -1000, y: -300, width: 900, height: 1200))
        XCTAssertEqual(MemoryScreenCapture.frontWindowID(in: [onLeft,onMain], pid: 42, displayBounds: [main,left]), 2)
        XCTAssertEqual(MemoryScreenCapture.frontWindowID(in: [onMain,onLeft], pid: 42, displayBounds: [main,left]), 1)
        // The disconnected display's old window is ignored even if WindowServer lists it.
        XCTAssertEqual(MemoryScreenCapture.frontWindowID(in: [onLeft,onMain], pid: 42, displayBounds: [main]), 1)
        let spanning = captureWindow(id: 3, pid: 42, frame: CGRect(x: -300, y: 100, width: 800, height: 600))
        XCTAssertEqual(MemoryScreenCapture.frontWindowID(in: [spanning,onMain], pid: 42, displayBounds: [main,left]), 3)
        XCTAssertNil(MemoryScreenCapture.frontWindowID(in: [onMain], pid: 42, displayBounds: []))
    }

    func testCaptureSkipsUnrelatedOverlayAndHiddenWindows() {
        let bounds = [CGRect(x: 0, y: 0, width: 1920, height: 1080)]
        let frame = CGRect(x: 50, y: 50, width: 800, height: 600)
        let otherApp = captureWindow(id: 1, pid: 99, frame: frame)
        var overlay = captureWindow(id: 2, pid: 42, frame: frame); overlay[kCGWindowLayer as String] = 3
        var hidden = captureWindow(id: 3, pid: 42, frame: frame); hidden[kCGWindowAlpha as String] = 0.0
        let tiny = captureWindow(id: 4, pid: 42, frame: CGRect(x: 0, y: 0, width: 30, height: 30))
        let normal = captureWindow(id: 5, pid: 42, frame: frame)
        XCTAssertEqual(MemoryScreenCapture.frontWindowID(in: [otherApp,overlay,hidden,tiny,normal], pid: 42, displayBounds: bounds), 5)
    }

    @MainActor func testScreenChangeRecoversHiddenPanelWithoutShowingIt() async throws {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: NSRect(x: 50000, y: 50000, width: 320, height: 268),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let support = FloatingScreenSupport(panel: panel)
        defer { panel.close(); withExtendedLifetime(support) {} }
        XCTAssertFalse(panel.isVisible)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(NSScreen.screens.contains { $0.visibleFrame.contains(panel.frame) })
        XCTAssertFalse(panel.isVisible)
        let size = panel.frame.size
        support.moveToCurrentScreen()
        XCTAssertEqual(panel.frame.size, size)
        XCTAssertTrue(FloatingScreenSupport.currentScreen!.visibleFrame.contains(panel.frame))
    }

    private func captureWindow(id: UInt32, pid: Int, frame: CGRect) -> [String: Any] {
        [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid,
         kCGWindowLayer as String: 0, kCGWindowAlpha as String: 1.0,
         kCGWindowBounds as String: frame.dictionaryRepresentation as NSDictionary]
    }
}
