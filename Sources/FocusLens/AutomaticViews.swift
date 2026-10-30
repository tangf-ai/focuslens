import SwiftUI
import AppKit
import Charts
import UniformTypeIdentifiers

extension ActivityCategory {
    @MainActor var color: Color {
        let opacity: Double = switch self { case .development: 1; case .reading: 0.65; case .writing: 0.8; case .communication: 0.43; case .video: 0.52; case .other: 0.27; case .unknown: 0.15 }
        return Theme.accent.opacity(opacity)
    }
}
extension ActivityPresentation.DistributionItem {
    @MainActor var color: Color {
        switch reason {
        case .waiting: Theme.muted.opacity(0.4)
        case .failure: Color.orange.opacity(0.65)
        case .insufficientEvidence: Theme.accent.opacity(0.25)
        case .legacy: Theme.muted.opacity(0.25)
        case nil: category.color
        }
    }
}
func compactDuration(_ seconds: TimeInterval) -> String {
    let minutes = max(0, Int(seconds / 60))
    return minutes < 60 ? "\(minutes) 分" : "\(minutes / 60) 小时 \(minutes % 60) 分"
}

struct AutomaticHome: View {
    @EnvironmentObject private var activity: AutomaticTracker
    @EnvironmentObject private var store: FocusStore
    @EnvironmentObject private var summary: AutomaticSummaryController
    let onSettings: () -> Void
    let onTimeline: () -> Void
    @State private var consent = false
    @State private var selected: ActivitySegment?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .top) {
                    PageTitle(title: "今天的时间", subtitle: "活动自动整理，无需开始或结束计时。")
                    Spacer()
                    Text(store.now.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day().weekday())).font(.system(size: 11)).foregroundStyle(Theme.muted).padding(.top, 10)
                }
                let read = try? activity.readSegments(in: Period.today.interval(now: store.now))
                let records = read ?? []
                if !activity.config.enabled && records.isEmpty && read != nil { onboarding }
                else {
                    if activity.config.enabled { CurrentActivityBand() }
                    else {
                        HStack { Label("自动记录已关闭 · 已有活动仍可查看", systemImage: "pause.circle"); Spacer(); Button("记录设置", action: onSettings).buttonStyle(QuietButtonStyle()) }.font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                    if read == nil { EmptyState(symbol: "exclamationmark.triangle", title: "活动文件无法读取", detail: "暂不展示不完整统计。请先备份并检查数据目录。") }
                    else {
                    HStack(alignment: .top, spacing: 28) {
                        VStack(alignment: .leading, spacing: 23) {
                            HStack { Text("时间分布").font(.system(size: 14, weight: .semibold)); Spacer(); Text("今天 · 估算").font(.system(size: 10)).foregroundStyle(Theme.muted) }
                            HStack(spacing: 20) {
                                Metric(label: "已记录", value: compactDuration(records.reduce(0) { $0 + $1.seconds }))
                                Metric(label: "开发", value: compactDuration(records.filter { $0.category == .development }.reduce(0) { $0 + $1.seconds }))
                                Metric(label: "阅读", value: compactDuration(records.filter { $0.category == .reading }.reduce(0) { $0 + $1.seconds }))
                            }
                            ActivityDistribution(records: records)
                            Divider().overlay(Theme.line).padding(.top, 3)
                            HStack {
                                Text("最近活动").font(.system(size: 14, weight: .semibold)); Spacer()
                                Button("完整时间线 ›", action: onTimeline).buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.muted)
                            }
                            VStack(spacing: 0) {
                                if records.isEmpty { Text("切换到工作窗口后开始识别；证据不足不推测具体活动。").font(.system(size: 12)).foregroundStyle(Theme.muted).padding(.vertical, 18) }
                                ForEach(Array(ActivityPresentation.coalesced(records).prefix(4))) { segment in
                                    ActivityRow(segment: segment, fullTime: false) { selected = segment }
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Rectangle().fill(Theme.line).frame(width: 1)
                        SummaryPane(onSettings: onSettings).frame(width: 218)
                    }.fixedSize(horizontal: false, vertical: true)
                    Label("时长为估算，不代表专注程度或工作绩效。AI 小结仅供回顾。", systemImage: "info.circle").font(.system(size: 10)).foregroundStyle(Theme.muted)
                    }
                }
            }.padding(30)
        }.onAppear { summary.openedToday() }
            .onChange(of: store.now) { old, new in if !Calendar.current.isDate(old, inSameDayAs: new) { summary.openedToday() } }
            .sheet(item: $selected) { ActivityDetail(segment: $0) }
    }
    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "viewfinder").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.accent)
            Text("开启自动活动记录").font(.system(size: 22, weight: .medium))
            Text("配置一次模型与隐私权限，之后自动记录前台窗口。不需要填写目标、打分或确认空闲。").font(.system(size: 12)).foregroundStyle(Theme.muted).lineSpacing(5)
            Button("配置视觉模型", action: onSettings).buttonStyle(QuietButtonStyle())
            HStack {
                Label(activity.verified ? "图片理解已通过" : "需要先测试图片理解", systemImage: activity.verified ? "checkmark.circle" : "photo")
                Spacer()
                Button(activity.hasPermission ? "屏幕权限已允许" : "允许屏幕录制") { activity.requestPermission() }.disabled(activity.hasPermission)
            }.font(.system(size: 11)).foregroundStyle(Theme.muted)
            Text("截图接收方：\(activity.config.ai.baseURL)\n模型：\(activity.config.ai.model.isEmpty ? "尚未配置" : activity.config.ai.model)").font(.system(size: 11)).foregroundStyle(Theme.muted).textSelection(.enabled)
            Toggle("同意将前台窗口截图发送至上述模型服务进行识别", isOn: $consent).font(.system(size: 12))
            Button("同意并开启记录") { activity.enable(consent: consent); consent = false }.buttonStyle(AccentButtonStyle()).disabled(!consent || !activity.verified || !activity.hasPermission || activity.testing)
            Text("截图仅在内存处理，不写入应用历史；服务端留存由所选服务决定。排除的应用不截图，敏感网页请先暂停。").font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(4)
        }.frame(maxWidth: 540, alignment: .leading).padding(.vertical, 22)
            .onChange(of: activity.config.ai) { _, _ in consent = false }
            .onChange(of: activity.config.credentialRevision) { _, _ in consent = false }
    }
}

struct CurrentActivityBand: View {
    @EnvironmentObject private var activity: AutomaticTracker
    @EnvironmentObject private var store: FocusStore
    var body: some View {
        Group {
            if store.hasVisibleWindow { TimelineView(.periodic(from: Date(), by: 5)) { _ in face(at: activity.observationDate) } }
            else { face(at: store.now) }
        }.padding(24).background(Theme.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.07), lineWidth: 1))
    }
    private func face(at date: Date) -> some View {
        let item = activity.liveSegment(at: date)
        let hasCurrent = activity.current != nil || activity.status == .paused
        return HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Label(activity.status.label + (hasCurrent ? " · \(item?.categoryLabel ?? "未识别")" : ""), systemImage: "circle.fill")
                    .font(.system(size: 10)).foregroundStyle(Theme.accent)
                Text(hasCurrent ? item?.title ?? "等待识别当前活动" : activity.status.label).font(.system(size: 22, weight: .medium)).lineLimit(2)
                Text(hasCurrent ? "\(item?.app ?? "") · \(activity.recognitionDetail(at: date))" : activity.status.detail)
                    .font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(2)
                if !activity.hasPermission { Button("重新允许屏幕录制") { activity.requestPermission() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 8) {
                Text(hasCurrent && item != nil ? "\(Int((item?.seconds ?? 0) / 60))" : "—").font(.system(size: 44, weight: .light, design: .rounded)).monospacedDigit()
                Text("分钟 · 约").font(.system(size: 10)).foregroundStyle(Theme.muted)
            }.frame(minWidth: 74)
            Button { if activity.status == .paused { activity.resume() } else { activity.pause() } } label: {
                Image(systemName: activity.status == .paused ? "play.fill" : "pause.fill").font(.system(size: 12)).frame(width: 34, height: 34)
                    .background(Theme.background.opacity(0.7), in: Circle()).overlay(Circle().stroke(Theme.accent.opacity(0.15), lineWidth: 1))
            }.buttonStyle(.plain).foregroundStyle(Theme.accent).help(activity.status == .paused ? "恢复记录" : "暂停记录")
        }
    }
}

struct SummaryPane: View {
    @EnvironmentObject private var summary: AutomaticSummaryController
    let onSettings: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Label("今日小结", systemImage: "sparkles").font(.system(size: 14, weight: .semibold)); Spacer(); Text(summary.isGenerating ? "整理中" : "自动").font(.system(size: 9)).foregroundStyle(Theme.muted) }
            if let report = summary.todayReport {
                Text(report.content).font(.system(size: 12)).lineSpacing(6).textSelection(.enabled)
                Text("基于文字记录 · \(report.updatedAt.formatted(.dateTime.hour().minute())) 更新\(summary.isStale ? " · 内容待更新" : "")").font(.system(size: 10)).foregroundStyle(Theme.muted)
            } else if summary.isGenerating { SummaryStreamingText(stream: summary.stream) }
            else {
                Text(summary.enabled ? "有足够记录后自动整理。未记录的时间不推测用途，也不要求补填。" : "开启后自动整理一天的活动，只使用文字记录，不重发历史截图。").font(.system(size: 12)).foregroundStyle(Theme.muted).lineSpacing(6)
            }
            if !summary.enabled {
                Button(summary.hasConsent ? "服务已变更，重新授权" : "设置自动小结", action: onSettings).buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent)
            }
            if let error = summary.errorMessage { Text(error).font(.system(size: 10)).foregroundStyle(Theme.muted) }
            if let attempt = summary.latestAttempt, attempt.state == .failed || attempt.state == .cancelled {
                Text("本次更新未完成：\(attempt.error ?? "请求中断")\n已有小结保留，本时段不重复请求。").font(.system(size: 10)).foregroundStyle(Theme.muted).lineSpacing(4)
            }
            Divider().overlay(Theme.line)
            Text("不计算效率分，不推测任务完成情况。AI 可能误判，请结合实际情况阅读。").font(.system(size: 10)).foregroundStyle(Theme.muted).lineSpacing(5)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
private struct SummaryStreamingText: View {
    @ObservedObject var stream: ReviewStreamingState
    var body: some View { Text(stream.text.isEmpty ? "正在整理今天的活动…" : stream.text).font(.system(size: 12)).lineSpacing(6).textSelection(.enabled) }
}

struct ActivityDistribution: View {
    let records: [ActivitySegment]
    private var total: TimeInterval { max(1, records.reduce(0) { $0 + $1.seconds }) }
    private var items: [ActivityPresentation.DistributionItem] { ActivityPresentation.distribution(records) }
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            GeometryReader { proxy in
                HStack(spacing: 2) { ForEach(items) { item in
                    Rectangle().fill(item.color).frame(width: max(0, (proxy.size.width - CGFloat(max(0, items.count - 1)) * 2) * item.seconds / total))
                } }.clipShape(RoundedRectangle(cornerRadius: 3))
            }.frame(height: 8)
            legend
            if items.contains(where: { $0.category == .unknown }) {
                Text("等待识别、识别异常与证据不足分别统计；历史未识别不推测原因，所有时长仍计入总量。")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted).lineSpacing(3)
            }
        }
    }
    private var legend: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), alignment: .leading)], alignment: .leading, spacing: 8) { ForEach(items) { item in
            HStack(spacing: 4) { Circle().fill(item.color).frame(width: 5, height: 5); Text("\(item.label) \(Int((item.seconds / total * 100).rounded()))%") }
                .font(.system(size: 9)).foregroundStyle(Theme.muted)
        } }
    }
}

struct ActivityRow: View {
    let segment: ActivitySegment
    var fullTime = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Text(segment.start.formatted(.dateTime.hour().minute()) + (fullTime ? " — " + segment.end.formatted(.dateTime.hour().minute()) : ""))
                    .font(.system(size: 10)).monospacedDigit().foregroundStyle(Theme.muted).frame(width: fullTime ? 94 : 38, alignment: .leading).padding(.top, 2)
                Circle().fill(segment.category.color).frame(width: 6, height: 6).padding(.top, 5)
                VStack(alignment: .leading, spacing: 7) {
                    Text(segment.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                    Text("\(segment.app) · \(segment.categoryLabel)").font(.system(size: 10)).foregroundStyle(Theme.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text("约 " + compactDuration(segment.seconds)).font(.system(size: 10)).foregroundStyle(Theme.muted).padding(.top, 2)
            }.padding(.vertical, 15).contentShape(Rectangle())
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.line.opacity(0.6)).frame(height: 1) }
        }.buttonStyle(.plain)
    }
}

struct ActivityDetail: View {
    let segment: ActivitySegment
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { Text(segment.title).font(.system(size: 22, weight: .medium)); Spacer(); Button("关闭") { dismiss() }.buttonStyle(QuietButtonStyle()) }
            LabeledContent("时间范围", value: segment.start.formatted(.dateTime.month().day().hour().minute()) + " — " + segment.end.formatted(.dateTime.hour().minute()))
            LabeledContent("活动类别", value: segment.categoryLabel)
            LabeledContent("估算时长", value: "约 " + durationText(segment.seconds))
            LabeledContent("前台应用", value: segment.app)
            Divider().overlay(Theme.line)
            Text(segment.corrected ? "这段历史记录曾经过人工确认，原样保留；时间仍为估算。" : "根据前台窗口的间隔识别整理。没有保存可回看的历史截图，也不提供事后补时或反馈表单。")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).lineSpacing(6)
            Text("证据不足的内容保留为未识别，不推测空白时段的用途。").font(.system(size: 11)).foregroundStyle(Theme.muted)
        }.padding(30).frame(width: 520).background(Theme.background)
    }
}

struct ActivityTimeline: View {
    @EnvironmentObject private var activity: AutomaticTracker
    @State private var day = Date()
    @State private var category: ActivityCategory?
    @State private var selected: ActivitySegment?
    private var interval: DateInterval { Calendar.current.dateInterval(of: .day, for: day)! }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) { PageTitle(title: "时间线", subtitle: "相邻的同类活动合并显示，不用逐条整理。"); Spacer(); Button("导出当天") { export() }.buttonStyle(QuietButtonStyle()) }
                HStack {
                    Button { moveDay(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain).help("前一天")
                    DatePicker("日期", selection: $day, in: ...Date(), displayedComponents: .date).labelsHidden().frame(width: 140)
                    Button { moveDay(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain).disabled(Calendar.current.isDateInToday(day)).help("后一天")
                    Spacer()
                }.font(.system(size: 11)).foregroundStyle(Theme.muted)
                Picker("类别", selection: $category) {
                    Text("全部").tag(nil as ActivityCategory?)
                    ForEach(ActivityCategory.allCases) { Text($0.displayName).tag(Optional($0)) }
                }.pickerStyle(.segmented)
                let read = try? activity.readSegments(in: interval)
                let records = ActivityPresentation.coalesced(read ?? []).filter { category == nil || $0.category == category }
                if read != nil { Text("共约 " + durationText(records.reduce(0) { $0 + $1.seconds })).font(.system(size: 22, weight: .regular, design: .rounded)) }
                if read == nil { EmptyState(symbol: "exclamationmark.triangle", title: "活动文件无法读取", detail: "未展示不完整统计。请在设置打开数据目录，先备份再检查对应日期的文件。") }
                else if records.isEmpty { EmptyState(symbol: "list.bullet", title: "这一天没有相应活动", detail: "未记录的时间保持空白，不要求补填。") }
                else { LazyVStack(spacing: 0) {
                    ForEach(Array(records.enumerated()), id: \.element.id) { index, segment in
                        ActivityRow(segment: segment) { selected = segment }
                        if category == nil, index + 1 < records.count, segment.start.timeIntervalSince(records[index + 1].end) >= 60 {
                            HStack { Text(records[index + 1].end.formatted(.dateTime.hour().minute()) + " — " + segment.start.formatted(.dateTime.hour().minute())).frame(width: 94, alignment: .leading); Text("┊"); Text("未记录 · 未计入时长"); Spacer() }
                                .font(.system(size: 10)).foregroundStyle(Theme.muted.opacity(0.75)).padding(.vertical, 14)
                        }
                    }
                } }
                Text("时长为估算。点击片段查看详情；没有历史截图，不提供手动补时或分类。").font(.system(size: 10)).foregroundStyle(Theme.muted)
            }.padding(30)
        }.sheet(item: $selected) { ActivityDetail(segment: $0) }
    }
    private func moveDay(_ offset: Int) { day = Calendar.current.date(byAdding: .day, value: offset, to: day)! }
    private func export() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "活动-\(ActivityPresentation.dayKey(day)).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted]; encoder.dateEncodingStrategy = .iso8601; try encoder.encode(activity.readSegments(in: interval)).write(to: url, options: .atomic) }
        catch { activity.errorMessage = "导出失败：\(error.localizedDescription)" }
    }
}

struct ActivityStatistics: View {
    @EnvironmentObject private var activity: AutomaticTracker
    @EnvironmentObject private var store: FocusStore
    @State private var weekOffset = 0
    var body: some View {
        let date = Calendar.current.date(byAdding: .weekOfYear, value: weekOffset, to: store.now)!
        let interval = Period.week.interval(now: date)
        let read = try? activity.readSegments(in: interval)
        let records = read ?? []
        let chartDays = ActivityPresentation.weeklyTotals(records, now: store.now, weekContaining: date).map { ChartDay(date: $0.date, seconds: $0.seconds) }
        let total = records.reduce(0) { $0 + $1.seconds }
        let recordedDays = chartDays.filter { ($0.seconds ?? 0) > 0 }.count
        return ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .top) { PageTitle(title: "时间洞察", subtitle: "看时间的分布，不给工作打分。"); Spacer(); HStack(spacing: 12) {
                    Button { weekOffset -= 1 } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain)
                    Text(interval.start.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day()) + " — " + interval.end.addingTimeInterval(-1).formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day()))
                    Button { weekOffset += 1 } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain).disabled(weekOffset == 0)
                }.font(.system(size: 11)).foregroundStyle(Theme.muted).padding(.top, 10) }
                if read == nil { EmptyState(symbol: "exclamationmark.triangle", title: "部分活动文件无法读取", detail: "暂不展示不完整统计。请先备份数据目录。") }
                else {
                HStack(spacing: 30) {
                    Metric(label: "这一周已记录 · 约", value: compactDuration(total))
                    Metric(label: "有记录的日期", value: "\(recordedDays) 天")
                    Metric(label: "主要活动", value: ActivityCategory.allCases.filter { $0 != .unknown }.max(by: { a, b in records.filter { $0.category == a }.reduce(0) { $0 + $1.seconds } < records.filter { $0.category == b }.reduce(0) { $0 + $1.seconds } }).flatMap { c in records.contains { $0.category == c } ? c.displayName : nil } ?? "—")
                }
                Chart(chartDays) { day in
                    if let seconds = day.seconds, seconds > 0 {
                        BarMark(x: .value("日期", day.date, unit: .day), y: .value("分钟", seconds / 60), width: .ratio(0.4))
                            .foregroundStyle(Calendar.current.isDateInToday(day.date) ? Theme.accent : Theme.accent.opacity(0.4)).cornerRadius(3)
                            .annotation(position: .top) { Text("\(Int(seconds / 60)) 分").font(.system(size: 9)).foregroundStyle(Theme.muted) }
                    }
                }.chartXScale(domain: interval.start...interval.end.addingTimeInterval(-1))
                    .chartYScale(domain: 0...max(60, (chartDays.compactMap(\.seconds).max() ?? 0) / 60 * 1.25))
                    .chartXAxis { AxisMarks(values: .stride(by: .day)) { AxisValueLabel(format: .dateTime.locale(Locale(identifier: "zh_CN")).weekday(.abbreviated)) } }
                    .chartYAxis { AxisMarks(position: .leading) { AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4])); AxisValueLabel() } }.frame(height: 200)
                Divider().overlay(Theme.line)
                Text("活动分布").font(.system(size: 14, weight: .semibold))
                ForEach(ActivityPresentation.distribution(records)) { item in
                    HStack(spacing: 20) {
                        Text(item.label).font(.system(size: 12)).frame(width: 76, alignment: .leading)
                        GeometryReader { proxy in
                            Capsule().fill(Theme.line.opacity(0.45))
                            Capsule().fill(item.color).frame(width: proxy.size.width * item.seconds / max(1, total))
                        }.frame(height: 6)
                        Text("约 " + compactDuration(item.seconds)).font(.system(size: 11)).foregroundStyle(Theme.muted).frame(width: 115, alignment: .trailing)
                    }
                }
                Text(recordedDays < 7 ? "记录日期较少，暂不判断长期趋势。未来日期留空，不当作 0 小时；未识别片段不计入具体类别。" : "时长不代表专注或绩效。识别可能漏记、误判，不推断没有记录的工作成果。")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(5)
                }
            }.padding(30)
        }
    }
    private struct ChartDay: Identifiable { var date: Date; var seconds: TimeInterval?; var id: Date { date } }
}
