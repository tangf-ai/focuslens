import AppKit
import Combine

@MainActor
final class ActivityFloatingController: NSObject {
    static let identifier = NSUserInterfaceItemIdentifier("FocusLensAutomaticFloating")
    private weak var tracker: AutomaticTracker?
    private var panel: NSPanel?
    private var observation: AnyCancellable?
    private var timer: Timer?
    private var dismissed = false
    private var visibilityObserver: NSObjectProtocol?
    private var screenSupport: FloatingScreenSupport?
    private let status = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let daily = NSTextField(labelWithString: "")
    private let rail = RemainingTimeRail()
    private let railLabel = NSTextField(labelWithString: "")
    private let pauseButton = NSButton(title: "暂停", target: nil, action: nil)
    private let editButton = NSButton(title: "修改分类", target: nil, action: nil)
    private let restButton = NSButton(title: "休息5分钟", target: nil, action: nil)
    private let continueButton = NSButton(title: "继续", target: nil, action: nil)
    private let accent = NSColor(red: 0.76, green: 0.31, blue: 0.19, alpha: 1)
    private var statusItem: NSStatusItem?

    init(tracker: AutomaticTracker) {
        self.tracker = tracker
        super.init()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: "专注镜自动记录")
        let menu = NSMenu()
        for (title, selector) in [("显示活动浮窗", #selector(showFromMenu)), ("打开主窗口", #selector(openMain)), ("暂停 / 恢复自动记录", #selector(toggle))] {
            let entry = NSMenuItem(title: title, action: selector, keyEquivalent: ""); entry.target = self; menu.addItem(entry)
        }
        item.menu = menu; item.isVisible = tracker.config.enabled; statusItem = item
        let move = NSMenuItem(title: "浮窗移到当前屏幕", action: #selector(moveFromMenu), keyEquivalent: "")
        move.target = self; move.toolTip = "移到鼠标当前所在的显示器"; menu.addItem(move)
        observation = tracker.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }
    deinit { timer?.invalidate(); if let visibilityObserver { NotificationCenter.default.removeObserver(visibilityObserver) } }
    func present() { dismissed = false; refresh(); screenSupport?.ensureVisible() }
    func moveToCurrentScreen() { present(); screenSupport?.moveToCurrentScreen() }
    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 268), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.identifier = Self.identifier; panel.title = "专注镜 · 自动记录浮窗"
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.appearance = NSAppearance(named: .aqua)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 268))
        content.wantsLayer = true; content.layer?.cornerRadius = 21
        content.layer?.backgroundColor = NSColor(red: 0.985, green: 0.98, blue: 0.965, alpha: 1).cgColor
        content.layer?.borderWidth = 0.75; content.layer?.borderColor = NSColor.lightGray.withAlphaComponent(0.4).cgColor
        panel.contentView = content
        for (label, frame, size) in [
            (status, NSRect(x: 20, y: 235, width: 267, height: 18), 11.0),
            (title, NSRect(x: 20, y: 203, width: 280, height: 22), 14.0),
            (time, NSRect(x: 18, y: 145, width: 285, height: 54), 36.0),
            (detail, NSRect(x: 20, y: 119, width: 280, height: 20), 11.0),
            (daily, NSRect(x: 20, y: 99, width: 280, height: 18), 11.0),
            (railLabel, NSRect(x: 20, y: 72, width: 280, height: 18), 10.0)
        ] {
            label.frame = frame; label.font = .systemFont(ofSize: size, weight: .regular)
            label.maximumNumberOfLines = 1; label.cell?.lineBreakMode = .byTruncatingTail
            content.addSubview(label)
        }
        status.textColor = accent
        time.font = .monospacedDigitSystemFont(ofSize: 36, weight: .light)
        rail.frame = NSRect(x: 20, y: 49, width: 280, height: 20)
        content.addSubview(rail)
        configure(editButton, frame: NSRect(x: 14, y: 14, width: 95, height: 30), action: #selector(edit))
        configure(pauseButton, frame: NSRect(x: 119, y: 14, width: 68, height: 30), action: #selector(toggle))
        let open = NSButton(title: "主窗口 ↗", target: nil, action: nil)
        configure(open, frame: NSRect(x: 210, y: 14, width: 95, height: 30), action: #selector(openMain))
        let close = NSButton(title: "×", target: nil, action: nil)
        configure(close, frame: NSRect(x: 285, y: 230, width: 24, height: 24), action: #selector(hide))
        close.toolTip = "只隐藏浮窗，不改变记录状态"
        configure(restButton, frame: NSRect(x: 15, y: 65, width: 130, height: 30), action: #selector(rest))
        configure(continueButton, frame: NSRect(x: 190, y: 65, width: 100, height: 30), action: #selector(keepGoing))
        let restored = panel.setFrameUsingName("FocusLensAutomaticFloating")
        let previous = panel.frame
        panel.setContentSize(NSSize(width: 320, height: 268))
        if let screen = FloatingScreenSupport.currentScreen {
            let proposed = restored ? NSRect(x: previous.maxX - 320, y: previous.maxY - 268, width: 320, height: 268)
                : FloatingPlacement.topRight(size: panel.frame.size, in: screen.visibleFrame)
            panel.setFrame(FloatingPlacement.recover(proposed, screens: NSScreen.screens.map(\.visibleFrame),
                                                     preferred: screen.visibleFrame), display: false)
        }
        panel.setFrameAutosaveName("FocusLensAutomaticFloating")
        screenSupport = FloatingScreenSupport(panel: panel)
        visibilityObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        return panel
    }
    private func configure(_ button: NSButton, frame: NSRect, action: Selector) {
        button.frame = frame; button.font = .systemFont(ofSize: 11); button.isBordered = false
        button.target = self; button.action = action; panel?.contentView?.addSubview(button)
        // During construction the panel property is not assigned yet.
        buildingButtons.append(button)
    }
    private var buildingButtons: [NSButton] = []
    func refresh() {
        guard let tracker else { return }
        tracker.updateReminder()
        statusItem?.isVisible = tracker.config.enabled
        statusItem?.button?.toolTip = "专注镜 · " + tracker.status.label
        switch tracker.status { case .manual, .excluded, .away: statusItem?.menu?.item(at: 2)?.isEnabled = false; default: statusItem?.menu?.item(at: 2)?.isEnabled = true }
        timer?.invalidate(); timer = nil
        guard tracker.config.enabled, tracker.status != .manual, !dismissed else { panel?.orderOut(nil); return }
        if panel == nil {
            panel = makePanel()
            for button in buildingButtons { panel?.contentView?.addSubview(button) }
            buildingButtons.removeAll()
        }
        status.stringValue = tracker.status.label
        let segment = tracker.current == nil && tracker.status != .paused ? nil : tracker.liveSegment()
        let active: Bool
        switch tracker.status { case .recording, .uncertain, .error, .waiting, .recognizing: active = true; default: active = false }
        title.stringValue = active ? segment.map { "\($0.category.rawValue) · \($0.title)" } ?? "正在判断当前活动" : tracker.status.detail
        time.stringValue = (active || tracker.status == .paused) ? segment.map { "约 \(max(0, Int($0.seconds / 60))) 分钟" } ?? "—" : "—"
        if case .resting(let until) = tracker.status { time.stringValue = clockText(max(0, until.timeIntervalSinceNow)) }
        detail.stringValue = tracker.recognitionDetail()
        if !active { detail.stringValue = "不截图、不分析" }
        let today = Period.today.interval()
        let seconds = tracker.segments(in: today).filter { $0.category == segment?.category }.reduce(0) { $0 + $1.seconds }
        daily.stringValue = active ? "今天\(segment?.category.rawValue ?? "已记录")约 \(Int(seconds / 60)) 分钟" : ""
        let remaining = max(0, Double(tracker.config.reminderMinutes * 60) - (segment?.seconds ?? 0))
        rail.fraction = remaining / Double(tracker.config.reminderMinutes * 60)
        railLabel.stringValue = "距休息建议约 \(Int(ceil(remaining / 60))) 分钟"
        rail.isHidden = !active || !tracker.config.reminders || tracker.reminderVisible
        railLabel.isHidden = rail.isHidden
        restButton.isHidden = !tracker.reminderVisible; continueButton.isHidden = !tracker.reminderVisible
        editButton.isEnabled = segment != nil
        switch tracker.status {
        case .paused, .resting: pauseButton.title = "恢复"; pauseButton.isEnabled = true
        case .excluded, .away: pauseButton.title = "暂挂中"; pauseButton.isEnabled = false
        default: pauseButton.title = "暂停"; pauseButton.isEnabled = true
        }
        for label in [title, detail, daily] { label.toolTip = label.stringValue }
        panel?.orderFrontRegardless()
        if panel?.occlusionState.contains(.visible) == true {
            let interval: TimeInterval = {
                if case .resting = tracker.status { return 1 }
                return active ? min(15, Double(tracker.config.intervalSeconds), tracker.isRecognizing ? 5 : 15) : 60
            }()
            let tick = Timer(timeInterval: interval, repeats: false) { [weak self] _ in Task { @MainActor in self?.refresh() } }
            tick.tolerance = interval == 1 ? 0.1 : 5; RunLoop.main.add(tick, forMode: .common); timer = tick
        }
    }
    @objc private func toggle() {
        guard let tracker else { return }
        switch tracker.status { case .paused, .resting: tracker.resume(); case .excluded, .away, .manual: break; default: tracker.pause() }
    }
    @objc private func edit() { if let segment = tracker?.display { tracker?.edit(segment) } }
    @objc private func showFromMenu() { present() }
    @objc private func moveFromMenu() { moveToCurrentScreen() }
    @objc private func openMain() { tracker?.openMain?() }
    @objc private func hide() { dismissed = true; timer?.invalidate(); timer = nil; panel?.orderOut(nil) }
    @objc private func rest() { tracker?.rest() }
    @objc private func keepGoing() { tracker?.ignoreReminder() }
}
