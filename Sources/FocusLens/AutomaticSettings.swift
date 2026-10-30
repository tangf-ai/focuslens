import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AutomaticSettings: View {
    @EnvironmentObject private var activity: AutomaticTracker
    @State private var draft = AutomaticConfig()
    @State private var key = ""
    @State private var removeKey = false
    @State private var savedConfig: AutomaticConfig?
    @State private var guidanceSaveFailed = false
    @FocusState private var focusedGuidance: String?
    private var saved: Bool { savedConfig == draft && key.isEmpty }
    private var guidanceSaved: Bool {
        !guidanceSaveFailed && AutomaticConfig.guidanceText(draft.workBackground, limit: AutomaticConfig.backgroundLimit) == AutomaticConfig.guidanceText(activity.config.workBackground, limit: AutomaticConfig.backgroundLimit)
            && AutomaticConfig.guidanceText(draft.classificationRules, limit: AutomaticConfig.rulesLimit) == AutomaticConfig.guidanceText(activity.config.classificationRules, limit: AutomaticConfig.rulesLimit)
    }
    private var changed: Bool { draft.ai != activity.config.ai || draft.workBackground != activity.config.workBackground || draft.classificationRules != activity.config.classificationRules || draft.inactivitySettings != activity.config.inactivitySettings || draft.intervalSeconds != activity.config.intervalSeconds || draft.excludedApps != activity.config.excludedApps }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label("视觉模型与自动记录", systemImage: "scan.viewfinder").font(.system(size: 17, weight: .semibold))
            Text("本地、自部署与云端均使用兼容图片输入的 Chat Completions 接口。启用后截图会发至这里；自动小结需另外同意发送文字记录。")
                .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            TextField("视觉模型接口地址", text: $draft.ai.baseURL).textFieldStyle(.roundedBorder)
            TextField("支持图片输入的模型名称", text: $draft.ai.model).textFieldStyle(.roundedBorder)
            SecureField(activity.keyAvailable ? "新密钥（留空保留），独立存入钥匙串" : "API 密钥，本地免鉴权可留空", text: $key).textFieldStyle(.roundedBorder)
            Text("更换接口地址时，留空会清除旧服务的密钥，避免发送到新的服务。").font(.system(size: 10)).foregroundStyle(Theme.muted)
            if activity.keyAvailable { Button("清除视觉模型密钥") { removeKey = true }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent) }
            HStack(spacing: 20) {
                Picker("识别间隔", selection: $draft.intervalSeconds) {
                    ForEach(AutomaticConfig.samplingIntervals, id: \.self) { seconds in
                        Text(seconds < 60 ? "每 \(seconds) 秒" : "每 \(seconds / 60) 分钟").tag(seconds)
                    }
                }.frame(width: 240)
                Text("常规最多约 \(3600 / draft.intervalSeconds) 次 / 小时").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            Text("本地模型可先选15秒，再按响应速度调到5或10秒。切换应用会提前更新，最快间隔5秒；慢请求不叠加，已有结果继续显示。")
                .font(.system(size: 10)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            guidanceSettings
            inactivitySettings
            HStack { Text("不记录的应用").font(.system(size: 12)); Spacer(); Button("添加应用") { addApp() }.buttonStyle(.plain).foregroundStyle(Theme.accent) }
            ForEach(draft.excludedApps.keys.sorted(), id: \.self) { bundle in
                HStack {
                    Text(draft.excludedApps[bundle] ?? bundle).font(.system(size: 11)).foregroundStyle(Theme.muted)
                    Spacer()
                    Button("移除") { draft.excludedApps.removeValue(forKey: bundle) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
            }
            HStack {
                Button("保存自动记录设置") {
                    if activity.saveConfig(draft, newKey: key.isEmpty ? nil : key) { draft = activity.config; key = ""; savedConfig = draft }
                }
                    .buttonStyle(QuietButtonStyle()).disabled(activity.testing)
                Button(activity.testing ? "正在测试…" : "测试图片理解") { activity.testVision() }
                    .buttonStyle(QuietButtonStyle()).disabled(activity.testing || changed || !key.isEmpty)
            }
            if saved {
                Label("自动记录设置已保存", systemImage: "checkmark.circle")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            Text(activity.testMessage).font(.system(size: 11)).foregroundStyle(activity.verified ? Theme.muted : Theme.accent)
            if activity.config.enabled { Button("关闭自动记录") { activity.disable() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.accent) }
            Text("先保存再测试；测试使用随机数字与颜色示例图，不截取桌面。实际开启需另外确认发送截图并允许屏幕录制。截图只在内存处理，不写入缓存、日志或历史。")
                .font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        }.onAppear { draft = activity.config }
            .onChange(of: focusedGuidance) { previous, _ in
                if previous != nil { saveGuidance() }
            }
            .onDisappear { saveGuidance() }
            .confirmationDialog("清除视觉模型密钥？", isPresented: $removeKey, titleVisibility: .visible) {
                Button("清除密钥", role: .destructive) { activity.saveConfig(activity.config, newKey: ""); draft = activity.config; key = "" }
                Button("取消", role: .cancel) { }
            }
    }
    private var inactivitySettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("无操作检测", isOn: $draft.inactivitySettings.enabled).font(.system(size: 13, weight: .semibold))
            Text("连续无键鼠操作达到等待时间后，显示「可能已离开」，暂停累计与截图。恢复操作后约 5 秒内继续；空闲时段不补记，也不要求确认。")
                .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                inactivityPicker("通用等待", value: $draft.inactivitySettings.minutes, continuous: false)
                inactivityPicker("阅读时", value: $draft.inactivitySettings.readingMinutes, continuous: true)
                inactivityPicker("视频时", value: $draft.inactivitySettings.videoMinutes, continuous: true)
            }.disabled(!draft.inactivitySettings.enabled)
            Text("默认通用 5 分钟、阅读 15 分钟、视频 30 分钟。阅读和视频也可选择继续记录。只读取系统空闲时长，不记录按键内容，不新增模型请求。")
                .font(.system(size: 10)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }.padding(16).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
    }
    private func inactivityPicker(_ title: String, value: Binding<Int>, continuous: Bool) -> some View {
        Picker(title, selection: value) {
            ForEach(InactivitySettings.intervals, id: \.self) { Text("\($0) 分钟后暂停").tag($0) }
            if continuous { Text("继续记录").tag(0) }
        }.frame(width: 270)
    }
    private var guidanceSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("我的活动说明", systemImage: "text.bubble").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("恢复默认") { draft.workBackground = nil; draft.classificationRules = nil; saveGuidance() }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent)
                    .disabled((draft.workBackground ?? "").isEmpty && (draft.classificationRules ?? "").isEmpty)
            }
            Text("告诉 AI 你主要做什么、怎样区分活动，帮助减少误分类。说明会随截图发送到当前视觉模型服务；留空使用默认识别。")
                .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            guidanceEditor("我的工作背景", text: Binding(get: { draft.workBackground ?? "" }, set: { draft.workBackground = String($0.prefix(AutomaticConfig.backgroundLimit)) }),
                           limit: AutomaticConfig.backgroundLimit, placeholder: "例如：我主要从事软件开发、AI 应用研究，也会阅读技术资料和编写项目方案。", height: 72)
            guidanceEditor("活动分类习惯", text: Binding(get: { draft.classificationRules ?? "" }, set: { draft.classificationRules = String($0.prefix(AutomaticConfig.rulesLimit)) }),
                           limit: AutomaticConfig.rulesLimit, placeholder: "例如：在 AI 工具中修改代码、排查错误归为开发；查看技术文档归为阅读；编辑方案归为写作。请结合内容判断。", height: 108)
            Label(guidanceSaveFailed ? "活动说明保存失败，请检查磁盘空间和文件权限" : (guidanceSaved ? "活动说明已保存" : "活动说明尚未保存"), systemImage: guidanceSaved ? "checkmark.circle" : "pencil.circle")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
            Text("鼠标移出输入框时自动保存，切换输入框或离开设置页时也会保存。可用分类：阅读、写作、开发、沟通、视频、其他。证据不足保留为未识别。保存后用于后续识别，历史记录保留；恢复默认会立即清空并保存两项说明。")
                .font(.system(size: 10)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }.padding(16).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
    }
    private func guidanceEditor(_ title: String, text: Binding<String>, limit: Int, placeholder: String, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(text.wrappedValue.count) / \(limit)").font(.system(size: 10)).monospacedDigit().foregroundStyle(Theme.muted)
            }
            ZStack(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder).font(.system(size: 12)).foregroundStyle(Theme.muted)
                        .padding(.horizontal, 6).padding(.vertical, 8).allowsHitTesting(false)
                }
                TextEditor(text: text).font(.system(size: 12)).foregroundStyle(Theme.ink)
                    .focused($focusedGuidance, equals: title)
                    .scrollContentBackground(.hidden).padding(.vertical, 2)
                    .accessibilityLabel(title)
            }.frame(height: height).padding(.horizontal, 5)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line, lineWidth: 1))
                .onHover { inside in if !inside { saveGuidance() } }
        }
    }
    private func saveGuidance() {
        // Never normalize the live editor buffer or save a partially composed IME phrase.
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.hasMarkedText() { return }
        let success = activity.saveGuidance(workBackground: draft.workBackground, classificationRules: draft.classificationRules)
        guidanceSaveFailed = !success
        if success && focusedGuidance == nil {
            draft.workBackground = activity.config.workBackground
            draft.classificationRules = activity.config.classificationRules
        }
    }
    private func addApp() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]; panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        draft.excludedApps[id] = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent
    }
}
