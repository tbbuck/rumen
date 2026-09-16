import SwiftUI
import ArcGISKit

/// Transport, strategy and state in form: `PBF`, `Done`, `Paused`.
struct Chip: View {
    enum Style { case accent, yes, warn, no, muted }
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
        switch style { case .accent: Palette.accent; case .yes: Palette.yes; case .warn: Palette.warn; case .no: Palette.no; case .muted: Palette.muted }
    }
    private var background: Color {
        switch style {
        case .accent: Palette.accentSoft
        case .yes: Palette.yesSoft
        case .warn: Palette.warnSoft
        case .no: Palette.no.opacity(0.14)
        case .muted: Palette.line
        }
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
    /// True for folders and servers, whose extent is our own union of real data and is drawn
    /// however wide it is; a server-reported extent that wide is treated as a default.
    var trusted = false

    var body: some View {
        Canvas { context, size in
            let outer = CGRect(x: 0.5, y: 0.5, width: size.width - 1, height: size.height - 1)
            let frameStroke = style == .table ? StrokeStyle(lineWidth: 1, dash: [2, 2]) : StrokeStyle(lineWidth: 1)
            context.stroke(Path(outer), with: .color(Palette.line2), style: frameStroke)
            // A default-looking extent (most of the world, or a speck at Null Island) says
            // nothing about where the data is: frame only, and the tooltip explains.
            guard style != .table, let extent, !extent.isDegenerate, trusted || !extent.isDefaultLike,
                  let frame, !frame.isDegenerate else { return }
            // The box lives inside a 2px margin, so even one that fills the frame reads as a
            // box within it rather than a second border.
            let inset: CGFloat = 2.5
            let inner = CGRect(x: inset, y: inset, width: size.width - 2 * inset, height: size.height - 2 * inset)
            let sx = inner.width / frame.width
            let sy = inner.height / frame.height
            let raw = CGRect(x: inner.minX + (extent.minX - frame.minX) * sx,
                             y: inner.minY + (frame.maxY - extent.maxY) * sy,
                             width: max(1.5, extent.width * sx),
                             height: max(1.5, extent.height * sy))
            let rect = raw.intersection(inner)
            let accent = style == .notExtractable ? Palette.muted2 : Palette.accent
            // Outside the frame (an outlier the frame was trimmed to exclude): a dot on the
            // nearest edge, pointing the way.
            if rect.isNull || rect.width < 1 || rect.height < 1 {
                let x = min(max(raw.midX, inner.minX), inner.maxX)
                let y = min(max(raw.midY, inner.minY), inner.maxY)
                context.fill(Path(ellipseIn: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3)), with: .color(accent))
                return
            }
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

// MARK: - Hover

/// Hover tracking with the tokens' motion rules: `.12s ease` scoped to the view, none under
/// Reduce Motion, and a pointing hand for anything that acts like a link. The cursor is set
/// outright rather than pushed, and reset when the view goes away, so it can never stick.
struct HoverTracking: ViewModifier {
    @Binding var isHovered: Bool
    var hand = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .onHover { hovering in isHovered = hovering }
            .onDisappear { if isHovered { isHovered = false } }
            .pointerStyle(hand ? PointerStyle.link : nil)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: isHovered)
    }
}

extension View {
    func hoverTracking(_ isHovered: Binding<Bool>, hand: Bool = false) -> some View {
        modifier(HoverTracking(isHovered: isHovered, hand: hand))
    }
}

/// A subtle pill behind hovered menu labels and links, drawn outside the layout so nothing shifts.
struct HoverPill: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: 5)
                .fill(on ? Palette.line.opacity(0.7) : .clear)
                .padding(.horizontal, -6).padding(.vertical, -3))
    }
}

/// Menu labels and other clickable text: pill on hover, pointing hand.
struct HoverLabel: ViewModifier {
    @State private var hovered = false
    func body(content: Content) -> some View {
        content.modifier(HoverPill(on: hovered)).hoverTracking($hovered, hand: true)
    }
}

extension View {
    func hoverLabel() -> some View { modifier(HoverLabel()) }
}

/// Primary: 30px, radius 6, accent fill; brightens and lifts on hover, dims when pressed. One
/// per view.
struct PrimaryButtonStyle: ButtonStyle {
    var small = false
    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration, small: small)
    }

    private struct PrimaryButtonBody: View {
        let configuration: Configuration
        let small: Bool
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.sheetUI(small ? 12 : 13, .semibold))
                .foregroundStyle(Palette.onAccent)
                .padding(.horizontal, small ? 10 : 12)
                .frame(height: small ? 26 : 30)
                .background(Palette.accent, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(hovered && !configuration.isPressed && isEnabled ? 0.18 : 0)))
                .shadow(color: Palette.accent.opacity(hovered && isEnabled ? 0.35 : 0), radius: 6, y: 2)
                .opacity(configuration.isPressed ? 0.85 : (isEnabled ? 1 : 0.45))
                .hoverTracking($hovered, hand: isEnabled)
        }
    }
}

/// Secondary actions are links, not outlined buttons: accent text, underline and a soft pill
/// on hover.
struct LinkButtonStyle: ButtonStyle {
    var size: CGFloat = 13
    func makeBody(configuration: Configuration) -> some View {
        LinkButtonBody(configuration: configuration, size: size)
    }

    private struct LinkButtonBody: View {
        let configuration: Configuration
        let size: CGFloat
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.sheetUI(size))
                .foregroundStyle(isEnabled ? Palette.accent : Palette.muted2)
                .underline(hovered && isEnabled)
                .opacity(configuration.isPressed ? 0.7 : 1)
                .modifier(HoverPill(on: hovered && isEnabled))
                .contentShape(Rectangle())
                .hoverTracking($hovered, hand: isEnabled)
        }
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

/// Run progress: 6px, radius 3; `yes` when done, `warn` when paused, `accent` while running.
struct ProgressBar: View {
    let fraction: Double
    var color: Color = Palette.accent
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.line)
                Capsule().fill(color).frame(width: max(0, min(1, fraction)) * proxy.size.width)
            }
        }
        .frame(height: height)
    }
}
