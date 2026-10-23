import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AutomaticHome: View {
    @EnvironmentObject private var activity: AutomaticTracker
    let onSettings: () -> Void
    let onTimeline: () -> Void
    @State private var consent = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                PageTitle(title: "自动记录", subtitle: Date().formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day().weekday()))
                Spacer()
                if activity.config.enabled {
                    AutomaticPauseButton()
                    Button("浮窗") { activity.showFloating() }.buttonStyle(QuietButtonStyle())
                }
            }
            if activity.undoSnapshot != nil {
                Button("撤销上一次分类修正") { activity.undoCorrection() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent)
            }
            if !activity.config.enabled {
                Spacer()
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "circle.lefthalf.filled").font(.system(size: 42, weight: .light)).foregroundStyle(Theme.accent)
                    Text("正在做的事，自动记下来。").font(.system(size: 26, weight: .medium))
                    Text("由你配置的视觉模型识别前台窗口。时间在本地计算，截图只在内存中处理，用完释放。")
                        .font(.system(size: 13)).foregroundStyle(Theme.muted).lineSpacing(5)
                    Button("配置视觉模型", action: onSettings).buttonStyle(QuietButtonStyle())
                    HStack {
                        Label(activity.verified ? "图片理解已通过" : "需要先通过图片理解测试", systemImage: activity.verified ? "checkmark.circle" : "photo")
                        Spacer()
                        Button(activity.hasPermission ? "屏幕权限已允许" : "允许屏幕录制") { activity.requestPermission() }.disabled(activity.hasPermission)
                    }.font(.system(size: 11)).foregroundStyle(Theme.muted)
                    Toggle("允许将前台窗口截图发送至当前模型服务进行识别", isOn: $consent).font(.system(size: 12))
                    Text(activity.config.ai.baseURL).font(.system(size: 11)).foregroundStyle(Theme.muted).textSelection(.enabled)
                    Button("开启自动记录") { activity.enable(consent: consent) }
                        .buttonStyle(AccentButtonStyle()).disabled(!activity.verified || !activity.hasPermission || !consent || activity.testing)
                    Text("排除的应用不截图；敏感网页请先暂停。截图不写入本机文件，服务端留存由所选服务决定。")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(4)
                }.frame(maxWidth: 510, alignment: .leading)
                Spacer()
            } else {
                TimelineView(.periodic(from: Date(), by: 5)) { context in
                    let item = activity.liveSegment(at: context.date)
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(activity.status.label, systemImage: "circle.fill").font(.system(size: 11)).foregroundStyle(Theme.accent)
                            Text(visibleTitle(item)).font(.system(size: 25, weight: .medium)).lineLimit(2)
                            Text(activity.recognitionDetail(at: context.date)).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(3)
                            Button(activity.isRecognizing ? "正在更新…" : "立即更新") { activity.retry() }
                                .buttonStyle(.plain).foregroundStyle(Theme.accent).disabled(!activity.canRefresh)
                            if !activity.hasPermission { Button("允许屏幕录制") { activity.requestPermission() }.buttonStyle(.plain).foregroundStyle(Theme.accent) }
                            if let item, activity.current != nil {
                                Button("修改分类") { activity.edit(item) }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.accent)
                            }
                        }
                        Spacer()
                        Text(visibleTime(item)).font(.system(size: 32, weight: .light, design: .rounded)).monospacedDigit()
                    }.padding(.vertical, 15)
                }
                Rectangle().fill(Theme.line).frame(height: 1)
                let records = activity.segments(in: Period.today.interval())
                HStack(spacing: 28) {
                    Metric(label: "今天自动记录", value: "约 \(Int(records.reduce(0) { $0 + $1.seconds } / 60)) 分")
                    Metric(label: "阅读", value: "约 \(Int(records.filter { $0.category == .reading }.reduce(0) { $0 + $1.seconds } / 60)) 分")
                    Metric(label: "待确认分类", value: "约 \(Int(records.filter { $0.category == .unknown }.reduce(0) { $0 + $1.seconds } / 60)) 分")
                }
                if activity.reminderVisible {
                    HStack {
                        Text("已经连续活动一段时间，要休息一下吗？").font(.system(size: 12))
                        Spacer()
                        Button("休息5分钟") { activity.rest() }
                        Button("继续") { activity.ignoreReminder() }
                    }.padding(12).background(Theme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                }
                HStack { Text("最近的活动").font(.system(size: 13, weight: .semibold)); Spacer(); Button("完整时间线", action: onTimeline).buttonStyle(.plain).foregroundStyle(Theme.accent) }
                if records.isEmpty { Text("切换到工作窗口后开始识别；没有识别结果前，不推测具体活动。").font(.system(size: 12)).foregroundStyle(Theme.muted) }
                ForEach(Array(records.prefix(3))) { ActivityRow(segment: $0) }
                Spacer(minLength: 0)
                Text("每 \(activity.config.intervalLabel)识别 · 切换应用提前更新 · 截图不保存 · 时长为估算")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted)
            }
        }.padding(25)
    }
    private func visibleTitle(_ item: ActivitySegment?) -> String {
        switch activity.status {
        case .recording, .uncertain, .waiting, .recognizing, .error: return activity.current != nil ? item?.title ?? "正在判断当前活动" : "当前活动待确认"
        case .paused: return item?.title ?? "自动记录已暂停"
        default: return activity.status.label
        }
    }
    private func visibleTime(_ item: ActivitySegment?) -> String {
        switch activity.status {
        case .recording, .uncertain, .waiting, .recognizing, .error: return activity.current != nil ? "约 \(Int((item?.seconds ?? 0) / 60)) 分钟" : "—"
        case .paused: return item.map { "约 \(Int($0.seconds / 60)) 分钟" } ?? "—"
        default: return "—"
        }
    }
}

struct AutomaticPauseButton: View {
    @EnvironmentObject private var activity: AutomaticTracker
    var body: some View {
        switch activity.status {
        case .paused, .resting: Button("恢复记录") { activity.resume() }.buttonStyle(QuietButtonStyle())
        case .excluded, .away, .manual: Text(activity.status.label).font(.system(size: 11)).foregroundStyle(Theme.muted)
        default: Button("暂停记录") { activity.pause() }.buttonStyle(QuietButtonStyle())
        }
    }
}

struct ActivityRow: View {
    @EnvironmentObject private var activity: AutomaticTracker
    let segment: ActivitySegment
    var body: some View {
        Button { activity.edit(segment) } label: {
            HStack(alignment: .center, spacing: 14) {
                Text(segment.start.formatted(.dateTime.hour().minute()) + " — " + segment.end.formatted(.dateTime.hour().minute()))
                    .font(.system(size: 10)).foregroundStyle(Theme.muted).frame(width: 100, alignment: .leading).monospacedDigit()
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(segment.category.rawValue) · \(segment.title)").font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text("\(segment.app) · \(segment.corrected ? "已确认分类 · 时间仍为估算" : "自动估算")").font(.system(size: 10)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Text("约 " + durationText(segment.seconds)).font(.system(size: 11)).foregroundStyle(Theme.muted)
            }.contentShape(Rectangle()).padding(.vertical, 11)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.line.opacity(0.5)).frame(height: 1) }
        }.buttonStyle(.plain)
    }
}

struct ActivityTimeline: View {
    @EnvironmentObject private var activity: AutomaticTracker
    @State private var day = Date()
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageTitle(title: "活动时间线", subtitle: "自动活动按片段整理；手动专注记录仍单独保留")
            HStack {
                DatePicker("日期", selection: $day, in: ...Date(), displayedComponents: .date).frame(width: 240)
                Spacer()
                Button("导出自动记录") { export() }.buttonStyle(QuietButtonStyle())
            }
            if activity.undoSnapshot != nil { Button("撤销上一次分类修正") { activity.undoCorrection() }.buttonStyle(.plain).foregroundStyle(Theme.accent).font(.system(size: 12)) }
            let interval = Calendar.current.dateInterval(of: .day, for: day)!
            let records = activity.segments(in: interval)
            Text("约 " + durationText(records.reduce(0) { $0 + $1.seconds })).font(.system(size: 26, weight: .medium))
            ScrollView {
                LazyVStack(spacing: 0) { ForEach(records) { ActivityRow(segment: $0) } }
                if records.isEmpty { Text("这一天还没有自动活动记录。").font(.system(size: 13)).foregroundStyle(Theme.muted).padding(.top, 60) }
            }
            Text("点击片段修正分类或描述。没有历史截图，断连期间的活动需要手动补充分类。")
                .font(.system(size: 10)).foregroundStyle(Theme.muted)
        }.padding(25)
    }
    private func export() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "自动活动.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let records = activity.segments(in: Calendar.current.dateInterval(of: .day, for: day)!)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(records).write(to: url, options: .atomic)
        } catch { activity.errorMessage = "导出失败，请检查保存位置。" }
    }
}

struct ActivityEditSheet: View {
    @EnvironmentObject private var activity: AutomaticTracker
    let segment: ActivitySegment
    @State private var category: ActivityCategory = .other
    @State private var title = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("修改这段活动").font(.system(size: 23, weight: .semibold))
            Text("人工分类优先，时间仍保留为自动估算。").font(.system(size: 12)).foregroundStyle(Theme.muted)
            Picker("活动分类", selection: $category) { ForEach(ActivityCategory.allCases) { Text($0.rawValue).tag($0) } }
            TextField("活动描述", text: $title).textFieldStyle(.roundedBorder).onChange(of: title) { _, value in if value.count > 100 { title = String(value.prefix(100)) } }
            HStack {
                Spacer()
                Button("取消") { activity.editingSegment = nil }.buttonStyle(QuietButtonStyle())
                Button("保存修改") { activity.correct(id: segment.id, category: category, title: title) }.buttonStyle(AccentButtonStyle())
            }
        }.padding(30).frame(width: 470).background(Theme.background)
            .onAppear { category = segment.category; title = segment.title }
    }
}

struct AutomaticSettings: View {
    @EnvironmentObject private var activity: AutomaticTracker
    @EnvironmentObject private var store: FocusStore
    @State private var draft = AutomaticConfig()
    @State private var key = ""
    @State private var removeKey = false
    private var changed: Bool { draft.ai != activity.config.ai || draft.intervalSeconds != activity.config.intervalSeconds || draft.reminderMinutes != activity.config.reminderMinutes || draft.reminders != activity.config.reminders || draft.excludedApps != activity.config.excludedApps }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label("视觉模型与自动记录", systemImage: "scan.viewfinder").font(.system(size: 17, weight: .semibold))
            Text("本地、自部署与云端均使用兼容图片输入的 Chat Completions 接口。启用后截图会发至这里，不影响下面的原有复盘接口。")
                .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            TextField("视觉模型接口地址", text: $draft.ai.baseURL).textFieldStyle(.roundedBorder)
            TextField("支持图片输入的模型名称", text: $draft.ai.model).textFieldStyle(.roundedBorder)
            SecureField(activity.keyAvailable ? "新密钥（留空保留），独立存入钥匙串" : "API 密钥，本地免鉴权可留空", text: $key).textFieldStyle(.roundedBorder)
            Text("更换接口地址时，留空会清除旧服务的密钥，避免发送到新的服务。").font(.system(size: 10)).foregroundStyle(Theme.muted)
            if activity.keyAvailable { Button("清除视觉模型密钥") { removeKey = true }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent) }
            HStack {
                Button("复制复盘配置") {
                    draft.ai = store.data.aiSettings
                    do { key = try store.reviewAPIKey() ?? "" } catch { activity.errorMessage = error.localizedDescription }
                }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent)
                Spacer()
            }
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
            Toggle("连续活动后在浮窗轻提示休息", isOn: $draft.reminders).font(.system(size: 12))
            Picker("提醒间隔", selection: $draft.reminderMinutes) { ForEach([25,30,45,60], id: \.self) { Text("\($0) 分钟").tag($0) } }.frame(width: 240)
            HStack { Text("不记录的应用").font(.system(size: 12)); Spacer(); Button("添加应用") { addApp() }.buttonStyle(.plain).foregroundStyle(Theme.accent) }
            ForEach(draft.excludedApps.keys.sorted(), id: \.self) { bundle in
                HStack {
                    Text(draft.excludedApps[bundle] ?? bundle).font(.system(size: 11)).foregroundStyle(Theme.muted)
                    Spacer()
                    Button("移除") { draft.excludedApps.removeValue(forKey: bundle) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
            }
            HStack {
                Button("保存自动记录设置") { activity.saveConfig(draft, newKey: key.isEmpty ? nil : key); draft = activity.config; key = "" }
                    .buttonStyle(QuietButtonStyle()).disabled(activity.testing)
                Button(activity.testing ? "正在测试…" : "测试图片理解") { activity.testVision() }
                    .buttonStyle(QuietButtonStyle()).disabled(activity.testing || changed || !key.isEmpty)
            }
            Text(activity.testMessage).font(.system(size: 11)).foregroundStyle(activity.verified ? Theme.muted : Theme.accent)
            if activity.config.enabled { Button("关闭自动记录") { activity.disable() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.accent) }
            Text("先保存再测试；测试使用随机数字与颜色示例图，不截取桌面。实际开启需另外确认发送截图并允许屏幕录制。截图只在内存处理，不写入缓存、日志或历史。")
                .font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        }.onAppear { draft = activity.config }
            .confirmationDialog("清除视觉模型密钥？", isPresented: $removeKey, titleVisibility: .visible) {
                Button("清除密钥", role: .destructive) { activity.saveConfig(activity.config, newKey: ""); draft = activity.config; key = "" }
                Button("取消", role: .cancel) { }
            }
    }
    private func addApp() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]; panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        draft.excludedApps[id] = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent
    }
}

struct ActivityStatistics: View {
    @EnvironmentObject private var activity: AutomaticTracker
    var body: some View {
        let records = activity.segments(in: Period.week.interval())
        VStack(alignment: .leading, spacing: 20) {
            PageTitle(title: "本周自动活动", subtitle: "自动时长为估算，与手动专注分开统计")
            Text("约 " + durationText(records.reduce(0) { $0 + $1.seconds })).font(.system(size: 31, weight: .medium))
            ForEach(ActivityCategory.allCases) { category in
                let seconds = records.filter { $0.category == category }.reduce(0) { $0 + $1.seconds }
                if seconds > 0 {
                    HStack { Text(category.rawValue).font(.system(size: 13)); Spacer(); Text("约 " + durationText(seconds)).font(.system(size: 13)).foregroundStyle(Theme.muted) }
                    ProgressView(value: seconds, total: max(1, records.reduce(0) { $0 + $1.seconds })).tint(Theme.accent)
                }
            }
            Spacer()
            Text("活动时长不代表专注程度，不计算自动完成率或效率分。").font(.system(size: 11)).foregroundStyle(Theme.muted)
        }.padding(25)
    }
}
