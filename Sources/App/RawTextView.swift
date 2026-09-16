import SwiftUI
import AppKit

/// A read-only, selectable text view for large mono text (the Raw tab). `NSTextView` lays out
/// lazily, so a multi-megabyte layer definition does not stall the main thread the way a
/// SwiftUI `Text` would.
struct RawTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor.sheet(0xFAFBF8, 0x212930)
        scroll.borderType = .noBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.font = SheetFonts.mono(size: 12, weight: 400) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = NSColor.sheet(0x222A26, 0xE7EAE6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.string = text
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
        textView.scroll(.zero)
    }
}
