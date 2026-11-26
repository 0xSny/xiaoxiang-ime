import UIKit

/// Inertial scrolling driven by raw touches (no UIScrollView, no gesture recognizers, no touch delay).
/// A drag starts only after the finger travels 8pt, so a tap below that threshold selects instantly.
final class KineticScroller: NSObject {
    static let slop: CGFloat = 8
    var offset: CGFloat = 0 { didSet { if offset != oldValue { onChange?() } } }
    var minOffset: CGFloat = 0
    var maxOffset: CGFloat = 0
    var onChange: (() -> Void)?
    private(set) var dragging = false

    private var startPos: CGFloat = 0
    private var startOffset: CGFloat = 0
    private var lastPos: CGFloat = 0
    private var lastTime: CFTimeInterval = 0
    private var velocity: CGFloat = 0
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0

    func clampOffset() { offset = max(minOffset, min(offset, maxOffset)) }

    func begin(_ pos: CGFloat) {
        stopInertia()
        dragging = false
        startPos = pos
        lastPos = pos
        startOffset = offset
        lastTime = CACurrentMediaTime()
        velocity = 0
    }

    /// Returns true once the touch has turned into a scroll.
    @discardableResult
    func move(_ pos: CGFloat) -> Bool {
        if !dragging {
            if abs(pos - startPos) > KineticScroller.slop { dragging = true } else { return false }
        }
        let now = CACurrentMediaTime()
        let dt = max(now - lastTime, 0.001)
        let v = (lastPos - pos) / CGFloat(dt)
        velocity = velocity * 0.6 + v * 0.4
        lastPos = pos
        lastTime = now
        offset = max(minOffset, min(startOffset - (pos - startPos), maxOffset))
        return true
    }

    func end() {
        guard dragging else { return }
        if CACurrentMediaTime() - lastTime > 0.08 { velocity = 0 }
        if abs(velocity) > 60 { startInertia() }
    }

    func stopInertia() {
        link?.invalidate()
        link = nil
    }

    private func startInertia() {
        stopInertia()
        lastTick = CACurrentMediaTime()
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(now - lastTick, 0.05))
        lastTick = now
        offset += velocity * dt
        velocity *= exp(-dt * 3.6)
        if offset <= minOffset { offset = minOffset; velocity = 0 }
        if offset >= maxOffset { offset = maxOffset; velocity = 0 }
        if abs(velocity) < 25 { stopInertia() }
    }

    deinit { link?.invalidate() }
}

struct CandItem {
    var text: String
    var index: Int          // index inside the engine result, -1 for synthetic items (phrases)
    var isUser: Bool
    var phrase: String?     // set for custom phrase candidates
    var syllables: Int
    var chars: Int
}

enum ToolbarItem: Int { case settings = 0, phrases, emoji, symbols }

/// Fixed-height top row. Idle: toolbar icons (+ clipboard capsule). Composing: candidate strip.
final class TopBarView: UIView {
    var onSelect: ((CandItem) -> Void)?
    var onExpand: (() -> Void)?
    var onLongPress: ((CandItem, CGRect) -> Void)?
    var onToolbar: ((ToolbarItem) -> Void)?
    var onCapsule: (() -> Void)?
    var onCapsuleClose: (() -> Void)?

    private(set) var items: [CandItem] = []
    private var xs: [CGFloat] = [0]       // cumulative boundaries; item i spans xs[i]..<xs[i+1]
    private var theme = Theme.light
    private var composing = false
    private let scroller = KineticScroller()
    private var scale: CGFloat = 3

    private var textPool: [CATextLayer] = []
    private var sepPool: [CALayer] = []
    private var iconLayers: [CALayer] = []
    private let expandIcon = CALayer()
    private let capsule = CALayer()
    private let capsuleText = CATextLayer()
    private let capsuleClose = CALayer()
    private let bottomLine = CALayer()
    private var capsuleVisible = false
    private var userHighlightIndex = -1

    private var downPoint: CGPoint = .zero
    private var downIndex = -1
    private var longTimer: DispatchWorkItem?
    private var longFired = false
    private let expandWidth: CGFloat = 42
    private let fontSize: CGFloat = 19

    private let iconNames = ["gearshape", "text.quote", "face.smiling", "ellipsis.rectangle"]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = false
        backgroundColor = .clear
        clipsToBounds = true
        for _ in 0..<4 { let l = CALayer(); l.actions = ["contents": NSNull(), "frame": NSNull(), "position": NSNull(), "bounds": NSNull()]; iconLayers.append(l); layer.addSublayer(l) }
        for l in [expandIcon, capsule, capsuleClose, bottomLine] { l.actions = ["contents": NSNull(), "frame": NSNull(), "position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull(), "hidden": NSNull()]; layer.addSublayer(l) }
        capsuleText.alignmentMode = .center
        capsuleText.actions = ["string": NSNull(), "frame": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        layer.addSublayer(capsuleText)
        capsule.cornerRadius = 14
        capsule.cornerCurve = .continuous
        scroller.onChange = { [weak self] in self?.updateVisible() }
        showToolbar()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: state

    func apply(theme t: Theme) {
        theme = t
        withoutAnimation {
            bottomLine.backgroundColor = UIColor.clear.cgColor
            capsule.backgroundColor = t.accent.withAlphaComponent(0.14).cgColor
            capsuleText.foregroundColor = t.accent.cgColor
            refreshIcons()
            updateVisible()
        }
    }

    func setCapsule(visible: Bool, title: String = "粘贴") {
        capsuleVisible = visible
        withoutAnimation {
            capsuleText.string = NSAttributedString(string: title, attributes: [.font: UIFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: theme.accent])
            layoutFixed()
        }
    }

    func showToolbar() {
        composing = false
        items = []
        scroller.stopInertia()
        scroller.offset = 0
        withoutAnimation { layoutFixed(); updateVisible() }
    }

    func setCandidates(_ list: [CandItem], resetScroll: Bool) {
        composing = true
        items = list
        scroller.stopInertia()
        xs = [0]
        xs.reserveCapacity(list.count + 1)
        let font = UIFont.systemFont(ofSize: fontSize)
        for it in list {
            let w = (it.text as NSString).size(withAttributes: [.font: font]).width
            xs.append(xs[xs.count - 1] + max(46, ceil(w) + 28))
        }
        let viewport = max(bounds.width - expandWidth, 1)
        scroller.minOffset = 0
        scroller.maxOffset = max(0, xs[xs.count - 1] - viewport)
        if resetScroll { scroller.offset = 0 } else { scroller.clampOffset() }
        withoutAnimation { layoutFixed(); updateVisible() }
    }

    // MARK: layout

    override func layoutSubviews() {
        super.layoutSubviews()
        scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        let viewport = max(bounds.width - expandWidth, 1)
        scroller.maxOffset = max(0, xs[xs.count - 1] - viewport)
        withoutAnimation { layoutFixed(); updateVisible() }
    }

    private func icon(_ name: String, pt: CGFloat, color: UIColor) -> CGImage? {
        let cfg = UIImage.SymbolConfiguration(pointSize: pt, weight: .regular)
        guard let img = UIImage(systemName: name, withConfiguration: cfg)?.withTintColor(color, renderingMode: .alwaysOriginal) else { return nil }
        let f = UIGraphicsImageRendererFormat(); f.scale = scale; f.opaque = false
        return UIGraphicsImageRenderer(size: img.size, format: f).image { _ in img.draw(at: .zero) }.cgImage
    }

    private func refreshIcons() {
        for (i, l) in iconLayers.enumerated() {
            l.contentsScale = scale
            l.contents = icon(iconNames[i], pt: 19, color: theme.toolbarIcon)
            l.contentsGravity = .center
        }
        expandIcon.contentsScale = scale
        expandIcon.contents = icon("chevron.down", pt: 16, color: theme.toolbarIcon)
        expandIcon.contentsGravity = .center
        capsuleClose.contentsScale = scale
        capsuleClose.contents = icon("xmark", pt: 9, color: theme.accent)
        capsuleClose.contentsGravity = .center
        capsuleText.contentsScale = scale
    }

    private func layoutFixed() {
        let h = bounds.height, w = bounds.width
        for (i, l) in iconLayers.enumerated() {
            l.isHidden = composing
            l.frame = CGRect(x: 6 + CGFloat(i) * 46, y: 0, width: 44, height: h)
        }
        expandIcon.isHidden = !composing
        expandIcon.frame = CGRect(x: w - expandWidth, y: 0, width: expandWidth, height: h)
        let showCap = capsuleVisible && !composing
        capsule.isHidden = !showCap
        capsuleText.isHidden = !showCap
        capsuleClose.isHidden = !showCap
        let cw: CGFloat = 86
        capsule.frame = CGRect(x: w - cw - 10, y: (h - 28) / 2, width: cw, height: 28)
        capsuleText.frame = CGRect(x: capsule.frame.minX, y: capsule.frame.minY + 4.5, width: cw - 20, height: 20)
        capsuleClose.frame = CGRect(x: capsule.frame.maxX - 24, y: capsule.frame.minY, width: 24, height: 28)
        if iconLayers.first?.contents == nil { refreshIcons() }
    }

    private func firstVisible(_ x: CGFloat) -> Int {
        var lo = 0, hi = items.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if xs[mid + 1] <= x { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private func updateVisible() {
        let viewport = max(bounds.width - expandWidth, 0)
        guard composing, !items.isEmpty else {
            for l in textPool { l.isHidden = true }
            for l in sepPool { l.isHidden = true }
            return
        }
        let off = scroller.offset
        var i = firstVisible(off)
        var slot = 0
        let h = bounds.height
        let font = UIFont.systemFont(ofSize: fontSize)
        while i < items.count && xs[i] - off < viewport {
            while textPool.count <= slot {
                let t = CATextLayer()
                t.alignmentMode = .center
                t.contentsScale = scale
                t.actions = ["string": NSNull(), "frame": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
                textPool.append(t)
                layer.addSublayer(t)
                let s = CALayer()
                s.actions = ["frame": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull(), "backgroundColor": NSNull()]
                sepPool.append(s)
                layer.addSublayer(s)
            }
            let it = items[i]
            let t = textPool[slot]
            let first = (i == 0)
            let color = first ? theme.accent : (it.isUser ? theme.candidateText : theme.candidateText)
            t.string = NSAttributedString(string: it.text, attributes: [.font: first ? UIFont.systemFont(ofSize: fontSize, weight: .medium) : font, .foregroundColor: color])
            t.frame = CGRect(x: xs[i] - off, y: (h - 24) / 2, width: xs[i + 1] - xs[i], height: 24)
            t.isHidden = false
            let s = sepPool[slot]
            s.backgroundColor = theme.separator.cgColor
            s.frame = CGRect(x: xs[i + 1] - off - 0.5, y: h * 0.28, width: 1 / scale, height: h * 0.44)
            s.isHidden = false
            slot += 1
            i += 1
        }
        while slot < textPool.count { textPool[slot].isHidden = true; sepPool[slot].isHidden = true; slot += 1 }
    }

    // MARK: touches (hot areas tile the whole bar; separators are purely visual)

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        let p = t.location(in: self)
        downPoint = p
        longFired = false
        downIndex = -1
        longTimer?.cancel()
        if composing {
            if p.x >= bounds.width - expandWidth { return }
            scroller.begin(p.x)
            let idx = firstVisible(p.x + scroller.offset)
            if idx < items.count {
                downIndex = idx
                if items[idx].isUser && items[idx].index >= 0 {
                    let work = DispatchWorkItem { [weak self] in
                        guard let self = self, !self.scroller.dragging, self.downIndex == idx else { return }
                        self.longFired = true
                        let r = CGRect(x: self.xs[idx] - self.scroller.offset, y: 0, width: self.xs[idx + 1] - self.xs[idx], height: self.bounds.height)
                        self.onLongPress?(self.items[idx], r)
                    }
                    longTimer = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
                }
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard composing, let t = touches.first, downIndex >= 0 || scroller.dragging else { return }
        if scroller.move(t.location(in: self).x) { longTimer?.cancel() }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        longTimer?.cancel()
        guard let t = touches.first else { return }
        let p = t.location(in: self)
        if composing {
            if p.x >= bounds.width - expandWidth && downPoint.x >= bounds.width - expandWidth {
                onExpand?()
                return
            }
            if scroller.dragging { scroller.end(); return }
            if longFired { return }
            let idx = firstVisible(p.x + scroller.offset)
            if idx < items.count { onSelect?(items[idx]) }
            return
        }
        // toolbar mode
        let w = bounds.width
        if capsuleVisible {
            if capsule.frame.contains(p) {
                if p.x > capsule.frame.maxX - 26 { onCapsuleClose?() } else { onCapsule?() }
                return
            }
        }
        _ = w
        let idx = Int((p.x - 6) / 46)
        if idx >= 0 && idx < 4 && p.x < 6 + 4 * 46, let item = ToolbarItem(rawValue: idx) { onToolbar?(item) }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        longTimer?.cancel()
        scroller.end()
    }
}
