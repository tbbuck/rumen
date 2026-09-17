import SwiftUI
import AppKit
import ArcGISKit

/// What the outline mirrors from the model, read in SwiftUI so a change reaches `updateNSView`.
struct TreeState: Equatable {
    let version: Int
    let filter: String
    let selection: NodeID?
    let expanded: Set<NodeID>
    let loading: Set<NodeID>
    let errors: [NodeID: String]
    /// Bumped by the model to hand keyboard focus to the tree.
    let focusRequest: Int
}

/// The server tree on `NSOutlineView` (M8): cells are reused, so filtering costs only the
/// visible rows, and arrows, Home and End, type-ahead, and Return-to-open come with it.
/// The row keeps the Sheet look: chevron or spinner, mono layer id, name, kind label, stale
/// caption, locator or error glyph, and the selection rail. The model stays the source of
/// truth for expansion and selection; the outline mirrors it and reports the user's changes.
struct TreeOutline: NSViewRepresentable {
    let model: AppModel
    let state: TreeState

    static let columnID = NSUserInterfaceItemIdentifier("tree")

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = TreeOutlineView()
        outline.headerView = nil
        outline.rowHeight = 27
        outline.intercellSpacing = .zero
        outline.indentationPerLevel = 0
        outline.style = .plain
        outline.backgroundColor = NSPalette.panel
        outline.selectionHighlightStyle = .regular
        outline.allowsEmptySelection = true
        outline.allowsMultipleSelection = false
        outline.allowsTypeSelect = true
        outline.usesAlternatingRowBackgroundColors = false
        outline.focusRingType = .none
        let column = NSTableColumn(identifier: Self.columnID)
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.doubleClicked(_:))
        outline.onReturn = { [weak coordinator = context.coordinator] item in coordinator?.returnPressed(item) }
        context.coordinator.outline = outline

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = true
        scroll.backgroundColor = NSPalette.panel
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 12, right: 0)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.apply(state)
    }

    // MARK: - Coordinator

    /// One stable object per node, so the outline's expansion memory survives a reload.
    final class OutlineItem: NSObject {
        let id: NodeID
        var node: TreeNode
        var children: [OutlineItem] = []
        var indent: CGFloat = 0
        init(id: NodeID, node: TreeNode) {
            self.id = id
            self.node = node
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        unowned let model: AppModel
        weak var outline: TreeOutlineView?
        private var items: [NodeID: OutlineItem] = [:]
        private var roots: [OutlineItem] = []
        private var frameExtent: BoundingBox?
        private var filtering = false
        private var structureKey = ""
        private var appliedExpanded: Set<NodeID> = []
        private var appliedSelection: NodeID?
        private var appliedLoading: Set<NodeID> = []
        private var appliedErrors: [NodeID: String] = [:]
        private var appliedFocusRequest = 0
        /// True while the model's state is being pushed into the outline, so the resulting
        /// notifications are not echoed back to the model.
        private var syncing = false

        init(model: AppModel) { self.model = model }

        func apply(_ state: TreeState) {
            guard let outline else { return }
            if state.focusRequest != appliedFocusRequest {
                appliedFocusRequest = state.focusRequest
                // After the current SwiftUI update, so a text field that just resigned is not re-focused.
                DispatchQueue.main.async { [weak outline] in
                    guard let outline, let window = outline.window else { return }
                    window.makeFirstResponder(outline)
                    if outline.selectedRow < 0, outline.numberOfRows > 0 {
                        outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                    }
                }
            }
            let filtering = !state.filter.trimmingCharacters(in: .whitespaces).isEmpty
            let key = "\(state.version)|\(filtering ? state.filter : "")"
            syncing = true
            defer { syncing = false }
            if key != structureKey {
                structureKey = key
                rebuild(filtering: filtering)
                appliedLoading = state.loading
                appliedErrors = state.errors
                appliedSelection = state.selection
                outline.reloadData()
                if !filtering { syncExpansion(roots, expanded: state.expanded) }
                appliedExpanded = state.expanded
                selectRow(for: state.selection)
                return
            }
            if !filtering, state.expanded != appliedExpanded {
                syncExpansion(roots, expanded: state.expanded)
                appliedExpanded = state.expanded
            }
            if state.selection != appliedSelection {
                appliedSelection = state.selection
                selectRow(for: state.selection)
            }
            if state.loading != appliedLoading || state.errors != appliedErrors {
                var changed = state.loading.symmetricDifference(appliedLoading)
                for id in Set(state.errors.keys).union(appliedErrors.keys) where state.errors[id] != appliedErrors[id] { changed.insert(id) }
                appliedLoading = state.loading
                appliedErrors = state.errors
                reload(items: changed.compactMap { items[$0] })
            }
        }

        /// Rebuilds the item tree from the model, reusing objects by node id.
        private func rebuild(filtering: Bool) {
            self.filtering = filtering
            frameExtent = model.tree?.extent
            var seen = Set<NodeID>()
            func item(for node: TreeNode, indent: CGFloat) -> OutlineItem {
                let existing = items[node.id] ?? OutlineItem(id: node.id, node: node)
                existing.node = node
                existing.indent = indent
                items[node.id] = existing
                seen.insert(node.id)
                return existing
            }
            if filtering {
                roots = model.filteredRows.map { row in
                    let flat = item(for: row.node, indent: row.indent)
                    flat.children = []
                    return flat
                }
            } else {
                func build(_ nodes: [TreeNode]) -> [OutlineItem] {
                    nodes.map { node in
                        let built = item(for: node, indent: AppModel.indentPublic(for: node))
                        built.children = build(node.children)
                        return built
                    }
                }
                roots = build(model.tree?.children ?? [])
                for id in items.keys where !seen.contains(id) { items[id] = nil }
            }
        }

        /// Expands and collapses to match the model, parents before children so the children
        /// exist in the outline when their turn comes.
        private func syncExpansion(_ items: [OutlineItem], expanded: Set<NodeID>) {
            guard let outline else { return }
            for item in items where item.node.isExpandable {
                let wanted = expanded.contains(item.id)
                let current = outline.isItemExpanded(item)
                if wanted, !current { outline.expandItem(item) }
                if !wanted, current { outline.collapseItem(item) }
                if wanted { syncExpansion(item.children, expanded: expanded) }
            }
        }

        private func selectRow(for id: NodeID?) {
            guard let outline else { return }
            let previous = outline.selectedRow
            if let id, let item = items[id], case let row = outline.row(forItem: item), row >= 0 {
                if row != previous {
                    outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    outline.scrollRowToVisible(row)
                }
            } else if previous >= 0 {
                outline.deselectAll(nil)
            }
            reload(rows: [previous, outline.selectedRow])
        }

        private func reload(items: [OutlineItem]) {
            guard let outline else { return }
            reload(rows: items.map { outline.row(forItem: $0) })
        }

        private func reload(rows: [Int]) {
            guard let outline else { return }
            let valid = IndexSet(rows.filter { $0 >= 0 && $0 < outline.numberOfRows })
            if !valid.isEmpty { outline.reloadData(forRowIndexes: valid, columnIndexes: IndexSet(integer: 0)) }
        }

        // MARK: User actions

        func toggle(_ item: OutlineItem) {
            guard let outline, !filtering, item.node.isExpandable else { return }
            if outline.isItemExpanded(item) { outline.collapseItem(item) } else { outline.expandItem(item) }
        }

        @objc func doubleClicked(_ sender: Any?) {
            guard let outline, outline.clickedRow >= 0, let item = outline.item(atRow: outline.clickedRow) as? OutlineItem else { return }
            toggle(item)
        }

        func returnPressed(_ item: Any) {
            guard let item = item as? OutlineItem else { return }
            toggle(item)
        }

        // MARK: Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let item = item as? OutlineItem else { return roots.count }
            return filtering ? 0 : item.children.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let item = item as? OutlineItem else { return roots[index] }
            return item.children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard !filtering, let item = item as? OutlineItem else { return false }
            return item.node.isExpandable
        }

        // MARK: Delegate


        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { 27 }

        func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
            (item as? OutlineItem)?.node.name
        }

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            let view = outlineView.makeView(withIdentifier: TreeRowView.identifier, owner: self) as? TreeRowView ?? TreeRowView()
            view.identifier = TreeRowView.identifier
            return view
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let item = item as? OutlineItem else { return nil }
            let cell = outlineView.makeView(withIdentifier: TreeCellView.identifier, owner: self) as? TreeCellView ?? TreeCellView()
            cell.identifier = TreeCellView.identifier
            cell.configure(item: item, frame: frameExtent, isExpanded: !filtering && outlineView.isItemExpanded(item),
                           isLoading: model.loadingNodes.contains(item.id),
                           error: model.nodeErrors[item.id] ?? item.node.lastError,
                           isSelected: model.selection == item.id, expandable: !filtering && item.node.isExpandable)
            cell.onToggle = { [weak self] in self?.toggle(item) }
            return cell
        }

        func outlineViewItemDidExpand(_ notification: Notification) { disclosureChanged(notification, expanded: true) }
        func outlineViewItemDidCollapse(_ notification: Notification) { disclosureChanged(notification, expanded: false) }

        private func disclosureChanged(_ notification: Notification, expanded: Bool) {
            guard let item = notification.userInfo?["NSObject"] as? OutlineItem else { return }
            reload(items: [item])
            guard !syncing else { return }
            if expanded { appliedExpanded.insert(item.id) } else { appliedExpanded.remove(item.id) }
            let node = item.node
            Task { await model.setExpanded(node, expanded) }
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !syncing, let outline else { return }
            let row = outline.selectedRow
            guard row >= 0, let item = outline.item(atRow: row) as? OutlineItem, item.id != appliedSelection else { return }
            let previous = appliedSelection.flatMap { items[$0] }.map { outline.row(forItem: $0) } ?? -1
            appliedSelection = item.id
            reload(rows: [previous, row])
            let id = item.id
            Task { await model.select(id) }
        }
    }
}

/// Keyboard: Up and Down move the selection (the outline's own), Left collapses the selected
/// node or moves to its parent, Right expands it or moves to its first child, Return and
/// Space toggle it, Home and End jump. The disclosure triangle is ours, not the outline's, so
/// the arrow handling is explicit rather than left to the hidden outline cell. A click takes
/// keyboard focus; a click on empty space keeps the selection.
final class TreeOutlineView: NSOutlineView {
    var onReturn: ((Any) -> Void)?

    /// The disclosure triangle is drawn by the cell, so the outline's own gets no room. (Telling
    /// the delegate not to show it made `collapseItem` a no-op; a zero frame does not.)
    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }

    override func keyDown(with event: NSEvent) {
        let selected = selectedRow >= 0 ? item(atRow: selectedRow) : nil
        switch event.keyCode {
        case 36, 76, 49:   // Return, Enter, Space
            if let selected { onReturn?(selected) }
        case 123:          // Left
            guard let selected else { return }
            if isExpandable(selected), isItemExpanded(selected) {
                collapseItem(selected)
            } else if let parent = parent(forItem: selected) {
                select(row: row(forItem: parent))
            }
        case 124:          // Right
            guard let selected, isExpandable(selected) else { return }
            if isItemExpanded(selected) {
                if numberOfChildren(ofItem: selected) > 0 { select(row: row(forItem: child(0, ofItem: selected))) }
            } else {
                expandItem(selected)
            }
        case 115:          // Home
            select(row: 0)
        case 119:          // End
            select(row: numberOfRows - 1)
        default:
            super.keyDown(with: event)
        }
    }

    private func select(row: Int) {
        guard row >= 0, row < numberOfRows else { return }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        scrollRowToVisible(row)
    }

    override func mouseDown(with event: NSEvent) {
        if row(at: convert(event.locationInWindow, from: nil)) < 0 { return }
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

// MARK: - Row: selection rail and hover

final class TreeRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("TreeRow")
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func prepareForReuse() { super.prepareForReuse(); hovered = false }

    override func drawBackground(in dirtyRect: NSRect) {
        guard hovered, !isSelected else { return }
        NSPalette.hover.setFill()
        bounds.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        NSPalette.accentSoft.setFill()
        bounds.fill()
        NSPalette.accent.setFill()
        NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
    }
}

// MARK: - Cell: the Sheet row, drawn

final class TreeCellView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("TreeCell")
    private var item: TreeOutline.OutlineItem?
    private var frameExtent: BoundingBox?
    private var isExpanded = false
    private var isLoading = false
    private var isSelected = false
    private var expandable = false
    private var error: String?
    private var chevronHovered = false { didSet { if chevronHovered != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?
    private let spinner = NSProgressIndicator()
    var onToggle: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(item: TreeOutline.OutlineItem, frame: BoundingBox?, isExpanded: Bool, isLoading: Bool, error: String?,
                   isSelected: Bool, expandable: Bool) {
        self.item = item
        frameExtent = frame
        self.isExpanded = isExpanded
        self.isLoading = isLoading
        self.error = error
        self.isSelected = isSelected
        self.expandable = expandable
        toolTip = error ?? locatorHelp
        if isLoading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        needsLayout = true
        needsDisplay = true
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        chevronHovered = false
        spinner.stopAnimation(nil)
    }

    // MARK: Layout

    private var indent: CGFloat { item?.indent ?? 0 }
    private var showsID: Bool { !expandable && item?.node.layerID != nil && !isLoading }
    private var slotWidth: CGFloat { showsID ? 14 : 10 }
    private var chevronRect: CGRect { CGRect(x: indent, y: 8.5, width: 10, height: 10) }
    private var chevronHit: CGRect { CGRect(x: indent - 6, y: 0, width: 22, height: 27) }
    private var rightRect: CGRect { CGRect(x: bounds.width - 14 - 22, y: 6, width: 22, height: 15) }

    override func layout() {
        super.layout()
        spinner.frame = CGRect(x: indent - 1, y: 7.5, width: 12, height: 12)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        chevronHovered = expandable && !isLoading && chevronHit.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) { chevronHovered = false }

    override func mouseDown(with event: NSEvent) {
        if expandable, !isLoading, chevronHit.contains(convert(event.locationInWindow, from: nil)) {
            onToggle?()
            return
        }
        super.mouseDown(with: event)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let item else { return }
        let node = item.node
        let dimmed = node.extractable == false

        // Leading slot: chevron, spinner (a subview), or the layer id.
        if isLoading {
            // the spinner draws itself
        } else if expandable {
            if chevronHovered {
                NSPalette.line.setFill()
                NSBezierPath(roundedRect: chevronHit, xRadius: 4, yRadius: 4).fill()
            }
            Self.symbol(isExpanded ? "chevron.down" : "chevron.right", size: 9, weight: .medium,
                        color: chevronHovered ? NSPalette.ink : NSPalette.muted2)?.draw(in: chevronRect)
        } else if showsID, let layerID = node.layerID {
            draw(String(layerID), font: SheetFonts.mono(size: 10.5, weight: 400) ?? .monospacedSystemFont(ofSize: 10.5, weight: .regular),
                 color: NSPalette.muted2, in: CGRect(x: indent, y: 0, width: 14, height: 27), alignment: .right)
        }

        // Trailing: locator or error glyph.
        if error != nil {
            Self.symbol("exclamationmark.circle", size: 11, weight: .regular, color: NSPalette.no)?
                .draw(in: CGRect(x: rightRect.midX - 6.5, y: rightRect.midY - 6.5, width: 13, height: 13))
        } else {
            drawLocator(in: rightRect, extent: node.extent, frame: frameExtent, style: locatorStyle, trusted: node.kind == .folder)
        }

        // Name, then kind label, then the stale caption; the name truncates, the rest never.
        let nameFont = SheetFonts.ui(size: 13, weight: isSelected ? 600 : 400) ?? .systemFont(ofSize: 13, weight: isSelected ? .semibold : .regular)
        let kindFont = SheetFonts.ui(size: 9.5) ?? .systemFont(ofSize: 9.5)
        let staleFont = SheetFonts.ui(size: 10.5) ?? .systemFont(ofSize: 10.5)
        var kind: String?
        if case .service(let type) = node.kind { kind = type.name }
        let stale = Age.isStale(node.fetchedAt) ? "stale" : nil
        let kindWidth = kind.map { Self.width(of: $0, font: kindFont) + 7 } ?? 0
        let staleWidth = stale.map { Self.width(of: $0, font: staleFont) + 7 } ?? 0
        let nameX = indent + slotWidth + 7
        let available = rightRect.minX - 4 - nameX
        let nameWidth = min(Self.width(of: node.name, font: nameFont), max(0, available - kindWidth - staleWidth))
        draw(node.name, font: nameFont, color: dimmed ? NSPalette.muted2 : NSPalette.ink,
             in: CGRect(x: nameX, y: 0, width: nameWidth, height: 27))
        var x = nameX + nameWidth + 7
        if let kind {
            draw(kind, font: kindFont, color: NSPalette.muted2, in: CGRect(x: x, y: 0, width: kindWidth - 7, height: 27))
            x += kindWidth
        }
        if let stale {
            draw(stale, font: staleFont, color: NSPalette.warn, in: CGRect(x: x, y: 0, width: staleWidth - 7, height: 27))
        }
    }

    private var locatorStyle: LocatorStyle {
        guard let node = item?.node else { return .normal }
        switch node.kind {
        case .table: return .table
        default: return node.extractable == false ? .notExtractable : .normal
        }
    }

    private var locatorHelp: String {
        guard let node = item?.node else { return "" }
        switch node.kind {
        case .table: return "A table: no geometry, so no extent."
        default:
            if node.extent == nil { return "No extent known yet; it arrives when the node is crawled." }
            if node.kind != .folder, node.extent?.isDefaultLike == true {
                return "The server reports an extent covering most of the world (or a speck at 0,0), which looks like a default rather than data, so nothing is drawn."
            }
            if node.extractable == false { return "Not extractable; its extent is outlined." }
            return "Extent locator: the frame is where the bulk of this server's data sits; the box is where this \(node.kind == .folder ? "folder" : "node") lies within it. A dot on the edge means it lies outside the frame."
        }
    }

    enum LocatorStyle { case normal, notExtractable, table }

    /// The 22 × 15 locator, as `ExtentLocator` draws it: frame = the server's union extent, box =
    /// this node's; dashed and empty when not extractable; frame only, dashed, for a table.
    private func drawLocator(in rect: CGRect, extent: BoundingBox?, frame: BoundingBox?, style: LocatorStyle, trusted: Bool) {
        let outer = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        outer.lineWidth = 1
        if style == .table { outer.setLineDash([2, 2], count: 2, phase: 0) }
        NSPalette.line2.setStroke()
        outer.stroke()
        guard style != .table, let extent, !extent.isDegenerate, trusted || !extent.isDefaultLike,
              let frame, !frame.isDegenerate else { return }
        let inset: CGFloat = 2.5
        let inner = CGRect(x: rect.minX + inset, y: rect.minY + inset, width: rect.width - 2 * inset, height: rect.height - 2 * inset)
        let sx = inner.width / frame.width
        let sy = inner.height / frame.height
        let raw = CGRect(x: inner.minX + (extent.minX - frame.minX) * sx,
                         y: inner.minY + (frame.maxY - extent.maxY) * sy,
                         width: max(1.5, extent.width * sx), height: max(1.5, extent.height * sy))
        let box = raw.intersection(inner)
        let accent = style == .notExtractable ? NSPalette.muted2 : NSPalette.accent
        if box.isNull || box.width < 1 || box.height < 1 {
            let x = min(max(raw.midX, inner.minX), inner.maxX)
            let y = min(max(raw.midY, inner.minY), inner.maxY)
            accent.setFill()
            NSBezierPath(ovalIn: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3)).fill()
            return
        }
        let path = NSBezierPath(rect: box)
        path.lineWidth = 1
        if style == .notExtractable {
            path.setLineDash([1.5, 1.5], count: 2, phase: 0)
            NSPalette.muted2.setStroke()
            path.stroke()
        } else {
            NSPalette.accentSoft.setFill()
            path.fill()
            NSPalette.accent.setStroke()
            path.stroke()
        }
    }

    // MARK: Text and symbols

    private func draw(_ text: String, font: NSFont, color: NSColor, in rect: CGRect, alignment: NSTextAlignment = .left) {
        guard rect.width > 0 else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = alignment
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        let height = ceil(attributed.size().height)
        let box = CGRect(x: rect.minX, y: rect.minY + (rect.height - height) / 2, width: rect.width, height: height)
        attributed.draw(with: box, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    nonisolated(unsafe) private static var widthCache: [String: CGFloat] = [:]

    private static func width(of text: String, font: NSFont) -> CGFloat {
        let key = "\(font.pointSize)|\(font.fontName)|\(text)"
        if let cached = widthCache[key] { return cached }
        let width = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        if widthCache.count > 20_000 { widthCache.removeAll() }
        widthCache[key] = width
        return width
    }

    nonisolated(unsafe) private static var symbolCache: [String: NSImage] = [:]

    private static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSImage? {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let key = "\(name)|\(size)|\(weight.rawValue)|\(color.description)|\(dark)"
        if let cached = symbolCache[key] { return cached }
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            .applying(.init(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return nil }
        symbolCache[key] = image
        return image
    }
}

/// The Sheet palette for AppKit drawing, mirroring `Palette`.
enum NSPalette {
    static let panel = NSColor.sheet(0xFAFBF8, 0x212930)
    static let line = NSColor.sheet(0xD6DBD2, 0x33404A)
    static let line2 = NSColor.sheet(0xBEC5BA, 0x445362)
    static let ink = NSColor.sheet(0x222A26, 0xE7EAE6)
    static let muted2 = NSColor.sheet(0x8A948E, 0x7B867F)
    static let accent = NSColor.sheet(0xB8236B, 0xEA6AA6)
    static let accentSoft = NSColor.sheet(0xB8236B, 0xEA6AA6, alpha: (0.10, 0.14))
    static let no = NSColor.sheet(0xB3382D, 0xE07A70)
    static let warn = NSColor.sheet(0xB8781F, 0xE2A64B)
    static let hover = NSColor.sheet(0xD6DBD2, 0x33404A, alpha: (0.55, 0.55))
}

