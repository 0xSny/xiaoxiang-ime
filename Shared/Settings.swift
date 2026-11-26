import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Strongly typed settings model shared by the host app and the keyboard extension

struct Phrase: Codable, Equatable, Hashable {
    var code: String
    var text: String
}

struct IMESettings: Codable, Equatable {
    var scheme: Int = 0                 // 0 全拼, 1 小鹤双拼
    var hintStyle: Int = 0              // 0 完整助记, 1 极简韵母, 2 盲打隐藏
    var preeditStyle: Int = 0           // 0 展开全拼提示, 1 原始双拼码
    var haptic: Int = 2                 // 0 关闭, 1 轻微, 2 清脆, 3 强劲
    var soundOn: Bool = true
    var soundVolume: Double = 0.6
    var bubbleOn: Bool = true
    var keyboardHeight: Double = 1.0    // 0.85 ... 1.25
    var oneHand: Int = 0                // 0 完整, 1 居左, 2 居右
    var swipeUp: Bool = true
    var fuzzy: Int = 0                  // 11-bit mask, see FuzzyBit in the C++ core
    var spatialSensitivity: Double = 1.0  // 0 关闭 ... 2 激进
    var autoSpace: Int = 1              // 0 关闭, 1 中英之间自动加空格
    var doubleSpacePeriod: Bool = true
    var spaceCursorSensitivity: Double = 1.0
    var backspaceSwipeClear: Bool = true
    var clipboardHint: Bool = true
    var appearance: Int = 0             // 0 清爽浅色, 1 纯净亮白, 2 跟随系统深色
    var learning: Bool = true
    var phrases: [Phrase] = []
    var stamp: Double = 0               // last-modified time, used by the sync bridge

    init() {}

    enum CodingKeys: String, CodingKey {
        case scheme, hintStyle, preeditStyle, haptic, soundOn, soundVolume, bubbleOn, keyboardHeight, oneHand
        case swipeUp, fuzzy, spatialSensitivity, autoSpace, doubleSpacePeriod, spaceCursorSensitivity
        case backspaceSwipeClear, clipboardHint, appearance, learning, phrases, stamp
    }

    // Tolerant decoding: unknown / missing keys fall back to defaults so app updates never wipe settings.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = IMESettings()
        scheme = (try? c.decodeIfPresent(Int.self, forKey: .scheme)) ?? d.scheme
        hintStyle = (try? c.decodeIfPresent(Int.self, forKey: .hintStyle)) ?? d.hintStyle
        preeditStyle = (try? c.decodeIfPresent(Int.self, forKey: .preeditStyle)) ?? d.preeditStyle
        haptic = (try? c.decodeIfPresent(Int.self, forKey: .haptic)) ?? d.haptic
        soundOn = (try? c.decodeIfPresent(Bool.self, forKey: .soundOn)) ?? d.soundOn
        soundVolume = (try? c.decodeIfPresent(Double.self, forKey: .soundVolume)) ?? d.soundVolume
        bubbleOn = (try? c.decodeIfPresent(Bool.self, forKey: .bubbleOn)) ?? d.bubbleOn
        keyboardHeight = (try? c.decodeIfPresent(Double.self, forKey: .keyboardHeight)) ?? d.keyboardHeight
        oneHand = (try? c.decodeIfPresent(Int.self, forKey: .oneHand)) ?? d.oneHand
        swipeUp = (try? c.decodeIfPresent(Bool.self, forKey: .swipeUp)) ?? d.swipeUp
        fuzzy = (try? c.decodeIfPresent(Int.self, forKey: .fuzzy)) ?? d.fuzzy
        spatialSensitivity = (try? c.decodeIfPresent(Double.self, forKey: .spatialSensitivity)) ?? d.spatialSensitivity
        autoSpace = (try? c.decodeIfPresent(Int.self, forKey: .autoSpace)) ?? d.autoSpace
        doubleSpacePeriod = (try? c.decodeIfPresent(Bool.self, forKey: .doubleSpacePeriod)) ?? d.doubleSpacePeriod
        spaceCursorSensitivity = (try? c.decodeIfPresent(Double.self, forKey: .spaceCursorSensitivity)) ?? d.spaceCursorSensitivity
        backspaceSwipeClear = (try? c.decodeIfPresent(Bool.self, forKey: .backspaceSwipeClear)) ?? d.backspaceSwipeClear
        clipboardHint = (try? c.decodeIfPresent(Bool.self, forKey: .clipboardHint)) ?? d.clipboardHint
        appearance = (try? c.decodeIfPresent(Int.self, forKey: .appearance)) ?? d.appearance
        learning = (try? c.decodeIfPresent(Bool.self, forKey: .learning)) ?? d.learning
        phrases = (try? c.decodeIfPresent([Phrase].self, forKey: .phrases)) ?? d.phrases
        stamp = (try? c.decodeIfPresent(Double.self, forKey: .stamp)) ?? d.stamp
    }

    // Names of the 11 independent fuzzy-sound groups (bit order matches the C++ FuzzyBit enum).
    static let fuzzyNames = ["z ↔ zh", "c ↔ ch", "s ↔ sh", "an ↔ ang", "en ↔ eng", "in ↔ ing",
                             "ian ↔ iang", "uan ↔ uang", "l ↔ n", "f ↔ h", "r ↔ l"]

    func fuzzyEnabled(_ bit: Int) -> Bool { (fuzzy >> bit) & 1 == 1 }
    mutating func setFuzzy(_ bit: Int, _ on: Bool) {
        if on { fuzzy |= (1 << bit) } else { fuzzy &= ~(1 << bit) }
    }
}

extension Notification.Name {
    static let imeSettingsChanged = Notification.Name("com.custom.ime.settingsChanged")
}

// MARK: - Store: App Group when available, otherwise sandbox-local with graceful degradation

final class SettingsStore {
    static let shared = SettingsStore()
    static let groupID = "group.com.custom.ime"
    private static let darwinName = "com.custom.ime.settings.changed" as CFString
    static let syncPrefix = "XYIME1:"

    private let defaults: UserDefaults
    let sharedContainer: URL?
    private(set) var current: IMESettings = IMESettings()
    private let key = "ime.settings.v1"

    /// True when the signing tool preserved the App Group entitlement (host <-> keyboard share storage).
    var hasSharedContainer: Bool { sharedContainer != nil }

    private init() {
        let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SettingsStore.groupID)
        if let url = url, let d = UserDefaults(suiteName: SettingsStore.groupID) {
            defaults = d
            sharedContainer = url
        } else {
            defaults = UserDefaults.standard
            sharedContainer = nil
        }
        current = loadFromDisk()
        registerDarwinObserver()
    }

    private func loadFromDisk() -> IMESettings {
        if let data = defaults.data(forKey: key), let s = try? JSONDecoder().decode(IMESettings.self, from: data) {
            return s
        }
        return IMESettings()
    }

    /// Re-reads storage (called when a Darwin notification arrives or the keyboard appears).
    func reload() {
        let s = loadFromDisk()
        if s != current {
            current = s
            NotificationCenter.default.post(name: .imeSettingsChanged, object: nil)
        }
    }

    func update(_ mutate: (inout IMESettings) -> Void) {
        var s = current
        mutate(&s)
        save(s)
    }

    func save(_ s: IMESettings, notifyOthers: Bool = true) {
        var s = s
        s.stamp = Date().timeIntervalSince1970
        current = s
        if let data = try? JSONEncoder().encode(s) {
            defaults.set(data, forKey: key)
        }
        NotificationCenter.default.post(name: .imeSettingsChanged, object: nil)
        if notifyOthers && hasSharedContainer {
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                 CFNotificationName(SettingsStore.darwinName), nil, nil, true)
        }
    }

    private func registerDarwinObserver() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(center, observer, { _, observer, _, _, _ in
            guard let observer = observer else { return }
            let store = Unmanaged<SettingsStore>.fromOpaque(observer).takeUnretainedValue()
            DispatchQueue.main.async { store.reload() }
        }, CFNotificationName(SettingsStore.darwinName).rawValue, nil, .deliverImmediately)
    }

    // MARK: user data location

    /// Directory that holds the self-learning dictionary (shared container when available).
    func userDataDirectory() -> URL {
        let fm = FileManager.default
        let base: URL
        if let c = sharedContainer {
            base = c.appendingPathComponent("Library/IMEData", isDirectory: true)
        } else {
            let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
            base = support.appendingPathComponent("IMEData", isDirectory: true)
        }
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    // MARK: sync bridge (host -> keyboard through the pasteboard; works without an App Group)

    func exportSyncString() -> String {
        guard let data = try? JSONEncoder().encode(current) else { return "" }
        return SettingsStore.syncPrefix + data.base64EncodedString()
    }

    @discardableResult
    func importSyncString(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix(SettingsStore.syncPrefix) else { return false }
        let b64 = String(t.dropFirst(SettingsStore.syncPrefix.count))
        guard let data = Data(base64Encoded: b64), let s = try? JSONDecoder().decode(IMESettings.self, from: data) else {
            return false
        }
        save(s, notifyOthers: false)
        return true
    }

    // MARK: stats / reset flag files (App Group only)

    var statsURL: URL? { sharedContainer?.appendingPathComponent("Library/IMEData/stats.json") }
    var resetFlagURL: URL? { sharedContainer?.appendingPathComponent("Library/IMEData/reset.flag") }
}
