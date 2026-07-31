import Cocoa
import Quartz
import ImageIO
final class FPTableHeaderCell: NSTableHeaderCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let path = NSBezierPath(roundedRect: cellFrame.insetBy(dx: 2, dy: 2), xRadius: 7, yRadius: 7)
        FPStyle.field.withAlphaComponent(0.72).setFill()
        path.fill()

        let title = stringValue as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: FPStyle.text
        ]
        let size = title.size(withAttributes: attributes)
        title.draw(
            in: NSRect(x: cellFrame.minX + 9, y: cellFrame.midY - size.height / 2 - 1, width: cellFrame.width - 18, height: size.height + 2),
            withAttributes: attributes
        )
    }
}

final class SortPillButton: NSButton {
    var ascending = true {
        didSet { needsDisplay = true }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { title }

    override func accessibilityPerformPress() -> Bool {
        performClick(nil)
        return true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 92, height: 26)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        let fill = isHighlighted
            ? NSColor(calibratedRed: 0.190, green: 0.205, blue: 0.232, alpha: 0.98)
            : NSColor(calibratedRed: 0.133, green: 0.146, blue: 0.166, alpha: 0.94)
        fill.setFill()
        path.fill()
        FPStyle.stroke.setStroke()
        path.lineWidth = 0.6
        path.stroke()

        let titleText = (title.isEmpty ? "Имя" : title) as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
            .foregroundColor: FPStyle.orange
        ]
        let textSize = titleText.size(withAttributes: attrs)
        titleText.draw(
            in: NSRect(x: 14, y: (bounds.height - textSize.height) / 2 - 1, width: bounds.width - 42, height: textSize.height + 2),
            withAttributes: attrs
        )

        let chevron = (ascending ? "↑" : "↓") as NSString
        let chevronAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
            .foregroundColor: FPStyle.orange
        ]
        let chevronSize = chevron.size(withAttributes: chevronAttrs)
        chevron.draw(
            in: NSRect(x: bounds.width - chevronSize.width - 13, y: (bounds.height - chevronSize.height) / 2 - 2, width: chevronSize.width, height: chevronSize.height),
            withAttributes: chevronAttrs
        )
    }
}

final class HoverButton: NSButton {
    var onHover: (() -> Void)?
    private var tracking: NSTrackingArea?
    private var hoverWorkItem: DispatchWorkItem?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hoverWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onHover?() }
        hoverWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.38, execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        hoverWorkItem?.cancel()
    }
}

final class FPLongPressButton: NSButton {
    var onLongPress: ((FPLongPressButton) -> Void)?
    private var longPressTimer: Timer?
    private var didTriggerLongPress = false

    override func mouseDown(with event: NSEvent) {
        didTriggerLongPress = false
        longPressTimer?.invalidate()
        let timer = Timer(timeInterval: 0.46, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.didTriggerLongPress = true
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            self.onLongPress?(self)
        }
        longPressTimer = timer
        RunLoop.main.add(timer, forMode: .eventTracking)
        super.mouseDown(with: event)
        timer.invalidate()
        longPressTimer = nil
    }

    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        if didTriggerLongPress {
            didTriggerLongPress = false
            return false
        }
        return super.sendAction(action, to: target)
    }
}

final class FileGridCanvasView: NSView {
    var onMouseDownInGrid: ((NSPoint, NSEvent) -> Void)?
    var onMenuInGrid: ((NSPoint) -> NSMenu?)?
    var onHorizontalSwipe: ((CGFloat) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onMouseDownInGrid?(convert(event.locationInWindow, from: nil), event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onMenuInGrid?(convert(event.locationInWindow, from: nil))
    }

    override func swipe(with event: NSEvent) {
        super.swipe(with: event)
    }
}

final class FileSelectionMarqueeView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = FPStyle.accent.withAlphaComponent(0.13).cgColor
        layer?.borderColor = FPStyle.accent.withAlphaComponent(0.82).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 4
        layer?.shadowColor = FPStyle.accent.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 5
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class FileGridScrollView: NSScrollView, NSDraggingSource {
    var onMouseDownInDocument: ((NSPoint, NSEvent) -> Void)?
    var onMenuInDocument: ((NSPoint) -> NSMenu?)?
    var onHorizontalSwipe: ((CGFloat) -> Void)?
    var onHorizontalSwipeBegan: (() -> Void)?
    var onHorizontalSwipeProgress: ((CGFloat, CGFloat) -> Void)?
    var onHorizontalSwipeCompletion: ((Bool) -> Void)?
    var onDragFromDocument: ((NSPoint) -> [URL])?
    var onDragImageFromDocument: ((NSPoint) -> NSImage?)?
    var onValidateDropInDocument: ((NSPoint, [URL]) -> NSDragOperation)?
    var onDropInDocument: ((NSPoint, [URL]) -> Bool)?
    var onSelectionMarqueeBegan: ((NSPoint, NSEvent) -> Bool)?
    var onSelectionMarqueeChanged: ((NSRect) -> Void)?
    var onSelectionMarqueeEnded: (() -> Void)?
    private var mouseDownDocumentPoint: NSPoint?
    private var didBeginDrag = false
    private var isSelectingWithMarquee = false
    private let horizontalSwipeTracker = HorizontalSwipeTracker()

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if let documentView, hit === contentView || hit === documentView {
            return self
        }
        return hit
    }

    override func mouseDown(with event: NSEvent) {
        guard let documentPoint = documentPoint(for: event) else {
            super.mouseDown(with: event)
            return
        }
        mouseDownDocumentPoint = documentPoint
        didBeginDrag = false
        isSelectingWithMarquee = onSelectionMarqueeBegan?(documentPoint, event) ?? false
        if !isSelectingWithMarquee {
            onMouseDownInDocument?(documentPoint, event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if isSelectingWithMarquee, let startPoint = mouseDownDocumentPoint {
            documentView?.autoscroll(with: event)
            guard let currentPoint = documentPoint(for: event) else { return }
            let selectionRect = NSRect(
                x: min(startPoint.x, currentPoint.x),
                y: min(startPoint.y, currentPoint.y),
                width: abs(currentPoint.x - startPoint.x),
                height: abs(currentPoint.y - startPoint.y)
            )
            onSelectionMarqueeChanged?(selectionRect)
            return
        }
        guard !didBeginDrag,
              let startPoint = mouseDownDocumentPoint,
              let currentPoint = documentPoint(for: event) else {
            super.mouseDragged(with: event)
            return
        }

        let distance = hypot(currentPoint.x - startPoint.x, currentPoint.y - startPoint.y)
        guard distance > 5, let urls = onDragFromDocument?(startPoint), !urls.isEmpty else { return }

        didBeginDrag = true
        beginDraggingSession(with: draggingItems(for: urls, from: startPoint), event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if isSelectingWithMarquee {
            onSelectionMarqueeEnded?()
            isSelectingWithMarquee = false
            mouseDownDocumentPoint = nil
            didBeginDrag = false
            return
        }
        mouseDownDocumentPoint = nil
        didBeginDrag = false
        super.mouseUp(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let documentPoint = documentPoint(for: event) else { return super.menu(for: event) }
        return onMenuInDocument?(documentPoint) ?? super.menu(for: event)
    }

    override func swipe(with event: NSEvent) {
        super.swipe(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        if horizontalSwipeTracker.handle(
            event,
            began: { [weak self] in self?.onHorizontalSwipeBegan?() },
            progress: { [weak self] deltaX, progress in self?.onHorizontalSwipeProgress?(deltaX, progress) },
            completion: { [weak self] committed in self?.onHorizontalSwipeCompletion?(committed) },
            action: { [weak self] deltaX in self?.onHorizontalSwipe?(deltaX) }
        ) {
            return
        }
        super.scrollWheel(with: event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let point = documentPoint(for: sender) else { return false }
        let urls = fileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        return onDropInDocument?(point, urls) ?? false
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : [.copy, .move]
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        false
    }

    private func draggingItems(for urls: [URL], from documentPoint: NSPoint) -> [NSDraggingItem] {
        let windowPoint = documentView?.convert(documentPoint, to: nil) ?? .zero
        let localPoint = convert(windowPoint, from: nil)
        let image = onDragImageFromDocument?(documentPoint)

        return urls.prefix(12).enumerated().map { offset, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let dragImage = image ?? NSWorkspace.shared.icon(forFile: url.path)
            dragImage.size = NSSize(width: 48, height: 48)
            let delta = CGFloat(offset) * 2
            let frame = NSRect(x: localPoint.x - 24 + delta, y: localPoint.y - 24 - delta, width: 48, height: 48)
            item.setDraggingFrame(frame, contents: dragImage)
            return item
        }
    }

    private func dragOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        guard let point = documentPoint(for: sender) else { return [] }
        let urls = fileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return [] }
        return onValidateDropInDocument?(point, urls) ?? []
    }

    private func documentPoint(for event: NSEvent) -> NSPoint? {
        guard let documentView else { return nil }
        return documentView.convert(event.locationInWindow, from: nil)
    }

    private func documentPoint(for draggingInfo: NSDraggingInfo) -> NSPoint? {
        guard let documentView else { return nil }
        return documentView.convert(draggingInfo.draggingLocation, from: nil)
    }
}

final class PanelTableView: NSTableView {
    weak var filePanel: FilePanel?
    private let horizontalSwipeTracker = HorizontalSwipeTracker()

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36:
            filePanel?.openSelection(nil)
        case 51:
            filePanel?.trashSelection(nil)
        case 49:
            filePanel?.quickLookSelection(nil)
        case 53:
            filePanel?.focusSearch()
        case 17 where event.modifierFlags.contains(.command):
            filePanel?.openSelectionInNewTab(nil)
        case 123 where event.modifierFlags.contains(.command):
            filePanel?.navigateHistoryWithWave(goesBack: true)
        case 124 where event.modifierFlags.contains(.command):
            filePanel?.navigateHistoryWithWave(goesBack: false)
        case 126 where event.modifierFlags.contains(.command):
            filePanel?.goUp(nil)
        case 120:
            filePanel?.renameSelection(nil)
        default:
            super.keyDown(with: event)
        }
    }

    override func swipe(with event: NSEvent) {
        super.swipe(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        if horizontalSwipeTracker.handle(
            event,
            began: { [weak self] in self?.filePanel?.beginHorizontalSwipe() },
            progress: { [weak self] deltaX, progress in self?.filePanel?.updateHorizontalSwipe(deltaX: deltaX, progress: progress) },
            completion: { [weak self] committed in self?.filePanel?.finishHorizontalSwipe(committed: committed) },
            action: { [weak self] deltaX in self?.filePanel?.handleHorizontalSwipe(deltaX: deltaX) }
        ) {
            return
        }
        super.scrollWheel(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        if clickedRow >= 0 {
            if !selectedRowIndexes.contains(clickedRow) {
                selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
            }
        }
        filePanel?.activate()
        return filePanel?.contextMenu()
    }
}

final class PanelCollectionView: NSCollectionView {
    weak var filePanel: FilePanel?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let indexPath = indexPathForItem(at: point) {
            selectionIndexes = IndexSet(integer: indexPath.item)
            filePanel?.activate()
            if event.clickCount >= 2 {
                filePanel?.openSelection(nil)
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36:
            filePanel?.openSelection(nil)
        case 51:
            filePanel?.trashSelection(nil)
        case 49:
            filePanel?.quickLookSelection(nil)
        case 53:
            filePanel?.focusSearch()
        case 17 where event.modifierFlags.contains(.command):
            filePanel?.openSelectionInNewTab(nil)
        case 123 where event.modifierFlags.contains(.command):
            filePanel?.navigateHistoryWithWave(goesBack: true)
        case 124 where event.modifierFlags.contains(.command):
            filePanel?.navigateHistoryWithWave(goesBack: false)
        case 126 where event.modifierFlags.contains(.command):
            filePanel?.goUp(nil)
        case 120:
            filePanel?.renameSelection(nil)
        default:
            super.keyDown(with: event)
        }
    }

    override func swipe(with event: NSEvent) {
        super.swipe(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let indexPath = indexPathForItem(at: point), !selectionIndexes.contains(indexPath.item) {
            selectionIndexes = IndexSet(integer: indexPath.item)
        }
        filePanel?.activate()
        return filePanel?.contextMenu()
    }
}

final class PanelRowView: NSTableRowView {
    var rowColor: NSColor = FPStyle.rowA

    override func drawBackground(in dirtyRect: NSRect) {
        rowColor.setFill()
        dirtyRect.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 7, dy: 2.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        FPStyle.rowSelection.setFill()
        path.fill()
        // Тонкая светящаяся рамка: заметнее сверху, мягче снизу — даёт
        // ощущение объёма без тяжёлого сплошного контура.
        FPStyle.accent.withAlphaComponent(0.52).setStroke()
        let strokePath = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 9.5, yRadius: 9.5)
        strokePath.lineWidth = 1
        strokePath.stroke()
    }
}

extension NSUserInterfaceItemIdentifier {
    static let fileGridItem = NSUserInterfaceItemIdentifier("FileGridItem")
}

@objc(FPFileGridItem)
final class FileGridItem: NSCollectionViewItem {
    private let previewImageView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let kindField = NSTextField(labelWithString: "")

    override var isSelected: Bool {
        didSet { updateSelection() }
    }

    override func loadView() {
        let root = FPLayerView(color: NSColor.clear, cornerRadius: 14)
        root.layer?.masksToBounds = true
        view = root

        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        previewImageView.imageScaling = .scaleProportionallyUpOrDown
        previewImageView.wantsLayer = true
        previewImageView.layer?.cornerRadius = 10
        previewImageView.layer?.masksToBounds = true

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.alignment = .center
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.maximumNumberOfLines = 2
        titleField.cell?.lineBreakMode = .byTruncatingMiddle
        titleField.cell?.wraps = true
        titleField.cell?.truncatesLastVisibleLine = true
        titleField.font = .systemFont(ofSize: 12, weight: .medium)
        titleField.textColor = FPStyle.text

        kindField.translatesAutoresizingMaskIntoConstraints = false
        kindField.alignment = .center
        kindField.lineBreakMode = .byTruncatingMiddle
        kindField.font = .systemFont(ofSize: 10, weight: .regular)
        kindField.textColor = FPStyle.dimText

        view.addSubview(previewImageView)
        view.addSubview(titleField)
        view.addSubview(kindField)

        NSLayoutConstraint.activate([
            previewImageView.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            previewImageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            titleField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            titleField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            titleField.topAnchor.constraint(equalTo: previewImageView.bottomAnchor, constant: 6),
            titleField.heightAnchor.constraint(equalToConstant: 38),
            kindField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            kindField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            kindField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 1),
            kindField.heightAnchor.constraint(equalToConstant: 14)
        ])
    }

    func configure(item: FileItem, image: NSImage, imageSize: CGFloat) {
        previewImageView.image = image
        titleField.stringValue = item.name
        titleField.textColor = item.isHidden ? .tertiaryLabelColor : FPStyle.text
        kindField.stringValue = item.isDirectory ? "Папка" : item.kind
        NSLayoutConstraint.deactivate(previewImageView.constraints.filter { $0.firstAttribute == .width || $0.firstAttribute == .height })
        previewImageView.widthAnchor.constraint(equalToConstant: imageSize).isActive = true
        previewImageView.heightAnchor.constraint(equalToConstant: imageSize).isActive = true
        updateSelection()
    }

    private func updateSelection() {
        view.layer?.backgroundColor = (isSelected ? FPStyle.rowSelection : NSColor.clear).cgColor
        view.layer?.borderColor = (isSelected ? FPStyle.accent.withAlphaComponent(0.55) : NSColor.clear).cgColor
        view.layer?.borderWidth = isSelected ? 1 : 0
    }
}

final class FileGridCellView: FPLayerView, NSDraggingSource {
    private let previewImageView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let kindField = NSTextField(labelWithString: "")
    /// Звёздочка «отобрано» в углу миниатюры.
    private let flagBadge = FPSelectedFlagBadge()
    private var previewWidthConstraint: NSLayoutConstraint!
    private var previewHeightConstraint: NSLayoutConstraint!
    private var mouseDownPoint: NSPoint?
    private var defersExclusiveSelection = false
    private var hoverTrackingArea: NSTrackingArea?
    private var isHoveredState = false
    private var isSelectedState = false
    private var isCutState = false
    private var representedPath: String?
    var itemIndex = 0
    var onSelect: ((Int, Bool, Bool) -> Void)?
    var shouldPreserveSelectionForDrag: ((Int) -> Bool)?
    var onOpen: (() -> Void)?
    var onMenu: (() -> NSMenu?)?
    var onDrag: ((Int) -> [URL])?
    var onToggleFlag: ((Int) -> Void)?

    init() {
        super.init(
            color: NSColor.clear,
            cornerRadius: FPStyle.isCyberEditorial ? 5 : 14
        )
        translatesAutoresizingMaskIntoConstraints = true
        // masksToBounds выключен, чтобы мягкое свечение выделенной ячейки
        // не обрезалось; скругление фона задаёт cornerRadius самого слоя.
        layer?.masksToBounds = false
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        buildUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0, bounds.contains(point) else { return nil }
        // Вся плитка — одна цель для выделения и перетаскивания, поэтому
        // клики забираются на себя. Звёздочка единственное исключение: без
        // него отметку мышью поставить нельзя, клик уходил в выделение.
        if !flagBadge.isHidden, flagBadge.frame.contains(point) {
            return flagBadge
        }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { titleField.stringValue }

    override func accessibilityPerformPress() -> Bool {
        onSelect?(itemIndex, false, false)
        onOpen?()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        let extendsSelection = event.modifierFlags.contains(.command)
        let selectsRange = event.modifierFlags.contains(.shift)
        defersExclusiveSelection = !extendsSelection && !selectsRange &&
            (shouldPreserveSelectionForDrag?(itemIndex) ?? false)
        if !defersExclusiveSelection {
            onSelect?(itemIndex, extendsSelection, selectsRange)
        }
        if event.clickCount >= 2 {
            playOpenPulse()
            let open = onOpen
            DispatchQueue.main.async {
                open?()
            }
            mouseDownPoint = nil
            defersExclusiveSelection = false
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setPointerHover(true)
    }

    override func mouseExited(with event: NSEvent) {
        setPointerHover(false)
    }

    func setPointerHover(_ hovered: Bool, animated: Bool = true) {
        guard hovered != isHoveredState else { return }
        isHoveredState = hovered
        updateFlagBadgeVisibility()
        applyChrome(animated: animated)
        animateIconScale(hovered ? 1.05 : 1.0, animated: animated)
    }

    /// Отмеченные файлы носят звёздочку всегда, остальные показывают её
    /// только под курсором: иначе сетка рябит от значков на каждой плитке.
    private func updateFlagBadgeVisibility() {
        flagBadge.isHidden = !(flagBadge.isFlagged || isHoveredState)
    }

    // Лёгкий «подъём» иконки при наведении: масштаб считается вокруг центра
    // превью через явную CABasicAnimation, чтобы не трогать anchorPoint слоя,
    // которым управляет AppKit.
    private func animateIconScale(_ scale: CGFloat, animated: Bool = true) {
        guard let iconLayer = previewImageView.layer else { return }
        let size = previewImageView.bounds.size
        guard size.width > 1, size.height > 1 else { return }
        let transform: CATransform3D
        if abs(scale - 1) < 0.001 {
            transform = CATransform3DIdentity
        } else {
            var lift = CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0)
            lift = CATransform3DScale(lift, scale, scale, 1)
            lift = CATransform3DTranslate(lift, -size.width / 2, -size.height / 2, 0)
            transform = lift
        }
        if !animated {
            iconLayer.removeAnimation(forKey: "hoverScale")
            iconLayer.transform = transform
            return
        }
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = iconLayer.presentation()?.transform ?? iconLayer.transform
        animation.toValue = transform
        animation.duration = 0.19
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.20, 0.80, 0.30, 1.0)
        iconLayer.transform = transform
        iconLayer.add(animation, forKey: "hoverScale")
    }

    // Короткая вспышка подтверждения при открытии файла или папки —
    // только presentation-анимация, модельное состояние ячейки не меняется.
    private func playOpenPulse() {
        guard let hostLayer = layer else { return }
        let flash = CABasicAnimation(keyPath: "backgroundColor")
        flash.fromValue = FPStyle.accent.withAlphaComponent(0.30).cgColor
        flash.toValue = hostLayer.backgroundColor
        flash.duration = 0.34
        flash.timingFunction = CAMediaTimingFunction(name: .easeOut)
        hostLayer.add(flash, forKey: "openPulse")
    }

    override func mouseDragged(with event: NSEvent) {
        if let mouseDownPoint {
            let point = convert(event.locationInWindow, from: nil)
            let dx = point.x - mouseDownPoint.x
            let dy = point.y - mouseDownPoint.y
            guard hypot(dx, dy) >= 6 else { return }
        }
        mouseDownPoint = nil
        defersExclusiveSelection = false

        let urls = onDrag?(itemIndex) ?? []
        guard !urls.isEmpty else { return }

        let dragImage = previewImageView.image ?? NSWorkspace.shared.icon(forFile: urls[0].path)
        let draggingItems = urls.enumerated().map { offset, url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let frame = previewImageView.frame.offsetBy(dx: CGFloat(offset) * 4, dy: -CGFloat(offset) * 4)
            item.setDraggingFrame(frame, contents: dragImage)
            return item
        }
        beginDraggingSession(with: draggingItems, event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if defersExclusiveSelection {
            onSelect?(itemIndex, false, false)
        }
        defersExclusiveSelection = false
        mouseDownPoint = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : [.copy, .move]
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onSelect?(itemIndex, false, false)
        return onMenu?()
    }

    private func buildUI() {
        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        previewImageView.imageScaling = .scaleProportionallyUpOrDown
        previewImageView.wantsLayer = true
        previewImageView.layer?.cornerRadius = FPStyle.isCyberEditorial ? 4 : 10
        previewImageView.layer?.masksToBounds = true

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.alignment = .center
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.maximumNumberOfLines = 2
        titleField.cell?.lineBreakMode = .byTruncatingMiddle
        titleField.cell?.wraps = true
        titleField.cell?.truncatesLastVisibleLine = true
        titleField.font = FPStyle.bodyFont(
            ofSize: 12,
            weight: FPStyle.isCyberEditorial ? .semibold : .medium
        )
        titleField.textColor = FPStyle.text

        kindField.translatesAutoresizingMaskIntoConstraints = false
        kindField.alignment = .center
        kindField.lineBreakMode = .byTruncatingMiddle
        kindField.font = FPStyle.isCyberEditorial
            ? .monospacedSystemFont(ofSize: 9.5, weight: .medium)
            : .systemFont(ofSize: 10.5, weight: .medium)
        kindField.textColor = FPStyle.dimText.withAlphaComponent(0.88)

        flagBadge.translatesAutoresizingMaskIntoConstraints = false
        flagBadge.isHidden = true
        flagBadge.onToggle = { [weak self] in
            guard let self else { return }
            self.onToggleFlag?(self.itemIndex)
        }

        addSubview(previewImageView)
        addSubview(titleField)
        addSubview(kindField)
        addSubview(flagBadge)

        previewWidthConstraint = previewImageView.widthAnchor.constraint(equalToConstant: 64)
        previewHeightConstraint = previewImageView.heightAnchor.constraint(equalToConstant: 64)

        NSLayoutConstraint.activate([
            previewImageView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            previewImageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            previewWidthConstraint,
            previewHeightConstraint,
            // Правый верхний угол миниатюры: не перекрывает ни подпись, ни
            // цветной кружок метки, который живёт слева.
            flagBadge.trailingAnchor.constraint(equalTo: previewImageView.trailingAnchor, constant: 3),
            flagBadge.topAnchor.constraint(equalTo: previewImageView.topAnchor, constant: -3),
            flagBadge.widthAnchor.constraint(equalToConstant: 18),
            flagBadge.heightAnchor.constraint(equalToConstant: 18),
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            titleField.topAnchor.constraint(equalTo: previewImageView.bottomAnchor, constant: 4),
            titleField.heightAnchor.constraint(equalToConstant: 34),
            kindField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            kindField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            kindField.topAnchor.constraint(equalTo: titleField.bottomAnchor),
            kindField.heightAnchor.constraint(equalToConstant: 14)
        ])
    }

    func configure(item: FileItem, image: NSImage, imageSize: CGFloat, selected: Bool, cut: Bool) {
        let path = item.url.standardizedFileURL.path
        let replacesPlaceholder = representedPath == path && previewImageView.image !== image
        if replacesPlaceholder,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.14
            transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
            previewImageView.layer?.add(transition, forKey: "thumbnailSwap")
        } else {
            previewImageView.layer?.removeAnimation(forKey: "thumbnailSwap")
        }
        previewImageView.image = image
        representedPath = path
        titleField.stringValue = item.name
        titleField.textColor = item.isHidden ? .tertiaryLabelColor : FPStyle.text
        titleField.font = FPStyle.bodyFont(
            ofSize: 12,
            weight: FPStyle.isCyberEditorial ? .semibold : .medium
        )
        kindField.font = FPStyle.isCyberEditorial
            ? .monospacedSystemFont(ofSize: 9.5, weight: .medium)
            : .systemFont(ofSize: 10.5, weight: .medium)
        // Разрешение читается из заголовка файла в фоне: в папке на полторы
        // тысячи объектов синхронный разбор подвесил бы прокрутку. Пока оно
        // едет, подпись показывает то же, что и раньше, без прыжков высоты.
        let cachedMedia = FPMediaInfoCache.cached(for: item.url, modified: item.modified)
        kindField.stringValue = FPTileCaption.text(for: item, media: cachedMedia)
        if cachedMedia == nil, !item.isDirectory {
            FPMediaInfoCache.load(for: item.url, modified: item.modified) { [weak self] info in
                guard let self, self.representedPath == path else { return }
                self.kindField.stringValue = FPTileCaption.text(for: item, media: info)
            }
        }
        flagBadge.isFlagged = FPFinderTagStore.isFlagged(item.finderTags ?? [])
        updateFlagBadgeVisibility()
        toolTip = hoverTooltip(for: item)
        setAccessibilityLabel(item.name)
        setAccessibilityHelp(item.isDirectory ? "Открыть папку" : "Открыть файл")
        // The preview slot must never change geometry after an asynchronous
        // thumbnail arrives. NSImageView keeps the real image aspect ratio
        // inside this stable square, so titles and every following row stay
        // in exactly the same position as they had with the placeholder icon.
        previewWidthConstraint.constant = imageSize
        previewHeightConstraint.constant = imageSize
        // Переиспользованная ячейка обязана начинать с чистого состояния:
        // без hover-подсветки, без наследованных анимаций и масштаба иконки.
        isHoveredState = false
        isSelectedState = selected
        isCutState = cut
        alphaValue = cut ? 0.42 : 1
        previewImageView.layer?.removeAnimation(forKey: "hoverScale")
        previewImageView.layer?.transform = CATransform3DIdentity
        layer?.removeAnimation(forKey: "openPulse")
        applyChrome(animated: false)
    }

    func setCut(_ cut: Bool, animated: Bool = true) {
        guard isCutState != cut else { return }
        isCutState = cut
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = cut ? 0.42 : 1
            }
        } else {
            alphaValue = cut ? 0.42 : 1
        }
    }

    private func hoverTooltip(for item: FileItem) -> String? {
        let availableWidth = max(42, bounds.width - 16)
        guard titleIsTruncated(item.name, availableWidth: availableWidth) else { return nil }
        if item.isDirectory {
            return item.name
        }
        let size = ByteCountFormatter.string(fromByteCount: item.size ?? 0, countStyle: .file)
        return "\(item.name)\nРазмер: \(size)"
    }

    private func titleIsTruncated(_ title: String, availableWidth: CGFloat) -> Bool {
        let font = titleField.font ?? .systemFont(ofSize: 12, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let singleLineWidth = (title as NSString).size(withAttributes: attrs).width
        if singleLineWidth > availableWidth * 1.82 {
            return true
        }
        let rect = (title as NSString).boundingRect(
            with: NSSize(width: availableWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        )
        return rect.height > 34
    }

    func setSelected(_ selected: Bool) {
        guard isSelectedState != selected else {
            applyChrome(animated: false)
            return
        }
        isSelectedState = selected
        applyChrome(animated: true)
    }

    // Единая отрисовка «хрома» ячейки: выделение и hover собраны в одном месте,
    // выделенная ячейка получает мягкое свечение акцентного цвета.
    private func applyChrome(animated: Bool) {
        let background: NSColor
        let border: NSColor
        let borderWidth: CGFloat
        if isSelectedState {
            background = FPStyle.rowSelection
            border = FPStyle.accent.withAlphaComponent(0.62)
            borderWidth = 1
        } else if isHoveredState {
            background = NSColor(calibratedWhite: 1.0, alpha: 0.055)
            border = NSColor(calibratedWhite: 1.0, alpha: 0.09)
            borderWidth = 1
        } else {
            background = .clear
            border = .clear
            borderWidth = 0
        }
        let apply = { [self] in
            layer?.backgroundColor = background.cgColor
            layer?.borderColor = border.cgColor
            layer?.borderWidth = borderWidth
            layer?.shadowColor = FPStyle.accent.cgColor
            layer?.shadowOpacity = isSelectedState ? 0.22 : 0
            layer?.shadowRadius = 8
            layer?.shadowOffset = .zero
        }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                context.allowsImplicitAnimation = true
                apply()
            }
        } else {
            apply()
        }
    }
}

final class GridSectionHeaderView: FPLayerView {
    private let titleField = NSTextField(labelWithString: "")
    private let toggleButton = NSButton()
    private let separator = CALayer()
    var sectionID = ""
    var onToggle: ((String) -> Void)?

    init() {
        super.init(color: NSColor.clear)
        translatesAutoresizingMaskIntoConstraints = true

        titleField.font = FPStyle.headingFont(
            ofSize: FPStyle.isCyberEditorial ? 14 : 13,
            weight: .semibold
        )
        titleField.textColor = FPStyle.text
        titleField.translatesAutoresizingMaskIntoConstraints = false

        toggleButton.isBordered = false
        toggleButton.bezelStyle = .inline
        toggleButton.alignment = .right
        toggleButton.font = FPStyle.bodyFont(ofSize: 11.5, weight: .semibold)
        toggleButton.contentTintColor = FPStyle.orange
        toggleButton.target = self
        toggleButton.action = #selector(togglePressed(_:))
        toggleButton.translatesAutoresizingMaskIntoConstraints = false

        separator.backgroundColor = FPStyle.stroke.withAlphaComponent(0.7).cgColor
        layer?.addSublayer(separator)
        addSubview(titleField)
        addSubview(toggleButton)

        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggleButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            toggleButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggleButton.leadingAnchor.constraint(greaterThanOrEqualTo: titleField.trailingAnchor, constant: 12)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        separator.frame = NSRect(x: 12, y: 0, width: max(0, bounds.width - 24), height: 1)
    }

    func configure(id: String, title: String, totalCount: Int, expanded: Bool, canToggle: Bool) {
        sectionID = id
        titleField.stringValue = FPStyle.isCyberEditorial ? title.uppercased() : title
        titleField.textColor = FPStyle.text
        titleField.font = FPStyle.headingFont(
            ofSize: FPStyle.isCyberEditorial ? 14 : 13,
            weight: .semibold
        )
        toggleButton.isHidden = !canToggle
        let buttonTitle = expanded ? "Показать меньше" : "Показать все (\(totalCount))"
        toggleButton.attributedTitle = NSAttributedString(
            string: buttonTitle,
            attributes: [
                .font: FPStyle.bodyFont(ofSize: 11.5, weight: .semibold),
                .foregroundColor: FPStyle.orange
            ]
        )
        toggleButton.contentTintColor = FPStyle.orange
        separator.backgroundColor = FPStyle.stroke.withAlphaComponent(0.7).cgColor
    }

    @objc private func togglePressed(_ sender: Any?) {
        onToggle?(sectionID)
    }
}

final class FileInspectorController: NSWindowController {
    private let iconView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let detailsStack = NSStackView()
    private var inspectedItems: [FileItem] = []
    private weak var calculatedSizeField: NSTextField?
    private weak var calculateSizeButton: NSButton?
    private var sizeCalculationGeneration = 0

    init() {
        let panel = EscapeClosingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 500),
            styleMask: [.titled, .closable, .utilityWindow, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Свойства"
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.minSize = NSSize(width: 360, height: 380)
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init(window: panel)
        buildUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(items: [FileItem]) {
        guard !items.isEmpty else { return }
        inspectedItems = items
        sizeCalculationGeneration += 1
        configure(items: items)
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func calculateFolderSizes() {
        startFolderSizeCalculation(nil)
    }

    private func buildUI() {
        guard let window else { return }
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = effect

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 12
        iconView.layer?.masksToBounds = true
        nameField.font = .systemFont(ofSize: 17, weight: .semibold)
        nameField.textColor = FPStyle.text
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.alignment = .center

        detailsStack.orientation = .vertical
        detailsStack.alignment = .width
        detailsStack.spacing = 9
        detailsStack.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [iconView, nameField, detailsStack])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 44, left: 24, bottom: 22, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: effect.bottomAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 92),
            iconView.heightAnchor.constraint(equalToConstant: 92),
            nameField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
            detailsStack.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48)
        ])
    }

    private func configure(items: [FileItem]) {
        calculatedSizeField = nil
        calculateSizeButton = nil
        for view in detailsStack.arrangedSubviews {
            detailsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if items.count > 1 {
            nameField.stringValue = "Выбрано объектов: \(items.count)"
            iconView.image = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: nil)
            let files = items.filter { !$0.isDirectory }
            let folders = items.count - files.count
            let totalSize = files.compactMap(\.size).reduce(0, +)
            addDetail("Файлы", "\(files.count)")
            addDetail("Папки", "\(folders)")
            if folders > 0 {
                addCalculatedSizeDetail(knownFileBytes: totalSize)
            } else {
                addDetail("Размер файлов", ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))
            }
            return
        }

        let item = items[0]
        nameField.stringValue = item.name
        if item.isDirectory, let custom = CustomFolderIconStore.shared.image(for: item.url) {
            iconView.image = custom
        } else {
            iconView.image = NSWorkspace.shared.icon(forFile: item.url.path)
        }
        addDetail("Тип", item.kind)
        if item.isDirectory {
            addCalculatedSizeDetail(knownFileBytes: 0)
        } else {
            addDetail("Размер", ByteCountFormatter.string(fromByteCount: item.size ?? 0, countStyle: .file))
        }
        addDetail("Создан", formatted(item.created))
        addDetail("Изменён", formatted(item.modified))
        if let dimensions = imageDimensions(item.url) {
            addDetail("Размер изображения", "\(dimensions.width) × \(dimensions.height) px")
        }
        addDetail("Путь", item.url.path, selectable: true)
    }

    private func addCalculatedSizeDetail(knownFileBytes: Int64) {
        let titleField = NSTextField(labelWithString: "Размер")
        titleField.font = .systemFont(ofSize: 11.5, weight: .medium)
        titleField.textColor = FPStyle.dimText
        titleField.widthAnchor.constraint(equalToConstant: 118).isActive = true

        let valueField = NSTextField(labelWithString: knownFileBytes > 0
            ? "\(ByteCountFormatter.string(fromByteCount: knownFileBytes, countStyle: .file)) + папки"
            : "Не посчитан")
        valueField.font = .systemFont(ofSize: 12, weight: .regular)
        valueField.textColor = FPStyle.text
        valueField.lineBreakMode = .byTruncatingMiddle

        let button = NSButton(title: "Посчитать", target: self, action: #selector(startFolderSizeCalculation(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11.5, weight: .semibold)
        button.contentTintColor = FPStyle.orange

        let row = NSStackView(views: [titleField, valueField, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        detailsStack.addArrangedSubview(row)
        calculatedSizeField = valueField
        calculateSizeButton = button
    }

    @objc private func startFolderSizeCalculation(_ sender: Any?) {
        let folders = inspectedItems.filter(\.isDirectory).map(\.url)
        guard !folders.isEmpty else { return }
        let knownFileBytes = inspectedItems.filter { !$0.isDirectory }.compactMap(\.size).reduce(0, +)
        sizeCalculationGeneration += 1
        let generation = sizeCalculationGeneration
        calculatedSizeField?.stringValue = "Считаю…"
        calculateSizeButton?.isEnabled = false
        calculateSizeButton?.title = "…"
        FPDirectorySizeCalculator.calculate(urls: folders) { [weak self] result in
            guard let self, self.sizeCalculationGeneration == generation else { return }
            self.calculateSizeButton?.isEnabled = true
            self.calculateSizeButton?.title = "Пересчитать"
            switch result {
            case .success(let folderBytes):
                self.calculatedSizeField?.stringValue = ByteCountFormatter.string(
                    fromByteCount: knownFileBytes + folderBytes,
                    countStyle: .file
                )
            case .failure(let error):
                self.calculatedSizeField?.stringValue = "Ошибка"
                self.window?.presentError(error)
            }
        }
    }

    private func addDetail(_ title: String, _ value: String, selectable: Bool = false) {
        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 11.5, weight: .medium)
        titleField.textColor = FPStyle.dimText
        titleField.widthAnchor.constraint(equalToConstant: 118).isActive = true
        let valueField = selectable ? NSTextField(string: value) : NSTextField(labelWithString: value)
        valueField.font = .systemFont(ofSize: 12, weight: .regular)
        valueField.textColor = FPStyle.text
        valueField.lineBreakMode = .byTruncatingMiddle
        valueField.isBordered = false
        valueField.drawsBackground = false
        valueField.isEditable = false
        valueField.isSelectable = selectable
        let row = NSStackView(views: [titleField, valueField])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 10
        detailsStack.addArrangedSubview(row)
    }

    private func formatted(_ date: Date?) -> String {
        guard let date else { return "-" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func imageDimensions(_ url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }
}

/// Звёздочка «отобрано» в углу миниатюры.
///
/// Рисуется вручную, а не иконкой SF Symbols: нужен контрастный кружок под
/// звездой, иначе на светлых кадрах отметка теряется. Цвет берётся из темы,
/// поэтому значок следует за палитрой проводника.
final class FPSelectedFlagBadge: NSView {
    /// Отмечен ли файл. Когда нет — значок показывается только под курсором
    /// и приглушённо, чтобы сетка не рябила от звёздочек.
    var isFlagged = false {
        didSet { needsDisplay = true }
    }
    var onToggle: (() -> Void)?

    override var wantsUpdateLayer: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        onToggle?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 1, dy: 1)
        let circle = NSBezierPath(ovalIn: inset)

        NSColor.black.withAlphaComponent(isFlagged ? 0.55 : 0.42).setFill()
        NSBezierPath(ovalIn: bounds).fill()
        (isFlagged ? FPStyle.orange : NSColor.white.withAlphaComponent(0.34)).setFill()
        circle.fill()

        let star = NSBezierPath()
        let center = NSPoint(x: inset.midX, y: inset.midY)
        let outer = inset.width * 0.34
        let inner = outer * 0.42
        for step in 0..<10 {
            let radius = step % 2 == 0 ? outer : inner
            let angle = .pi / 2 + CGFloat(step) * .pi / 5
            let point = NSPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
            step == 0 ? star.move(to: point) : star.line(to: point)
        }
        star.close()
        NSColor.black.withAlphaComponent(isFlagged ? 0.82 : 0.55).setFill()
        star.fill()
    }
}

final class FolderPocketItemView: FPLayerView, NSDraggingSource {
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private var mouseDownPoint: NSPoint?
    let url: URL
    let isDirectory: Bool
    var onOpen: ((URL, Bool) -> Void)?

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
        super.init(color: NSColor.clear, cornerRadius: 9)
        translatesAutoresizingMaskIntoConstraints = false
        layer?.borderColor = FPStyle.stroke.cgColor
        layer?.borderWidth = 0.5
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func buildUI() {
        iconView.image = NSWorkspace.shared.icon(forFile: url.path)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        titleField.stringValue = url.lastPathComponent
        titleField.font = .systemFont(ofSize: 10.5, weight: .medium)
        titleField.textColor = FPStyle.text
        titleField.alignment = .center
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.toolTip = url.lastPathComponent
        titleField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        addSubview(titleField)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 104),
            heightAnchor.constraint(equalToConstant: 118),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            titleField.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 7),
            titleField.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        layer?.backgroundColor = FPStyle.rowSelection.cgColor
        if event.clickCount >= 2 { onOpen?(url, isDirectory) }
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) >= 5 else { return }
        mouseDownPoint = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(iconView.frame, contents: iconView.image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

final class FolderPocketController: NSWindowController {
    private weak var parentView: NSView?
    private var currentURL: URL?
    private var history: [URL] = []
    private var historyIndex = -1
    var onClose: (() -> Void)?

    var isVisible: Bool { window?.isVisible == true }

    init(parentView: NSView) {
        self.parentView = parentView
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 190),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init(window: panel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(folder: URL) {
        if !isVisible {
            history = [folder]
            historyIndex = 0
        }
        currentURL = folder
        buildContent(folder: folder)
        reposition()
        if let parent = parentView?.window, let panel = window {
            parent.addChildWindow(panel, ordered: .above)
        }
        window?.orderFront(nil)
    }

    func toggle(folder: URL) {
        if isVisible {
            closePocket()
        } else {
            show(folder: folder)
        }
    }

    func follow(folder: URL) {
        guard isVisible, currentURL?.standardizedFileURL != folder.standardizedFileURL else { return }
        history = [folder]
        historyIndex = 0
        currentURL = folder
        buildContent(folder: folder)
        reposition()
    }

    private func openNested(_ folder: URL) {
        if historyIndex + 1 < history.count {
            history.removeSubrange((historyIndex + 1)..<history.count)
        }
        history.append(folder)
        historyIndex = history.count - 1
        currentURL = folder
        buildContent(folder: folder)
    }

    func reposition() {
        guard let parentView, let parentWindow = parentView.window, let panel = window else { return }
        let localRect = parentView.convert(parentView.bounds, to: nil)
        let screenRect = parentWindow.convertToScreen(localRect)
        let width = max(420, min(screenRect.width - 32, 920))
        panel.setFrame(NSRect(x: screenRect.midX - width / 2, y: screenRect.minY + 28, width: width, height: 190), display: true)
    }

    func closePocket() {
        if let parent = window?.parent, let panel = window { parent.removeChildWindow(panel) }
        window?.orderOut(nil)
        onClose?()
    }

    private func buildContent(folder: URL) {
        guard let panel = window else { return }
        let root = NSVisualEffectView()
        root.material = .hudWindow
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 16
        root.layer?.masksToBounds = true
        root.layer?.borderColor = FPStyle.accent.withAlphaComponent(0.55).cgColor
        root.layer?.borderWidth = 1

        let back = NSButton(title: "", target: self, action: #selector(goBack(_:)))
        back.isBordered = false
        back.bezelStyle = .inline
        back.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Назад")
        back.contentTintColor = FPStyle.orange
        back.isEnabled = historyIndex > 0
        let title = NSTextField(labelWithString: folder.path)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = FPStyle.text
        title.lineBreakMode = .byTruncatingMiddle
        let close = NSButton(title: "", target: self, action: #selector(closePressed(_:)))
        close.isBordered = false
        close.bezelStyle = .inline
        close.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Закрыть")
        close.contentTintColor = FPStyle.dimText
        let header = NSStackView(views: [back, title, NSView(), close])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 4, right: 8)
        header.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 10, right: 10)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )) ?? []
        let entries = urls.compactMap { url -> (URL, Bool)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.isDirectory == true)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 && !$1.1 }
            return $0.0.lastPathComponent.localizedStandardCompare($1.0.lastPathComponent) == .orderedAscending
        }
        let count = NSTextField(labelWithString: "\(entries.count) объектов")
        count.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        count.textColor = FPStyle.dimText
        header.insertArrangedSubview(count, at: max(0, header.arrangedSubviews.count - 2))
        for (url, directory) in entries.prefix(160) {
            let item = FolderPocketItemView(url: url, isDirectory: directory)
            item.onOpen = { [weak self] url, isDirectory in
                if isDirectory { self?.openNested(url) } else { NSWorkspace.shared.open(url) }
            }
            stack.addArrangedSubview(item)
        }
        stack.frame = NSRect(
            x: 0,
            y: 0,
            width: max(740, CGFloat(min(entries.count, 160)) * 112 + 20),
            height: 142
        )

        let scroll = NSScrollView()
        scroll.documentView = stack
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(header)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 34),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        panel.contentView = root
    }

    @objc private func closePressed(_ sender: Any?) { closePocket() }

    @objc private func goBack(_ sender: Any?) {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        let folder = history[historyIndex]
        currentURL = folder
        buildContent(folder: folder)
    }
}

final class FileTransferController: NSWindowController {
    struct Task {
        let source: URL
        let destination: URL
        let move: Bool
        let replaceExisting: Bool
    }

    private let titleField = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let cancelButton = NSButton()
    private var cancelled = false
    private var pendingShowWorkItem: DispatchWorkItem?
    private var runGeneration = 0
    private let queue = DispatchQueue(label: "Qyvro.FileTransfer", qos: .userInitiated)

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 128),
            styleMask: [.titled, .closable, .utilityWindow, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Файловая операция"
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        // The progress panel must never drag the user to the Space it was last
        // shown on. It always joins the Space the paste happened on instead —
        // this was the "teleport to another desktop on ⌘V" bug.
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        super.init(window: panel)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildUI() {
        guard let window else { return }
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        titleField.font = .systemFont(ofSize: 12.5, weight: .medium)
        titleField.textColor = FPStyle.text
        titleField.lineBreakMode = .byTruncatingMiddle
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.controlTint = .blueControlTint
        cancelButton.title = "Отменить"
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        let stack = NSStackView(views: [titleField, progress, cancelButton])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 34, left: 18, bottom: 14, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: 94)
        ])
        window.contentView = effect
    }

    func run(tasks: [Task], parent: NSWindow?, completion: @escaping ([QyvroTransferRecord], [String]) -> Void) {
        guard !tasks.isEmpty else { completion([], []); return }
        runGeneration += 1
        let generation = runGeneration
        cancelled = false
        progress.maxValue = Double(tasks.count)
        progress.doubleValue = 0
        titleField.stringValue = tasks[0].source.lastPathComponent

        // Fast operations finish silently. The HUD only appears when a transfer
        // is actually taking time, positioned over the Qyvro window itself and
        // without stealing keyboard focus — so pasting never yanks the user to
        // another Space and never flashes a panel for instant copies.
        pendingShowWorkItem?.cancel()
        let show = DispatchWorkItem { [weak self] in
            guard let self, let window = self.window else { return }
            if let parent {
                let target = NSPoint(
                    x: parent.frame.midX - window.frame.width / 2,
                    y: parent.frame.midY - window.frame.height / 2
                )
                window.setFrameOrigin(target)
                parent.addChildWindow(window, ordered: .above)
            } else {
                window.center()
            }
            window.alphaValue = 0
            window.orderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1
            }
        }
        pendingShowWorkItem = show
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32, execute: show)

        queue.async { [weak self] in
            guard let self else { return }
            var completed: [QyvroTransferRecord] = []
            var errors: [String] = []
            for (index, task) in tasks.enumerated() {
                if self.cancelled { break }
                DispatchQueue.main.async {
                    self.titleField.stringValue = task.source.lastPathComponent
                    self.progress.doubleValue = Double(index)
                }
                var replacedItemTrashURL: URL?
                do {
                    if task.replaceExisting, FileManager.default.fileExists(atPath: task.destination.path) {
                        var trashed: NSURL?
                        try FileManager.default.trashItem(at: task.destination, resultingItemURL: &trashed)
                        replacedItemTrashURL = (trashed as URL?)?.standardizedFileURL
                    }
                    if task.move {
                        try FileManager.default.moveItem(at: task.source, to: task.destination)
                    } else {
                        try FileManager.default.copyItem(at: task.source, to: task.destination)
                    }
                    completed.append(
                        QyvroTransferRecord(
                            source: task.source,
                            destination: task.destination,
                            move: task.move,
                            replacedItemTrashURL: replacedItemTrashURL
                        )
                    )
                } catch {
                    if let replacedItemTrashURL,
                       !FileManager.default.fileExists(atPath: task.destination.path) {
                        try? FileManager.default.moveItem(at: replacedItemTrashURL, to: task.destination)
                    }
                    errors.append("\(task.source.lastPathComponent): \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                // Если за время работы уже поставили следующий перенос
                // (очередь последовательная), HUD не прячем — им продолжит
                // управлять более поздний запуск.
                if generation == self.runGeneration {
                    self.pendingShowWorkItem?.cancel()
                    self.pendingShowWorkItem = nil
                    self.progress.doubleValue = Double(tasks.count)
                    if let parent = self.window?.parent, let window = self.window { parent.removeChildWindow(window) }
                    if let window = self.window, window.isVisible {
                        NSAnimationContext.runAnimationGroup { context in
                            context.duration = 0.16
                            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                            window.animator().alphaValue = 0
                        } completionHandler: {
                            window.orderOut(nil)
                            window.alphaValue = 1
                        }
                    } else {
                        self.window?.orderOut(nil)
                    }
                }
                completion(completed, errors)
            }
        }
    }

    @objc private func cancel(_ sender: Any?) {
        cancelled = true
        titleField.stringValue = "Остановка после текущего объекта…"
    }
}
