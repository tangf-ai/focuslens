import AppKit
import QuartzCore

private func setLayerMotion(_ layer: CALayer, running: Bool) {
    if running, layer.speed == 0 {
        let paused = layer.timeOffset; layer.speed = 1; layer.timeOffset = 0; layer.beginTime = 0
        layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - paused
    } else if !running, layer.speed != 0 {
        let paused = layer.convertTime(CACurrentMediaTime(), from: nil)
        layer.speed = 0; layer.timeOffset = paused
    }
}

@MainActor
final class FocusRingView: NSView {
    private let track = CAShapeLayer(), value = CAShapeLayer(), halo = CAGradientLayer()
    private(set) var fraction = 1.0
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        halo.type = .radial; halo.startPoint = CGPoint(x: 0.5, y: 0.5); halo.endPoint = CGPoint(x: 1, y: 1)
        layer?.addSublayer(halo)
        for shape in [track, value] { shape.fillColor = nil; shape.lineWidth = 4; shape.lineCap = .round; layer?.addSublayer(shape) }
        setAccessibilityElement(true); setAccessibilityRole(.progressIndicator)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        halo.frame = bounds.insetBy(dx: 12, dy: 12)
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: max(0, min(bounds.width, bounds.height) / 2 - 5),
                    startAngle: .pi / 2, endAngle: -.pi * 1.5, clockwise: true)
        track.path = path; value.path = path
        CATransaction.commit()
    }
    func update(fraction: Double, palette: FocusPalette, motion: Bool) {
        self.fraction = min(1, max(0, fraction.isFinite ? fraction : 0))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        track.strokeColor = palette.ns(\.accent).withAlphaComponent(0.13).cgColor
        value.strokeColor = palette.ns(\.accent).cgColor; value.strokeEnd = self.fraction
        halo.colors = [palette.ns(\.glow).withAlphaComponent(0.28).cgColor, palette.ns(\.glow).withAlphaComponent(0.02).cgColor]
        CATransaction.commit()
        if motion && halo.animation(forKey: "breath") == nil {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 0.3; animation.toValue = 0.85; animation.duration = 4
            animation.autoreverses = true; animation.repeatCount = .greatestFiniteMagnitude
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            halo.add(animation, forKey: "breath")
        }
        setLayerMotion(halo, running: motion)
        setAccessibilityValue("\(Int(ceil(self.fraction * 100)))%")
    }
}

/// One small layer-backed surface, with no display link, particle engine, or animation timer.
@MainActor
final class FocusFloatingContent: NSView {
    let status = NSTextField(labelWithString: ""), title = NSTextField(labelWithString: "")
    let time = NSTextField(labelWithString: "—"), caption = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: ""), daily = NSTextField(labelWithString: "")
    let progressText = NSTextField(labelWithString: "")
    let pause = NSButton(title: "暂停", target: nil, action: nil)
    let open = NSButton(title: "↗", target: nil, action: nil), close = NSButton(title: "×", target: nil, action: nil)
    let edit = NSButton(title: "修改", target: nil, action: nil)
    let rest = NSButton(title: "休息5分钟", target: nil, action: nil), keepGoing = NSButton(title: "继续", target: nil, action: nil)
    let ring = FocusRingView(frame: .zero), rail = RemainingTimeRail()
    private let light = CAGradientLayer(), lowerLight = CAGradientLayer(), separator = CALayer()
    private var preferences = AppearancePreferences(), palette = FocusTheme.silver.palette
    private(set) var decorating = false
    private var progressVisible = true
    private var hasTitle: Bool { !title.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var desiredSize: NSSize { NSSize(width: preferences.width, height: preferences.style == .ring ? (hasTitle ? 360 : 336) : (hasTitle ? 300 : 276)) }
    var reminderVisible = false { didSet { needsLayout = true } }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 332, height: 360)); wantsLayer = true
        autoresizingMask = [.width, .height]; layer?.masksToBounds = true
        for blob in [light, lowerLight] {
            blob.type = .radial; blob.startPoint = CGPoint(x: 0.5, y: 0.5); blob.endPoint = CGPoint(x: 1, y: 1)
            layer?.addSublayer(blob)
        }
        layer?.addSublayer(separator)
        addSubview(ring); addSubview(rail)
        for label in [status, title, time, caption, detail, daily, progressText] {
            label.maximumNumberOfLines = 1; label.cell?.lineBreakMode = .byTruncatingTail
            label.font = .systemFont(ofSize: 11); addSubview(label)
        }
        title.font = .systemFont(ofSize: 14, weight: .medium)
        for button in [pause, open, close, edit, rest, keepGoing] {
            button.font = .systemFont(ofSize: 11); button.isBordered = false; addSubview(button)
        }
        close.toolTip = "只隐藏浮窗，不改变计时状态"; open.toolTip = "返回主窗口"
        open.setAccessibilityLabel("返回主窗口")
        rest.isHidden = true; keepGoing.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height, circular = preferences.style == .ring
        CATransaction.begin(); CATransaction.setDisableActions(true)
        light.frame = NSRect(x: w - 230, y: h - 195, width: 280, height: 280)
        lowerLight.frame = NSRect(x: -115, y: -100, width: 280, height: 280)
        separator.frame = NSRect(x: 20, y: 49, width: w - 40, height: 0.7)
        CATransaction.commit()
        status.frame = NSRect(x: 20, y: h - 36, width: w - 65, height: 18)
        close.frame = NSRect(x: w - 40, y: h - 40, width: 25, height: 25)
        title.isHidden = !hasTitle
        if circular {
            ring.frame = NSRect(x: (w - 164) / 2, y: h - 223, width: 164, height: 164)
            time.frame = NSRect(x: 20, y: h - 166, width: w - 40, height: 46)
            caption.frame = NSRect(x: 20, y: h - 190, width: w - 40, height: 18)
            title.frame = NSRect(x: 20, y: 111, width: w - 40, height: 20)
            detail.frame = NSRect(x: 20, y: 88, width: w - 40, height: 18)
            progressText.frame = NSRect(x: 20, y: 64, width: w - 40, height: 18)
        } else {
            title.frame = NSRect(x: 20, y: 228, width: w - 40, height: 20)
            time.frame = NSRect(x: 18, y: 164, width: w - 36, height: 58)
            caption.frame = NSRect(x: 20, y: 144, width: w - 40, height: 18)
            detail.frame = NSRect(x: 20, y: 112, width: w - 40, height: 18)
            progressText.frame = NSRect(x: 20, y: 86, width: w - 40, height: 18)
            rail.frame = NSRect(x: 20, y: 63, width: w - 40, height: 20)
        }
        time.font = .monospacedDigitSystemFont(ofSize: circular ? 34 : 46, weight: .light)
        for label in [time, caption, title, detail, progressText] { label.alignment = circular ? .center : .left }
        daily.frame = NSRect(x: 20, y: 18, width: w - 188, height: 18)
        edit.frame = NSRect(x: w - 166, y: 12, width: 40, height: 30)
        pause.frame = NSRect(x: w - 122, y: 12, width: 64, height: 30)
        open.frame = NSRect(x: w - 48, y: 12, width: 32, height: 30)
        rest.frame = NSRect(x: 18, y: 55, width: 130, height: 28)
        keepGoing.frame = NSRect(x: w - 114, y: 55, width: 94, height: 28)
        rest.isHidden = !reminderVisible; keepGoing.isHidden = !reminderVisible
        ring.isHidden = !circular || !progressVisible
        rail.isHidden = circular || !progressVisible || reminderVisible
        progressText.isHidden = reminderVisible || !progressVisible
        ring.needsLayout = true
    }
    func apply(appearance: AppearanceStore, active: Bool, visible: Bool) {
        preferences = appearance.preferences; palette = appearance.palette
        decorating = preferences.animates(active: active, visible: visible, reducedMotion: appearance.reducedMotion, lowPower: appearance.lowPower)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.cornerRadius = preferences.radius; layer?.backgroundColor = palette.ns(\.floating).cgColor
        layer?.borderWidth = 0.75; layer?.borderColor = palette.ns(\.line).cgColor
        light.colors = [palette.ns(\.glow).withAlphaComponent(0.8).cgColor, palette.ns(\.glow).withAlphaComponent(0).cgColor]
        lowerLight.colors = [palette.ns(\.glowTwo).withAlphaComponent(0.65).cgColor, palette.ns(\.glowTwo).withAlphaComponent(0).cgColor]
        light.isHidden = !preferences.glow; lowerLight.isHidden = !preferences.glow
        separator.backgroundColor = palette.ns(\.line).cgColor
        CATransaction.commit()
        for label in [title, time] { label.textColor = palette.ns(\.ink) }
        for label in [caption, detail, daily, progressText] { label.textColor = palette.ns(\.muted) }
        status.textColor = active ? palette.ns(\.accent) : palette.ns(\.muted)
        for button in [pause, open, close, edit, rest, keepGoing] { button.contentTintColor = palette.ns(\.accent) }
        rail.tint = palette.ns(\.accent)
        rail.trackColor = palette.ns(\.accent).withAlphaComponent(0.12)
        rail.tickColor = palette.ns(\.muted).withAlphaComponent(0.35)
        for (index, blob) in [light, lowerLight].enumerated() {
            if !preferences.glow || !preferences.gentleMotion { blob.removeAllAnimations() }
            if decorating && preferences.glow && blob.animation(forKey: "drift") == nil {
                let animation = CABasicAnimation(keyPath: "transform.translation")
                animation.fromValue = NSValue(point: .zero); animation.toValue = NSValue(point: NSPoint(x: index == 0 ? -28 : 24, y: index == 0 ? -22 : 18))
                animation.duration = index == 0 ? 15 : 18; animation.autoreverses = true
                animation.repeatCount = .greatestFiniteMagnitude; animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                blob.add(animation, forKey: "drift")
            }
            setLayerMotion(blob, running: decorating && preferences.glow)
        }
        ring.update(fraction: ring.fraction, palette: palette, motion: decorating && preferences.style == .ring && progressVisible)
        needsLayout = true
    }
    func setProgress(_ fraction: Double, visible: Bool) {
        progressVisible = visible
        rail.fraction = min(1, max(0, fraction.isFinite ? fraction : 0))
        ring.update(fraction: fraction, palette: palette, motion: decorating && preferences.style == .ring && visible)
        ring.isHidden = preferences.style != .ring || !visible
        rail.isHidden = preferences.style != .rail || !visible || reminderVisible
        progressText.isHidden = reminderVisible || !visible
    }
}
