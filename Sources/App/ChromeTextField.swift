import SwiftUI
import AppKit

/// A single-line field for the title bar (the location box and "Find a column"), on AppKit's
/// own `NSTextField` rather than SwiftUI's `TextField`.
///
/// SwiftUI's field kept its own idea of focus beside the window's first responder, and the two
/// drifted: a click elsewhere resigned the field editor while the box stayed lit, and ⌘L set a
/// flag the field only read when it first appeared, so a second ⌘L lit the box and left the
/// keyboard wherever it was — a paste then landed in the other box, or nowhere. Its field
/// editor also laid the text out a couple of points left of where the resting field drew it,
/// so the text jumped on focus. Here focus *is* the first responder: a request makes the field
/// first responder, and losing it by any route (a click, Tab, the other box's shortcut) is
/// reported back once.
struct ChromeTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let font: NSFont
    let accessibilityLabel: String
    let identifier: String
    /// Bumped to put the caret here (⌘L, ⌘F); a counter, so a repeat still acts.
    let focusRequest: Int
    /// Take the keyboard as soon as the field exists (the location box only exists while editing).
    var focusOnAppear = false
    /// The box drawn around the field, in window-content coordinates from the top left: a click
    /// inside it keeps the keyboard here (see `FieldFocus`).
    var focusArea: CGRect?
    var onFocusChange: (Bool) -> Void = { _ in }
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}

    func makeNSView(context: Context) -> ChromeNSTextField {
        let field = ChromeNSTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.font = font
        field.textColor = NSColor.sheet(0x222A26, 0xE7EAE6)
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: font, .foregroundColor: NSColor.sheet(0x646F6B, 0x8C9791),
        ])
        field.setAccessibilityLabel(accessibilityLabel)
        field.setAccessibilityIdentifier(identifier)
        field.stringValue = text
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let coordinator = context.coordinator
        field.onFocusChange = { [weak coordinator] focused in coordinator?.parent.onFocusChange(focused) }
        if focusOnAppear { field.requestFocus() }
        return field
    }

    func updateNSView(_ field: ChromeNSTextField, context: Context) {
        context.coordinator.parent = self
        field.focusArea = focusArea
        // Only when the model moved out from under the field (the clear button, a launch
        // argument): assigning while typing would put the caret back at the end.
        // Mid-edit it goes to the field editor, which keeps the session (and the keyboard).
        if field.stringValue != text {
            if let editor = field.currentEditor() { editor.string = text } else { field.stringValue = text }
        }
        if context.coordinator.lastRequest != focusRequest {
            context.coordinator.lastRequest = focusRequest
            field.requestFocus()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ChromeTextField
        /// The request already acted on; the one the field was created with counts as acted on,
        /// so an existing request is not replayed when the view is rebuilt.
        var lastRequest: Int

        init(_ parent: ChromeTextField) {
            self.parent = parent
            self.lastRequest = parent.focusRequest
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        /// Return and Escape are answered here, so the field editor never ends editing for them:
        /// an `NSTextField` ends and restarts its session on Return, which would read as the
        /// focus leaving and coming back.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}

/// The `NSTextField` behind `ChromeTextField`: reports focus gained and lost, and takes focus
/// on request even before it is in a window.
final class ChromeNSTextField: NSTextField {
    var onFocusChange: ((Bool) -> Void)?
    /// See `ChromeTextField.focusArea`.
    var focusArea: CGRect?
    private var pendingFocus = false

    func requestFocus() {
        guard let window else { pendingFocus = true; return }
        // Next turn of the run loop: SwiftUI may still be laying the field out, and a field
        // made first responder mid-update can be dropped again by the same update.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window === window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if pendingFocus, window != nil {
            pendingFocus = false
            requestFocus()
        }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    /// The field editor ended its session: the keyboard went somewhere else.
    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange?(false)
    }
}
