import Cocoa
import Quartz
import ImageIO
final class FPTableHeaderCell: NSTableHeaderCell {
    var columnAlignment: NSTextAlignment = .left

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        // Бесшовная прозрачная шапка без серой капсулы и обрезанных краёв.
        let title = stringValue as NSString
        let font = FPStyle.isObsidianAurora
            ? NSFont.systemFont(ofSize: 11, weight: .medium)
            : NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        let color = FPStyle.dimText.withAlphaComponent(FPStyle.isObsidianAurora ? 0.82 : 0.90)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = columnAlignment
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        let size = title.size(withAttributes: attributes)
        let leadingInset: CGFloat = columnAlignment == .right ? 6 : 10
        let trailingInset: CGFloat = columnAlignment == .right ? 14 : 18
        title.draw(
            in: NSRect(
                x: cellFrame.minX + leadingInset,
                y: cellFrame.midY - size.height / 2 - 1,
                width: max(0, cellFrame.width - leadingInset - trailingInset),
                height: size.height + 2
            ),
            withAttributes: attributes
        )
    }

    override func drawSortIndicator(withFrame cellFrame: NSRect, in controlView: NSView, ascending: Bool, priority: Int) {
        guard priority == 0 else { return }
        let arrow = (ascending ? "↑" : "↓") as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: FPStyle.isObsidianAurora ? FPStyle.accent : FPStyle.orange
        ]
        let sz = arrow.size(withAttributes: attrs)
        let x = columnAlignment == .right
            ? cellFrame.maxX - 11
            : cellFrame.maxX - sz.width - 7
        arrow.draw(at: NSPoint(x: x, y: cellFrame.midY - sz.height / 2 - 1), withAttributes: attrs)
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
        let aurora = FPStyle.isObsidianAurora
        let auroraTint = FPStyle.text.blended(withFraction: 0.22, of: FPStyle.accent) ?? FPStyle.text
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius: CGFloat = aurora ? 8 : 9
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        let fill: NSColor
        if aurora {
            fill = isHighlighted
                ? auroraTint.withAlphaComponent(0.13)
                : auroraTint.withAlphaComponent(0.055)
        } else {
            fill = isHighlighted
                ? NSColor(calibratedRed: 0.190, green: 0.205, blue: 0.232, alpha: 0.98)
                : NSColor(calibratedRed: 0.133, green: 0.146, blue: 0.166, alpha: 0.94)
        }
        fill.setFill()
        path.fill()
        if !aurora {
            FPStyle.stroke.setStroke()
            path.lineWidth = 0.6
            path.stroke()
        } else {
            auroraTint.withAlphaComponent(0.09).setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }

        let fgColor = aurora ? FPStyle.text.withAlphaComponent(0.88) : FPStyle.orange
        let chevronColor = aurora ? FPStyle.accent.withAlphaComponent(0.82) : FPStyle.orange
        let titleText = (title.isEmpty ? "Имя" : title) as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: aurora
                ? FPStyle.bodyFont(ofSize: 11.4, weight: .medium)
                : NSFont.systemFont(ofSize: 12.5, weight: .semibold),
            .foregroundColor: fgColor
        ]
        let textSize = titleText.size(withAttributes: attrs)
        titleText.draw(
            in: NSRect(x: 12, y: (bounds.height - textSize.height) / 2 - 0.5, width: bounds.width - 36, height: textSize.height + 2),
            withAttributes: attrs
        )

        let chevron = (ascending ? "↑" : "↓") as NSString
        let chevronAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: aurora ? 13 : 16, weight: .semibold),
            .foregroundColor: chevronColor
        ]
        let chevronSize = chevron.size(withAttributes: chevronAttrs)
        chevron.draw(
            in: NSRect(x: bounds.width - chevronSize.width - 11, y: (bounds.height - chevronSize.height) / 2 - 1, width: chevronSize.width, height: chevronSize.height),
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
    /// Возвращает true, если прокрутка ушла в свёрнутый ряд под курсором.
    /// Точка передаётся в системе координат документа сетки.
    var onSectionScroll: ((NSPoint, CGFloat) -> Bool)?
    /// Ctrl с колесом: положительное значение — увеличить значки.
    var onZoomScroll: ((CGFloat) -> Void)?
    /// Щипок двумя пальцами: положительное значение — раздвигание.
    var onMagnify: ((CGFloat) -> Void)?

    override func magnify(with event: NSEvent) {
        guard abs(event.magnification) > 0.001 else { return }
        onMagnify?(event.magnification)
    }
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
        let dragged = FPUploadPrep.prepareIfRequested(urls, event: event)
        beginDraggingSession(with: draggingItems(for: dragged, from: startPoint), event: event, source: self)
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
        // Ctrl с колесом меняет размер значков — жест для мыши, у которой нет
        // щипка двумя пальцами.
        if event.modifierFlags.contains(.control), let onZoomScroll {
            let raw = abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX)
                ? event.scrollingDeltaY
                : event.scrollingDeltaX
            // Колесо мыши шлёт дискретные щелчки, трекпад — плавные значения в
            // точках. Без разных множителей на мыши шаг был бы незаметным.
            onZoomScroll(event.hasPreciseScrollingDeltas ? raw : raw * 6)
            return
        }
        // С зажатым Shift колесо прокручивает свёрнутый ряд под курсором.
        //
        // Событие не отдаётся дальше ни при каких условиях: раньше, когда ряд
        // упирался в край, оно проваливалось в обработчик жеста и срабатывало
        // перелистывание истории — человек листал ленту, а его уносило в
        // другую папку.
        if event.modifierFlags.contains(.shift) {
            if let onSectionScroll, let documentView {
                let point = documentView.convert(event.locationInWindow, from: nil)
                let raw = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
                    ? event.scrollingDeltaX
                    : event.scrollingDeltaY
                let delta = event.hasPreciseScrollingDeltas ? raw : raw * 6
                if onSectionScroll(point, delta) { return }
            }
            // Ряд не сдвинулся — пусть работает обычная прокрутка, но не жест.
            super.scrollWheel(with: event)
            return
        }
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

        // Элемент перетаскивания несёт сам файл, а не только картинку под
        // курсором. Прежде список обрезался до двенадцати ради вида стопки —
        // и вместе с картинками обрезался перенос: сколько ни выдели,
        // уходило двенадцать файлов.
        //
        // Теперь элементы создаются для всех выбранных файлов, а изображение
        // получают только первые: рисовать стопку из тридцати иконок незачем,
        // они всё равно лягут друг на друга.
        let visibleStackLimit = 12
        return urls.enumerated().map { offset, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            guard offset < visibleStackLimit else {
                // Кадр обязан быть настоящим: с нулевым размером AppKit
                // отбрасывал перетаскивание целиком, и не переносилось ничего.
                // Скрытые элементы получают ту же рамку, что и первый, но без
                // изображения — груз идёт, рисунка нет.
                item.setDraggingFrame(
                    NSRect(x: localPoint.x - 24, y: localPoint.y - 24, width: 48, height: 48),
                    contents: nil
                )
                return item
            }
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
        case 51 where event.modifierFlags.contains(.command):
            filePanel?.trashSelection(nil)
        case 49:
            filePanel?.quickLookSelection(nil)
        case 53:
            filePanel?.handleEscapeKey()
        case 17 where event.modifierFlags.contains(.command):
            filePanel?.openSelectionInNewTab(nil)
        case 33 where event.modifierFlags.intersection([.command, .control, .option]).isEmpty:
            filePanel?.navigateToSiblingFolder(delta: -1)
        case 30 where event.modifierFlags.intersection([.command, .control, .option]).isEmpty:
            filePanel?.navigateToSiblingFolder(delta: 1)
        case 123 where event.modifierFlags.contains(.option) && !event.modifierFlags.contains(.command):
            filePanel?.navigateToSiblingFolder(delta: -1)
        case 124 where event.modifierFlags.contains(.option) && !event.modifierFlags.contains(.command):
            filePanel?.navigateToSiblingFolder(delta: 1)
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

final class PanelRowView: NSTableRowView {
    var rowColor: NSColor = FPStyle.rowA

    override func drawBackground(in dirtyRect: NSRect) {
        if FPStyle.isObsidianAurora {
            if rowColor.alphaComponent > 0.001 {
                let rect = bounds.insetBy(dx: 4, dy: 1)
                rowColor.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            }
            return
        }
        rowColor.setFill()
        dirtyRect.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        if FPStyle.isObsidianAurora {
            let rect = bounds.insetBy(dx: 4, dy: 1.5)
            let path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
            NSColor.white.withAlphaComponent(0.095).setFill()
            path.fill()
            NSColor.white.withAlphaComponent(0.08).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            // Спокойный вертикальный индикатор слева (как в Steam/Spotify Glass).
            let indicator = NSRect(x: rect.minX + 2, y: rect.midY - 7, width: 3, height: 14)
            FPStyle.accent.setFill()
            NSBezierPath(roundedRect: indicator, xRadius: 1.5, yRadius: 1.5).fill()
            return
        }
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

/// Метка имени файла в плитке: визуально позволяет переносить длинные имена по
/// символам `_` через невидимый `U+200B`, но `stringValue` и VoiceOver всегда
/// возвращают чистое исходное имя файла без служебных символов.
private final class FPGlyphWrappingTitleField: NSTextField {
    var rawFilename: String = ""

    override var stringValue: String {
        get { rawFilename.isEmpty ? super.stringValue : rawFilename }
        set {
            rawFilename = newValue
            super.stringValue = newValue
        }
    }
}

final class FileGridCellView: FPLayerView, NSDraggingSource {
    private let previewImageView = NSImageView()
    private let titleField: FPGlyphWrappingTitleField = {
        let field = FPGlyphWrappingTitleField(labelWithString: "")
        return field
    }()
    private let kindField = NSTextField(labelWithString: "")
    /// Звёздочка «отобрано» в углу миниатюры.
    private let flagBadge = FPSelectedFlagBadge()
    /// Папка ли в этой плитке: у папок отметки нет.
    private var representsDirectory = false
    private let versionBadge = FPVersionCountBadge()
    private var previewWidthConstraint: NSLayoutConstraint!
    private var previewHeightConstraint: NSLayoutConstraint!
    private var mouseDownPoint: NSPoint?
    private var defersExclusiveSelection = false
    private var hoverTrackingArea: NSTrackingArea?
    private var isHoveredState = false
    private var isSelectedState = false
    private var isCutState = false
    private var configuredImageSize: CGFloat = 64
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

    /// Попал ли клик по звёздочке. Точка ожидается в системе координат
    /// надвью ячейки — именно в ней приходит нажатие с холста сетки.
    ///
    /// Клики в сетке обрабатывает холст `FileGridCanvasView`, а не сами
    /// ячейки: до `mouseDown` ячейки нажатие не доходит, поэтому разбирать
    /// попадание по значку приходится снаружи.
    func flagBadgeContains(_ point: NSPoint) -> Bool {
        guard !flagBadge.isHidden, let superview else { return false }
        return flagBadge.frame.contains(convert(point, from: superview))
    }

    /// Нажатие по счётчику версий раскрывает стопку.
    func versionBadgeContains(_ point: NSPoint) -> Bool {
        guard !versionBadge.isHidden, let superview else { return false }
        return versionBadge.frame.contains(convert(point, from: superview))
    }

    override func layout() {
        let targetW = bounds.width > 40 ? max(configuredImageSize, bounds.width - 12) : max(configuredImageSize, round(configuredImageSize * 1.12))
        if abs(previewWidthConstraint.constant - targetW) > 0.5 {
            previewWidthConstraint.constant = targetW
        }
        super.layout()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Все клики, перетаскивания, контекстное меню и нажатия на значки
        // звёздочки/версий разбирает `FileGridScrollView` → `FilePanel`.
        // Раньше здесь проверялось `bounds.contains(point)` без перевода из
        // координат надвью (`gridContentView`): для любой точки в левом нижнем
        // углу холста `(0..cellW, 0..cellH)` проверка срабатывала на последней
        // ячейке в списке и перехватывала клик по левой нижней плитке.
        nil
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
        // Папки не отбирают: отметка нужна для кадров, которые идут в работу.
        // Значок на папке только сбивал с толку — нажатие на него ничего не
        // делало.
        guard !representsDirectory else {
            flagBadge.isHidden = true
            return
        }
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

        let selected = onDrag?(itemIndex) ?? []
        guard !selected.isEmpty else { return }
        let urls = FPUploadPrep.prepareIfRequested(selected, event: event)

        let dragImage = previewImageView.image ?? NSWorkspace.shared.icon(forFile: urls[0].path)
        // Переносятся все выбранные файлы, а рисуются только первые: стопка из
        // трёх десятков иконок уехала бы длинной диагональю и ничего бы не
        // сообщила.
        let visibleStackLimit = 12
        let draggingItems = urls.enumerated().map { offset, url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            guard offset < visibleStackLimit else {
                item.setDraggingFrame(previewImageView.frame, contents: nil)
                return item
            }
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
        titleField.lineBreakMode = .byWordWrapping
        titleField.maximumNumberOfLines = 2
        titleField.cell?.lineBreakMode = .byWordWrapping
        titleField.cell?.wraps = true
        titleField.cell?.truncatesLastVisibleLine = true
        titleField.font = FPStyle.bodyFont(
            ofSize: FPStyle.isObsidianAurora ? 11.8 : 12,
            weight: FPStyle.isCyberEditorial ? .semibold : .medium
        )
        titleField.textColor = FPStyle.text

        kindField.translatesAutoresizingMaskIntoConstraints = false
        kindField.alignment = .center
        kindField.lineBreakMode = .byTruncatingMiddle
        kindField.font = (FPStyle.isCyberEditorial || FPStyle.isObsidianAurora)
            ? FPStyle.monoMetaFont(ofSize: 9.8, weight: .regular)
            : .systemFont(ofSize: 10.5, weight: .medium)
        kindField.textColor = FPStyle.dimText.withAlphaComponent(FPStyle.isObsidianAurora ? 0.68 : 0.88)

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
        versionBadge.translatesAutoresizingMaskIntoConstraints = false
        versionBadge.isHidden = true
        addSubview(versionBadge)

        previewWidthConstraint = previewImageView.widthAnchor.constraint(equalToConstant: 64)
        previewHeightConstraint = previewImageView.heightAnchor.constraint(equalToConstant: 64)

        NSLayoutConstraint.activate([
            previewImageView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            previewImageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            previewWidthConstraint,
            previewHeightConstraint,
            // Правый верхний угол миниатюры: не перекрывает ни подпись, ни
            // цветной кружок метки, который живёт слева.
            // Значок садится на сам кадр, а не на пустое поле рядом с ним.
            flagBadge.trailingAnchor.constraint(equalTo: previewImageView.trailingAnchor, constant: -5),
            flagBadge.topAnchor.constraint(equalTo: previewImageView.topAnchor, constant: 5),
            versionBadge.leadingAnchor.constraint(equalTo: previewImageView.leadingAnchor, constant: -3),
            versionBadge.topAnchor.constraint(equalTo: previewImageView.topAnchor, constant: -3),
            versionBadge.heightAnchor.constraint(equalToConstant: 20),
            versionBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 30),
            flagBadge.widthAnchor.constraint(equalToConstant: 20),
            flagBadge.heightAnchor.constraint(equalToConstant: 20),
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            titleField.topAnchor.constraint(equalTo: previewImageView.bottomAnchor, constant: 3),
            titleField.heightAnchor.constraint(equalToConstant: 31),
            kindField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            kindField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            kindField.topAnchor.constraint(equalTo: titleField.bottomAnchor),
            kindField.heightAnchor.constraint(equalToConstant: 13)
        ])
    }

    func configure(
        item: FileItem,
        image: NSImage,
        imageSize: CGFloat,
        selected: Bool,
        cut: Bool,
        versionCount: Int = 0,
        flagLevel: FPFinderTagStore.FlagLevel? = nil
    ) {
        representsDirectory = item.isDirectory
        flagBadge.level = item.isDirectory
            ? .none
            : (flagLevel ?? FPFinderTagStore.flagLevel(item.finderTags ?? []))
        versionBadge.count = versionCount
        versionBadge.isHidden = versionCount < 2
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
        let aurora = FPStyle.isObsidianAurora
        let titleFont = FPStyle.bodyFont(
            ofSize: aurora ? 11.8 : 12,
            weight: FPStyle.isCyberEditorial ? .semibold : .medium
        )
        let titleColor = item.isHidden ? .tertiaryLabelColor : FPStyle.text
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        para.lineHeightMultiple = aurora ? 1.05 : 1.0
        let displayTitle = FPStyle.wrappableFilename(item.name)
        var titleAttrs: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: titleColor,
            .paragraphStyle: para
        ]
        if aurora {
            titleAttrs[.kern] = -0.1
        }
        titleField.font = titleFont
        titleField.textColor = titleColor
        titleField.rawFilename = item.name
        titleField.attributedStringValue = NSAttributedString(string: displayTitle, attributes: titleAttrs)

        let metaFont: NSFont = (FPStyle.isCyberEditorial || aurora)
            ? FPStyle.monoMetaFont(ofSize: 9.8, weight: .regular)
            : .systemFont(ofSize: 10.5, weight: .medium)
        let metaColor = FPStyle.dimText.withAlphaComponent(aurora ? 0.68 : 0.88)
        kindField.font = metaFont
        kindField.textColor = metaColor
        // Разрешение читается из заголовка файла в фоне: в папке на полторы
        // тысячи объектов синхронный разбор подвесил бы прокрутку. Пока оно
        // едет, подпись показывает то же, что и раньше, без прыжков высоты.
        let cachedMedia = FPMediaInfoCache.cached(for: item.url, modified: item.modified)
        let applyKindCaption: (String) -> Void = { [weak self] text in
            guard let self else { return }
            if aurora {
                let metaPara = NSMutableParagraphStyle()
                metaPara.alignment = .center
                metaPara.lineBreakMode = .byTruncatingMiddle
                self.kindField.attributedStringValue = NSAttributedString(
                    string: text,
                    attributes: [
                        .font: metaFont,
                        .foregroundColor: metaColor,
                        .kern: 0.15,
                        .paragraphStyle: metaPara
                    ]
                )
            } else {
                self.kindField.stringValue = text
            }
        }
        applyKindCaption(FPTileCaption.text(for: item, media: cachedMedia))
        if cachedMedia == nil, !item.isDirectory {
            FPMediaInfoCache.load(for: item.url, modified: item.modified) { [weak self] info in
                guard let self, self.representedPath == path else { return }
                applyKindCaption(FPTileCaption.text(for: item, media: info))
            }
        }
        // Ступень уже выставлена в начале configure и учитывает изменения
        // этого сеанса. Прежнее присваивание отсюда убрано: оно перезаписывало
        // её значением из кэша — сбрасывало «точно берём» до «кандидата», а на
        // незаполненном кэше прятало значок совсем.
        updateFlagBadgeVisibility()
        toolTip = hoverTooltip(for: item)
        setAccessibilityLabel(item.name)
        setAccessibilityHelp(item.isDirectory ? "Открыть папку" : "Открыть файл")
        // The preview slot must never change geometry after an asynchronous
        // thumbnail arrives. Filling the column slot width (minus crisp 12pt
        // gutter) with a sleek 5:4/3:2 editorial height eliminates dead vertical
        // gutters between columns and empty air above landscape media.
        configuredImageSize = imageSize
        let slotW = bounds.width > 40 ? max(imageSize, bounds.width - 12) : max(imageSize, round(imageSize * 1.12))
        let slotH = FilePanel.previewBoxHeight(for: imageSize)
        previewWidthConstraint.constant = slotW
        previewHeightConstraint.constant = slotH
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
        let aurora = FPStyle.isObsidianAurora
        let background: NSColor
        let border: NSColor
        let borderWidth: CGFloat
        let auroraTint = FPStyle.text.blended(withFraction: 0.22, of: FPStyle.accent) ?? FPStyle.text
        if isSelectedState {
            if aurora {
                background = FPStyle.accent.withAlphaComponent(0.13)
                border = FPStyle.accent.withAlphaComponent(0.46)
                borderWidth = 1
            } else {
                background = FPStyle.rowSelection
                border = FPStyle.accent.withAlphaComponent(0.62)
                borderWidth = 1
            }
        } else if isHoveredState {
            background = (aurora ? auroraTint : NSColor(calibratedWhite: 1.0, alpha: 1.0)).withAlphaComponent(aurora ? 0.055 : 0.055)
            border = (aurora ? auroraTint : NSColor(calibratedWhite: 1.0, alpha: 1.0)).withAlphaComponent(aurora ? 0.095 : 0.09)
            borderWidth = aurora ? 0.5 : 1
        } else {
            background = .clear
            border = .clear
            borderWidth = 0
        }
        let apply = { [self] in
            layer?.cornerRadius = FPStyle.isCyberEditorial ? 5 : (aurora ? 12 : 14)
            previewImageView.layer?.cornerRadius = FPStyle.isCyberEditorial ? 4 : 10
            layer?.backgroundColor = background.cgColor
            layer?.borderColor = border.cgColor
            layer?.borderWidth = borderWidth
            layer?.shadowColor = (aurora ? NSColor.black : FPStyle.accent).cgColor
            layer?.shadowOpacity = isSelectedState ? (aurora ? 0.28 : 0.22) : 0
            layer?.shadowRadius = aurora ? 12 : 8
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
    private let scrollHint = NSTextField(labelWithString: "")
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
        titleField.textColor = FPStyle.orange
        titleField.translatesAutoresizingMaskIntoConstraints = false

        toggleButton.isBordered = false
        toggleButton.bezelStyle = .inline
        toggleButton.alignment = .right
        toggleButton.font = FPStyle.bodyFont(ofSize: 11.5, weight: .semibold)
        toggleButton.contentTintColor = FPStyle.orange
        toggleButton.target = self
        toggleButton.action = #selector(togglePressed(_:))
        toggleButton.translatesAutoresizingMaskIntoConstraints = false

        // Подсказка о боковом листании: сама возможность есть, но узнать о
        // ней в интерфейсе было неоткуда.
        scrollHint.font = FPStyle.headingFont(ofSize: 9.5, weight: .semibold)
        scrollHint.textColor = FPStyle.dimText.withAlphaComponent(0.62)
        scrollHint.stringValue = "⇧ + ПРОКРУТКА"
        scrollHint.translatesAutoresizingMaskIntoConstraints = false
        scrollHint.isHidden = true

        separator.backgroundColor = FPStyle.stroke.withAlphaComponent(0.7).cgColor
        layer?.addSublayer(separator)
        addSubview(titleField)
        addSubview(scrollHint)
        addSubview(toggleButton)

        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggleButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            toggleButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            scrollHint.leadingAnchor.constraint(equalTo: titleField.trailingAnchor, constant: 12),
            scrollHint.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggleButton.leadingAnchor.constraint(greaterThanOrEqualTo: scrollHint.trailingAnchor, constant: 12)
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
        let aurora = FPStyle.isObsidianAurora
        sectionID = id
        let displayTitle = FPStyle.isCyberEditorial ? title.uppercased() : title
        let titleFont = FPStyle.headingFont(
            ofSize: FPStyle.isCyberEditorial ? 14 : (aurora ? 14 : 13),
            weight: .semibold
        )
        let titleColor = aurora ? FPStyle.text.withAlphaComponent(0.95) : FPStyle.orange
        titleField.font = titleFont
        titleField.textColor = titleColor
        titleField.attributedStringValue = NSAttributedString(
            string: displayTitle,
            attributes: [
                .font: titleFont,
                .foregroundColor: titleColor,
                .kern: aurora ? -0.2 : 0.0
            ]
        )
        toggleButton.isHidden = !canToggle
        // Подсказка нужна только там, где ряд действительно длиннее экрана:
        // на коротком разделе она была бы обманом.
        scrollHint.isHidden = !(canToggle && !expanded)
        let hintFont: NSFont = aurora
            ? FPStyle.monoMetaFont(ofSize: 9.2, weight: .medium)
            : FPStyle.headingFont(ofSize: 9.5, weight: .semibold)
        let hintColor = FPStyle.dimText.withAlphaComponent(aurora ? 0.50 : 0.55)
        scrollHint.font = hintFont
        scrollHint.attributedStringValue = NSAttributedString(
            string: L("⇧ + ПРОКРУТКА", "⇧ + SCROLL"),
            attributes: [
                .font: hintFont,
                .foregroundColor: hintColor,
                .kern: aurora ? 0.45 : 0.0
            ]
        )
        let buttonTitle = expanded
            ? L("Свернуть", "Collapse")
            : L("Все (\(totalCount))", "All (\(totalCount))")
        let actionColor = aurora ? FPStyle.dimText.withAlphaComponent(0.86) : FPStyle.orange
        toggleButton.attributedTitle = NSAttributedString(
            string: buttonTitle,
            attributes: [
                .font: FPStyle.bodyFont(ofSize: 11.5, weight: .medium),
                .foregroundColor: actionColor
            ]
        )
        toggleButton.contentTintColor = actionColor
        let hairlineTint = FPStyle.text.blended(withFraction: 0.22, of: FPStyle.accent) ?? FPStyle.text
        separator.backgroundColor = (aurora
            ? hairlineTint.withAlphaComponent(0.085)
            : FPStyle.stroke.withAlphaComponent(0.7)).cgColor
    }

    @objc private func togglePressed(_ sender: Any?) {
        onToggle?(sectionID)
    }
}

final class FileInspectorController: NSWindowController {
    private let backdrop = FPAuxiliaryBackdrop(frame: .zero)
    private let headerTitle = NSTextField(labelWithString: "СВОЙСТВА")
    private let heroCard = FPLayerView(color: .clear, cornerRadius: 12)
    private let iconContainer = FPLayerView(color: .clear, cornerRadius: 12)
    private let iconView = NSImageView()
    private let nameField = NSTextField(wrappingLabelWithString: "")
    private let kindPill = FPLayerView(color: .clear, cornerRadius: 6)
    private let kindLabel = NSTextField(labelWithString: "")
    private let heroSizeSpinner = NSProgressIndicator()
    private let heroSizeLabel = NSTextField(labelWithString: "")
    private let tagsStack = NSStackView()
    private let detailsCard = FPLayerView(color: .clear, cornerRadius: 12)
    private let detailsStack = NSStackView()
    private let actionsStack = NSStackView()

    private var inspectedItems: [FileItem] = []
    private weak var calculatedSizeField: NSTextField?
    private weak var calculatedContentsField: NSTextField?
    private weak var copyPathButton: NSButton?
    private var sizeCalculationGeneration = 0
    private var themeObserver: NSObjectProtocol?

    init() {
        let panel = EscapeClosingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 470),
            styleMask: [.titled, .closable, .utilityWindow, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Свойства"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isFloatingPanel = true
        panel.minSize = NSSize(width: 390, height: 390)
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init(window: panel)
        buildUI()
        themeObserver = NotificationCenter.default.addObserver(
            forName: .fpThemeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyTheme()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
    }

    func show(items: [FileItem]) {
        guard !items.isEmpty else { return }
        inspectedItems = items
        sizeCalculationGeneration += 1
        configure(items: items)
        applyTheme()
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        // Размер папок считается автоматически при открытии — лишняя кнопка
        // «Посчитать» больше не нужна.
        if items.contains(where: \.isDirectory) {
            startFolderSizeCalculation()
        }
    }

    func calculateFolderSizes() {
        startFolderSizeCalculation()
    }

    private func buildUI() {
        guard let window else { return }
        let root = NSView(frame: window.contentRect(forFrameRect: window.frame))
        root.wantsLayer = true
        window.contentView = root

        root.addSubview(backdrop)

        headerTitle.font = FPStyle.headingFont(ofSize: 11, weight: .semibold)
        headerTitle.alignment = .center
        headerTitle.translatesAutoresizingMaskIntoConstraints = false

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 9
        iconView.layer?.masksToBounds = true
        iconContainer.addSubview(iconView)

        nameField.font = FPStyle.headingFont(ofSize: 15.5, weight: .semibold)
        nameField.maximumNumberOfLines = 2
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.isSelectable = true
        nameField.translatesAutoresizingMaskIntoConstraints = false

        kindLabel.font = FPStyle.headingFont(ofSize: 10, weight: .semibold)
        kindLabel.translatesAutoresizingMaskIntoConstraints = false
        kindPill.addSubview(kindLabel)

        heroSizeSpinner.style = .spinning
        heroSizeSpinner.controlSize = .small
        heroSizeSpinner.isDisplayedWhenStopped = false
        heroSizeSpinner.translatesAutoresizingMaskIntoConstraints = false

        heroSizeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        heroSizeLabel.lineBreakMode = .byTruncatingTail
        heroSizeLabel.translatesAutoresizingMaskIntoConstraints = false

        let metaLine = NSStackView(views: [kindPill, heroSizeSpinner, heroSizeLabel])
        metaLine.orientation = .horizontal
        metaLine.alignment = .centerY
        metaLine.spacing = 8
        metaLine.translatesAutoresizingMaskIntoConstraints = false

        tagsStack.orientation = .horizontal
        tagsStack.alignment = .centerY
        tagsStack.spacing = 5
        tagsStack.translatesAutoresizingMaskIntoConstraints = false

        let titleColumn = NSStackView(views: [nameField, metaLine, tagsStack])
        titleColumn.orientation = .vertical
        titleColumn.alignment = .leading
        titleColumn.spacing = 6
        titleColumn.translatesAutoresizingMaskIntoConstraints = false

        heroCard.addSubview(iconContainer)
        heroCard.addSubview(titleColumn)

        detailsStack.orientation = .vertical
        detailsStack.alignment = .width
        detailsStack.spacing = 0
        detailsStack.translatesAutoresizingMaskIntoConstraints = false
        detailsCard.addSubview(detailsStack)

        actionsStack.orientation = .horizontal
        actionsStack.alignment = .centerY
        actionsStack.distribution = .fillEqually
        actionsStack.spacing = 8
        actionsStack.translatesAutoresizingMaskIntoConstraints = false

        let bodyStack = NSStackView(views: [heroCard, detailsCard])
        bodyStack.orientation = .vertical
        bodyStack.alignment = .width
        bodyStack.spacing = 12
        bodyStack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets()
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let document = FPFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(bodyStack)
        scroll.documentView = document

        root.addSubview(headerTitle)
        root.addSubview(scroll)
        root.addSubview(actionsStack)

        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: root.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            headerTitle.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            headerTitle.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            scroll.topAnchor.constraint(equalTo: headerTitle.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: actionsStack.topAnchor, constant: -12),

            bodyStack.topAnchor.constraint(equalTo: document.topAnchor),
            bodyStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            bodyStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            bodyStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -4),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            iconContainer.leadingAnchor.constraint(equalTo: heroCard.leadingAnchor, constant: 14),
            iconContainer.centerYAnchor.constraint(equalTo: heroCard.centerYAnchor),
            iconContainer.widthAnchor.constraint(equalToConstant: 66),
            iconContainer.heightAnchor.constraint(equalToConstant: 66),
            iconView.leadingAnchor.constraint(equalTo: iconContainer.leadingAnchor, constant: 5),
            iconView.trailingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: -5),
            iconView.topAnchor.constraint(equalTo: iconContainer.topAnchor, constant: 5),
            iconView.bottomAnchor.constraint(equalTo: iconContainer.bottomAnchor, constant: -5),

            titleColumn.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 14),
            titleColumn.trailingAnchor.constraint(equalTo: heroCard.trailingAnchor, constant: -14),
            titleColumn.topAnchor.constraint(equalTo: heroCard.topAnchor, constant: 14),
            titleColumn.bottomAnchor.constraint(equalTo: heroCard.bottomAnchor, constant: -14),
            heroCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 94),

            kindLabel.leadingAnchor.constraint(equalTo: kindPill.leadingAnchor, constant: 7),
            kindLabel.trailingAnchor.constraint(equalTo: kindPill.trailingAnchor, constant: -7),
            kindLabel.topAnchor.constraint(equalTo: kindPill.topAnchor, constant: 2),
            kindLabel.bottomAnchor.constraint(equalTo: kindPill.bottomAnchor, constant: -2),

            detailsStack.leadingAnchor.constraint(equalTo: detailsCard.leadingAnchor),
            detailsStack.trailingAnchor.constraint(equalTo: detailsCard.trailingAnchor),
            detailsStack.topAnchor.constraint(equalTo: detailsCard.topAnchor, constant: 4),
            detailsStack.bottomAnchor.constraint(equalTo: detailsCard.bottomAnchor, constant: -4),

            actionsStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            actionsStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            actionsStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            actionsStack.heightAnchor.constraint(equalToConstant: 32)
        ])

        QyvroWindowResizeOverlay.install(
            in: root,
            insets: QyvroWindowResizeInsets(left: 8, right: 8, top: 6, bottom: 8, cornerSize: 14)
        )
        applyTheme()
    }

    private func applyTheme() {
        backdrop.applyTheme()
        headerTitle.textColor = FPStyle.dimText
        heroCard.layer?.backgroundColor = FPStyle.control.cgColor
        heroCard.layer?.borderColor = FPStyle.stroke.cgColor
        heroCard.layer?.borderWidth = 0.75
        iconContainer.layer?.backgroundColor = FPStyle.field.withAlphaComponent(0.75).cgColor
        iconContainer.layer?.borderColor = FPStyle.stroke.cgColor
        iconContainer.layer?.borderWidth = 0.5
        nameField.textColor = FPStyle.text
        kindPill.layer?.backgroundColor = FPStyle.orange.withAlphaComponent(0.18).cgColor
        kindPill.layer?.borderColor = FPStyle.orange.withAlphaComponent(0.45).cgColor
        kindPill.layer?.borderWidth = 0.6
        kindLabel.textColor = FPStyle.orange
        heroSizeLabel.textColor = FPStyle.accent
        detailsCard.layer?.backgroundColor = FPStyle.control.cgColor
        detailsCard.layer?.borderColor = FPStyle.stroke.cgColor
        detailsCard.layer?.borderWidth = 0.75
    }

    private func configure(items: [FileItem]) {
        calculatedSizeField = nil
        calculatedContentsField = nil
        copyPathButton = nil
        heroSizeSpinner.stopAnimation(nil)

        for view in detailsStack.arrangedSubviews {
            detailsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for view in tagsStack.arrangedSubviews {
            tagsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for view in actionsStack.arrangedSubviews {
            actionsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if items.count > 1 {
            let files = items.filter { !$0.isDirectory }
            let folders = items.count - files.count
            let totalSize = files.compactMap(\.size).reduce(0, +)
            nameField.stringValue = "Выбрано объектов: \(items.count)"
            kindLabel.stringValue = "ПАЧКА"
            if #available(macOS 11.0, *) {
                iconView.image = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: nil)
                iconView.contentTintColor = FPStyle.accent
            }
            tagsStack.isHidden = true
            if folders > 0 {
                heroSizeLabel.stringValue = "Подсчёт…"
                heroSizeSpinner.startAnimation(nil)
            } else {
                heroSizeLabel.stringValue = ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
            }

            addDetailRow("Файлы", "\(files.count)", first: true)
            addDetailRow("Папки", "\(folders)")
            if folders > 0 {
                calculatedSizeField = addDetailRow("Общий вес", "Считаю…", accent: true)
                calculatedContentsField = addDetailRow("Внутри папок", "Считаю…")
            } else {
                addDetailRow("Общий вес", ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file), accent: true)
            }
            addActionButton(title: "Показать в Finder", symbol: "folder", action: #selector(revealInspectedInFinder(_:)))
            addActionButton(title: "На полку", symbol: "tray.and.arrow.down", action: #selector(sendInspectedToShelf(_:)))
            return
        }

        let item = items[0]
        nameField.stringValue = item.name
        kindLabel.stringValue = item.isDirectory
            ? "ПАПКА"
            : (item.url.pathExtension.isEmpty ? item.kind.uppercased() : item.url.pathExtension.uppercased())

        iconView.contentTintColor = nil
        if item.isDirectory, let custom = CustomFolderIconStore.shared.image(for: item.url) {
            iconView.image = custom
        } else if QyvroPreviewImageCache.isDirectImage(item.url) {
            iconView.image = NSWorkspace.shared.icon(forFile: item.url.path)
            let targetURL = item.url
            QyvroPreviewImageCache.shared.load(url: targetURL, maxPixelSize: 160) { [weak self] thumb in
                guard let self, self.inspectedItems.first?.url == targetURL, let thumb else { return }
                self.iconView.image = thumb
            }
        } else {
            iconView.image = NSWorkspace.shared.icon(forFile: item.url.path)
        }

        // Теги Finder, если назначены
        let tags = item.finderTags ?? []
        tagsStack.isHidden = tags.isEmpty
        for tag in tags.prefix(4) {
            let pill = FPLayerView(
                color: FPFinderTagStore.color(forFinderNumber: tag.colorNumber).withAlphaComponent(0.22),
                cornerRadius: 5,
                borderColor: FPFinderTagStore.color(forFinderNumber: tag.colorNumber).withAlphaComponent(0.55),
                borderWidth: 0.6
            )
            let lbl = NSTextField(labelWithString: tag.title)
            lbl.font = .systemFont(ofSize: 10, weight: .semibold)
            lbl.textColor = FPStyle.text
            lbl.translatesAutoresizingMaskIntoConstraints = false
            pill.addSubview(lbl)
            NSLayoutConstraint.activate([
                lbl.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 6),
                lbl.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -6),
                lbl.topAnchor.constraint(equalTo: pill.topAnchor, constant: 1.5),
                lbl.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -1.5)
            ])
            tagsStack.addArrangedSubview(pill)
        }

        if item.isDirectory {
            heroSizeLabel.stringValue = "Подсчёт…"
            heroSizeSpinner.startAnimation(nil)
        } else {
            heroSizeLabel.stringValue = ByteCountFormatter.string(fromByteCount: item.size ?? 0, countStyle: .file)
        }

        addDetailRow("Тип", item.kind, first: true)
        if item.isDirectory {
            calculatedSizeField = addDetailRow("Размер", "Считаю…", accent: true)
            calculatedContentsField = addDetailRow("Содержимое", "Считаю…")
        } else {
            addDetailRow("Размер", ByteCountFormatter.string(fromByteCount: item.size ?? 0, countStyle: .file), accent: true)
        }
        if let media = FPMediaInfoCache.cached(for: item.url, modified: item.modified) {
            addDetailRow("Разрешение", "\(media.pixelWidth) × \(media.pixelHeight) px")
            if let duration = media.durationText {
                addDetailRow("Длительность", duration)
            }
        } else if let dimensions = imageDimensions(item.url) {
            addDetailRow("Разрешение", "\(dimensions.width) × \(dimensions.height) px")
        }
        addDetailRow("Создан", formatted(item.created))
        addDetailRow("Изменён", formatted(item.modified))
        addPathRow(item.url.path)

        addActionButton(title: "Открыть", symbol: "arrow.up.right.square", action: #selector(openInspected(_:)))
        addActionButton(title: "В Finder", symbol: "folder", action: #selector(revealInspectedInFinder(_:)))
        addActionButton(title: "На полку", symbol: "tray.and.arrow.down", action: #selector(sendInspectedToShelf(_:)))
        if item.isDirectory {
            addActionButton(title: "Анализ веса", symbol: "chart.pie", action: #selector(analyzeInspectedFolder(_:)))
        }
    }

    private func startFolderSizeCalculation() {
        let folders = inspectedItems.filter(\.isDirectory).map(\.url)
        guard !folders.isEmpty else { return }
        let knownFileBytes = inspectedItems.filter { !$0.isDirectory }.compactMap(\.size).reduce(0, +)
        sizeCalculationGeneration += 1
        let generation = sizeCalculationGeneration
        heroSizeSpinner.startAnimation(nil)
        heroSizeLabel.stringValue = "Подсчёт…"
        calculatedSizeField?.stringValue = "Считаю…"
        calculatedContentsField?.stringValue = "Считаю…"

        FPDirectorySizeCalculator.calculateDetailed(urls: folders) { [weak self] result in
            guard let self, self.sizeCalculationGeneration == generation else { return }
            self.heroSizeSpinner.stopAnimation(nil)
            switch result {
            case .success(let summary):
                let formattedSize = ByteCountFormatter.string(
                    fromByteCount: knownFileBytes + summary.bytes,
                    countStyle: .file
                )
                let objectsText = "\(summary.fileCount) файлов · \(summary.folderCount) папок"
                self.heroSizeLabel.stringValue = "\(formattedSize) · \(summary.fileCount + summary.folderCount) об."
                self.calculatedSizeField?.stringValue = formattedSize
                self.calculatedContentsField?.stringValue = objectsText
            case .failure(let error):
                self.heroSizeLabel.stringValue = "Ошибка"
                self.calculatedSizeField?.stringValue = "Ошибка"
                self.window?.presentError(error)
            }
        }
    }

    @discardableResult
    private func addDetailRow(
        _ title: String,
        _ value: String,
        first: Bool = false,
        accent: Bool = false
    ) -> NSTextField {
        if !first {
            let sep = FPLayerView(color: FPStyle.stroke.withAlphaComponent(0.55))
            sep.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
            detailsStack.addArrangedSubview(sep)
        }
        let titleField = NSTextField(labelWithString: title.uppercased())
        titleField.font = FPStyle.headingFont(ofSize: 10, weight: .semibold)
        titleField.textColor = FPStyle.dimText
        titleField.widthAnchor.constraint(equalToConstant: 98).isActive = true
        titleField.setContentHuggingPriority(.required, for: .horizontal)

        let valueField = NSTextField(labelWithString: value)
        valueField.font = .monospacedDigitSystemFont(ofSize: 12, weight: accent ? .semibold : .regular)
        valueField.textColor = accent ? FPStyle.accent : FPStyle.text
        valueField.alignment = .right
        valueField.lineBreakMode = .byTruncatingMiddle
        valueField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [titleField, valueField])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        detailsStack.addArrangedSubview(row)
        return valueField
    }

    private func addPathRow(_ path: String) {
        let sep = FPLayerView(color: FPStyle.stroke.withAlphaComponent(0.55))
        sep.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        detailsStack.addArrangedSubview(sep)

        let titleField = NSTextField(labelWithString: "ПУТЬ")
        titleField.font = FPStyle.headingFont(ofSize: 10, weight: .semibold)
        titleField.textColor = FPStyle.dimText
        titleField.translatesAutoresizingMaskIntoConstraints = false

        let copyBtn = NSButton(title: "Копировать", target: self, action: #selector(copyInspectedPath(_:)))
        copyBtn.isBordered = false
        copyBtn.bezelStyle = .inline
        copyBtn.font = FPStyle.headingFont(ofSize: 10, weight: .semibold)
        copyBtn.contentTintColor = FPStyle.orange
        copyBtn.wantsLayer = true
        copyBtn.layer?.cornerRadius = 5
        copyBtn.layer?.backgroundColor = FPStyle.orange.withAlphaComponent(0.14).cgColor
        copyBtn.translatesAutoresizingMaskIntoConstraints = false
        copyBtn.widthAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true
        copyBtn.heightAnchor.constraint(equalToConstant: 19).isActive = true
        copyPathButton = copyBtn

        let header = NSStackView(views: [titleField, NSView(), copyBtn])
        header.orientation = .horizontal
        header.alignment = .centerY

        let pathField = NSTextField(wrappingLabelWithString: path)
        pathField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        pathField.textColor = FPStyle.text.withAlphaComponent(0.86)
        pathField.isSelectable = true
        pathField.lineBreakMode = .byCharWrapping
        pathField.maximumNumberOfLines = 3

        let container = NSStackView(views: [header, pathField])
        container.orientation = .vertical
        container.alignment = .width
        container.spacing = 5
        container.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 10, right: 14)
        detailsStack.addArrangedSubview(container)
    }

    private func addActionButton(title: String, symbol: String, action: Selector) {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.bezelStyle = .inline
        button.font = FPStyle.headingFont(ofSize: 11.5, weight: .semibold)
        button.contentTintColor = FPStyle.text
        if #available(macOS 11.0, *), let img = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            img.size = NSSize(width: 13, height: 13)
            button.image = img
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
        }
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.layer?.backgroundColor = FPStyle.controlStrong.cgColor
        button.layer?.borderColor = FPStyle.stroke.cgColor
        button.layer?.borderWidth = 0.6
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        actionsStack.addArrangedSubview(button)
    }

    @objc private func copyInspectedPath(_ sender: Any?) {
        guard let path = inspectedItems.first?.url.path else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        copyPathButton?.title = "Скопировано"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.copyPathButton?.title = "Копировать"
        }
    }

    @objc private func openInspected(_ sender: Any?) {
        for item in inspectedItems {
            NSWorkspace.shared.open(item.url)
        }
    }

    @objc private func revealInspectedInFinder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting(inspectedItems.map(\.url))
    }

    @objc private func sendInspectedToShelf(_ sender: Any?) {
        QyvroDropShelfModule.shared.add(urls: inspectedItems.map(\.url), reveal: true)
    }

    @objc private func analyzeInspectedFolder(_ sender: Any?) {
        guard let folder = inspectedItems.first(where: \.isDirectory)?.url else { return }
        QyvroDiskAnalyzerModule.shared.show(rootURL: folder)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private func formatted(_ date: Date?) -> String {
        guard let date else { return "—" }
        return Self.dateFormatter.string(from: date)
    }

    private func imageDimensions(_ url: URL) -> (width: Int, height: Int)? {
        FPMediaInfoCache.imageDimensions(at: url)
    }
}

/// Звёздочка «отобрано» в углу миниатюры.
///
/// Рисуется вручную, а не иконкой SF Symbols: нужен контрастный кружок под
/// звездой, иначе на светлых кадрах отметка теряется. Цвет берётся из темы,
/// поэтому значок следует за палитрой проводника.
final class FPSelectedFlagBadge: NSView {
    /// Ступень отметки. Когда её нет — значок показывается только под
    /// курсором и приглушённо, чтобы сетка не рябила от звёздочек.
    var level: FPFinderTagStore.FlagLevel = .none {
        didSet { needsDisplay = true }
    }

    var isFlagged: Bool {
        get { level != .none }
        set { level = newValue ? .candidate : .none }
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
        // Точка с кольцом: мелкая, не закрывает кадр и не спорит с ним
        // формой. Ступени различаются только цветом — значка внутри нет,
        // поэтому нечему выглядеть казённо на любом масштабе сетки.
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let dotRadius = min(bounds.width, bounds.height) * 0.28
        let ringRadius = min(bounds.width, bounds.height) * 0.46

        func circle(_ radius: CGFloat) -> NSBezierPath {
            NSBezierPath(ovalIn: NSRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
        }

        // Тёмная подложка под кольцом: на светлой картинке цвет иначе тонет.
        NSColor.black.withAlphaComponent(level == .none ? 0.22 : 0.34).setFill()
        circle(ringRadius + 1).fill()

        switch level {
        case .none:
            NSColor.white.withAlphaComponent(0.62).setStroke()
            let ring = circle(dotRadius)
            ring.lineWidth = 1.5
            ring.stroke()
        case .candidate, .confirmed:
            let color = level == .candidate ? FPStyle.orange : FPStyle.accent
            color.setFill()
            circle(dotRadius).fill()
            color.withAlphaComponent(0.45).setStroke()
            let ring = circle(ringRadius)
            ring.lineWidth = 1.5
            ring.stroke()
        }
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
    private let stateLock = NSLock()
    private var cancelled = false
    private var pendingShowWorkItem: DispatchWorkItem?
    private var runGeneration = 0
    private let queue = DispatchQueue(label: "Qyvro.FileTransfer", qos: .userInitiated)

    private var isCancelled: Bool {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return cancelled
        }
        set {
            stateLock.lock()
            cancelled = newValue
            stateLock.unlock()
        }
    }

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
        isCancelled = false
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
                if self.isCancelled { break }
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
        isCancelled = true
        titleField.stringValue = "Остановка после текущего объекта…"
    }
}


/// Счётчик версий в углу плитки: «×3» означает, что под этим файлом лежат
/// ещё две его производные. Нажатие раскрывает стопку.
final class FPVersionCountBadge: NSView {
    var count = 0 {
        didSet { needsDisplay = true }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard count > 1 else { return }
        let path = NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7)
        NSColor.black.withAlphaComponent(0.62).setFill()
        path.fill()
        FPStyle.orange.withAlphaComponent(0.85).setStroke()
        path.lineWidth = 1
        path.stroke()

        let text = "×\(count)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold),
            .foregroundColor: FPStyle.orange
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes
        )
    }
}

/// Кольцо занятости диска в нижней панели.
///
/// Небольшое и без подписей: цифры мешали бы, а картина «сколько занято и чем»
/// читается с одного взгляда. Сегменты кликабельны — нажатие открывает все
/// файлы этого типа на компьютере.
/// Общая палитра и категории занятости диска для кольца, полосы и легенды.
enum FPDiskUsagePalette {
    static var images: NSColor { FPStyle.accent }
    static var videos: NSColor { FPStyle.orange }
    static var apps: NSColor { FPStyle.defaultFolder }
    static var docsAndAudio: NSColor { NSColor(calibratedRed: 0.69, green: 0.50, blue: 1.0, alpha: 1.0) }
    /// Насыщенный индиго-синий вместо тусклого серого — гармонирует с палитрой
    /// и чётко отделяется от тёмной пустой канавки свободного места.
    static var other: NSColor { NSColor(calibratedRed: 0.36, green: 0.50, blue: 0.98, alpha: 0.92) }
    /// Тёмная пустая канавка для свободного места — контрастирует с занятыми
    /// сегментами и никогда не путается с «Система и прочее».
    static var freeTrack: NSColor { NSColor.white.withAlphaComponent(0.09) }
    static var freeOutline: NSColor { NSColor.white.withAlphaComponent(0.45) }

    struct Segment {
        let title: String
        let bytes: Int64
        let color: NSColor
        let filter: FPGridFilter?
        let folderURL: URL?
    }

    static func occupiedSegments(for snapshot: FPDiskUsage.Snapshot) -> [Segment] {
        var result: [Segment] = []
        if snapshot.images > 0 {
            result.append(Segment(
                title: "Картинки",
                bytes: snapshot.images,
                color: images,
                filter: .images,
                folderURL: nil
            ))
        }
        if snapshot.videos > 0 {
            result.append(Segment(
                title: "Видео",
                bytes: snapshot.videos,
                color: videos,
                filter: .videos,
                folderURL: nil
            ))
        }
        if snapshot.apps > 0 {
            result.append(Segment(
                title: "Программы",
                bytes: snapshot.apps,
                color: apps,
                filter: nil,
                folderURL: URL(fileURLWithPath: "/Applications", isDirectory: true)
            ))
        }
        if snapshot.docsAndAudio > 0 {
            result.append(Segment(
                title: "Аудио и доки",
                bytes: snapshot.docsAndAudio,
                color: docsAndAudio,
                filter: nil,
                folderURL: nil
            ))
        }
        if snapshot.other > 0 {
            result.append(Segment(
                title: "Система и прочее",
                bytes: snapshot.other,
                color: other,
                filter: nil,
                folderURL: nil
            ))
        }
        return result
    }

    /// Переводит байты занятых сегментов в углы/ширины внутри занятой доли,
    /// сохраняя честный пустой остаток для свободного места и гарантируя
    /// видимую минимальную толщину маленьким категориям.
    static func visualShares(
        for segments: [Segment],
        total: Int64,
        usedShare: CGFloat,
        minVisualShare: CGFloat
    ) -> [CGFloat] {
        guard total > 0, !segments.isEmpty, usedShare > 0 else { return [] }
        var shares = segments.map { CGFloat($0.bytes) / CGFloat(total) }
        var deficit: CGFloat = 0
        for index in shares.indices where shares[index] > 0 && shares[index] < minVisualShare {
            deficit += (minVisualShare - shares[index])
            shares[index] = minVisualShare
        }
        if deficit > 0 {
            let donorIndices = shares.indices.filter { shares[$0] > minVisualShare * 1.5 }
            let donorPool = donorIndices.reduce(CGFloat(0)) { $0 + (shares[$1] - minVisualShare) }
            if donorPool > 0 {
                let takeRatio = min(1, deficit / donorPool)
                for index in donorIndices {
                    shares[index] -= (shares[index] - minVisualShare) * takeRatio
                }
            }
        }
        let sum = shares.reduce(0, +)
        guard sum > 0 else { return shares }
        let scale = usedShare / sum
        return shares.map { $0 * scale }
    }
}

/// Кольцо занятости диска: рисует тёмную канавку свободного места и поверх неё
/// занятые сегменты по часовой стрелке от 12 часов.
final class FPDiskUsageRing: NSControl {
    private var snapshot = FPDiskUsage.Snapshot()
    /// Какой сегмент нажали: картинки, видео, папка или «Система и прочее».
    var onSegmentPicked: ((FPGridFilter) -> Void)?
    var onFolderPicked: ((URL) -> Void)?
    var onAnalyzePicked: (() -> Void)?

    override var intrinsicContentSize: NSSize { NSSize(width: 26, height: 26) }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    func update(_ value: FPDiskUsage.Snapshot) {
        snapshot = value
        toolTip = tooltipText()
        needsDisplay = true
    }

    private func tooltipText() -> String {
        func format(_ value: Int64) -> String {
            ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
        }
        guard snapshot.total > 0 else { return "Занятость диска" }
        var lines = [
            "Занято \(format(snapshot.used)) из \(format(snapshot.total))",
            "Свободно \(format(snapshot.free))"
        ]
        for segment in FPDiskUsagePalette.occupiedSegments(for: snapshot) {
            lines.append("\(segment.title): \(format(segment.bytes))")
        }
        return lines.joined(separator: "\n")
    }

    private func ringLayout() -> [(segment: FPDiskUsagePalette.Segment, sweep: CGFloat)] {
        guard snapshot.total > 0 else { return [] }
        let segments = FPDiskUsagePalette.occupiedSegments(for: snapshot)
        let usedShare = CGFloat(snapshot.usedFraction)
        let shares = FPDiskUsagePalette.visualShares(
            for: segments,
            total: snapshot.total,
            usedShare: usedShare,
            minVisualShare: 0.022
        )
        return zip(segments, shares).map { ($0.0, $0.1 * 360) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard snapshot.total > 0 else { return }
        let inset = bounds.insetBy(dx: 3.2, dy: 3.2)
        let center = NSPoint(x: inset.midX, y: inset.midY)
        let radius = min(inset.width, inset.height) / 2

        // Полная тёмная канавка: свободное место выглядит именно пустым, а не
        // вторым серым сегментом, сливающимся с «Остальным».
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        FPDiskUsagePalette.freeTrack.setStroke()
        track.lineWidth = 4.2
        track.stroke()

        let layout = ringLayout()
        let gap: CGFloat = layout.count > 1 ? 2.5 : 0
        var angle: CGFloat = 90 // 12 часов, далее по часовой стрелке (уменьшение угла)
        for entry in layout where entry.sweep > 0.5 {
            let drawnSweep = max(1.5, entry.sweep - gap)
            let path = NSBezierPath()
            path.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: angle,
                endAngle: angle - drawnSweep,
                clockwise: true
            )
            entry.segment.color.setStroke()
            path.lineWidth = 4.2
            path.lineCapStyle = .butt
            path.stroke()
            angle -= entry.sweep
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard snapshot.total > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        // Угол по часовой стрелке от 12 часов (0°..360°), совпадает с порядком отрисовки.
        var clockwiseDegrees = 90 - atan2(point.y - center.y, point.x - center.x) * 180 / .pi
        while clockwiseDegrees < 0 { clockwiseDegrees += 360 }
        while clockwiseDegrees >= 360 { clockwiseDegrees -= 360 }

        var cursor: CGFloat = 0
        for entry in ringLayout() {
            if clockwiseDegrees >= cursor, clockwiseDegrees < cursor + entry.sweep {
                if let filter = entry.segment.filter {
                    onSegmentPicked?(filter)
                } else if let folderURL = entry.segment.folderURL {
                    onFolderPicked?(folderURL)
                } else if let onAnalyzePicked {
                    onAnalyzePicked()
                } else {
                    super.mouseDown(with: event)
                }
                return
            }
            cursor += entry.sweep
        }
        super.mouseDown(with: event)
    }
}

/// Горизонтальная сегментированная полоса диска (как в macOS Storage):
/// цветные блоки слева показывают, чем занят SSD, а пустая тёмная часть справа
/// наглядно показывает остаток свободного места.
final class FPDiskUsageBar: NSView {
    private var snapshot = FPDiskUsage.Snapshot()
    var onSegmentPicked: ((FPGridFilter) -> Void)?
    var onFolderPicked: ((URL) -> Void)?
    var onAnalyzePicked: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ value: FPDiskUsage.Snapshot) {
        snapshot = value
        needsDisplay = true
    }

    private func segmentRects() -> [(segment: FPDiskUsagePalette.Segment, rect: NSRect)] {
        guard snapshot.total > 0, bounds.width > 4 else { return [] }
        let segments = FPDiskUsagePalette.occupiedSegments(for: snapshot)
        let usedShare = CGFloat(snapshot.usedFraction)
        let minShare = min(0.035, 5.0 / max(bounds.width, 1))
        let shares = FPDiskUsagePalette.visualShares(
            for: segments,
            total: snapshot.total,
            usedShare: usedShare,
            minVisualShare: minShare
        )
        let gap: CGFloat = 1.5
        var x: CGFloat = 0
        var out: [(FPDiskUsagePalette.Segment, NSRect)] = []
        for (index, pair) in zip(segments, shares).enumerated() {
            let rawWidth = pair.1 * bounds.width
            let drawWidth = max(2, rawWidth - (index + 1 < segments.count ? gap : 0))
            out.append((pair.0, NSRect(x: x, y: 0, width: drawWidth, height: bounds.height)))
            x += rawWidth
        }
        return out
    }

    override func draw(_ dirtyRect: NSRect) {
        let trackPath = NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4)
        FPDiskUsagePalette.freeTrack.setFill()
        trackPath.fill()

        for entry in segmentRects() {
            entry.segment.color.setFill()
            entry.rect.fill()
        }

        NSColor.white.withAlphaComponent(0.11).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 3.5, yRadius: 3.5)
        border.lineWidth = 1
        border.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for entry in segmentRects() where entry.rect.contains(point) {
            if let filter = entry.segment.filter {
                onSegmentPicked?(filter)
                return
            }
            if let folderURL = entry.segment.folderURL {
                onFolderPicked?(folderURL)
                return
            }
            if let onAnalyzePicked {
                onAnalyzePicked()
                return
            }
        }
        super.mouseDown(with: event)
    }
}
