import AppKit
import SwiftUI
import Observation

enum FocusTheme: String, Codable, CaseIterable, Identifiable {
    case silver, jade, lilac, night
    var id: String { rawValue }
    var name: String { switch self { case .silver: "银雾"; case .jade: "雨青"; case .lilac: "暮紫"; case .night: "深空" } }
    var isDark: Bool { self == .night }
    var palette: FocusPalette {
        switch self {
        case .silver: FocusPalette(paper: 0xfafbfd, side: 0xf0f3f7, ink: 0x1d293b, muted: 0x5c6b80, line: 0xdde4ed, accent: 0x2d61d3, accentInk: 0xffffff, floating: 0xf7faff, glow: 0xacc9ff, glowTwo: 0xdae5ff)
        case .jade: FocusPalette(paper: 0xf9fcfb, side: 0xedf4f0, ink: 0x213a34, muted: 0x536e64, line: 0xd9e5de, accent: 0x1b745e, accentInk: 0xffffff, floating: 0xf5fcf8, glow: 0xa1d9c4, glowTwo: 0xdcebd6)
        case .lilac: FocusPalette(paper: 0xfcfbfe, side: 0xf1eef6, ink: 0x352c46, muted: 0x70637f, line: 0xe3ddea, accent: 0x73549f, accentInk: 0xffffff, floating: 0xfcf8ff, glow: 0xd0bce9, glowTwo: 0xebd9e9)
        case .night: FocusPalette(paper: 0x151d2a, side: 0x111a27, ink: 0xe7edf7, muted: 0xa0afc4, line: 0x2c3a4f, accent: 0x8cb7ff, accentInk: 0x11243f, floating: 0x1a273b, glow: 0x294c7f, glowTwo: 0x344561)
        }
    }
}

struct FocusPalette {
    var paper, side, ink, muted, line, accent, accentInk, floating, glow, glowTwo: UInt32
    static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    func ns(_ key: KeyPath<FocusPalette, UInt32>) -> NSColor { Self.color(self[keyPath: key]) }
}

enum FloatingStyle: String, Codable, CaseIterable, Identifiable {
    case rail, ring
    var id: String { rawValue }
    var name: String { self == .ring ? "呼吸圆环" : "柔光刻度" }
}

struct AppearancePreferences: Codable, Equatable {
    var theme: FocusTheme = .silver
    var style: FloatingStyle = .ring
    var glow = true
    var gentleMotion = true
    var followsReducedMotion = true
    var width: Double = 332
    var radius: Double = 27
    mutating func normalize() {
        width = width.isFinite ? min(360, max(290, width)) : 332
        radius = radius.isFinite ? min(36, max(16, radius)) : 27
    }
    func animates(active: Bool, visible: Bool, reducedMotion: Bool, lowPower: Bool) -> Bool {
        gentleMotion && active && visible && !lowPower && !(followsReducedMotion && reducedMotion)
    }
}

extension Notification.Name { static let focusLensAppearanceChanged = Notification.Name("FocusLensAppearanceChanged") }

@MainActor @Observable
final class AppearanceStore {
    static var current: AppearanceStore?
    private(set) var preferences = AppearancePreferences()
    private(set) var errorMessage: String?
    private(set) var reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private(set) var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @ObservationIgnored private let file: URL
    @ObservationIgnored private var writable = true
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(directory: URL) {
        file = directory.appendingPathComponent("appearance-settings.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do { preferences = try JSONDecoder().decode(AppearancePreferences.self, from: Data(contentsOf: file)); preferences.normalize() }
            catch { writable = false; errorMessage = "外观配置读取失败，已使用默认外观且停止覆盖原文件。" }
        }
        Self.current = self
        applyAppAppearance()
        let workspace = NSWorkspace.shared.notificationCenter
        let accessibility = workspace.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshMotionPolicy() }
        }
        observers.append((workspace, accessibility))
        let center = NotificationCenter.default
        let power = center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshMotionPolicy() }
        }
        observers.append((center, power))
    }
    deinit { for (center, token) in observers { center.removeObserver(token) } }
    var palette: FocusPalette { preferences.theme.palette }
    private func applyAppAppearance() {
        NSApplication.shared.appearance = NSAppearance(named: preferences.theme.isDark ? .darkAqua : .aqua)
    }
    private func refreshMotionPolicy() {
        reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        NotificationCenter.default.post(name: .focusLensAppearanceChanged, object: self)
    }
    func update(_ edit: (inout AppearancePreferences) -> Void) {
        guard writable else { return }
        var updated = preferences; edit(&updated); updated.normalize()
        guard updated != preferences else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(updated).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            preferences = updated; errorMessage = nil
            applyAppAppearance()
            NotificationCenter.default.post(name: .focusLensAppearanceChanged, object: self)
        } catch { errorMessage = "外观未保存，请检查磁盘空间或数据目录权限。" }
    }
}

/// Observation tracks these preference reads inside every SwiftUI body that uses a token.
@MainActor enum Theme {
    static var palette: FocusPalette { AppearanceStore.current?.palette ?? FocusTheme.silver.palette }
    static var accent: Color { Color(nsColor: palette.ns(\.accent)) }
    static var accentInk: Color { Color(nsColor: palette.ns(\.accentInk)) }
    static var background: Color { Color(nsColor: palette.ns(\.paper)) }
    static var surface: Color { Color(nsColor: palette.ns(\.floating)) }
    static var ink: Color { Color(nsColor: palette.ns(\.ink)) }
    static var muted: Color { Color(nsColor: palette.ns(\.muted)) }
    static var line: Color { Color(nsColor: palette.ns(\.line)) }
    static var sidebar: Color { Color(nsColor: palette.ns(\.side)) }
}
