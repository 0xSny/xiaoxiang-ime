import UIKit

final class KeyboardViewController: UIInputViewController, KeyboardCanvasDelegate {

    // MARK: views
    private let topBar = TopBarView()
    private let canvas = KeyboardCanvas()
    private var gridPanel: GridPanelView?
    private var candGrid: CandidateGridView?
    private var quickPanel: QuickSettingsView?
    private let userMenu = UIButton(type: .system)
    private var heightConstraint: NSLayoutConstraint?

    // MARK: engine & services
    private var engine: IMEEngine?
    private let haptics = HapticEngine()
    private let clicker = ClickPlayer()
    private var settings = SettingsStore.shared.current
    private lazy var themes = ThemeController(
        inputs: { [unowned self] in
            ThemeController.Inputs(appearance: self.settings.appearance,
                                   proxyAppearance: self.textDocumentProxy.keyboardAppearance ?? .default,
                                   traits: [self.traitCollection, self.view.window?.traitCollection,
                                            (self.view.window?.screen ?? UIScreen.main).traitCollection].compactMap { $0 })
        },
        apply: { [unowned self] t in self.applyTheme(t) })
    private var theme: Theme { themes.theme }

    // MARK: composing state
    private var strokes: [IMEKeyStroke] = []
    private var picks: [(pick: IMEPick, strokes: [IMEKeyStroke])] = []
    private var result: IMEResult?
    private var generation: UInt64 = 0
    private var candItems: [CandItem] = []
    private var lastMarked = ""
    private var lastEdit: CFTimeInterval = 0

    private var englishMode = false
    private var shift: ShiftState = .off
    private var lastShiftTap: CFTimeInterval = 0
    private var layout: CanvasLayout = .letters
    private var lastSpaceTime: CFTimeInterval = 0
    private var lastCommit: (text: String, time: CFTimeInterval)?
    private var flushWork: DispatchWorkItem?
    private var capsuleWork: DispatchWorkItem?
    private var userMenuItem: CandItem?
    private var warmed = false

    private var composing: Bool { !strokes.isEmpty || !picks.isEmpty }
    private var isXiaohe: Bool { settings.scheme == 1 }

    // MARK: lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.isMultipleTouchEnabled = true
        view.backgroundColor = Theme.light.background

        view.addSubview(topBar)
        view.addSubview(canvas)
        canvas.delegate = self
        canvas.bubbleHost = view
        userMenu.isHidden = true
        userMenu.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        userMenu.layer.cornerRadius = 8
        userMenu.layer.cornerCurve = .continuous
        userMenu.addTarget(self, action: #selector(userMenuTapped), for: .touchUpInside)
        view.addSubview(userMenu)

        // The single constraint that sizes the input view itself; every key is positioned with plain frame math.
        let hc = NSLayoutConstraint(item: view as Any, attribute: .height, relatedBy: .equal, toItem: nil,
                                    attribute: .notAnAttribute, multiplier: 1, constant: totalHeight())
        hc.priority = UILayoutPriority(999)
        view.addConstraint(hc)
        heightConstraint = hc

        setupEngine()
        wireTopBar()
        applySettings(initial: true)
        themes.refresh(force: true)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: .imeSettingsChanged, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        SettingsStore.shared.reload()
        settings = SettingsStore.shared.current
        checkResetFlag()
        applySettings(initial: false)
        themes.refreshSettling(force: true)
        updateReturnKey()
        haptics.prepare()
        refreshClipboardCapsule()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        themes.refreshSettling()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self = self, !self.warmed else { return }
            self.warmed = true
            self.clicker.warmUp()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        canvas.cancelAllTracks()
        if composing { commitRaw() }
        hideAllPanels()
        flushUserData()
        clicker.shutDown()
        warmed = false
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        flushUserData()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let W = view.bounds.width, H = view.bounds.height
        let barH: CGFloat = 44
        topBar.frame = CGRect(x: 0, y: 0, width: W, height: barH)
        let area = CGRect(x: 0, y: barH, width: W, height: max(H - barH, 1))
        canvas.frame = area
        gridPanel?.frame = area
        candGrid?.frame = area
        quickPanel?.frame = area
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        heightConstraint?.constant = totalHeight(forWidth: size.width)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        themes.refreshSettling()
    }

    override func textWillChange(_ textInput: UITextInput?) { themes.refreshSettling() }

    override func textDidChange(_ textInput: UITextInput?) {
        themes.refreshSettling()
        updateReturnKey()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        guard composing else { return }
        // Detect an external caret jump: the text before the cursor no longer ends with our preedit.
        let expected = lastMarked
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            guard let self = self, self.composing else { return }
            if CACurrentMediaTime() - self.lastEdit < 0.14 { return }
            let before = self.textDocumentProxy.documentContextBeforeInput ?? ""
            if !expected.isEmpty && !before.hasSuffix(expected) {
                self.resetComposingState()
                self.topBar.showToolbar()
                self.hideCandidateGrid()
            }
        }
    }

    // MARK: sizing

    private func totalHeight(forWidth w: CGFloat? = nil) -> CGFloat {
        let width = w ?? UIScreen.main.bounds.width
        let landscape = width > UIScreen.main.bounds.height
        let base: CGFloat = landscape ? 158 : 216
        return 44 + (base * CGFloat(settings.keyboardHeight)).rounded()
    }

    // MARK: engine

    private func setupEngine() {
        let path = Bundle.main.path(forResource: "dict", ofType: "bin") ?? ""
        let e = IMEEngine(dictionaryPath: path)
        e.openUserData(atPath: SettingsStore.shared.userDataDirectory().path)
        engine = e
    }

    private func applyEngineSettings() {
        engine?.applySettingsScheme(settings.scheme, fuzzy: settings.fuzzy, jianpin: true,
                                    correction: settings.spatialSensitivity > 0.01,
                                    spatialScale: Float(settings.spatialSensitivity),
                                    learning: settings.learning, completion: true)
    }

    private func checkResetFlag() {
        guard let url = SettingsStore.shared.resetFlagURL, FileManager.default.fileExists(atPath: url.path) else { return }
        engine?.resetUserData()
        try? FileManager.default.removeItem(at: url)
    }

    private func flushUserData(delayed: Bool = false) {
        flushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, let e = self.engine else { return }
            e.flushUserForce(false) {
                e.userStats { words, bigrams in
                    guard let url = SettingsStore.shared.statsURL else { return }
                    let obj: [String: Any] = ["words": words, "bigrams": bigrams, "time": Date().timeIntervalSince1970]
                    if let d = try? JSONSerialization.data(withJSONObject: obj) { try? d.write(to: url, options: .atomic) }
                }
            }
        }
        flushWork = work
        if delayed { DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work) } else { work.perform() }
    }

    // MARK: settings

    @objc private func settingsChanged() {
        let old = settings
        settings = SettingsStore.shared.current
        if old.scheme != settings.scheme && composing { clearComposing() }
        applySettings(initial: false)
        themes.refresh(force: true)
        quickPanel?.reload()
    }

    private func applySettings(initial: Bool) {
        haptics.level = settings.haptic
        clicker.enabled = settings.soundOn
        clicker.volume = Float(settings.soundVolume)
        applyEngineSettings()
        heightConstraint?.constant = totalHeight()
        canvas.configure(layout: layout, scheme: settings.scheme, hintStyle: settings.hintStyle, swipeUp: settings.swipeUp,
                         oneHand: settings.oneHand, showGlobe: needsInputModeSwitchKey, english: englishMode,
                         bubble: settings.bubbleOn, spatial: settings.spatialSensitivity > 0.01,
                         backspaceSwipe: settings.backspaceSwipeClear, cursorSensitivity: settings.spaceCursorSensitivity)
        canvas.setShift(shift)
        updateReturnKey()
        view.setNeedsLayout()
    }

    /// Applies a resolved palette to every view in one animation-free transaction.
    private func applyTheme(_ t: Theme) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.backgroundColor = t.background
        canvas.apply(theme: t)
        topBar.apply(theme: t)
        gridPanel?.apply(theme: t)
        candGrid?.apply(theme: t)
        quickPanel?.apply(theme: t)
        userMenu.backgroundColor = t.letterKey
        userMenu.setTitleColor(.systemRed, for: .normal)
        CATransaction.commit()
    }

    private func updateReturnKey() {
        var title = "换行"
        var accent = true
        switch textDocumentProxy.returnKeyType ?? .default {
        case .go: title = "前往"
        case .search, .google, .yahoo: title = "搜索"
        case .send: title = "发送"
        case .done: title = "完成"
        case .next: title = "下一项"
        case .join: title = "加入"
        case .route: title = "路线"
        case .continue: title = "继续"
        case .emergencyCall: title = "呼叫"
        default: accent = false
        }
        canvas.setReturnKey(title: title, accent: accent)
    }

    // MARK: top bar

    private func wireTopBar() {
        topBar.onSelect = { [weak self] item in self?.select(item) }
        topBar.onExpand = { [weak self] in self?.toggleCandidateGrid() }
        topBar.onLongPress = { [weak self] item, rect in self?.showUserMenu(item, rect) }
        topBar.onToolbar = { [weak self] item in
            guard let self = self else { return }
            self.haptics.tap()
            switch item {
            case .settings: self.showQuickSettings()
            case .phrases: self.showPhrases()
            case .emoji: self.showGrid(PanelData.emoji())
            case .symbols: self.showGrid(PanelData.symbols())
            }
        }
        topBar.onCapsule = { [weak self] in self?.pasteFromClipboard() }
        topBar.onCapsuleClose = { [weak self] in
            self?.markClipboardSeen()
            self?.topBar.setCapsule(visible: false)
        }
    }

    // MARK: clipboard capsule

    private let seenKey = "ime.pasteboard.seen"

    private func refreshClipboardCapsule() {
        guard settings.clipboardHint, hasFullAccess else { topBar.setCapsule(visible: false); return }
        let pb = UIPasteboard.general
        let seen = UserDefaults.standard.integer(forKey: seenKey)
        if pb.changeCount != seen && pb.hasStrings {
            topBar.setCapsule(visible: true, title: "粘贴")
            capsuleWork?.cancel()
            let w = DispatchWorkItem { [weak self] in
                self?.markClipboardSeen()
                self?.topBar.setCapsule(visible: false)
            }
            capsuleWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: w)
        } else {
            topBar.setCapsule(visible: false)
        }
    }

    private func markClipboardSeen() {
        UserDefaults.standard.set(UIPasteboard.general.changeCount, forKey: seenKey)
        capsuleWork?.cancel()
    }

    private func pasteFromClipboard() {
        markClipboardSeen()
        topBar.setCapsule(visible: false)
        guard hasFullAccess, let s = UIPasteboard.general.string, !s.isEmpty else { return }
        if SettingsStore.shared.importSyncString(s) { return }
        flushComposingAsRaw()
        textDocumentProxy.insertText(s)
    }

    // MARK: panels

    private func hideAllPanels() {
        gridPanel?.removeFromSuperview(); gridPanel = nil
        quickPanel?.removeFromSuperview(); quickPanel = nil
        hideCandidateGrid()
        hideUserMenu()
    }

    private func showGrid(_ cats: [GridCategory], emptyHint: String? = nil) {
        hideAllPanels()
        if composing { flushComposingAsRaw() }
        let p = GridPanelView(frame: canvas.frame)
        p.apply(theme: theme)
        p.setCategories(cats, emptyHint: emptyHint)
        p.onBack = { [weak self] in self?.haptics.tap(); self?.hideAllPanels() }
        p.onDelete = { [weak self] in self?.haptics.tap(); self?.textDocumentProxy.deleteBackward() }
        p.onInsert = { [weak self] text in
            self?.haptics.tap()
            self?.clicker.play(.key)
            self?.insertSymbolText(text)
        }
        view.insertSubview(p, belowSubview: userMenu)
        gridPanel = p
    }

    private func showPhrases() {
        let list = settings.phrases
        if list.isEmpty {
            showGrid([], emptyHint: "还没有自定义短语：请在宿主 App 添加后，点「同步到键盘」，再到此处设置里导入")
        } else {
            showGrid([GridCategory(title: "常用短语", items: list.map { $0.text }, columns: 2, fontSize: 16, cellHeight: 44)])
        }
    }

    private func showQuickSettings() {
        hideAllPanels()
        let q = QuickSettingsView(frame: canvas.frame)
        q.apply(theme: theme)
        q.reload()
        q.onClose = { [weak self] in self?.hideAllPanels() }
        q.onClearLearned = { [weak self] in self?.engine?.resetUserData() }
        q.onImport = { [weak self] in
            guard let self = self else { return "" }
            guard self.hasFullAccess else { return "请先在系统设置中开启「允许完全访问」" }
            guard let s = UIPasteboard.general.string else { return "剪贴板为空" }
            if SettingsStore.shared.importSyncString(s) { return "已导入宿主 App 同步的设置与短语" }
            return "剪贴板中没有同步数据：请先在宿主 App 点「同步到键盘」"
        }
        view.insertSubview(q, belowSubview: userMenu)
        quickPanel = q
    }

    private func toggleCandidateGrid() {
        if candGrid != nil { hideCandidateGrid(); return }
        guard !candItems.isEmpty else { return }
        hideUserMenu()
        let g = CandidateGridView(frame: canvas.frame)
        g.apply(theme: theme)
        g.setItems(candItems)
        g.onSelect = { [weak self] item in self?.select(item) }
        view.insertSubview(g, belowSubview: userMenu)
        candGrid = g
    }

    private func hideCandidateGrid() {
        candGrid?.removeFromSuperview()
        candGrid = nil
    }

    private func showUserMenu(_ item: CandItem, _ rect: CGRect) {
        haptics.tap()
        userMenuItem = item
        userMenu.setTitle("删除 / 恢复默认词频", for: .normal)
        let w: CGFloat = 170, h: CGFloat = 36
        let x = max(4, min(rect.midX - w / 2, view.bounds.width - w - 4))
        userMenu.frame = CGRect(x: x, y: topBar.frame.maxY + 4, width: w, height: h)
        userMenu.backgroundColor = theme.letterKey
        userMenu.layer.shadowColor = UIColor.black.cgColor
        userMenu.layer.shadowOpacity = 0.25
        userMenu.layer.shadowRadius = 4
        userMenu.layer.shadowOffset = CGSize(width: 0, height: 2)
        userMenu.isHidden = false
        view.bringSubviewToFront(userMenu)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in self?.hideUserMenu() }
    }

    private func hideUserMenu() {
        userMenu.isHidden = true
        userMenuItem = nil
    }

    @objc private func userMenuTapped() {
        defer { hideUserMenu() }
        guard let item = userMenuItem, let res = result, item.index >= 0, let pick = engine?.pick(with: res, index: item.index) else { return }
        engine?.delete(pick)
        scheduleDecode()
    }

    // MARK: composing helpers

    private func primaryLetter(_ s: IMEKeyStroke) -> CChar {
        var best = 0
        if s.n > 1 && s.p.1 > s.p.0 { best = 1 }
        if s.n > 2 && s.p.2 > (best == 0 ? s.p.0 : s.p.1) { best = 2 }
        return best == 0 ? s.c.0 : (best == 1 ? s.c.1 : s.c.2)
    }

    private func typedLetters() -> [CChar] { strokes.map { primaryLetter($0) } }

    private func remainderDisplay() -> String {
        let letters = typedLetters()
        if letters.isEmpty { return "" }
        guard let e = engine else { return String(letters.map { Character(UnicodeScalar(UInt8($0))) }) }
        return letters.withUnsafeBufferPointer {
            e.quickSegmentLetters($0.baseAddress!, count: letters.count, scheme: settings.scheme, expand: settings.preeditStyle == 0)
        }
    }

    private func pendingText() -> String { picks.map { $0.pick.text }.joined() }

    private func showPreedit() {
        let text = pendingText() + remainderDisplay()
        lastMarked = text
        lastEdit = CACurrentMediaTime()
        if text.isEmpty {
            textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
            textDocumentProxy.unmarkText()
        } else {
            textDocumentProxy.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0))
        }
    }

    private func clearMarked() {
        textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
        textDocumentProxy.unmarkText()
        lastMarked = ""
    }

    private func resetComposingState() {
        strokes.removeAll(keepingCapacity: true)
        picks.removeAll(keepingCapacity: true)
        result = nil
        candItems = []
        lastMarked = ""
        generation = engine?.bumpGeneration() ?? 0
    }

    private func clearComposing() {
        clearMarked()
        resetComposingState()
        topBar.showToolbar()
        hideCandidateGrid()
        hideUserMenu()
    }

    private func scheduleDecode() {
        guard let e = engine, !strokes.isEmpty else { return }
        let gen = e.bumpGeneration()
        generation = gen
        strokes.withUnsafeBufferPointer { buf in
            e.decodeKeys(buf.baseAddress!, count: buf.count, generation: gen) { [weak self] res, g in
                guard let self = self, g == self.generation else { return }
                self.decoded(res)
            }
        }
    }

    private func decoded(_ res: IMEResult) {
        result = res
        var items: [CandItem] = []
        let letters = String(typedLetters().map { Character(UnicodeScalar(UInt8($0))) })
        for p in settings.phrases where !p.code.isEmpty && p.code.lowercased() == letters {
            items.append(CandItem(text: p.text, index: -1, isUser: false, phrase: p.text, syllables: 0, chars: p.text.count))
        }
        let n = min(res.count, 160)
        items.reserveCapacity(n + items.count)
        for i in 0..<n {
            let flags = res.flags(at: i)
            if flags & IMECandidateFlags.raw.rawValue != 0 && i != n - 1 { continue }
            items.append(CandItem(text: res.text(at: i), index: i, isUser: flags & IMECandidateFlags.user.rawValue != 0,
                                  phrase: nil, syllables: res.syllableCount(at: i), chars: res.characterCount(at: i)))
        }
        candItems = items
        topBar.setCandidates(items, resetScroll: true)
        if let g = candGrid { g.setItems(items) }
    }

    private func select(_ item: CandItem) {
        if let phrase = item.phrase {
            clearMarked()
            resetComposingState()
            topBar.showToolbar()
            hideCandidateGrid()
            textDocumentProxy.insertText(phrase)
            return
        }
        guard let res = result, let e = engine, let pick = e.pick(with: res, index: item.index) else { return }
        if pick.isRaw { commitRaw(); return }
        let consumed = max(1, min(pick.consumed, strokes.count))
        let used = Array(strokes.prefix(consumed))
        strokes.removeFirst(consumed)
        picks.append((pick, used))
        hideCandidateGrid()
        if strokes.isEmpty {
            finalizeCommit()
        } else {
            showPreedit()
            scheduleDecode()
        }
    }

    private func smartPrefix(for text: String) -> String {
        guard settings.autoSpace == 1, let first = text.unicodeScalars.first, first.value >= 0x4E00 else { return "" }
        guard let prev = textDocumentProxy.documentContextBeforeInput?.unicodeScalars.last else { return "" }
        let v = prev.value
        let isAsciiAlnum = (v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122)
        return isAsciiAlnum ? " " : ""
    }

    private func finalizeCommit() {
        let text = pendingText()
        let learned = picks.map { $0.pick }
        clearMarked()
        textDocumentProxy.insertText(smartPrefix(for: text) + text)
        engine?.commit(learned)
        lastCommit = (text, CACurrentMediaTime())
        strokes.removeAll(keepingCapacity: true)
        picks.removeAll(keepingCapacity: true)
        result = nil
        candItems = []
        lastMarked = ""
        generation = engine?.bumpGeneration() ?? 0
        topBar.showToolbar()
        hideCandidateGrid()
        flushUserData(delayed: true)
    }

    /// Commits the typed letters as-is (Return key, mode switches, hiding the keyboard).
    private func commitRaw() {
        let raw = pendingText() + String(typedLetters().map { Character(UnicodeScalar(UInt8($0))) })
        clearMarked()
        if !raw.isEmpty { textDocumentProxy.insertText(raw) }
        resetComposingState()
        topBar.showToolbar()
        hideCandidateGrid()
        lastCommit = nil
    }

    private func flushComposingAsRaw() { if composing { commitRaw() } }

    /// Commits the first candidate (space / punctuation while composing).
    private func commitFirstCandidate() {
        if let first = candItems.first(where: { $0.phrase == nil }) ?? candItems.first, result != nil {
            // keep selecting until the preedit is consumed
            var guardCount = 0
            var item = first
            while composing && guardCount < 12 {
                guardCount += 1
                guard let res = result, let e = engine, let pick = e.pick(with: res, index: item.index) else { break }
                if pick.isRaw { commitRaw(); return }
                let consumed = max(1, min(pick.consumed, strokes.count))
                let used = Array(strokes.prefix(consumed))
                strokes.removeFirst(consumed)
                picks.append((pick, used))
                if strokes.isEmpty { finalizeCommit(); return }
                // remainder: no decoded result for it yet -> commit it raw after the picked part
                break
            }
            if composing { commitRaw() }
        } else {
            commitRaw()
        }
    }

    // MARK: KeyboardCanvasDelegate

    func canvasKeyDown(_ action: KeyAction) {
        haptics.tap()
        if !warmed { warmed = true; clicker.warmUp() }
        switch action {
        case .backspace: clicker.play(.delete)
        case .space: clicker.play(.space)
        default: clicker.play(.key)
        }
    }

    func canvasLetter(_ ch: UInt8, stroke: IMEKeyStroke, uppercase: Bool) {
        lastEdit = CACurrentMediaTime()
        lastSpaceTime = 0
        let chinese = !englishMode && layout == .letters
        if chinese && !uppercase {
            if strokes.count >= 40 { return }
            hideUserMenu()
            var s = stroke
            if s.n == 0 { s = IMEKeyStroke(n: 1, c: (CChar(ch), 0, 0), p: (1, 0, 0)) }
            strokes.append(s)
            showPreedit()           // optimistic inline echo in the same frame
            scheduleDecode()        // candidates follow from the background queue
            return
        }
        if composing { flushComposingAsRaw() }
        var text = String(UnicodeScalar(ch))
        if uppercase { text = text.uppercased() }
        if settings.autoSpace == 1, let prev = textDocumentProxy.documentContextBeforeInput?.unicodeScalars.last, prev.value >= 0x4E00, prev.value <= 0x9FFF {
            text = " " + text
        }
        textDocumentProxy.insertText(text)
        engine?.resetContext()
        lastCommit = nil
        if shift == .on { shift = .off; canvas.setShift(.off) }
    }

    func canvasInsert(_ text: String) {
        lastEdit = CACurrentMediaTime()
        if composing { commitFirstCandidate() }
        insertSymbolText(text)
    }

    private func insertSymbolText(_ text: String) {
        lastSpaceTime = 0
        lastCommit = nil
        textDocumentProxy.insertText(text)
        if PanelData.pairs.contains(text) { textDocumentProxy.adjustTextPosition(byCharacterOffset: -1) }
        engine?.resetContext()
    }

    func canvasSpace() {
        lastEdit = CACurrentMediaTime()
        if composing {
            commitFirstCandidate()
            lastSpaceTime = 0
            return
        }
        let now = CACurrentMediaTime()
        if settings.doubleSpacePeriod, now - lastSpaceTime < 0.4, let before = textDocumentProxy.documentContextBeforeInput, before.hasSuffix(" "),
           before.count >= 2 {
            let chars = Array(before)
            let prev = chars[chars.count - 2]
            let punct: Set<Character> = ["。", ".", "，", ",", "！", "!", "？", "?", " ", "；", ";", "："]
            if !punct.contains(prev) {
                textDocumentProxy.deleteBackward()
                let ascii = prev.isASCII && (prev.isLetter || prev.isNumber)
                textDocumentProxy.insertText(ascii ? "." : "。")
                if ascii && englishMode { textDocumentProxy.insertText(" ") }
                lastSpaceTime = 0
                return
            }
        }
        textDocumentProxy.insertText(" ")
        lastSpaceTime = now
        lastCommit = nil
        if shift == .on { shift = .off; canvas.setShift(.off) }
    }

    func canvasReturn() {
        lastEdit = CACurrentMediaTime()
        if composing { commitRaw(); return }
        lastSpaceTime = 0
        lastCommit = nil
        textDocumentProxy.insertText("\n")
        engine?.resetContext()
    }

    func canvasShift() {
        let now = CACurrentMediaTime()
        switch shift {
        case .off:
            shift = .on
        case .on:
            shift = (now - lastShiftTap < 0.35) ? .locked : .off
        case .locked:
            shift = .off
        }
        lastShiftTap = now
        canvas.setShift(shift)
    }

    func canvasBackspaceStep(repeatCount: Int) {
        lastEdit = CACurrentMediaTime()
        lastSpaceTime = 0
        if composing {
            if !strokes.isEmpty {
                strokes.removeLast()
            } else if let last = picks.popLast() {
                strokes = last.strokes
                if !strokes.isEmpty { strokes.removeLast() }
            }
            if composing {
                showPreedit()
                if strokes.isEmpty { candItems = []; result = nil; generation = engine?.bumpGeneration() ?? 0; topBar.showToolbar(); hideCandidateGrid() }
                else { scheduleDecode() }
            } else {
                clearComposing()
            }
            return
        }
        // refund the learning of a word that is deleted right after it was committed
        if repeatCount == 0, let lc = lastCommit, CACurrentMediaTime() - lc.time < 6 {
            let before = textDocumentProxy.documentContextBeforeInput ?? ""
            if before.hasSuffix(lc.text) { engine?.rollbackLastCommit() }
            lastCommit = nil
        }
        if repeatCount >= 14 {
            let before = Array(textDocumentProxy.documentContextBeforeInput ?? "")
            var n = 0
            var i = before.count - 1
            while i >= 0 && n < 8 {
                let c = before[i]
                if n > 0 && (c == " " || c == "\n" || "，。！？,.!?；;：:".contains(c)) { break }
                n += 1
                i -= 1
                if c.unicodeScalars.first.map({ $0.value >= 0x4E00 }) == true && n >= 2 { break }
            }
            for _ in 0..<max(n, 1) { textDocumentProxy.deleteBackward() }
        } else {
            textDocumentProxy.deleteBackward()
        }
    }

    func canvasBackspaceSwipeClear() {
        haptics.tick()
        if composing { clearComposing() }
    }

    func canvasBackspaceEnd() {}

    func canvasCursorMove(by offset: Int) {
        if composing { flushComposingAsRaw() }
        textDocumentProxy.adjustTextPosition(byCharacterOffset: offset)
        haptics.tick()
        lastSpaceTime = 0
        lastCommit = nil
        engine?.resetContext()
    }

    func canvasAction(_ action: KeyAction) {
        switch action {
        case .numbers:
            if composing { flushComposingAsRaw() }
            layout = .numbers
            applySettings(initial: false)
        case .letters:
            layout = .letters
            applySettings(initial: false)
        case .symbols:
            showGrid(PanelData.symbols())
        case .cnEn:
            if composing { flushComposingAsRaw() }
            englishMode.toggle()
            engine?.resetContext()
            canvas.setEnglishMode(englishMode)
        case .oneHandToggle:
            SettingsStore.shared.update { $0.oneHand = 0 }
        default:
            break
        }
    }

    func canvasGlobeDown(_ view: UIView, event: UIEvent?) {
        if let e = event { handleInputModeList(from: view, with: e) } else { advanceToNextInputMode() }
    }

    func canvasLetterPrior(_ out: UnsafeMutablePointer<Float>) -> Bool {
        guard composing, !strokes.isEmpty, let e = engine else { return false }
        let letters = typedLetters()
        letters.withUnsafeBufferPointer {
            e.nextLetterPriorLetters($0.baseAddress!, count: letters.count, scheme: settings.scheme, out: out)
        }
        return true
    }

    func canvasCurrentScheme() -> Int { settings.scheme }
}
