import AppKit
import SwiftUI

// Synthetic, isolated native previews. No system screen capture, real model, or user data is used.
@main struct NativePreview {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FocusLensNativePreview-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("automatic-activities"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let calendar = Calendar.current
        func time(_ hour: Int, _ minute: Int) -> Date { calendar.date(bySettingHour: hour, minute: minute, second: 0, of: Date())! }
        var now = time(13, 54)
        func record(_ h: Int, _ m: Int, _ eh: Int, _ em: Int, _ category: ActivityCategory, _ title: String, _ app: String) -> ActivitySegment {
            ActivitySegment(start: time(h,m), end: time(eh,em), category: category, title: title, app: app, bundleID: "demo." + app)
        }
        var records = [record(13,22,13,54,.reading,"阅读技术文档","浏览器"), record(11,52,12,30,.communication,"讨论项目方案","即时通讯"), record(11,10,11,52,.reading,"查阅接口文档","浏览器"), record(9,44,11,10,.development,"实现活动时间线","代码编辑器"), record(9,26,9,44,.other,"整理工作文件","文件管理器")]
        for (start, end, reason) in [(0,2,ActivityUnknownReason.waiting), (2,8,.failure), (8,14,.insufficientEvidence), (14,20,.legacy)] {
            var item = record(9,start,9,end,.unknown,reason.label,"示例应用")
            item.unknownReason = reason; records.append(item)
        }
        let formatter = DateFormatter(); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
        for (day, values) in Dictionary(grouping: records, by: { formatter.string(from: $0.start) }) {
            try JSONEncoder().encode(values).write(to: directory.appendingPathComponent("automatic-activities/" + day + ".json"))
        }
        var config = AutomaticConfig(); config.ai = AISettings(baseURL: "http://127.0.0.1:9/v1", model: "示例模型（不连接）")
        config.enabled = true; config.verifiedSignature = VisionService.signature(config); config.consentSignature = config.verifiedSignature
        try JSONEncoder().encode(config).write(to: directory.appendingPathComponent("automatic-settings.json"))
        let store = FocusStore(directory: directory, startClock: false)
        let tracker = AutomaticTracker(directory: directory, startClock: false, idleSeconds: { 0 }, now: { now }, appearance: store.appearance, permission: { true }, sessionAvailable: { true }, foreground: { ForegroundContext(pid: 42, bundleID: "demo.editor", name: "代码编辑器") }, capture: { _ in
            MemoryScreenCapture.Frame(jpeg: Data([1]), fingerprint: Data([1]), contextKey: "synthetic", capturedAt: now)
        }, analyze: { _, _, _ in ActivityClassification(category: .development, title: "调整活动识别逻辑") })
        for index in 0...21 {
            now = time(13,54).addingTimeInterval(Double(index * 120))
            tracker.sample(); try await Task.sleep(for: .milliseconds(5))
        }
        store.now = now
        let evidence = try tracker.readSegments(in: Period.today.interval(now: now))
        let totalText = compactDuration(evidence.reduce(0) { $0 + $1.seconds })
        let report = ActivitySummary(day: ActivityPresentation.dayKey(now), updatedAt: now, content: "今天主要在开发与阅读之间切换，已记录约 \(totalText)，其中 20 分钟没有确定类别。\n\n上午有一段较长的开发活动，约 86 分钟。午后先阅读技术资料，再回到代码编辑。\n\n12:30–13:22 未计入活动时长。未记录的时间不推测用途，也不要求补填。", model: "示例模型", fingerprint: try SummaryPolicy.fingerprint(evidence), evidence: evidence)
        let archive = SummaryArchive(consentSignature: "automatic-summary-v1:" + VisionService.signature(config), reports: [report])
        try JSONEncoder().encode(archive).write(to: directory.appendingPathComponent("automatic-summaries.json"))
        let summary = AutomaticSummaryController(directory: directory, tracker: tracker, startClock: false, now: { now }, request: { _, _, _, _ in fatalError("Native preview must not send requests") })
        for (name, destination, size) in [("today",Destination.today,NSSize(width:1080,height:760)), ("today-compact",Destination.today,NSSize(width:860,height:620)), ("timeline",Destination.activity,NSSize(width:1080,height:760)), ("insights",Destination.insights,NSSize(width:1080,height:760)), ("settings",Destination.settings,NSSize(width:1080,height:760))] {
            let root = RootView(initialDestination: destination).environmentObject(store).environmentObject(tracker).environmentObject(summary)
                .environment(\.locale, Locale(identifier: "zh_CN")).environment(\.controlActiveState, .active).tint(Theme.accent).frame(width: size.width,height: size.height)
            let view = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view
            view.frame = NSRect(origin: .zero, size: size)
            try await Task.sleep(for: .milliseconds(150))
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            try save(view, to: output.appendingPathComponent(name + ".png"))
            window.close()
            print("Native preview: \(name)")
        }
        let floating = FocusFloatingContent(); floating.apply(appearance: store.appearance, active: true)
        floating.status.stringValue = "自动记录 · 开发"; floating.title.stringValue = "调整活动识别逻辑"
        floating.detail.stringValue = "代码编辑器 · 最近识别于 14:36"; floating.time.stringValue = "约 42 分钟"
        floating.daily.stringValue = "今天开发 · 约 2 小时 08 分"
        floating.frame = NSRect(origin:.zero,size:floating.desiredSize); floating.layoutSubtreeIfNeeded()
        try save(floating, to: output.appendingPathComponent("floating.png"))
        summary.shutdown(); tracker.shutdown()
    }
    @MainActor static func save(_ view: NSView, to url: URL) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw AutomaticError.invalidResponse }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let bytes = bitmap.representation(using: .png, properties: [:]) else { throw AutomaticError.invalidResponse }
        try bytes.write(to: url)
    }
}
