import SwiftUI
import AppKit
import CoreText

/// The Sheet palette (DESIGN-TOKENS.md): Day (sheet paper) and Night (blue slate), resolved
/// dynamically from the system appearance. One accent — Landranger magenta — means "here"
/// or "yours"; verdicts use `yes` / `no` / `muted2` and are always carried by a word.
enum Palette {
    static let bg         = Color.sheet(0xF2F4F0, 0x1A2128)
    static let panel      = Color.sheet(0xFAFBF8, 0x212930)
    static let line       = Color.sheet(0xD6DBD2, 0x33404A)
    static let line2      = Color.sheet(0xBEC5BA, 0x445362)
    static let grat       = Color.sheet(0xC5D3E2, 0x34506A)
    static let water      = Color.sheet(0xDCE7F0, 0x22303D)
    static let ink        = Color.sheet(0x222A26, 0xE7EAE6)
    static let muted      = Color.sheet(0x5E6863, 0xA2ACA6)
    static let muted2     = Color.sheet(0x646F6B, 0x8C9791)
    static let accent     = Color.sheet(0xB8236B, 0xF476B1)
    static let accentSoft = Color.sheet(0xB8236B, 0xF476B1, alpha: (0.10, 0.14))
    static let onAccent   = Color.sheet(0xFFFFFF, 0x2A0F1D)
    static let yes        = Color.sheet(0x297047, 0x62B98A)
    static let yesSoft    = Color.sheet(0x297047, 0x62B98A, alpha: (0.12, 0.16))
    static let no         = Color.sheet(0xAF372C, 0xED8177)
    static let warn       = Color.sheet(0x875814, 0xE2A64B)
    static let warnSoft   = Color.sheet(0x875814, 0xE2A64B, alpha: (0.14, 0.16))
}

extension Font {
    /// Cabin — display and headings.
    static func sheetDisplay(_ size: CGFloat, _ weight: Weight = .bold) -> Font {
        .custom("Cabin", size: size).weight(weight)
    }
    /// Cabin — UI and body.
    static func sheetUI(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
        .custom("Cabin", size: size).weight(weight)
    }
    /// Fira Code — data: ids, field names, types, extents, paths. Ligatures and contextual
    /// alternates off so data reads character for character; digits are tabular by design.
    static func sheetMono(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
        if let nsFont = SheetFonts.mono(size: size, weight: weight == .medium || weight == .semibold || weight == .bold ? 500 : 400) {
            return Font(nsFont)
        }
        return .custom("Fira Code", size: size).weight(weight).monospacedDigit()
    }
}

extension Color {
    /// A dynamic colour resolving to `light`/`dark` (0xRRGGBB), with optional per-appearance alpha.
    static func sheet(_ light: UInt32, _ dark: UInt32, alpha: (Double, Double) = (1, 1)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: isDark ? alpha.1 : alpha.0)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: CGFloat(alpha))
    }
}

/// Registers the bundled Sheet fonts (both variable TTFs) so `Font.custom` can find them.
enum SheetFonts {
    static func register() {
        for name in ["Cabin", "FiraCode"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    nonisolated(unsafe) private static var monoCache: [String: NSFont] = [:]
    nonisolated(unsafe) private static var uiCache: [String: NSFont] = [:]
    private static let monoLock = NSLock()

    /// Cabin at a variable weight (400–700) for AppKit views, cached per size and weight.
    static func ui(size: CGFloat, weight: Double = 400) -> NSFont? {
        let key = "\(size)|\(weight)"
        monoLock.lock()
        let cached = uiCache[key]
        monoLock.unlock()
        if let cached { return cached }
        let wghtAxis = 0x77676874 as NSNumber   // 'wght'
        let attributes: [NSFontDescriptor.AttributeName: Any] = [
            .family: "Cabin",
            NSFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [wghtAxis: weight as NSNumber],
        ]
        let font = NSFont(descriptor: NSFontDescriptor(fontAttributes: attributes), size: size)
        if let font {
            monoLock.lock()
            uiCache[key] = font
            monoLock.unlock()
        }
        return font
    }

    /// Fira Code at a variable weight with `liga` and `calt` disabled. Built once per size and
    /// weight: a variable-font instance is not free, and tree rows ask for it constantly.
    static func mono(size: CGFloat, weight: Double) -> NSFont? {
        let key = "\(size)|\(weight)"
        monoLock.lock()
        let cached = monoCache[key]
        monoLock.unlock()
        if let cached { return cached }
        let font = build(size: size, weight: weight)
        if let font {
            monoLock.lock()
            monoCache[key] = font
            monoLock.unlock()
        }
        return font
    }

    private static func build(size: CGFloat, weight: Double) -> NSFont? {
        let wghtAxis = 0x77676874 as NSNumber   // 'wght'
        let attributes: [NSFontDescriptor.AttributeName: Any] = [
            .family: "Fira Code",
            NSFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [wghtAxis: weight as NSNumber],
            .featureSettings: [
                [NSFontDescriptor.FeatureKey.typeIdentifier: kLigaturesType,
                 NSFontDescriptor.FeatureKey.selectorIdentifier: kCommonLigaturesOffSelector],
                [NSFontDescriptor.FeatureKey.typeIdentifier: kContextualAlternatesType,
                 NSFontDescriptor.FeatureKey.selectorIdentifier: kContextualAlternatesOffSelector],
            ],
        ]
        return NSFont(descriptor: NSFontDescriptor(fontAttributes: attributes), size: size)
    }
}

/// Relative ages in the copy voice ("14 minutes ago", "yesterday").
enum Age {
    static func text(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "never" }
        if now.timeIntervalSince(date) < 60 { return "just now" }
        return date.formatted(Date.RelativeFormatStyle(presentation: .named, unitsStyle: .wide))
    }

    /// Older than this, a cached node is flagged stale in `warn`.
    static let staleAfter: TimeInterval = 7 * 24 * 3600

    static func isStale(_ date: Date?, now: Date = Date()) -> Bool {
        guard let date else { return false }
        return now.timeIntervalSince(date) > staleAfter
    }
}

extension Int {
    /// Grouped digits: 184212 → "184,212".
    var grouped: String { formatted(.number.grouping(.automatic)) }
}

extension Int64 {
    var grouped: String { Int(self).grouped }
}
