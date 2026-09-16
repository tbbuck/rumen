import SwiftUI
import ArcGISKit

/// Transport, strategy and state in form: `PBF`, `Done`, `Paused`.
struct Chip: View {
    enum Style { case accent, yes, warn, no }
    let text: String
    var style: Style = .accent

    var body: some View {
        Text(text)
            .font(.sheetUI(10.5, .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(background, in: RoundedRectangle(cornerRadius: 5))
    }

    private var foreground: Color {
        switch style { case .accent: Palette.accent; case .yes: Palette.yes; case .warn: Palette.warn; case .no: Palette.no }
    }
    private var background: Color {
        switch style { case .accent: Palette.accentSoft; case .yes: Palette.yesSoft; case .warn: Palette.warnSoft; case .no: Palette.no.opacity(0.14) }
    }
}

/// 8px status dot: accent running, yes done, warn paused, muted2 queued.
struct StatusDot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 8, height: 8) }
}

/// `Extractable` / `Not extractable` / `Unknown` — the one word that matters.
enum Verdict {
    case extractable, notExtractable, unknown

    init(_ flag: Bool?) {
        switch flag { case true?: self = .extractable; case false?: self = .notExtractable; case nil: self = .unknown }
    }
    var word: String {
        switch self { case .extractable: "Extractable."; case .notExtractable: "Not extractable."; case .unknown: "Unknown." }
    }
    var color: Color {
        switch self { case .extractable: Palette.yes; case .notExtractable: Palette.no; case .unknown: Palette.muted2 }
    }
}

struct VerdictWord: View {
    let verdict: Verdict
    var body: some View {
        Text(verdict.word).font(.sheetUI(15, .bold)).foregroundStyle(verdict.color)
    }
}

/// `MapServer` / `FeatureServer` in 9.5 `muted2` after a service name.
struct KindLabel: View {
    let type: ServiceType
    var body: some View {
        Text(type.name).font(.sheetUI(9.5)).foregroundStyle(Palette.muted2)
    }
}

/// 22 × 15 locator: the frame is the server's union extent, the filled rect this node's.
/// Dashed and empty for a non-extractable layer; frame-only dashed for a table.
struct ExtentLocator: View {
    enum Style { case normal, notExtractable, table }
    let extent: BoundingBox?
    let frame: BoundingBox?
    var style: Style = .normal

    var body: some View {
        Canvas { context, size in
            let outer = CGRect(x: 0.5, y: 0.5, width: size.width - 1, height: size.height - 1)
            var framePath = Path(outer)
            let frameStroke = style == .table ? StrokeStyle(lineWidth: 1, dash: [2, 2]) : StrokeStyle(lineWidth: 1)
            context.stroke(framePath, with: .color(Palette.line2), style: frameStroke)
            framePath = Path()
            guard style != .table, let extent, let frame, frame.width > 0, frame.height > 0 else { return }
            // Map lon/lat into the frame; y flips (north up).
            let sx = (size.width - 2) / frame.width
            let sy = (size.height - 2) / frame.height
            var rect = CGRect(x: 1 + (extent.minX - frame.minX) * sx,
                              y: 1 + (frame.maxY - extent.maxY) * sy,
                              width: max(1.5, extent.width * sx),
                              height: max(1.5, extent.height * sy))
            rect = rect.intersection(CGRect(x: 1, y: 1, width: size.width - 2, height: size.height - 2))
            guard !rect.isNull else { return }
            let path = Path(rect)
            if style == .notExtractable {
                context.stroke(path, with: .color(Palette.muted2), style: StrokeStyle(lineWidth: 1, dash: [1.5, 1.5]))
            } else {
                context.fill(path, with: .color(Palette.accentSoft))
                context.stroke(path, with: .color(Palette.accent), lineWidth: 1)
            }
        }
        .frame(width: 22, height: 15)
        .accessibilityHidden(true)
    }
}

/// Primary: 30px, radius 6, accent fill. One per view.
struct PrimaryButtonStyle: ButtonStyle {
    var small = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.sheetUI(small ? 12 : 13, .semibold))
            .foregroundStyle(Palette.onAccent)
            .padding(.horizontal, small ? 10 : 12)
            .frame(height: small ? 26 : 30)
            .background(Palette.accent.opacity(configuration.isPressed ? 0.85 : 1), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Secondary actions are links, not outlined buttons.
struct LinkButtonStyle: ButtonStyle {
    var size: CGFloat = 13
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.sheetUI(size))
            .foregroundStyle(Palette.accent)
            .underline(configuration.isPressed)
            .contentShape(Rectangle())
    }
}

/// 30px input, radius 7, 1px line2, bg fill.
struct SheetFieldStyle: TextFieldStyle {
    var mono = false
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(mono ? .sheetMono(12.5) : .sheetUI(13))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(Palette.bg, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.line2, lineWidth: 1))
    }
}

/// Captions, ages, notes.
struct Caption: View {
    let text: String
    var size: CGFloat = 12.5
    var color: Color = Palette.muted
    init(_ text: String, size: CGFloat = 12.5, color: Color = Palette.muted) {
        self.text = text; self.size = size; self.color = color
    }
    var body: some View { Text(text).font(.sheetUI(size)).foregroundStyle(color) }
}

/// Section heading: 13.5 / 700, sentence case, no rule.
struct SectionHeading: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.sheetUI(13.5, .bold)).foregroundStyle(Palette.ink) }
}

/// Verbatim error text with the URL that produced it — never vague.
struct ErrorText: View {
    let message: String
    var body: some View {
        Text(message)
            .font(.sheetMono(11))
            .foregroundStyle(Palette.no)
            .textSelection(.enabled)
            .frame(maxWidth: 720, alignment: .leading)
    }
}
