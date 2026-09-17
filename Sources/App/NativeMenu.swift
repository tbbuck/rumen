import SwiftUI
import AppKit

/// A pull-down menu as the AppKit control. SwiftUI's `Menu` and menu-style `Picker` on
/// macOS 26 expose no press action to accessibility (the audit's "Action is missing"), so a
/// screen reader cannot open them; `NSPopUpButton` opens, reads and walks with the keyboard,
/// and its items carry real check marks. Text only, in the app's UI face, borderless.
struct NativeMenu: NSViewRepresentable {
    struct Item {
        let title: String
        var checked = false
        var action: (() -> Void)? = nil
        init(_ title: String, checked: Bool = false, action: (() -> Void)? = nil) {
            self.title = title; self.checked = checked; self.action = action
        }
        static var separator: Item { Item("-") }
        var isSeparator: Bool { title == "-" && action == nil }
    }

    let title: String
    var size: CGFloat = 12.5
    var color: NSColor = NSPalette.ink
    let items: [Item]

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = PullDown(frame: .zero, pullsDown: true)
        button.isBordered = false
        button.controlSize = .small
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtCenter
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let font = SheetFonts.ui(size: size) ?? .systemFont(ofSize: size)
        let menu = NSMenu()
        // A pull-down shows its first item as its face.
        let face = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        face.attributedTitle = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: color])
        menu.addItem(face)
        for item in items {
            if item.isSeparator { menu.addItem(.separator()); continue }
            let entry = NSMenuItem(title: item.title, action: #selector(Coordinator.fire(_:)), keyEquivalent: "")
            entry.target = context.coordinator
            entry.representedObject = item.action.map(Action.init)
            entry.state = item.checked ? .on : .off
            menu.addItem(entry)
        }
        button.menu = menu
        button.font = font
        button.isEnabled = context.environment.isEnabled
        (button as? PullDown)?.faceWidth = face.attributedTitle?.size().width ?? 0
        button.invalidateIntrinsicContentSize()
    }

    /// Sized to its face and the arrow, where `NSPopUpButton` would size itself to its widest
    /// item and leave the arrow far from a short face.
    private final class PullDown: NSPopUpButton {
        var faceWidth: CGFloat = 0
        override var intrinsicContentSize: NSSize { NSSize(width: ceil(faceWidth) + 18, height: 18) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        @objc func fire(_ sender: NSMenuItem) { (sender.representedObject as? Action)?.run() }
    }

    /// A closure an `NSMenuItem` can carry.
    final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }
}

extension NativeMenu {
    /// As wide as its face and one text row tall, so it sits on the row's centre line beside
    /// link buttons and text rather than where its own taller cell would put it.
    func inline() -> some View {
        fixedSize(horizontal: true, vertical: false).frame(height: 18)
    }
}
