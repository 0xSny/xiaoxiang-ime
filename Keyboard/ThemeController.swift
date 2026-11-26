import UIKit

/// Single owner of the keyboard colour scheme.
///
/// Why this exists: right after returning from another app the controller's own `traitCollection` can be
/// `.unspecified` (or stale) and `keyboardAppearance` may not be populated yet, so reading them once makes the
/// keyboard flash to the light palette. The controller therefore
///   1. merges every available signal (host proxy, controller / window / screen traits),
///   2. ignores `.unspecified` readings and falls back to the last determinate value,
///   3. re-evaluates a few times while the system settles, applying only when the resolved kind changes.
final class ThemeController {
    enum Kind: Equatable { case light, white, dark }

    /// Snapshot of everything the resolver reads. Evaluated lazily on every refresh.
    struct Inputs {
        var appearance: Int                      // 0 清爽浅色, 1 纯净亮白 (both adapt to dark), 2 始终深色
        var proxyAppearance: UIKeyboardAppearance
        var traits: [UITraitCollection]          // controller, window, screen (most specific first)
    }

    private(set) var kind: Kind = .light
    private var applied: Kind?
    private var lastSystemDark = false
    private var settleToken = 0
    private var lastSettleStart: CFTimeInterval = 0

    private let inputs: () -> Inputs
    private let apply: (Theme) -> Void

    init(inputs: @escaping () -> Inputs, apply: @escaping (Theme) -> Void) {
        self.inputs = inputs
        self.apply = apply
    }

    var theme: Theme { ThemeController.palette(kind) }

    static func palette(_ k: Kind) -> Theme {
        switch k {
        case .light: return .light
        case .white: return .white
        case .dark: return .dark
        }
    }

    /// Resolves and applies immediately. `force` re-applies even when the kind did not change
    /// (after settings changes or when views were rebuilt).
    func refresh(force: Bool = false) {
        let i = inputs()
        let resolved = resolve(i)
        kind = resolved
        if force || applied != resolved {
            applied = resolved
            apply(ThemeController.palette(resolved))
        }
    }

    /// Refresh now, then again while trait / proxy information settles after a lifecycle event.
    func refreshSettling(force: Bool = false) {
        refresh(force: force)
        // Bursts of text-change callbacks must not pile up timers; pending ones already cover the window.
        let now = CACurrentMediaTime()
        if !force && now - lastSettleStart < 0.5 { return }
        lastSettleStart = now
        settleToken += 1
        let token = settleToken
        for delay in [0.06, 0.25, 0.8, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, self.settleToken == token else { return }
                self.refresh()
            }
        }
    }

    private func resolve(_ i: Inputs) -> Kind {
        if i.appearance == 2 { return .dark }
        let hostDark = i.proxyAppearance == .dark || i.proxyAppearance == .alert
        return (hostDark || systemDark(i.traits)) ? .dark : (i.appearance == 1 ? .white : .light)
    }

    /// Dark when any determinate trait says dark; `.unspecified` readings are ignored.
    private func systemDark(_ traits: [UITraitCollection]) -> Bool {
        var determinate = false
        var dark = false
        for t in traits where t.userInterfaceStyle != .unspecified {
            determinate = true
            if t.userInterfaceStyle == .dark { dark = true }
        }
        if determinate { lastSystemDark = dark }
        return determinate ? dark : lastSystemDark
    }
}
