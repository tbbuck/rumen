import SwiftUI
import AppKit

/// An editable plain-text view for the things the user types *at a machine*: where clauses and
/// SQL.
///
/// AppKit turns `'` into `‘…’` and `--` into `–` as you type, following the system's "smart
/// quotes and dashes" setting, and SwiftUI's `TextEditor` offers no way to switch that off. In
/// prose that is helpful; in a query it is silent corruption — the server answers a clause the
/// user never wrote, and nothing in the app shows why. Every editor meant for code turns the
/// substitutions off, and so does this one.
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    let accessibilityLabel: String
    var fontSize: CGFloat = 12.5

    /// Switches off every automatic rewrite AppKit performs on typed text. Separate from view
    /// construction so a test can assert it without a running app.
    static func disableSubstitutions(_ textView: NSTextView) {
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        // Smart insert/delete adds and eats spaces around pasted words, which mangles a pasted
        // clause just as surely as a curly quote does.
        textView.smartInsertDeleteEnabled = false
    }

    static func makeTextView(fontSize: CGFloat) -> NSTextView {
        let textView = NSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 4)
        textView.font = SheetFonts.mono(size: fontSize, weight: 400) ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = NSColor.sheet(0x222A26, 0xE7EAE6)
        textView.insertionPointColor = NSColor.sheet(0x222A26, 0xE7EAE6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        disableSubstitutions(textView)
        return textView
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let textView = Self.makeTextView(fontSize: fontSize)
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.delegate = context.coordinator
        textView.string = text
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView, textView.string != text else { return }
        // Only when the model moved out from under the view: assigning while the user is typing
        // would drop the insertion point to the end of the line.
        textView.string = text
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}

/// Switches AppKit's automatic rewriting off for the whole process. This is what covers the
/// single-line fields — a server URL, an `Origin` header, a cookie: an `NSTextField` edits
/// through the window's shared field editor, so it cannot be configured the way
/// `PlainTextEditor` configures a view it owns. Written to the app's own defaults domain, which
/// outranks the system-wide "smart quotes and dashes" setting.
enum TextSubstitution {
    static let keys = [
        "NSAutomaticQuoteSubstitutionEnabled",
        "NSAutomaticDashSubstitutionEnabled",
        "NSAutomaticTextReplacementEnabled",
        "NSAutomaticSpellingCorrectionEnabled",
        "NSAutomaticPeriodSubstitutionEnabled",
        "NSAutomaticCapitalizationEnabled",
    ]

    static func disableForThisApp(_ defaults: UserDefaults = .standard) {
        for key in keys { defaults.set(false, forKey: key) }
    }
}

extension View {
    /// The frame the where-clause and SQL boxes share.
    func plainEditorChrome(height: CGFloat = 64, maxWidth: CGFloat = 720) -> some View {
        frame(height: height)
            .background(Palette.bg, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.line2, lineWidth: 1))
            .frame(maxWidth: maxWidth)
    }
}
