import AppKit
import Combine

private final class CountdownPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A quiet, decreasing time rail. Drawing is limited to the small progress region.
private final class RemainingTimeRail: NSView {
    var fraction = 1.0 { didSet { if fraction != oldValue { needsDisplay = true } } }
    var tint = NSColor(red: 0.76, green: 0.31, blue: 0.19, alpha: 1) {
        didSet { if tint != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: 4, y: 11, width: max(0, bounds.width - 8), height: 6)
        NSColor(red: 0.89, green: 0.90, blue: 0.87, alpha: 1).setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        let width = track.width * min(1, max(0, fraction))
        if width > 0 {
            tint.setFill()
            let fill = NSRect(x: track.minX, y: track.minY, width: width, height: track.height)
            NSBezierPath(roundedRect: fill, xRadius: min(3, width / 2), yRadius: 3).fill()
            NSBezierPath(ovalIn: NSRect(x: track.minX + width - 4, y: track.midY - 4, width: 8, height: 8)).fill()
        }
        NSColor(red: 0.80, green: 0.82, blue: 0.79, alpha: 1).setStroke()
        for index in 0...4 {
            let x = track.minX + track.width * Double(index) / 4
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: x, y: 1))
            tick.line(to: NSPoint(x: x, y: 5))
            tick.lineWidth = 0.75
            tick.stroke()
        }
    }
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
    private let planLabel = NSTextField(labelWithString: "25 分钟")
    private let progressLabel = NSTextField(labelWithString: "剩余时间")
    private let percentLabel = NSTextField(labelWithString: "100%")
    private let progressRail = RemainingTimeRail()
    private let statusDot = NSView()
    private let panelSize = NSSize(width: 320, height: 168)
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
        let panel = CountdownPanel(contentRect: NSRect(origin: .zero, size: panelSize),
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

        let content = NSView(frame: NSRect(origin: .zero, size: panelSize))
        content.wantsLayer = true
        content.layer?.cornerRadius = 20
        content.layer?.backgroundColor = NSColor(red: 0.985, green: 0.98, blue: 0.965, alpha: 1).cgColor
        content.layer?.borderColor = NSColor(red: 0.88, green: 0.89, blue: 0.86, alpha: 1).cgColor
        content.layer?.borderWidth = 0.75
        panel.contentView = content

        statusDot.frame = NSRect(x: 21, y: 143, width: 7, height: 7)
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3.5
        statusDot.layer?.backgroundColor = accent.cgColor
        statusDot.setAccessibilityElement(false)
        statusLabel.frame = NSRect(x: 34, y: 137, width: 160, height: 18)
        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = muted
        planLabel.frame = NSRect(x: 202, y: 138, width: 76, height: 16)
        planLabel.font = .systemFont(ofSize: 10, weight: .regular)
        planLabel.textColor = muted
        planLabel.alignment = .right
        timeLabel.frame = NSRect(x: 18, y: 65, width: 201, height: 63)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 50, weight: .light)
        timeLabel.textColor = ink
        progressLabel.frame = NSRect(x: 20, y: 42, width: 190, height: 16)
        progressLabel.font = .systemFont(ofSize: 10, weight: .regular)
        progressLabel.textColor = muted
        percentLabel.frame = NSRect(x: 224, y: 42, width: 76, height: 16)
        percentLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        percentLabel.textColor = muted
        percentLabel.alignment = .right
        progressRail.frame = NSRect(x: 20, y: 16, width: 280, height: 20)
        progressRail.setAccessibilityElement(true)
        progressRail.setAccessibilityRole(.progressIndicator)
        progressRail.setAccessibilityLabel("剩余时间比例")
        progressRail.setAccessibilityValue(percentLabel.stringValue)
        for view in [statusDot, statusLabel, planLabel, timeLabel, progressLabel, percentLabel, progressRail] {
            content.addSubview(view)
        }

        configure(pauseButton, symbol: "pause.fill", tooltip: "暂停", action: #selector(togglePause),
                  frame: NSRect(x: 226, y: 80, width: 32, height: 32))
        styleAction(pauseButton)
        content.addSubview(pauseButton)
        let openButton = NSButton()
        configure(openButton, symbol: "arrow.up.right", tooltip: "返回主窗口", action: #selector(openMainWindow),
                  frame: NSRect(x: 268, y: 80, width: 32, height: 32))
        styleAction(openButton)
        content.addSubview(openButton)
        let closeButton = NSButton()
        configure(closeButton, symbol: "xmark", tooltip: "隐藏浮窗（继续计时）", action: #selector(dismiss),
                  frame: NSRect(x: 287, y: 136, width: 19, height: 19))
        closeButton.alphaValue = 0.6
        content.addSubview(closeButton)

        let restored = panel.setFrameUsingName("FocusLensFloatingTimer")
        if restored {
            let oldFrame = panel.frame
            panel.setContentSize(panelSize)
            panel.setFrameOrigin(NSPoint(x: oldFrame.maxX - panelSize.width, y: oldFrame.maxY - panelSize.height))
        }
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(panel.frame) }
            ?? NSScreen.main ?? NSScreen.screens.first
        if let available = screen?.visibleFrame {
            let x = restored ? panel.frame.minX : available.maxX - panelSize.width - 24
            let y = restored ? panel.frame.minY : available.maxY - panelSize.height - 24
            panel.setFrameOrigin(NSPoint(
                x: min(max(x, available.minX + 12), available.maxX - panelSize.width - 12),
                y: min(max(y, available.minY + 12), available.maxY - panelSize.height - 12)))
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

    private func styleAction(_ button: NSButton) {
        button.wantsLayer = true
        button.layer?.cornerRadius = 16
        button.layer?.backgroundColor = NSColor(red: 0.925, green: 0.93, blue: 0.91, alpha: 1).cgColor
        button.contentTintColor = ink
        if let image = button.image {
            button.image = image.withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        }
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
        let now = Date()
        let remaining = currentRun.map { $0.remaining(at: now) } ?? 0
        let text = clockText(remaining)
        if timeLabel.stringValue != text { timeLabel.stringValue = text }
        let fraction = currentRun.map { min(1, max(0, remaining / $0.plannedSeconds)) } ?? 0
        progressRail.fraction = fraction
        let percentage = "\(Int(ceil(fraction * 100)))%"
        if percentLabel.stringValue != percentage {
            percentLabel.stringValue = percentage
            progressRail.setAccessibilityValue(percentage)
        }
    }

    private func refreshText() {
        refreshTime()
        if let run = currentRun {
            statusLabel.stringValue = run.isPaused ? "已暂停" : (run.phase == .focus ? "专注中" : "休息中")
            planLabel.stringValue = "\(Int(run.plannedSeconds / 60)) 分钟"
            progressLabel.stringValue = "剩余时间"
            timeLabel.textColor = run.isPaused ? muted : ink
            progressRail.tint = run.isPaused ? NSColor(red: 0.66, green: 0.69, blue: 0.64, alpha: 1) : accent
            statusDot.layer?.backgroundColor = (run.isPaused ? muted : accent).cgColor
            pauseButton.isHidden = false
            let title = run.isPaused ? "继续" : "暂停"
            pauseButton.image = NSImage(systemSymbolName: run.isPaused ? "play.fill" : "pause.fill", accessibilityDescription: title)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
            pauseButton.toolTip = title
            pauseButton.setAccessibilityLabel(title)
        } else {
            statusLabel.stringValue = hasFeedback ? "专注结束" : "休息结束"
            planLabel.stringValue = hasFeedback ? "待填写反馈" : "已结束"
            progressLabel.stringValue = "本轮已结束"
            timeLabel.textColor = accent
            progressRail.tint = accent
            statusDot.layer?.backgroundColor = accent.cgColor
            pauseButton.isHidden = true
        }
    }

    @objc private func togglePause() { store?.togglePause() }
    @objc private func openMainWindow() { store?.restoreMainWindow() }
    @objc private func dismiss() { dismissed = true; hidePanel() }
}
