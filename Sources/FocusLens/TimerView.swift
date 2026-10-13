import SwiftUI

struct TimerWorkspace: View {
    @EnvironmentObject private var store: FocusStore
    @State private var goal = ""
    @State private var tagManagerOpen = false
    @State private var minutes = 25
    @State private var confirmEnd = false
    private var run: TimerRun? { store.data.activeRun }
    private var isRest: Bool { run?.phase == .rest }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                PageTitle(title: store.focusMode ? "" : "专注计时", subtitle: store.focusMode ? "" : store.now.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).year().month().day().weekday()))
                Spacer()
                if run != nil {
                    Button { store.showFloatingTimer() } label: {
                        Label("小浮窗", systemImage: "pip")
                    }.buttonStyle(QuietButtonStyle())
                    Button { store.setFocusMode(!store.focusMode) } label: {
                        Label(store.focusMode ? "退出专注模式" : "专注模式", systemImage: store.focusMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }.buttonStyle(QuietButtonStyle())
                }
            }
            .padding(.bottom, store.focusMode ? 0 : 16)
            if store.focusMode {
                focusedTimer.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 22) {
                    VStack(spacing: 0) {
                        HStack(spacing: 7) {
                            Circle().fill(run == nil ? Theme.line : Theme.accent).frame(width: 6, height: 6)
                            Text(run == nil ? "准备开始" : (run!.isPaused ? "已暂停 · 暂停时间不计入专注" : (isRest ? "休息中" : "正在专注")))
                                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }.padding(.top, 8).padding(.bottom, 16)
                        timerFace(size: 230, textSize: 58)
                        if run == nil { setup.padding(.top, 18) }
                        else {
                            VStack(spacing: 8) {
                                Text(isRest ? "让注意力休息一下" : goalDisplayText(run!.goal)).font(.system(size: 17, weight: .medium)).lineLimit(3).multilineTextAlignment(.center)
                                Text(isRest ? "结束后手动开始下一轮" : "\(run!.kind.displayName) · 计划 \(Int(run!.plannedSeconds / 60)) 分钟 · 中断 \(run!.interruptions) 次")
                                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
                            }.frame(minHeight: 64).padding(.top, 12)
                        }
                        controls.padding(.top, 16)
                        if run == nil {
                            Button { store.start(goal: "休息", kind: .other, minutes: store.data.restMinutes, phase: .rest) } label: {
                                Text("先休息 \(store.data.restMinutes) 分钟").font(.system(size: 11)).foregroundStyle(Theme.muted)
                            }.buttonStyle(.plain).padding(.top, 12)
                        }
                        Spacer(minLength: 16)
                    }.frame(maxWidth: .infinity)
                    Rectangle().fill(Theme.line).frame(width: 1)
                    context.frame(width: 168)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 24).padding(.top, 28).padding(.bottom, 20)
        .onAppear { if run == nil { minutes = store.data.focusMinutes } }
        .sheet(isPresented: $tagManagerOpen) { TagManagerView().environmentObject(store) }
        .confirmationDialog("提前结束这一轮？", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("结束并填写反馈") { store.finish() }
            Button("继续专注", role: .cancel) { }
        } message: { Text("已专注的时间会保留，结束后记录目标完成情况。") }
    }

    private func timerFace(size: CGFloat, textSize: CGFloat) -> some View {
        CountdownFace(run: run, previewSeconds: TimeInterval(minutes * 60), size: size, textSize: textSize)
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("这一轮，准备完成什么？（选填）", text: $goal, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 14)).lineLimit(1...2)
                .padding(11).background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
                .onChange(of: goal) { _, value in if value.count > 500 { goal = String(value.prefix(500)) } }
                .accessibilityLabel("本轮目标（选填）")
            HStack {
                Picker("标签", selection: Binding(get: { store.data.selectedKind }, set: { store.selectKind($0) })) {
                    Text("无标签").tag(TaskKind.uncategorized)
                    ForEach(store.data.taskKinds) { Text($0.displayName).tag($0) }
                }.labelsHidden().frame(width: 105)
                Button("管理标签") { tagManagerOpen = true }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.muted)
                Spacer()
                Picker("专注时长", selection: $minutes) {
                    ForEach(Array(Set([1, 15, 25, 45, 60, 90, store.data.focusMinutes])).sorted(), id: \.self) {
                        Text("\($0) 分钟").tag($0)
                    }
                }.labelsHidden().frame(width: 105)
            }.font(.system(size: 12))
        }.frame(maxWidth: 340)
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 12) {
            if let run {
                Button { store.togglePause() } label: {
                    Label(run.isPaused ? "继续" : "暂停", systemImage: run.isPaused ? "play.fill" : "pause.fill")
                        .frame(minWidth: 85)
                }.buttonStyle(AccentButtonStyle())
                Button(isRest ? "结束休息" : "结束") {
                    if isRest { store.finish() } else { confirmEnd = true }
                }.buttonStyle(QuietButtonStyle())
            } else {
                Button { store.start(goal: goal, kind: store.data.selectedKind, minutes: minutes) } label: {
                    Label("开始专注", systemImage: "play.fill").frame(minWidth: 135)
                }.buttonStyle(AccentButtonStyle())
            }
        }
    }

    private var focusedTimer: some View {
        VStack(spacing: 30) {
            Spacer()
            timerFace(size: 410, textSize: 104)
            Text(run.map { goalDisplayText($0.goal) } ?? "").font(.system(size: 23, weight: .medium)).lineLimit(2)
            controls
            Spacer()
            Text("⌘ 空格 暂停 / 继续     ·     Esc 退出专注模式").font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
    }

    private var context: some View {
        let stats = store.stats(.today)
        return VStack(alignment: .leading, spacing: 0) {
            Text("今天的记录").font(.system(size: 13, weight: .semibold)).padding(.top, 10)
            Text(durationText(stats.totalSeconds)).font(.system(size: 26, weight: .medium, design: .rounded)).padding(.top, 14)
            Text("已专注 · 不含正在进行的一轮").font(.system(size: 10)).foregroundStyle(Theme.muted).padding(.top, 7)
            HStack {
                VStack(alignment: .leading, spacing: 7) {
                    Text("\(stats.sessions.count)").font(.system(size: 24, weight: .light, design: .rounded))
                    Text("专注轮数").font(.system(size: 10)).foregroundStyle(Theme.muted)
                }
                Spacer()
                VStack(alignment: .leading, spacing: 7) {
                    Text("\(stats.completed)").font(.system(size: 24, weight: .light, design: .rounded))
                    Text("目标完成").font(.system(size: 10)).foregroundStyle(Theme.muted)
                }
                Spacer()
            }.padding(.vertical, 18)
            Rectangle().fill(Theme.line).frame(height: 1)
            Text("最近专注").font(.system(size: 12, weight: .semibold)).padding(.top, 18).padding(.bottom, 14)
            if stats.sessions.isEmpty {
                Text("完成第一轮后，\n这里会留下你的记录。").font(.system(size: 12)).foregroundStyle(Theme.muted).lineSpacing(6)
            } else {
                ForEach(Array(stats.sessions.sorted { $0.startedAt > $1.startedAt }.prefix(3))) { session in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(goalDisplayText(session.goal)).font(.system(size: 12, weight: .medium)).lineLimit(2)
                        Text("\(session.kind.displayName) · \(durationText(session.focusSeconds)) · \(session.outcome.rawValue)")
                            .font(.system(size: 10)).foregroundStyle(Theme.muted)
                    }.padding(.bottom, 16)
                }
            }
            Spacer(minLength: 15)
        }
    }
}

struct FeedbackView: View {
    @EnvironmentObject private var store: FocusStore
    let draft: SessionDraft
    @State private var outcome: Outcome?
    @State private var rating: Int?
    @State private var note = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Image(systemName: "checkmark.circle").font(.system(size: 28, weight: .light)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("这一轮，完成得怎么样？").font(.system(size: 23, weight: .semibold))
                    Text("已专注 \(durationText(draft.focusSeconds)) · 中断 \(draft.interruptions) 次")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }
            Text(goalDisplayText(draft.goal)).font(.system(size: 15)).lineLimit(3)
            VStack(alignment: .leading, spacing: 12) {
                Text("目标完成情况 · 必选").font(.system(size: 12)).foregroundStyle(Theme.muted)
                HStack(spacing: 10) {
                    ForEach(Outcome.allCases) { item in
                        Button { outcome = item } label: {
                            Text(item.rawValue).font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 13)
                                .foregroundStyle(outcome == item ? .white : Theme.ink)
                                .background(outcome == item ? Theme.accent : Theme.line.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                    }
                }
            }
            HStack {
                Text("专注状态 · 选填").font(.system(size: 12)).foregroundStyle(Theme.muted)
                Spacer()
                ForEach(1...5, id: \.self) { value in
                    Button { rating = rating == value ? nil : value } label: {
                        Image(systemName: value <= (rating ?? 0) ? "star.fill" : "star").font(.system(size: 20))
                            .foregroundStyle(value <= (rating ?? 0) ? Theme.accent : Theme.muted)
                    }.buttonStyle(.plain).accessibilityLabel("\(value) 分")
                }
            }
            TextField("有什么进展或干扰？（选填）", text: $note, axis: .vertical).lineLimit(3...4)
                .textFieldStyle(.plain).padding(13).background(.white, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                .onChange(of: note) { _, value in if value.count > 1000 { note = String(value.prefix(1000)) } }
            HStack {
                Text("保存后可在专注记录中查看").font(.system(size: 11)).foregroundStyle(Theme.muted)
                Spacer()
                Button("保存记录") { if let outcome { store.saveFeedback(outcome: outcome, rating: rating, note: note) } }
                    .buttonStyle(AccentButtonStyle()).disabled(outcome == nil)
            }
        }.padding(35).frame(width: 565).background(Theme.background).foregroundStyle(Theme.ink)
    }
}

// Local state updates only this small view; history, charts and the sidebar remain idle.
struct CountdownFace: View {
    @EnvironmentObject private var store: FocusStore
    let run: TimerRun?
    let previewSeconds: TimeInterval
    let size: CGFloat
    let textSize: CGFloat
    @State private var displayTime = Date()
    private var shouldRefresh: Bool { run != nil && run?.isPaused == false && store.hasVisibleWindow }
    private var remaining: TimeInterval { run?.remaining(at: displayTime) ?? previewSeconds }
    private var progress: Double { guard let run else { return 0 }; return run.elapsed(at: displayTime) / run.plannedSeconds }

    var body: some View {
        ZStack {
            Circle().stroke(Theme.line.opacity(0.7), lineWidth: 2)
            Circle().trim(from: 0, to: CGFloat(max(0.003, progress)))
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 12) {
                Text(clockText(remaining)).font(.system(size: textSize, weight: .ultraLight, design: .rounded))
                    .monospacedDigit().tracking(-2).accessibilityLabel("剩余 \(clockText(remaining))")
                Text(run?.phase == .rest ? "休 息" : "专 注")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted).tracking(5)
            }
        }
        .frame(width: size, height: size)
        .onChange(of: run) { _, _ in displayTime = Date() }
        .task(id: shouldRefresh) {
            displayTime = Date()
            guard shouldRefresh else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard !Task.isCancelled else { return }
                displayTime = Date()
            }
        }
    }
}
