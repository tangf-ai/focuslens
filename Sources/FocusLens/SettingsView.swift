import SwiftUI

struct SettingsWorkspace: View {
    @EnvironmentObject private var store: FocusStore
    @EnvironmentObject private var activity: AutomaticTracker
    @EnvironmentObject private var summary: AutomaticSummaryController
    @State private var showArchive = false
    @State private var showRecordingConsent = false
    @State private var recordingConsent = false
    @State private var showSummaryConsent = false
    @State private var confirmClear = false
    @State private var modelExpanded = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                PageTitle(title: "设置", subtitle: "配置一次，之后在后台自动记录。隐私控制始终由你决定。")
                section("记录与隐私") {
                    row("自动记录", detail: "授权后随应用启动；锁屏、睡眠和持续无操作时暂停。") {
                        Toggle("自动记录", isOn: Binding(get: { activity.config.enabled }, set: { enabled in
                            if enabled { recordingConsent = false; showRecordingConsent = true } else { activity.disable() }
                        })).labelsHidden().toggleStyle(.switch)
                    }
                    if activity.config.enabled { HStack { Text(activity.status.label).font(.system(size: 11)).foregroundStyle(Theme.muted); Spacer(); Button(activity.status == .paused ? "恢复记录" : "暂停记录") { if activity.status == .paused { activity.resume() } else { activity.pause() } }.buttonStyle(QuietButtonStyle()) } }
                    DisclosureGroup("识别服务、排除应用与等待时间", isExpanded: $modelExpanded) { AutomaticSettings().padding(.top, 18) }
                        .font(.system(size: 12)).tint(Theme.accent)
                }
                section("自动小结") {
                    row("根据文字记录自动整理", detail: "单独授权，仅发送活动文字到已确认的视觉服务。最多每天 3 次，不逐条调用。") {
                        Toggle("自动小结", isOn: Binding(get: { summary.enabled }, set: { enabled in
                            if enabled { showSummaryConsent = true } else { summary.disable() }
                        })).labelsHidden().toggleStyle(.switch).disabled(!summary.enabled && (!activity.config.enabled || !activity.verified || !summary.dataReadable))
                    }
                    Text("每天首次打开“今天”、12:30 和 18:30 按需更新；内容未变则跳过。退出或睡眠时不唤醒电脑，回来后不补发所有错过的任务。失败本时段不重复请求。").font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(5)
                    if summary.hasConsent && !summary.enabled {
                        Text("模型或密钥已变化，自动小结已停止。请核对服务后重新开启授权。").font(.system(size: 11)).foregroundStyle(Theme.accent)
                        Button("撤销旧的小结授权") { summary.disable() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent)
                    }
                    if let error = summary.errorMessage { Text(error).font(.system(size: 11)).foregroundStyle(Theme.accent) }
                }
                section("外观与浮窗") {
                    AppearanceSettings(appearance: store.appearance)
                    HStack { Text("浮窗仅显示当前活动与估算时长，不再显示倒计时。").font(.system(size: 11)).foregroundStyle(Theme.muted); Spacer(); Button("显示浮窗") { activity.showFloating() }.buttonStyle(QuietButtonStyle()).disabled(!activity.config.enabled) }
                }
                section("数据与归档") {
                    row("旧版记录与复盘", detail: "手动记录、旧复盘和升级前未完成轮次仅供只读查看，不混入自动统计。") { Button("查看归档") { showArchive = true }.buttonStyle(QuietButtonStyle()) }
                    if let transition = store.data.legacyTransition {
                        Text("已在 \(transition.migratedAt.formatted(.dateTime.month().day().hour().minute())) 完成迁移并保存完整备份。原计时已停止，未填写的反馈原样归档，没有虚构完成情况。").font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(5)
                    }
                    HStack {
                        Button("导出全部记录") { store.exportAll() }.buttonStyle(QuietButtonStyle())
                        Button("打开数据文件夹") { store.openDataDirectory() }.buttonStyle(QuietButtonStyle())
                        Spacer()
                        Button("清除自动活动", role: .destructive) { confirmClear = true }.buttonStyle(.plain).font(.system(size: 11))
                    }
                    Text("记录和小结保存在本机；密钥保存在系统钥匙串。导出包含活动文字及旧版个人记录，分享前请检查。应用不持久化截图，模型服务端留存取决于服务提供方。").font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(5)
                    Text("本机识别诊断仅保留最近 200 次的时间、阶段、结果和脱敏错误码，不含截图、窗口标题、接口地址或响应正文。清除自动活动时一并备份并清除。")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(5)
                    if let warning = activity.diagnosticWarning { Text(warning).font(.system(size: 11)).foregroundStyle(Theme.accent) }
                }
                Text("专注镜 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版") · 自动活动日志").font(.system(size: 10)).foregroundStyle(Theme.muted)
            }.padding(30)
        }.onAppear { modelExpanded = !activity.verified }
            .sheet(isPresented: $showArchive) { LegacyArchiveView() }
            .sheet(isPresented: $showRecordingConsent) { recordingSheet }
            .confirmationDialog("允许自动小结发送文字记录？", isPresented: $showSummaryConsent, titleVisibility: .visible) {
                Button("同意并开启") { _ = summary.enable(consent: true) }
                Button("取消", role: .cancel) { }
            } message: {
                Text("接收方：\(activity.config.ai.baseURL)\n模型：\(activity.config.ai.model)\n将发送当天活动的时间、类别、应用名和文字概括，不发送历史截图。每天最多 3 次，可随时关闭。")
            }
            .confirmationDialog("清除所有自动活动与小结？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("备份后清除", role: .destructive) { _ = store.clearAutomaticData() }
                Button("取消", role: .cancel) { }
            } message: { Text("将先保存本机完整备份，然后关闭记录与小结并清除活动。旧版手动归档保留。备份仍包含这些数据；此操作不是安全擦除，也不会删除模型服务端的数据。") }
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 20) { Text(title).font(.system(size: 15, weight: .semibold)); content() }
            .padding(.top, 23).overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
    private func row<Control: View>(_ title: String, detail: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 30) {
            VStack(alignment: .leading, spacing: 7) { Text(title).font(.system(size: 12, weight: .medium)); Text(detail).font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(4) }.frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
    }
    private var recordingSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("开启自动记录").font(.system(size: 23, weight: .semibold))
            Text("接收方：\(activity.config.ai.baseURL)\n模型：\(activity.config.ai.model)").font(.system(size: 12)).textSelection(.enabled)
            Text(activity.verified ? "图片理解已通过。截图只在内存处理；服务端留存取决于所选服务。" : "请先关闭此窗口，在识别服务中保存配置并通过图片理解测试。").font(.system(size: 12)).foregroundStyle(Theme.muted).lineSpacing(5)
            Button(activity.hasPermission ? "屏幕录制已允许" : "允许屏幕录制") { activity.requestPermission() }.disabled(activity.hasPermission)
            Toggle("同意向上述服务发送前台窗口截图", isOn: $recordingConsent).font(.system(size: 12))
            HStack { Spacer(); Button("取消") { showRecordingConsent = false }.buttonStyle(QuietButtonStyle()); Button("同意并开启") { activity.enable(consent: recordingConsent); showRecordingConsent = !activity.config.enabled }.buttonStyle(AccentButtonStyle()).disabled(!recordingConsent || !activity.verified || !activity.hasPermission) }
        }.padding(30).frame(width: 540).background(Theme.background)
    }
}

struct LegacyArchiveView: View {
    @EnvironmentObject private var store: FocusStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { PageTitle(title: "旧版只读归档", subtitle: "原记录保留，不再创建轮次，也不混入自动统计。"); Spacer(); Button("关闭") { dismiss() }.buttonStyle(QuietButtonStyle()) }
            TextField("搜索目标、标签、反馈或旧复盘", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let transition = store.data.legacyTransition {
                        if let run = transition.activeRun { DisclosureGroup("升级时已停止的轮次 · \(goalDisplayText(run.goal))") {
                            Text("开始于 \(run.startedAt.formatted())\n停止时有效时长：\(durationText(run.elapsed(at: transition.migratedAt)))\n原标签：\(run.kind.displayName)\n没有生成完成情况或评分。").font(.system(size: 12)).lineSpacing(5).padding(.vertical, 10)
                        } }
                        if let pending = transition.pendingFeedback { DisclosureGroup("升级时待反馈 · \(goalDisplayText(pending.goal))") { Text("\(durationText(pending.focusSeconds)) · \(pending.kind.displayName)\n结束于 \(pending.endedAt.formatted())\n反馈未填写，原样保留。").font(.system(size: 12)).lineSpacing(5).padding(.vertical, 10) } }
                    }
                    Text("历史手动记录 · \(store.data.sessions.count) 条").font(.system(size: 14, weight: .semibold))
                    ForEach(store.data.sessions.filter { query.isEmpty || ($0.goal + $0.note + $0.kind.displayName).localizedCaseInsensitiveContains(query) }.sorted { $0.startedAt > $1.startedAt }) { session in
                        DisclosureGroup(goalDisplayText(session.goal)) {
                            Text("\(session.startedAt.formatted()) · \(session.kind.displayName)\n有效时长：\(durationText(session.focusSeconds)) · 原反馈：\(session.outcome.rawValue)\n原自评分：\(session.rating.map(String.init) ?? "未填写")\n备注：\(session.note.isEmpty ? "未填写" : session.note)")
                                .font(.system(size: 12)).lineSpacing(5).textSelection(.enabled).padding(.vertical, 10)
                        }
                    }
                    Divider()
                    Text("旧版复盘 · \(store.data.reviews.count) 份").font(.system(size: 14, weight: .semibold))
                    ForEach(store.data.reviews.filter { query.isEmpty || $0.transcript.localizedCaseInsensitiveContains(query) }) { review in
                        DisclosureGroup("\(review.createdAt.formatted(.dateTime.month().day().hour().minute())) · \(review.model)") {
                            Text(review.transcript).font(.system(size: 12)).lineSpacing(5).textSelection(.enabled).padding(.vertical, 10)
                        }
                    }
                    if store.data.sessions.isEmpty && store.data.reviews.isEmpty { Text("没有旧版历史记录。").font(.system(size: 12)).foregroundStyle(Theme.muted) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Text("导出包含新活动、小结和全部旧版归档，不含密钥。").font(.system(size: 10)).foregroundStyle(Theme.muted); Spacer(); Button("导出全部记录") { store.exportAll() }.buttonStyle(QuietButtonStyle()) }
        }.padding(30).frame(width: 720, height: 580).background(Theme.background)
    }
}
