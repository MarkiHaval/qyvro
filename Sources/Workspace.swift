import Cocoa
import Quartz
final class TabChip: FPLayerView {
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    var tabIndex: Int
    let isPinned: Bool
    private let symbolName: String
    private var onSelect: (() -> Void)?
    private var onClose: (() -> Void)?
    private var onSpringOpen: (() -> Void)?
    private var onFilesDropped: (([URL]) -> Bool)?
    private var onLiveDragBegan: ((TabChip, NSPoint) -> Bool)?
    private var onLiveDragMoved: ((TabChip, NSPoint) -> Void)?
    private var onLiveDragEnded: ((TabChip) -> Void)?
    private var onContextMenu: (() -> NSMenu?)?
    private var springOpenWorkItem: DispatchWorkItem?
    private var hoverTrackingArea: NSTrackingArea?
    private(set) var isActiveTab: Bool

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Перехватывает все клики внутри вкладки, кроме кнопки закрытия `×`.
    ///
    /// Без этого клики по заголовку (`NSTextField`) и иконке (`NSImageView`)
    /// возвращали их в `hitTest` с `mouseDownCanMoveWindow == true`, и окно
    /// перехватывало перетаскивание вкладки под перемещение самого окна.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let superview else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if !isPinned, closeButton.frame.contains(local) {
            return closeButton
        }
        return self
    }

    init(
        index: Int,
        title: String,
        tooltip: String,
        symbolName: String,
        pinned: Bool,
        active: Bool,
        onSelect: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onSpringOpen: (() -> Void)?,
        onFilesDropped: (([URL]) -> Bool)?,
        onLiveDragBegan: @escaping (TabChip, NSPoint) -> Bool,
        onLiveDragMoved: @escaping (TabChip, NSPoint) -> Void,
        onLiveDragEnded: @escaping (TabChip) -> Void,
        onContextMenu: @escaping () -> NSMenu?
    ) {
        tabIndex = index
        isPinned = pinned
        self.symbolName = symbolName
        self.onSelect = onSelect
        self.onClose = onClose
        self.onSpringOpen = onSpringOpen
        self.onFilesDropped = onFilesDropped
        self.onLiveDragBegan = onLiveDragBegan
        self.onLiveDragMoved = onLiveDragMoved
        self.onLiveDragEnded = onLiveDragEnded
        self.onContextMenu = onContextMenu
        isActiveTab = active
        let cyber = FPStyle.isCyberEditorial
        let aurora = FPStyle.isObsidianAurora
        let auroraTint = FPStyle.text.blended(withFraction: 0.22, of: FPStyle.accent) ?? FPStyle.text
        super.init(
            color: active ? FPStyle.tab : FPStyle.tabInactive,
            cornerRadius: cyber ? 7 : (aurora ? 9 : 10),
            borderColor: aurora
                ? (active ? auroraTint.withAlphaComponent(0.16) : NSColor.clear)
                : (active ? FPStyle.accent : FPStyle.stroke),
            borderWidth: aurora
                ? (active ? 0.6 : 0)
                : (active ? (cyber ? 1.25 : 1) : 0.5)
        )
        layer?.shadowColor = (cyber ? FPStyle.accent : NSColor.black).cgColor
        layer?.shadowOpacity = active ? (aurora ? 0.24 : (cyber ? 0.18 : 0.22)) : 0
        layer?.shadowRadius = cyber ? 12 : (aurora ? 10 : 8)
        layer?.shadowOffset = NSSize(width: 0, height: -2)
        buildUI(title: title, tooltip: tooltip, active: active)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Обновляет активный вид вкладки на месте, не пересоздавая сам вид:
    /// иначе `rebuildTabs()` в `mouseDown` удалял `TabChip` и ломал перетаскивание.
    func setActive(_ active: Bool) {
        isActiveTab = active
        let cyber = FPStyle.isCyberEditorial
        let aurora = FPStyle.isObsidianAurora
        let auroraTint = FPStyle.text.blended(withFraction: 0.22, of: FPStyle.accent) ?? FPStyle.text
        layer?.cornerRadius = cyber ? 7 : (aurora ? 9 : 10)
        layer?.backgroundColor = (active ? FPStyle.tab : FPStyle.tabInactive).cgColor
        layer?.borderColor = (aurora
            ? (active ? auroraTint.withAlphaComponent(0.16) : NSColor.clear)
            : (active ? FPStyle.accent : FPStyle.stroke)).cgColor
        layer?.borderWidth = aurora
            ? (active ? 0.6 : 0)
            : (active ? (cyber ? 1.25 : 1) : 0.5)
        layer?.shadowColor = (cyber ? FPStyle.accent : NSColor.black).cgColor
        layer?.shadowOpacity = active ? (aurora ? 0.24 : (cyber ? 0.18 : 0.22)) : 0
        layer?.shadowRadius = cyber ? 12 : (aurora ? 10 : 8)
        if aurora {
            iconView.contentTintColor = active ? FPStyle.accent : FPStyle.dimText
        } else {
            iconView.contentTintColor = active ? FPStyle.orange : (isPinned ? FPStyle.accent.withAlphaComponent(0.85) : FPStyle.dimText)
        }
        titleField.textColor = active ? FPStyle.text : FPStyle.dimText
        titleField.font = FPStyle.headingFont(
            ofSize: 12,
            weight: active && cyber ? .bold : (active ? .semibold : .medium)
        )
    }

    func setDraggingAppearance(_ dragging: Bool) {
        let aurora = FPStyle.isObsidianAurora
        layer?.zPosition = dragging ? 20 : 0
        if dragging {
            layer?.borderColor = FPStyle.accent.cgColor
            layer?.borderWidth = aurora ? 1.0 : 1.5
            layer?.shadowColor = (aurora ? NSColor.black : FPStyle.accent).cgColor
            layer?.shadowOpacity = 0.34
            layer?.shadowRadius = 14
        } else {
            setActive(isActiveTab)
        }
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
        guard let window else { return }
        let wasMovable = window.isMovable
        window.isMovable = false
        defer { window.isMovable = wasMovable }

        let startPointInWindow = event.locationInWindow
        var isDragging = false

        window.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp],
            timeout: .infinity,
            mode: .eventTracking
        ) { [weak self] nextEvent, stop in
            guard let self, let nextEvent else {
                stop.pointee = true
                return
            }
            switch nextEvent.type {
            case .leftMouseDragged:
                if !isDragging {
                    let dx = nextEvent.locationInWindow.x - startPointInWindow.x
                    let dy = nextEvent.locationInWindow.y - startPointInWindow.y
                    guard hypot(dx, dy) >= 4 else { return }
                    guard self.onLiveDragBegan?(self, startPointInWindow) == true else { return }
                    isDragging = true
                }
                self.onLiveDragMoved?(self, nextEvent.locationInWindow)
            case .leftMouseUp:
                if isDragging {
                    self.onLiveDragEnded?(self)
                }
                stop.pointee = true
            default:
                break
            }
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2, !isPinned {
            onClose?()
            return
        }
        super.otherMouseUp(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onContextMenu?()
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
        guard !isActiveTab, springOpenWorkItem == nil else { return }
        let hover = FPStyle.isObsidianAurora
            ? NSColor(calibratedWhite: 1.0, alpha: 0.055)
            : FPStyle.tab.withAlphaComponent(0.72)
        animateBackground(hover)
    }

    override func mouseExited(with event: NSEvent) {
        guard !isActiveTab, springOpenWorkItem == nil else { return }
        animateBackground(FPStyle.tabInactive)
    }

    private func animateBackground(_ color: NSColor) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            layer?.backgroundColor = color.cgColor
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDragHover(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDragHover(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        cancelSpringOpen()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender.draggingPasteboard)
        cancelSpringOpen()
        guard !urls.isEmpty else { return false }
        return onFilesDropped?(urls) ?? false
    }

    private func updateDragHover(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(from: sender.draggingPasteboard).isEmpty else {
            cancelSpringOpen()
            return []
        }
        layer?.borderColor = FPStyle.orange.cgColor
        layer?.borderWidth = 1.5
        layer?.shadowColor = FPStyle.orange.cgColor
        layer?.shadowOpacity = 0.34
        layer?.shadowRadius = 10
        if springOpenWorkItem == nil, let onSpringOpen {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.springOpenWorkItem = nil
                onSpringOpen()
            }
            springOpenWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.85, execute: work)
        }
        return .move
    }

    private func cancelSpringOpen() {
        springOpenWorkItem?.cancel()
        springOpenWorkItem = nil
        layer?.borderColor = (isActiveTab ? FPStyle.accent : FPStyle.stroke).cgColor
        layer?.borderWidth = isActiveTab ? (FPStyle.isCyberEditorial ? 1.25 : 1) : 0.5
        layer?.shadowColor = (FPStyle.isCyberEditorial ? FPStyle.accent : NSColor.black).cgColor
        layer?.shadowOpacity = isActiveTab ? (FPStyle.isCyberEditorial ? 0.18 : 0.22) : 0
        layer?.shadowRadius = FPStyle.isCyberEditorial ? 12 : 8
    }

    private func buildUI(title: String, tooltip: String, active: Bool) {
        toolTip = isPinned ? "\(title) — \(tooltip)" : tooltip
        heightAnchor.constraint(equalToConstant: 32).isActive = true

        if #available(macOS 11.0, *) {
            iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
                ?? NSImage(systemSymbolName: "folder.fill", accessibilityDescription: title)
        }
        iconView.contentTintColor = FPStyle.isObsidianAurora
            ? (active ? FPStyle.text : FPStyle.dimText)
            : (active ? FPStyle.orange : (isPinned ? FPStyle.accent.withAlphaComponent(0.85) : FPStyle.dimText))
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        if isPinned {
            // Закреплённая вкладка — компактная иконка слева, как в браузере.
            widthAnchor.constraint(equalToConstant: 38).isActive = true
            setContentHuggingPriority(.required, for: .horizontal)
            setContentCompressionResistancePriority(.required, for: .horizontal)
            addSubview(iconView)
            NSLayoutConstraint.activate([
                iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
                iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 16),
                iconView.heightAnchor.constraint(equalToConstant: 16)
            ])
            return
        }

        // Компактная длина вкладки (134 pt вместо 176 pt): в полосу помещается
        // больше папок сразу, а приоритет 220 ниже удержания сайдбара (260) и
        // `windowSizeStayPut` (500), чтобы ресайз окна всегда оставался свободным.
        let preferredWidth = widthAnchor.constraint(equalToConstant: 134)
        preferredWidth.priority = NSLayoutConstraint.Priority(220)
        preferredWidth.isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
        setContentHuggingPriority(NSLayoutConstraint.Priority(180), for: .horizontal)
        setContentCompressionResistancePriority(NSLayoutConstraint.Priority(190), for: .horizontal)

        titleField.stringValue = title
        titleField.textColor = active ? FPStyle.text : FPStyle.dimText
        titleField.font = FPStyle.headingFont(
            ofSize: 12,
            weight: active && FPStyle.isCyberEditorial ? .bold : (active ? .semibold : .medium)
        )
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.setContentHuggingPriority(NSLayoutConstraint.Priority(150), for: .horizontal)
        titleField.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(190), for: .horizontal)
        titleField.translatesAutoresizingMaskIntoConstraints = false

        if #available(macOS 11.0, *), let image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close") {
            image.size = NSSize(width: 10, height: 10)
            closeButton.image = image
            closeButton.imagePosition = .imageOnly
            closeButton.title = ""
        } else {
            closeButton.title = "x"
        }
        closeButton.font = .systemFont(ofSize: 10, weight: .bold)
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.contentTintColor = FPStyle.dimText
        closeButton.toolTip = "Закрыть вкладку"
        closeButton.target = self
        closeButton.action = #selector(closePressed(_:))
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(titleField)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 15),
            iconView.heightAnchor.constraint(equalToConstant: 15),
            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            titleField.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18)
        ])
    }

    @objc private func closePressed(_ sender: Any?) {
        onClose?()
    }
}

struct FPPaneSession: Codable {
    var tabPaths: [String]
    var activeIndex: Int
    var pinnedCount: Int? = nil
}

struct FPWindowSession: Codable {
    var panes: [FPPaneSession]
    var activePaneIndex: Int
    var paneFractions: [Double]?
    var alwaysOnTop: Bool?
    var frameX: Double
    var frameY: Double
    var frameWidth: Double
    var frameHeight: Double
}

private final class QyvroNoWindowDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
}

private final class QyvroNoWindowDragStackView: NSStackView {
    override var mouseDownCanMoveWindow: Bool { false }
}

/// Custom explorer window that prevents macOS titlebar window-dragging from
/// hijacking `TabChip` drag gestures inside the top `.fullSizeContentView` strip.
final class QyvroExplorerWindow: NSWindow {
    private var lockedMovableForTabDrag = false

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown,
           let hit = contentView?.hitTest(event.locationInWindow),
           Self.isInsideInteractiveTitlebarControl(hit) {
            lockedMovableForTabDrag = true
            isMovable = false
        }
        super.sendEvent(event)
        if event.type == .leftMouseUp && lockedMovableForTabDrag {
            lockedMovableForTabDrag = false
            isMovable = true
        }
    }

    private static func isInsideInteractiveTitlebarControl(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let v = current {
            if v is TabChip || v is QyvroTabStripScrollView || v is NSControl {
                return true
            }
            if v is FPWindowZoomSpacer {
                return false
            }
            current = v.superview
        }
        return false
    }
}

final class FPWindowZoomSpacer: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.performZoom(nil)
        } else {
            window?.performDrag(with: event)
        }
    }
}

/// Горизонтальная полоса вкладок без видимых скроллбаров.
///
/// При 1–4 вкладках сжимается вплотную к содержимому, чтобы кнопка «+» стояла
/// сразу за последней вкладкой. Когда вкладок много или окно сужается,
/// полоса сначала даёт вкладкам ужаться до 72 pt, а затем переходит в
/// горизонтальную прокрутку и никогда не блокирует сужение окна.
private final class QyvroTabStripScrollView: NSScrollView {
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Полоса вкладок лежит в верхней зоне `.fullSizeContentView`. При
        // `automaticallyAdjustsContentInsets == true` AppKit добавляет сюда
        // `contentInsets.top = 27 pt`, из-за чего `NSClipView.hitTest` отрезает
        // верхние 27 pt из 32 pt и вкладки перестают нажиматься и перетаскиваться.
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsets()
        contentView.automaticallyAdjustsContentInsets = false
        contentView.contentInsets = NSEdgeInsets()
        drawsBackground = false
        borderType = .noBorder
        hasHorizontalScroller = false
        hasVerticalScroller = false
        horizontalScrollElasticity = .automatic
        verticalScrollElasticity = .none
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func scrollWheel(with event: NSEvent) {
        guard let documentView, documentView.bounds.width > contentView.bounds.width + 1 else {
            super.scrollWheel(with: event)
            return
        }
        let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
            ? -event.scrollingDeltaX
            : -event.scrollingDeltaY
        let maxX = max(0, documentView.bounds.width - contentView.bounds.width)
        var origin = contentView.bounds.origin
        origin.x = min(max(origin.x + delta, 0), maxX)
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }
}

final class BrowserPane: NSView {
    weak var workspace: WorkspaceView?

    private let tabStrip = QyvroTabStripScrollView()
    private let tabBar = QyvroNoWindowDragStackView()
    private let stageContainer = NSView()
    private let contentView = NSView()
    private var stageLeading: NSLayoutConstraint?
    private var stageTrailing: NSLayoutConstraint?
    private var stageTop: NSLayoutConstraint?
    private var stageBottom: NSLayoutConstraint?
    private weak var rootStack: NSStackView?
    private weak var tabControlsView: NSStackView?
    private var chromeToolbarButtons: [NSButton] = []
    private weak var layoutSwitcherButton: NSButton?
    private let studioDiskGauge = QyvroCircularGaugeButton(showPercentLabel: false)
    private weak var studioSettingsButton: NSButton?
    private weak var alwaysOnTopButton: NSButton?
    private weak var clipboardToolbarButton: NSButton?
    private weak var shelfButton: QyvroShelfToolbarButton?
    private var shelfButtonWidthConstraint: NSLayoutConstraint?
    private var dropShelfObserver: NSObjectProtocol?
    private var alwaysOnTopEnabled = false
    private var currentLayout: QyvroWorkspaceLayout = QyvroWorkspaceLayout.current
    private var isLeadingPaneInWorkspace = true
    private var tabs: [FilePanel] = []
    private var activeIndex = 0
    private(set) var pinnedCount = 0
    private var closedTabURLs: [URL] = []
    private var dragGrabOffsetX: CGFloat = 0
    private var dragDidReorder = false

    var activePanel: FilePanel? {
        guard activeIndex >= 0 && activeIndex < tabs.count else { return nil }
        return tabs[activeIndex]
    }

    var tabURLs: [URL] {
        tabs.map(\.currentURL)
    }

    func refreshLocalization() {
        clipboardToolbarButton?.title = L("Буфер", "Clipboard")
        updateShelfButton()
        tabs.forEach { $0.refreshLocalization() }
        rebuildTabs()
    }

    func refreshActivePanel(force: Bool = false) {
        activePanel?.refreshCurrentDirectory(force: force)
    }

    var sessionState: FPPaneSession {
        FPPaneSession(
            tabPaths: tabs.map { $0.isRecentItemsView ? "qyvro://recents" : $0.currentURL.path },
            activeIndex: activeIndex,
            pinnedCount: pinnedCount > 0 ? pinnedCount : nil
        )
    }

    init(startURL: URL) {
        super.init(frame: .zero)
        buildUI()
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged(_:)), name: .fpThemeDidChange, object: nil)
        dropShelfObserver = NotificationCenter.default.addObserver(
            forName: .qyvroDropShelfDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateShelfButton()
        }
        updateShelfButton()
        addTab(url: startURL, activate: true)
    }

    deinit {
        if let dropShelfObserver {
            NotificationCenter.default.removeObserver(dropShelfObserver)
        }
        NotificationCenter.default.removeObserver(self)
    }

    convenience init(session: FPPaneSession) {
        let manager = FileManager.default
        var restoredEntries: [(url: URL, isRecents: Bool)] = []
        var restoredPinned = 0
        let savedPinned = max(0, session.pinnedCount ?? 0)
        for (idx, rawPath) in session.tabPaths.enumerated() {
            if rawPath == "qyvro://recents" {
                restoredEntries.append((manager.homeDirectoryForCurrentUser, true))
                if idx < savedPinned { restoredPinned += 1 }
            } else {
                let url = URL(fileURLWithPath: rawPath, isDirectory: true).standardizedFileURL
                if manager.fileExists(atPath: url.path) {
                    restoredEntries.append((url, false))
                    if idx < savedPinned { restoredPinned += 1 }
                }
            }
        }
        if restoredEntries.isEmpty {
            restoredEntries = [(manager.homeDirectoryForCurrentUser, false)]
        }
        self.init(startURL: restoredEntries[0].url)
        if restoredEntries[0].isRecents {
            tabs[0].showRecentItems(addingToHistory: false)
        }
        for entry in restoredEntries.dropFirst() {
            addTab(url: entry.url, activate: false)
            if entry.isRecents {
                tabs.last?.showRecentItems(addingToHistory: false)
            }
        }
        pinnedCount = min(restoredPinned, tabs.count)
        rebuildTabs()
        selectTab(at: min(max(session.activeIndex, 0), tabs.count - 1))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setActive(_ active: Bool) {
        layer?.borderWidth = 0
        layer?.borderColor = nil
        if FPStyle.isObsidianAurora {
            layer?.backgroundColor = NSColor.clear.cgColor
        } else {
            layer?.backgroundColor = (active ? FPStyle.pane : FPStyle.paneInactive).cgColor
        }
    }

    @objc private func themeChanged(_ notification: Notification) {
        let aurora = FPStyle.isObsidianAurora
        let tint = FPStyle.text.blended(withFraction: 0.22, of: FPStyle.accent) ?? FPStyle.text
        layer?.backgroundColor = aurora ? NSColor.clear.cgColor : FPStyle.pane.cgColor
        applyStageChrome()
        for btn in chromeToolbarButtons {
            btn.contentTintColor = aurora ? FPStyle.dimText : FPStyle.orange
            btn.layer?.cornerRadius = FPStyle.isCyberEditorial ? 5 : 9
            btn.layer?.backgroundColor = (aurora ? tint.withAlphaComponent(0.055) : FPStyle.control).cgColor
            btn.layer?.borderColor = (aurora ? tint.withAlphaComponent(0.09) : FPStyle.stroke).cgColor
        }
        studioDiskGauge.needsDisplay = true
        updateAlwaysOnTopButton()
        updateShelfButton()
        updateLayoutSwitcherIcon()
        rebuildTabs()
    }

    private func applyStageChrome() {
        let aurora = FPStyle.isObsidianAurora
        let tint = FPStyle.text.blended(withFraction: 0.22, of: FPStyle.accent) ?? FPStyle.text
        let isStudio = (currentLayout == .studioCanvas)
        if isStudio {
            // Парящий скруглённый «остров» внутри глубокой внешней рамки
            // (как в Ron Design и RhythmoTune): чёткое разделение слоёв без
            // лишних рамок вокруг отдельных кнопок.
            tabControlsView?.layer?.backgroundColor = NSColor.clear.cgColor
            tabControlsView?.layer?.borderWidth = 0
            contentView.layer?.cornerRadius = 18
            contentView.layer?.masksToBounds = true
            let base = FPStyle.pane.withAlphaComponent(max(0.76, FPStyle.pane.alphaComponent))
            contentView.layer?.backgroundColor = base.cgColor
            contentView.layer?.borderColor = tint.withAlphaComponent(0.11).cgColor
            contentView.layer?.borderWidth = 0.75
        } else {
            tabControlsView?.layer?.backgroundColor = FPStyle.tabBar.cgColor
            tabControlsView?.layer?.borderColor = (aurora ? tint.withAlphaComponent(0.08) : FPStyle.stroke).cgColor
            tabControlsView?.layer?.borderWidth = 0.5
            contentView.layer?.cornerRadius = 0
            contentView.layer?.masksToBounds = false
            contentView.layer?.backgroundColor = NSColor.clear.cgColor
            contentView.layer?.borderWidth = 0
        }
    }

    func updateDiskGauge(_ snapshot: FPDiskUsage.Snapshot) {
        studioDiskGauge.update(snapshot)
    }

    func updateStudioSearch(query: String, isGlobalScope: Bool) {
        for tab in tabs {
            tab.studioHeaderView.updateSearch(query: query, isGlobalScope: isGlobalScope)
        }
    }

    func applyWorkspaceLayout(_ layout: QyvroWorkspaceLayout, isLeadingPane: Bool) {
        currentLayout = layout
        isLeadingPaneInWorkspace = isLeadingPane
        guard let rootStack, let tabControlsView else { return }

        // В макете «Рейл» вкладки переезжают в нижнюю полосу, освобождая
        // верх под чистую рабочую шапку.
        let tabsOnBottom = (layout == .edgeRail)
        let currentOrder = rootStack.arrangedSubviews
        let desiredFirst: NSView = tabsOnBottom ? stageContainer : tabControlsView
        if currentOrder.first !== desiredFirst {
            rootStack.removeArrangedSubview(tabControlsView)
            rootStack.removeArrangedSubview(stageContainer)
            if tabsOnBottom {
                rootStack.addArrangedSubview(stageContainer)
                rootStack.addArrangedSubview(tabControlsView)
            } else {
                rootStack.addArrangedSubview(tabControlsView)
                rootStack.addArrangedSubview(stageContainer)
            }
        }

        let isStudio = (layout == .studioCanvas)
        // В «Студии» и «Подиуме» нет боковой панели, поэтому крайняя левая
        // панель освобождает 80 pt слева под системные кнопки светофора.
        let clearsTrafficLights = (layout == .floatingDock || isStudio) && isLeadingPane
        let leftInset: CGFloat = clearsTrafficLights ? 80 : 10
        tabControlsView.edgeInsets = NSEdgeInsets(
            top: 6,
            left: leftInset,
            bottom: isStudio ? 4 : 6,
            right: isStudio ? 12 : 10
        )

        stageLeading?.constant = isStudio ? 10 : 0
        stageTrailing?.constant = isStudio ? -10 : 0
        stageTop?.constant = isStudio ? 2 : 0
        stageBottom?.constant = isStudio ? -10 : 0

        studioDiskGauge.isHidden = !isStudio
        studioSettingsButton?.isHidden = !isStudio

        let dockClearance: CGFloat = (layout == .floatingDock) ? 54 : 0
        for tab in tabs {
            tab.setFloatingDockClearance(dockClearance)
            tab.setStudioMode(isStudio)
        }
        applyStageChrome()
        updateLayoutSwitcherIcon()
    }

    private func updateLayoutSwitcherIcon() {
        guard let button = layoutSwitcherButton else { return }
        if #available(macOS 11.0, *),
           let image = NSImage(systemSymbolName: currentLayout.symbol, accessibilityDescription: "Макет и темы") {
            image.size = NSSize(width: 15, height: 15)
            button.image = image
        }
        button.toolTip = "Макет: \(currentLayout.shortTitle) · нажмите для смены вида и темы"
    }

    private func buildUI() {
        wantsLayer = true
        layer?.backgroundColor = FPStyle.pane.cgColor
        layer?.cornerRadius = 0
        layer?.borderWidth = 0
        translatesAutoresizingMaskIntoConstraints = false

        tabBar.orientation = .horizontal
        tabBar.spacing = 8
        tabBar.alignment = .centerY
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.setHuggingPriority(NSLayoutConstraint.Priority(160), for: .horizontal)
        tabBar.setContentHuggingPriority(NSLayoutConstraint.Priority(180), for: .horizontal)
        tabBar.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(190), for: .horizontal)

        let tabDocument = QyvroNoWindowDragView()
        tabDocument.translatesAutoresizingMaskIntoConstraints = false
        tabDocument.addSubview(tabBar)
        tabStrip.documentView = tabDocument
        tabStrip.setContentHuggingPriority(NSLayoutConstraint.Priority(180), for: .horizontal)
        tabStrip.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(190), for: .horizontal)

        let fitTabsInsideStrip = tabBar.widthAnchor.constraint(lessThanOrEqualTo: tabStrip.contentView.widthAnchor)
        fitTabsInsideStrip.priority = NSLayoutConstraint.Priority(240)
        let hugTabsInStrip = tabStrip.widthAnchor.constraint(equalTo: tabBar.widthAnchor)
        hugTabsInStrip.priority = NSLayoutConstraint.Priority(230)
        NSLayoutConstraint.activate([
            tabStrip.heightAnchor.constraint(equalToConstant: 32),
            tabStrip.widthAnchor.constraint(greaterThanOrEqualToConstant: 52),
            tabBar.leadingAnchor.constraint(equalTo: tabDocument.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: tabDocument.trailingAnchor),
            tabBar.topAnchor.constraint(equalTo: tabDocument.topAnchor),
            tabBar.bottomAnchor.constraint(equalTo: tabDocument.bottomAnchor),
            tabDocument.heightAnchor.constraint(equalTo: tabStrip.contentView.heightAnchor),
            fitTabsInsideStrip,
            hugTabsInStrip
        ])

        let addButton = iconButton(symbol: "plus", fallback: "+", tooltip: "Новая вкладка", action: #selector(newTab(_:)))
        let tabGroupsButton = iconButton(
            symbol: "rectangle.3.group",
            fallback: "▤",
            tooltip: "Сохранённые группы вкладок",
            action: #selector(showSavedTabGroups(_:))
        )
        let tabSpacer = FPWindowZoomSpacer()
        tabSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(150), for: .horizontal)
        tabSpacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(150), for: .horizontal)

        let layoutButton = iconButton(
            symbol: currentLayout.symbol,
            fallback: "⊞",
            tooltip: "Макет и темы (Подиум / Рейл / Сайдбар)",
            action: #selector(showLayoutAndThemeMenu(_:))
        )
        layoutSwitcherButton = layoutButton
        let commandPaletteButton = iconButton(
            symbol: "command",
            fallback: "⌘",
            tooltip: "Палитра команд (⌘K)",
            action: #selector(showCommandPalette(_:))
        )
        let clipboardButton = labeledIconButton(
            title: L("Буфер", "Clipboard"),
            symbol: "clipboard",
            tooltip: L("История буфера обмена (\(QyvroClipboardShortcut.displayName))", "Clipboard History (\(QyvroClipboardShortcut.displayName))"),
            action: #selector(showClipboard(_:))
        )
        clipboardToolbarButton = clipboardButton
        let shelfBtn = makeShelfToolbarButton()
        shelfButton = shelfBtn
        let previewButton = iconButton(
            symbol: "sidebar.right",
            fallback: "◧",
            tooltip: "Панель предпросмотра (⌥⌘P)",
            action: #selector(togglePreviewPanel(_:))
        )
        let pinButton = iconButton(
            symbol: "pin",
            fallback: "•",
            tooltip: "Оставить Qyvro поверх остальных окон",
            action: #selector(toggleAlwaysOnTop(_:))
        )
        let settingsBtn = iconButton(
            symbol: "slider.horizontal.3",
            fallback: "⚙",
            tooltip: "Настройки и темы (⌘,)",
            action: #selector(openSettingsFromMenu(_:))
        )
        studioSettingsButton = settingsBtn
        studioDiskGauge.onClick = { [weak self] in
            self?.workspace?.openDiskAnalyzer(nil)
        }
        studioDiskGauge.isHidden = (currentLayout != .studioCanvas)
        settingsBtn.isHidden = (currentLayout != .studioCanvas)

        alwaysOnTopButton = pinButton
        chromeToolbarButtons = [
            tabGroupsButton,
            addButton,
            layoutButton,
            previewButton,
            clipboardButton,
            settingsBtn,
            commandPaletteButton
        ]
        let tabControls = NSStackView(
            views: [
                tabGroupsButton,
                tabStrip,
                addButton,
                tabSpacer,
                studioDiskGauge,
                layoutButton,
                previewButton,
                shelfBtn,
                clipboardButton,
                pinButton,
                settingsBtn,
                commandPaletteButton
            ]
        )
        tabControls.detachesHiddenViews = true
        tabControls.orientation = .horizontal
        tabControls.spacing = 5
        tabControls.alignment = .centerY
        tabControls.setHuggingPriority(NSLayoutConstraint.Priority(150), for: .horizontal)
        tabControls.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        tabControls.translatesAutoresizingMaskIntoConstraints = false
        tabControls.wantsLayer = true
        tabControls.layer?.backgroundColor = FPStyle.tabBar.cgColor
        tabControls.layer?.borderColor = (FPStyle.isObsidianAurora ? NSColor.white.withAlphaComponent(0.06) : FPStyle.stroke).cgColor
        tabControls.layer?.borderWidth = 0.5
        tabControlsView = tabControls

        stageContainer.translatesAutoresizingMaskIntoConstraints = false
        stageContainer.wantsLayer = true
        stageContainer.layer?.backgroundColor = NSColor.clear.cgColor

        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        stageContainer.addSubview(contentView)

        let sLead = contentView.leadingAnchor.constraint(equalTo: stageContainer.leadingAnchor)
        let sTrail = contentView.trailingAnchor.constraint(equalTo: stageContainer.trailingAnchor)
        let sTop = contentView.topAnchor.constraint(equalTo: stageContainer.topAnchor)
        let sBottom = contentView.bottomAnchor.constraint(equalTo: stageContainer.bottomAnchor)
        stageLeading = sLead
        stageTrailing = sTrail
        stageTop = sTop
        stageBottom = sBottom

        let root = NSStackView(views: [tabControls, stageContainer])
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        rootStack = root
        addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
            tabControls.widthAnchor.constraint(equalTo: root.widthAnchor),
            stageContainer.widthAnchor.constraint(equalTo: root.widthAnchor),
            tabControls.heightAnchor.constraint(equalToConstant: 42),
            stageContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),
            sLead, sTrail, sTop, sBottom
        ])
        applyStageChrome()
    }

    private func iconButton(symbol: String, fallback: String, tooltip: String, action: Selector) -> NSButton {
        let button = FPToolbarButton()
        if #available(macOS 11.0, *), let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) {
            image.size = NSSize(width: 15, height: 15)
            button.image = image
            button.title = ""
            button.imagePosition = .imageOnly
        } else {
            button.title = fallback
            button.font = .systemFont(ofSize: 11, weight: .medium)
        }
        let aurora = FPStyle.isObsidianAurora
        button.bezelStyle = .inline
        button.isBordered = false
        button.toolTip = tooltip
        button.contentTintColor = aurora ? FPStyle.dimText : FPStyle.orange
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.wantsLayer = true
        button.layer?.cornerRadius = FPStyle.isCyberEditorial ? 5 : 9
        button.layer?.backgroundColor = FPStyle.control.cgColor
        button.layer?.borderColor = (aurora ? NSColor.white.withAlphaComponent(0.07) : FPStyle.stroke).cgColor
        button.layer?.borderWidth = 0.5
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }

    private func labeledIconButton(
        title: String,
        symbol: String,
        tooltip: String,
        action: Selector
    ) -> NSButton {
        let aurora = FPStyle.isObsidianAurora
        let button = FPToolbarButton(title: title, target: self, action: action)
        button.bezelStyle = .inline
        button.isBordered = false
        button.font = FPStyle.bodyFont(ofSize: 11.5, weight: aurora ? .medium : .semibold)
        button.contentTintColor = aurora ? FPStyle.dimText : FPStyle.orange
        button.toolTip = tooltip
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.imageScaling = .scaleProportionallyDown
        button.alignment = .center
        if #available(macOS 11.0, *),
           let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) {
            image.size = NSSize(width: 14, height: 14)
            button.image = image
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        button.wantsLayer = true
        button.layer?.cornerRadius = FPStyle.isCyberEditorial ? 5 : 9
        button.layer?.backgroundColor = FPStyle.control.cgColor
        button.layer?.borderColor = (aurora ? NSColor.white.withAlphaComponent(0.07) : FPStyle.stroke).cgColor
        button.layer?.borderWidth = 0.5
        button.widthAnchor.constraint(equalToConstant: 70).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }

    private func makeShelfToolbarButton() -> QyvroShelfToolbarButton {
        let button = QyvroShelfToolbarButton(frame: .zero)
        button.title = "Полка"
        button.target = self
        button.action = #selector(showDropShelf(_:))
        button.bezelStyle = .inline
        button.isBordered = false
        button.font = FPStyle.bodyFont(ofSize: 11.5, weight: .semibold)
        button.contentTintColor = FPStyle.orange
        button.toolTip = "Полка временного сбора (⌥⌘S) — перетащите файлы сюда или нажмите"
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.imageScaling = .scaleProportionallyDown
        button.alignment = .center
        if #available(macOS 11.0, *),
           let image = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: "Полка сбора") {
            image.size = NSSize(width: 14, height: 14)
            button.image = image
        }
        button.onURLsDropped = { urls in
            QyvroDropShelfModule.shared.add(urls: urls, reveal: false)
        }
        button.onDragHoverEnded = { [weak self] in
            self?.updateShelfButton()
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        button.wantsLayer = true
        button.layer?.cornerRadius = FPStyle.isCyberEditorial ? 5 : 9
        button.layer?.backgroundColor = FPStyle.control.cgColor
        button.layer?.borderColor = FPStyle.stroke.cgColor
        button.layer?.borderWidth = 0.5
        let widthConstraint = button.widthAnchor.constraint(equalToConstant: 66)
        widthConstraint.isActive = true
        shelfButtonWidthConstraint = widthConstraint
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }

    private func updateShelfButton() {
        guard let button = shelfButton else { return }
        let aurora = FPStyle.isObsidianAurora
        let count = QyvroDropShelfModule.shared.store.count
        let hasItems = count > 0
        button.title = hasItems ? L("Полка · \(count)", "Shelf · \(count)") : L("Полка", "Shelf")
        shelfButtonWidthConstraint?.constant = hasItems ? 84 : 66
        button.contentTintColor = hasItems
            ? FPStyle.accent
            : (aurora ? FPStyle.dimText : FPStyle.orange)
        button.layer?.cornerRadius = FPStyle.isCyberEditorial ? 5 : 9
        button.layer?.backgroundColor = (hasItems
            ? FPStyle.accent.withAlphaComponent(0.16)
            : FPStyle.control).cgColor
        button.layer?.borderColor = (hasItems
            ? FPStyle.accent.withAlphaComponent(0.45)
            : (aurora ? NSColor.white.withAlphaComponent(0.07) : FPStyle.stroke)).cgColor
        button.layer?.borderWidth = hasItems ? 0.8 : 0.5
        button.toolTip = hasItems
            ? "На полке временного сбора объектов: \(count) (⌥⌘S)"
            : "Полка временного сбора (⌥⌘S) — перетащите файлы сюда или нажмите"
    }

    func setAlwaysOnTop(_ enabled: Bool) {
        alwaysOnTopEnabled = enabled
        updateAlwaysOnTopButton()
        // A momentary NSButton restores its pre-click image after sending the
        // action. Reapply our persistent pin artwork on the following main-loop
        // turn, once AppKit has completed mouse-up handling.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.alwaysOnTopEnabled == enabled else { return }
            self.updateAlwaysOnTopButton()
        }
    }

    private func updateAlwaysOnTopButton() {
        guard let button = alwaysOnTopButton else { return }
        // NSButton's default momentary style resets `state` after its action.
        // Keep the persistent window mode separately so the pin remains filled
        // and highlighted for as long as the window itself is floating.
        let enabled = alwaysOnTopEnabled
        if #available(macOS 11.0, *),
           let image = NSImage(
               systemSymbolName: enabled ? "pin.fill" : "pin",
               accessibilityDescription: enabled ? "Окно закреплено поверх остальных" : "Закрепить окно поверх остальных"
           ) {
            let color = enabled ? FPStyle.orange : FPStyle.dimText
            let baseConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            let paletteConfiguration = NSImage.SymbolConfiguration(paletteColors: [color])
            let configuration = baseConfiguration.applying(paletteConfiguration)
            let coloredImage = image.withSymbolConfiguration(configuration) ?? image
            coloredImage.isTemplate = false
            coloredImage.size = NSSize(width: 14, height: 14)
            button.image = coloredImage
            button.title = ""
            button.imagePosition = .imageOnly
        }
        button.contentTintColor = enabled ? FPStyle.orange : FPStyle.dimText
        button.layer?.backgroundColor = (enabled
            ? FPStyle.orange.withAlphaComponent(0.22)
            : FPStyle.control).cgColor
        button.layer?.borderColor = (enabled
            ? FPStyle.orange.withAlphaComponent(0.72)
            : FPStyle.stroke).cgColor
        button.toolTip = enabled
            ? "Qyvro остаётся поверх остальных окон — нажмите, чтобы отключить"
            : "Оставить Qyvro поверх остальных окон"
        button.setAccessibilityValue(enabled ? "Включено" : "Выключено")
    }

    func addTab(url: URL, activate: Bool) {
        let panel = FilePanel(startURL: url)
        configure(panel)
        panel.setFloatingDockClearance(currentLayout == .floatingDock ? 54 : 0)
        panel.setStudioMode(currentLayout == .studioCanvas)
        tabs.append(panel)
        if activate {
            activeIndex = tabs.count - 1
        }
        rebuildTabs()
        showActivePanel()
        workspace?.onSessionChanged?()
    }

    private func configure(_ panel: FilePanel) {
        panel.onActivated = { [weak self] activePanel in
            guard let self else { return }
            self.workspace?.activate(panel: activePanel, in: self)
        }
        panel.onURLChanged = { [weak self] _ in
            self?.rebuildTabs()
            self?.workspace?.syncSidebarSearchFromActivePanel()
            self?.workspace?.syncActiveLocationToChrome()
            self?.workspace?.onSessionChanged?()
        }
        panel.onStudioShowVolumesMenu = { [weak self] anchor in
            self?.workspace?.showVolumesAndBookmarksMenu(from: anchor)
        }
        panel.onStudioShowBookmarksMenu = { [weak self] anchor in
            self?.workspace?.showBookmarksQuickMenu(from: anchor)
        }
        panel.onStudioShowTagsMenu = { [weak self] anchor in
            self?.workspace?.showTagsQuickMenu(from: anchor)
        }
        panel.onStudioSearchChanged = { [weak self] text in
            self?.workspace?.handleExternalSearchInput(text)
        }
        panel.onStudioToggleSearchScope = { [weak self] in
            self?.workspace?.toggleSearchScopeFromExternal()
        }
        panel.onOpenURLInNewTab = { [weak self] url in
            self?.addTab(url: url, activate: true)
        }
        panel.onOpenURLInNewPane = { [weak self] url in
            self?.workspace?.addPane(with: url, after: self)
        }
        panel.onQuickLook = { [weak self] request in
            self?.workspace?.quickLook(request)
        }
        panel.onFocusSearch = { [weak self] in
            self?.workspace?.focusSidebarSearch()
        }
        panel.onSelectionChanged = { [weak self, weak panel] _ in
            guard let self, let panel else { return }
            self.workspace?.selectionChanged(in: panel)
        }
    }

    private func rebuildTabs() {
        for view in tabBar.arrangedSubviews {
            tabBar.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for (index, panel) in tabs.enumerated() {
            let acceptsPhysicalDrop = panel.physicalDropDestinationURL != nil
            let isPinned = index < pinnedCount
            let tab = TabChip(
                index: index,
                title: panel.tabTitle,
                tooltip: panel.isRecentItemsView ? "Недавние файлы и папки" : panel.currentURL.path,
                symbolName: panel.tabIconSymbol,
                pinned: isPinned,
                active: index == activeIndex,
                onSelect: { [weak self, weak panel] in
                    guard let self, let panel,
                          let currentIndex = self.tabs.firstIndex(where: { $0 === panel }) else { return }
                    self.selectTab(at: currentIndex)
                },
                onClose: { [weak self, weak panel] in
                    guard let self, let panel,
                          let currentIndex = self.tabs.firstIndex(where: { $0 === panel }) else { return }
                    self.closeTab(at: currentIndex)
                },
                onSpringOpen: acceptsPhysicalDrop
                    ? { [weak self, weak panel] in
                        guard let self, let panel,
                              let currentIndex = self.tabs.firstIndex(where: { $0 === panel }),
                              self.activeIndex != currentIndex else { return }
                        self.selectTab(at: currentIndex, focusFiles: false)
                    }
                    : nil,
                onFilesDropped: acceptsPhysicalDrop
                    ? { [weak panel] urls in panel?.moveDroppedItemsIntoCurrentFolder(urls) ?? false }
                    : nil,
                onLiveDragBegan: { [weak self] chip, startInWindow in
                    self?.beginLiveTabDrag(chip: chip, startPointInWindow: startInWindow) ?? false
                },
                onLiveDragMoved: { [weak self] chip, pointInWindow in
                    self?.updateLiveTabDrag(chip: chip, pointInWindow: pointInWindow)
                },
                onLiveDragEnded: { [weak self] chip in
                    self?.endLiveTabDrag(chip: chip)
                },
                onContextMenu: { [weak self, weak panel] in
                    guard let self, let panel,
                          let currentIndex = self.tabs.firstIndex(where: { $0 === panel }) else { return nil }
                    return self.tabContextMenu(for: currentIndex)
                }
            )
            tabBar.addArrangedSubview(tab)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.tabBar.arrangedSubviews.indices.contains(self.activeIndex) else { return }
            self.tabBar.layoutSubtreeIfNeeded()
            let activeChip = self.tabBar.arrangedSubviews[self.activeIndex]
            let targetRect = self.tabBar.convert(activeChip.frame, to: self.tabStrip.documentView)
            self.tabStrip.documentView?.scrollToVisible(targetRect.insetBy(dx: -8, dy: 0))
        }
    }

    private func beginLiveTabDrag(chip: TabChip, startPointInWindow: NSPoint) -> Bool {
        let zoneCount = chip.isPinned ? pinnedCount : (tabs.count - pinnedCount)
        guard zoneCount > 1 else { return false }
        dragDidReorder = false
        let startInBar = tabBar.convert(startPointInWindow, from: nil)
        dragGrabOffsetX = startInBar.x - chip.frame.minX
        chip.setDraggingAppearance(true)
        NSCursor.closedHand.push()
        return true
    }

    private func updateLiveTabDrag(chip: TabChip, pointInWindow: NSPoint) {
        // Если вкладок больше, чем помещается в полосе, плавно подкручиваем
        // полосу у левого и правого края во время перетаскивания.
        if let document = tabStrip.documentView,
           document.bounds.width > tabStrip.contentView.bounds.width + 1 {
            let pointInStrip = tabStrip.convert(pointInWindow, from: nil)
            let edgeMargin: CGFloat = 28
            let maxScrollX = max(0, document.bounds.width - tabStrip.contentView.bounds.width)
            var origin = tabStrip.contentView.bounds.origin
            if pointInStrip.x < edgeMargin {
                origin.x = max(0, origin.x - 10)
                tabStrip.contentView.scroll(to: origin)
                tabStrip.reflectScrolledClipView(tabStrip.contentView)
            } else if pointInStrip.x > tabStrip.bounds.width - edgeMargin {
                origin.x = min(maxScrollX, origin.x + 10)
                tabStrip.contentView.scroll(to: origin)
                tabStrip.reflectScrolledClipView(tabStrip.contentView)
            }
        }

        // Важно считать порог обмена по НЕзажатому `rawMinX`/`rawMaxX`:
        // предварительное зажатие до `[0, maxX]` делало невозможным переход
        // в первую (`0`) и последнюю позиции при равной ширине вкладок.
        let pointerInBar = tabBar.convert(pointInWindow, from: nil)
        let rawMinX = pointerInBar.x - dragGrabOffsetX
        let rawMaxX = rawMinX + chip.frame.width

        let minIndex = chip.isPinned ? 0 : pinnedCount
        let maxIndex = chip.isPinned
            ? max(0, pinnedCount - 1)
            : max(minIndex, tabBar.arrangedSubviews.count - 1)

        while chip.tabIndex > minIndex,
              let leftNeighbor = tabBar.arrangedSubviews[chip.tabIndex - 1] as? TabChip,
              rawMinX < leftNeighbor.frame.midX {
            swapLiveTab(chip: chip, withNeighborAt: chip.tabIndex - 1)
        }
        while chip.tabIndex < maxIndex,
              let rightNeighbor = tabBar.arrangedSubviews[chip.tabIndex + 1] as? TabChip,
              rawMaxX > rightNeighbor.frame.midX {
            swapLiveTab(chip: chip, withNeighborAt: chip.tabIndex + 1)
        }

        let zoneMinX = (tabBar.arrangedSubviews.indices.contains(minIndex)
            ? tabBar.arrangedSubviews[minIndex].frame.minX
            : 0) - 4
        let zoneRightEdge = tabBar.arrangedSubviews.indices.contains(maxIndex)
            ? tabBar.arrangedSubviews[maxIndex].frame.maxX
            : tabBar.bounds.width
        let zoneMaxX = max(zoneMinX, zoneRightEdge - chip.frame.width + 4)
        let visualMinX = min(max(rawMinX, zoneMinX), zoneMaxX)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chip.layer?.transform = CATransform3DMakeTranslation(visualMinX - chip.frame.minX, 0, 0)
        CATransaction.commit()
    }

    private func swapLiveTab(chip: TabChip, withNeighborAt targetIndex: Int) {
        let sourceIndex = chip.tabIndex
        guard sourceIndex != targetIndex,
              tabs.indices.contains(sourceIndex),
              tabs.indices.contains(targetIndex),
              tabBar.arrangedSubviews.indices.contains(targetIndex),
              let neighbor = tabBar.arrangedSubviews[targetIndex] as? TabChip else { return }

        let oldNeighborMinX = neighbor.frame.minX
        let selectedPanel = activePanel
        tabs.swapAt(sourceIndex, targetIndex)
        if let selectedPanel,
           let updatedIndex = tabs.firstIndex(where: { $0 === selectedPanel }) {
            activeIndex = updatedIndex
        }
        dragDidReorder = true

        tabBar.removeArrangedSubview(chip)
        tabBar.insertArrangedSubview(chip, at: targetIndex)
        for (idx, view) in tabBar.arrangedSubviews.enumerated() {
            (view as? TabChip)?.tabIndex = idx
        }
        tabBar.layoutSubtreeIfNeeded()

        let deltaX = oldNeighborMinX - neighbor.frame.minX
        if abs(deltaX) > 0.5, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let slide = CABasicAnimation(keyPath: "transform.translation.x")
            slide.fromValue = deltaX
            slide.toValue = 0
            slide.duration = 0.16
            slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
            neighbor.layer?.add(slide, forKey: "tabReorderSlide")
        }
    }

    private func endLiveTabDrag(chip: TabChip) {
        NSCursor.pop()
        let currentTx = chip.layer?.transform.m41 ?? 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chip.layer?.transform = CATransform3DIdentity
        CATransaction.commit()
        if abs(currentTx) > 0.5, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let settle = CABasicAnimation(keyPath: "transform.translation.x")
            settle.fromValue = currentTx
            settle.toValue = 0
            settle.duration = 0.14
            settle.timingFunction = CAMediaTimingFunction(name: .easeOut)
            chip.layer?.add(settle, forKey: "tabSettle")
        }
        chip.setDraggingAppearance(false)
        if dragDidReorder {
            workspace?.onSessionChanged?()
        }
        dragDidReorder = false
    }

    private func tabContextMenu(for index: Int) -> NSMenu? {
        guard tabs.indices.contains(index) else { return nil }
        let isPinned = index < pinnedCount
        let menu = NSMenu(title: "Вкладка")

        let pinItem = NSMenuItem(
            title: isPinned ? "Открепить вкладку" : "Закрепить вкладку",
            action: #selector(togglePinTabFromMenu(_:)),
            keyEquivalent: ""
        )
        pinItem.target = self
        pinItem.tag = index
        menu.addItem(pinItem)

        let duplicate = NSMenuItem(title: "Дублировать вкладку", action: #selector(duplicateTabFromMenu(_:)), keyEquivalent: "")
        duplicate.target = self
        duplicate.tag = index
        menu.addItem(duplicate)

        let copyPath = NSMenuItem(title: "Скопировать путь", action: #selector(copyTabPathFromMenu(_:)), keyEquivalent: "")
        copyPath.target = self
        copyPath.tag = index
        copyPath.isEnabled = !tabs[index].isRecentItemsView
        menu.addItem(copyPath)

        menu.addItem(.separator())

        let closeThis = NSMenuItem(title: "Закрыть вкладку", action: #selector(closeTabFromMenu(_:)), keyEquivalent: "")
        closeThis.target = self
        closeThis.tag = index
        closeThis.isEnabled = !isPinned
        menu.addItem(closeThis)

        let closeOthers = NSMenuItem(title: "Закрыть другие вкладки", action: #selector(closeOtherTabsFromMenu(_:)), keyEquivalent: "")
        closeOthers.target = self
        closeOthers.tag = index
        closeOthers.isEnabled = tabs.count > max(1, pinnedCount + (isPinned ? 0 : 1))
        menu.addItem(closeOthers)

        let closeRight = NSMenuItem(title: "Закрыть вкладки справа", action: #selector(closeTabsToRightFromMenu(_:)), keyEquivalent: "")
        closeRight.target = self
        closeRight.tag = index
        closeRight.isEnabled = max(index + 1, pinnedCount) < tabs.count
        menu.addItem(closeRight)

        if !closedTabURLs.isEmpty {
            menu.addItem(.separator())
            let reopen = NSMenuItem(title: "Открыть закрытую вкладку", action: #selector(reopenClosedTab(_:)), keyEquivalent: "")
            reopen.target = self
            menu.addItem(reopen)
        }
        return menu
    }

    @objc private func togglePinTabFromMenu(_ sender: NSMenuItem) {
        togglePinTab(at: sender.tag)
    }

    func togglePinTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let selectedPanel = activePanel
        let targetPanel = tabs.remove(at: index)
        if index < pinnedCount {
            pinnedCount = max(0, pinnedCount - 1)
            tabs.insert(targetPanel, at: pinnedCount)
        } else {
            tabs.insert(targetPanel, at: pinnedCount)
            pinnedCount += 1
        }
        if let selectedPanel, let updated = tabs.firstIndex(where: { $0 === selectedPanel }) {
            activeIndex = updated
        }
        rebuildTabs()
        workspace?.onSessionChanged?()
    }

    @objc private func duplicateTabFromMenu(_ sender: NSMenuItem) {
        guard tabs.indices.contains(sender.tag) else { return }
        let source = tabs[sender.tag]
        let panel = FilePanel(startURL: source.currentURL)
        configure(panel)
        if source.isRecentItemsView {
            panel.showRecentItems(addingToHistory: false)
        }
        let insertIndex = max(sender.tag + 1, pinnedCount)
        tabs.insert(panel, at: insertIndex)
        activeIndex = insertIndex
        rebuildTabs()
        showActivePanel()
        workspace?.onSessionChanged?()
    }

    @objc private func copyTabPathFromMenu(_ sender: NSMenuItem) {
        guard tabs.indices.contains(sender.tag) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tabs[sender.tag].currentURL.path, forType: .string)
    }

    @objc private func closeTabFromMenu(_ sender: NSMenuItem) {
        closeTab(at: sender.tag)
    }

    @objc private func closeOtherTabsFromMenu(_ sender: NSMenuItem) {
        let keepIndex = sender.tag
        guard tabs.indices.contains(keepIndex), tabs.count > 1 else { return }
        let keptPanel = tabs[keepIndex]
        var remaining: [FilePanel] = []
        for (idx, panel) in tabs.enumerated() {
            if idx < pinnedCount || idx == keepIndex {
                remaining.append(panel)
            } else {
                recordClosedTab(panel.currentURL)
                panel.removeFromSuperview()
            }
        }
        tabs = remaining
        activeIndex = tabs.firstIndex(where: { $0 === keptPanel }) ?? 0
        rebuildTabs()
        showActivePanel()
        workspace?.onSessionChanged?()
    }

    @objc private func closeTabsToRightFromMenu(_ sender: NSMenuItem) {
        let startRemove = max(sender.tag + 1, pinnedCount)
        guard startRemove < tabs.count else { return }
        let removedPanels = Array(tabs[startRemove...])
        tabs.removeSubrange(startRemove...)
        for panel in removedPanels {
            recordClosedTab(panel.currentURL)
            panel.removeFromSuperview()
        }
        activeIndex = min(activeIndex, tabs.count - 1)
        rebuildTabs()
        showActivePanel()
        workspace?.onSessionChanged?()
    }

    private func recordClosedTab(_ url: URL) {
        closedTabURLs.append(url)
        if closedTabURLs.count > 20 {
            closedTabURLs.removeFirst(closedTabURLs.count - 20)
        }
    }

    var canReopenClosedTab: Bool { !closedTabURLs.isEmpty }

    @objc func reopenClosedTab(_ sender: Any? = nil) {
        while let url = closedTabURLs.popLast() {
            if FileManager.default.fileExists(atPath: url.path) {
                addTab(url: url, activate: true)
                return
            }
        }
        NSSound.beep()
    }

    func reorderTab(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex >= 0, sourceIndex < tabs.count,
              destinationIndex >= 0, destinationIndex < tabs.count,
              sourceIndex != destinationIndex else { return }
        let selectedPanel = activePanel
        let movingPanel = tabs.remove(at: sourceIndex)
        let insertionIndex = min(destinationIndex, tabs.count)
        tabs.insert(movingPanel, at: insertionIndex)
        if let selectedPanel,
           let updatedIndex = tabs.firstIndex(where: { $0 === selectedPanel }) {
            activeIndex = updatedIndex
        }
        rebuildTabs()
        workspace?.onSessionChanged?()
    }

    private func showActivePanel(focusFiles: Bool = true) {
        let replacesVisiblePanel = contentView.subviews.contains { $0 !== activePanel && !$0.isHidden }
        for view in contentView.subviews {
            view.removeFromSuperview()
        }

        guard let panel = activePanel else { return }
        contentView.addSubview(panel)
        panel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            panel.topAnchor.constraint(equalTo: contentView.topAnchor),
            panel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        // Мягкий фейд при переключении вкладок вместо мгновенной подмены.
        if replacesVisiblePanel, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
        }
        if focusFiles {
            panel.focusFiles()
        }
        workspace?.activate(panel: panel, in: self)
    }

    @objc private func selectTab(_ sender: NSButton) {
        selectTab(at: sender.tag)
    }

    private func selectTab(at index: Int, focusFiles: Bool = true) {
        guard index >= 0 && index < tabs.count else { return }
        if index == activeIndex, activePanel?.superview === contentView {
            return
        }
        activeIndex = index
        if tabBar.arrangedSubviews.count == tabs.count {
            for (chipIndex, view) in tabBar.arrangedSubviews.enumerated() {
                (view as? TabChip)?.setActive(chipIndex == activeIndex)
            }
            scrollActiveTabIntoView()
        } else {
            rebuildTabs()
        }
        showActivePanel(focusFiles: focusFiles)
        workspace?.onSessionChanged?()
    }

    private func scrollActiveTabIntoView() {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.tabBar.arrangedSubviews.indices.contains(self.activeIndex) else { return }
            self.tabBar.layoutSubtreeIfNeeded()
            let activeChip = self.tabBar.arrangedSubviews[self.activeIndex]
            let targetRect = self.tabBar.convert(activeChip.frame, to: self.tabStrip.documentView)
            self.tabStrip.documentView?.scrollToVisible(targetRect.insetBy(dx: -8, dy: 0))
        }
    }

    func selectTab(number: Int) {
        guard !tabs.isEmpty else { return }
        let index = number == 9 ? tabs.count - 1 : number - 1
        selectTab(at: index)
    }

    @objc func newTab(_ sender: Any?) {
        let url = activePanel?.currentURL ?? FileManager.default.homeDirectoryForCurrentUser
        addTab(url: url, activate: true)
    }

    @objc private func showSavedTabGroups(_ sender: NSButton) {
        let menu = NSMenu(title: "Группы вкладок")
        let save = NSMenuItem(
            title: "Сохранить текущие вкладки как группу…",
            action: #selector(saveCurrentTabsAsGroup(_:)),
            keyEquivalent: ""
        )
        save.target = self
        menu.addItem(save)

        let groups = FPSavedTabGroupStore.shared.groups
        if !groups.isEmpty {
            menu.addItem(.separator())
        }
        for group in groups {
            let parent = NSMenuItem(title: group.name, action: nil, keyEquivalent: "")
            parent.image = NSImage(
                systemSymbolName: "rectangle.3.group",
                accessibilityDescription: nil
            )
            let submenu = NSMenu(title: group.name)

            let replace = NSMenuItem(
                title: "Открыть группу",
                action: #selector(openSavedTabGroup(_:)),
                keyEquivalent: ""
            )
            replace.target = self
            replace.representedObject = group.id.uuidString
            submenu.addItem(replace)

            let append = NSMenuItem(
                title: "Добавить вкладки к текущим",
                action: #selector(appendSavedTabGroup(_:)),
                keyEquivalent: ""
            )
            append.target = self
            append.representedObject = group.id.uuidString
            submenu.addItem(append)

            submenu.addItem(.separator())
            let update = NSMenuItem(
                title: "Обновить из текущих вкладок",
                action: #selector(updateSavedTabGroup(_:)),
                keyEquivalent: ""
            )
            update.target = self
            update.representedObject = group.id.uuidString
            submenu.addItem(update)

            let remove = NSMenuItem(
                title: "Удалить группу",
                action: #selector(removeSavedTabGroup(_:)),
                keyEquivalent: ""
            )
            remove.target = self
            remove.representedObject = group.id.uuidString
            submenu.addItem(remove)

            menu.setSubmenu(submenu, for: parent)
            menu.addItem(parent)
        }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: sender.bounds.height + 5),
            in: sender
        )
    }

    @objc private func saveCurrentTabsAsGroup(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Сохранить группу вкладок"
        alert.informativeText = "Эту группу можно будет открыть в любой момент из кнопки рядом с «+»."
        alert.addButton(withTitle: "Сохранить")
        alert.addButton(withTitle: "Отмена")
        let field = NSTextField(
            string: activePanel?.tabTitle ?? "Моя группа"
        )
        field.placeholderString = "Название группы"
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 26)
        alert.accessoryView = field

        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            _ = FPSavedTabGroupStore.shared.save(
                name: field.stringValue,
                paths: self.tabs.map { $0.currentURL.path },
                activeIndex: self.activeIndex
            )
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    private func savedGroup(from sender: NSMenuItem) -> FPSavedTabGroup? {
        guard let rawID = sender.representedObject as? String,
              let id = UUID(uuidString: rawID) else { return nil }
        return FPSavedTabGroupStore.shared.group(id: id)
    }

    private func validGroupURLs(_ group: FPSavedTabGroup) -> [URL] {
        let manager = FileManager.default
        return group.paths.compactMap { path in
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            return url
        }
    }

    @objc private func openSavedTabGroup(_ sender: NSMenuItem) {
        guard let group = savedGroup(from: sender) else { return }
        let urls = validGroupURLs(group)
        guard !urls.isEmpty else {
            presentMissingTabGroupAlert(group)
            return
        }

        tabs.forEach { $0.removeFromSuperview() }
        tabs.removeAll()
        for url in urls {
            let panel = FilePanel(startURL: url)
            configure(panel)
            tabs.append(panel)
        }
        activeIndex = min(max(group.activeIndex, 0), tabs.count - 1)
        rebuildTabs()
        showActivePanel()
        workspace?.onSessionChanged?()
    }

    @objc private func appendSavedTabGroup(_ sender: NSMenuItem) {
        guard let group = savedGroup(from: sender) else { return }
        let urls = validGroupURLs(group)
        guard !urls.isEmpty else {
            presentMissingTabGroupAlert(group)
            return
        }
        let existing = Set(tabs.map { $0.currentURL.standardizedFileURL.path })
        let newURLs = urls.filter { !existing.contains($0.path) }
        guard !newURLs.isEmpty else {
            NSSound.beep()
            return
        }
        for (offset, url) in newURLs.enumerated() {
            addTab(url: url, activate: offset == newURLs.count - 1)
        }
    }

    @objc private func updateSavedTabGroup(_ sender: NSMenuItem) {
        guard let group = savedGroup(from: sender) else { return }
        _ = FPSavedTabGroupStore.shared.save(
            name: group.name,
            paths: tabs.map { $0.currentURL.path },
            activeIndex: activeIndex,
            replacing: group.id
        )
    }

    @objc private func removeSavedTabGroup(_ sender: NSMenuItem) {
        guard let group = savedGroup(from: sender) else { return }
        FPSavedTabGroupStore.shared.remove(id: group.id)
    }

    private func presentMissingTabGroupAlert(_ group: FPSavedTabGroup) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Папки группы недоступны"
        alert.informativeText = "Проверьте подключение внешних дисков или сетевых папок для группы «\(group.name)»."
        alert.addButton(withTitle: "ОК")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    @objc func closeActiveTab(_ sender: Any?) {
        closeTab(at: activeIndex)
    }

    @objc private func closeTab(_ sender: NSButton) {
        closeTab(at: sender.tag)
    }

    private func closeTab(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }
        // Закреплённые вкладки защищены от случайного закрытия по ⌘W и колёсику.
        if index < pinnedCount {
            if tabs.count == 1 {
                if workspace?.paneCount ?? 1 > 1 {
                    workspace?.removePane(self)
                } else {
                    window?.performClose(nil)
                }
            } else {
                NSSound.beep()
            }
            return
        }

        if tabs.count == 1 {
            if workspace?.paneCount ?? 1 > 1 {
                workspace?.removePane(self)
            } else {
                window?.performClose(nil)
            }
            return
        }

        let removed = tabs.remove(at: index)
        recordClosedTab(removed.currentURL)
        removed.removeFromSuperview()
        if index < activeIndex {
            activeIndex -= 1
        }
        activeIndex = min(activeIndex, tabs.count - 1)
        rebuildTabs()
        showActivePanel()
        workspace?.onSessionChanged?()
    }

    @objc func showCommandPalette(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.showCommandPalette(sender)
    }

    @objc private func showClipboard(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.showClipboard(sender)
    }

    @objc private func showDropShelf(_ sender: Any?) {
        QyvroDropShelfModule.shared.toggle()
    }

    @objc private func showLayoutAndThemeMenu(_ sender: NSButton) {
        let menu = NSMenu(title: "Макет и темы")

        let layoutHeader = NSMenuItem(title: "Макет окна", action: nil, keyEquivalent: "")
        layoutHeader.isEnabled = false
        menu.addItem(layoutHeader)

        for layout in QyvroWorkspaceLayout.allCases {
            let item = NSMenuItem(
                title: layout.title,
                action: #selector(selectLayoutFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = layout.rawValue
            item.state = layout == currentLayout ? .on : .off
            if #available(macOS 11.0, *) {
                item.image = NSImage(systemSymbolName: layout.symbol, accessibilityDescription: layout.title)
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let folderStyleItem = NSMenuItem(title: L("Стиль папок", "Folder Style"), action: nil, keyEquivalent: "")
        let folderStyleSub = NSMenu(title: L("Стиль папок", "Folder Style"))
        for style in FPFolderIconStyle.allCases {
            let item = NSMenuItem(
                title: style.title,
                action: #selector(selectFolderStyleFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = style.rawValue
            item.state = style == FPFolderIconStyle.current ? .on : .off
            folderStyleSub.addItem(item)
        }
        folderStyleItem.submenu = folderStyleSub
        menu.addItem(folderStyleItem)

        menu.addItem(.separator())
        let v4Header = NSMenuItem(title: L("Студия (V4 · новое)", "Studio (V4 · New)"), action: nil, keyEquivalent: "")
        v4Header.isEnabled = false
        menu.addItem(v4Header)

        for (index, preset) in FPThemePreset.all.enumerated() where preset.title.hasPrefix("Студия") {
            let item = NSMenuItem(
                title: FPLocalization.localizedThemeTitle(preset.title),
                action: #selector(selectThemePresetFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = index
            item.image = FPThemeSwatchRenderer.swatch(for: preset)
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let v3Header = NSMenuItem(title: L("Аврора и Стекло (V3)", "Aurora & Glass (V3)"), action: nil, keyEquivalent: "")
        v3Header.isEnabled = false
        menu.addItem(v3Header)

        for (index, preset) in FPThemePreset.all.enumerated()
        where preset.styleVariant == .obsidianAurora && !preset.title.hasPrefix("Студия") {
            let item = NSMenuItem(
                title: FPLocalization.localizedThemeTitle(preset.title),
                action: #selector(selectThemePresetFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = index
            item.image = FPThemeSwatchRenderer.swatch(for: preset)
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let legacyHeader = NSMenuItem(title: L("Прошлый дизайн и классика", "Legacy & Classic"), action: nil, keyEquivalent: "")
        legacyHeader.isEnabled = false
        menu.addItem(legacyHeader)

        for (index, preset) in FPThemePreset.all.enumerated() where preset.styleVariant != .obsidianAurora {
            let item = NSMenuItem(
                title: FPLocalization.localizedThemeTitle(preset.title),
                action: #selector(selectThemePresetFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = index
            item.image = FPThemeSwatchRenderer.swatch(for: preset)
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let openSettings = NSMenuItem(
            title: L("Все настройки оформления…", "All Appearance Settings…"),
            action: #selector(openSettingsFromMenu(_:)),
            keyEquivalent: ""
        )
        openSettings.target = self
        menu.addItem(openSettings)

        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: sender.bounds.height + 5),
            in: sender
        )
    }

    @objc private func selectLayoutFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let layout = QyvroWorkspaceLayout(rawValue: raw) else { return }
        QyvroWorkspaceLayout.setCurrent(layout)
    }

    @objc private func selectFolderStyleFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = FPFolderIconStyle(rawValue: raw) else { return }
        FPFolderIconStyle.setCurrent(style)
    }

    @objc private func selectThemePresetFromMenu(_ sender: NSMenuItem) {
        guard FPThemePreset.all.indices.contains(sender.tag) else { return }
        let preset = FPThemePreset.all[sender.tag]
        FPStyle.applyBuiltInPreset(preset)
        NotificationCenter.default.post(name: .fpThemeDidChange, object: nil)
    }

    @objc private func openSettingsFromMenu(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.showSettings(sender)
    }

    @objc private func togglePreviewPanel(_ sender: Any?) {
        workspace?.togglePreviewPanel(sender)
    }

    @objc private func toggleAlwaysOnTop(_ sender: Any?) {
        workspace?.toggleAlwaysOnTop(sender)
    }
}

final class WorkspaceView: NSVisualEffectView, NSTextFieldDelegate, NSSplitViewDelegate {
    private enum SearchScope {
        case folder
        case mac
    }

    private let rootSplitView = NSSplitView()
    private let centerStage = NSView()
    private let splitView = NSSplitView()
    private let diskPanel = FPDiskUsagePanel(frame: .zero)
    private let edgeRailView = QyvroEdgeRailView()
    private let floatingDockView = QyvroFloatingDockView()
    private var sidebarContainer: NSView!
    private var currentLayout: QyvroWorkspaceLayout = QyvroWorkspaceLayout.current
    private var splitLeadingToStage: NSLayoutConstraint?
    private var splitLeadingToRail: NSLayoutConstraint?
    private var floatingSearchPopover: NSPopover?
    private var sidebarResizeMonitor: Any?
    private var isDraggingSidebarEdge = false
    private let previewSidebar = FilePreviewSidebar()
    private let backgroundGradientView = FPBackgroundGradientView()
    private let editorialBackdropView = FPEditorialBackdropView()
    private let auroraBackdropView = QyvroAuroraBackdropView()
    private let sidebarStack = NSStackView()
    /// Нижняя строка «Настройки» вынесена из scroll view и закреплена над
    /// виджетом диска, чтобы её hover-подложка никогда не обрезалась снизу.
    private let sidebarSettingsFooter = NSStackView()
    private let sidebarSearchContainer = NSView()
    private let sidebarSearchField = CenteredTextField()
    private let sidebarSearchIcon = NSImageView()
    private let sidebarSearchScopeButton = AnimatedSidebarButton()
    private var searchScope: SearchScope = .folder
    private var metadataQuery: NSMetadataQuery?
    private var metadataObservers: [NSObjectProtocol] = []
    private var volumeObservers: [NSObjectProtocol] = []
    private var globalSearchWorkItem: DispatchWorkItem?
    private var tagListScrollObserver: NSObjectProtocol?
    private var panes: [BrowserPane] = []
    private weak var activePane: BrowserPane?
    private weak var activePanel: FilePanel?
    /// Рамка окна до открытия сплит-панели (⌘D), чтобы после закрытия
    /// сплит-панелей вернуть точный исходный размер без сжимания в «мелкое» окно.
    private var frameBeforeSplit: NSRect?
    private(set) var isAlwaysOnTop = false
    private var tagManagerController: TagManagerController?
    private let quickLookHandler: (FPQuickLookRequest) -> Void
    var onSessionChanged: (() -> Void)?

    var paneCount: Int {
        panes.count
    }

    var isPreviewPanelVisible: Bool {
        previewSidebar.superview === rootSplitView && !previewSidebar.isHidden
    }

    func refreshVisiblePanels(force: Bool = false) {
        panes.forEach { $0.refreshActivePanel(force: force) }
    }

    init(
        startURL: URL,
        restoredPanes: [FPPaneSession]? = nil,
        restoredActivePane: Int = 0,
        restoredPaneFractions: [Double]? = nil,
        quickLookHandler: @escaping (FPQuickLookRequest) -> Void
    ) {
        self.quickLookHandler = quickLookHandler
        super.init(frame: .zero)
        buildUI(
            startURL: startURL,
            restoredPanes: restoredPanes,
            restoredActivePane: restoredActivePane,
            restoredPaneFractions: restoredPaneFractions
        )
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged(_:)), name: .fpThemeDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(tagsChanged(_:)), name: .fpTagsDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(layoutDidChange(_:)), name: .qyvroLayoutDidChange, object: nil)
        QyvroDropShelfModule.shared.onTransferToActiveFolder = { [weak self] urls, move in
            self?.transferFromDropShelf(urls: urls, move: move) ?? false
        }
        QyvroDiskAnalyzerModule.shared.onOpenFolderInExplorer = { [weak self] url in
            self?.openFolderFromAnalyzer(url)
        }
        installVolumeObservers()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let sidebarResizeMonitor {
            NSEvent.removeMonitor(sidebarResizeMonitor)
        }
        globalSearchWorkItem?.cancel()
        metadataQuery?.stop()
        metadataObservers.forEach(NotificationCenter.default.removeObserver)
        volumeObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        if let tagListScrollObserver {
            NotificationCenter.default.removeObserver(tagListScrollObserver)
        }
        NotificationCenter.default.removeObserver(self)
    }

    private func installVolumeObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification
        ]
        volumeObservers = names.map { name in
            workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.rebuildSidebarContents()
                FPDiskUsage.refreshCapacity()
                self.diskPanel.update(FPDiskUsage.snapshot)
                self.floatingDockView.updateDisk(FPDiskUsage.snapshot)
                self.edgeRailView.updateDisk(FPDiskUsage.snapshot)
                self.panes.forEach { $0.updateDiskGauge(FPDiskUsage.snapshot) }
            }
        }
    }

    private func buildUI(
        startURL: URL,
        restoredPanes: [FPPaneSession]?,
        restoredActivePane: Int,
        restoredPaneFractions: [Double]?
    ) {
        wantsLayer = true
        material = .underWindowBackground
        blendingMode = .behindWindow
        state = .active
        updateWindowBackdrop()
        layer?.cornerRadius = 18
        layer?.masksToBounds = true
        updateBackgroundGradient()

        rootSplitView.isVertical = true
        rootSplitView.dividerStyle = .thin
        rootSplitView.delegate = self
        rootSplitView.translatesAutoresizingMaskIntoConstraints = false

        let sidebar = buildSidebar()
        sidebarContainer = sidebar

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.translatesAutoresizingMaskIntoConstraints = false

        centerStage.translatesAutoresizingMaskIntoConstraints = false
        centerStage.wantsLayer = true
        centerStage.layer?.backgroundColor = NSColor.clear.cgColor
        configureAlternateLayoutChrome()
        centerStage.addSubview(edgeRailView)
        centerStage.addSubview(splitView)
        centerStage.addSubview(floatingDockView)

        let toStage = splitView.leadingAnchor.constraint(equalTo: centerStage.leadingAnchor)
        let toRail = splitView.leadingAnchor.constraint(equalTo: edgeRailView.trailingAnchor)
        splitLeadingToStage = toStage
        splitLeadingToRail = toRail

        let dockLeading = floatingDockView.leadingAnchor.constraint(greaterThanOrEqualTo: centerStage.leadingAnchor, constant: 12)
        dockLeading.priority = NSLayoutConstraint.Priority(240)
        let dockTrailing = floatingDockView.trailingAnchor.constraint(lessThanOrEqualTo: centerStage.trailingAnchor, constant: -12)
        dockTrailing.priority = NSLayoutConstraint.Priority(240)

        NSLayoutConstraint.activate([
            edgeRailView.leadingAnchor.constraint(equalTo: centerStage.leadingAnchor),
            edgeRailView.topAnchor.constraint(equalTo: centerStage.topAnchor),
            edgeRailView.bottomAnchor.constraint(equalTo: centerStage.bottomAnchor),

            splitView.trailingAnchor.constraint(equalTo: centerStage.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: centerStage.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: centerStage.bottomAnchor),

            floatingDockView.centerXAnchor.constraint(equalTo: centerStage.centerXAnchor),
            floatingDockView.bottomAnchor.constraint(equalTo: centerStage.bottomAnchor, constant: -10),
            dockLeading,
            dockTrailing
        ])

        addSubview(backgroundGradientView)
        addSubview(editorialBackdropView)
        addSubview(auroraBackdropView)
        addSubview(rootSplitView)
        if currentLayout == .classicSidebar {
            rootSplitView.addArrangedSubview(sidebar)
            rootSplitView.addArrangedSubview(centerStage)
            rootSplitView.setHoldingPriority(
                NSLayoutConstraint.Priority(260),
                forSubviewAt: 0
            )
        } else {
            rootSplitView.addArrangedSubview(centerStage)
        }
        previewSidebar.setContentHuggingPriority(.defaultLow, for: .horizontal)
        previewSidebar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previewSidebar.onClose = { [weak self] in
            self?.setPreviewPanelVisible(false)
        }
        // Скрытый `previewSidebar` нельзя держать внутри `rootSplitView`:
        // тогда второй разделитель остаётся стоять ровно на правом краю окна
        // (`x = width - 1`) и `NSSplitView` блокирует ресайз правого края.
        let showPreviewInitially = UserDefaults.standard.bool(forKey: "PreviewSidebarVisible")
        if showPreviewInitially {
            previewSidebar.isHidden = false
            rootSplitView.addArrangedSubview(previewSidebar)
            rootSplitView.setHoldingPriority(
                NSLayoutConstraint.Priority(260),
                forSubviewAt: rootSplitView.arrangedSubviews.count - 1
            )
        } else {
            previewSidebar.isHidden = true
        }
        rootSplitView.autosaveName = "FilePilotRootSplit"

        // Ширина сайдбара меняется через монитор событий: он не зависит ни от
        // порядка наложения видов, ни от систем координат в цепочке надвью.
        installSidebarResizeMonitor()

        NSLayoutConstraint.activate([
            backgroundGradientView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundGradientView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundGradientView.topAnchor.constraint(equalTo: topAnchor),
            backgroundGradientView.bottomAnchor.constraint(equalTo: bottomAnchor),
            editorialBackdropView.leadingAnchor.constraint(equalTo: leadingAnchor),
            editorialBackdropView.trailingAnchor.constraint(equalTo: trailingAnchor),
            editorialBackdropView.topAnchor.constraint(equalTo: topAnchor),
            editorialBackdropView.bottomAnchor.constraint(equalTo: bottomAnchor),
            auroraBackdropView.leadingAnchor.constraint(equalTo: leadingAnchor),
            auroraBackdropView.trailingAnchor.constraint(equalTo: trailingAnchor),
            auroraBackdropView.topAnchor.constraint(equalTo: topAnchor),
            auroraBackdropView.bottomAnchor.constraint(equalTo: bottomAnchor),
            rootSplitView.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootSplitView.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootSplitView.topAnchor.constraint(equalTo: topAnchor),
            rootSplitView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        QyvroWindowResizeOverlay.install(
            in: self,
            insets: QyvroWindowResizeInsets(left: 10, right: 10, top: 6, bottom: 8, cornerSize: 16)
        )

        if let restoredPanes, !restoredPanes.isEmpty {
            for state in restoredPanes {
                addRestoredPane(state)
            }
            let index = min(max(restoredActivePane, 0), panes.count - 1)
            activePane = panes[index]
            if let panel = panes[index].activePanel {
                activate(panel: panel, in: panes[index])
            }
        } else {
            addPane(with: startURL, after: nil)
        }
        applyWorkspaceLayout(currentLayout)
        DispatchQueue.main.async {
            if self.currentLayout == .classicSidebar, self.rootSplitView.arrangedSubviews.count >= 2 {
                let storedSidebar = UserDefaults.standard.double(forKey: "SidebarWidth")
                let sidebarWidth: CGFloat = storedSidebar >= 200 ? min(CGFloat(storedSidebar), 560) : 244
                self.rootSplitView.setPosition(sidebarWidth, ofDividerAt: 0)
            }
            if self.isPreviewPanelVisible, self.rootSplitView.arrangedSubviews.count >= 2 {
                let dividerIdx = self.rootSplitView.arrangedSubviews.count - 2
                self.rootSplitView.setPosition(
                    max(420, self.rootSplitView.bounds.width - 310),
                    ofDividerAt: dividerIdx
                )
            }
            if let restoredPaneFractions {
                self.applyPaneFractions(restoredPaneFractions)
            }
        }
    }

    func activate(panel: FilePanel, in pane: BrowserPane) {
        activePane = pane
        activePanel = panel
        if isPreviewPanelVisible {
            previewSidebar.update(items: panel.selectedItems)
        }
        if searchScope == .folder {
            sidebarSearchField.stringValue = panel.searchQuery
        }
        for candidate in panes {
            candidate.setActive(candidate === pane)
            candidate.activePanel?.setActive(candidate === pane && candidate.activePanel === panel)
        }
        syncActiveLocationToChrome()
    }

    func syncActiveLocationToChrome() {
        let url = activePanel?.currentURL
        let isRecents = activePanel?.isRecentItemsView == true
        floatingDockView.updateActiveLocation(url: url, isRecents: isRecents)
        edgeRailView.updateActiveLocation(url: url, isRecents: isRecents)
    }

    @objc private func layoutDidChange(_ notification: Notification) {
        applyWorkspaceLayout(QyvroWorkspaceLayout.current)
    }

    func applyWorkspaceLayout(_ layout: QyvroWorkspaceLayout) {
        currentLayout = layout

        // 1. Показываем или убираем классический сайдбар из rootSplitView.
        if layout == .classicSidebar {
            if sidebarContainer.superview !== rootSplitView {
                rootSplitView.insertArrangedSubview(sidebarContainer, at: 0)
                rootSplitView.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
            }
            sidebarContainer.isHidden = false
        } else {
            if sidebarContainer.superview === rootSplitView {
                rootSplitView.removeArrangedSubview(sidebarContainer)
                sidebarContainer.removeFromSuperview()
            }
        }

        // 2. Управляем узкой рейкой «Рейл» и плавающим доком «Подиум».
        let isRail = (layout == .edgeRail)
        let isDock = (layout == .floatingDock)
        edgeRailView.isHidden = !isRail
        floatingDockView.isHidden = !isDock
        splitLeadingToStage?.isActive = !isRail
        splitLeadingToRail?.isActive = isRail

        // 3. Синхронизируем положение полосы вкладок и отступы во всех панелях.
        for (idx, pane) in panes.enumerated() {
            pane.applyWorkspaceLayout(layout, isLeadingPane: idx == 0)
        }

        if layout == .classicSidebar, rootSplitView.arrangedSubviews.count >= 2 {
            let storedSidebar = UserDefaults.standard.double(forKey: "SidebarWidth")
            let sidebarWidth: CGFloat = storedSidebar >= 200 ? min(CGFloat(storedSidebar), 560) : 244
            rootSplitView.setPosition(sidebarWidth, ofDividerAt: 0)
        }
        rootSplitView.adjustSubviews()
        syncActiveLocationToChrome()
        needsLayout = true
    }

    private func configureAlternateLayoutChrome() {
        let moveHandler: ([URL], URL) -> Bool = { [weak self] urls, dest in
            guard let panel = self?.activePanel ?? self?.panes.first?.activePanel else { return false }
            return panel.moveDroppedItems(urls, to: dest)
        }
        floatingDockView.onOpenRecents = { [weak self] in self?.openRecents(nil) }
        floatingDockView.onOpenURL = { [weak self] url in self?.activePanel?.navigate(to: url) }
        floatingDockView.onMoveFilesToURL = moveHandler
        floatingDockView.onShowVolumesMenu = { [weak self] anchor in self?.showVolumesAndBookmarksMenu(from: anchor) }
        floatingDockView.onShowTagsMenu = { [weak self] anchor in self?.showTagsQuickMenu(from: anchor) }
        floatingDockView.onFocusSearch = { [weak self] in self?.focusSidebarSearch() }
        floatingDockView.onAnalyzeDisk = { [weak self] in self?.openDiskAnalyzer(nil) }
        floatingDockView.onOpenSettings = { [weak self] in self?.openSettings(nil) }

        edgeRailView.onOpenRecents = { [weak self] in self?.openRecents(nil) }
        edgeRailView.onOpenURL = { [weak self] url in self?.activePanel?.navigate(to: url) }
        edgeRailView.onMoveFilesToURL = moveHandler
        edgeRailView.onShowVolumesMenu = { [weak self] anchor in self?.showVolumesAndBookmarksMenu(from: anchor) }
        edgeRailView.onOpenTag = { [weak self] key, title in
            self?.activePanel?.showTaggedItems(tagKey: key, title: title)
        }
        edgeRailView.onApplyTag = { [weak self] key, urls in
            self?.applyTag(key, to: urls)
        }
        edgeRailView.onFocusSearch = { [weak self] in self?.focusSidebarSearch() }
        edgeRailView.onAnalyzeDisk = { [weak self] in self?.openDiskAnalyzer(nil) }
        edgeRailView.onOpenSettings = { [weak self] in self?.openSettings(nil) }
    }

    func showVolumesAndBookmarksMenu(from anchor: NSView) {
        let menu = NSMenu(title: "Диски и закладки")
        let volumesHeader = NSMenuItem(title: "Диски", action: nil, keyEquivalent: "")
        volumesHeader.isEnabled = false
        menu.addItem(volumesHeader)
        for vol in storageLocations() {
            var label = vol.title
            if let cap = FPDiskUsage.volumeCapacity(at: vol.url) {
                label += " · свободно \(ByteCountFormatter.string(fromByteCount: cap.free, countStyle: .file))"
            }
            let item = NSMenuItem(title: label, action: #selector(openURLFromQuickMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = vol.url
            if #available(macOS 11.0, *) {
                item.image = NSImage(systemSymbolName: vol.symbol, accessibilityDescription: vol.title)
            }
            menu.addItem(item)
            if vol.ejectable {
                let eject = NSMenuItem(title: "   Извлечь «\(vol.title)»", action: #selector(ejectVolumeFromMenu(_:)), keyEquivalent: "")
                eject.target = self
                eject.representedObject = vol.url
                menu.addItem(eject)
            }
        }
        let bookmarks = bookmarkLocations()
        menu.addItem(.separator())
        let bmHeader = NSMenuItem(title: "Закреплённые папки", action: nil, keyEquivalent: "")
        bmHeader.isEnabled = false
        menu.addItem(bmHeader)
        for entry in bookmarks {
            let item = NSMenuItem(title: entry.title, action: #selector(openURLFromQuickMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.url
            if #available(macOS 11.0, *) {
                item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: entry.title)
            }
            menu.addItem(item)
        }
        let addBM = NSMenuItem(title: "Закрепить папку…", action: #selector(addBookmark(_:)), keyEquivalent: "")
        addBM.target = self
        menu.addItem(addBM)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 6), in: anchor)
    }

    func showBookmarksQuickMenu(from anchor: NSView) {
        let menu = NSMenu(title: "Закладки")
        let bookmarks = bookmarkLocations()
        if bookmarks.isEmpty {
            let empty = NSMenuItem(title: "Пока нет закреплённых папок", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for entry in bookmarks {
                let item = NSMenuItem(title: entry.title, action: #selector(openURLFromQuickMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.url
                if #available(macOS 11.0, *) {
                    item.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: entry.title)
                }
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        if let panel = activePanel, panel.virtualTagTitle == nil, panel.virtualSearchTitle == nil {
            let currentPath = panel.currentURL.standardizedFileURL.path
            let savedPaths = UserDefaults.standard.stringArray(forKey: "SidebarBookmarks") ?? []
            if savedPaths.contains(currentPath) {
                let remove = NSMenuItem(
                    title: "Убрать «\(panel.currentURL.lastPathComponent)» из закладок",
                    action: #selector(removeCurrentBookmarkFromMenu(_:)),
                    keyEquivalent: ""
                )
                remove.target = self
                remove.representedObject = currentPath
                menu.addItem(remove)
            } else {
                let addCurrent = NSMenuItem(
                    title: "Закрепить «\(panel.currentURL.lastPathComponent)»",
                    action: #selector(bookmarkCurrentFolderFromMenu(_:)),
                    keyEquivalent: ""
                )
                addCurrent.target = self
                menu.addItem(addCurrent)
            }
        }
        let addOther = NSMenuItem(title: "Выбрать другую папку…", action: #selector(addBookmark(_:)), keyEquivalent: "")
        addOther.target = self
        menu.addItem(addOther)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 6), in: anchor)
    }

    @objc private func bookmarkCurrentFolderFromMenu(_ sender: Any?) {
        guard let panel = activePanel, panel.virtualTagTitle == nil, panel.virtualSearchTitle == nil else { return }
        addBookmarks(from: [panel.currentURL])
        panel.showToast("Папка закреплена в закладках", symbol: "bookmark.fill")
    }

    @objc private func removeCurrentBookmarkFromMenu(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        var paths = UserDefaults.standard.stringArray(forKey: "SidebarBookmarks") ?? []
        paths.removeAll { $0 == path }
        UserDefaults.standard.set(paths, forKey: "SidebarBookmarks")
        rebuildSidebarContents()
        activePanel?.showToast("Удалено из закладок", symbol: "bookmark.slash")
    }

    @objc private func openURLFromQuickMenu(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        activePanel?.navigate(to: url)
    }

    func showTagsQuickMenu(from anchor: NSView) {
        let menu = NSMenu(title: "Теги")
        for tag in FPTag.all {
            let item = NSMenuItem(title: tag.title, action: #selector(openTagFromQuickMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [tag.key, tag.title]
            let img = NSImage(size: NSSize(width: 12, height: 12))
            img.lockFocus()
            tag.color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 10, height: 10)).fill()
            img.unlockFocus()
            item.image = img
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let all = NSMenuItem(title: "Все теги и управление…", action: #selector(showAllTags(_:)), keyEquivalent: "")
        all.target = self
        menu.addItem(all)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 6), in: anchor)
    }

    @objc private func openTagFromQuickMenu(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        activePanel?.showTaggedItems(tagKey: pair[0], title: pair[1])
    }

    func selectionChanged(in panel: FilePanel) {
        guard panel === activePanel, isPreviewPanelVisible else { return }
        previewSidebar.update(items: panel.selectedItems)
    }

    @objc func togglePreviewPanel(_ sender: Any?) {
        setPreviewPanelVisible(!isPreviewPanelVisible)
    }

    private func setPreviewPanelVisible(_ visible: Bool) {
        guard visible != isPreviewPanelVisible else { return }
        UserDefaults.standard.set(visible, forKey: "PreviewSidebarVisible")
        if visible {
            previewSidebar.alphaValue = 0
            previewSidebar.isHidden = false
            if previewSidebar.superview !== rootSplitView {
                rootSplitView.addArrangedSubview(previewSidebar)
                rootSplitView.setHoldingPriority(
                    NSLayoutConstraint.Priority(260),
                    forSubviewAt: rootSplitView.arrangedSubviews.count - 1
                )
            }
            previewSidebar.update(items: activePanel?.selectedItems ?? [])
            rootSplitView.adjustSubviews()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isPreviewPanelVisible, self.rootSplitView.arrangedSubviews.count >= 2 else { return }
                let dividerIdx = self.rootSplitView.arrangedSubviews.count - 2
                self.rootSplitView.setPosition(
                    max(420, self.rootSplitView.bounds.width - 310),
                    ofDividerAt: dividerIdx
                )
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    self.previewSidebar.animator().alphaValue = 1
                }
            }
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                previewSidebar.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                guard let self, !UserDefaults.standard.bool(forKey: "PreviewSidebarVisible") else {
                    return
                }
                self.previewSidebar.isHidden = true
                self.previewSidebar.alphaValue = 1
                if self.previewSidebar.superview === self.rootSplitView {
                    self.rootSplitView.removeArrangedSubview(self.previewSidebar)
                    self.previewSidebar.removeFromSuperview()
                }
                self.rootSplitView.adjustSubviews()
            }
        }
        onSessionChanged?()
    }

    func quickLook(_ request: FPQuickLookRequest) {
        quickLookHandler(request)
    }

    var sessionPanes: [FPPaneSession] { panes.map(\.sessionState) }

    var activePaneSessionIndex: Int {
        guard let activePane else { return 0 }
        return panes.firstIndex(where: { $0 === activePane }) ?? 0
    }

    var paneSessionFractions: [Double] {
        let width = max(splitView.bounds.width, 1)
        return panes.map { Double(max(0, $0.frame.width) / width) }
    }

    private func applyPaneFractions(_ fractions: [Double]) {
        guard panes.count > 1, fractions.count == panes.count, splitView.bounds.width > 1 else { return }
        let usableWidth = splitView.bounds.width - CGFloat(panes.count - 1) * splitView.dividerThickness
        var position: CGFloat = 0
        let total = max(fractions.reduce(0, +), 0.001)
        for index in 0..<(panes.count - 1) {
            position += usableWidth * CGFloat(fractions[index] / total)
            splitView.setPosition(position + CGFloat(index) * splitView.dividerThickness, ofDividerAt: index)
        }
    }

    private func addRestoredPane(_ state: FPPaneSession) {
        let pane = BrowserPane(session: state)
        pane.workspace = self
        pane.setAlwaysOnTop(isAlwaysOnTop)
        pane.updateDiskGauge(FPDiskUsage.snapshot)
        panes.append(pane)
        splitView.addArrangedSubview(pane)
        activePane = pane
    }

    @objc private func themeChanged(_ notification: Notification) {
        updateWindowBackdrop()
        updateBackgroundGradient()
        editorialBackdropView.refreshTheme()
        auroraBackdropView.refreshTheme()
        sidebarSearchIcon.contentTintColor = FPStyle.dimText
        sidebarSearchField.textColor = FPStyle.text
        sidebarSearchScopeButton.contentTintColor = FPStyle.isObsidianAurora ? FPStyle.text : FPStyle.orange
        sidebarSearchScopeButton.layer?.backgroundColor = FPStyle.controlStrong.cgColor
        diskPanel.applyTheme()
        floatingDockView.applyTheme()
        edgeRailView.applyTheme()
        rebuildSidebarContents()
        needsDisplay = true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // F2 / fn+F2 всегда переименовывает активный файл или папку,
        // независимо от того, какой вид внутри окна держит фокус.
        if event.keyCode == 120,
           !(window?.firstResponder is NSText),
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            activePanel?.renameSelection(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func layout() {
        super.layout()
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        onSessionChanged?()
    }

    /// Перетаскивание края боковой панели.
    ///
    /// Ловится монитором, а не видом-ручкой: у прежней накладки `hitTest`
    /// сравнивал точку в системе координат надвью со своими границами,
    /// поэтому нажатие до неё не доходило и панель не тянулась.
    private func installSidebarResizeMonitor() {
        guard sidebarResizeMonitor == nil else { return }
        sidebarResizeMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self,
                  self.currentLayout == .classicSidebar,
                  let window = self.window,
                  event.window === window,
                  let sidebar = self.rootSplitView.arrangedSubviews.first else {
                return event
            }
            let point = self.rootSplitView.convert(event.locationInWindow, from: nil)
            switch event.type {
            case .leftMouseDown:
                let edge = sidebar.frame.maxX
                guard abs(point.x - edge) <= 10 else { return event }
                self.isDraggingSidebarEdge = true
                return nil
            case .leftMouseDragged:
                guard self.isDraggingSidebarEdge else { return event }
                let target = min(max(point.x, 200), 560)
                self.rootSplitView.setPosition(target, ofDividerAt: 0)
                self.rootSplitView.layoutSubtreeIfNeeded()
                return nil
            default:
                guard self.isDraggingSidebarEdge else { return event }
                self.isDraggingSidebarEdge = false
                UserDefaults.standard.set(Double(sidebar.frame.width), forKey: "SidebarWidth")
                return nil
            }
        }
    }

    func splitView(
        _ splitView: NSSplitView,
        shouldHideDividerAt dividerIndex: Int
    ) -> Bool {
        if splitView === rootSplitView, dividerIndex == 1 {
            return !isPreviewPanelVisible
        }
        return false
    }

    func splitView(
        _ splitView: NSSplitView,
        additionalEffectiveRectOfDividerAt dividerIndex: Int
    ) -> NSRect {
        let hitWidth: CGFloat = 12
        let subviews = splitView.arrangedSubviews
        guard dividerIndex >= 0, dividerIndex + 1 < subviews.count else {
            return .zero
        }
        let leadingView = subviews[dividerIndex]
        let trailingView = subviews[dividerIndex + 1]
        guard !leadingView.isHidden, !trailingView.isHidden else {
            return .zero
        }
        // Keep the native NSSplitView drag, but give its one-pixel divider a
        // forgiving hit target. The visual line stays thin; only the mouse
        // interaction area grows into both neighbouring panes.
        return NSRect(
            x: leadingView.frame.maxX - hitWidth / 2,
            y: splitView.bounds.minY,
            width: hitWidth,
            height: splitView.bounds.height
        )
    }

    private func updateBackgroundGradient() {
        let opacity = min(max(FPStyle.pane.alphaComponent, 0), 1)
        if FPStyle.isObsidianAurora {
            // В V3 основной фон и световая дуга рисуются через `auroraBackdropView`,
            // поэтому базовый линейный градиент остаётся прозрачным, не мутня стекло.
            backgroundGradientView.setColors([
                NSColor.clear,
                NSColor.clear
            ])
            return
        }
        if FPStyle.isCyberEditorial {
            backgroundGradientView.setColors(
                FPStyle.gradientEnabled
                    ? [
                        FPStyle.gradientStart.withAlphaComponent(0.42),
                        FPStyle.window.withAlphaComponent(0.86),
                        FPStyle.gradientEnd.withAlphaComponent(0.38)
                    ]
                    : [
                        FPStyle.window.withAlphaComponent(0.82),
                        FPStyle.window.withAlphaComponent(0.82)
                    ]
            )
            return
        }
        // Keep the theme's blue/orange character clearly visible while the
        // visual-effect backdrop supplies real macOS blur underneath it.
        let gradientOpacity = min(0.75, 0.50 + opacity * 0.25)
        backgroundGradientView.setColors(
            FPStyle.gradientEnabled
                ? [
                    FPStyle.gradientStart.withAlphaComponent(gradientOpacity),
                    FPStyle.gradientEnd.withAlphaComponent(gradientOpacity)
                ]
                : [
                    FPStyle.window.withAlphaComponent(gradientOpacity),
                    FPStyle.window.withAlphaComponent(gradientOpacity)
                ]
        )
    }

    private func updateWindowBackdrop() {
        let opacity = min(max(FPStyle.pane.alphaComponent, 0), 1)
        let backdropOpacity = min(0.30, 0.08 + opacity * 0.22)
        layer?.backgroundColor = FPStyle.window.withAlphaComponent(backdropOpacity).cgColor
    }

    func addPane(with url: URL, after pane: BrowserPane?) {
        let previousPaneCount = panes.count
        if previousPaneCount == 1, let window, !window.styleMask.contains(.fullScreen) {
            frameBeforeSplit = window.frame
        }
        let previousPaneWidth = previousPaneCount > 0
            ? max(320, splitView.bounds.width / CGFloat(previousPaneCount))
            : 0
        let newPane = BrowserPane(startURL: url)
        newPane.workspace = self
        newPane.setAlwaysOnTop(isAlwaysOnTop)

        let index: Int
        if let pane, let existingIndex = panes.firstIndex(where: { $0 === pane }) {
            index = existingIndex + 1
        } else {
            index = panes.count
        }

        panes.insert(newPane, at: index)
        splitView.insertArrangedSubview(newPane, at: index)
        newPane.updateDiskGauge(FPDiskUsage.snapshot)
        newPane.updateStudioSearch(query: sidebarSearchField.stringValue, isGlobalScope: searchScope == .mac)
        for (idx, p) in panes.enumerated() {
            p.applyWorkspaceLayout(currentLayout, isLeadingPane: idx == 0)
        }
        activePane = newPane
        if let panel = newPane.activePanel {
            activate(panel: panel, in: newPane)
        }
        if previousPaneCount > 0 {
            expandWindowForNewPane(preferredWidth: previousPaneWidth)
        }
        DispatchQueue.main.async { [weak self] in
            self?.equalizePaneWidths()
        }
        onSessionChanged?()
    }

    func removePane(_ pane: BrowserPane) {
        guard panes.count > 1, let index = panes.firstIndex(where: { $0 === pane }) else { return }
        let removedWidth = max(260, pane.frame.width + splitView.dividerThickness)
        panes.remove(at: index)
        splitView.removeArrangedSubview(pane)
        pane.removeFromSuperview()
        for (idx, p) in panes.enumerated() {
            p.applyWorkspaceLayout(currentLayout, isLeadingPane: idx == 0)
        }
        splitView.adjustSubviews()
        splitView.needsLayout = true
        splitView.layoutSubtreeIfNeeded()
        let nextIndex = min(index, panes.count - 1)
        activePane = panes[nextIndex]
        if let panel = panes[nextIndex].activePanel {
            activate(panel: panel, in: panes[nextIndex])
        }
        if panes.count == 1, let saved = frameBeforeSplit, let window, !window.styleMask.contains(.fullScreen) {
            frameBeforeSplit = nil
            window.setFrame(saved, display: true, animate: true)
        } else {
            shrinkWindowAfterRemovingPane(width: removedWidth)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            self?.equalizePaneWidths()
        }
        onSessionChanged?()
    }

    private func expandWindowForNewPane(preferredWidth: CGFloat) {
        guard let window, !window.styleMask.contains(.fullScreen), let screen = window.screen else { return }
        var frame = window.frame
        let availableRight = max(0, screen.visibleFrame.maxX - frame.maxX)
        let availableLeft = max(0, frame.minX - screen.visibleFrame.minX)
        let desiredGrowth = min(preferredWidth + splitView.dividerThickness, availableRight + availableLeft)
        guard desiredGrowth > 40 else { return }
        let growRight = min(desiredGrowth, availableRight)
        let growLeft = desiredGrowth - growRight
        frame.origin.x -= growLeft
        frame.size.width += desiredGrowth
        window.setFrame(frame, display: true, animate: true)
    }

    private func shrinkWindowAfterRemovingPane(width: CGFloat) {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        var frame = window.frame
        let minimumWidth: CGFloat = 760
        let shrink = min(width, max(0, frame.width - minimumWidth))
        guard shrink > 1 else { return }
        frame.size.width -= shrink
        window.setFrame(frame, display: true, animate: true)
    }

    private func equalizePaneWidths() {
        guard panes.count > 1, splitView.bounds.width > 1 else {
            splitView.adjustSubviews()
            return
        }
        let dividerTotal = CGFloat(panes.count - 1) * splitView.dividerThickness
        let paneWidth = max(260, (splitView.bounds.width - dividerTotal) / CGFloat(panes.count))
        for dividerIndex in 0..<(panes.count - 1) {
            let position = CGFloat(dividerIndex + 1) * paneWidth + CGFloat(dividerIndex) * splitView.dividerThickness
            splitView.setPosition(position, ofDividerAt: dividerIndex)
        }
        splitView.adjustSubviews()
    }

    private func buildSidebar() -> NSView {
        let container = FPSidebarView()
        container.userInterfaceLayoutDirection = .leftToRight
        // Обязательные ограничения 244-360 перебивали любое перетаскивание
        // разделителя: сплит-вью выставлял ширину, а автолейаут возвращал её
        // обратно. Диапазон расширен и понижен в приоритете, чтобы решение
        // оставалось за разделителем.
        let minWidth = container.widthAnchor.constraint(greaterThanOrEqualToConstant: 200)
        minWidth.priority = NSLayoutConstraint.Priority(999)
        minWidth.isActive = true
        let maxWidth = container.widthAnchor.constraint(lessThanOrEqualToConstant: 560)
        maxWidth.priority = NSLayoutConstraint.Priority(999)
        maxWidth.isActive = true

        configureSidebarSearchField()

        sidebarStack.userInterfaceLayoutDirection = .leftToRight
        sidebarStack.orientation = .vertical
        // Every row follows the split-view width. Fixed 210 pt rows plus both
        // outer constraints previously pinned the whole sidebar at exactly
        // 244 pt and made the divider appear completely frozen.
        sidebarStack.alignment = .leading
        sidebarStack.spacing = 2
        // Use real constraints instead of NSStackView.edgeInsets. AppKit can
        // temporarily drop stack edge insets while rebuilding/compressing a
        // sibling tab bar, which made every sidebar label jump to x = 0.
        sidebarStack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)
        sidebarStack.translatesAutoresizingMaskIntoConstraints = false

        sidebarSettingsFooter.userInterfaceLayoutDirection = .leftToRight
        sidebarSettingsFooter.orientation = .vertical
        sidebarSettingsFooter.alignment = .leading
        sidebarSettingsFooter.spacing = 6
        sidebarSettingsFooter.translatesAutoresizingMaskIntoConstraints = false

        rebuildSidebarContents()

        diskPanel.onSegmentPicked = { [weak self] filter in
            self?.activePanel?.applyFilterFromSidebar(filter)
        }
        diskPanel.onFolderPicked = { [weak self] url in
            self?.activePanel?.navigate(to: url)
        }
        diskPanel.onAnalyzeDisk = { [weak self] in
            self?.openDiskAnalyzer(nil)
        }
        FPDiskUsage.refreshCapacity()
        diskPanel.update(FPDiskUsage.snapshot)
        floatingDockView.updateDisk(FPDiskUsage.snapshot)
        edgeRailView.updateDisk(FPDiskUsage.snapshot)
        panes.forEach { $0.updateDiskGauge(FPDiskUsage.snapshot) }
        FPDiskUsage.refreshBreakdown { [weak self] in
            self?.diskPanel.update(FPDiskUsage.snapshot)
            self?.floatingDockView.updateDisk(FPDiskUsage.snapshot)
            self?.edgeRailView.updateDisk(FPDiskUsage.snapshot)
            self?.panes.forEach { $0.updateDiskGauge(FPDiskUsage.snapshot) }
        }

        // Оборачиваем список сайдбара в scroll view, чтобы при раскрытии
        // виджета диска, большом числе дисков или невысоком окне пункты
        // сайдбара никогда не налезали на нижнюю панель диска.
        let sidebarDocument = FPFlippedView()
        sidebarDocument.translatesAutoresizingMaskIntoConstraints = false
        sidebarDocument.addSubview(sidebarStack)

        let sidebarScroll = NSScrollView()
        sidebarScroll.automaticallyAdjustsContentInsets = false
        sidebarScroll.contentInsets = NSEdgeInsets()
        sidebarScroll.contentView.automaticallyAdjustsContentInsets = false
        sidebarScroll.contentView.contentInsets = NSEdgeInsets()
        sidebarScroll.documentView = sidebarDocument
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.scrollerStyle = .overlay
        sidebarScroll.autohidesScrollers = true
        sidebarScroll.hasHorizontalScroller = false
        sidebarScroll.drawsBackground = false
        sidebarScroll.borderType = .noBorder
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(sidebarScroll)
        container.addSubview(sidebarSettingsFooter)
        container.addSubview(diskPanel)
        NSLayoutConstraint.activate([
            sidebarStack.leadingAnchor.constraint(equalTo: sidebarDocument.leadingAnchor),
            sidebarStack.trailingAnchor.constraint(equalTo: sidebarDocument.trailingAnchor),
            sidebarStack.topAnchor.constraint(equalTo: sidebarDocument.topAnchor),
            sidebarStack.bottomAnchor.constraint(equalTo: sidebarDocument.bottomAnchor, constant: -6),
            sidebarDocument.widthAnchor.constraint(equalTo: sidebarScroll.contentView.widthAnchor),

            sidebarScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            sidebarScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            sidebarScroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 52),
            sidebarScroll.bottomAnchor.constraint(equalTo: sidebarSettingsFooter.topAnchor, constant: -8),

            sidebarSettingsFooter.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            sidebarSettingsFooter.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            sidebarSettingsFooter.bottomAnchor.constraint(equalTo: diskPanel.topAnchor, constant: -8),

            // Занятость диска прижата к низу панели: это справочная строка, а
            // не пункт навигации, ей не место в общем списке.
            diskPanel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            diskPanel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            diskPanel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14)
        ])
        return container
    }

    private func configureSidebarSearchField() {
        sidebarSearchField.placeholderString = "Поиск"
        sidebarSearchField.target = self
        sidebarSearchField.action = #selector(sidebarSearchChanged(_:))
        sidebarSearchField.delegate = self
        sidebarSearchField.isBordered = false
        sidebarSearchField.isBezeled = false
        sidebarSearchField.focusRingType = .none
        sidebarSearchField.drawsBackground = false
        sidebarSearchField.textColor = FPStyle.text
        sidebarSearchField.font = .systemFont(ofSize: 13, weight: .medium)
        sidebarSearchField.translatesAutoresizingMaskIntoConstraints = false

        sidebarSearchScopeButton.font = .systemFont(ofSize: 10.5, weight: .semibold)
        sidebarSearchScopeButton.isBordered = false
        sidebarSearchScopeButton.bezelStyle = .inline
        sidebarSearchScopeButton.target = self
        sidebarSearchScopeButton.action = #selector(toggleSearchScope(_:))
        sidebarSearchScopeButton.toolTip = "Искать в текущей папке. Нажмите, чтобы искать на всём Mac"
        sidebarSearchScopeButton.wantsLayer = true
        sidebarSearchScopeButton.layer?.cornerRadius = 6
        sidebarSearchScopeButton.layer?.backgroundColor = FPStyle.controlStrong.cgColor
        sidebarSearchScopeButton.translatesAutoresizingMaskIntoConstraints = false
        applySearchScopeAppearance()

        if #available(macOS 11.0, *) {
            sidebarSearchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Поиск")
        }
        sidebarSearchIcon.imageScaling = .scaleProportionallyDown
        sidebarSearchIcon.contentTintColor = FPStyle.dimText
        sidebarSearchIcon.translatesAutoresizingMaskIntoConstraints = false

        sidebarSearchContainer.translatesAutoresizingMaskIntoConstraints = false
        sidebarSearchContainer.addSubview(sidebarSearchIcon)
        sidebarSearchContainer.addSubview(sidebarSearchField)
        sidebarSearchContainer.addSubview(sidebarSearchScopeButton)
        NSLayoutConstraint.activate([
            sidebarSearchContainer.heightAnchor.constraint(equalToConstant: 30),
            sidebarSearchIcon.leadingAnchor.constraint(equalTo: sidebarSearchContainer.leadingAnchor, constant: 2),
            sidebarSearchIcon.centerYAnchor.constraint(equalTo: sidebarSearchContainer.centerYAnchor),
            sidebarSearchIcon.widthAnchor.constraint(equalToConstant: 17),
            sidebarSearchIcon.heightAnchor.constraint(equalToConstant: 17),
            sidebarSearchField.leadingAnchor.constraint(equalTo: sidebarSearchIcon.trailingAnchor, constant: 7),
            sidebarSearchField.trailingAnchor.constraint(equalTo: sidebarSearchScopeButton.leadingAnchor, constant: -5),
            sidebarSearchField.centerYAnchor.constraint(equalTo: sidebarSearchContainer.centerYAnchor),
            sidebarSearchField.heightAnchor.constraint(equalToConstant: 26),
            sidebarSearchScopeButton.trailingAnchor.constraint(equalTo: sidebarSearchContainer.trailingAnchor, constant: -1),
            sidebarSearchScopeButton.centerYAnchor.constraint(equalTo: sidebarSearchContainer.centerYAnchor),
            sidebarSearchScopeButton.widthAnchor.constraint(equalToConstant: 48),
            sidebarSearchScopeButton.heightAnchor.constraint(equalToConstant: 23)
        ])
    }

    private func rebuildSidebarContents() {
        if let tagListScrollObserver {
            NotificationCenter.default.removeObserver(tagListScrollObserver)
            self.tagListScrollObserver = nil
        }
        for view in sidebarStack.arrangedSubviews {
            sidebarStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        func appendFullWidth(_ view: NSView) {
            sidebarStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor).isActive = true
        }

        appendFullWidth(sidebarSearchContainer)
        appendFullWidth(separator())

        appendFullWidth(sectionHeader("Закреплённые"))
        for entry in bookmarkLocations() {
            appendFullWidth(locationButton(title: entry.title, symbol: entry.symbol, url: entry.url, removableBookmark: entry.removable))
        }
        appendFullWidth(bookmarkDropButton())

        appendFullWidth(sectionHeader("Диски"))
        for entry in storageLocations() {
            appendFullWidth(volumeRow(title: entry.title, symbol: entry.symbol, url: entry.url, ejectable: entry.ejectable))
        }

        appendFullWidth(sectionHeader("Папки"))
        appendFullWidth(commandButton(title: "Недавние", symbol: "clock.arrow.circlepath", action: #selector(openRecents(_:))))
        for entry in placeLocations() {
            appendFullWidth(locationButton(title: entry.title, symbol: entry.symbol, url: entry.url))
        }

        appendFullWidth(sectionHeader("Теги"))
        appendFullWidth(tagListScrollView())
        appendFullWidth(commandButton(title: "Все теги...", symbol: "tag", action: #selector(showAllTags(_:))))

        for view in sidebarSettingsFooter.arrangedSubviews {
            sidebarSettingsFooter.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let footerSep = separator()
        sidebarSettingsFooter.addArrangedSubview(footerSep)
        footerSep.widthAnchor.constraint(equalTo: sidebarSettingsFooter.widthAnchor).isActive = true
        let settingsBtn = commandButton(title: "Настройки", symbol: "slider.horizontal.3", action: #selector(openSettings(_:)))
        sidebarSettingsFooter.addArrangedSubview(settingsBtn)
        settingsBtn.widthAnchor.constraint(equalTo: sidebarSettingsFooter.widthAnchor).isActive = true
    }

    private func tagListScrollView() -> NSScrollView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        for tag in FPTag.all {
            let button = tagButton(title: tag.title, key: tag.key, color: tag.color)
            stack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let document = FPFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .none
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentView.postsBoundsChangedNotifications = true

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])

        tagListScrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView,
            queue: .main
        ) { [weak stack] _ in
            guard let stack else { return }
            for case let button as AnimatedSidebarButton in stack.arrangedSubviews {
                button.refreshHoverStateFromCurrentMouseLocation()
            }
        }
        scroll.heightAnchor.constraint(equalToConstant: 184).isActive = true
        return scroll
    }

    @objc private func tagsChanged(_ notification: Notification) {
        rebuildSidebarContents()
        edgeRailView.rebuildItems()
        if activePanel?.tabTitle == "Все теги" {
            activePanel?.showTaggedItems(tagKey: nil, title: "Все теги", addingToHistory: false)
        }
    }

    @objc private func sidebarSearchChanged(_ sender: NSTextField) {
        routeSearch(sender.stringValue)
    }

    func controlTextDidChange(_ obj: Notification) {
        if let field = obj.object as? NSTextField,
           field === sidebarSearchField || field.identifier?.rawValue == "QyvroFloatingSearchField" {
            if field !== sidebarSearchField {
                sidebarSearchField.stringValue = field.stringValue
            }
            routeSearch(field.stringValue)
        }
    }

    func focusSidebarSearch() {
        if currentLayout == .studioCanvas {
            activePanel?.studioHeaderView.focusSearchField()
            return
        }
        if currentLayout == .classicSidebar {
            window?.makeFirstResponder(sidebarSearchField)
            sidebarSearchField.currentEditor()?.selectAll(nil)
            return
        }
        presentFloatingSearchPopover()
    }

    func handleExternalSearchInput(_ text: String) {
        if sidebarSearchField.stringValue != text {
            sidebarSearchField.stringValue = text
        }
        routeSearch(text)
    }

    func toggleSearchScopeFromExternal() {
        toggleSearchScope(nil)
        panes.forEach {
            $0.updateStudioSearch(query: sidebarSearchField.stringValue, isGlobalScope: searchScope == .mac)
        }
    }

    private func presentFloatingSearchPopover() {
        if let existing = floatingSearchPopover, existing.isShown {
            existing.close()
            floatingSearchPopover = nil
            return
        }
        let host = FPAuxiliaryBackdrop(frame: NSRect(x: 0, y: 0, width: 340, height: 46))
        host.layer?.cornerRadius = 12
        host.layer?.masksToBounds = true

        let icon = NSImageView()
        if #available(macOS 11.0, *) {
            icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Поиск")
        }
        icon.contentTintColor = FPStyle.dimText
        icon.translatesAutoresizingMaskIntoConstraints = false

        let field = CenteredTextField()
        field.identifier = NSUserInterfaceItemIdentifier("QyvroFloatingSearchField")
        field.placeholderString = searchScope == .mac ? "Поиск по всему Mac…" : "Поиск в текущей папке…"
        field.stringValue = sidebarSearchField.stringValue
        field.isBordered = false
        field.isBezeled = false
        field.focusRingType = .none
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 13.5, weight: .medium)
        field.textColor = FPStyle.text
        field.delegate = self
        field.target = self
        field.action = #selector(sidebarSearchChanged(_:))
        field.translatesAutoresizingMaskIntoConstraints = false

        let scope = NSButton(
            title: searchScope == .mac ? "Мак" : "Папка",
            target: self,
            action: #selector(toggleSearchScopeFromPopover(_:))
        )
        scope.isBordered = false
        scope.bezelStyle = .inline
        scope.font = .systemFont(ofSize: 11, weight: .semibold)
        scope.contentTintColor = searchScope == .mac ? FPStyle.accent : FPStyle.text
        scope.wantsLayer = true
        scope.layer?.cornerRadius = 7
        scope.layer?.backgroundColor = FPStyle.controlStrong.cgColor
        scope.translatesAutoresizingMaskIntoConstraints = false

        host.addSubview(icon)
        host.addSubview(field)
        host.addSubview(scope)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: scope.leadingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            field.heightAnchor.constraint(equalToConstant: 26),
            scope.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -10),
            scope.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            scope.widthAnchor.constraint(equalToConstant: 56),
            scope.heightAnchor.constraint(equalToConstant: 24)
        ])

        let vc = NSViewController()
        vc.view = host
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = host.frame.size
        popover.contentViewController = vc
        floatingSearchPopover = popover

        let anchor: NSView = currentLayout == .floatingDock ? floatingDockView : edgeRailView
        let edge: NSRectEdge = currentLayout == .floatingDock ? .maxY : .maxX
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: edge)
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
    }

    @objc private func toggleSearchScopeFromPopover(_ sender: NSButton) {
        toggleSearchScope(sender)
        let isMac = searchScope == .mac
        sender.title = isMac ? "Мак" : "Папка"
        sender.contentTintColor = isMac ? FPStyle.accent : FPStyle.text
    }

    /// Вид переключателя области поиска: «Мак» выделен цветом, «Папка» —
    /// обычным текстом, чтобы расширенный поиск был заметен.
    private func applySearchScopeAppearance() {
        let isMac = searchScope == .mac
        let title = isMac ? "Мак" : "Папка"
        // Иначе анимация нажатия вернёт подпись, запомненную до переключения.
        sidebarSearchScopeButton.cancelTitleAnimation()
        sidebarSearchScopeButton.title = title
        sidebarSearchScopeButton.contentTintColor = isMac ? FPStyle.orange : FPStyle.text
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        sidebarSearchScopeButton.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: isMac ? FPStyle.orange : FPStyle.text,
                .paragraphStyle: paragraph
            ]
        )
        sidebarSearchScopeButton.toolTip = isMac
            ? "Искать на всём Mac. Нажмите, чтобы искать только в текущей папке"
            : "Искать в текущей папке. Нажмите, чтобы искать на всём Mac"
    }

    func syncSidebarSearchFromActivePanel() {
        if searchScope == .folder {
            let q = activePanel?.searchQuery ?? ""
            sidebarSearchField.stringValue = q
            panes.forEach { $0.updateStudioSearch(query: q, isGlobalScope: false) }
        }
    }

    @objc private func toggleSearchScope(_ sender: Any?) {
        searchScope = searchScope == .folder ? .mac : .folder
        let isMac = searchScope == .mac
        // Запрос запоминается до переключения: возврат в режим папки делает
        // переход в текущую папку, а тот синхронизирует поле из панели, где
        // запрос уже пустой — набранный текст затирался.
        let pendingQuery = sidebarSearchField.stringValue
        FPActionLog.action(
            "поиск: область → \(isMac ? "Мак" : "Папка")",
            "запрос «\(pendingQuery)»"
        )
        applySearchScopeAppearance()
        if !isMac {
            stopGlobalSearch()
            if let panel = activePanel {
                panel.navigate(to: panel.currentURL, addingToHistory: false)
                sidebarSearchField.stringValue = pendingQuery
                panel.setSearchQuery(pendingQuery)
            }
        } else {
            activePanel?.setSearchQuery("")
            sidebarSearchField.stringValue = pendingQuery
            routeSearch(pendingQuery)
        }
    }

    private func routeSearch(_ text: String) {
        let studioFieldFocused = currentLayout == .studioCanvas
            && (activePanel?.studioHeaderView.isSearchFieldFocused == true)
        let searchWasFocused = window?.firstResponder === sidebarSearchField.currentEditor() || studioFieldFocused
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if searchScope == .folder {
            activePanel?.setSearchQuery(query)
            restoreSidebarSearchFocus(ifNeeded: searchWasFocused)
            return
        }
        globalSearchWorkItem?.cancel()
        guard !query.isEmpty else {
            stopGlobalSearch()
            if let panel = activePanel {
                panel.navigate(to: panel.currentURL, addingToHistory: false)
            }
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.startGlobalSearch(query) }
        globalSearchWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
        restoreSidebarSearchFocus(ifNeeded: searchWasFocused)
    }

    private func restoreSidebarSearchFocus(ifNeeded shouldRestore: Bool) {
        guard shouldRestore, let window else { return }
        if currentLayout == .studioCanvas {
            activePanel?.studioHeaderView.restoreSearchFocusPreservingCaret()
            return
        }
        let insertionPoint = sidebarSearchField.currentEditor()?.selectedRange.location ?? sidebarSearchField.stringValue.utf16.count
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            window.makeFirstResponder(self.sidebarSearchField)
            let length = self.sidebarSearchField.stringValue.utf16.count
            self.sidebarSearchField.currentEditor()?.selectedRange = NSRange(location: min(insertionPoint, length), length: 0)
        }
    }

    private func startGlobalSearch(_ text: String) {
        stopGlobalSearch()
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.predicate = FPSpotlightSearch.predicate(for: text)
        let center = NotificationCenter.default
        metadataObservers = [
            center.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
                self?.publishGlobalSearch(query: query, text: text)
            },
            center.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: .main) { [weak self] _ in
                self?.publishGlobalSearch(query: query, text: text)
            }
        ]
        metadataQuery = query
        query.start()
    }

    private func publishGlobalSearch(query: NSMetadataQuery, text: String) {
        guard metadataQuery === query, searchScope == .mac,
              sidebarSearchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
        query.disableUpdates()
        // Отбор идёт по всей выдаче, а срез берётся уже после него: иначе
        // первые восемьсот результатов оказывались забиты кэшами и
        // внутренностями программ, а нужные файлы в срез не попадали.
        var urls: [URL] = []
        var skipped = 0
        for result in query.results {
            guard let item = result as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            let url = URL(fileURLWithPath: path)
            guard FPSpotlightSearch.isMeaningful(url) else {
                skipped += 1
                continue
            }
            urls.append(url)
            if urls.count >= 800 { break }
        }
        query.enableUpdates()
        FPActionLog.result(
            "поиск по Маку: «\(text)»",
            "показано \(urls.count), отсеяно служебных \(skipped)"
        )
        activePanel?.showSearchResults(urls, query: text)
    }

    private func stopGlobalSearch() {
        globalSearchWorkItem?.cancel()
        metadataQuery?.stop()
        metadataQuery = nil
        metadataObservers.forEach(NotificationCenter.default.removeObserver)
        metadataObservers.removeAll()
    }

    private func bookmarkLocations() -> [(title: String, symbol: String, url: URL, removable: Bool)] {
        var entries: [(title: String, symbol: String, url: URL, removable: Bool)] = []
        var seen = Set<String>()

        for path in UserDefaults.standard.stringArray(forKey: "SidebarBookmarks") ?? [] {
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path), !seen.contains(url.path) else { continue }
            let title = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
            entries.append((title, "folder", url, true))
            seen.insert(url.path)
        }

        return entries
    }

    private func storageLocations() -> [(title: String, symbol: String, url: URL, ejectable: Bool)] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey], options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.volumeNameKey])
            let title = values?.volumeName ?? url.lastPathComponent
            guard !title.isEmpty else { return nil }
            let ejectable = FPDiskUsage.isEjectableVolume(at: url)
            return (title, ejectable ? "externaldrive" : "internaldrive", url, ejectable)
        }
    }

    private func volumeRow(title: String, symbol: String, url: URL, ejectable: Bool) -> NSView {
        let button = locationButton(title: title, symbol: symbol, url: url)
        if let cap = FPDiskUsage.volumeCapacity(at: url) {
            let freeText = ByteCountFormatter.string(fromByteCount: cap.free, countStyle: .file)
            let totalText = ByteCountFormatter.string(fromByteCount: cap.total, countStyle: .file)
            button.toolTip = "\(title) — свободно \(freeText) из \(totalText)"
        }
        guard ejectable else { return button }

        button.contextMenuProvider = { [weak self] in
            guard let self else { return nil }
            let menu = NSMenu()
            let ejectItem = NSMenuItem(title: "Извлечь «\(title)»", action: #selector(self.ejectVolumeFromMenu(_:)), keyEquivalent: "")
            ejectItem.target = self
            ejectItem.representedObject = url
            menu.addItem(ejectItem)
            return menu
        }

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let ejectButton = NSButton()
        ejectButton.isBordered = false
        ejectButton.bezelStyle = .inline
        ejectButton.imagePosition = .imageOnly
        if #available(macOS 11.0, *) {
            let img = NSImage(systemSymbolName: "eject.fill", accessibilityDescription: "Извлечь")
            img?.size = NSSize(width: 11, height: 11)
            ejectButton.image = img
        } else {
            ejectButton.title = "⏏"
        }
        ejectButton.contentTintColor = FPStyle.dimText
        ejectButton.toolTip = "Извлечь «\(title)»"
        ejectButton.target = self
        ejectButton.action = #selector(ejectVolumeButtonPressed(_:))
        ejectButton.identifier = NSUserInterfaceItemIdentifier(url.path)
        ejectButton.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(button)
        row.addSubview(ejectButton)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 24),
            button.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: ejectButton.leadingAnchor, constant: -2),
            button.topAnchor.constraint(equalTo: row.topAnchor),
            button.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            ejectButton.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -2),
            ejectButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            ejectButton.widthAnchor.constraint(equalToConstant: 20),
            ejectButton.heightAnchor.constraint(equalToConstant: 20)
        ])
        return row
    }

    @objc private func ejectVolumeButtonPressed(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        ejectVolume(at: URL(fileURLWithPath: path))
    }

    @objc private func ejectVolumeFromMenu(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        ejectVolume(at: url)
    }

    private func ejectVolume(at url: URL) {
        FPActionLog.action("извлечение диска", url.lastPathComponent)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            } catch {
                DispatchQueue.main.async {
                    NSSound.beep()
                    FPActionLog.problem("не удалось извлечь диск", "\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
    }

    private func placeLocations() -> [(title: String, symbol: String, url: URL)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let entries: [(String, String, URL)] = [
            ("Дом", "house", home),
            ("Рабочий стол", "menubar.rectangle", home.appendingPathComponent("Desktop", isDirectory: true)),
            ("Загрузки", "arrow.down.circle", home.appendingPathComponent("Downloads", isDirectory: true)),
            ("Документы", "doc.text", home.appendingPathComponent("Documents", isDirectory: true)),
            ("Изображения", "photo", home.appendingPathComponent("Pictures", isDirectory: true)),
            ("Видео", "film", home.appendingPathComponent("Movies", isDirectory: true)),
            ("Программы", "app.badge", URL(fileURLWithPath: "/Applications", isDirectory: true))
        ]
        return entries
    }

    private func locationButton(title: String, symbol: String, url: URL, removableBookmark: Bool = false) -> LocationButton {
        let button = LocationButton()
        button.locationURL = url
        configureSidebarButton(button, title: title, symbol: symbol)
        button.target = self
        button.action = #selector(openLocation(_:))
        if removableBookmark {
            button.contextMenuProvider = { [weak self, weak button] in
                guard let self, let path = button?.locationURL?.standardizedFileURL.path else { return nil }
                let menu = NSMenu()
                let item = NSMenuItem(title: "Удалить из закреплённых", action: #selector(self.removeBookmarkFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = path
                menu.addItem(item)
                return menu
            }
        }
        return button
    }

    private func commandButton(title: String, symbol: String, action: Selector) -> NSButton {
        let button = AnimatedSidebarButton()
        configureSidebarButton(button, title: title, symbol: symbol)
        button.target = self
        button.action = action
        return button
    }

    private func bookmarkDropButton() -> NSButton {
        let button = BookmarkDropButton()
        configureSidebarButton(button, title: "Закрепить папку", symbol: "plus.square.dashed")
        button.target = self
        button.action = #selector(addBookmark(_:))
        button.onURLsDropped = { [weak self] urls in
            self?.addBookmarks(from: urls)
        }
        return button
    }

    private func tagButton(title: String, key: String?, color: NSColor?) -> TagDropButton {
        let button = TagDropButton(title: title, key: key, color: color)
        button.onApply = { [weak self] tagKey, urls in
            self?.applyTag(tagKey, to: urls)
        }
        button.onOpen = { [weak self] tagKey, tagTitle in
            self?.activePanel?.showTaggedItems(tagKey: tagKey, title: tagTitle)
        }
        return button
    }

    private func configureSidebarButton(_ button: NSButton, title: String, symbol: String) {
        let aurora = FPStyle.isObsidianAurora
        button.title = title
        button.userInterfaceLayoutDirection = .leftToRight
        if #available(macOS 11.0, *), let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            image.size = NSSize(width: 15.5, height: 15.5)
            button.image = image
            button.imagePosition = .imageLeading
        }
        button.alignment = .left
        button.cell?.alignment = .left
        button.cell?.baseWritingDirection = .leftToRight
        button.sendAction(on: [.leftMouseDown])
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.bezelStyle = .inline
        button.isBordered = false
        // В V3 значки спокойные монохромные (как в Steam/Spotify Glass), в V2 — акцентные.
        button.contentTintColor = aurora ? FPStyle.dimText : FPStyle.accent
        let font = aurora
            ? NSFont.systemFont(ofSize: 12.5, weight: .medium)
            : FPStyle.headingFont(
                ofSize: FPStyle.isCyberEditorial ? 12 : 12.5,
                weight: .semibold
            )
        button.font = font
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.baseWritingDirection = .leftToRight
        button.attributedTitle = NSAttributedString(
            string: aurora ? title : title.uppercased(),
            attributes: [
                .font: font,
                .foregroundColor: aurora ? FPStyle.text.withAlphaComponent(0.90) : FPStyle.text,
                .paragraphStyle: paragraph,
                .kern: aurora ? 0.0 : 0.6
            ]
        )
        button.wantsLayer = true
        button.layer?.cornerRadius = aurora ? 9 : 8
        button.layer?.backgroundColor = NSColor.clear.cgColor
        button.layer?.borderColor = NSColor.clear.cgColor
        button.layer?.borderWidth = 0
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: aurora ? 30 : 28).isActive = true
    }

    private func sectionHeader(_ title: String) -> NSTextField {
        let aurora = FPStyle.isObsidianAurora
        let field = NSTextField(
            labelWithString: FPStyle.isCyberEditorial ? title.uppercased() : title
        )
        field.font = aurora
            ? .systemFont(ofSize: 10.5, weight: .semibold)
            : FPStyle.headingFont(
                ofSize: FPStyle.isCyberEditorial ? 10 : 11,
                weight: FPStyle.isCyberEditorial ? .bold : .medium
            )
        field.textColor = FPStyle.dimText.withAlphaComponent(
            aurora ? 0.56 : (FPStyle.isCyberEditorial ? 0.72 : 0.62)
        )
        field.attributedStringValue = NSAttributedString(
            string: field.stringValue,
            attributes: [
                .font: field.font as Any,
                .foregroundColor: field.textColor as Any,
                .kern: aurora ? 0.3 : 1.1
            ]
        )
        field.alignment = .left
        field.baseWritingDirection = .leftToRight
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    private func separator() -> NSView {
        let line = FPLayerView(color: FPStyle.stroke.withAlphaComponent(0.55))
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    @objc private func openLocation(_ sender: LocationButton) {
        guard let url = sender.locationURL else { return }
        activePanel?.navigate(to: url)
    }

    @objc private func openSettings(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.showSettings(sender)
    }

    @objc private func removeBookmarkFromMenu(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        let paths = (UserDefaults.standard.stringArray(forKey: "SidebarBookmarks") ?? [])
            .filter { URL(fileURLWithPath: $0).standardizedFileURL.path != path }
        UserDefaults.standard.set(paths, forKey: "SidebarBookmarks")
        rebuildSidebarContents()
    }

    private func applyTag(_ key: String?, to urls: [URL]) {
        guard let key, !urls.isEmpty else { return }
        let targets = urls
        activePanel?.applyFolderColor(key, to: targets)
    }

    private func addBookmarks(from urls: [URL]) {
        let folders = urls.compactMap { bookmarkableURL(from: $0) }
        guard !folders.isEmpty else { return }

        var paths = UserDefaults.standard.stringArray(forKey: "SidebarBookmarks") ?? []
        var seen = Set(paths)
        for url in folders {
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else { continue }
            paths.append(path)
            seen.insert(path)
        }
        UserDefaults.standard.set(paths, forKey: "SidebarBookmarks")
        rebuildSidebarContents()
    }

    private func bookmarkableURL(from url: URL) -> URL? {
        let resolved = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return resolved
    }

    @objc func openFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = activePanel?.currentURL
        if panel.runModal() == .OK, let url = panel.url {
            activePanel?.navigate(to: url)
        }
    }

    @objc func newTab(_ sender: Any?) {
        let url = activePanel?.currentURL ?? FileManager.default.homeDirectoryForCurrentUser
        activePane?.addTab(url: url, activate: true)
    }

    @objc func addBookmark(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = activePanel?.currentURL
        if panel.runModal() == .OK, let url = panel.url {
            addBookmarks(from: [url])
        }
    }

    @objc func openRecents(_ sender: Any?) {
        activePanel?.showRecentItems()
    }

    @objc func showDropShelf(_ sender: Any?) {
        QyvroDropShelfModule.shared.toggle()
    }

    @objc func openDiskAnalyzer(_ sender: Any?) {
        let root = FileManager.default.homeDirectoryForCurrentUser
        QyvroDiskAnalyzerModule.shared.show(rootURL: root)
    }

    var activeFolderURL: URL {
        activePanel?.currentURL ?? FileManager.default.homeDirectoryForCurrentUser
    }

    var openTabURLs: [URL] {
        panes.flatMap(\.tabURLs)
    }

    func openURLInActivePanel(_ url: URL) {
        (activePanel ?? activePane?.activePanel ?? panes.first?.activePanel)?.navigate(to: url)
    }

    func openURLInNewTab(_ url: URL) {
        (activePane ?? panes.first)?.addTab(url: url, activate: true)
    }

    func refreshLocalization() {
        panes.forEach { $0.refreshLocalization() }
    }

    private func transferFromDropShelf(urls: [URL], move: Bool) -> Bool {
        guard let panel = activePanel ?? activePane?.activePanel ?? panes.first?.activePanel,
              let destination = panel.physicalDropDestinationURL else {
            NSSound.beep()
            return false
        }
        let target = destination.standardizedFileURL
        let valid = urls.filter { raw in
            let src = raw.standardizedFileURL
            guard FileManager.default.fileExists(atPath: src.path) else { return false }
            if src.path == target.path || panel.isSameOrAncestor(src, of: target) {
                return false
            }
            if move && src.deletingLastPathComponent().path == target.path {
                return false
            }
            return true
        }
        guard !valid.isEmpty else {
            NSSound.beep()
            return false
        }
        panel.startTransfer(urls: valid, to: target, move: move)
        window?.makeKeyAndOrderFront(nil)
        return true
    }

    private func openFolderFromAnalyzer(_ url: URL) {
        let target = url.standardizedFileURL
        var isDir: ObjCBool = false
        let destination = (FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir) && isDir.boolValue)
            ? target
            : target.deletingLastPathComponent()
        let panel = activePanel ?? activePane?.activePanel ?? panes.first?.activePanel
        panel?.navigate(to: destination)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showAllTags(_ sender: Any?) {
        if tagManagerController == nil {
            let controller = TagManagerController()
            controller.onShowAll = { [weak self] in
                self?.activePanel?.showTaggedItems(tagKey: nil, title: "Все теги")
            }
            tagManagerController = controller
        }
        tagManagerController?.present()
    }

    @objc func closeTab(_ sender: Any?) {
        activePane?.closeActiveTab(sender)
    }

    var canReopenClosedTab: Bool {
        activePane?.canReopenClosedTab ?? false
    }

    @objc func reopenClosedTab(_ sender: Any?) {
        activePane?.reopenClosedTab(sender)
    }

    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        activePane?.selectTab(number: sender.tag)
    }

    @objc func splitPane(_ sender: Any?) {
        let url = activePanel?.currentURL ?? FileManager.default.homeDirectoryForCurrentUser
        addPane(with: url, after: activePane)
    }

    @objc func newFolder(_ sender: Any?) { activePanel?.newFolder(sender) }
    @objc func newTextFile(_ sender: Any?) { activePanel?.newTextFile(sender) }
    @objc func renameSelection(_ sender: Any?) { activePanel?.renameSelection(sender) }
    @objc func batchRenameSelection(_ sender: Any?) { activePanel?.batchRenameSelection(sender) }
    @objc func inspectSelection(_ sender: Any?) { activePanel?.showInspector(sender) }
    @objc func togglePreview(_ sender: Any?) { togglePreviewPanel(sender) }
    @objc func toggleViewMode(_ sender: Any?) { activePanel?.toggleViewModeFromCommand() }
    @objc func trashSelection(_ sender: Any?) { activePanel?.trashSelection(sender) }
    @objc func revealSelection(_ sender: Any?) { activePanel?.revealSelection(sender) }
    @objc func copyPaths(_ sender: Any?) { activePanel?.copySelectedPaths() }
    @objc func copyFiles(_ sender: Any?) { activePanel?.copyFiles(sender) }
    @objc func cutFiles(_ sender: Any?) { activePanel?.cutFiles(sender) }
    @objc func pasteFiles(_ sender: Any?) { activePanel?.pasteFiles(sender) }
    @objc func duplicateSelection(_ sender: Any?) { activePanel?.duplicateSelection(sender) }
    @objc func openInTerminal(_ sender: Any?) { activePanel?.openInTerminal(sender) }
    @objc func goBack(_ sender: Any?) { activePanel?.navigateHistoryWithWave(goesBack: true) }
    @objc func goForward(_ sender: Any?) { activePanel?.navigateHistoryWithWave(goesBack: false) }
    @objc func goUp(_ sender: Any?) { activePanel?.goUp(sender) }
    @objc func reload(_ sender: Any?) { activePanel?.reload(sender) }
    @objc func toggleHidden(_ sender: Any?) { activePanel?.toggleHidden(sender) }
    @objc func focusPath(_ sender: Any?) { activePanel?.focusPath() }
    @objc func focusSearch(_ sender: Any?) { (activePanel ?? activePane?.activePanel ?? panes.first?.activePanel)?.focusSearch() }
    @objc func quickLook(_ sender: Any?) { activePanel?.quickLookSelection(sender) }

    @objc func toggleAlwaysOnTop(_ sender: Any?) {
        setAlwaysOnTop(!isAlwaysOnTop)
    }

    func setAlwaysOnTop(_ enabled: Bool, notify: Bool = true) {
        isAlwaysOnTop = enabled
        window?.level = enabled ? .floating : .normal
        panes.forEach { $0.setAlwaysOnTop(enabled) }
        if notify { onSessionChanged?() }
    }
}

final class ExplorerWindowController: NSWindowController, NSWindowDelegate {
    let workspace: WorkspaceView
    var onSessionChanged: (() -> Void)? {
        didSet { workspace.onSessionChanged = onSessionChanged }
    }

    init(startURL: URL, session: FPWindowSession? = nil, quickLookHandler: @escaping (FPQuickLookRequest) -> Void) {
        workspace = WorkspaceView(
            startURL: startURL,
            restoredPanes: session?.panes,
            restoredActivePane: session?.activePaneIndex ?? 0,
            restoredPaneFractions: session?.paneFractions,
            quickLookHandler: quickLookHandler
        )
        // Сохранённое положение может указывать на экран, которого больше нет:
        // после отключения монитора или смены разрешения окно открывалось за
        // краем видимой области, и добраться до него было нельзя.
        let restoredFrame = session
            .map {
                NSRect(x: $0.frameX, y: $0.frameY, width: $0.frameWidth, height: $0.frameHeight)
            }
            .flatMap { frame -> NSRect? in
                let visibleSomewhere = NSScreen.screens.contains { screen in
                    let overlap = screen.visibleFrame.intersection(frame)
                    return overlap.width >= 160 && overlap.height >= 120
                }
                return visibleSomewhere ? frame : nil
            }
        let window = QyvroExplorerWindow(
            contentRect: restoredFrame ?? NSRect(x: 0, y: 0, width: 1220, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = appDisplayName
        window.minSize = NSSize(width: 680, height: 460)
        window.isOpaque = false
        window.backgroundColor = NSColor.clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Window dragging is handled explicitly by `FPWindowZoomSpacer` and
        // empty header space so tab drags in the top strip never hijack the window.
        window.isMovableByWindowBackground = false
        if #available(macOS 11.0, *) {
            window.toolbarStyle = .unifiedCompact
        }
        if restoredFrame == nil { window.center() }
        super.init(window: window)
        window.delegate = self
        window.contentView = workspace
        workspace.setAlwaysOnTop(session?.alwaysOnTop ?? false, notify: false)
    }

    var sessionState: FPWindowSession? {
        guard let window else { return nil }
        let frame = window.frame
        return FPWindowSession(
            panes: workspace.sessionPanes,
            activePaneIndex: workspace.activePaneSessionIndex,
            paneFractions: workspace.paneSessionFractions,
            alwaysOnTop: workspace.isAlwaysOnTop,
            frameX: frame.origin.x,
            frameY: frame.origin.y,
            frameWidth: frame.width,
            frameHeight: frame.height
        )
    }

    func windowDidMove(_ notification: Notification) { onSessionChanged?() }
    func windowDidResize(_ notification: Notification) { onSessionChanged?() }
    // The filesystem watcher remains active while a window is miniaturized or
    // on another Space, so restoring it must not rebuild the grid or its scroll.
    func windowDidDeminiaturize(_ notification: Notification) {}
    // Directory dispatch sources already report real filesystem changes.
    // In particular, closing QLPreviewPanel merely makes this window key again
    // and must not trigger a destructive grid reload.
    func windowDidBecomeKey(_ notification: Notification) {}
    func windowWillClose(_ notification: Notification) { onSessionChanged?() }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
