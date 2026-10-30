import AppKit
import QuartzCore

/// A compact AppKit surface. Only visible activity text refreshes; there are no decorative animation timers.
@MainActor
final class FocusFloatingContent: NSView {
    let status = NSTextField(labelWithString: ""), title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: ""), time = NSTextField(labelWithString: "—")
    let caption = NSTextField(labelWithString: "当前活动 · 估算"), daily = NSTextField(labelWithString: "")
    let pause = NSButton(title: "暂停", target: nil, action: nil)
    let open = NSButton(title: "↗", target: nil, action: nil), close = NSButton(title: "×", target: nil, action: nil)
    private var preferences = AppearancePreferences()
    private let separator = CALayer()
    var desiredSize: NSSize { NSSize(width: preferences.width, height: 220) }
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 290, height: 220)); wantsLayer = true
        autoresizingMask = [.width, .height]; layer?.masksToBounds = true; layer?.addSublayer(separator)
        for label in [status, title, detail, time, caption, daily] {
            label.maximumNumberOfLines = 1; label.cell?.lineBreakMode = .byTruncatingTail
            label.font = .systemFont(ofSize: 10); addSubview(label)
        }
        title.font = .systemFont(ofSize: 15, weight: .medium); time.font = .monospacedDigitSystemFont(ofSize: 31, weight: .light)
        for button in [pause, open, close] { button.isBordered = false; button.font = .systemFont(ofSize: 11); addSubview(button) }
        open.setAccessibilityLabel("返回今天"); close.setAccessibilityLabel("隐藏浮窗"); close.toolTip = "只隐藏浮窗，不停止记录"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layout() {
        super.layout()
        let w = bounds.width
        status.frame = NSRect(x: 18, y: 184, width: w - 65, height: 16)
        close.frame = NSRect(x: w - 39, y: 180, width: 24, height: 24)
        title.frame = NSRect(x: 18, y: 151, width: w - 36, height: 21)
        detail.frame = NSRect(x: 18, y: 126, width: w - 36, height: 16)
        time.frame = NSRect(x: 16, y: 67, width: w - 95, height: 44)
        caption.frame = NSRect(x: 18, y: 49, width: w - 36, height: 15)
        pause.frame = NSRect(x: w - 71, y: 74, width: 55, height: 30)
        daily.frame = NSRect(x: 18, y: 15, width: w - 75, height: 16)
        open.frame = NSRect(x: w - 48, y: 9, width: 32, height: 28)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        separator.frame = NSRect(x: 18, y: 40, width: w - 36, height: 0.7)
        CATransaction.commit()
    }
    func apply(appearance: AppearanceStore, active: Bool) {
        preferences = appearance.preferences
        let palette = appearance.palette
        layer?.cornerRadius = min(20, preferences.radius); layer?.backgroundColor = palette.ns(\.floating).cgColor
        layer?.borderWidth = 0.75; layer?.borderColor = palette.ns(\.line).cgColor; separator.backgroundColor = palette.ns(\.line).cgColor
        for label in [title, time] { label.textColor = palette.ns(\.ink) }
        for label in [detail, caption, daily] { label.textColor = palette.ns(\.muted) }
        status.textColor = active ? palette.ns(\.accent) : palette.ns(\.muted)
        for button in [pause, open, close] { button.contentTintColor = palette.ns(\.accent) }
        needsLayout = true
    }
}
