import UIKit

// MARK: - Grid panel (symbols / emoji / phrases)

struct GridCategory {
    var title: String
    var items: [String]
    var columns: Int
    var fontSize: CGFloat
    var cellHeight: CGFloat
}

enum PanelData {
    static let cnPunct = ["，", "。", "？", "！", "、", "：", "；", "“”", "‘’", "（）", "《》", "「」", "『』", "【】", "〈〉", "〔〕", "…", "——", "～", "·",
                          "￥", "＠", "＃", "％", "＆", "＊", "＋", "－", "＝", "／", "｜", "•", "※", "§", "¶", "‖"]
    static let enPunct = [",", ".", "?", "!", "'", "\"", ":", ";", "()", "[]", "{}", "<>", "/", "\\", "|", "@", "#", "$", "%", "^",
                          "&", "*", "-", "_", "+", "=", "~", "`", "…", "·"]
    static let math = ["+", "−", "×", "÷", "=", "≠", "≈", "±", "<", ">", "≤", "≥", "∞", "%", "‰", "√", "π", "°", "∑", "∏", "²", "³", "½", "¼", "¾", "∠", "∥", "⊥"]
    static let money = ["¥", "$", "€", "£", "₩", "¢", "฿", "₹", "₽", ":", "℃", "℉", "年", "月", "日", "时", "分", "秒", "AM", "PM", "星期", "元", "角", "分"]
    static let arrows = ["←", "→", "↑", "↓", "↖", "↗", "↘", "↙", "★", "☆", "○", "●", "◎", "◇", "◆", "□", "■", "△", "▲", "▽", "▼", "♀", "♂", "✓", "✗", "©", "®", "™"]
    static let pairs: Set<String> = ["“”", "‘’", "（）", "《》", "「」", "『』", "【】", "〈〉", "〔〕", "()", "[]", "{}", "<>", "\"\""]

    static let emojiFaces = "😀😃😄😁😆😅😂🤣😊😇🙂😉😍🥰😘😋😛😜🤪🤔🤨😐😑😶🙄😏😴😌😔😪🤤😷🤒🥵🥶🤯😎🤓😕😟🙁😮😲😳🥺😢😭😤😠😡😱😨😰🤗🤭🤫😈".map { String($0) }
    static let emojiHands = ["👍", "👎", "👌", "✌️", "🤞", "🤟", "🤘", "👈", "👉", "👆", "👇", "✋", "👋", "🙏", "👏", "🙌", "🤝", "💪", "❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "💔", "💕", "💯"]
    static let emojiAnimals = ["🐶", "🐱", "🐭", "🐹", "🐰", "🦊", "🐻", "🐼", "🐨", "🐯", "🦁", "🐮", "🐷", "🐸", "🐵", "🐔", "🐧", "🐦", "🦆", "🦉", "🐴", "🦄", "🐝", "🦋", "🐌", "🐢", "🐍", "🐙", "🐠", "🐬", "🐳"]
    static let emojiFood = ["🍎", "🍐", "🍊", "🍋", "🍌", "🍉", "🍇", "🍓", "🍒", "🍑", "🍍", "🥝", "🍅", "🥑", "🌽", "🥕", "🍞", "🧀", "🍗", "🍔", "🍟", "🍕", "🌭", "🍜", "🍣", "🍦", "🍰", "🎂", "🍩", "🍪", "☕", "🍺", "🍷"]
    static let emojiMisc = ["🔥", "✨", "⭐", "🌟", "💥", "🎉", "🎁", "🎈", "🏆", "⚽", "🏀", "🎮", "🎵", "🎤", "📱", "💻", "📷", "🚗", "✈️", "🏠", "🌈", "☀️", "🌙", "⛅", "❄️", "💧", "🌹", "🌸"]

    static func symbols() -> [GridCategory] {
        [GridCategory(title: "中文", items: cnPunct, columns: 6, fontSize: 22, cellHeight: 44),
         GridCategory(title: "英文", items: enPunct, columns: 6, fontSize: 22, cellHeight: 44),
         GridCategory(title: "数学", items: math, columns: 6, fontSize: 22, cellHeight: 44),
         GridCategory(title: "货币时间", items: money, columns: 6, fontSize: 20, cellHeight: 44),
         GridCategory(title: "箭头", items: arrows, columns: 6, fontSize: 22, cellHeight: 44)]
    }

    static func emoji() -> [GridCategory] {
        [GridCategory(title: "😀", items: emojiFaces, columns: 8, fontSize: 28, cellHeight: 42),
         GridCategory(title: "👍", items: emojiHands, columns: 8, fontSize: 28, cellHeight: 42),
         GridCategory(title: "🐶", items: emojiAnimals, columns: 8, fontSize: 28, cellHeight: 42),
         GridCategory(title: "🍎", items: emojiFood, columns: 8, fontSize: 28, cellHeight: 42),
         GridCategory(title: "🎉", items: emojiMisc, columns: 8, fontSize: 28, cellHeight: 42)]
    }
}

final class GridPanelView: UIView {
    var onInsert: ((String) -> Void)?
    var onBack: (() -> Void)?
    var onDelete: (() -> Void)?

    private var cats: [GridCategory] = []
    private var current = 0
    private var emptyHint: String?
    private var theme = Theme.light
    private let scroller = KineticScroller()
    private var pool: [CATextLayer] = []
    private var slotKey: [Int] = []
    private let tabBar = CALayer()
    private var tabLayers: [CATextLayer] = []
    private let tabIndicator = CALayer()
    private let backLayer = CATextLayer()
    private let deleteLayer = CALayer()
    private let hintLayer = CATextLayer()
    private let flash = CALayer()
    private var scale: CGFloat = 3
    private let barH: CGFloat = 40
    private var downIdx = -1

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isMultipleTouchEnabled = false
        for l in [tabBar, tabIndicator, deleteLayer, flash] { l.actions = ["frame": NSNull(), "position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull(), "hidden": NSNull(), "contents": NSNull()] }
        flash.cornerRadius = 8
        flash.isHidden = true
        layer.addSublayer(flash)
        layer.addSublayer(tabBar)
        layer.addSublayer(tabIndicator)
        for t in [backLayer, hintLayer] { t.alignmentMode = .center; t.actions = ["string": NSNull(), "contents": NSNull(), "opacity": NSNull(), "frame": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull()] }
        layer.addSublayer(backLayer)
        layer.addSublayer(deleteLayer)
        layer.addSublayer(hintLayer)
        scroller.onChange = { [weak self] in self?.updateCells() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setCategories(_ c: [GridCategory], emptyHint: String? = nil, selected: Int = 0) {
        cats = c
        current = min(max(selected, 0), max(c.count - 1, 0))
        self.emptyHint = emptyHint
        scroller.offset = 0
        withoutAnimation { rebuildTabs(); relayout() }
    }

    func apply(theme t: Theme) {
        theme = t
        withoutAnimation { rebuildTabs(); relayout() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        withoutAnimation { relayout() }
    }

    private func rebuildTabs() {
        for l in tabLayers { l.removeFromSuperlayer() }
        tabLayers.removeAll()
        for _ in cats {
            let t = CATextLayer()
            t.alignmentMode = .center
            t.contentsScale = scale
            t.actions = ["string": NSNull(), "frame": NSNull(), "position": NSNull(), "bounds": NSNull()]
            tabLayers.append(t)
            layer.addSublayer(t)
        }
    }

    private func gridRect() -> CGRect { CGRect(x: 0, y: 0, width: bounds.width, height: max(bounds.height - barH, 1)) }

    private func relayout() {
        guard bounds.width > 1 else { return }
        slotKey = [Int](repeating: -1, count: pool.count)
        backgroundColor = theme.panel
        let w = bounds.width, h = bounds.height
        tabBar.frame = CGRect(x: 0, y: h - barH, width: w, height: barH)
        tabBar.backgroundColor = theme.functionKey.withAlphaComponent(theme.isDark ? 0.5 : 0.55).cgColor
        let backW: CGFloat = 60, delW: CGFloat = 56
        backLayer.contentsScale = scale
        backLayer.string = NSAttributedString(string: "返回", attributes: [.font: UIFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: theme.text])
        backLayer.frame = CGRect(x: 0, y: h - barH + 10, width: backW, height: 22)
        deleteLayer.contentsScale = scale
        deleteLayer.contentsGravity = .center
        let cfg = UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        if let img = UIImage(systemName: "delete.left", withConfiguration: cfg)?.withTintColor(theme.text, renderingMode: .alwaysOriginal) {
            let f = UIGraphicsImageRendererFormat(); f.scale = scale
            deleteLayer.contents = UIGraphicsImageRenderer(size: img.size, format: f).image { _ in img.draw(at: .zero) }.cgImage
        }
        deleteLayer.frame = CGRect(x: w - delW, y: h - barH, width: delW, height: barH)
        let tabsW = w - backW - delW
        let n = max(cats.count, 1)
        let tw = tabsW / CGFloat(n)
        for (i, t) in tabLayers.enumerated() {
            let sel = i == current
            t.string = NSAttributedString(string: cats[i].title, attributes: [.font: UIFont.systemFont(ofSize: 15, weight: sel ? .semibold : .regular), .foregroundColor: sel ? theme.accent : theme.text.withAlphaComponent(0.65)])
            t.frame = CGRect(x: backW + CGFloat(i) * tw, y: h - barH + 10, width: tw, height: 22)
        }
        tabIndicator.backgroundColor = theme.accent.cgColor
        tabIndicator.frame = CGRect(x: backW + CGFloat(current) * tw + tw * 0.3, y: h - 3, width: tw * 0.4, height: 2)
        tabIndicator.isHidden = cats.isEmpty
        // content metrics
        if let c = currentCategory() {
            let rows = (c.items.count + c.columns - 1) / c.columns
            let content = CGFloat(rows) * c.cellHeight
            scroller.minOffset = 0
            scroller.maxOffset = max(0, content - gridRect().height)
            scroller.clampOffset()
            hintLayer.isHidden = true
        } else {
            scroller.maxOffset = 0
            hintLayer.isHidden = emptyHint == nil
            hintLayer.contentsScale = scale
            hintLayer.string = NSAttributedString(string: emptyHint ?? "", attributes: [.font: UIFont.systemFont(ofSize: 15), .foregroundColor: theme.text.withAlphaComponent(0.6)])
            hintLayer.frame = CGRect(x: 20, y: h / 2 - 30, width: w - 40, height: 20)
        }
        updateCells()
    }

    private func currentCategory() -> GridCategory? {
        cats.indices.contains(current) ? cats[current] : nil
    }

    private func updateCells() {
        guard let c = currentCategory() else {
            for l in pool { l.isHidden = true }
            return
        }
        let w = bounds.width
        let cw = w / CGFloat(c.columns)
        let off = scroller.offset
        let firstRow = max(0, Int(off / c.cellHeight))
        let visRows = Int(ceil(gridRect().height / c.cellHeight)) + 1
        var slot = 0
        let font = UIFont.systemFont(ofSize: c.fontSize)
        let isEmoji = c.cellHeight < 43 && c.fontSize > 26
        withoutAnimation {
            for r in firstRow..<(firstRow + visRows) {
                for col in 0..<c.columns {
                    let idx = r * c.columns + col
                    if idx >= c.items.count { break }
                    while pool.count <= slot {
                        let t = CATextLayer()
                        t.alignmentMode = .center
                        t.contentsScale = scale
                        t.actions = ["string": NSNull(), "contents": NSNull(), "opacity": NSNull(), "frame": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
                        pool.append(t)
                        slotKey.append(-1)
                        layer.insertSublayer(t, above: flash)
                    }
                    let t = pool[slot]
                    t.contentsScale = scale
                    var label = c.items[idx]
                    if c.columns <= 2 && label.count > 14 { label = String(label.prefix(13)) + "…" }
                    let key = current &* 1_000_003 &+ idx
                    if slotKey[slot] != key {
                        slotKey[slot] = key
                        t.string = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: theme.text])
                    }
                    t.frame = CGRect(x: CGFloat(col) * cw, y: CGFloat(r) * c.cellHeight - off + (c.cellHeight - c.fontSize * 1.3) / 2, width: cw, height: c.fontSize * 1.3)
                    t.isHidden = false
                    slot += 1
                }
            }
            while slot < pool.count { pool[slot].isHidden = true; slot += 1 }
        }
        _ = isEmoji
    }

    private func cellIndex(at p: CGPoint) -> Int {
        guard let c = currentCategory(), p.y < bounds.height - barH else { return -1 }
        let cw = bounds.width / CGFloat(c.columns)
        let col = min(c.columns - 1, max(0, Int(p.x / cw)))
        let row = Int((p.y + scroller.offset) / c.cellHeight)
        let idx = row * c.columns + col
        return idx < c.items.count ? idx : -1
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        let p = t.location(in: self)
        downIdx = -1
        if p.y < bounds.height - barH {
            scroller.begin(p.y)
            downIdx = cellIndex(at: p)
            if let c = currentCategory(), downIdx >= 0 {
                let cw = bounds.width / CGFloat(c.columns)
                let row = downIdx / c.columns, col = downIdx % c.columns
                withoutAnimation {
                    flash.backgroundColor = theme.functionKey.withAlphaComponent(0.6).cgColor
                    flash.frame = CGRect(x: CGFloat(col) * cw + 2, y: CGFloat(row) * c.cellHeight - scroller.offset + 2, width: cw - 4, height: c.cellHeight - 4)
                    flash.isHidden = false
                }
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first, downIdx >= 0 || scroller.dragging else { return }
        if scroller.move(t.location(in: self).y) { withoutAnimation { flash.isHidden = true } }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        let p = t.location(in: self)
        withoutAnimation { flash.isHidden = true }
        if scroller.dragging { scroller.end(); return }
        if p.y >= bounds.height - barH {
            let backW: CGFloat = 60, delW: CGFloat = 56
            if p.x < backW { onBack?(); return }
            if p.x > bounds.width - delW { onDelete?(); return }
            let n = max(cats.count, 1)
            let tw = (bounds.width - backW - delW) / CGFloat(n)
            let idx = Int((p.x - backW) / tw)
            if cats.indices.contains(idx) {
                current = idx
                scroller.offset = 0
                withoutAnimation { relayout() }
            }
            return
        }
        let idx = cellIndex(at: p)
        if idx >= 0, idx == downIdx, let c = currentCategory() { onInsert?(c.items[idx]) }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        withoutAnimation { flash.isHidden = true }
        scroller.end()
    }
}

// MARK: - Expanded candidate grid

final class CandidateGridView: UIView {
    var onSelect: ((CandItem) -> Void)?

    private var all: [CandItem] = []
    private var filtered: [CandItem] = []
    private var rows: [(start: Int, end: Int, y: CGFloat)] = []
    private var widths: [CGFloat] = []
    private var filter = 0   // 0 all, 1 single char, 2, 3, 4 = 4+
    private var theme = Theme.light
    private let scroller = KineticScroller()
    private var pool: [CATextLayer] = []
    private var slotKey: [Int] = []
    private var chips: [CATextLayer] = []
    private let chipBar = CALayer()
    private let chipTitles = ["全部", "单字", "二字", "三字", "四字+"]
    private let chipH: CGFloat = 34
    private let rowH: CGFloat = 44
    private var scale: CGFloat = 3
    private var downItem: CandItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        chipBar.actions = ["frame": NSNull(), "backgroundColor": NSNull(), "position": NSNull(), "bounds": NSNull()]
        layer.addSublayer(chipBar)
        for _ in chipTitles {
            let t = CATextLayer()
            t.alignmentMode = .center
            t.actions = ["string": NSNull(), "frame": NSNull(), "position": NSNull(), "bounds": NSNull()]
            chips.append(t)
            layer.addSublayer(t)
        }
        scroller.onChange = { [weak self] in self?.updateCells() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(theme t: Theme) { theme = t; rebuild() }

    func setItems(_ items: [CandItem]) {
        all = items
        filter = 0
        scroller.offset = 0
        rebuild()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        rebuild()
    }

    private func rebuild() {
        guard bounds.width > 1 else { return }
        slotKey = [Int](repeating: -1, count: pool.count)
        backgroundColor = theme.panel
        filtered = all.filter { it in
            switch filter {
            case 0: return true
            case 1: return it.chars == 1
            case 2: return it.chars == 2
            case 3: return it.chars == 3
            default: return it.chars >= 4
            }
        }
        let font = UIFont.systemFont(ofSize: 20)
        let W = bounds.width
        widths = filtered.map { max(52, ceil(($0.text as NSString).size(withAttributes: [.font: font]).width) + 26) }
        rows.removeAll(keepingCapacity: true)
        var i = 0
        var y: CGFloat = 0
        while i < filtered.count {
            var j = i
            var sum: CGFloat = 0
            while j < filtered.count && (sum + widths[j] <= W || j == i) { sum += widths[j]; j += 1 }
            rows.append((i, j, y))
            // stretch the row so the hot areas tile the full width
            let extra = (W - sum) / CGFloat(j - i)
            if j < filtered.count && extra > 0 { for k in i..<j { widths[k] += extra } }
            y += rowH
            i = j
        }
        let contentH = y
        scroller.minOffset = 0
        scroller.maxOffset = max(0, contentH - (bounds.height - chipH))
        scroller.clampOffset()
        withoutAnimation {
            chipBar.frame = CGRect(x: 0, y: 0, width: W, height: chipH)
            chipBar.backgroundColor = theme.functionKey.withAlphaComponent(0.5).cgColor
            let cw = W / CGFloat(chipTitles.count)
            for (k, c) in chips.enumerated() {
                c.contentsScale = scale
                let sel = k == filter
                c.string = NSAttributedString(string: chipTitles[k], attributes: [.font: UIFont.systemFont(ofSize: 14, weight: sel ? .semibold : .regular), .foregroundColor: sel ? theme.accent : theme.text.withAlphaComponent(0.7)])
                c.frame = CGRect(x: CGFloat(k) * cw, y: 7, width: cw, height: 20)
            }
            updateCells()
        }
    }

    private func updateCells() {
        let off = scroller.offset
        let top = chipH
        var slot = 0
        let font = UIFont.systemFont(ofSize: 20)
        withoutAnimation {
            for r in rows {
                let ry = top + r.y - off
                if ry > bounds.height || ry + rowH < top { continue }
                var x: CGFloat = 0
                for k in r.start..<r.end {
                    while pool.count <= slot {
                        let t = CATextLayer()
                        t.alignmentMode = .center
                        t.contentsScale = scale
                        t.actions = ["string": NSNull(), "contents": NSNull(), "opacity": NSNull(), "frame": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
                        pool.append(t)
                        slotKey.append(-1)
                        layer.addSublayer(t)
                    }
                    let t = pool[slot]
                    t.contentsScale = scale
                    if slotKey[slot] != k {
                        slotKey[slot] = k
                        t.string = NSAttributedString(string: filtered[k].text, attributes: [.font: font, .foregroundColor: filtered[k].isUser ? theme.accent : theme.candidateText])
                    }
                    t.frame = CGRect(x: x, y: ry + 10, width: widths[k], height: 26)
                    t.isHidden = false
                    x += widths[k]
                    slot += 1
                }
            }
            while slot < pool.count { pool[slot].isHidden = true; slot += 1 }
        }
    }

    private func item(at p: CGPoint) -> CandItem? {
        let y = p.y - chipH + scroller.offset
        guard y >= 0 else { return nil }
        guard let r = rows.first(where: { y >= $0.y && y < $0.y + rowH }) else { return nil }
        var x: CGFloat = 0
        for k in r.start..<r.end {
            if p.x < x + widths[k] || k == r.end - 1 { return filtered[k] }
            x += widths[k]
        }
        return nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        let p = t.location(in: self)
        downItem = nil
        if p.y >= chipH { scroller.begin(p.y); downItem = item(at: p) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first, downItem != nil || scroller.dragging else { return }
        scroller.move(t.location(in: self).y)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        let p = t.location(in: self)
        if scroller.dragging { scroller.end(); return }
        if p.y < chipH {
            let k = min(chipTitles.count - 1, max(0, Int(p.x / (bounds.width / CGFloat(chipTitles.count)))))
            filter = k
            scroller.offset = 0
            rebuild()
            return
        }
        if let it = item(at: p), let d = downItem, it.text == d.text, it.index == d.index { onSelect?(it) }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { scroller.end() }
}
