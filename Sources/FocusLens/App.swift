import SwiftUI
import AppKit

@main
struct FocusLensApp: App {
    @StateObject private var store: FocusStore
    init() {
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        let args = ProcessInfo.processInfo.arguments
        var directory: URL?
        if let index = args.firstIndex(of: "--data-directory"), index + 1 < args.count {
            directory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        }
        _store = StateObject(wrappedValue: FocusStore(directory: directory))
    }
    var body: some Scene {
        WindowGroup("专注镜", id: "main") {
            RootView().environmentObject(store).frame(minWidth: 1000, minHeight: 720)
                .preferredColorScheme(.light)
                .tint(Theme.accent)
                .environment(\.locale, Locale(identifier: "zh_CN"))
        }
        .defaultSize(width: 1120, height: 790)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("专注") {
                Button("显示倒计时浮窗") { store.showFloatingTimer() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .disabled(store.data.activeRun == nil && store.data.pendingFeedback == nil)

                Button("暂停 / 继续") { store.togglePause() }
                    .keyboardShortcut(.space, modifiers: [.command])
                    .disabled(store.data.activeRun == nil)
                Button("退出专注模式") { store.setFocusMode(false) }
                    .keyboardShortcut(.escape, modifiers: [])
            }
        }
    }
}

enum Theme {
    static let accent = Color(red: 0.76, green: 0.31, blue: 0.19)
    static let background = Color(red: 0.98, green: 0.97, blue: 0.95)
    static let ink = Color(red: 0.16, green: 0.18, blue: 0.17)
    static let muted = Color(red: 0.43, green: 0.45, blue: 0.43)
    static let line = Color(red: 0.87, green: 0.87, blue: 0.84)
    static let sidebar = Color(red: 0.95, green: 0.95, blue: 0.93)
}

enum Destination: String, CaseIterable, Identifiable {
    case timer = "专注计时", insights = "本周统计", history = "专注记录", review = "AI 复盘", settings = "设置"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .timer: "timer"
        case .insights: "chart.bar.xaxis"
        case .history: "clock.arrow.circlepath"
        case .review: "sparkles"
        case .settings: "slider.horizontal.3"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: FocusStore
    @State private var selection: Destination = .timer
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        HStack(spacing: 0) {
            if !store.focusMode { sidebar }
            Group {
                switch selection {
                case .timer: TimerWorkspace()
                case .insights: InsightsView()
                case .history: HistoryView()
                case .review: ReviewView(onSettings: { selection = .settings })
                case .settings: SettingsWorkspace()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
        }
        .onAppear {
            let opener = openWindow
            store.openMainWindowAction = { opener(id: "main") }
            store.enableFloatingTimer()
        }
        .foregroundStyle(Theme.ink)
        .animation(.easeInOut(duration: 0.2), value: store.focusMode)
        .sheet(item: Binding(get: { store.data.pendingFeedback }, set: { _ in })) { draft in
            FeedbackView(draft: draft).environmentObject(store).interactiveDismissDisabled()
        }
        .alert("需要处理", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("知道了") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "circle.lefthalf.filled").font(.system(size: 27, weight: .light)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("专注镜").font(.system(size: 23, weight: .semibold))
                    Text("FOCUS LENS").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(2.2).foregroundStyle(Theme.muted)
                }
            }
            .padding(.top, 48).padding(.bottom, 42)
            ForEach(Destination.allCases) { item in
                Button {
                    selection = item
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: item.symbol).font(.system(size: 15)).frame(width: 19)
                        Text(item.rawValue).font(.system(size: 14, weight: selection == item ? .semibold : .regular))
                        Spacer()
                        if item == .timer, store.data.activeRun != nil { Circle().fill(Theme.accent).frame(width: 6, height: 6) }
                    }
                    .foregroundStyle(selection == item ? Theme.accent : Theme.muted)
                    .padding(.horizontal, 14).padding(.vertical, 13)
                    .background(selection == item ? Theme.accent.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.bottom, 5)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 9) {
                Text("今日累计").font(.system(size: 11)).foregroundStyle(Theme.muted)
                Text(durationText(store.stats(.today).totalSeconds)).font(.system(size: 21, weight: .medium, design: .rounded))
                Text("\(store.stats(.today).sessions.count) 轮已记录").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 14).padding(.bottom, 30)
            Rectangle().fill(Theme.line).frame(height: 1)
            Text("记录保存在这台 Mac 上").font(.system(size: 10)).foregroundStyle(Theme.muted).padding(.top, 17).padding(.bottom, 25).padding(.leading, 14)
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 19).frame(width: 208).background(Theme.sidebar)
    }
}

struct PageTitle: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 29, weight: .semibold))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
    }
}

struct AccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 28).padding(.vertical, 13)
            .background(Theme.accent.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.35), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted)
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(Theme.line.opacity(configuration.isPressed ? 0.7 : 0.4), in: Capsule())
    }
}

struct Metric: View {
    let label: String
    let value: String
    var hint: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.muted)
            Text(value).font(.system(size: 29, weight: .medium, design: .rounded)).monospacedDigit()
            if let hint { Text(hint).font(.system(size: 10)).foregroundStyle(Theme.muted) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 15) {
            Image(systemName: symbol).font(.system(size: 36, weight: .ultraLight)).foregroundStyle(Theme.accent)
            Text(title).font(.system(size: 18, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted).multilineTextAlignment(.center).lineSpacing(4)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
    }
}
