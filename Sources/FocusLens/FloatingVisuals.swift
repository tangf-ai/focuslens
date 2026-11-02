import AppKit
import QuartzCore

/// Never becomes the key window: interacting with the capsule preserves the foreground editor.
final class FocusFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class FocusFloatingButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { false }
}

enum FloatingDisplayMode: CaseIterable { case compact, expanded, docked }

/// The panel has exactly the visible surface's size, including while collapsed.
@MainActor
final class FocusFloatingContent: NSView {
    let status = NSTextField(labelWithString: ""), title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: ""), time = NSTextField(labelWithString: "—")
    let daily = NSTextField(labelWithString: "")
    let category = NSTextField(labelWithString: "等待识别"), compactTime = NSTextField(labelWithString: "—")
    let pause = FocusFloatingButton(title: "暂停", target: nil, action: nil)
    let open = FocusFloatingButton(title: "↗", target: nil, action: nil), close = FocusFloatingButton(title: "×", target: nil, action: nil)
    let dock = FocusFloatingButton(title: "贴边", target: nil, action: nil)
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    var onDragStart: (() -> Void)?
    var onDragEnd: (() -> Void)?
    private(set) var dragging = false
    private var tracking: NSTrackingArea?
    private var palette = FocusTheme.silver.palette
    private var active = false
    private let separator = CALayer(), dot = CALayer()
    var mode: FloatingDisplayMode = .compact { didSet { updateSurface() } }
    var desiredSize: NSSize {
        switch mode {
        case .compact: NSSize(width: 148, height: 32)
        case .expanded: NSSize(width: 220, height: 144)
        case .docked: NSSize(width: 8, height: 36)
        }
    }
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 148, height: 32)); wantsLayer = true
        autoresizingMask = [.width, .height]; layer?.masksToBounds = true
        layer?.addSublayer(separator); layer?.addSublayer(dot)
        for label in [status, title, detail, time, daily, category, compactTime] {
            label.maximumNumberOfLines = 1; label.cell?.lineBreakMode = .byTruncatingTail
            label.font = .systemFont(ofSize: 10); addSubview(label)
        }
        title.font = .systemFont(ofSize: 12, weight: .medium)
        time.font = .monospacedDigitSystemFont(ofSize: 22, weight: .regular)
        category.font = .systemFont(ofSize: 11, weight: .medium)
        compactTime.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        for button in [pause, open, close, dock] {
            button.isBordered = false; button.font = .systemFont(ofSize: 11)
            button.focusRingType = .none; addSubview(button)
        }
        open.setAccessibilityLabel("返回今天"); dock.setAccessibilityLabel("贴边收起")
        close.setAccessibilityLabel("隐藏浮窗"); close.toolTip = "只隐藏浮窗，不停止记录"
        updateSurface()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit is NSTextField ? self : hit
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { if !dragging { onHover?(true) } }
    override func mouseExited(with event: NSEvent) { if !dragging { onHover?(false) } }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let origin = window.frame.origin
        dragging = true; onDragStart?()
        window.performDrag(with: event)
        dragging = false
        if window.frame.origin != origin { onDragEnd?() } else { onClick?() }
    }
    private func updateSurface() {
        let expanded = mode == .expanded
        for view in [status, title, detail, time, daily, pause, open, close, dock] { view.isHidden = !expanded }
        for label in [category, compactTime] { label.isHidden = mode != .compact }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        separator.isHidden = !expanded; dot.isHidden = mode != .compact
        layer?.cornerRadius = mode == .compact ? 16 : mode == .docked ? 4 : 14
        layer?.backgroundColor = palette.ns(mode == .docked ? (active ? \.accent : \.muted) : \.floating).cgColor
        layer?.borderWidth = mode == .docked ? 0 : 0.75
        layer?.borderColor = palette.ns(\.line).cgColor
        separator.backgroundColor = palette.ns(\.line).cgColor
        dot.backgroundColor = palette.ns(active ? \.accent : \.muted).cgColor
        CATransaction.commit()
        toolTip = mode == .expanded ? nil : "\(status.stringValue) · \(category.stringValue) · \(compactTime.stringValue)\n\(title.stringValue)\n停留展开 · 拖动移位 · 点击切换"
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let w = bounds.width
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dot.frame = NSRect(x: 10, y: 13, width: 6, height: 6)
        dot.cornerRadius = 3
        category.frame = NSRect(x: 22, y: 8, width: w - 100, height: 16)
        compactTime.frame = NSRect(x: w - 77, y: 8, width: 67, height: 16)
        compactTime.alignment = .right
        status.frame = NSRect(x: 12, y: 118, width: w - 48, height: 16)
        close.frame = NSRect(x: w - 34, y: 114, width: 24, height: 24)
        title.frame = NSRect(x: 12, y: 94, width: w - 24, height: 18)
        detail.frame = NSRect(x: 12, y: 76, width: w - 24, height: 15)
        time.frame = NSRect(x: 10, y: 36, width: w - 76, height: 32)
        pause.frame = NSRect(x: w - 64, y: 39, width: 52, height: 28)
        daily.frame = NSRect(x: 12, y: 8, width: w - 91, height: 16)
        dock.frame = NSRect(x: w - 78, y: 4, width: 40, height: 24)
        open.frame = NSRect(x: w - 36, y: 4, width: 26, height: 24)
        separator.frame = NSRect(x: 12, y: 31, width: w - 24, height: 0.7)
        CATransaction.commit()
    }
    func apply(appearance: AppearanceStore, active: Bool) {
        palette = appearance.palette; self.active = active
        for label in [title, time, category] { label.textColor = palette.ns(\.ink) }
        for label in [detail, daily, compactTime] { label.textColor = palette.ns(\.muted) }
        status.textColor = active ? palette.ns(\.accent) : palette.ns(\.muted)
        for button in [pause, open, close, dock] { button.contentTintColor = palette.ns(\.accent) }
        updateSurface()
    }
}
