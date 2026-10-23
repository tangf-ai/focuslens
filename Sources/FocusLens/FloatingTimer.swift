import AppKit
import Combine

private final class CountdownPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A quiet, decreasing time rail. Drawing is limited to the small progress region.
final class RemainingTimeRail: NSView {
    var trackColor = NSColor.gray.withAlphaComponent(0.12) { didSet { if trackColor != oldValue { needsDisplay = true } } }
    var tickColor = NSColor.gray.withAlphaComponent(0.35) { didSet { if tickColor != oldValue { needsDisplay = true } } }
    var fraction = 1.0 { didSet { if fraction != oldValue { needsDisplay = true } } }
    var tint = NSColor(red: 0.76, green: 0.31, blue: 0.19, alpha: 1) {
        didSet { if tint != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: 4, y: 11, width: max(0, bounds.width - 8), height: 6)
        trackColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        let width = track.width * min(1, max(0, fraction))
        if width > 0 {
            tint.setFill()
            let fill = NSRect(x: track.minX, y: track.minY, width: width, height: track.height)
            NSBezierPath(roundedRect: fill, xRadius: min(3, width / 2), yRadius: 3).fill()
            NSBezierPath(ovalIn: NSRect(x: track.minX + width - 4, y: track.midY - 4, width: 8, height: 8)).fill()
        }
        tickColor.setStroke()
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

@MainActor
final class FloatingTimerController: NSObject {
    static let identifier = NSUserInterfaceItemIdentifier("FocusLensFloatingTimer")
    private weak var store: FocusStore?
    private var panel: CountdownPanel?
    private let content = FocusFloatingContent()
    private var observation: AnyCancellable?
    private var observers: [NSObjectProtocol] = []
    private var screenSupport: FloatingScreenSupport?
    private var timer: Timer?
    private var currentRun: TimerRun?
    private var pendingFeedback: SessionDraft?
    private var runID: UUID?
    private var hasFeedback = false, restFinished = false, dismissed = false

    init(store: FocusStore) {
        self.store = store; super.init()
        content.edit.isHidden = true
        for (button, action) in [(content.pause, #selector(togglePause)), (content.open, #selector(openMain)), (content.close, #selector(hide))] {
            button.target = self; button.action = action
        }
        observation = store.$data.sink { [weak self] data in self?.update(data) }
        observers.append(NotificationCenter.default.addObserver(forName: .focusLensAppearanceChanged, object: store.appearance, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
    }
    deinit { timer?.invalidate(); for token in observers { NotificationCenter.default.removeObserver(token) } }
    func present() {
        guard currentRun != nil || hasFeedback || restFinished else { return }
        dismissed = false; refresh(); screenSupport?.ensureVisible()
    }
    func moveToCurrentScreen() {
        guard currentRun != nil || hasFeedback || restFinished else { return }
        present(); screenSupport?.moveToCurrentScreen()
    }
    private func update(_ data: AppData) {
        let previous = currentRun; currentRun = data.activeRun; pendingFeedback = data.pendingFeedback; hasFeedback = pendingFeedback != nil
        if let run = currentRun {
            if run.id != runID { dismissed = false }
            runID = run.id; restFinished = false
        } else if previous?.phase == .rest { restFinished = true }
        refresh()
    }
    private func makePanel() -> CountdownPanel {
        let panel = CountdownPanel(contentRect: NSRect(origin: .zero, size: content.desiredSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.identifier = Self.identifier; panel.title = "专注镜 · 倒计时浮窗"
        panel.level = .floating; panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true; panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isExcludedFromWindowsMenu = true; panel.isReleasedWhenClosed = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.contentView = content
        let restored = panel.setFrameUsingName("FocusLensFloatingTimer"), previous = panel.frame
        panel.setContentSize(content.desiredSize)
        if let screen = FloatingScreenSupport.currentScreen {
            let proposed = restored ? NSRect(x: previous.maxX - content.desiredSize.width, y: previous.maxY - content.desiredSize.height, width: content.desiredSize.width, height: content.desiredSize.height)
                : FloatingPlacement.topRight(size: content.desiredSize, in: screen.visibleFrame)
            panel.setFrame(FloatingPlacement.recover(proposed, screens: NSScreen.screens.map(\.visibleFrame), preferred: screen.visibleFrame), display: false)
        }
        panel.setFrameAutosaveName("FocusLensFloatingTimer"); screenSupport = FloatingScreenSupport(panel: panel)
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.configureClockAndMotion() }
        })
        return panel
    }
    private func refresh() {
        guard let store else { return }
        guard currentRun != nil || hasFeedback || restFinished else {
            runID = nil; panel?.orderOut(nil); configureClockAndMotion(); return
        }
        if panel == nil { panel = makePanel() }
        let focus = currentRun?.phase == .focus || hasFeedback
        let kind = currentRun?.phase == .focus ? currentRun?.kind : pendingFeedback?.kind
        let goal = currentRun?.phase == .focus ? currentRun?.goal ?? "" : pendingFeedback?.goal ?? ""
        content.status.stringValue = currentRun.map { $0.isPaused ? "已暂停" : ($0.phase == .focus ? "专注中" : "休息中") } ?? (hasFeedback ? "专注结束" : "休息结束")
        if let kind, focus { content.status.stringValue += " · " + kind.displayName }
        content.status.toolTip = content.status.stringValue
        content.title.stringValue = focus ? goal.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") : ""
        content.title.toolTip = goal.isEmpty ? nil : goal
        content.detail.stringValue = currentRun.map { "计划 \(Int($0.plannedSeconds / 60)) 分钟" } ?? (hasFeedback ? "待填写反馈" : "本轮已结束")
        content.daily.stringValue = focus ? "手动专注" : "休息时间"
        content.pause.isHidden = currentRun == nil; content.pause.title = currentRun?.isPaused == true ? "继续" : "暂停"
        panel?.appearance = NSAppearance(named: store.appearance.preferences.theme.isDark ? .darkAqua : .aqua)
        content.apply(appearance: store.appearance, active: false, visible: false)
        if let panel, panel.frame.size != content.desiredSize {
            let old = panel.frame; panel.setContentSize(content.desiredSize)
            panel.setFrameOrigin(NSPoint(x: old.maxX - content.desiredSize.width, y: old.maxY - content.desiredSize.height))
            screenSupport?.ensureVisible()
        }
        content.needsLayout = true; content.layoutSubtreeIfNeeded(); refreshTime()
        if !dismissed, panel?.isVisible != true { screenSupport?.ensureVisible(); panel?.orderFrontRegardless() }
        configureClockAndMotion()
    }
    private func refreshTime() {
        let remaining = currentRun?.remaining(at: Date()) ?? 0
        content.time.stringValue = clockText(remaining)
        content.caption.stringValue = currentRun == nil ? "本轮已结束" : "本轮剩余时间"
        let fraction = currentRun.map { remaining / $0.plannedSeconds } ?? 0
        content.progressText.stringValue = currentRun == nil ? "本轮已结束" : "剩余 \(Int(ceil(min(1, max(0, fraction)) * 100)))%"
        content.setProgress(fraction, visible: true)
    }
    private func configureClockAndMotion() {
        timer?.invalidate(); timer = nil
        guard let store else { return }
        let visible = panel?.isVisible == true && panel?.occlusionState.contains(.visible) == true && !dismissed
        let running = currentRun != nil && currentRun?.isPaused != true
        content.apply(appearance: store.appearance, active: running, visible: visible)
        guard visible, running else { return }
        let tick = Timer(timeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.refreshTime() } }
        tick.tolerance = 0.15; RunLoop.main.add(tick, forMode: .common); timer = tick
    }
    @objc private func togglePause() { store?.togglePause() }
    @objc private func openMain() { store?.restoreMainWindow() }
    @objc private func hide() { dismissed = true; panel?.orderOut(nil); configureClockAndMotion() }
}
