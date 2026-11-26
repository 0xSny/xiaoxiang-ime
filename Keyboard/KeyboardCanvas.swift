import UIKit

// MARK: - Model

enum KeyAction: Equatable {
    case letter(UInt8)       // ascii 'a'...'z'
    case shift
    case backspace
    case space
    case returnKey
    case numbers             // switch to the number pad
    case letters             // back to the letter layout
    case symbols             // open the symbol panel
    case cnEn                // toggle Chinese / English
    case globe
    case insert(String)      // insert text directly
    case oneHandToggle
}

enum CanvasLayout { case letters, numbers }

enum ShiftState { case off, on, locked }

protocol KeyboardCanvasDelegate: AnyObject {
    func canvasKeyDown(_ action: KeyAction)
    func canvasLetter(_ ch: UInt8, stroke: IMEKeyStroke, uppercase: Bool)
    func canvasInsert(_ text: String)
    func canvasSpace()
    func canvasReturn()
    func canvasShift()
    func canvasBackspaceStep(repeatCount: Int)
    func canvasBackspaceSwipeClear()
    func canvasBackspaceEnd()
    func canvasCursorMove(by offset: Int)
    func canvasAction(_ action: KeyAction)
    func canvasGlobeDown(_ view: UIView, event: UIEvent?)
    func canvasLetterPrior(_ out: UnsafeMutablePointer<Float>) -> Bool
    func canvasCurrentScheme() -> Int
}

final class KeyDef {
    var action: KeyAction
    var title: String = ""
    var icon: String? = nil
    var swipe: String? = nil
    var isFunction = false
    var isAccent = false
    var frame: CGRect = .zero
    var center: CGPoint = .zero
    var letter: UInt8 = 0

    let shadow = CALayer()
    let face = CALayer()
    let shine = CALayer()
    let main = CATextLayer()
    let hint = CATextLayer()
    let corner = CATextLayer()
    let iconLayer = CALayer()

    init(_ a: KeyAction) {
        action = a
        if case .letter(let c) = a { letter = c }
    }
}

private struct Track {
    enum State { case pending, swipeUp, spaceDrag, backspaceHold, backspaceSwiped, done }
    var active = false
    var id: ObjectIdentifier? = nil
    var key: Int = -1
    var start: CGPoint = .zero
    var last: CGPoint = .zero
    var state: State = .pending
    var committed = false
    var downTime: CFTimeInterval = 0
    var stroke = IMEKeyStroke(n: 0, c: (0, 0, 0), p: (0, 0, 0))
    var cursorSteps = 0
    var lastTapPoint: CGPoint = .zero
}

// MARK: - Xiaohe mnemonic tables

enum XiaoheHints {
    static let initials: [UInt8: String] = [UInt8(ascii: "u"): "sh", UInt8(ascii: "i"): "ch", UInt8(ascii: "v"): "zh"]
    static let finals: [UInt8: [String]] = {
        let t: [Character: [String]] = [
            "a": ["a"], "b": ["in"], "c": ["ao"], "d": ["ai"], "e": ["e"], "f": ["en"], "g": ["eng"], "h": ["ang"],
            "i": ["i"], "j": ["an"], "k": ["ing", "uai"], "l": ["iang", "uang"], "m": ["ian"], "n": ["iao"],
            "o": ["o", "uo"], "p": ["ie"], "q": ["iu"], "r": ["uan"], "s": ["ong", "iong"], "t": ["ue", "ve"],
            "u": ["u"], "v": ["ui", "ü"], "w": ["ei"], "x": ["ia", "ua"], "y": ["un"], "z": ["ou"]]
        var out: [UInt8: [String]] = [:]
        for (k, v) in t { out[k.asciiValue!] = v }
        return out
    }()
}

// MARK: - Canvas

/// The whole key area is ONE view: raw multi-touch handling with a single deterministic state machine.
/// No gesture recognizers, no AutoLayout: every frame is computed with plain rectangle math.
final class KeyboardCanvas: UIView {
    weak var delegate: KeyboardCanvasDelegate?
    weak var bubbleHost: UIView?

    private(set) var keys: [KeyDef] = []
    private var letterIndex = [Int](repeating: -1, count: 26)
    private var tracks = [Track](repeating: Track(), count: 6)
    private var theme = Theme.light
    private var layoutKind: CanvasLayout = .letters
    private var scheme = 0
    private var hintStyle = 0
    private var swipeEnabled = true
    private var oneHand = 0
    private var showGlobe = true
    private var englishMode = false
    private var shiftState: ShiftState = .off
    private var returnTitle = "换行"
    private var returnAccent = false
    private var backspaceSwipeEnabled = true
    private var cursorSensitivity: CGFloat = 1.0
    private var bubbleEnabled = true
    private var spatialEnabled = true
    private var scale: CGFloat = 3

    private var pressTimes = [CFTimeInterval](repeating: 0, count: 64)
    private var highlighted = [Bool](repeating: false, count: 64)
    private var releaseItems = [DispatchWorkItem?](repeating: nil, count: 64)
    private var spaceLock = false

    // backspace repeat
    private var repeatTimer: DispatchSourceTimer?
    private var repeatActive = false
    private var repeatStart: CFTimeInterval = 0
    private var repeatCount = 0

    // bubble
    private let bubbleLayer = CAShapeLayer()
    private let bubbleText = CATextLayer()
    private var bubbleKey = -1

    private var priorBuf = [Float](repeating: 1, count: 26)
    private var needsRelayout = true
    private var lastSize: CGSize = .zero
    private var iconCache: [String: CGImage] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
        backgroundColor = .clear
        clipsToBounds = false
        layer.actions = ["sublayers": NSNull(), "bounds": NSNull(), "position": NSNull()]
        bubbleLayer.isHidden = true
        bubbleLayer.shadowOpacity = 0.28
        bubbleLayer.shadowRadius = 3
        bubbleLayer.shadowOffset = CGSize(width: 0, height: 1)
        bubbleLayer.shadowColor = UIColor.black.cgColor
        bubbleText.alignmentMode = .center
        bubbleText.isHidden = true
        bubbleText.isWrapped = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: configuration

    func configure(layout: CanvasLayout, scheme: Int, hintStyle: Int, swipeUp: Bool, oneHand: Int, showGlobe: Bool,
                   english: Bool, bubble: Bool, spatial: Bool, backspaceSwipe: Bool, cursorSensitivity: Double) {
        let structural = layout != layoutKind || oneHand != self.oneHand || showGlobe != self.showGlobe || keys.isEmpty
        let labels = scheme != self.scheme || hintStyle != self.hintStyle || swipeUp != swipeEnabled || english != englishMode
        layoutKind = layout
        self.scheme = scheme
        self.hintStyle = hintStyle
        swipeEnabled = swipeUp
        self.oneHand = oneHand
        self.showGlobe = showGlobe
        englishMode = english
        bubbleEnabled = bubble
        spatialEnabled = spatial
        backspaceSwipeEnabled = backspaceSwipe
        self.cursorSensitivity = CGFloat(max(0.4, min(cursorSensitivity, 2.5)))
        if structural { rebuildKeys() }
        else if labels { refreshLabels() }
    }

    func setReturnKey(title: String, accent: Bool) {
        returnTitle = title
        returnAccent = accent
        if let k = keys.first(where: { $0.action == .returnKey }) {
            k.title = title
            k.isAccent = accent
            withoutAnimation { styleKey(k); layoutKeyLayers(k) }
        }
    }

    func setShift(_ s: ShiftState) {
        shiftState = s
        withoutAnimation {
            for k in keys {
                if case .letter = k.action { styleKey(k); layoutKeyLayers(k) }
                if k.action == .shift { styleKey(k); layoutKeyLayers(k) }
            }
        }
    }

    func apply(theme t: Theme) {
        theme = t
        withoutAnimation {
            for k in keys { styleKey(k); layoutKeyLayers(k) }
            bubbleLayer.fillColor = t.bubble.cgColor
            bubbleText.foregroundColor = t.bubbleText.cgColor
        }
    }

    func setEnglishMode(_ e: Bool) {
        englishMode = e
        refreshLabels()
    }

    // MARK: building keys

    private func rebuildKeys() {
        for k in keys {
            k.shadow.removeFromSuperlayer(); k.face.removeFromSuperlayer(); k.shine.removeFromSuperlayer()
            k.main.removeFromSuperlayer(); k.hint.removeFromSuperlayer(); k.corner.removeFromSuperlayer()
            k.iconLayer.removeFromSuperlayer()
        }
        keys.removeAll(keepingCapacity: true)
        for i in 0..<26 { letterIndex[i] = -1 }
        cancelAllTracks()

        func add(_ a: KeyAction, title: String = "", icon: String? = nil, function: Bool = false) {
            let k = KeyDef(a)
            k.title = title
            k.icon = icon
            k.isFunction = function
            if case .letter(let c) = a { letterIndex[Int(c) - 97] = keys.count }
            keys.append(k)
        }

        if layoutKind == .letters {
            for c in "qwertyuiop".utf8 { add(.letter(c)) }
            for c in "asdfghjkl".utf8 { add(.letter(c)) }
            add(.shift, icon: "shift", function: true)
            for c in "zxcvbnm".utf8 { add(.letter(c)) }
            add(.backspace, icon: "delete.left", function: true)
            add(.numbers, title: "123", function: true)
            if showGlobe { add(.globe, icon: "globe", function: true) }
            add(.cnEn, title: englishMode ? "英" : "中", function: true)
            add(.space, title: "空格")
            add(.returnKey, title: returnTitle, function: true)
        } else {
            let grid: [[String]] = [["+", "1", "2", "3", "⌫"], ["-", "4", "5", "6", "¥"], ["×", "7", "8", "9", "$"],
                                    ["÷", ",", "0", ".", "%"]]
            for row in grid {
                for s in row {
                    if s == "⌫" { add(.backspace, icon: "delete.left", function: true) }
                    else if "+-×÷¥$%".contains(s) { add(.insert(s), title: s, function: true) }
                    else { add(.insert(s), title: s) }
                }
            }
            add(.letters, title: "ABC", function: true)
            add(.insert(":"), title: ":", function: true)
            add(.space, title: "空格")
            add(.returnKey, title: returnTitle, function: true)
        }
        if oneHand != 0 { add(.oneHandToggle, icon: "arrow.left.arrow.right", function: true) }

        for k in keys {
            k.shadow.actions = ["backgroundColor": NSNull(), "frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
            k.face.actions = ["backgroundColor": NSNull(), "frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
            for t in [k.main, k.hint, k.corner] {
                t.alignmentMode = .center
                t.isWrapped = false
                t.truncationMode = .none
                t.actions = ["string": NSNull(), "frame": NSNull(), "bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
            }
            k.iconLayer.actions = ["contents": NSNull(), "frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
            k.iconLayer.contentsGravity = .resizeAspect
            layer.addSublayer(k.shadow)
            layer.addSublayer(k.face)
            layer.addSublayer(k.shine)
            layer.addSublayer(k.iconLayer)
            layer.addSublayer(k.main)
            layer.addSublayer(k.hint)
            layer.addSublayer(k.corner)
        }
        // bubble goes to the host (above toolbar), otherwise onto the canvas
        bubbleLayer.removeFromSuperlayer()
        bubbleText.removeFromSuperlayer()
        needsRelayout = true
        setNeedsLayout()
        layoutIfNeeded()
        withoutAnimation { for k in keys { styleKey(k); layoutKeyLayers(k) } }
    }

    private func refreshLabels() {
        if layoutKind == .letters, let k = keys.first(where: { $0.action == .cnEn }) { k.title = englishMode ? "英" : "中" }
        withoutAnimation { for k in keys { styleKey(k); layoutKeyLayers(k) } }
    }

    // MARK: geometry (pure rectangle math, snapped to physical pixels)

    override func layoutSubviews() {
        super.layoutSubviews()
        scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        if !needsRelayout && bounds.size == lastSize { return }
        needsRelayout = false
        lastSize = bounds.size
        computeFrames()
        withoutAnimation { for k in keys { styleKey(k); layoutKeyLayers(k) } }
    }

    private func computeFrames() {
        let W = bounds.width, H = bounds.height
        guard W > 10, H > 10, !keys.isEmpty else { return }
        var usableX: CGFloat = 0
        var usableW = W
        if oneHand != 0 {
            usableW = (W * 0.84).rounded()
            usableX = oneHand == 1 ? 0 : W - usableW
        }
        let side: CGFloat = 3
        let gap: CGFloat = 6
        let topPad: CGFloat = 5
        let botPad: CGFloat = 4
        let ax = usableX + side
        let aw = usableW - 2 * side

        if layoutKind == .letters {
            let rows = 4
            let rowGap: CGFloat = max(9, min(12, H * 0.05))
            let kh = (H - topPad - botPad - CGFloat(rows - 1) * rowGap) / CGFloat(rows)
            let kw = (aw - 9 * gap) / 10
            func rowY(_ r: Int) -> CGFloat { topPad + CGFloat(r) * (kh + rowGap) }
            var idx = 0
            for i in 0..<10 {
                keys[idx].frame = CGRect(x: ax + CGFloat(i) * (kw + gap), y: rowY(0), width: kw, height: kh); idx += 1
            }
            let r2x = ax + (kw + gap) * 0.5
            for i in 0..<9 {
                keys[idx].frame = CGRect(x: r2x + CGFloat(i) * (kw + gap), y: rowY(1), width: kw, height: kh); idx += 1
            }
            let sw = (3 * kw + gap) / 2
            keys[idx].frame = CGRect(x: ax, y: rowY(2), width: sw, height: kh); idx += 1
            for i in 0..<7 {
                keys[idx].frame = CGRect(x: ax + sw + gap + CGFloat(i) * (kw + gap), y: rowY(2), width: kw, height: kh); idx += 1
            }
            keys[idx].frame = CGRect(x: ax + aw - sw, y: rowY(2), width: sw, height: kh); idx += 1
            // bottom row weights
            var weights: [CGFloat] = [1.3]
            if showGlobe { weights.append(1.0) }
            weights.append(1.0)
            let spaceW: CGFloat = 10 - weights.reduce(0, +) - 2.0
            weights.append(spaceW)
            weights.append(2.0)
            let n = CGFloat(weights.count)
            let unit = (aw - (n - 1) * gap) / weights.reduce(0, +)
            var x = ax
            for w in weights {
                keys[idx].frame = CGRect(x: x, y: rowY(3), width: w * unit, height: kh)
                x += w * unit + gap
                idx += 1
            }
        } else {
            let rows = 5
            let rowGap: CGFloat = 7
            let kh = (H - topPad - botPad - CGFloat(rows - 1) * rowGap) / CGFloat(rows)
            let kw = (aw - 4 * gap) / 5
            func rowY(_ r: Int) -> CGFloat { topPad + CGFloat(r) * (kh + rowGap) }
            var idx = 0
            for r in 0..<4 {
                for c in 0..<5 {
                    keys[idx].frame = CGRect(x: ax + CGFloat(c) * (kw + gap), y: rowY(r), width: kw, height: kh); idx += 1
                }
            }
            // ABC, ':', space (2 cols), return
            keys[idx].frame = CGRect(x: ax, y: rowY(4), width: kw, height: kh); idx += 1
            keys[idx].frame = CGRect(x: ax + (kw + gap), y: rowY(4), width: kw, height: kh); idx += 1
            keys[idx].frame = CGRect(x: ax + 2 * (kw + gap), y: rowY(4), width: 2 * kw + gap, height: kh); idx += 1
            keys[idx].frame = CGRect(x: ax + 4 * (kw + gap), y: rowY(4), width: kw, height: kh); idx += 1
        }
        if oneHand != 0, let tk = keys.last, tk.action == .oneHandToggle {
            let stripW = W - usableW
            let x = oneHand == 1 ? usableW + 4 : 4
            tk.frame = CGRect(x: x, y: topPad, width: max(stripW - 8, 20), height: H - topPad - botPad)
        }
        for k in keys {
            k.frame = pixelRect(k.frame, scale)
            k.center = CGPoint(x: k.frame.midX, y: k.frame.midY)
        }
    }

    // MARK: styling

    private func letterDisplay(_ k: KeyDef) -> String {
        let s = String(UnicodeScalar(k.letter))
        let upper = shiftState != .off
        return upper ? s.uppercased() : s
    }

    private func fitFont(_ s: String, size: CGFloat, weight: UIFont.Weight, maxWidth: CGFloat, minSize: CGFloat = 6) -> UIFont {
        var f = UIFont.systemFont(ofSize: size, weight: weight)
        let w = (s as NSString).size(withAttributes: [.font: f]).width
        if w > maxWidth && w > 0 {
            f = UIFont.systemFont(ofSize: max(minSize, size * maxWidth / w), weight: weight)
        }
        return f
    }

    private func iconImage(_ name: String, color: UIColor, pt: CGFloat) -> CGImage? {
        let key = "\(name)|\(color.hash)|\(Int(pt))|\(scale)"
        if let c = iconCache[key] { return c }
        let cfg = UIImage.SymbolConfiguration(pointSize: pt, weight: .regular)
        guard let img = UIImage(systemName: name, withConfiguration: cfg)?.withTintColor(color, renderingMode: .alwaysOriginal) else { return nil }
        let r = UIGraphicsImageRenderer(size: img.size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = scale; f.opaque = false; return f }())
        let out = r.image { _ in img.draw(at: .zero) }
        iconCache[key] = out.cgImage
        return out.cgImage
    }

    private func styleKey(_ k: KeyDef) {
        let t = theme
        let isLetterKey = !k.isFunction
        let accent = k.isAccent
        k.shadow.backgroundColor = t.keyShadow.cgColor
        k.face.backgroundColor = (accent ? t.accent : (isLetterKey ? t.letterKey : t.functionKey)).cgColor
        k.face.borderColor = t.keyBorder.cgColor
        k.face.borderWidth = t.keyBorder.cgColor.alpha > 0 ? 0.5 : 0
        k.shine.backgroundColor = t.keyHighlight.cgColor
        for l in [k.shadow, k.face] { l.cornerRadius = 5.5; l.cornerCurve = .continuous }
        k.shine.cornerRadius = 0.5
        let textColor = accent ? t.accentText : t.text
        for l in [k.main, k.hint, k.corner] { l.contentsScale = scale }
        k.iconLayer.contentsScale = scale

        // reset
        k.main.string = nil; k.hint.string = nil; k.corner.string = nil
        k.iconLayer.contents = nil
        k.main.isHidden = false; k.hint.isHidden = true; k.corner.isHidden = true; k.iconLayer.isHidden = true

        let w = max(k.frame.width, 1)
        switch k.action {
        case .letter:
            let disp = letterDisplay(k)
            let xiaohe = scheme == 1 && !englishMode && hintStyle != 2
            var mainSize: CGFloat = 22
            if xiaohe { mainSize = hintStyle == 0 ? 19 : 20 }
            let initial = (xiaohe && hintStyle == 0) ? XiaoheHints.initials[k.letter] : nil
            let attr = NSMutableAttributedString(string: disp, attributes: [.font: UIFont.systemFont(ofSize: mainSize, weight: .regular), .foregroundColor: textColor])
            if let ini = initial {
                attr.append(NSAttributedString(string: " " + ini, attributes: [.font: UIFont.systemFont(ofSize: 9.5, weight: .medium), .foregroundColor: t.accent]))
            }
            k.main.string = attr
            // finals mnemonic
            if xiaohe, let finals = XiaoheHints.finals[k.letter] {
                k.hint.isHidden = false
                let color = t.text.withAlphaComponent(0.6)
                if hintStyle == 0 && finals.count == 2 {
                    let s = finals[0] + "\n" + finals[1]
                    let f = fitFont(finals.max(by: { $0.count < $1.count })!, size: 8, weight: .regular, maxWidth: w - 6, minSize: 6)
                    let ps = NSMutableParagraphStyle(); ps.alignment = .center; ps.lineSpacing = -1.5; ps.maximumLineHeight = f.pointSize + 1
                    k.hint.string = NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: color, .paragraphStyle: ps])
                } else {
                    let s = finals.joined(separator: "/")
                    let f = fitFont(s, size: hintStyle == 0 ? 9 : 8.5, weight: .regular, maxWidth: w - 6, minSize: 6)
                    let ps = NSMutableParagraphStyle(); ps.alignment = .center
                    k.hint.string = NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: color, .paragraphStyle: ps])
                }
            }
            // corner hint (digit / punctuation)
            if swipeEnabled, let sw = swipeText(for: k) {
                let digitOnly = xiaohe && hintStyle == 0
                let isDigit = sw.unicodeScalars.first.map { $0.value >= 48 && $0.value <= 57 } ?? false
                if !digitOnly || isDigit {
                    k.corner.isHidden = false
                    k.corner.string = NSAttributedString(string: sw, attributes: [.font: UIFont.systemFont(ofSize: 9, weight: .regular), .foregroundColor: t.text.withAlphaComponent(digitOnly ? 0.32 : 0.42)])
                }
            }
        case .space:
            k.main.string = NSAttributedString(string: k.title, attributes: [.font: UIFont.systemFont(ofSize: 15, weight: .regular), .foregroundColor: t.text.withAlphaComponent(0.75)])
        case .returnKey:
            k.main.string = NSAttributedString(string: k.title, attributes: [.font: UIFont.systemFont(ofSize: 16, weight: .medium), .foregroundColor: textColor])
        case .cnEn:
            k.main.string = NSAttributedString(string: k.title, attributes: [.font: UIFont.systemFont(ofSize: 17, weight: .medium), .foregroundColor: textColor])
        case .insert:
            k.main.string = NSAttributedString(string: k.title, attributes: [.font: UIFont.systemFont(ofSize: k.isFunction ? 20 : 24, weight: .regular), .foregroundColor: textColor])
        default:
            if let icon = k.icon {
                var name = icon
                if k.action == .shift { name = shiftState == .off ? "shift" : (shiftState == .on ? "shift.fill" : "capslock.fill") }
                k.main.isHidden = true
                k.iconLayer.isHidden = false
                k.iconLayer.contents = iconImage(name, color: textColor, pt: 17)
            } else {
                k.main.string = NSAttributedString(string: k.title, attributes: [.font: UIFont.systemFont(ofSize: 16, weight: .regular), .foregroundColor: textColor])
            }
        }
    }

    private func swipeText(for k: KeyDef) -> String? {
        guard case .letter = k.action else { return nil }
        let ch = Character(UnicodeScalar(k.letter))
        let digits: [Character: String] = ["q": "1", "w": "2", "e": "3", "r": "4", "t": "5", "y": "6", "u": "7", "i": "8", "o": "9", "p": "0"]
        if let d = digits[ch] { return d }
        let common: [Character: String] = ["a": "@", "s": "#", "d": "$", "f": "%", "g": "&", "h": "*", "j": "-", "k": "+", "l": "="]
        if let s = common[ch] { return s }
        let cn: [Character: String] = ["z": "，", "x": "。", "c": "？", "v": "！", "b": "、", "n": "：", "m": "；"]
        let en: [Character: String] = ["z": ",", "x": ".", "c": "?", "v": "!", "b": "'", "n": ":", "m": ";"]
        return (englishMode ? en : cn)[ch]
    }

    private func layoutKeyLayers(_ k: KeyDef) {
        let f = k.frame
        let px = 1 / scale
        k.shadow.frame = CGRect(x: f.minX, y: f.minY + 1, width: f.width, height: f.height)
        k.face.frame = f
        k.shine.frame = CGRect(x: f.minX + 3, y: f.minY + px, width: max(f.width - 6, 1), height: px)
        k.shine.isHidden = theme.isDark && false
        k.iconLayer.frame = CGRect(x: f.midX - 12, y: f.midY - 12, width: 24, height: 24)
        switch k.action {
        case .letter:
            let xiaohe = scheme == 1 && !englishMode && hintStyle != 2
            if xiaohe {
                let two = hintStyle == 0 && (XiaoheHints.finals[k.letter]?.count ?? 0) == 2
                let mainH: CGFloat = 22
                let mainTop = f.minY + (hintStyle == 0 ? 3 : 4)
                k.main.frame = CGRect(x: f.minX, y: mainTop, width: f.width, height: mainH)
                let hintH: CGFloat = two ? 19 : 11
                k.hint.frame = CGRect(x: f.minX + 1.5, y: f.maxY - hintH - (two ? 3 : 4), width: f.width - 3, height: hintH)
            } else {
                k.main.frame = CGRect(x: f.minX, y: f.midY - 14, width: f.width, height: 28)
            }
            k.corner.frame = CGRect(x: f.maxX - 14, y: f.minY + 2, width: 12, height: 12)
            k.corner.alignmentMode = .right
        case .space, .returnKey, .cnEn, .insert:
            let h: CGFloat = 28
            k.main.frame = CGRect(x: f.minX, y: f.midY - h / 2 + 1, width: f.width, height: h)
        default:
            k.main.frame = CGRect(x: f.minX, y: f.midY - 11, width: f.width, height: 22)
        }
    }

    // MARK: hit testing

    private func nearestKey(_ p: CGPoint) -> Int {
        var best = -1
        var bestD = CGFloat.greatestFiniteMagnitude
        var bestC = CGFloat.greatestFiniteMagnitude
        for (i, k) in keys.enumerated() {
            let f = k.frame
            let dx = max(f.minX - p.x, 0, p.x - f.maxX)
            let dy = max(f.minY - p.y, 0, p.y - f.maxY)
            let d = dx * dx + dy * dy
            let cx = k.center.x - p.x, cy = k.center.y - p.y
            let c = cx * cx + cy * cy
            if d < bestD || (d == bestD && c < bestC) { best = i; bestD = d; bestC = c }
        }
        return best
    }

    /// Gaussian spatial model over the letter keys: returns the most probable letter key and the top-3 probabilities.
    private func resolveLetter(at p: CGPoint, nearest: Int, stroke: inout IMEKeyStroke) -> Int {
        let kRef = keys[nearest]
        let kw = max(kRef.frame.width, 20), kh = max(kRef.frame.height, 20)
        let xiaohe = scheme == 1 && !englishMode
        let sx: CGFloat = (xiaohe ? 0.30 : 0.38)
        let sy: CGFloat = (xiaohe ? 0.34 : 0.42)
        var havePrior = false
        if spatialEnabled && !englishMode, let d = delegate {
            havePrior = priorBuf.withUnsafeMutableBufferPointer { d.canvasLetterPrior($0.baseAddress!) }
        }
        let priorWeight: Float = xiaohe ? 0.5 : 0.85
        var bestIdx = nearest, bestV = -Float.greatestFiniteMagnitude
        var top: (Int, Float) = (-1, -1e9), second: (Int, Float) = (-1, -1e9), third: (Int, Float) = (-1, -1e9)
        for li in 0..<26 {
            let ki = letterIndex[li]
            if ki < 0 { continue }
            let k = keys[ki]
            let dx = (p.x - k.center.x) / kw, dy = (p.y - k.center.y) / kh
            if abs(dx) > 2.2 || abs(dy) > 1.6 { continue }
            var v = Float(-(dx * dx) / (2 * sx * sx) - (dy * dy) / (2 * sy * sy))
            if havePrior { v += priorWeight * log(max(priorBuf[li], 0.05)) }
            if v > bestV { bestV = v; bestIdx = ki }
            if v > top.1 { third = second; second = top; top = (ki, v) }
            else if v > second.1 { third = second; second = (ki, v) }
            else if v > third.1 { third = (ki, v) }
        }
        // probabilities relative to the best candidate
        var n: UInt8 = 0
        var cs: [UInt8] = [0, 0, 0]
        var ps: [Float] = [0, 0, 0]
        var sum: Float = 0
        for (i, c) in [top, second, third].enumerated() where c.0 >= 0 && c.1 > top.1 - 6 {
            cs[i] = keys[c.0].letter
            ps[i] = exp(c.1 - top.1)
            sum += ps[i]
            n += 1
        }
        if n == 0 { cs[0] = kRef.letter; ps[0] = 1; sum = 1; n = 1 }
        stroke = IMEKeyStroke(n: n, c: (CChar(cs[0]), CChar(cs[1]), CChar(cs[2])), p: (ps[0] / sum, ps[1] / sum, ps[2] / sum))
        return bestIdx
    }

    // MARK: touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { began(t, event) }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { moved(t) }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { ended(t, cancelled: false) }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { ended(t, cancelled: true) }
    }

    private func trackIndex(_ t: UITouch) -> Int {
        let id = ObjectIdentifier(t)
        for i in 0..<tracks.count where tracks[i].active && tracks[i].id == id { return i }
        return -1
    }

    private func began(_ t: UITouch, _ event: UIEvent?) {
        if spaceLock { return }
        let p = t.location(in: self)
        var nearest = nearestKey(p)
        if nearest < 0 { return }
        guard let slot = tracks.indices.first(where: { !tracks[$0].active }) else { return }

        // Rollover: settle every still-pending tap before the new key takes focus.
        for i in 0..<tracks.count where tracks[i].active && tracks[i].state == .pending && !tracks[i].committed {
            commitTap(i)
            tracks[i].committed = true
            unhighlight(tracks[i].key, immediate: true)
            hideBubble()
        }

        var stroke = IMEKeyStroke(n: 0, c: (0, 0, 0), p: (0, 0, 0))
        if case .letter = keys[nearest].action {
            nearest = resolveLetter(at: p, nearest: nearest, stroke: &stroke)
        }
        var tr = Track()
        tr.active = true
        tr.id = ObjectIdentifier(t)
        tr.key = nearest
        tr.start = p
        tr.last = p
        tr.downTime = CACurrentMediaTime()
        tr.stroke = stroke
        tracks[slot] = tr

        let key = keys[nearest]
        withoutAnimation {
            highlight(nearest)
            if case .letter = key.action, bubbleEnabled { showBubble(nearest, text: letterDisplay(key)) }
        }
        delegate?.canvasKeyDown(key.action)   // haptic + click in the same call stack, same frame

        switch key.action {
        case .backspace:
            tracks[slot].state = .backspaceHold
            delegate?.canvasBackspaceStep(repeatCount: 0)
            startRepeat()
        case .globe:
            tracks[slot].state = .done
            delegate?.canvasGlobeDown(self, event: event)
        default:
            break
        }
    }

    private func moved(_ t: UITouch) {
        let i = trackIndex(t)
        if i < 0 { return }
        let p = t.location(in: self)
        tracks[i].last = p
        let key = keys[tracks[i].key]
        let dx = p.x - tracks[i].start.x
        let dy = p.y - tracks[i].start.y
        switch tracks[i].state {
        case .pending:
            switch key.action {
            case .letter:
                if swipeEnabled, let sw = swipeText(for: key), -dy > 18, -dy > abs(dx) {
                    tracks[i].state = .swipeUp
                    if bubbleEnabled { withoutAnimation { showBubble(tracks[i].key, text: sw) } }
                    return
                }
                // follow the finger to the key under it (commit happens on lift)
                var nearest = nearestKey(p)
                if nearest >= 0, case .letter = keys[nearest].action {
                    var stroke = tracks[i].stroke
                    nearest = resolveLetter(at: p, nearest: nearest, stroke: &stroke)
                    if nearest != tracks[i].key {
                        withoutAnimation {
                            unhighlight(tracks[i].key, immediate: true)
                            tracks[i].key = nearest
                            highlight(nearest)
                            if bubbleEnabled { showBubble(nearest, text: letterDisplay(keys[nearest])) }
                        }
                    }
                    tracks[i].stroke = stroke
                }
            case .space:
                if abs(dx) > 14 {
                    tracks[i].state = .spaceDrag
                    spaceLock = true
                    tracks[i].cursorSteps = 0
                }
            default:
                break
            }
        case .swipeUp:
            if -dy < 8, case .letter = key.action {
                tracks[i].state = .pending
                withoutAnimation { if bubbleEnabled { showBubble(tracks[i].key, text: letterDisplay(key)) } }
            }
        case .spaceDrag:
            let step: CGFloat = 11 / cursorSensitivity
            let target = Int((dx / step).rounded(.towardZero))
            if target != tracks[i].cursorSteps {
                let delta = target - tracks[i].cursorSteps
                tracks[i].cursorSteps = target
                delegate?.canvasCursorMove(by: delta)
            }
        case .backspaceHold:
            if backspaceSwipeEnabled && dx < -38 && abs(dx) > abs(dy) {
                tracks[i].state = .backspaceSwiped
                stopRepeat()
                delegate?.canvasBackspaceSwipeClear()
            }
        default:
            break
        }
    }

    private func ended(_ t: UITouch, cancelled: Bool) {
        let i = trackIndex(t)
        if i < 0 { return }
        let tr = tracks[i]
        let key = tr.key
        if !cancelled && !tr.committed {
            switch tr.state {
            case .pending:
                commitTap(i)
            case .swipeUp:
                if let sw = swipeText(for: keys[key]) { delegate?.canvasInsert(sw) }
            default:
                break
            }
        }
        if tr.state == .backspaceHold || tr.state == .backspaceSwiped { stopRepeat(); delegate?.canvasBackspaceEnd() }
        if tr.state == .spaceDrag { spaceLock = false }
        tracks[i] = Track()
        let stillHeld = tracks.contains { $0.active && $0.key == key }
        if !stillHeld { unhighlight(key, immediate: tr.committed) }
        if bubbleKey == key || tr.state == .swipeUp {
            if !tracks.contains(where: { $0.active && $0.key == bubbleKey }) { hideBubbleAfterMinimum(key) }
        }
    }

    private func commitTap(_ i: Int) {
        let tr = tracks[i]
        let key = keys[tr.key]
        switch key.action {
        case .letter(let c):
            delegate?.canvasLetter(c, stroke: tr.stroke, uppercase: shiftState != .off)
        case .space: delegate?.canvasSpace()
        case .returnKey: delegate?.canvasReturn()
        case .shift: delegate?.canvasShift()
        case .insert(let s): delegate?.canvasInsert(s)
        case .numbers, .letters, .symbols, .cnEn, .oneHandToggle: delegate?.canvasAction(key.action)
        default: break
        }
    }

    func cancelAllTracks() {
        stopRepeat()
        spaceLock = false
        for i in 0..<tracks.count { tracks[i] = Track() }
        for i in 0..<keys.count { unhighlight(i, immediate: true) }
        hideBubble()
    }

    // MARK: highlight & bubble (visual feedback with a 35 ms minimum flash)

    private func highlight(_ ki: Int) {
        guard ki >= 0, ki < keys.count, ki < 64 else { return }
        releaseItems[ki]?.cancel()
        releaseItems[ki] = nil
        let k = keys[ki]
        k.face.backgroundColor = (k.isAccent ? theme.accentPressed : (k.isFunction ? theme.functionPressed : theme.keyPressed)).cgColor
        highlighted[ki] = true
        pressTimes[ki] = CACurrentMediaTime()
    }

    private func unhighlight(_ ki: Int, immediate: Bool) {
        guard ki >= 0, ki < keys.count, ki < 64, highlighted[ki] else { return }
        let elapsed = CACurrentMediaTime() - pressTimes[ki]
        let remaining = 0.035 - elapsed
        if immediate || remaining <= 0 {
            applyRelease(ki)
        } else {
            let item = DispatchWorkItem { [weak self] in self?.applyRelease(ki) }
            releaseItems[ki]?.cancel()
            releaseItems[ki] = item
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: item)
        }
    }

    private func applyRelease(_ ki: Int) {
        guard ki < keys.count else { return }
        releaseItems[ki] = nil
        highlighted[ki] = false
        let k = keys[ki]
        withoutAnimation {
            k.face.backgroundColor = (k.isAccent ? theme.accent : (k.isFunction ? theme.functionKey : theme.letterKey)).cgColor
        }
    }

    private func attachBubbleIfNeeded() {
        let hostLayer = (bubbleHost ?? self).layer
        if bubbleLayer.superlayer !== hostLayer {
            bubbleLayer.removeFromSuperlayer()
            bubbleText.removeFromSuperlayer()
            hostLayer.addSublayer(bubbleLayer)
            hostLayer.addSublayer(bubbleText)
            bubbleLayer.fillColor = theme.bubble.cgColor
            bubbleText.foregroundColor = theme.bubbleText.cgColor
            bubbleText.contentsScale = scale
        }
    }

    private func showBubble(_ ki: Int, text: String) {
        attachBubbleIfNeeded()
        let k = keys[ki]
        let host: UIView = bubbleHost ?? self
        let keyRect = convert(k.frame, to: host)
        let bw = k.frame.width * 1.5, bh = k.frame.height * 1.35
        var bx = keyRect.midX - bw / 2
        bx = max(2, min(bx, host.bounds.width - bw - 2))
        let by = keyRect.minY - bh - 4
        let bubbleRect = CGRect(x: bx, y: by, width: bw, height: bh)
        let path = CGMutablePath()
        path.addRoundedRect(in: bubbleRect, cornerWidth: 9, cornerHeight: 9)
        let neck = CGRect(x: max(keyRect.minX, bx + 2), y: bubbleRect.maxY - 8, width: min(keyRect.width, bw - 4), height: keyRect.minY - bubbleRect.maxY + 12)
        path.addRect(neck)
        path.addRoundedRect(in: keyRect, cornerWidth: 5.5, cornerHeight: 5.5)
        bubbleLayer.frame = host.bounds
        bubbleLayer.path = path
        bubbleLayer.fillColor = theme.bubble.cgColor
        bubbleLayer.shadowPath = path
        bubbleLayer.isHidden = false
        let fontSize: CGFloat = text.count > 1 ? 26 : 34
        bubbleText.font = UIFont.systemFont(ofSize: fontSize, weight: .regular)
        bubbleText.fontSize = fontSize
        bubbleText.string = text
        bubbleText.foregroundColor = theme.bubbleText.cgColor
        bubbleText.frame = CGRect(x: bubbleRect.minX, y: bubbleRect.midY - fontSize * 0.62, width: bubbleRect.width, height: fontSize * 1.25)
        bubbleText.isHidden = false
        bubbleKey = ki
    }

    private func hideBubble() {
        withoutAnimation {
            bubbleLayer.isHidden = true
            bubbleText.isHidden = true
        }
        bubbleKey = -1
    }

    private func hideBubbleAfterMinimum(_ ki: Int) {
        let elapsed = CACurrentMediaTime() - pressTimes[min(max(ki, 0), 63)]
        let remaining = 0.035 - elapsed
        if remaining <= 0 { hideBubble(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
            guard let self = self else { return }
            if !self.tracks.contains(where: { $0.active }) || self.bubbleKey == ki { self.hideBubble() }
        }
    }

    // MARK: backspace repeat

    private func startRepeat() {
        stopRepeat()
        repeatActive = true
        repeatStart = CACurrentMediaTime()
        repeatCount = 0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.4, repeating: 0.11, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self = self, self.repeatActive else { return }
            self.repeatCount += 1
            self.delegate?.canvasBackspaceStep(repeatCount: self.repeatCount)
            let elapsed = CACurrentMediaTime() - self.repeatStart
            let interval: Double = elapsed < 1.4 ? 0.11 : (elapsed < 2.8 ? 0.06 : 0.04)
            self.repeatTimer?.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        }
        repeatTimer = timer
        timer.resume()
    }

    func stopRepeat() {
        repeatActive = false
        repeatTimer?.cancel()
        repeatTimer = nil
    }
}
