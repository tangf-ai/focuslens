import SwiftUI
import AppKit

@main
struct FocusLensApp: App {
    @StateObject private var store: FocusStore
    init() {
        let args = ProcessInfo.processInfo.arguments
        var directory: URL?
        if let index = args.firstIndex(of: "--data-directory"), index + 1 < args.count {
            directory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        }
        _store = StateObject(wrappedValue: FocusStore(directory: directory))
    }
    var body: some Scene {
        WindowGroup("专注镜", id: "main") {
            RootView().environmentObject(store).frame(minWidth: 860, minHeight: 620)
                .environmentObject(store.automatic)
                .preferredColorScheme(store.appearance.preferences.theme.isDark ? .dark : .light)
                .tint(Theme.accent)
                .environment(\.locale, Locale(identifier: "zh_CN"))
        }
        .defaultSize(width: 960, height: 680)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("专注") {
                Button("显示活动浮窗") { store.automatic.showFloating() }.disabled(!store.automatic.config.enabled)
                Button("活动浮窗移到当前屏幕") { store.automatic.moveFloatingToCurrentScreen() }
                    .help("移到鼠标当前所在的显示器").disabled(!store.automatic.config.enabled)
                Button("显示倒计时浮窗") { store.showFloatingTimer() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .disabled(store.data.activeRun == nil && store.data.pendingFeedback == nil)
                Button("倒计时浮窗移到当前屏幕") { store.moveFloatingTimerToCurrentScreen() }
                    .help("移到鼠标当前所在的显示器")
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

enum Destination: String, CaseIterable, Identifiable {
    case automatic = "自动记录", activity = "活动时间线", insights = "本周统计", review = "AI 复盘", timer = "手动计时", history = "专注记录", appearance = "外观与浮窗", settings = "设置"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .automatic: "viewfinder"
        case .activity: "list.bullet"
        case .timer: "timer"
        case .insights: "chart.bar.xaxis"
        case .history: "clock.arrow.circlepath"
        case .review: "sparkles"
        case .settings: "slider.horizontal.3"
        case .appearance: "paintpalette"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: FocusStore
    @EnvironmentObject private var activity: AutomaticTracker
    @State private var selection: Destination = .automatic
    @State private var automaticStatistics = true
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        HStack(spacing: 0) {
            if !store.focusMode { sidebar }
            Group {
                switch selection {
                case .automatic: AutomaticHome(onSettings: { selection = .settings }, onTimeline: { selection = .activity })
                case .activity: ActivityTimeline()
                case .timer: TimerWorkspace()
                case .insights:
                    VStack(spacing: 0) {
                        Picker("统计口径", selection: $automaticStatistics) { Text("自动活动").tag(true); Text("手动专注").tag(false) }
                            .pickerStyle(.segmented).frame(width: 260).padding(.top, 18)
                        if automaticStatistics { ActivityStatistics() } else { InsightsView() }
                    }
                case .history: HistoryView()
                case .review: ReviewView(stream: store.reviewStream, onSettings: { selection = .settings })
                case .settings: SettingsWorkspace()
                case .appearance: AppearanceWorkspace()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
        }
        .onAppear {
            let opener = openWindow
            store.openMainWindowAction = { opener(id: "main") }
            store.enableFloatingTimer()
            activity.openMain = { selection = .automatic; store.restoreMainWindow() }
            activity.installFloating()
            store.applyCompactMainWindow()
        }
        .foregroundStyle(Theme.ink)
        .animation(.easeInOut(duration: 0.2), value: store.focusMode)
        .sheet(item: Binding(get: { store.data.pendingFeedback }, set: { _ in })) { draft in
            FeedbackView(draft: draft).environmentObject(store).interactiveDismissDisabled()
        }
        .sheet(item: $activity.editingSegment) { ActivityEditSheet(segment: $0) }
        .alert("需要处理", isPresented: Binding(get: { store.errorMessage != nil || activity.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil; activity.errorMessage = nil } })) {
            Button("知道了") { store.errorMessage = nil; activity.errorMessage = nil }
        } message: { Text(store.errorMessage ?? activity.errorMessage ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "circle.lefthalf.filled").font(.system(size: 24, weight: .light)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("专注镜").font(.system(size: 21, weight: .semibold))
                    Text("FOCUS LENS").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(2.2).foregroundStyle(Theme.muted)
                }
            }
            .padding(.top, 26).padding(.bottom, 22)
            ForEach(Destination.allCases) { item in
                Button {
                    selection = item
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: item.symbol).font(.system(size: 15)).frame(width: 19)
                        Text(item.rawValue).font(.system(size: 13, weight: selection == item ? .semibold : .regular))
                        Spacer()
                        if item == .timer, store.data.activeRun != nil { Circle().fill(Theme.accent).frame(width: 6, height: 6) }
                    }
                    .foregroundStyle(selection == item ? Theme.accent : Theme.muted)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(selection == item ? Theme.accent.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.bottom, 3)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 9) {
                Text("手动专注累计").font(.system(size: 11)).foregroundStyle(Theme.muted)
                Text(durationText(store.stats(.today).totalSeconds)).font(.system(size: 21, weight: .medium, design: .rounded))
                Text("\(store.stats(.today).sessions.count) 轮已记录").font(.system(size: 11)).foregroundStyle(Theme.muted)
                Text(activity.status.label).font(.system(size: 10)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 14).padding(.bottom, 30)
            Rectangle().fill(Theme.line).frame(height: 1)
            Text("记录保存在这台 Mac 上").font(.system(size: 10)).foregroundStyle(Theme.muted).padding(.top, 17).padding(.bottom, 25).padding(.leading, 14)
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 14).frame(width: 180).background(Theme.sidebar)
    }
}

struct PageTitle: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 25, weight: .semibold))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
    }
}

struct AccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accentInk)
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
            Text(value).font(.system(size: 26, weight: .medium, design: .rounded)).monospacedDigit()
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
