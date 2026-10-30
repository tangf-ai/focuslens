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
                                  (content.close, #selector(hide))] {
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
        statusItem?.isVisible = tracker.config.enabled
        statusItem?.button?.toolTip = "专注镜 · " + tracker.status.label
        statusItem?.menu?.item(at: 2)?.isEnabled = tracker.config.enabled
        guard tracker.config.enabled, !dismissed else {
            panel?.orderOut(nil); configureClockAndMotion(); return
        }
        if panel == nil { panel = makePanel() }
        panel?.appearance = NSAppearance(named: tracker.appearance.preferences.theme.isDark ? .darkAqua : .aqua)
        let segment = tracker.current == nil && tracker.status != .paused ? nil : tracker.liveSegment()
        content.status.stringValue = tracker.status.label
        content.status.toolTip = content.status.stringValue
        content.title.stringValue = active || tracker.status == .paused ? segment.map { "\($0.categoryLabel) · \($0.title)" } ?? "当前活动未识别" : tracker.status.detail
        content.detail.stringValue = active ? tracker.recognitionDetail() : "不截图、不分析"
        if tracker.status == .inactive {
            content.title.stringValue = "无操作，计时已暂停"
            content.detail.stringValue = "恢复操作自动继续 · 空闲时段不补记"
        }
        if case .error(let message) = tracker.status { content.detail.stringValue = message }
        let today = tracker.segments(in: Period.today.interval()).filter { $0.category == segment?.category && $0.unresolvedReason == segment?.unresolvedReason }.reduce(0) { $0 + $1.seconds }
        content.daily.stringValue = active ? "今日约 \(Int(today / 60)) 分钟" : ""
        content.daily.toolTip = segment.map { "今天\($0.categoryLabel)约 \(Int(today / 60)) 分钟" }
        switch tracker.status {
        case .paused: content.pause.title = "恢复"; content.pause.isEnabled = true
        default: content.pause.title = "暂停"; content.pause.isEnabled = true
        }
        content.apply(appearance: tracker.appearance, active: active)
        resize(); content.layoutSubtreeIfNeeded(); refreshTime()
        for label in [content.title, content.detail] { label.toolTip = label.stringValue }
        if panel?.isVisible != true { panel?.orderFrontRegardless() }
        configureClockAndMotion()
    }
    private func refreshTime() {
        guard let tracker else { return }
        let segment = tracker.current == nil && tracker.status != .paused ? nil : tracker.liveSegment()
        content.time.stringValue = segment.map { "约 \(Int($0.seconds / 60)) 分钟" } ?? "—"
        content.caption.stringValue = tracker.status == .inactive ? "空闲期间未累计" : "当前活动 · 估算"
        if active { content.detail.stringValue = tracker.recognitionDetail() }
    }
    private func configureClockAndMotion() {
        timer?.invalidate(); timer = nil
        guard let tracker else { return }
        let visible = panel?.isVisible == true && panel?.occlusionState.contains(.visible) == true && !dismissed
        content.apply(appearance: tracker.appearance, active: active)
        guard visible, active else { return }
        let tick = Timer(timeInterval: 5, repeats: true) { [weak self] _ in Task { @MainActor in self?.refreshTime() } }
        tick.tolerance = 1; RunLoop.main.add(tick, forMode: .common); timer = tick
    }
    @objc private func toggle() {
        guard let tracker else { return }
        if tracker.status == .paused { tracker.resume() } else { tracker.pause() }
    }
    @objc private func showFromMenu() { present() }
    @objc private func moveFromMenu() { moveToCurrentScreen() }
    @objc private func openMain() { tracker?.openMain?() }
    @objc private func hide() { dismissed = true; panel?.orderOut(nil); configureClockAndMotion() }
}
