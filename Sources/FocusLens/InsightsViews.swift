import SwiftUI
import Charts
import AppKit

struct DayTotal: Identifiable {
    let date: Date
    let seconds: TimeInterval
    var id: Date { date }
}

struct InsightsView: View {
    @EnvironmentObject private var store: FocusStore
    private var interval: DateInterval { Period.week.interval(now: store.now) }
    private var stats: FocusStats { store.stats(.week) }
    private var days: [DayTotal] {
        (0..<7).map { offset in
            let day = Calendar.current.date(byAdding: .day, value: offset, to: interval.start)!
            let next = Calendar.current.date(byAdding: .day, value: 1, to: day)!
            let sessions = sessionsIn(stats.sessions, interval: DateInterval(start: day, end: next))
            return DayTotal(date: day, seconds: FocusStats(sessions: sessions).totalSeconds)
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                PageTitle(title: "本周统计", subtitle: "\(interval.start.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day())) — \(interval.end.addingTimeInterval(-1).formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day())) · 周一至周日")
                HStack(alignment: .top, spacing: 24) {
                    Metric(label: "专注时间", value: String(format: "%.0f 分", stats.totalSeconds / 60), hint: "\(stats.sessions.count) 轮已记录")
                    Metric(label: "完整完成率", value: stats.completionRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "—", hint: "\(stats.completed) / \(stats.sessions.count) 轮完整完成")
                    Metric(label: "中断次数", value: "\(stats.interruptions)", hint: "手动暂停计为一次中断")
                    Metric(label: "专注自评分", value: stats.averageRating.map { String(format: "%.1f / 5", $0) } ?? "—", hint: "\(stats.ratedCount) 轮有评分 · 主观反馈")
                }.padding(.vertical, 6)
                Rectangle().fill(Theme.line).frame(height: 1)
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        Text("每日专注时间").font(.system(size: 15, weight: .semibold))
                        Spacer()
                        Text("分钟").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                    Chart(days) { day in
                        BarMark(x: .value("日期", day.date, unit: .day), y: .value("分钟", day.seconds / 60), width: .ratio(0.42))
                            .foregroundStyle(Calendar.current.isDateInToday(day.date) ? Theme.accent : Theme.accent.opacity(0.35))
                            .cornerRadius(3)
                            .annotation(position: .top) {
                                if day.seconds > 0 { Text(String(format: "%.0f", day.seconds / 60)).font(.system(size: 10)).foregroundStyle(Theme.muted) }
                            }
                    }
                    .chartYScale(domain: 0...max(30, (days.map { $0.seconds / 60 }.max() ?? 0) * 1.2))
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day)) { _ in
                            AxisValueLabel(format: .dateTime.locale(Locale(identifier: "zh_CN")).weekday(.abbreviated))
                        }
                    }
                    .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4])); AxisValueLabel() } }
                    .frame(height: 215)
                    Text("按每轮开始日期归属；跨日专注全部计入开始日。暂停、休息及正在进行的轮次不计入。").font(.system(size: 10)).foregroundStyle(Theme.muted)
                }
                Rectangle().fill(Theme.line).frame(height: 1)
                HStack(alignment: .top, spacing: 45) {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("任务类型").font(.system(size: 15, weight: .semibold))
                        if stats.sessions.isEmpty { Text("完成专注后显示分布").font(.system(size: 12)).foregroundStyle(Theme.muted) }
                        ForEach(TaskKind.allCases.filter { kind in stats.sessions.contains { $0.kind == kind } }) { kind in
                            let matching = stats.sessions.filter { $0.kind == kind }
                            let total = FocusStats(sessions: matching).totalSeconds
                            VStack(spacing: 8) {
                                HStack {
                                    Text(kind.rawValue)
                                    Spacer()
                                    Text("\(durationText(total)) · \(matching.count) 轮").foregroundStyle(Theme.muted)
                                }.font(.system(size: 11))
                                GeometryReader { proxy in
                                    Capsule().fill(Theme.line.opacity(0.6))
                                    Capsule().fill(Theme.accent.opacity(0.65)).frame(width: proxy.size.width * (stats.totalSeconds > 0 ? total / stats.totalSeconds : 0))
                                }.frame(height: 4)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 16) {
                        Text("记录摘要").font(.system(size: 15, weight: .semibold))
                        Text("有记录 \(stats.days) 天，共 \(stats.sessions.count) 轮。").font(.system(size: 12))
                        Text("完整完成 \(stats.completed) 轮，部分完成 \(stats.sessions.filter { $0.outcome == .partial }.count) 轮，未完成 \(stats.sessions.filter { $0.outcome == .unfinished }.count) 轮。")
                            .font(.system(size: 12)).lineSpacing(5)
                        Text(stats.days < 7 || stats.sessions.count < 20 ? "样本较少。先积累记录，再观察时段和周期差异；时长本身不代表效率。" : "可以在 AI 复盘中结合任务反馈，观察工作节奏。时长本身不代表效率。")
                            .font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(5)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(35).padding(.top, 10)
        }
    }
}

struct HistoryView: View {
    @EnvironmentObject private var store: FocusStore
    @State private var query = ""
    @State private var range = "全部"
    @State private var deleteID: UUID?
    private var filtered: [FocusSession] {
        let sessions = range == "全部" ? store.data.sessions : sessionsIn(store.data.sessions, interval: (range == "今天" ? Period.today : .week).interval(now: store.now))
        return sessions.filter { query.isEmpty || goalDisplayText($0.goal).localizedCaseInsensitiveContains(query) || $0.note.localizedCaseInsensitiveContains(query) }
            .sorted { $0.startedAt > $1.startedAt }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                PageTitle(title: "专注记录", subtitle: "每轮的目标、投入与反馈")
                Spacer()
                Button("导出全部 JSON") { store.exportSessions() }.buttonStyle(QuietButtonStyle()).disabled(store.data.sessions.isEmpty)
            }
            HStack(spacing: 18) {
                Picker("时间范围", selection: $range) { ForEach(["全部", "今天", "本周"], id: \.self) { Text($0).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 215)
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                    TextField("搜索目标或反馈", text: $query).textFieldStyle(.plain)
                }.padding(9).frame(width: 230).background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 7))
            }
            if filtered.isEmpty {
                EmptyState(symbol: "clock.arrow.circlepath", title: query.isEmpty ? "还没有专注记录" : "没有匹配的记录", detail: query.isEmpty ? "从一轮专注开始，结束后记录完成情况。" : "试试其他关键词或时间范围。")
            } else {
                HStack {
                    Text("\(filtered.count) 轮 · \(durationText(FocusStats(sessions: filtered).totalSeconds))")
                    Spacer()
                    Text("点击记录查看反馈")
                }.font(.system(size: 11)).foregroundStyle(Theme.muted)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { session in
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("计划 \(durationText(session.plannedSeconds)) · 中断 \(session.interruptions) 次 · 自评分 \(session.rating.map { "\($0) / 5" } ?? "未填写")")
                                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                                    Text(session.note.isEmpty ? "未填写备注" : session.note).font(.system(size: 12)).textSelection(.enabled).lineSpacing(5)
                                    HStack {
                                        Text("结束于 \(session.endedAt.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day().hour().minute()))").font(.system(size: 10)).foregroundStyle(Theme.muted)
                                        Spacer()
                                        Button("删除这条记录", role: .destructive) { deleteID = session.id }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(Theme.accent)
                                    }
                                }.padding(.vertical, 14).padding(.leading, 5)
                            } label: {
                                HStack(spacing: 15) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(goalDisplayText(session.goal)).font(.system(size: 14, weight: .medium)).lineLimit(2)
                                        Text("\(session.startedAt.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day().hour().minute())) · \(session.kind.rawValue)")
                                            .font(.system(size: 10)).foregroundStyle(Theme.muted)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    Text(durationText(session.focusSeconds)).font(.system(size: 12, design: .rounded)).frame(width: 100, alignment: .trailing)
                                    Text(session.outcome.rawValue).font(.system(size: 11)).foregroundStyle(session.outcome == .completed ? Theme.accent : Theme.muted).frame(width: 70, alignment: .trailing)
                                }.padding(.vertical, 15)
                            }.tint(Theme.muted)
                            Rectangle().fill(Theme.line).frame(height: 1)
                        }
                    }
                }
            }
        }.padding(35).padding(.top, 10)
        .confirmationDialog("删除这条专注记录？", isPresented: Binding(get: { deleteID != nil }, set: { if !$0 { deleteID = nil } }), titleVisibility: .visible) {
            Button("删除记录", role: .destructive) { if let deleteID { store.deleteSession(deleteID) }; deleteID = nil }
            Button("取消", role: .cancel) { deleteID = nil }
        } message: { Text("删除后无法撤销。已生成的 AI 复盘会保留原来的分析快照。") }
    }
}

struct ReviewView: View {
    @EnvironmentObject private var store: FocusStore
    let onSettings: () -> Void
    @State private var period: Period = .today
    @State private var copied = false
    @State private var archivedReport: Review?
    private var interval: DateInterval { period.interval(now: store.now) }
    private var sessions: [FocusSession] { sessionsIn(store.data.sessions, interval: interval) }
    private var report: Review? { store.data.reviews.first { $0.start == interval.start && $0.end == interval.end } }
    private var stale: Bool { guard let report else { return false }; return Set(report.sessionIDs) != Set(sessions.map(\.id)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .top) {
                PageTitle(title: "AI 复盘", subtitle: "结合专注记录，了解投入与完成情况")
                Spacer()
                if !store.data.reviews.isEmpty {
                    Menu("历史复盘") {
                        ForEach(store.data.reviews) { review in
                            Button("\(review.start.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day())) · \(review.end.timeIntervalSince(review.start) > 90000 ? "周" : "日")复盘 · \(review.createdAt.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day().hour().minute()))") {
                                archivedReport = review
                            }
                        }
                    }.frame(width: 100)
                }
                Button("接口设置", action: onSettings).buttonStyle(QuietButtonStyle())
            }
            HStack {
                Picker("复盘范围", selection: $period) { ForEach(Period.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 180).disabled(store.isGenerating)
                Spacer()
                if store.isGenerating {
                    ProgressView().controlSize(.small)
                    Button("取消") { store.cancelReview() }.buttonStyle(QuietButtonStyle())
                } else {
                    Button(report == nil ? "生成复盘" : "重新生成") { store.generateReview(period: period) }
                        .buttonStyle(AccentButtonStyle()).disabled(sessions.isEmpty)
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                Text("分析范围：\(period.rawValue) · \(sessions.count) 轮 · \(durationText(FocusStats(sessions: sessions).totalSeconds))").font(.system(size: 12, weight: .medium))
                Text("点击生成时，将所选范围的目标、时长、完成情况、评分和反馈发送给你配置的 AI 服务。其余记录保留在本地。")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            if store.isGenerating {
                EmptyState(symbol: "sparkles", title: "正在整理这次复盘", detail: "通常需要数十秒。你可以切换页面，或随时取消。")
            } else if let report {
                HStack {
                    Text("\(report.createdAt.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day().hour().minute())) 生成 · \(report.model)")
                        .font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1)
                    Spacer()
                    Button(copied ? "已复制" : "复制复盘") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report.content, forType: .string)
                        copied = true
                    }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent)
                }
                if stale { Label("记录已有变化，可重新生成以更新分析。", systemImage: "arrow.clockwise").font(.system(size: 11)).foregroundStyle(Theme.accent) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(report.content.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                            if !line.isEmpty {
                                let heading = line.hasPrefix("#")
                                let cleaned = heading ? line.drop(while: { $0 == "#" || $0 == " " }).description : line
                                Text(.init(cleaned)).font(.system(size: heading ? 17 : 13, weight: heading ? .semibold : .regular))
                                    .lineSpacing(6).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, heading ? 10 : 0)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("AI 输出可能有误，请结合实际任务核对。专注自评分和目标完成情况来自你的反馈。")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted)
            } else {
                EmptyState(symbol: "sparkles", title: sessions.isEmpty ? "先积累一轮专注" : "记录已经准备好", detail: sessions.isEmpty ? "完成专注并保存反馈后，就可以生成复盘。\n数据较少时，AI 会只做初步观察。" : "配置 AI 接口后，点击生成复盘。\n分析以记录为依据，不会把时长直接当作效率。")
            }
        }.padding(35).padding(.top, 10)
        .onChange(of: period) { _, _ in copied = false }
        .onChange(of: report?.id) { _, _ in copied = false }
        .sheet(item: $archivedReport) { review in
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("历史复盘").font(.system(size: 23, weight: .semibold))
                    Spacer()
                    Button("关闭") { archivedReport = nil }.buttonStyle(QuietButtonStyle())
                }
                Text("\(review.start.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).year().month().day())) 起 · \(review.sessionIDs.count) 轮 · \(review.model)")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
                ScrollView {
                    Text(review.content).font(.system(size: 13)).lineSpacing(6).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("历史快照保留生成时的内容，不随记录修改。最多保留最近 50 份。").font(.system(size: 10)).foregroundStyle(Theme.muted)
            }.padding(30).frame(width: 650, height: 580).background(Theme.background)
        }
    }
}
