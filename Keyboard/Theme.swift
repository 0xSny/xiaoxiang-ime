import UIKit

/// Complete keyboard palette. Colors are plain RGB values (no dynamic providers) so a theme swap is a
/// single, animation-free pass over all layers.
struct Theme {
    var isDark: Bool
    var background: UIColor
    var letterKey: UIColor
    var functionKey: UIColor
    var keyPressed: UIColor
    var functionPressed: UIColor
    var keyShadow: UIColor
    var keyHighlight: UIColor
    var keyBorder: UIColor
    var text: UIColor
    var subText: UIColor
    var accent: UIColor
    var accentPressed: UIColor
    var accentText: UIColor
    var candidateText: UIColor
    var candidateSubText: UIColor
    var separator: UIColor
    var bubble: UIColor
    var bubbleText: UIColor
    var toolbarIcon: UIColor
    var panel: UIColor

    static func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }

    /// 清爽浅色: classic light keyboard, white keys on a soft cool-gray bed.
    static let light = Theme(
        isDark: false, background: rgb(0xD5D8DE), letterKey: rgb(0xFFFFFF), functionKey: rgb(0xAEB4BE),
        keyPressed: rgb(0xE6E9EE), functionPressed: rgb(0xFFFFFF), keyShadow: rgb(0x8B8F97), keyHighlight: rgb(0xFFFFFF, 0.9),
        keyBorder: rgb(0x000000, 0.0), text: rgb(0x1C1C1E), subText: rgb(0x1C1C1E, 0.58), accent: rgb(0x3D7BEA),
        accentPressed: rgb(0x2F66CC), accentText: rgb(0xFFFFFF), candidateText: rgb(0x1C1C1E), candidateSubText: rgb(0x6B7280),
        separator: rgb(0x000000, 0.12), bubble: rgb(0xFFFFFF), bubbleText: rgb(0x1C1C1E), toolbarIcon: rgb(0x4B5563),
        panel: rgb(0xD5D8DE))

    /// 纯净亮白: brighter bed and hairline key borders.
    static let white = Theme(
        isDark: false, background: rgb(0xF3F4F7), letterKey: rgb(0xFFFFFF), functionKey: rgb(0xE3E6EB),
        keyPressed: rgb(0xE9ECF1), functionPressed: rgb(0xFFFFFF), keyShadow: rgb(0xA9AEB8), keyHighlight: rgb(0xFFFFFF, 1.0),
        keyBorder: rgb(0x000000, 0.06), text: rgb(0x1C1C1E), subText: rgb(0x1C1C1E, 0.58), accent: rgb(0x3D7BEA),
        accentPressed: rgb(0x2F66CC), accentText: rgb(0xFFFFFF), candidateText: rgb(0x1C1C1E), candidateSubText: rgb(0x6B7280),
        separator: rgb(0x000000, 0.10), bubble: rgb(0xFFFFFF), bubbleText: rgb(0x1C1C1E), toolbarIcon: rgb(0x4B5563),
        panel: rgb(0xF3F4F7))

    /// Dark: soft charcoal keys, muted blue accent (no neon).
    static let dark = Theme(
        isDark: true, background: rgb(0x1E1F22), letterKey: rgb(0x4A4B50), functionKey: rgb(0x303135),
        keyPressed: rgb(0x66676D), functionPressed: rgb(0x4A4B50), keyShadow: rgb(0x000000, 0.75), keyHighlight: rgb(0xFFFFFF, 0.10),
        keyBorder: rgb(0xFFFFFF, 0.0), text: rgb(0xF2F2F7), subText: rgb(0xF2F2F7, 0.60), accent: rgb(0x4F83D6),
        accentPressed: rgb(0x6A9AE6), accentText: rgb(0xFFFFFF), candidateText: rgb(0xF2F2F7), candidateSubText: rgb(0x9CA3AF),
        separator: rgb(0xFFFFFF, 0.14), bubble: rgb(0x5B5C62), bubbleText: rgb(0xF2F2F7), toolbarIcon: rgb(0xC7CBD3),
        panel: rgb(0x1E1F22))

    static func resolve(appearance: Int, hostDark: Bool, systemDark: Bool) -> Theme {
        switch appearance {
        case 2: return (hostDark || systemDark) ? .dark : .light
        case 1: return hostDark ? .dark : .white
        default: return hostDark ? .dark : .light
        }
    }
}

/// Runs a block with implicit CALayer animations disabled.
@inline(__always)
func withoutAnimation(_ body: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    body()
    CATransaction.commit()
}

/// Snaps a coordinate to the physical pixel grid.
@inline(__always)
func pixelSnap(_ v: CGFloat, _ scale: CGFloat) -> CGFloat {
    (v * scale).rounded() / scale
}

func pixelRect(_ r: CGRect, _ scale: CGFloat) -> CGRect {
    let x0 = pixelSnap(r.minX, scale), y0 = pixelSnap(r.minY, scale)
    let x1 = pixelSnap(r.maxX, scale), y1 = pixelSnap(r.maxY, scale)
    return CGRect(x: x0, y: y0, width: max(x1 - x0, 1 / scale), height: max(y1 - y0, 1 / scale))
}
