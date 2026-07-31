import Cocoa
import Quartz
final class TabChip: FPLayerView, NSDraggingSource {
    private static let tabPasteboardType = NSPasteboard.PasteboardType("com.qyvro.files.tab-index")
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let tabIndex: Int
    private var onSelect: (() -> Void)?
    private var onClose: (() -> Void)?
    private var onSpringOpen: (() -> Void)?
    private var onFilesDropped: (([URL]) -> Bool)?
    private var onReorder: ((Int, Int) -> Void)?
    private var springOpenWorkItem: DispatchWorkItem?
    private var hoverTrackingArea: NSTrackingArea?
    private var dragStartPoint: NSPoint?
    private var hasStartedTabDrag = false
    private let isActiveTab: Bool

    init(
        index: Int,
        title: String,
        tooltip: String,
        active: Bool,
        onSelect: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onSpringOpen: (() -> Void)?,
        onFilesDropped: (([URL]) -> Bool)?,
        onReorder: @escaping (Int, Int) -> Void
    ) {
        tabIndex = index
        self.onSelect = onSelect
        self.onClose = onClose
        self.onSpringOpen = onSpringOpen
        self.onFilesDropped = onFilesDropped
        self.onReorder = onReorder
        isActiveTab = active
        let cyber = FPStyle.isCyberEditorial
        super.init(
            color: active ? FPStyle.tab : FPStyle.tabInactive,
            cornerRadius: cyber ? 7 : 10,
            borderColor: active ? FPStyle.accent : FPStyle.stroke,
            borderWidth: active ? (cyber ? 1.25 : 1) : 0.5
        )
        layer?.shadowColor = (cyber ? FPStyle.accent : NSColor.black).cgColor
        layer?.shadowOpacity = active ? (cyber ? 0.18 : 0.22) : 0
        layer?.shadowRadius = cyber ? 12 : 8
        layer?.shadowOffset = NSSize(width: 0, height: -2)
        buildUI(title: title, tooltip: tooltip, active: active)
        registerForDraggedTypes([.fileURL, Self.tabPasteboardType])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        dragStartPoint = convert(event.locationInWindow, from: nil)
        hasStartedTabDrag = false
        onSelect?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard !hasStartedTabDrag, let dragStartPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - dragStartPoint.x, point.y - dragStartPoint.y) >= 5 else { return }
        hasStartedTabDrag = true

        let item = NSPasteboardItem()
        item.setString(String(tabIndex), forType: Self.tabPasteboardType)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        draggingItem.setDraggingFrame(bounds, contents: draggingSnapshot())
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        dragStartPoint = nil
        hasStartedTabDrag = false
        super.mouseUp(with: event)
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
        animateBackground(FPStyle.tab.withAlphaComponent(0.72))
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
        if let sourceString = sender.draggingPasteboard.string(forType: Self.tabPasteboardType),
           let sourceIndex = Int(sourceString) {
            cancelSpringOpen()
            onReorder?(sourceIndex, tabIndex)
            return sourceIndex != tabIndex
        }
        let urls = fileURLs(from: sender.draggingPasteboard)
        cancelSpringOpen()
        guard !urls.isEmpty else { return false }
        return onFilesDropped?(urls) ?? false
    }

    private func updateDragHover(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.availableType(from: [Self.tabPasteboardType]) != nil {
            cancelSpringOpen()
            layer?.borderColor = FPStyle.accent.cgColor
            layer?.borderWidth = 1.5
            return .move
        }
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

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .move
    }

    private func draggingSnapshot() -> NSImage {
        guard let representation = bitmapImageRepForCachingDisplay(in: bounds) else {
            return NSImage(size: bounds.size)
        }
        cacheDisplay(in: bounds, to: representation)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(representation)
        return image
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
        toolTip = tooltip
        // Tabs prefer the roomy Finder-like width, but may compress before the
        // root split view is allowed to eat into the sidebar. A required 176 pt
        // width on every new tab used to push the sidebar below its real
        // content width, clipping all labels against the left window edge.
        let preferredWidth = widthAnchor.constraint(equalToConstant: 176)
        preferredWidth.priority = .defaultHigh
        preferredWidth.isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        heightAnchor.constraint(equalToConstant: 32).isActive = true

        if #available(macOS 11.0, *) {
            iconView.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Folder")
        }
        iconView.contentTintColor = active ? FPStyle.orange : FPStyle.dimText
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleField.stringValue = title
        titleField.textColor = active ? FPStyle.text : FPStyle.dimText
        titleField.font = FPStyle.headingFont(
            ofSize: 12,
            weight: active && FPStyle.isCyberEditorial ? .bold : (active ? .semibold : .medium)
        )
        titleField.lineBreakMode = .byTruncatingMiddle
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
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 7),
            titleField.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -5),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
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

final class BrowserPane: NSView {
    weak var workspace: WorkspaceView?

    private let tabBar = NSStackView()
    private let contentView = NSView()
    private weak var tabControlsView: NSStackView?
    private weak var alwaysOnTopButton: NSButton?
    private var alwaysOnTopEnabled = false
    private var tabs: [FilePanel] = []
    private var activeIndex = 0

    var activePanel: FilePanel? {
        guard activeIndex >= 0 && activeIndex < tabs.count else { return nil }
        return tabs[activeIndex]
    }

    func refreshActivePanel(force: Bool = false) {
        activePanel?.refreshCurrentDirectory(force: force)
    }

    var sessionState: FPPaneSession {
        FPPaneSession(tabPaths: tabs.map { $0.currentURL.path }, activeIndex: activeIndex)
    }

    init(startURL: URL) {
        super.init(frame: .zero)
        buildUI()
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged(_:)), name: .fpThemeDidChange, object: nil)
        addTab(url: startURL, activate: true)
    }

    convenience init(session: FPPaneSession) {
        let manager = FileManager.default
        let restored = session.tabPaths
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            .filter { manager.fileExists(atPath: $0.path) }
        let urls = restored.isEmpty ? [manager.homeDirectoryForCurrentUser] : restored
        self.init(startURL: urls[0])
        for url in urls.dropFirst() {
            addTab(url: url, activate: false)
        }
        selectTab(at: min(max(session.activeIndex, 0), urls.count - 1))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setActive(_ active: Bool) {
        layer?.borderWidth = 0
        layer?.borderColor = nil
        layer?.backgroundColor = (active ? FPStyle.pane : FPStyle.paneInactive).cgColor
    }

    @objc private func themeChanged(_ notification: Notification) {
        layer?.backgroundColor = FPStyle.pane.cgColor
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        tabControlsView?.layer?.backgroundColor = FPStyle.tabBar.cgColor
        updateAlwaysOnTopButton()
        rebuildTabs()
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
        tabBar.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        tabBar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let addButton = iconButton(symbol: "plus", fallback: "+", tooltip: "Новая вкладка", action: #selector(newTab(_:)))
        let tabGroupsButton = iconButton(
            symbol: "rectangle.3.group",
            fallback: "▤",
            tooltip: "Сохранённые группы вкладок",
            action: #selector(showSavedTabGroups(_:))
        )
        let tabSpacer = FPWindowZoomSpacer()
        tabSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let commandPaletteButton = iconButton(
            symbol: "command",
            fallback: "⌘",
            tooltip: "Палитра команд (⌘K)",
            action: #selector(showCommandPalette(_:))
        )
        let clipboardButton = labeledIconButton(
            title: "Буфер",
            symbol: "clipboard",
            tooltip: "История буфера обмена (\(QyvroClipboardShortcut.displayName))",
            action: #selector(showClipboard(_:))
        )
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
        alwaysOnTopButton = pinButton
        let tabControls = NSStackView(
            views: [
                tabGroupsButton,
                tabBar,
                addButton,
                tabSpacer,
                previewButton,
                clipboardButton,
                pinButton,
                commandPaletteButton
            ]
        )
        tabControls.orientation = .horizontal
        tabControls.spacing = 8
        tabControls.alignment = .centerY
        tabControls.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        tabControls.translatesAutoresizingMaskIntoConstraints = false
        tabControls.wantsLayer = true
        tabControls.layer?.backgroundColor = FPStyle.tabBar.cgColor
        tabControls.layer?.borderColor = FPStyle.stroke.cgColor
        tabControls.layer?.borderWidth = 0.5
        tabControlsView = tabControls

        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor

        let root = NSStackView(views: [tabControls, contentView])
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
            tabControls.widthAnchor.constraint(equalTo: root.widthAnchor),
            contentView.widthAnchor.constraint(equalTo: root.widthAnchor),
            tabControls.heightAnchor.constraint(equalToConstant: 42),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 320)
        ])
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
        button.bezelStyle = .inline
        button.isBordered = false
        button.toolTip = tooltip
        button.contentTintColor = FPStyle.orange
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.wantsLayer = true
        button.layer?.cornerRadius = FPStyle.isCyberEditorial ? 5 : 9
        button.layer?.backgroundColor = FPStyle.control.cgColor
        button.layer?.borderColor = FPStyle.stroke.cgColor
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
        let button = FPToolbarButton(title: title, target: self, action: action)
        button.bezelStyle = .inline
        button.isBordered = false
        button.font = FPStyle.bodyFont(ofSize: 11.5, weight: .semibold)
        button.contentTintColor = FPStyle.orange
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
        button.layer?.borderColor = FPStyle.stroke.cgColor
        button.layer?.borderWidth = 0.5
        button.widthAnchor.constraint(equalToConstant: 80).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
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
        tabs.append(panel)
        if activate {
            activeIndex = tabs.count - 1
        }
        rebuildTabs()
        showActivePanel()
        workspace?.onSessionChanged?()
    }

    func addExistingTab(_ panel: FilePanel, activate: Bool) {
        configure(panel)
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
            self?.workspace?.onSessionChanged?()
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
            let tab = TabChip(
                index: index,
                title: panel.tabTitle,
                tooltip: panel.currentURL.path,
                active: index == activeIndex,
                onSelect: { [weak self] in self?.selectTab(at: index) },
                onClose: { [weak self] in self?.closeTab(at: index) },
                onSpringOpen: index != activeIndex && acceptsPhysicalDrop
                    ? { [weak self] in self?.selectTab(at: index, focusFiles: false) }
                    : nil,
                onFilesDropped: acceptsPhysicalDrop
                    ? { [weak panel] urls in panel?.moveDroppedItemsIntoCurrentFolder(urls) ?? false }
                    : nil,
                onReorder: { [weak self] source, destination in
                    self?.reorderTab(from: source, to: destination)
                }
            )
            tabBar.addArrangedSubview(tab)
        }
    }

    private func reorderTab(from sourceIndex: Int, to destinationIndex: Int) {
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
        activeIndex = index
        rebuildTabs()
        showActivePanel(focusFiles: focusFiles)
        workspace?.onSessionChanged?()
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

        if tabs.count == 1 {
            if workspace?.paneCount ?? 1 > 1 {
                workspace?.removePane(self)
            } else {
                window?.performClose(nil)
            }
            return
        }

        let removed = tabs.remove(at: index)
        removed.removeFromSuperview()
        activeIndex = min(activeIndex, tabs.count - 1)
        if index < activeIndex {
            activeIndex -= 1
        }
        rebuildTabs()
        showActivePanel()
        workspace?.onSessionChanged?()
    }

    @objc private func openTabInNewPane(_ sender: Any?) {
        let url = activePanel?.currentURL ?? FileManager.default.homeDirectoryForCurrentUser
        workspace?.addPane(with: url, after: self)
    }

    @objc private func closePane(_ sender: Any?) {
        workspace?.removePane(self)
    }

    @objc func showCommandPalette(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.showCommandPalette(sender)
    }

    @objc private func showClipboard(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.showClipboard(sender)
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
    private let splitView = NSSplitView()
    private var sidebarResizeMonitor: Any?
    private var isDraggingSidebarEdge = false
    private let previewSidebar = FilePreviewSidebar()
    private let backgroundGradientView = FPBackgroundGradientView()
    private let editorialBackdropView = FPEditorialBackdropView()
    private let sidebarStack = NSStackView()
    private let sidebarSearchContainer = NSView()
    private let sidebarSearchField = CenteredTextField()
    private let sidebarSearchIcon = NSImageView()
    private let sidebarSearchScopeButton = AnimatedSidebarButton()
    private var searchScope: SearchScope = .folder
    private var metadataQuery: NSMetadataQuery?
    private var metadataObservers: [NSObjectProtocol] = []
    private var globalSearchWorkItem: DispatchWorkItem?
    private var tagListScrollObserver: NSObjectProtocol?
    private var panes: [BrowserPane] = []
    private weak var activePane: BrowserPane?
    private weak var activePanel: FilePanel?
    private(set) var isAlwaysOnTop = false
    private var tagManagerController: TagManagerController?
    private let quickLookHandler: (FPQuickLookRequest) -> Void
    var onSessionChanged: (() -> Void)?

    var paneCount: Int {
        panes.count
    }

    var isPreviewPanelVisible: Bool {
        !previewSidebar.isHidden
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
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        globalSearchWorkItem?.cancel()
        metadataQuery?.stop()
        metadataObservers.forEach(NotificationCenter.default.removeObserver)
        if let tagListScrollObserver {
            NotificationCenter.default.removeObserver(tagListScrollObserver)
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

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(backgroundGradientView)
        addSubview(editorialBackdropView)
        addSubview(rootSplitView)
        rootSplitView.addArrangedSubview(sidebar)
        rootSplitView.addArrangedSubview(splitView)
        rootSplitView.addArrangedSubview(previewSidebar)
        // Preserve the native split-view resizing behavior used before the
        // editorial theme. The divider itself owns the drag interaction.
        // Обязательный приоритет удержания означал «эта панель не меняет
        // ширину никогда» — разделитель перетаскивался, но setPosition тут же
        // отменялся. Значение чуть выше приоритета содержимого сохраняет
        // ширину при изменении размера окна и при этом пускает ручку.
        rootSplitView.setHoldingPriority(
            NSLayoutConstraint.Priority(260),
            forSubviewAt: 0
        )
        rootSplitView.setHoldingPriority(
            NSLayoutConstraint.Priority(260),
            forSubviewAt: 2
        )
        previewSidebar.setContentHuggingPriority(.defaultLow, for: .horizontal)
        previewSidebar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rootSplitView.autosaveName = "FilePilotRootSplit"
        previewSidebar.onClose = { [weak self] in
            self?.setPreviewPanelVisible(false)
        }
        previewSidebar.isHidden = !UserDefaults.standard.bool(forKey: "PreviewSidebarVisible")

        // Самодельная накладка-ручка убрана: у сплит-вью уже есть родная зона
        // перетаскивания шириной 12 точек, которую задаёт делегат в
        // `additionalEffectiveRectOfDividerAt`. Накладка лежала поверх неё и
        // перехватывала нажатия, а сама их не получала — её `hitTest`
        // сравнивал точку в системе координат надвью со своими границами.
        // Ширина меняется через монитор событий: он не зависит ни от порядка
        // наложения видов, ни от систем координат в цепочке надвью.
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
            rootSplitView.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootSplitView.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootSplitView.topAnchor.constraint(equalTo: topAnchor),
            rootSplitView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

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
        DispatchQueue.main.async {
            self.rootSplitView.setPosition(244, ofDividerAt: 0)
            if !self.previewSidebar.isHidden {
                self.rootSplitView.setPosition(
                    max(500, self.rootSplitView.bounds.width - 310),
                    ofDividerAt: 1
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
            previewSidebar.update(items: activePanel?.selectedItems ?? [])
            rootSplitView.adjustSubviews()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.rootSplitView.setPosition(
                    max(500, self.rootSplitView.bounds.width - 310),
                    ofDividerAt: 1
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
        panes.append(pane)
        splitView.addArrangedSubview(pane)
        activePane = pane
    }

    @objc private func themeChanged(_ notification: Notification) {
        updateWindowBackdrop()
        updateBackgroundGradient()
        editorialBackdropView.refreshTheme()
        sidebarSearchIcon.contentTintColor = FPStyle.dimText
        sidebarSearchField.textColor = FPStyle.text
        sidebarSearchScopeButton.contentTintColor = FPStyle.orange
        sidebarSearchScopeButton.layer?.backgroundColor = FPStyle.controlStrong.cgColor
        rebuildSidebarContents()
        needsDisplay = true
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
                  let window = self.window,
                  event.window === window,
                  let sidebar = self.rootSplitView.arrangedSubviews.first else {
                return event
            }
            let point = self.rootSplitView.convert(event.locationInWindow, from: nil)
            switch event.type {
            case .leftMouseDown:
                guard abs(point.x - sidebar.frame.maxX) <= 8,
                      point.y >= self.rootSplitView.bounds.minY,
                      point.y <= self.rootSplitView.bounds.maxY else { return event }
                self.isDraggingSidebarEdge = true
                return nil
            case .leftMouseDragged:
                guard self.isDraggingSidebarEdge else { return event }
                self.rootSplitView.setPosition(
                    min(max(point.x, 200), 560),
                    ofDividerAt: 0
                )
                return nil
            default:
                guard self.isDraggingSidebarEdge else { return event }
                self.isDraggingSidebarEdge = false
                return nil
            }
        }
    }

    func splitView(
        _ splitView: NSSplitView,
        additionalEffectiveRectOfDividerAt dividerIndex: Int
    ) -> NSRect {
        guard splitView === rootSplitView,
              dividerIndex == 0,
              let sidebar = rootSplitView.arrangedSubviews.first else {
            return .zero
        }

        // Keep the native NSSplitView drag, but give its one-pixel divider a
        // forgiving hit target. The visual line stays thin; only the mouse
        // interaction area grows into both neighbouring panes.
        let hitWidth: CGFloat = 12
        return NSRect(
            x: sidebar.frame.maxX - hitWidth / 2,
            y: rootSplitView.bounds.minY,
            width: hitWidth,
            height: rootSplitView.bounds.height
        )
    }

    private func updateBackgroundGradient() {
        let opacity = min(max(FPStyle.pane.alphaComponent, 0), 1)
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
        splitView.adjustSubviews()
        splitView.needsLayout = true
        splitView.layoutSubtreeIfNeeded()
        let nextIndex = min(index, panes.count - 1)
        activePane = panes[nextIndex]
        if let panel = panes[nextIndex].activePanel {
            activate(panel: panel, in: panes[nextIndex])
        }
        shrinkWindowAfterRemovingPane(width: removedWidth)
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
        container.widthAnchor.constraint(greaterThanOrEqualToConstant: 244).isActive = true
        container.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true

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
        sidebarStack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        sidebarStack.translatesAutoresizingMaskIntoConstraints = false
        rebuildSidebarContents()

        container.addSubview(sidebarStack)
        NSLayoutConstraint.activate([
            sidebarStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            sidebarStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            sidebarStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 52),
            sidebarStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14)
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

        sidebarSearchScopeButton.title = "Папка"
        sidebarSearchScopeButton.font = .systemFont(ofSize: 10.5, weight: .semibold)
        sidebarSearchScopeButton.contentTintColor = FPStyle.orange
        sidebarSearchScopeButton.isBordered = false
        sidebarSearchScopeButton.bezelStyle = .inline
        sidebarSearchScopeButton.target = self
        sidebarSearchScopeButton.action = #selector(toggleSearchScope(_:))
        sidebarSearchScopeButton.toolTip = "Искать в текущей папке. Нажмите, чтобы искать на всём Mac"
        sidebarSearchScopeButton.wantsLayer = true
        sidebarSearchScopeButton.layer?.cornerRadius = 6
        sidebarSearchScopeButton.layer?.backgroundColor = FPStyle.controlStrong.cgColor
        sidebarSearchScopeButton.translatesAutoresizingMaskIntoConstraints = false

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
            appendFullWidth(locationButton(title: entry.title, symbol: entry.symbol, url: entry.url))
        }

        appendFullWidth(sectionHeader("Папки"))
        for entry in placeLocations() {
            appendFullWidth(locationButton(title: entry.title, symbol: entry.symbol, url: entry.url))
        }

        appendFullWidth(sectionHeader("Теги"))
        appendFullWidth(tagListScrollView())
        appendFullWidth(commandButton(title: "Все теги...", symbol: "tag", action: #selector(showAllTags(_:))))

        appendFullWidth(separator())
        appendFullWidth(commandButton(title: "Настройки", symbol: "slider.horizontal.3", action: #selector(openSettings(_:))))

        let spacer = NSView()
        appendFullWidth(spacer)
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
        if activePanel?.tabTitle == "Все теги" {
            activePanel?.showTaggedItems(tagKey: nil, title: "Все теги", addingToHistory: false)
        }
    }

    @objc private func sidebarSearchChanged(_ sender: NSTextField) {
        routeSearch(sender.stringValue)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSTextField === sidebarSearchField else { return }
        routeSearch(sidebarSearchField.stringValue)
    }

    func focusSidebarSearch() {
        window?.makeFirstResponder(sidebarSearchField)
        sidebarSearchField.currentEditor()?.selectAll(nil)
    }

    func syncSidebarSearchFromActivePanel() {
        if searchScope == .folder {
            sidebarSearchField.stringValue = activePanel?.searchQuery ?? ""
        }
    }

    @objc private func toggleSearchScope(_ sender: Any?) {
        searchScope = searchScope == .folder ? .mac : .folder
        let isMac = searchScope == .mac
        sidebarSearchScopeButton.title = isMac ? "Mac" : "Папка"
        sidebarSearchScopeButton.toolTip = isMac
            ? "Искать на всём Mac по имени и содержимому. Нажмите, чтобы искать только в текущей папке"
            : "Искать в текущей папке. Нажмите, чтобы искать на всём Mac"
        if !isMac {
            stopGlobalSearch()
            if let panel = activePanel {
                panel.navigate(to: panel.currentURL, addingToHistory: false)
                panel.setSearchQuery(sidebarSearchField.stringValue)
            }
        } else {
            activePanel?.setSearchQuery("")
            routeSearch(sidebarSearchField.stringValue)
        }
    }

    private func routeSearch(_ text: String) {
        let searchWasFocused = window?.firstResponder === sidebarSearchField.currentEditor()
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
        let urls = query.results.prefix(800).compactMap { result -> URL? in
            guard let item = result as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
            return URL(fileURLWithPath: path)
        }
        query.enableUpdates()
        activePanel?.showSearchResults(Array(urls), query: text)
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

    private func storageLocations() -> [(title: String, symbol: String, url: URL)] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey], options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.volumeNameKey])
            let title = values?.volumeName ?? url.lastPathComponent
            return title.isEmpty ? nil : (title, "internaldrive", url)
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

    private func locationButton(title: String, symbol: String, url: URL, removableBookmark: Bool = false) -> NSButton {
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
        button.title = title
        button.userInterfaceLayoutDirection = .leftToRight
        if #available(macOS 11.0, *), let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            image.size = NSSize(width: 16, height: 16)
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
        // Значок акцентным, подпись приглушённой: раньше и то и другое было
        // почти белым, панель выглядела плоско и слепила.
        button.contentTintColor = FPStyle.accent
        let font = FPStyle.bodyFont(
            ofSize: FPStyle.isCyberEditorial ? 12.5 : 13,
            weight: FPStyle.isCyberEditorial ? .semibold : .medium
        )
        button.font = font
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.baseWritingDirection = .leftToRight
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: font,
                .foregroundColor: FPStyle.text
                    .blended(withFraction: 0.34, of: FPStyle.dimText) ?? FPStyle.text,
                .paragraphStyle: paragraph,
                // Небольшая разрядка: с ней список читается спокойнее, чем
                // плотно набранным почти белым текстом.
                .kern: 0.25
            ]
        )
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.layer?.backgroundColor = NSColor.clear.cgColor
        button.layer?.borderColor = NSColor.clear.cgColor
        button.layer?.borderWidth = 0
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    private func sectionHeader(_ title: String) -> NSTextField {
        let field = NSTextField(
            labelWithString: FPStyle.isCyberEditorial ? title.uppercased() : title
        )
        field.font = FPStyle.headingFont(
            ofSize: FPStyle.isCyberEditorial ? 10 : 11,
            weight: FPStyle.isCyberEditorial ? .bold : .medium
        )
        field.textColor = FPStyle.dimText.withAlphaComponent(
            FPStyle.isCyberEditorial ? 0.72 : 0.62
        )
        // Заголовки разделов набраны в разрядку — так они читаются как
        // рубрики, а не как ещё одна строка списка.
        field.attributedStringValue = NSAttributedString(
            string: field.stringValue,
            attributes: [
                .font: field.font as Any,
                .foregroundColor: field.textColor as Any,
                .kern: 1.1
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
        let restoredFrame = session.map {
            NSRect(x: $0.frameX, y: $0.frameY, width: $0.frameWidth, height: $0.frameHeight)
        }
        let window = NSWindow(
            contentRect: restoredFrame ?? NSRect(x: 0, y: 0, width: 1220, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = appDisplayName
        window.minSize = NSSize(width: 820, height: 520)
        window.isOpaque = false
        window.backgroundColor = NSColor.clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]
        // Keep the controller's single explorer window reusable after the user
        // presses the red close button. Global ⌘E can then show this exact window
        // again instead of constructing a duplicate.
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
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
