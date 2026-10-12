import AppKit
import Combine

private final class CountdownPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A small AppKit panel updates its text directly, without publishing per-second app state.
@MainActor
final class FloatingTimerController: NSObject {
    static let identifier = NSUserInterfaceItemIdentifier("FocusLensFloatingTimer")
    private weak var store: FocusStore?
    private var panel: CountdownPanel?
    private let timeLabel = NSTextField(labelWithString: "25:00")
    private let statusLabel = NSTextField(labelWithString: "专注中")
    private let pauseButton = NSButton()
    private var observation: AnyCancellable?
    private var visibilityObserver: NSObjectProtocol?
    private var displayTimer: Timer?
    private var currentRun: TimerRun?
    private var runID: UUID?
    private var hasFeedback = false
    private var restFinished = false
    private var dismissed = false
    private let accent = NSColor(red: 0.76, green: 0.31, blue: 0.19, alpha: 1)
    private let ink = NSColor(red: 0.16, green: 0.18, blue: 0.17, alpha: 1)
    private let muted = NSColor(red: 0.43, green: 0.45, blue: 0.43, alpha: 1)

    init(store: FocusStore) {
        self.store = store
        super.init()
        observation = store.$data.sink { [weak self] data in self?.update(data) }
    }

    deinit {
        displayTimer?.invalidate()
        if let visibilityObserver { NotificationCenter.default.removeObserver(visibilityObserver) }
    }

    func present() {
        guard currentRun != nil || hasFeedback || restFinished else { return }
        dismissed = false
        showPanel()
    }

    private func update(_ data: AppData) {
        let previousRun = currentRun
        currentRun = data.activeRun
        hasFeedback = data.pendingFeedback != nil
        if let run = currentRun {
            if run.id != runID { dismissed = false }
            runID = run.id
            restFinished = false
        } else if previousRun?.phase == .rest {
            restFinished = true
        }
        guard currentRun != nil || hasFeedback || restFinished else {
            hidePanel()
            runID = nil
            return
        }
        refreshText()
        if !dismissed { showPanel() }
        configureDisplayTimer()
    }

    private func makePanel() -> CountdownPanel {
        let panel = CountdownPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 84),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.identifier = Self.identifier
        panel.title = "专注镜 · 倒计时浮窗"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.isExcludedFromWindowsMenu = true
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .aqua)

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 84))
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.backgroundColor = NSColor(red: 0.98, green: 0.97, blue: 0.95, alpha: 1).cgColor
        content.layer?.borderColor = NSColor(red: 0.87, green: 0.87, blue: 0.84, alpha: 1).cgColor
        content.layer?.borderWidth = 1
        panel.contentView = content

        statusLabel.frame = NSRect(x: 16, y: 56, width: 180, height: 15)
        statusLabel.font = .systemFont(ofSize: 10, weight: .medium)
        statusLabel.textColor = muted
        timeLabel.frame = NSRect(x: 14, y: 12, width: 145, height: 41)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 33, weight: .light)
        timeLabel.textColor = ink
        content.addSubview(statusLabel)
        content.addSubview(timeLabel)

        configure(pauseButton, symbol: "pause.fill", tooltip: "暂停", action: #selector(togglePause),
                  frame: NSRect(x: 163, y: 18, width: 28, height: 28))
        content.addSubview(pauseButton)
        let openButton = NSButton()
        configure(openButton, symbol: "arrow.up.right.square", tooltip: "返回主窗口", action: #selector(openMainWindow),
                  frame: NSRect(x: 199, y: 18, width: 28, height: 28))
        content.addSubview(openButton)
        let closeButton = NSButton()
        configure(closeButton, symbol: "xmark", tooltip: "隐藏浮窗（继续计时）", action: #selector(dismiss),
                  frame: NSRect(x: 212, y: 55, width: 16, height: 16))
        content.addSubview(closeButton)

        let restored = panel.setFrameUsingName("FocusLensFloatingTimer")
        if !restored || !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) {
            let screen = NSScreen.main ?? NSScreen.screens.first
            if let frame = screen?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: frame.maxX - 264, y: frame.maxY - 108))
            }
        }
        panel.setFrameAutosaveName("FocusLensFloatingTimer")
        visibilityObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
            object: panel, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshText()
                    self?.configureDisplayTimer()
                }
            }
        return panel
    }

    private func configure(_ button: NSButton, symbol: String, tooltip: String, action: Selector, frame: NSRect) {
        button.frame = frame
        button.title = ""
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.contentTintColor = muted
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        button.target = self
        button.action = action
    }

    private func showPanel() {
        if panel == nil { panel = makePanel() }
        refreshText()
        if panel?.isVisible != true { panel?.orderFrontRegardless() }
        configureDisplayTimer()
    }

    private func hidePanel() {
        displayTimer?.invalidate()
        displayTimer = nil
        panel?.orderOut(nil)
    }

    private func configureDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
        guard let run = currentRun, !run.isPaused, !dismissed,
              let panel, panel.isVisible, panel.occlusionState.contains(.visible) else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshTime() }
        }
        timer.tolerance = 0.15
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    private func refreshTime() {
        let text = currentRun.map { clockText($0.remaining(at: Date())) } ?? "00:00"
        if timeLabel.stringValue != text { timeLabel.stringValue = text }
    }

    private func refreshText() {
        refreshTime()
        if let run = currentRun {
            statusLabel.stringValue = run.isPaused ? "已暂停" : (run.phase == .focus ? "专注中" : "休息中")
            timeLabel.textColor = run.isPaused ? muted : ink
            pauseButton.isHidden = false
            let title = run.isPaused ? "继续" : "暂停"
            pauseButton.image = NSImage(systemSymbolName: run.isPaused ? "play.fill" : "pause.fill", accessibilityDescription: title)
            pauseButton.toolTip = title
            pauseButton.setAccessibilityLabel(title)
        } else {
            statusLabel.stringValue = hasFeedback ? "专注结束 · 待填写反馈" : "休息结束"
            timeLabel.textColor = accent
            pauseButton.isHidden = true
        }
    }

    @objc private func togglePause() { store?.togglePause() }
    @objc private func openMainWindow() { store?.restoreMainWindow() }
    @objc private func dismiss() { dismissed = true; hidePanel() }
}
