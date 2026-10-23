import SwiftUI
import AppKit

struct ReviewView: View {
    @EnvironmentObject private var store: FocusStore
    @EnvironmentObject private var activity: AutomaticTracker
    @ObservedObject var stream: ReviewStreamingState
    let onSettings: () -> Void
    @State private var period: Period = .today
    @State private var selectedReviewID: UUID?
    @State private var question = ""
    @State private var copied = false
    @State private var followsOutput = true
    @State private var automaticSource = false
    private var activities: [ActivitySegment] { activity.segments(in: interval) }
    private var noRecords: Bool { automaticSource ? activities.isEmpty : sessions.isEmpty }
    private var interval: DateInterval { period.interval(now: store.now) }
    private var sessions: [FocusSession] { sessionsIn(store.data.sessions, interval: interval) }
    private var report: Review? {
        if let selectedReviewID { return store.data.reviews.first { $0.id == selectedReviewID } }
        return store.data.reviews.first { $0.start == interval.start && $0.end == interval.end && ($0.activityEvidence != nil) == automaticSource }
    }
    private var active: Bool { store.isGenerating && store.generatingReviewID == report?.id }
    private var stale: Bool {
        guard let report else { return false }
        if let evidence = report.activityEvidence { return activity.segments(in: DateInterval(start: report.start, end: report.end)) != evidence }
        let current = sessionsIn(store.data.sessions, interval: DateInterval(start: report.start, end: report.end))
        return report.isStale == true || Set(report.sessionIDs) != Set(current.map(\.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                PageTitle(title: "AI 复盘", subtitle: "边生成边阅读，围绕专注记录继续讨论")
                Spacer()
                if !store.data.reviews.isEmpty {
                    Menu("历史复盘") {
                        ForEach(store.data.reviews) { review in
                            Button("\(review.activityEvidence == nil ? "手动" : "自动") · \(review.start.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day())) · \(review.createdAt.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).hour().minute()))") {
                                selectedReviewID = review.id
                                automaticSource = review.activityEvidence != nil
                                question = ""
                            }
                        }
                    }.frame(width: 100).disabled(store.isGenerating)
                }
                Button("接口设置", action: onSettings).buttonStyle(QuietButtonStyle())
            }
            HStack {
                Picker("记录来源", selection: Binding(get: { automaticSource }, set: { automaticSource = $0; selectedReviewID = nil; question = ""; copied = false })) { Text("自动活动").tag(true); Text("手动专注").tag(false) }
                    .pickerStyle(.segmented).frame(width: 180).disabled(store.isGenerating)
                Picker("复盘范围", selection: $period) { ForEach(Period.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 130).disabled(store.isGenerating)
                Spacer()
                if store.isGenerating {
                    ProgressView().controlSize(.small)
                    Button("停止生成") { store.cancelReview() }.buttonStyle(QuietButtonStyle())
                } else {
                    Button(report == nil ? "生成复盘" : (report?.start == interval.start && report?.end == interval.end ? "重新生成" : "生成\(period.rawValue)复盘")) {
                        let id = automaticSource ? store.generateActivityReview(period: period) : store.generateReview(period: period)
                        if let id { selectedReviewID = id; question = ""; followsOutput = true }
                    }.buttonStyle(AccentButtonStyle()).disabled(noRecords)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                if let report {
                    Text("\(report.activityEvidence != nil ? "自动活动快照" : report.evidence == nil ? "历史复盘" : "记录快照")：\(report.start.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day())) 起 · \(report.sessionIDs.count) \(report.activityEvidence == nil ? "轮" : "段") · \(report.model)")
                        .font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Text(report.activityEvidence != nil ? "追问发送这份文字活动快照和已完成对话，不含截图。" : report.evidence == nil ? "追问会发送这份复盘文字和已完成对话给当前配置的 AI 服务。" : "追问会发送这份复盘、原始记录快照和已完成对话给当前配置的 AI 服务。")
                        .font(.system(size: 10)).foregroundStyle(Theme.muted)
                } else {
                    Text(automaticSource ? "分析范围：\(period.rawValue) · \(activities.count) 段自动估算活动" : "分析范围：\(period.rawValue) · \(sessions.count) 轮 · \(durationText(FocusStats(sessions: sessions).totalSeconds))")
                        .font(.system(size: 11, weight: .medium))
                    Text(automaticSource ? "仅发送时间、分类与活动概括，不发送或重新读取历史截图。\n复盘服务：\(store.activityReviewSettings.baseURL) · \(store.activityReviewSettings.model)" : "点击生成时，将范围内的目标、时长、完成情况、评分和反馈发送给你配置的 AI 服务。")
                        .font(.system(size: 10)).foregroundStyle(Theme.muted)
                }
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            if let report {
                conversation(report)
                if report.canContinue { composer(report) }
            } else {
                EmptyState(symbol: "sparkles", title: noRecords ? "先积累一些记录" : "记录已经准备好",
                    detail: noRecords ? "选择有记录的范围后，就可以生成复盘。" : "生成结果会逐步显示，你也可以继续提问。")
            }
        }
        .padding(24).padding(.top, 4)
        .onChange(of: period) { _, _ in selectedReviewID = nil; question = ""; copied = false }
        .onChange(of: report?.id) { _, _ in copied = false; followsOutput = true }
        .onAppear {
            if let id = store.generatingReviewID, let review = store.data.reviews.first(where: { $0.id == id }) {
                period = review.end.timeIntervalSince(review.start) > 90000 ? .week : .today
                selectedReviewID = id
                automaticSource = review.activityEvidence != nil
            }
        }
    }

    private func conversation(_ review: Review) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("复盘与对话").font(.system(size: 12, weight: .semibold))
                Spacer()
                if active {
                    Button { followsOutput.toggle() } label: {
                        Label(followsOutput ? "跟随输出" : "自由阅读", systemImage: followsOutput ? "arrow.down.to.line" : "text.alignleft")
                    }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Theme.muted)
                }
                Button(copied ? "已复制" : "复制对话") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(review.transcript, forType: .string)
                    copied = true
                }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent).disabled(active)
            }
            if stale {
                Text("记录已有变化；本次对话沿用原快照，重新生成可更新分析。")
                    .font(.system(size: 10)).foregroundStyle(Theme.accent)
            }
            if review.evidence == nil && review.activityEvidence == nil {
                Text("这份旧复盘仅保留分析文字；重新生成可带入原始记录快照。")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ReviewResponseView(text: active && store.generatingMessageID == nil ? stream.text : review.content,
                            state: review.state ?? .complete, error: review.error, title: "AI · 复盘")
                        ForEach(review.messages ?? []) { message in
                            if message.role == .user {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text("我").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.muted)
                                    Text(message.content).font(.system(size: 13)).lineSpacing(5).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }.padding(12).background(Theme.sidebar, in: RoundedRectangle(cornerRadius: 8))
                            } else {
                                ReviewResponseView(text: active && store.generatingMessageID == message.id ? stream.text : message.content,
                                    state: message.state, error: message.error, title: "AI\(message.model.map { " · " + $0 } ?? "")")
                            }
                        }
                        Color.clear.frame(height: 1).id("reviewBottom")
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 8)
                }
                .onChange(of: stream.text) { _, _ in
                    if active && followsOutput { proxy.scrollTo("reviewBottom", anchor: .bottom) }
                }
                .onChange(of: review.messages?.count) { _, _ in proxy.scrollTo("reviewBottom", anchor: .bottom) }
            }
            Text("AI 输出可能有误，请结合实际任务核对。对话保存在本机，只在你生成或发送问题时请求服务。")
                .font(.system(size: 10)).foregroundStyle(Theme.muted)
        }.frame(maxHeight: .infinity)
    }

    private func composer(_ review: Review) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(alignment: .bottom, spacing: 10) {
                TextField("继续提问，例如：下一轮该怎么安排？", text: $question, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...3)
                    .padding(11).background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
                    .onChange(of: question) { _, value in if value.count > 2000 { question = String(value.prefix(2000)) } }
                    .accessibilityLabel("复盘追问")
                Button {
                    if store.sendReviewQuestion(reviewID: review.id, question: question) { question = ""; followsOutput = true }
                } label: { Image(systemName: "arrow.up").frame(width: 20, height: 20) }
                    .buttonStyle(AccentButtonStyle()).keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel("发送追问")
                    .disabled(store.isGenerating || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("⌘ Return 发送 · 最多 20 轮追问，每条最多 2000 字")
                .font(.system(size: 10)).foregroundStyle(Theme.muted)
        }
    }
}

private struct ReviewResponseView: View {
    let text: String
    let state: ReviewState
    let error: String?
    let title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                Text(title).foregroundStyle(Theme.muted)
                if state == .generating { Text("正在生成…").foregroundStyle(Theme.accent) }
            }.font(.system(size: 10, weight: .medium))
            if text.isEmpty && state == .generating {
                Text("正在连接，收到文字后会逐步显示…").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                if !line.isEmpty {
                    let heading = line.hasPrefix("#")
                    let cleaned = heading ? line.drop(while: { $0 == "#" || $0 == " " }).description : line
                    Text(.init(cleaned)).font(.system(size: heading ? 16 : 13, weight: heading ? .semibold : .regular))
                        .lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, heading ? 5 : 0)
                }
            }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(Theme.accent)
            } else if state == .cancelled {
                Text("已停止，以上内容尚未完成。").font(.system(size: 11)).foregroundStyle(Theme.accent)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
