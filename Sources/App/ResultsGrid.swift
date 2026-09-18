import SwiftUI
import AppKit
import RumenKit

/// A virtualised results grid backed by `NSTableView` (ported from DuckLake Explorer). Headers
/// show the column name over its type; cells are Fira Code; numeric columns right-align;
/// widths default to the content about to be shown, capped so strings cannot run away.
struct ResultsGrid: NSViewRepresentable {
    let grid: QueryGrid

    func makeCoordinator() -> Coordinator { Coordinator(grid: grid) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .sheet(0xF2F4F0, 0x1A2128)                 // bg
        table.gridStyleMask = [.solidHorizontalGridLineMask]
        table.gridColor = .sheet(0xD6DBD2, 0x33404A)                        // line
        table.rowHeight = 24
        table.intercellSpacing = NSSize(width: 8, height: 0)
        table.headerView = SheetHeaderView()
        table.setAccessibilityLabel("Rows")
        table.allowsColumnResizing = true
        table.allowsMultipleSelection = true
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        context.coordinator.table = table
        context.coordinator.rebuildColumns(for: grid)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .sheet(0xF2F4F0, 0x1A2128)
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.grid = grid
        guard let table = scroll.documentView as? NSTableView else { return }
        context.coordinator.rebuildColumns(for: grid)
        table.reloadData()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var grid: QueryGrid
        weak var table: NSTableView?
        private var signature: [String] = []

        init(grid: QueryGrid) { self.grid = grid }

        /// Rebuilds columns only when the shape actually changes (avoids churn on reload).
        func rebuildColumns(for grid: QueryGrid) {
            guard let table else { return }
            let newSignature = grid.columns.map { "\($0.name)|\($0.typeLabel)" }
            guard newSignature != signature else { return }
            signature = newSignature
            for column in table.tableColumns { table.removeTableColumn(column) }
            for (index, column) in grid.columns.enumerated() {
                let tableColumn = NSTableColumn(identifier: .init("c\(index)"))
                // Name + type ride in the cell's own title ("name\ntype"): NSCell copies its
                // built-in title correctly, whereas Swift ivars on an NSCell subclass are
                // bitwise-copied without a retain and double-freed on teardown.
                tableColumn.headerCell = SheetHeaderCell(textCell: "\(column.name)\n\(column.typeLabel)")
                tableColumn.width = Self.width(for: index, in: grid)
                tableColumn.minWidth = 56
                tableColumn.resizingMask = .userResizingMask
                table.addTableColumn(tableColumn)
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { grid.rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let index = Int(tableColumn.identifier.rawValue.dropFirst()),
                  row < grid.rows.count, index < grid.rows[row].count else { return nil }
            let field = tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? NSTextField ?? {
                let textField = NSTextField(labelWithString: "")
                let cell = VCenterTextFieldCell()
                cell.isBordered = false
                cell.drawsBackground = false
                cell.usesSingleLineMode = true
                cell.lineBreakMode = .byTruncatingTail
                textField.cell = cell
                textField.isEditable = false
                textField.isSelectable = false
                textField.identifier = tableColumn.identifier
                textField.font = sheetMonoFont(12)
                return textField
            }()
            let value = grid.rows[row][index]
            let isNull = value == "NULL"
            // Multi-line values (addresses with carriage returns) would otherwise be drawn as a
            // stack of lines squeezed into one row; show the break instead.
            field.stringValue = value.contains(where: \.isNewline)
                ? value.replacingOccurrences(of: "\r\n", with: "↵ ").replacingOccurrences(of: "\r", with: "↵ ").replacingOccurrences(of: "\n", with: "↵ ")
                : value
            field.textColor = isNull ? .sheet(0x646F6B, 0x8C9791) : .sheet(0x222A26, 0xE7EAE6)   // muted2 / ink
            field.alignment = grid.columns[index].isNumeric && !isNull ? .right : .left
            return field
        }

        /// A default width from the header and a sample of the values, capped so long strings
        /// (measured up to 64 chars) cannot run away.
        static func width(for index: Int, in grid: QueryGrid) -> CGFloat {
            let column = grid.columns[index]
            let charW = ("0" as NSString).size(withAttributes: [.font: sheetMonoFont(12)]).width
            var maxChars = max(column.name.count, column.typeLabel.count)
            for r in 0..<min(grid.rows.count, 200) {
                let length = min(grid.rows[r][index].count, 64)
                if length > maxChars { maxChars = length }
            }
            let content = CGFloat(maxChars) * charW + 20
            let cap: CGFloat = column.name == QueryGrid.geometryColumn ? 320 : (column.isNumeric ? 200 : 300)
            return min(max(content, 60), cap)
        }
    }
}

/// A flat, two-line column header: the name over its type. Both ride in the cell's `title`
/// as "name\ntype" — no Swift stored properties on NSCell subclasses (see above).
final class SheetHeaderCell: NSTableHeaderCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard cellFrame.isValidForDrawing else { return }
        NSColor.sheet(0xFAFBF8, 0x212930).setFill()                       // panel
        cellFrame.fill()
        let flipped = controlView.isFlipped
        NSColor.sheet(0xBEC5BA, 0x445362).setFill()                       // line2 along the bottom
        NSRect(x: cellFrame.minX, y: flipped ? cellFrame.maxY - 1 : cellFrame.minY, width: cellFrame.width, height: 1).fill()
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard cellFrame.isValidForDrawing else { return }
        let parts = stringValue.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let name = parts.first.map(String.init) ?? stringValue
        let type = parts.count > 1 ? String(parts[1]) : ""
        let inset: CGFloat = 9
        let width = max(0, cellFrame.width - inset - 6)
        let flipped = controlView.isFlipped
        let nameY = flipped ? cellFrame.minY + 6 : cellFrame.maxY - 21
        let typeY = flipped ? cellFrame.minY + 22 : cellFrame.maxY - 36
        (name as NSString).draw(in: NSRect(x: cellFrame.minX + inset, y: nameY, width: width, height: 15),
                                withAttributes: [.font: sheetMonoFont(11, weight: 500),
                                                 .foregroundColor: NSColor.sheet(0x222A26, 0xE7EAE6)])
        if !type.isEmpty {
            (type as NSString).draw(in: NSRect(x: cellFrame.minX + inset, y: typeY, width: width, height: 14),
                                    withAttributes: [.font: sheetMonoFont(9.5),
                                                     .foregroundColor: NSColor.sheet(0x646F6B, 0x8C9791)])
        }
    }
}

/// The header view, pinned taller for the name-over-type layout.
final class SheetHeaderView: NSTableHeaderView {
    static let height: CGFloat = 40
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(NSSize(width: newSize.width, height: Self.height))
    }
    override var frame: NSRect {
        get { super.frame }
        set { super.frame = NSRect(origin: newValue.origin, size: NSSize(width: newValue.width, height: Self.height)) }
    }
}

/// Fira Code for AppKit views, ligatures off, falling back to the system mono.
private func sheetMonoFont(_ size: CGFloat, weight: Double = 400) -> NSFont {
    SheetFonts.mono(size: size, weight: weight) ?? .monospacedSystemFont(ofSize: size, weight: weight >= 500 ? .medium : .regular)
}

/// A text field cell that vertically centres its single-line text within the row.
final class VCenterTextFieldCell: NSTextFieldCell {
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        let textHeight = cellSize(forBounds: rect).height
        var r = rect
        let delta = (rect.height - textHeight) / 2
        if delta > 0 { r.origin.y += delta; r.size.height -= delta }
        return super.titleRect(forBounds: r)
    }
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: titleRect(forBounds: cellFrame), in: controlView)
    }
}

private extension NSRect {
    /// Guards custom drawing against degenerate / NaN frames during header relayout.
    var isValidForDrawing: Bool {
        width > 1 && height > 1 && origin.x.isFinite && origin.y.isFinite && size.width.isFinite && size.height.isFinite
    }
}

extension NSColor {
    /// Dynamic Day/Night NSColor mirroring the Sheet palette, for AppKit views, with optional
    /// per-appearance alpha.
    static func sheet(_ light: UInt32, _ dark: UInt32, alpha: (Double, Double) = (1, 1)) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: isDark ? alpha.1 : alpha.0)
        }
    }
}
