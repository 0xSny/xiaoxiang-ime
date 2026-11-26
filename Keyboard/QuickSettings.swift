import UIKit

/// Keyboard-internal quick settings drawer. Reads and writes the settings inside the keyboard process, so it
/// works even when a self-signing tool stripped the App Group and host/keyboard sandboxes are isolated.
final class QuickSettingsView: UIScrollView {
    var onClose: (() -> Void)?
    var onClearLearned: (() -> Void)?
    var onImport: (() -> String)?       // returns a status message

    private struct Row {
        let title: UILabel
        let control: UIView
        let width: CGFloat
        let height: CGFloat
    }
    private var rows: [Row] = []
    private var theme = Theme.light
    private let status = UILabel()
    private let closeButton = UIButton(type: .system)

    private let scheme = UISegmentedControl(items: ["全拼", "小鹤双拼"])
    private let hint = UISegmentedControl(items: ["完整助记", "极简韵母", "盲打隐藏"])
    private let haptic = UISegmentedControl(items: ["关闭", "轻微", "清脆", "强劲"])
    private let sound = UISwitch()
    private let height = UISlider()
    private let oneHand = UISegmentedControl(items: ["完整", "居左", "居右"])
    private let fuzzy = UISwitch()
    private let correction = UISwitch()
    private let clear = UIButton(type: .system)
    private let importBtn = UIButton(type: .system)
    private var clearArmed = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        alwaysBounceVertical = true
        showsVerticalScrollIndicator = false
        delaysContentTouches = false
        height.minimumValue = 0.85
        height.maximumValue = 1.25

        add("输入方案", scheme, 190)
        add("双拼键面助记", hint, 230)
        add("震动力度", haptic, 230)
        add("按键音", sound, 51)
        add("键盘高度", height, 190)
        add("单手模式", oneHand, 190)
        add("模糊音（常用组合）", fuzzy, 51)
        add("邻键纠错", correction, 51)
        clear.setTitle("清空自学习词库", for: .normal)
        clear.setTitleColor(.systemRed, for: .normal)
        clear.addTarget(self, action: #selector(clearTapped), for: .touchUpInside)
        add("", clear, 150)
        importBtn.setTitle("从剪贴板导入宿主设置", for: .normal)
        importBtn.addTarget(self, action: #selector(importTapped), for: .touchUpInside)
        add("", importBtn, 190)

        closeButton.setTitle("完成", for: .normal)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        addSubview(closeButton)
        status.font = UIFont.systemFont(ofSize: 12)
        status.textAlignment = .center
        addSubview(status)

        for c in [scheme, hint, haptic, oneHand] as [UISegmentedControl] { c.addTarget(self, action: #selector(changed), for: .valueChanged) }
        for c in [sound, fuzzy, correction] as [UISwitch] { c.addTarget(self, action: #selector(changed), for: .valueChanged) }
        height.addTarget(self, action: #selector(changed), for: .valueChanged)
        height.addTarget(self, action: #selector(heightReleased), for: [.touchUpInside, .touchUpOutside])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func add(_ title: String, _ control: UIView, _ width: CGFloat) {
        let l = UILabel()
        l.text = title
        l.font = UIFont.systemFont(ofSize: 15)
        addSubview(l)
        addSubview(control)
        rows.append(Row(title: l, control: control, width: width, height: 40))
    }

    func apply(theme t: Theme) {
        theme = t
        backgroundColor = t.panel
        for r in rows { r.title.textColor = t.text }
        closeButton.setTitleColor(t.accent, for: .normal)
        importBtn.setTitleColor(t.accent, for: .normal)
        status.textColor = t.subText
        for c in [scheme, hint, haptic, oneHand] as [UISegmentedControl] {
            c.overrideUserInterfaceStyle = t.isDark ? .dark : .light
        }
    }

    func reload() {
        let s = SettingsStore.shared.current
        scheme.selectedSegmentIndex = s.scheme
        hint.selectedSegmentIndex = s.hintStyle
        haptic.selectedSegmentIndex = s.haptic
        sound.isOn = s.soundOn
        height.value = Float(s.keyboardHeight)
        oneHand.selectedSegmentIndex = s.oneHand
        fuzzy.isOn = (s.fuzzy & 0x3F) != 0
        correction.isOn = s.spatialSensitivity > 0.01
        hint.isEnabled = s.scheme == 1
        clearArmed = false
        clear.setTitle("清空自学习词库", for: .normal)
        status.text = SettingsStore.shared.hasSharedContainer ? "已启用共享容器：宿主 App 与键盘设置自动同步" : "沙盒隔离模式：请在此处直接修改设置"
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let W = bounds.width
        var y: CGFloat = 4
        closeButton.frame = CGRect(x: W - 70, y: y, width: 60, height: 30)
        y += 30
        for r in rows {
            if r.title.text?.isEmpty == false {
                r.title.frame = CGRect(x: 14, y: y, width: W - r.width - 34, height: r.height)
                r.control.frame = CGRect(x: W - r.width - 14, y: y + (r.height - (r.control is UISwitch ? 31 : 30)) / 2, width: r.width, height: r.control is UISwitch ? 31 : 30)
            } else {
                r.control.frame = CGRect(x: 14, y: y, width: W - 28, height: r.height)
                (r.control as? UIButton)?.contentHorizontalAlignment = .left
            }
            y += r.height
        }
        status.frame = CGRect(x: 10, y: y + 4, width: W - 20, height: 18)
        contentSize = CGSize(width: W, height: y + 34)
    }

    @objc private func changed() {
        SettingsStore.shared.update { s in
            s.scheme = scheme.selectedSegmentIndex
            s.hintStyle = hint.selectedSegmentIndex
            s.haptic = haptic.selectedSegmentIndex
            s.soundOn = sound.isOn
            s.keyboardHeight = Double((height.value * 100).rounded() / 100)
            s.oneHand = oneHand.selectedSegmentIndex
            s.fuzzy = fuzzy.isOn ? (s.fuzzy == 0 ? 0b00100111111 : s.fuzzy) : 0
            s.spatialSensitivity = correction.isOn ? max(s.spatialSensitivity, 1.0) : 0
        }
        hint.isEnabled = scheme.selectedSegmentIndex == 1
    }

    @objc private func heightReleased() { changed() }

    @objc private func clearTapped() {
        if !clearArmed {
            clearArmed = true
            clear.setTitle("再点一次确认清空", for: .normal)
            return
        }
        clearArmed = false
        clear.setTitle("清空自学习词库", for: .normal)
        onClearLearned?()
        status.text = "自学习词库已清空"
    }

    @objc private func importTapped() {
        status.text = onImport?() ?? ""
        reload()
    }

    @objc private func closeTapped() { onClose?() }
}
