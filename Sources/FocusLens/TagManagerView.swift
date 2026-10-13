import SwiftUI

struct TagManagerView: View {
    @EnvironmentObject private var store: FocusStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var editing: TaskKind?
    @State private var deleting: TaskKind?
    @State private var message: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("标签管理").font(.system(size: 22, weight: .semibold))
                Spacer()
                Button("完成") { dismiss() }.buttonStyle(QuietButtonStyle())
            }
            Text("改名会同步到相关记录；删除只移除可选项，历史记录保留原标签。")
                .font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVStack(spacing: 0) {
                    if store.data.taskKinds.isEmpty {
                        Text("还没有标签，在下方新增即可。")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted).padding(.vertical, 35)
                    }
                    ForEach(store.data.taskKinds) { kind in
                        HStack(spacing: 10) {
                            Image(systemName: "tag").foregroundStyle(Theme.accent).font(.system(size: 12))
                            Text(kind.displayName).font(.system(size: 13)).lineLimit(1)
                            Spacer()
                            Button {
                                editing = kind
                                name = kind.rawValue
                                message = nil
                                nameFocused = true
                            } label: { Image(systemName: "pencil") }
                                .buttonStyle(.plain).foregroundStyle(Theme.muted)
                                .accessibilityLabel("编辑标签\(kind.displayName)")
                                .help("编辑标签")
                            Button { deleting = kind } label: { Image(systemName: "trash") }
                                .buttonStyle(.plain).foregroundStyle(Theme.muted)
                                .accessibilityLabel("删除标签\(kind.displayName)")
                                .help("删除标签").padding(.leading, 12)
                        }.padding(.vertical, 13).padding(.horizontal, 2)
                        Rectangle().fill(Theme.line).frame(height: 1)
                    }
                }
            }.frame(height: 230)
            HStack(spacing: 10) {
                TextField(editing == nil ? "新标签名称（1–20 字）" : "编辑标签名称", text: $name)
                    .textFieldStyle(.roundedBorder).focused($nameFocused)
                    .accessibilityLabel("标签名称").onSubmit { save() }
                Button(editing == nil ? "新增" : "保存", action: save)
                    .buttonStyle(AccentButtonStyle())
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack {
                if let message { Text(message).foregroundStyle(Theme.accent) }
                else { Text(editing == nil ? "新增后会自动选中该标签。也可以选择“无标签”直接开始。" : "正在编辑“\(editing!.displayName)”") }
                Spacer()
                if editing != nil {
                    Button("取消编辑") { editing = nil; name = ""; message = nil }
                        .buttonStyle(.plain).foregroundStyle(Theme.muted)
                }
            }.font(.system(size: 10)).foregroundStyle(Theme.muted).frame(minHeight: 16)
        }
        .padding(25).frame(width: 490).background(Theme.background).foregroundStyle(Theme.ink)
        .confirmationDialog("删除标签“\(deleting?.displayName ?? "")”？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("删除标签", role: .destructive) {
                guard let kind = deleting else { return }
                do {
                    try store.deleteKind(kind)
                    if editing == kind { editing = nil; name = "" }
                    message = nil
                } catch { message = error.localizedDescription }
                deleting = nil
            }
            Button("取消", role: .cancel) { deleting = nil }
        } message: { Text("已有专注记录和时间统计会保留。") }
    }

    private func save() {
        do {
            if let editing { try store.renameKind(editing, to: name) }
            else { try store.addKind(name) }
            editing = nil
            name = ""
            message = nil
        } catch { message = error.localizedDescription }
    }
}
