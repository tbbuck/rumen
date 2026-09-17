import XCTest

/// WCAG 2 contrast of the Sheet palette, computed from the tokens themselves: every tone used
/// as text (`ink`, `muted`, `muted2`, `accent`, `yes`, `no`, `warn`) against both grounds
/// (`bg`, `panel`) in both appearances must reach 4.5:1, the AA floor for text under 18pt;
/// `on-accent` on `accent` likewise. The values are read from `Sources/App/Theme.swift`, so
/// the code, not a copy of it, is what is checked; DESIGN-TOKENS.md must agree with it.
final class PaletteContrastTests: XCTestCase {

    private static let repo = URL(fileURLWithPath: #filePath)   // Tests/ArcGISExplorerUITests/PaletteContrastTests.swift
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// `name: (day, night)` from every `static let name = Color.sheet(0xDAY, 0xNIGHT…)` line.
    private func palette() throws -> [String: (day: UInt32, night: UInt32)] {
        let text = try String(contentsOf: Self.repo.appendingPathComponent("Sources/App/Theme.swift"), encoding: .utf8)
        let pattern = #"static let (\w+)\s*=\s*Color\.sheet\(0x([0-9A-Fa-f]{6}),\s*0x([0-9A-Fa-f]{6})"#
        let regex = try NSRegularExpression(pattern: pattern)
        var out = [String: (day: UInt32, night: UInt32)]()
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let name = String(text[Range(match.range(at: 1), in: text)!])
            let day = UInt32(text[Range(match.range(at: 2), in: text)!], radix: 16)!
            let night = UInt32(text[Range(match.range(at: 3), in: text)!], radix: 16)!
            out[name] = (day, night)
        }
        return out
    }

    /// `token: (day, night)` from the DESIGN-TOKENS.md colour table.
    private func documented() throws -> [String: (day: String, night: String)] {
        let text = try String(contentsOf: Self.repo.appendingPathComponent("DESIGN-TOKENS.md"), encoding: .utf8)
        let pattern = #"^\| `([\w-]+)` \| `#([0-9A-Fa-f]{6})` \| `#([0-9A-Fa-f]{6})` \|"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        var out = [String: (day: String, night: String)]()
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            out[String(text[Range(match.range(at: 1), in: text)!])] = (
                String(text[Range(match.range(at: 2), in: text)!]).uppercased(),
                String(text[Range(match.range(at: 3), in: text)!]).uppercased())
        }
        return out
    }

    static func luminance(_ rgb: UInt32) -> Double {
        func channel(_ v: UInt32) -> Double {
            let c = Double(v) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel((rgb >> 16) & 0xFF) + 0.7152 * channel((rgb >> 8) & 0xFF) + 0.0722 * channel(rgb & 0xFF)
    }

    static func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    func testEveryTextToneReachesAAOnBothGrounds() throws {
        let tones = try palette()
        for name in ["bg", "panel", "ink", "muted", "muted2", "accent", "onAccent", "yes", "no", "warn"] {
            XCTAssertNotNil(tones[name], "\(name) is missing from Theme.swift")
        }
        guard let bg = tones["bg"], let panel = tones["panel"] else { return }
        for text in ["ink", "muted", "muted2", "accent", "yes", "no", "warn"] {
            guard let tone = tones[text] else { continue }
            for (ground, values) in [("bg", bg), ("panel", panel)] {
                let day = Self.ratio(tone.day, values.day)
                let night = Self.ratio(tone.night, values.night)
                XCTAssertGreaterThanOrEqual(day, 4.5, "\(text) on \(ground) by day: \(String(format: "%.2f", day)):1")
                XCTAssertGreaterThanOrEqual(night, 4.5, "\(text) on \(ground) by night: \(String(format: "%.2f", night)):1")
            }
        }
        if let onAccent = tones["onAccent"], let accent = tones["accent"] {
            XCTAssertGreaterThanOrEqual(Self.ratio(onAccent.day, accent.day), 4.5, "on-accent on accent by day")
            XCTAssertGreaterThanOrEqual(Self.ratio(onAccent.night, accent.night), 4.5, "on-accent on accent by night")
        }
    }

    func testDesignTokensAgreeWithTheCode() throws {
        let tones = try palette()
        let docs = try documented()
        let names: [(code: String, doc: String)] = [
            ("bg", "bg"), ("panel", "panel"), ("line", "line"), ("line2", "line2"), ("grat", "grat"), ("water", "water"),
            ("ink", "ink"), ("muted", "muted"), ("muted2", "muted2"), ("accent", "accent"), ("onAccent", "on-accent"),
            ("yes", "yes"), ("no", "no"), ("warn", "warn"),
        ]
        for pair in names {
            guard let code = tones[pair.code], let doc = docs[pair.doc] else {
                XCTFail("\(pair.doc) is missing from Theme.swift or DESIGN-TOKENS.md"); continue
            }
            XCTAssertEqual(String(format: "%06X", code.day), doc.day, "\(pair.doc) by day differs between Theme.swift and DESIGN-TOKENS.md")
            XCTAssertEqual(String(format: "%06X", code.night), doc.night, "\(pair.doc) by night differs between Theme.swift and DESIGN-TOKENS.md")
        }
    }
}
