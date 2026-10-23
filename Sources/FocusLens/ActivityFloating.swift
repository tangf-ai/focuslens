import AppKit
import Combine

@MainActor
final class ActivityFloatingController: NSObject {
    static let identifier = NSUserInterfaceItemIdentifier("FocusLensAutomaticFloating")
    private weak var tracker: AutomaticTracker?
    private var panel: NSPanel?
    private let content = FocusFloatingContent()
    private var observation: AnyCancellable?
    private var timer: Timer?
    private var dismissed = false
    private var observers: [NSObjectProtocol] = []
    private var screenSupport: FloatingScreenSupport?
    private var statusItem: NSStatusItem?
    private var active: Bool {
        guard let tracker else { return false }
        switch tracker.status { case .recording, .uncertain, .recognizing, .waiting: return true; default: return false }
    }

    init(tracker: AutomaticTracker) {
        self.tracker = tracker; super.init()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: "专注镜自动记录")
        let menu = NSMenu()
        for (title, selector) in [("显示活动浮窗", #selector(showFromMenu)), ("打开主窗口", #selector(openMain)),
                                  ("暂停 / 恢复自动记录", #selector(toggle)), ("浮窗移到当前屏幕", #selector(moveFromMenu))] {
            let entry = NSMenuItem(title: title, action: selector, keyEquivalent: ""); entry.target = self; menu.addItem(entry)
        }
        item.menu = menu; item.isVisible = tracker.config.enabled; statusItem = item
        for (button, action) in [(content.pause, #selector(toggle)), (content.open, #selector(openMain)),
                                  (content.close, #selector(hide)), (content.edit, #selector(edit)),
                                  (content.rest, #selector(rest)), (content.keepGoing, #selector(keepGoing))] {
            button.target = self; button.action = action
        }
        observation = tracker.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
        observers.append(NotificationCenter.default.addObserver(forName: .focusLensAppearanceChanged, object: tracker.appearance, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
    }
    deinit { timer?.invalidate(); for token in observers { NotificationCenter.default.removeObserver(token) } }
    func present() { dismissed = false; refresh(); screenSupport?.ensureVisible() }
    func moveToCurrentScreen() { present(); screenSupport?.moveToCurrentScreen() }
    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: content.desiredSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.identifier = Self.identifier; panel.title = "专注镜 · 自动记录浮窗"
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.contentView = content
        let restored = panel.setFrameUsingName("FocusLensAutomaticFloating"), previous = panel.frame
        panel.setContentSize(content.desiredSize)
        if let screen = FloatingScreenSupport.currentScreen {
            let proposed = restored ? NSRect(x: previous.maxX - content.desiredSize.width, y: previous.maxY - content.desiredSize.height,
                                            width: content.desiredSize.width, height: content.desiredSize.height)
                : FloatingPlacement.topRight(size: content.desiredSize, in: screen.visibleFrame)
            panel.setFrame(FloatingPlacement.recover(proposed, screens: NSScreen.screens.map(\.visibleFrame), preferred: screen.visibleFrame), display: false)
        }
        panel.setFrameAutosaveName("FocusLensAutomaticFloating"); screenSupport = FloatingScreenSupport(panel: panel)
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.configureClockAndMotion() }
        })
        return panel
    }
    private func resize() {
        guard let panel, panel.frame.size != content.desiredSize else { content.needsLayout = true; return }
        let old = panel.frame; panel.setContentSize(content.desiredSize)
        panel.setFrameOrigin(NSPoint(x: old.maxX - content.desiredSize.width, y: old.maxY - content.desiredSize.height))
        screenSupport?.ensureVisible()
    }
    func refresh() {
        guard let tracker else { return }
        tracker.updateReminder(); statusItem?.isVisible = tracker.config.enabled
        statusItem?.button?.toolTip = "专注镜 · " + tracker.status.label
        switch tracker.status { case .manual, .excluded, .away: statusItem?.menu?.item(at: 2)?.isEnabled = false; default: statusItem?.menu?.item(at: 2)?.isEnabled = true }
        guard tracker.config.enabled, tracker.status != .manual, !dismissed else {
            panel?.orderOut(nil); configureClockAndMotion(); return
        }
        if panel == nil { panel = makePanel() }
        panel?.appearance = NSAppearance(named: tracker.appearance.preferences.theme.isDark ? .darkAqua : .aqua)
        let segment = tracker.current == nil && tracker.status != .paused ? nil : tracker.liveSegment()
        content.status.stringValue = tracker.status.label
        content.status.toolTip = content.status.stringValue
        content.title.stringValue = active || tracker.status == .paused ? segment.map { "\($0.category.rawValue) · \($0.title)" } ?? "当前活动待确认" : tracker.status.detail
        content.detail.stringValue = active ? tracker.recognitionDetail() : "不截图、不分析"
        if case .error(let message) = tracker.status { content.detail.stringValue = message }
        let today = tracker.segments(in: Period.today.interval()).filter { $0.category == segment?.category }.reduce(0) { $0 + $1.seconds }
        content.daily.stringValue = active ? "今日约 \(Int(today / 60)) 分钟" : ""
        content.daily.toolTip = segment.map { "今天\($0.category.rawValue)约 \(Int(today / 60)) 分钟" }
        content.reminderVisible = tracker.reminderVisible
        content.edit.isHidden = false; content.edit.isEnabled = segment != nil
        switch tracker.status {
        case .paused, .resting: content.pause.title = "恢复"; content.pause.isEnabled = true
        case .excluded, .away: content.pause.title = "暂挂中"; content.pause.isEnabled = false
        default: content.pause.title = "暂停"; content.pause.isEnabled = true
        }
        content.apply(appearance: tracker.appearance, active: false, visible: false)
        resize(); content.layoutSubtreeIfNeeded(); refreshTime()
        for label in [content.title, content.detail, content.progressText] { label.toolTip = label.stringValue }
        if panel?.isVisible != true { panel?.orderFrontRegardless() }
        configureClockAndMotion()
    }
    private func refreshTime() {
        guard let tracker else { return }
        tracker.updateReminder()
        let segment = tracker.current == nil && tracker.status != .paused ? nil : tracker.liveSegment()
        let seconds = segment?.seconds ?? 0
        if case .resting(let until) = tracker.status {
            let remaining = max(0, until.timeIntervalSinceNow)
            content.time.stringValue = clockText(remaining); content.caption.stringValue = "休息剩余时间"
            content.progressText.stringValue = "休息结束后恢复识别"; content.setProgress(remaining / 300, visible: true)
        } else {
            content.time.stringValue = (active || tracker.status == .paused) && segment != nil ? "约 " + clockText(seconds) : "—"
            content.caption.stringValue = active || tracker.status == .paused ? "已持续 · 自动估算" : ""
            let remaining = max(0, Double(tracker.config.reminderMinutes * 60) - seconds)
            content.progressText.stringValue = "距休息建议约 \(Int(ceil(remaining / 60))) 分钟"
            content.setProgress(remaining / Double(tracker.config.reminderMinutes * 60), visible: tracker.config.reminders && segment?.category != .unknown && segment != nil)
        }
        if active { content.detail.stringValue = tracker.recognitionDetail() }
    }
    private func configureClockAndMotion() {
        timer?.invalidate(); timer = nil
        guard let tracker else { return }
        let visible = panel?.isVisible == true && panel?.occlusionState.contains(.visible) == true && !dismissed
        let resting: Bool = { if case .resting = tracker.status { return true }; return false }()
        content.apply(appearance: tracker.appearance, active: active || resting, visible: visible)
        guard visible, active || resting else { return }
        let tick = Timer(timeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.refreshTime() } }
        tick.tolerance = 0.15; RunLoop.main.add(tick, forMode: .common); timer = tick
    }
    @objc private func toggle() {
        guard let tracker else { return }
        switch tracker.status { case .paused, .resting: tracker.resume(); case .excluded, .away, .manual: break; default: tracker.pause() }
    }
    @objc private func edit() { if let segment = tracker?.display { tracker?.edit(segment) } }
    @objc private func showFromMenu() { present() }
    @objc private func moveFromMenu() { moveToCurrentScreen() }
    @objc private func openMain() { tracker?.openMain?() }
    @objc private func hide() { dismissed = true; panel?.orderOut(nil); configureClockAndMotion() }
    @objc private func rest() { tracker?.rest() }
    @objc private func keepGoing() { tracker?.ignoreReminder() }
}
