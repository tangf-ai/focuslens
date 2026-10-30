import SwiftUI
import AppKit

@main
struct FocusLensApp: App {
    @StateObject private var store: FocusStore
    init() {
        let args = ProcessInfo.processInfo.arguments
        var directory: URL?
        if let index = args.firstIndex(of: "--data-directory"), index + 1 < args.count { directory = URL(fileURLWithPath: args[index + 1], isDirectory: true) }
        _store = StateObject(wrappedValue: FocusStore(directory: directory))
    }
    var body: some Scene {
        WindowGroup("专注镜", id: "main") {
            RootView().environmentObject(store).environmentObject(store.automatic).environmentObject(store.summary)
                .frame(minWidth: 860, minHeight: 620)
                .preferredColorScheme(store.appearance.preferences.theme.isDark ? .dark : .light)
                .tint(Theme.accent).environment(\.locale, Locale(identifier: "zh_CN"))
        }
        .defaultSize(width: 1080, height: 760).windowStyle(.hiddenTitleBar).windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("记录") {
                Button("显示活动浮窗") { store.automatic.showFloating() }
                    .keyboardShortcut("m", modifiers: [.command, .shift]).disabled(!store.automatic.config.enabled)
                Button("活动浮窗移到当前屏幕") { store.automatic.moveFloatingToCurrentScreen() }.disabled(!store.automatic.config.enabled)
                Button("暂停 / 恢复记录") {
                    if store.automatic.status == .paused { store.automatic.resume() } else { store.automatic.pause() }
                }.keyboardShortcut(.space, modifiers: [.command]).disabled(!store.automatic.config.enabled)
            }
        }
    }
}

enum Destination: String, CaseIterable, Identifiable {
    case today = "今天", activity = "时间线", insights = "时间洞察", settings = "设置"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .today: "calendar"; case .activity: "list.bullet"; case .insights: "chart.bar.xaxis"; case .settings: "slider.horizontal.3" }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: FocusStore
    @EnvironmentObject private var activity: AutomaticTracker
    @EnvironmentObject private var summary: AutomaticSummaryController
    @Environment(\.openWindow) private var openWindow
    @State private var selection: Destination = .today
    init(initialDestination: Destination = .today) { _selection = State(initialValue: initialDestination) }
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                HStack {
                    Text("工作空间 / \(selection.rawValue)").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    Spacer()
                    Button { activity.showFloating() } label: { Label("小浮窗", systemImage: "pip") }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.muted).disabled(!activity.config.enabled)
                }.padding(.horizontal, 30).frame(height: 45)
                Rectangle().fill(Theme.line).frame(height: 1)
                Group {
                    switch selection {
                    case .today: AutomaticHome(onSettings: { selection = .settings }, onTimeline: { selection = .activity })
                    case .activity: ActivityTimeline()
                    case .insights: ActivityStatistics()
                    case .settings: SettingsWorkspace()
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.background(Theme.background)
        }
        .foregroundStyle(Theme.ink)
        .onAppear {
            let opener = openWindow
            store.openMainWindowAction = { opener(id: "main") }
            activity.openMain = { selection = .today; store.restoreMainWindow() }
            activity.installFloating(); store.applyCompactMainWindow()
        }
        .alert("需要处理", isPresented: Binding(get: { store.errorMessage != nil || activity.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil; activity.errorMessage = nil } })) {
            Button("知道了") { store.errorMessage = nil; activity.errorMessage = nil }
        } message: { Text(store.errorMessage ?? activity.errorMessage ?? "") }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "circle.lefthalf.filled").font(.system(size: 28, weight: .light)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("专注镜").font(.system(size: 21, weight: .semibold))
                    Text("FOCUS LENS").font(.system(size: 8, design: .monospaced)).tracking(2).foregroundStyle(Theme.muted)
                }
            }.padding(.top, 42).padding(.bottom, 38).padding(.leading, 11)
            Text("工作空间").font(.system(size: 10)).foregroundStyle(Theme.muted.opacity(0.7)).padding(.leading, 14).padding(.bottom, 12)
            ForEach(Destination.allCases.filter { $0 != .settings }) { navigation($0) }
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Label(activity.status.label, systemImage: "circle.fill").font(.system(size: 10)).foregroundStyle(Theme.muted)
                Text("只在你工作时记录").font(.system(size: 10)).foregroundStyle(Theme.muted.opacity(0.7))
            }.padding(.horizontal, 14).padding(.bottom, 28)
            navigation(.settings)
            Rectangle().fill(Theme.line).frame(height: 1).padding(.top, 15)
            Label("活动记录保存在本机", systemImage: "lock").font(.system(size: 9)).foregroundStyle(Theme.muted.opacity(0.75))
                .padding(.top, 18).padding(.bottom, 24).padding(.leading, 14)
        }.padding(.horizontal, 13).frame(width: 184).background(Theme.sidebar)
    }
    private func navigation(_ item: Destination) -> some View {
        Button { selection = item } label: {
            HStack(spacing: 12) {
                Image(systemName: item.symbol).frame(width: 18)
                Text(item.rawValue)
                Spacer()
            }.font(.system(size: 13, weight: selection == item ? .semibold : .regular))
                .foregroundStyle(selection == item ? Theme.accent : Theme.muted)
                .padding(.horizontal, 13).padding(.vertical, 12)
                .background(selection == item ? Theme.accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).padding(.bottom, 4)
    }
}

struct PageTitle: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 26, weight: .semibold))
            Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
    }
}
struct AccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accentInk)
            .padding(.horizontal, 20).padding(.vertical, 11)
            .background(Theme.accent.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.35), in: RoundedRectangle(cornerRadius: 7))
    }
}
struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted.opacity(enabled ? 1 : 0.5))
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Theme.line.opacity(configuration.isPressed ? 0.7 : 0.3), in: RoundedRectangle(cornerRadius: 6))
    }
}
struct Metric: View {
    let label: String
    let value: String
    var hint: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(label).font(.system(size: 10)).foregroundStyle(Theme.muted)
            Text(value).font(.system(size: 26, weight: .regular, design: .rounded)).monospacedDigit().minimumScaleFactor(0.65).lineLimit(1)
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
            Image(systemName: symbol).font(.system(size: 30, weight: .ultraLight)).foregroundStyle(Theme.accent)
            Text(title).font(.system(size: 16, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted).multilineTextAlignment(.center).lineSpacing(4)
        }.frame(maxWidth: .infinity).padding(.vertical, 45)
    }
}
