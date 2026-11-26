import SwiftUI
import UIKit

@main
struct IMEHostApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - Model bound to the shared strongly typed settings

final class SettingsModel: ObservableObject {
    @Published var s: IMESettings {
        didSet {
            if s != SettingsStore.shared.current { SettingsStore.shared.save(s) }
        }
    }
    @Published var keyboardEnabled = false
    @Published var statsText = "—"

    init() {
        s = SettingsStore.shared.current
        NotificationCenter.default.addObserver(forName: .imeSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            let cur = SettingsStore.shared.current
            if cur != self.s { self.s = cur }
        }
        refresh()
    }

    func refresh() {
        SettingsStore.shared.reload()
        let modes = (UserDefaults.standard.object(forKey: "AppleKeyboards") as? [String]) ?? []
        keyboardEnabled = modes.contains("com.custom.ime.keyboard")
        if let url = SettingsStore.shared.statsURL, let d = try? Data(contentsOf: url),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            statsText = "已学词条 \(o["words"] as? Int ?? 0) 个 · 搭配记忆 \(o["bigrams"] as? Int ?? 0) 条"
        } else if SettingsStore.shared.hasSharedContainer {
            statsText = "暂无数据（在键盘中打字后自动生成）"
        } else {
            statsText = "沙盒隔离：词库保存在键盘内，请在键盘内设置查看 / 清空"
        }
    }
}

// MARK: - Typing sandbox

struct TestField: UIViewRepresentable {
    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.font = UIFont.systemFont(ofSize: 17)
        v.layer.cornerRadius = 10
        v.layer.borderWidth = 1
        v.layer.borderColor = UIColor.separator.cgColor
        v.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        v.text = ""
        return v
    }
    func updateUIView(_ uiView: UITextView, context: Context) {}
}

struct ContentView: View {
    @StateObject private var model = SettingsModel()
    @State private var newCode = ""
    @State private var newText = ""
    @State private var toast = ""
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Form {
                Section("打字测试（免跳转直接试键盘）") {
                    TestField().frame(height: 96)
                    guideCard
                }
                Section("输入方案与双拼") {
                    Picker("输入方案", selection: $model.s.scheme) {
                        Text("全拼").tag(0)
                        Text("小鹤双拼").tag(1)
                    }.pickerStyle(.segmented)
                    Picker("双拼键面助记", selection: $model.s.hintStyle) {
                        Text("完整助记").tag(0)
                        Text("极简韵母").tag(1)
                        Text("隐藏").tag(2)
                    }.pickerStyle(.segmented)
                    Picker("行内预编辑", selection: $model.s.preeditStyle) {
                        Text("展开全拼提示").tag(0)
                        Text("原始双拼码").tag(1)
                    }.pickerStyle(.segmented)
                }
                Section("手感与声效") {
                    Picker("触感震动", selection: $model.s.haptic) {
                        Text("关闭").tag(0)
                        Text("轻微").tag(1)
                        Text("清脆").tag(2)
                        Text("强劲").tag(3)
                    }.pickerStyle(.segmented)
                    Toggle("按键音", isOn: $model.s.soundOn)
                    HStack { Text("音量"); Slider(value: $model.s.soundVolume, in: 0...1) }
                    Toggle("按下放大气泡", isOn: $model.s.bubbleOn)
                }
                Section("布局与尺寸") {
                    HStack {
                        Text("键盘高度")
                        Slider(value: $model.s.keyboardHeight, in: 0.85...1.25)
                        Button("默认") { model.s.keyboardHeight = 1.0 }.buttonStyle(.borderless)
                    }
                    Picker("单手模式", selection: $model.s.oneHand) {
                        Text("完整").tag(0)
                        Text("居左").tag(1)
                        Text("居右").tag(2)
                    }.pickerStyle(.segmented)
                    Toggle("按键上滑输入数字 / 符号", isOn: $model.s.swipeUp)
                }
                Section("纠错与混输") {
                    ForEach(0..<IMESettings.fuzzyNames.count, id: \.self) { i in
                        Toggle("模糊音  \(IMESettings.fuzzyNames[i])", isOn: Binding(
                            get: { model.s.fuzzyEnabled(i) }, set: { model.s.setFuzzy(i, $0) }))
                    }
                    VStack(alignment: .leading) {
                        Text("邻键空间纠错灵敏度：" + (model.s.spatialSensitivity < 0.05 ? "关闭" : String(format: "%.1f", model.s.spatialSensitivity)))
                        Slider(value: $model.s.spatialSensitivity, in: 0...2)
                    }
                    Picker("中英混输自动空格", selection: $model.s.autoSpace) {
                        Text("关闭").tag(0)
                        Text("中英之间加空格").tag(1)
                    }
                    Toggle("双击空格输入句号", isOn: $model.s.doubleSpacePeriod)
                }
                Section("手势与词库") {
                    VStack(alignment: .leading) {
                        Text("空格移动光标灵敏度：" + String(format: "%.1f", model.s.spaceCursorSensitivity))
                        Slider(value: $model.s.spaceCursorSensitivity, in: 0.5...2.0)
                    }
                    Toggle("退格左滑清空拼音", isOn: $model.s.backspaceSwipeClear)
                    Toggle("剪贴板快捷粘贴提示", isOn: $model.s.clipboardHint)
                    Picker("外观（浅色款随系统自动变深）", selection: $model.s.appearance) {
                        Text("清爽浅色").tag(0)
                        Text("纯净亮白").tag(1)
                        Text("始终深色").tag(2)
                    }.pickerStyle(.segmented)
                    Toggle("自学习（选词晋升 / 自动造词）", isOn: $model.s.learning)
                    Text(model.statsText).font(.footnote).foregroundColor(.secondary)
                    Button("重置个人自学习词库", role: .destructive) { resetLearned() }
                }
                Section("自定义快捷短语（输入编码 → 候选首位展开）") {
                    ForEach(model.s.phrases, id: \.self) { p in
                        HStack { Text(p.code).font(.system(.body, design: .monospaced)); Spacer(); Text(p.text).foregroundColor(.secondary).lineLimit(1) }
                    }
                    .onDelete { idx in model.s.phrases.remove(atOffsets: idx) }
                    HStack {
                        TextField("编码，如 yx", text: $newCode).textInputAutocapitalization(.never).autocorrectionDisabled().frame(width: 100)
                        TextField("展开内容", text: $newText)
                        Button("添加") {
                            let c = newCode.trimmingCharacters(in: .whitespaces).lowercased()
                            let t = newText.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !c.isEmpty, !t.isEmpty else { return }
                            model.s.phrases.removeAll { $0.code == c }
                            model.s.phrases.append(Phrase(code: c, text: t))
                            newCode = ""; newText = ""
                        }.buttonStyle(.borderless)
                    }
                    Button("同步到键盘（复制同步数据）") { syncToKeyboard() }
                    Text("沙盒隔离（无 App Group）时：点上面按钮后，切到键盘 → 顶部 ⚙ 设置 → 「从剪贴板导入宿主设置」，即可把本页全部设置与短语带入键盘。").font(.footnote).foregroundColor(.secondary)
                }
                if !toast.isEmpty { Section { Text(toast).font(.footnote) } }
            }
            .navigationTitle("小象输入法")
        }
        .onChange(of: scenePhase) { phase in if phase == .active { model.refresh() } }
    }

    private var guideCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: model.keyboardEnabled ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(model.keyboardEnabled ? .green : .orange)
                Text(model.keyboardEnabled ? "键盘已启用" : "键盘尚未启用").font(.headline)
            }
            Text("设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → 小象输入法，并点开它打开「允许完全访问」（触感震动、剪贴板、同步需要）。长按 🌐 切换到本键盘。")
                .font(.footnote).foregroundColor(.secondary)
            Button("打开系统设置") {
                if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
            }.buttonStyle(.borderless)
        }
    }

    private func syncToKeyboard() {
        UIPasteboard.general.string = SettingsStore.shared.exportSyncString()
        toast = "已复制同步数据 ✓  现在切到键盘，在 ⚙ 设置中点「从剪贴板导入宿主设置」。"
    }

    private func resetLearned() {
        if let url = SettingsStore.shared.resetFlagURL {
            try? Data().write(to: url)
            toast = "已提交重置请求，下次打开键盘时清空自学习词库。"
        } else {
            toast = "沙盒隔离模式下宿主无法直接清空，请在键盘 ⚙ 设置中点「清空自学习词库」。"
        }
    }
}
