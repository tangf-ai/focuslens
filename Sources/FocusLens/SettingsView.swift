import SwiftUI

struct SettingsWorkspace: View {
    @EnvironmentObject private var store: FocusStore
    @State private var focus = 25
    @State private var rest = 5
    @State private var baseURL = ""
    @State private var model = ""
    @State private var key = ""
    @State private var replaceKey = false
    @State private var saved = false
    @State private var confirmDeleteKey = false
    @State private var tagManagerOpen = false
    private var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版" }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                PageTitle(title: "设置", subtitle: "调整专注周期，连接你使用的 AI 服务")
                AutomaticSettings()
                Rectangle().fill(Theme.line).frame(height: 1)
                sectionTitle("专注与休息", symbol: "timer")
                HStack(spacing: 35) {
                    durationField("默认专注", value: $focus, range: 5...180)
                    durationField("默认休息", value: $rest, range: 1...60)
                    Spacer()
                }
                Text("开始后自动显示可拖动的置顶倒计时浮窗，关闭浮窗不会结束计时。专注模式会放大计时器并进入全屏，计时结束后退出由应用开启的全屏。休息需手动开始；应用不修改系统勿扰或通知设置，也不播放提示音。")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                Rectangle().fill(Theme.line).frame(height: 1)
                HStack {
                    VStack(alignment: .leading, spacing: 7) {
                        sectionTitle("专注标签", symbol: "tag")
                        Text("\(store.data.taskKinds.count) 个标签，可新增、改名和删除。")
                            .font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Button("管理标签") { tagManagerOpen = true }.buttonStyle(QuietButtonStyle())
                }
                Rectangle().fill(Theme.line).frame(height: 1)
                sectionTitle("AI 接口", symbol: "sparkles")
                VStack(alignment: .leading, spacing: 19) {
                    labeledField("接口基础地址", placeholder: "https://你的服务地址/v1", text: $baseURL)
                    Text("支持 Chat Completions 格式；可填写基础地址或完整地址。远程服务建议使用 HTTPS。")
                        .font(.system(size: 10)).foregroundStyle(Theme.muted).padding(.top, -11)
                    labeledField("模型名称", placeholder: "填写服务支持的模型名称", text: $model)
                    HStack {
                        Text("API 密钥").font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text(store.keyAvailable ? "已保存在系统钥匙串" : "尚未保存").font(.system(size: 10)).foregroundStyle(Theme.muted)
                    }
                    SecureField(store.keyAvailable ? "输入新密钥以替换；留空保留原密钥" : "填写 API 密钥；本地免鉴权接口可留空", text: $key)
                        .textFieldStyle(.roundedBorder).padding(.top, -9)
                        .onChange(of: key) { _, _ in replaceKey = !key.isEmpty; saved = false }
                    if store.keyAvailable {
                        Button("删除已保存的密钥", role: .destructive) { confirmDeleteKey = true }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent).padding(.top, -7)
                    }
                }.frame(maxWidth: 610, alignment: .leading)
                HStack {
                    Button("保存设置") { save() }.buttonStyle(AccentButtonStyle())
                    if saved { Label("已保存", systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(Theme.muted) }
                    Spacer()
                }
                Text("手动计时无需 AI 接口。自动记录仅在你授权并开启后发送前台窗口截图；复盘仍由你手动生成。")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(5)
                Rectangle().fill(Theme.line).frame(height: 1)
                sectionTitle("本地数据", symbol: "externaldrive")
                HStack(spacing: 12) {
                    Button("打开数据文件夹") { store.openDataDirectory() }.buttonStyle(QuietButtonStyle())
                    Button("导出全部记录") { store.exportSessions() }.buttonStyle(QuietButtonStyle()).disabled(store.data.sessions.isEmpty)
                }
                Text("记录和复盘保存在这台 Mac，密钥单独存入系统钥匙串。退出后计时会根据实际时间恢复；关闭应用或电脑睡眠期间，未暂停的时间仍会计入。离开工作前请先暂停。")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                Text("专注镜 \(appVersion) · 独立开发的专注工具").font(.system(size: 10)).foregroundStyle(Theme.muted).padding(.top, 8)
            }.padding(24).padding(.top, 4)
        }
        .sheet(isPresented: $tagManagerOpen) { TagManagerView().environmentObject(store) }
        .onAppear {
            focus = store.data.focusMinutes
            rest = store.data.restMinutes
            baseURL = store.data.aiSettings.baseURL
            model = store.data.aiSettings.model
        }
        .onChange(of: focus) { _, _ in saved = false }
        .onChange(of: rest) { _, _ in saved = false }
        .onChange(of: baseURL) { _, _ in saved = false }
        .onChange(of: model) { _, _ in saved = false }
        .confirmationDialog("从系统钥匙串删除 AI 密钥？", isPresented: $confirmDeleteKey, titleVisibility: .visible) {
            Button("删除密钥", role: .destructive) {
                do {
                    try store.deleteAIKey()
                    key = ""
                    replaceKey = false
                } catch { store.errorMessage = error.localizedDescription }
            }
            Button("取消", role: .cancel) { }
        }
    }

    private func sectionTitle(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.system(size: 15, weight: .semibold))
    }
    private func labeledField(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(label).font(.system(size: 12, weight: .medium))
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }
    private func durationField(_ label: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.muted)
            HStack(spacing: 8) {
                TextField("分钟", value: value, format: .number).textFieldStyle(.roundedBorder).frame(width: 58)
                Stepper("", value: value, in: range).labelsHidden()
                Text("分钟").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        }
    }
    private func save() {
        do {
            let settings = AISettings(baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines), model: model.trimmingCharacters(in: .whitespacesAndNewlines))
            try store.updateAI(settings: settings, newKey: replaceKey ? key.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
            store.updateDurations(focus: focus, rest: rest)
            focus = store.data.focusMinutes
            rest = store.data.restMinutes
            key = ""
            replaceKey = false
            saved = store.errorMessage == nil
        } catch { store.errorMessage = error.localizedDescription }
    }
}
