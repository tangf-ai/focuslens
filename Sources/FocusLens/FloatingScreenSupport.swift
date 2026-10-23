import AppKit

/// Geometry uses AppKit points, including displays left of or below the primary display.
enum FloatingPlacement {
    static func topRight(size: NSSize, in screen: NSRect) -> NSRect {
        recover(NSRect(x: screen.maxX - size.width - 24, y: screen.maxY - size.height - 24,
                       width: size.width, height: size.height), screens: [screen])
    }

    static func recover(_ frame: NSRect, screens: [NSRect], preferred: NSRect? = nil) -> NSRect {
        let screens = screens.filter { !$0.isEmpty && !$0.isInfinite && !$0.isNull }
        guard !screens.isEmpty else { return frame }
        // Select the display containing most of the panel, rather than the first display it touches.
        let overlaps = screens.map { screen -> CGFloat in
            let intersection = frame.intersection(screen)
            return intersection.isNull ? 0 : intersection.width * intersection.height
        }
        let best = overlaps.indices.max { overlaps[$0] < overlaps[$1] }!
        let screen = overlaps[best] > 0 ? screens[best] : preferred.flatMap { screens.contains($0) ? $0 : nil } ?? screens[0]
        let marginX = min(12, max(0, (screen.width - frame.width) / 2))
        let marginY = min(12, max(0, (screen.height - frame.height) / 2))
        let lowX = screen.minX + marginX, lowY = screen.minY + marginY
        let highX = max(lowX, screen.maxX - frame.width - marginX)
        let highY = max(lowY, screen.maxY - frame.height - marginY)
        return NSRect(x: min(max(frame.minX, lowX), highX), y: min(max(frame.minY, lowY), highY),
                      width: frame.width, height: frame.height)
    }
}

/// Event-driven recovery; there is no display polling and moving a panel never steals focus.
@MainActor
final class FloatingScreenSupport {
    private weak var panel: NSPanel?
    private var observer: NSObjectProtocol?
    static var currentScreen: NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    init(panel: NSPanel) {
        self.panel = panel
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                         object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.ensureVisible() }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func ensureVisible() {
        guard let panel else { return }
        let frame = FloatingPlacement.recover(panel.frame, screens: NSScreen.screens.map(\.visibleFrame),
                                             preferred: NSScreen.main?.visibleFrame)
        if frame != panel.frame { panel.setFrame(frame, display: false) }
    }

    func moveToCurrentScreen() {
        guard let panel, let screen = Self.currentScreen else { return }
        panel.setFrame(FloatingPlacement.topRight(size: panel.frame.size, in: screen.visibleFrame), display: false)
    }
}
