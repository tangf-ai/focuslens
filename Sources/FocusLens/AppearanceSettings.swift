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
    private func binding<Value>(_ key: WritableKeyPath<AppearancePreferences, Value>) -> Binding<Value> {
        Binding(get: { appearance.preferences[keyPath: key] }, set: { value in appearance.update { $0[keyPath: key] = value } })
    }
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
            Text("主窗口和轻量活动浮窗同步切换主题；浮窗不再使用圆环、倒计时或装饰动画。")
                .font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(4)
            DisclosureGroup("大小与圆角") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("宽度 \(Int(appearance.preferences.width)) 点"); Slider(value: binding(\.width), in: 290...360, step: 2) }
                    HStack { Text("圆角 \(Int(appearance.preferences.radius)) 点"); Slider(value: binding(\.radius), in: 16...36, step: 1) }
                }.font(.system(size: 12)).padding(.top, 10)
            }.frame(maxWidth: 460)
            if let error = appearance.errorMessage { Text(error).font(.system(size: 12)).foregroundStyle(Theme.accent) }
            else { Label("外观已自动保存", systemImage: "checkmark").font(.system(size: 11)).foregroundStyle(Theme.muted) }
        }.foregroundStyle(Theme.ink)
    }
}
