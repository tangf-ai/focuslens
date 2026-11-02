import SwiftUI

struct AppearanceWorkspace: View {
    @EnvironmentObject private var store: FocusStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                PageTitle(title: "外观与浮窗", subtitle: "主题、背景与动态效果")
                AppearanceSettings(appearance: store.appearance)
            }.padding(26)
        }
    }
}

struct AppearanceSettings: View {
    let appearance: AppearanceStore
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("主题", systemImage: "palette").font(.system(size: 15, weight: .semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 12) {
                ForEach(FocusTheme.allCases) { theme in
                    let palette = theme.palette
                    Button { appearance.update { $0.theme = theme } } label: {
                        VStack(alignment: .leading, spacing: 11) {
                            HStack(spacing: 0) {
                                Rectangle().fill(Color(nsColor: palette.ns(\.side))).frame(width: 30)
                                VStack(alignment: .leading, spacing: 5) {
                                    Capsule().fill(Color(nsColor: palette.ns(\.accent))).frame(width: 60, height: 4)
                                    Capsule().fill(Color(nsColor: palette.ns(\.line))).frame(height: 4)
                                    Capsule().fill(Color(nsColor: palette.ns(\.line))).frame(width: 45, height: 4)
                                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(height: 58).background(Color(nsColor: palette.ns(\.paper))).clipShape(RoundedRectangle(cornerRadius: 7))
                            HStack {
                                Text(theme.name).font(.system(size: 12, weight: .medium))
                                Text(theme.isDark ? "深色" : "浅色").font(.system(size: 10)).foregroundStyle(Theme.muted)
                                Spacer(minLength: 0)
                                if appearance.preferences.theme == theme { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
                            }
                        }.padding(11).background(Theme.background)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(appearance.preferences.theme == theme ? Theme.accent : Theme.line, lineWidth: appearance.preferences.theme == theme ? 1.5 : 1))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("\(theme.name)，\(theme.isDark ? "深色" : "浅色")主题")
                        .accessibilityAddTraits(appearance.preferences.theme == theme ? .isSelected : [])
                }
            }
            Divider().overlay(Theme.line)
            Text("主窗口和悬浮胶囊同步切换主题。胶囊常驻 148 × 32 点，停留展开，移开收起；可拖动，贴边缩成小把手。")
                .font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(4)
            if let error = appearance.errorMessage { Text(error).font(.system(size: 12)).foregroundStyle(Theme.accent) }
            else { Label("外观已自动保存", systemImage: "checkmark").font(.system(size: 11)).foregroundStyle(Theme.muted) }
        }.foregroundStyle(Theme.ink)
    }
}
