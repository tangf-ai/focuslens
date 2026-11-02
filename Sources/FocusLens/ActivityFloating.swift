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
    private var hoverTask: Task<Void, Never>?
    private var dockEdge: FloatingDockEdge?
    private let pointerLocation: () -> NSPoint
    private var active: Bool {
        guard let tracker else { return false }
        switch tracker.status { case .recording, .uncertain, .recognizing, .waiting: return true; default: return false }
    }

    init(tracker: AutomaticTracker, pointerLocation: @escaping () -> NSPoint = { NSEvent.mouseLocation }) {
        self.tracker = tracker; self.pointerLocation = pointerLocation; super.init()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: "专注镜自动记录")
        let menu = NSMenu()
        for (title, selector) in [("显示活动浮窗", #selector(showFromMenu)), ("打开主窗口", #selector(openMain)),
                                  ("暂停 / 恢复自动记录", #selector(toggle)), ("浮窗移到当前屏幕", #selector(moveFromMenu))] {
            let entry = NSMenuItem(title: title, action: selector, keyEquivalent: ""); entry.target = self; menu.addItem(entry)
        }
        item.menu = menu; item.isVisible = tracker.config.enabled; statusItem = item
        for (button, action) in [(content.pause, #selector(toggle)), (content.open, #selector(openMain)),
                                  (content.close, #selector(hide)), (content.dock, #selector(dockFromButton))] {
            button.target = self; button.action = action
        }
        content.onHover = { [weak self] inside in self?.hover(inside) }
        content.onClick = { [weak self] in self?.clicked() }
        content.onDragStart = { [weak self] in self?.hoverTask?.cancel() }
        content.onDragEnd = { [weak self] in self?.dragEnded() }
        observation = tracker.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
        observers.append(NotificationCenter.default.addObserver(forName: .focusLensAppearanceChanged, object: tracker.appearance, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
    }
    deinit { timer?.invalidate(); hoverTask?.cancel(); for token in observers { NotificationCenter.default.removeObserver(token) } }
    func shutdown() {
        hoverTask?.cancel(); hoverTask = nil; timer?.invalidate(); timer = nil
        tracker = nil; panel?.close(); panel = nil; screenSupport = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }
    func present() { dismissed = false; dockEdge = nil; setMode(.compact); refresh(); screenSupport?.ensureVisible() }
    func moveToCurrentScreen() { present(); screenSupport?.moveToCurrentScreen() }
    private func makePanel() -> NSPanel {
        let panel = FocusFloatingPanel(contentRect: NSRect(origin: .zero, size: content.desiredSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.identifier = Self.identifier; panel.title = "专注镜 · 自动记录浮窗"
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = true; panel.acceptsMouseMovedEvents = true
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
        panel.setFrameAutosaveName("FocusLensAutomaticFloating")
        screenSupport = FloatingScreenSupport(panel: panel, dockEdge: { [weak self] in self?.dockEdge })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.configureClockAndMotion() }
        })
        return panel
    }
    private func resize() {
        guard let panel, panel.frame.size != content.desiredSize else { content.needsLayout = true; return }
        panel.setFrame(FloatingPlacement.resized(panel.frame, to: content.desiredSize, edge: dockEdge), display: true)
        screenSupport?.ensureVisible()
    }
    private func setMode(_ mode: FloatingDisplayMode) {
        content.mode = mode; resize(); content.layoutSubtreeIfNeeded()
    }
    private func hover(_ inside: Bool) {
        hoverTask?.cancel()
        guard !content.dragging, panel?.isVisible == true, !dismissed else { return }
        hoverTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(inside ? 350 : 500)) } catch { return }
            guard let self, !self.content.dragging, !self.dismissed, let panel = self.panel, panel.isVisible else { return }
            let contains = panel.frame.contains(self.pointerLocation())
            if inside && contains { self.setMode(.expanded) }
            if !inside && !contains { self.setMode(self.dockEdge == nil ? .compact : .docked) }
        }
    }
    private func clicked() {
        hoverTask?.cancel()
        if dockEdge != nil { dockEdge = nil; setMode(.compact) }
        else { setMode(content.mode == .expanded ? .compact : .expanded) }
        // A click can reveal details without pinning a large surface on screen.
        hover(false)
    }
    private func dragEnded() {
        hoverTask?.cancel(); dockEdge = nil
        guard let panel else { return }
        let frame = FloatingPlacement.recover(panel.frame, screens: NSScreen.screens.map(\.visibleFrame), margin: 0)
        if let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(frame) }) {
            dockEdge = FloatingPlacement.dockEdge(for: frame, in: screen.visibleFrame)
        }
        setMode(dockEdge == nil ? .compact : .docked)
        screenSupport?.ensureVisible()
    }
    @objc private func dockFromButton() {
        hoverTask?.cancel()
        guard let panel else { return }
        let recovered = FloatingPlacement.recover(panel.frame, screens: NSScreen.screens.map(\.visibleFrame), margin: 0)
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(recovered) }) else { return }
        dockEdge = recovered.midX < screen.visibleFrame.midX ? .left : .right
        setMode(.docked); screenSupport?.ensureVisible()
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
        content.category.stringValue = active ? segment?.categoryLabel ?? "待识别" : tracker.status.label
        content.category.toolTip = content.category.stringValue
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
        content.compactTime.stringValue = content.time.stringValue
        let caption = tracker.status == .inactive ? "空闲期间未累计" : "当前活动 · 估算"
        content.time.toolTip = "\(caption)：\(content.time.stringValue)"
        content.compactTime.toolTip = content.time.toolTip
        content.time.setAccessibilityLabel(caption)
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
    @objc private func hide() { hoverTask?.cancel(); dismissed = true; panel?.orderOut(nil); configureClockAndMotion() }
}
