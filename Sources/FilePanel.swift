import Cocoa
import Quartz
import QuickLookThumbnailing
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import AVFoundation
final class FilePanel: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSSearchFieldDelegate {
    private struct GridItemPosition {
        let sectionIndex: Int
        let position: Int
    }

    private struct GridSectionLayout {
        let id: String
        let title: String?
        let totalCount: Int
        let expanded: Bool
        let headerTop: CGFloat
        let headerHeight: CGFloat
        let itemsTop: CGFloat
        let displayedIndexes: [Int]
        let rowCount: Int
        let rowOffsets: [CGFloat]
        let rowHeights: [CGFloat]
        let itemsHeight: CGFloat
    }

    private struct GridLayout {
        let viewportWidth: CGFloat
        let itemSize: NSSize
        let inset: CGFloat
        let spacing: CGFloat
        let rowPitch: CGFloat
        let columns: Int
        let leadingInset: CGFloat
        let contentWidth: CGFloat
        let contentHeight: CGFloat
        let sections: [GridSectionLayout]
        let positions: [Int: GridItemPosition]
        let grouped: Bool
    }

    private struct GridScrollState {
        let topOffset: CGFloat
        let anchorPath: String?
        let anchorOffsetFromViewportTop: CGFloat
    }

    private struct FolderViewState {
        let gridScroll: GridScrollState?
        let tableOrigin: NSPoint
        let selectedPaths: Set<String>
        let selectionAnchorPath: String?
    }

    private struct HistoryEntry: Equatable {
        let url: URL
        let tagKey: String?
        let tagTitle: String?
    }

    private let pathField = CenteredTextField()
    private let breadcrumbPathView = FPBreadcrumbPathView()
    private let pathContainer = NSView()
    private let searchField = NSSearchField()
    private let tableView = PanelTableView()
    private let tableScrollView = NSScrollView()
    private let gridScrollView = FileGridScrollView()
    private let gridContentView = FileGridCanvasView()
    private let contentArea = NSView()
    private let gridSelectionMarquee = FileSelectionMarqueeView()
    private let footerLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(labelWithString: "")
    private let viewScaleRail = ViewScaleRail()
    private let viewModeToggleButton = NSButton()
    private let viewScaleButton = HoverButton()
    private let sortButton = SortPillButton()
    private let swipeIndicator = SwipeNavigationIndicator(frame: NSRect(x: 0, y: 0, width: 66, height: 68))
    private let swipeWaveOverlay = SwipeSurfaceWaveView()
    private let sortOptions: [(title: String, key: String)] = [
        ("Имя", "name"),
        ("Создан", "created"),
        ("Тип", "kind"),
        ("Дата изменения", "modified"),
        ("Размер", "size")
    ]
    private var modeButtons: [NSButton] = []
    private let fileManager = FileManager.default
    private let dateFormatter = DateFormatter()

    private var items: [FileItem] = []
    private var filteredItems: [FileItem] = []
    private var filteredIndexByPath: [String: Int] = [:]
    private var thumbnailCache: [String: NSImage] = [:]
    private var pendingThumbnailKeys = Set<String>()
    private var thumbnailOperations: [String: Operation] = [:]
    private var quickLookRequests: [String: QLThumbnailGenerator.Request] = [:]
    private var videoThumbnailGenerators: [String: AVAssetImageGenerator] = [:]
    private var gridScrollWorkItem: DispatchWorkItem?
    private var gridItemViews: [FileGridCellView] = []
    private var reusableGridItemViews: [FileGridCellView] = []
    private var gridSectionHeaderViews: [String: GridSectionHeaderView] = [:]
    private var gridSelectionIndexes = IndexSet()
    private var gridSelectionAnchor: Int?
    private var gridMarqueeBaseSelection = IndexSet()
    private var gridColumnCount = 1
    private var lastGridWidth: CGFloat = 0
    private var isRebuildingGrid = false
    private var resetGridScrollOnNextRebuild = false
    private var renderedGridIndexes: [Int]?
    private var renderedGridColumns = 0
    private var renderedGridIconSize: CGFloat = 0
    private var renderedGridItemCount = 0
    private var renderedGridViewportWidth: CGFloat = 0
    private var renderedGridContentHeight: CGFloat = 0
    private var cachedGridLayout: GridLayout?
    private var expandedGridSections = Set<String>()
    private var folderViewStates: [String: FolderViewState] = [:]
    private var pendingFolderViewState: FolderViewState?
    private var history: [HistoryEntry] = []
    private var historyIndex = -1
    private var isChangingHistory = false
    private var iconSize: CGFloat = 48
    private var viewMode: ExplorerViewMode = .list
    private var virtualTagKey: String?
    private var virtualTagTitle: String?
    private var virtualSearchTitle: String?
    private let horizontalSwipeTracker = HorizontalSwipeTracker()
    private var iconResizeWorkItem: DispatchWorkItem?
    private var gridResizeWorkItem: DispatchWorkItem?
    private var swipeVisualResetWorkItem: DispatchWorkItem?
    private var swipeEffectActive = false
    private var historyTransitionGeneration = 0
    private var activeHistoryTargetIndex: Int?
    private var gridAppearAnimationPending = false
    private var pendingSwipeDeltaX: CGFloat = 0
    private var pendingGridWidth: CGFloat = 0
    private var gridRelayoutScheduled = false
    private var viewScalePopover: NSPopover?
    private var viewScale: Double = 58
    private var gridDataRevision = 0
    private var cachedDateSections: (grouped: Bool, revision: Int, sections: [(id: String, title: String, indexes: [Int])])?
    private var cachedGridPositions: (grouped: Bool, revision: Int, positions: [Int: GridItemPosition])?
    private var loadGeneration = 0
    private var isShowingLightweightDirectoryItems = false
    private var activeDirectoryLoadURL: URL?
    private var pendingDirectoryRefreshURL: URL?
    private var directoryWatcher: DispatchSourceFileSystemObject?
    private var directoryWatchGeneration = 0
    private var directoryRefreshWorkItem: DispatchWorkItem?
    private var lastAutomaticRefresh = Date.distantPast
    private var inspectorController: FileInspectorController?
    private var folderPocketController: FolderPocketController?
    private var transferController: FileTransferController?
    private let cutPasteboardType = NSPasteboard.PasteboardType("com.qyvro.files.cut-files")
    private let directoryLoadQueue = DispatchQueue(label: "Qyvro.DirectoryLoad", qos: .utility)
    private let directoryWatchQueue = DispatchQueue(
        label: "Qyvro.DirectoryWatchOpen",
        qos: .utility,
        attributes: .concurrent
    )
    private let imageLoadQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Qyvro.ImageLoad"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 3
        return queue
    }()

    var currentURL: URL
    var showHiddenFiles: Bool
    var onActivated: ((FilePanel) -> Void)?
    var onURLChanged: ((FilePanel) -> Void)?
    var onOpenURLInNewTab: ((URL) -> Void)?
    var onOpenURLInNewPane: ((URL) -> Void)?
    var onQuickLook: ((FPQuickLookRequest) -> Void)?
    var onFocusSearch: (() -> Void)?
    var onSelectionChanged: (([FileItem]) -> Void)?

    var tabTitle: String {
        if let virtualSearchTitle {
            return virtualSearchTitle
        }
        if let virtualTagTitle {
            return virtualTagTitle
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if currentURL.path == home { return "Дом" }
        let name = currentURL.lastPathComponent
        return name.isEmpty ? "/" : name
    }

    var physicalDropDestinationURL: URL? {
        guard virtualTagTitle == nil, virtualSearchTitle == nil else { return nil }
        return currentURL.standardizedFileURL
    }

    var selectedItems: [FileItem] {
        let indexes = viewMode == .largeIcons ? gridSelectionIndexes : tableView.selectedRowIndexes
        return indexes.compactMap { index in
            guard index >= 0 && index < filteredItems.count else { return nil }
            return filteredItems[index]
        }
    }

    var searchQuery: String {
        searchField.stringValue
    }

    init(startURL: URL) {
        currentURL = startURL
        showHiddenFiles = UserDefaults.standard.bool(forKey: "ShowHiddenFiles")
        viewMode = .largeIcons
        UserDefaults.standard.set(ExplorerViewMode.largeIcons.rawValue, forKey: "ViewMode")
        let storedIconSize = UserDefaults.standard.double(forKey: "IconSize")
        iconSize = storedIconSize > 0 ? min(max(CGFloat(storedIconSize), 48), 144) : 88
        if UserDefaults.standard.object(forKey: "ViewScale") != nil {
            viewScale = min(max(UserDefaults.standard.double(forKey: "ViewScale"), 0), 100)
        } else {
            viewScale = 28 + Double((iconSize - 48) / 96) * 72
        }
        if viewScale <= 28 {
            viewMode = .list
            iconSize = CGFloat(16 + (viewScale / 28) * 16)
        } else {
            viewMode = .largeIcons
            iconSize = CGFloat(48 + ((viewScale - 28) / 72) * 96)
        }
        super.init(frame: .zero)
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        buildUI()
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged(_:)), name: .fpThemeDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(thumbnailCacheCleared(_:)), name: .fpThumbnailCacheDidClear, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(cutFileStateChanged(_:)), name: .fpCutFileStateDidChange, object: nil)
        navigate(to: startURL, addingToHistory: true)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        directoryRefreshWorkItem?.cancel()
        directoryWatcher?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override func mouseDown(with event: NSEvent) {
        activate()
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36:
            openSelection(nil)
        case 51:
            trashSelection(nil)
        case 49:
            quickLookSelection(nil)
        case 53:
            if folderPocketController?.isVisible == true {
                folderPocketController?.closePocket()
            } else {
                focusSearch()
            }
        case 17 where event.modifierFlags.contains(.command):
            openSelectionInNewTab(nil)
        case 8 where event.modifierFlags.contains(.command):
            copyFiles(nil)
        case 7 where event.modifierFlags.contains(.command):
            cutFiles(nil)
        case 9 where event.modifierFlags.contains(.command):
            pasteFiles(nil)
        case 0 where event.modifierFlags.contains(.command):
            if viewMode == .largeIcons {
                gridSelectionIndexes = IndexSet(integersIn: filteredItems.indices)
                updateGridSelection()
                footerLabel.stringValue = footerText()
                notifySelectionChanged()
            } else {
                tableView.selectAll(nil)
            }
        case 123 where !event.modifierFlags.contains(.command):
            moveGridSelection(by: -1)
        case 124 where !event.modifierFlags.contains(.command):
            moveGridSelection(by: 1)
        case 126 where !event.modifierFlags.contains(.command):
            moveGridSelection(by: -gridColumnCount)
        case 125 where !event.modifierFlags.contains(.command):
            moveGridSelection(by: gridColumnCount)
        case 123 where event.modifierFlags.contains(.command):
            navigateHistoryWithWave(goesBack: true)
        case 124 where event.modifierFlags.contains(.command):
            navigateHistoryWithWave(goesBack: false)
        case 126 where event.modifierFlags.contains(.command):
            goUp(nil)
        case 120:
            renameSelection(nil)
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
            began: { [weak self] in self?.beginHorizontalSwipe() },
            progress: { [weak self] deltaX, progress in self?.updateHorizontalSwipe(deltaX: deltaX, progress: progress) },
            completion: { [weak self] committed in self?.finishHorizontalSwipe(committed: committed) },
            action: { [weak self] deltaX in self?.handleHorizontalSwipe(deltaX: deltaX) }
        ) {
            return
        }
        super.scrollWheel(with: event)
    }

    override func layout() {
        super.layout()
        if !swipeIndicator.isHidden { positionSwipeIndicator() }
        folderPocketController?.reposition()
        let width = currentGridViewportWidth()
        if viewMode == .largeIcons, !isRebuildingGrid, abs(width - lastGridWidth) > 2 {
            pendingGridWidth = width
            if !gridRelayoutScheduled {
                gridRelayoutScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
                    guard let self else { return }
                    self.gridRelayoutScheduled = false
                    self.lightweightGridRelayout(width: self.pendingGridWidth)
                }
            }
            gridResizeWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.rebuildGridViews()
            }
            gridResizeWorkItem = work
            // Recycle/add cells only after the user has stopped resizing. Doing
            // a full rebuild every 35 ms fought the lightweight frame pass and
            // produced the visible jumping/glitching during live resize.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
        }
    }

    func setActive(_ active: Bool) {
        layer?.borderWidth = 0
        layer?.borderColor = nil
    }

    @objc private func themeChanged(_ notification: Notification) {
        layer?.backgroundColor = NSColor.clear.cgColor
        pathField.layer?.backgroundColor = FPStyle.field.cgColor
        pathField.textColor = FPStyle.orange
        pathField.font = FPStyle.isCyberEditorial
            ? FPStyle.bodyFont(ofSize: 13, weight: .semibold)
            : .monospacedSystemFont(ofSize: 13, weight: .medium)
        pathField.layer?.cornerRadius = FPStyle.isCyberEditorial ? 5 : 12
        breadcrumbPathView.refreshTheme()
        searchField.layer?.backgroundColor = FPStyle.field.cgColor
        searchField.font = FPStyle.bodyFont(ofSize: 12.5, weight: .medium)
        searchField.layer?.cornerRadius = FPStyle.isCyberEditorial ? 5 : 9
        tableView.backgroundColor = .clear
        tableScrollView.backgroundColor = .clear
        tableScrollView.layer?.backgroundColor = NSColor.clear.cgColor
        gridScrollView.backgroundColor = .clear
        gridScrollView.layer?.backgroundColor = NSColor.clear.cgColor
        gridContentView.layer?.backgroundColor = NSColor.clear.cgColor
        sortButton.needsDisplay = true
        viewScaleButton.contentTintColor = FPStyle.orange
        viewScaleButton.layer?.backgroundColor = FPStyle.controlStrong.cgColor
        viewScaleButton.layer?.borderColor = FPStyle.stroke.cgColor
        updateViewScaleButton()
        tableView.headerView?.needsDisplay = true
        tableView.reloadData()
        invalidateGridRenderCache()
        rebuildGridViews()
    }

    @objc private func thumbnailCacheCleared(_ notification: Notification) {
        thumbnailCache.removeAll()
        cancelThumbnailRequests(except: [])
        tableView.reloadData()
        invalidateGridRenderCache()
        rebuildGridViews()
    }

    @objc private func cutFileStateChanged(_ notification: Notification) {
        for cell in gridItemViews where filteredItems.indices.contains(cell.itemIndex) {
            cell.setCut(FPCutFileState.shared.contains(filteredItems[cell.itemIndex].url))
        }
        tableView.reloadData()
    }

    func activate() {
        onActivated?(self)
    }

    private func buildUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = 0
        layer?.borderWidth = 0
        translatesAutoresizingMaskIntoConstraints = false

        pathField.font = FPStyle.isCyberEditorial
            ? FPStyle.bodyFont(ofSize: 13, weight: .semibold)
            : .monospacedSystemFont(ofSize: 13, weight: .medium)
        pathField.placeholderString = "Путь"
        pathField.isEditable = true
        pathField.isSelectable = true
        pathField.cell?.usesSingleLineMode = true
        pathField.cell?.isScrollable = true
        pathField.delegate = self
        pathField.target = self
        pathField.action = #selector(pathSubmitted(_:))
        pathField.lineBreakMode = .byTruncatingMiddle
        pathField.isBordered = false
        pathField.isBezeled = false
        pathField.focusRingType = .none
        pathField.drawsBackground = false
        pathField.textColor = FPStyle.orange
        pathField.wantsLayer = true
        pathField.layer?.backgroundColor = FPStyle.field.cgColor
        pathField.layer?.cornerRadius = FPStyle.isCyberEditorial ? 5 : 12
        pathField.layer?.borderColor = FPStyle.stroke.cgColor
        pathField.layer?.borderWidth = 0.5
        pathField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        pathField.heightAnchor.constraint(equalToConstant: 32).isActive = true
        pathField.widthAnchor.constraint(greaterThanOrEqualToConstant: 112).isActive = true
        pathField.isHidden = true

        breadcrumbPathView.onNavigate = { [weak self] url in
            self?.navigate(to: url)
        }
        breadcrumbPathView.onRequestEditing = { [weak self] in
            self?.focusPath()
        }
        breadcrumbPathView.onMoveFiles = { [weak self] urls, target in
            self?.moveDroppedItems(urls, to: target) ?? false
        }
        pathContainer.translatesAutoresizingMaskIntoConstraints = false
        pathContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathContainer.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        pathContainer.addSubview(breadcrumbPathView)
        pathContainer.addSubview(pathField)
        breadcrumbPathView.translatesAutoresizingMaskIntoConstraints = false
        pathField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pathContainer.heightAnchor.constraint(equalToConstant: 32),
            pathContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 112),
            breadcrumbPathView.leadingAnchor.constraint(equalTo: pathContainer.leadingAnchor),
            breadcrumbPathView.trailingAnchor.constraint(equalTo: pathContainer.trailingAnchor),
            breadcrumbPathView.topAnchor.constraint(equalTo: pathContainer.topAnchor),
            breadcrumbPathView.bottomAnchor.constraint(equalTo: pathContainer.bottomAnchor),
            pathField.leadingAnchor.constraint(equalTo: pathContainer.leadingAnchor),
            pathField.trailingAnchor.constraint(equalTo: pathContainer.trailingAnchor),
            pathField.topAnchor.constraint(equalTo: pathContainer.topAnchor),
            pathField.bottomAnchor.constraint(equalTo: pathContainer.bottomAnchor)
        ])

        searchField.placeholderString = "Поиск"
        searchField.font = FPStyle.bodyFont(ofSize: 12.5, weight: .medium)
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(filterChanged(_:))
        searchField.delegate = self
        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.focusRingType = .none
        searchField.drawsBackground = false
        searchField.textColor = FPStyle.text
        searchField.wantsLayer = true
        searchField.layer?.backgroundColor = FPStyle.field.cgColor
        searchField.layer?.cornerRadius = FPStyle.isCyberEditorial ? 5 : 9
        searchField.layer?.borderColor = FPStyle.stroke.cgColor
        searchField.layer?.borderWidth = 0.5

        let historyBackButton = FPLongPressButton()
        historyBackButton.onLongPress = { [weak self] button in
            self?.showBackHistoryMenu(from: button)
        }
        let toolbar = NSStackView(views: [
            symbolButton(
                "chevron.left",
                fallback: "<",
                tooltip: "Назад · удерживайте для истории",
                action: #selector(goBack(_:)),
                button: historyBackButton
            ),
            symbolButton("chevron.right", fallback: ">", tooltip: "Вперёд", action: #selector(goForward(_:))),
            symbolButton("arrow.up", fallback: "Вверх", tooltip: "В родительскую папку", action: #selector(goUp(_:)))
        ])
        toolbar.orientation = .horizontal
        toolbar.spacing = 6
        toolbar.alignment = .centerY

        // Keep the path strip geometrically stable. NSStackView's gravity
        // distribution was shrinking the container to its text and moving it
        // across the row as the path length changed.
        let topRow = NSView()
        topRow.translatesAutoresizingMaskIntoConstraints = false
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.setContentHuggingPriority(.required, for: .horizontal)
        toolbar.setContentCompressionResistancePriority(.required, for: .horizontal)
        topRow.addSubview(toolbar)
        topRow.addSubview(pathContainer)
        NSLayoutConstraint.activate([
            topRow.heightAnchor.constraint(equalToConstant: 32),
            toolbar.leadingAnchor.constraint(equalTo: topRow.leadingAnchor),
            toolbar.centerYAnchor.constraint(equalTo: topRow.centerYAnchor),
            pathContainer.leadingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: 8),
            pathContainer.trailingAnchor.constraint(equalTo: topRow.trailingAnchor),
            pathContainer.topAnchor.constraint(equalTo: topRow.topAnchor),
            pathContainer.bottomAnchor.constraint(equalTo: topRow.bottomAnchor)
        ])

        buildTable()
        contentArea.translatesAutoresizingMaskIntoConstraints = false
        contentArea.wantsLayer = true
        contentArea.layer?.backgroundColor = NSColor.clear.cgColor
        contentArea.setContentHuggingPriority(.defaultLow, for: .horizontal)
        contentArea.setContentHuggingPriority(.defaultLow, for: .vertical)
        contentArea.addSubview(tableScrollView)
        contentArea.addSubview(gridScrollView)
        tableScrollView.translatesAutoresizingMaskIntoConstraints = false
        gridScrollView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            tableScrollView.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            tableScrollView.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            tableScrollView.topAnchor.constraint(equalTo: contentArea.topAnchor),
            tableScrollView.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
            gridScrollView.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            gridScrollView.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            gridScrollView.topAnchor.constraint(equalTo: contentArea.topAnchor),
            gridScrollView.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor)
        ])

        footerLabel.font = .systemFont(ofSize: 11)
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.lineBreakMode = .byTruncatingTail

        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.lineBreakMode = .byTruncatingTail

        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let sortControl = sortMenuControl()
        let sizeControl = iconSizeControl()
        let footerRow = NSStackView(views: [footerLabel, errorLabel, footerSpacer, sortControl, sizeControl])
        footerRow.orientation = .horizontal
        footerRow.spacing = 8
        footerRow.alignment = .centerY

        let content = NSStackView(views: [topRow, contentArea, footerRow])
        content.orientation = .vertical
        content.alignment = .width
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        addSubview(swipeIndicator)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            topRow.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -20),
            contentArea.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -20),
            footerRow.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -20),
            contentArea.heightAnchor.constraint(greaterThanOrEqualToConstant: 260)
        ])

        buildGrid()
        updateViewModeVisibility()
    }

    private func modeButtonStrip() -> NSView {
        let container = FPLayerView(color: FPStyle.control, cornerRadius: 10, borderColor: FPStyle.stroke, borderWidth: 0.5)
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        stack.translatesAutoresizingMaskIntoConstraints = false

        modeButtons = [
            modeButton(title: "Список", tag: ExplorerViewMode.list.rawValue),
            modeButton(title: "Мелко", tag: ExplorerViewMode.smallIcons.rawValue),
            modeButton(title: "Крупно", tag: ExplorerViewMode.largeIcons.rawValue)
        ]
        modeButtons.forEach { stack.addArrangedSubview($0) }
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 176),
            container.heightAnchor.constraint(equalToConstant: 32),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        updateModeButtons()
        return container
    }

    private func modeButton(title: String, tag: Int) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(viewModeChanged(_:)))
        button.tag = tag
        button.isBordered = false
        button.bezelStyle = .inline
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.widthAnchor.constraint(equalToConstant: 54).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    private func updateModeButtons() {
        for button in modeButtons {
            let active = button.tag == viewMode.rawValue
            button.layer?.backgroundColor = (active ? FPStyle.orangeFill : NSColor.clear).cgColor
            button.contentTintColor = active ? .white : FPStyle.dimText
        }
    }

    private func iconSizeControl() -> NSView {
        viewScaleButton.target = self
        viewScaleButton.action = #selector(showViewScalePopover(_:))
        viewScaleButton.onHover = { [weak self, weak viewScaleButton] in
            guard let self, let viewScaleButton, self.viewScalePopover?.isShown != true else { return }
            self.showViewScalePopover(viewScaleButton)
        }
        viewScaleButton.bezelStyle = .inline
        viewScaleButton.isBordered = false
        viewScaleButton.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        viewScaleButton.contentTintColor = FPStyle.orange
        viewScaleButton.imagePosition = .imageLeading
        viewScaleButton.wantsLayer = true
        viewScaleButton.layer?.cornerRadius = 7
        viewScaleButton.layer?.backgroundColor = FPStyle.controlStrong.cgColor
        viewScaleButton.layer?.borderColor = FPStyle.stroke.cgColor
        viewScaleButton.layer?.borderWidth = 0.5
        viewScaleButton.heightAnchor.constraint(equalToConstant: 26).isActive = true
        viewScaleButton.widthAnchor.constraint(equalToConstant: 102).isActive = true
        updateViewScaleButton()
        return viewScaleButton
    }

    private func viewModeToggle() -> NSButton {
        viewModeToggleButton.bezelStyle = .inline
        viewModeToggleButton.isBordered = false
        viewModeToggleButton.imagePosition = .imageOnly
        viewModeToggleButton.contentTintColor = FPStyle.orange
        viewModeToggleButton.target = self
        viewModeToggleButton.action = #selector(toggleViewMode(_:))
        viewModeToggleButton.translatesAutoresizingMaskIntoConstraints = false
        viewModeToggleButton.widthAnchor.constraint(equalToConstant: 22).isActive = true
        viewModeToggleButton.heightAnchor.constraint(equalToConstant: 22).isActive = true
        updateViewModeToggleButton()
        return viewModeToggleButton
    }

    private func updateViewModeToggleButton() {
        let symbol = viewMode == .largeIcons ? "list.bullet" : "square.grid.2x2"
        let tooltip = viewMode == .largeIcons ? "Показать списком" : "Показать плиткой"
        if #available(macOS 11.0, *) {
            viewModeToggleButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        } else {
            viewModeToggleButton.title = viewMode == .largeIcons ? "≡" : "▦"
        }
        viewModeToggleButton.toolTip = tooltip
    }

    private func sortMenuControl() -> NSView {
        sortButton.target = self
        sortButton.action = #selector(showSortMenu(_:))
        sortButton.sendAction(on: [.leftMouseDown])
        sortButton.toolTip = "Сортировка"
        sortButton.isBordered = false
        sortButton.isTransparent = false
        sortButton.bezelStyle = .inline
        sortButton.alignment = .left
        sortButton.contentTintColor = FPStyle.text
        sortButton.wantsLayer = false
        sortButton.translatesAutoresizingMaskIntoConstraints = false
        sortButton.widthAnchor.constraint(equalToConstant: 92).isActive = true
        sortButton.heightAnchor.constraint(equalToConstant: 26).isActive = true
        syncSortControl()
        return sortButton
    }

    private func sliderIcon(_ symbol: String) -> NSImageView {
        let imageView = NSImageView()
        if #available(macOS 11.0, *) {
            imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        imageView.contentTintColor = FPStyle.orange
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.widthAnchor.constraint(equalToConstant: 16).isActive = true
        imageView.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return imageView
    }

    private func buildTable() {
        tableView.filePanel = self
        tableView.delegate = self
        tableView.dataSource = self
        tableView.backgroundColor = .clear
        tableView.enclosingScrollView?.backgroundColor = .clear
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.setDraggingSourceOperationMask(.copy, forLocal: true)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.doubleAction = #selector(openSelection(_:))
        tableView.target = self
        tableView.rowHeight = 24
        tableView.headerView = NSTableHeaderView()
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        if #available(macOS 11.0, *) {
            tableView.style = .inset
        }

        addColumn(identifier: "name", title: "Имя", width: 280)
        addColumn(identifier: "size", title: "Размер", width: 90)
        addColumn(identifier: "created", title: "Создан", width: 165)
        addColumn(identifier: "modified", title: "Изменён", width: 165)
        addColumn(identifier: "kind", title: "Тип", width: 140)
        tableView.sortDescriptors = [NSSortDescriptor(key: "created", ascending: false)]
        updateTableRowHeight()

        FPConfigurePrimaryScroller(tableScrollView)
        tableScrollView.hasHorizontalScroller = true
        tableScrollView.documentView = tableView
        tableScrollView.borderType = .noBorder
        tableScrollView.drawsBackground = false
        tableScrollView.backgroundColor = .clear
        tableScrollView.wantsLayer = true
        tableScrollView.layer?.cornerRadius = 10
        tableScrollView.layer?.masksToBounds = true
    }

    private func buildGrid() {
        gridContentView.translatesAutoresizingMaskIntoConstraints = true
        gridContentView.wantsLayer = true
        gridContentView.layer?.backgroundColor = NSColor.clear.cgColor
        gridContentView.onMouseDownInGrid = { [weak self] point, event in
            self?.handleGridMouseDown(at: point, event: event)
        }
        gridContentView.onMenuInGrid = { [weak self] point in
            self?.handleGridMenu(at: point)
        }
        gridContentView.onHorizontalSwipe = { [weak self] deltaX in
            self?.handleHorizontalSwipe(deltaX: deltaX)
        }
        gridScrollView.onMouseDownInDocument = { [weak self] point, event in
            self?.handleGridMouseDown(at: point, event: event)
        }
        gridScrollView.onMenuInDocument = { [weak self] point in
            self?.handleGridMenu(at: point)
        }
        gridScrollView.onHorizontalSwipe = { [weak self] deltaX in
            self?.handleHorizontalSwipe(deltaX: deltaX)
        }
        gridScrollView.onHorizontalSwipeBegan = { [weak self] in
            self?.beginHorizontalSwipe()
        }
        gridScrollView.onHorizontalSwipeProgress = { [weak self] deltaX, progress in
            self?.updateHorizontalSwipe(deltaX: deltaX, progress: progress)
        }
        gridScrollView.onHorizontalSwipeCompletion = { [weak self] committed in
            self?.finishHorizontalSwipe(committed: committed)
        }
        gridScrollView.onDragFromDocument = { [weak self] point in
            self?.gridDragURLs(at: point) ?? []
        }
        gridScrollView.onDragImageFromDocument = { [weak self] point in
            self?.gridDragImage(at: point)
        }
        gridScrollView.onValidateDropInDocument = { [weak self] point, urls in
            self?.validateGridDrop(at: point, urls: urls) ?? []
        }
        gridScrollView.onDropInDocument = { [weak self] point, urls in
            self?.performGridDrop(at: point, urls: urls) ?? false
        }
        gridScrollView.onSelectionMarqueeBegan = { [weak self] point, event in
            self?.beginGridMarquee(at: point, event: event) ?? false
        }
        gridScrollView.onSelectionMarqueeChanged = { [weak self] rect in
            self?.updateGridMarquee(rect: rect)
        }
        gridScrollView.onSelectionMarqueeEnded = { [weak self] in
            self?.endGridMarquee()
        }
        gridScrollView.registerForDraggedTypes([.fileURL, .string])
        gridScrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(gridBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: gridScrollView.contentView
        )
        FPConfigurePrimaryScroller(gridScrollView)
        gridScrollView.hasHorizontalScroller = false
        gridScrollView.documentView = gridContentView
        gridScrollView.borderType = .noBorder
        gridScrollView.drawsBackground = false
        gridScrollView.backgroundColor = .clear
        gridScrollView.wantsLayer = true
        gridScrollView.layer?.cornerRadius = 12
        gridScrollView.layer?.masksToBounds = true
        gridScrollView.isHidden = true
    }

    private var gridItemSize: NSSize {
        let thumb = visibleIconSize
        let width = max(124, thumb + 26)
        let height = thumb + 60
        return NSSize(width: width, height: height)
    }

    private func currentGridViewportWidth() -> CGFloat {
        let contentWidth = gridScrollView.contentView.bounds.width
        if contentWidth > 1 {
            return contentWidth
        }
        return max(bounds.width - 20, 220)
    }

    private func lightweightGridRelayout(width: CGFloat) {
        guard viewMode == .largeIcons, width > 1 else { return }
        cachedGridLayout = nil
        let layout = makeGridLayout(viewportWidth: max(width, 220))
        lastGridWidth = width
        gridColumnCount = layout.columns
        gridContentView.frame = NSRect(x: 0, y: 0, width: layout.contentWidth, height: layout.contentHeight)
        updateGridSectionHeaders(layout: layout)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for cell in gridItemViews {
            let frame = gridFrame(for: cell.itemIndex, layout: layout)
            cell.isHidden = frame.width <= 1 || frame.height <= 1
            if !cell.isHidden {
                cell.frame = frame
            }
        }
        CATransaction.commit()
        renderedGridColumns = layout.columns
        renderedGridViewportWidth = width
        renderedGridContentHeight = layout.contentHeight
        synchronizeGridHoverWithPointer(animated: false)
    }

    private func rebuildGridViews() {
        guard !isRebuildingGrid else { return }
        isRebuildingGrid = true
        defer { isRebuildingGrid = false }

        // Флаг потребляется при первом непустом построении сетки, чтобы каскад
        // не «выстрелил» позже на обычной прокрутке или ресайзе. Пока папка ещё
        // грузится (пустая сетка), флаг ждёт появления контента.
        let animateAppear: Bool
        if viewMode == .largeIcons, filteredItems.isEmpty, gridAppearAnimationPending {
            animateAppear = false
        } else {
            animateAppear = gridAppearAnimationPending
            gridAppearAnimationPending = false
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard viewMode == .largeIcons else {
            clearGridViews()
            return
        }

        let viewportWidth = max(currentGridViewportWidth(), 220)
        let clipView = gridScrollView.contentView
        let previousContentHeight = max(gridContentView.frame.height, renderedGridContentHeight)
        let previousTopOffset = max(0, previousContentHeight - clipView.bounds.maxY)
        let layout = makeGridLayout(viewportWidth: viewportWidth)
        lastGridWidth = viewportWidth
        gridColumnCount = layout.columns
        gridContentView.frame = NSRect(x: 0, y: 0, width: layout.contentWidth, height: layout.contentHeight)
        updateGridSectionHeaders(layout: layout)

        if resetGridScrollOnNextRebuild {
            scrollGridToTop(contentHeight: layout.contentHeight)
            resetGridScrollOnNextRebuild = false
        } else if previousContentHeight > 1, abs(previousContentHeight - layout.contentHeight) > 0.5 {
            let y = max(0, layout.contentHeight - clipView.bounds.height - previousTopOffset)
            clipView.scroll(to: NSPoint(x: 0, y: y))
            gridScrollView.reflectScrolledClipView(clipView)
        }

        let visibleIndexes = visibleGridIndexes(layout: layout)
        guard !visibleIndexes.isEmpty else {
            cancelThumbnailRequests(except: [])
            clearGridViews()
            return
        }

        let visibleThumbnailKeys = Set(visibleIndexes.compactMap { index -> String? in
            guard index >= 0, index < filteredItems.count else { return nil }
            let item = filteredItems[index]
            return item.isDirectory ? nil : thumbnailKey(for: item, size: visibleIconSize)
        })
        cancelThumbnailRequests(except: visibleThumbnailKeys)

        let needsReconfigure =
            renderedGridIndexes == nil ||
            renderedGridItemCount != filteredItems.count ||
            abs(renderedGridIconSize - visibleIconSize) >= 0.5
        let canReuseVisibleCells = renderedGridIndexes == visibleIndexes && !needsReconfigure

        if canReuseVisibleCells {
            if renderedGridColumns != layout.columns
                || abs(renderedGridViewportWidth - viewportWidth) >= 0.5
                || abs(renderedGridContentHeight - layout.contentHeight) >= 0.5 {
                for cell in gridItemViews {
                    cell.isHidden = false
                    cell.frame = gridFrame(for: cell.itemIndex, layout: layout)
                }
            }
            renderedGridColumns = layout.columns
            renderedGridViewportWidth = viewportWidth
            renderedGridContentHeight = layout.contentHeight
            synchronizeGridHoverWithPointer(animated: false)
            return
        }

        let desiredIndexes = Set(visibleIndexes)
        var existingByIndex: [Int: FileGridCellView] = [:]
        for cell in gridItemViews {
            if desiredIndexes.contains(cell.itemIndex) {
                existingByIndex[cell.itemIndex] = cell
            } else {
                cell.removeFromSuperview()
                if reusableGridItemViews.count < 96 {
                    reusableGridItemViews.append(cell)
                }
            }
        }

        var nextVisibleCells: [FileGridCellView] = []
        nextVisibleCells.reserveCapacity(visibleIndexes.count)
        for index in visibleIndexes {
            let item = filteredItems[index]
            let cell = existingByIndex[index] ?? reusableGridItemViews.popLast() ?? makeGridCell()
            cell.isHidden = false
            cell.frame = gridFrame(for: index, layout: layout)
            cell.itemIndex = index
            if cell.superview == nil {
                gridContentView.addSubview(cell)
            }
            if needsReconfigure || existingByIndex[index] == nil {
                cell.configure(
                    item: item,
                    image: displayImage(for: item, size: visibleIconSize),
                    imageSize: visibleIconSize,
                    selected: gridSelectionIndexes.contains(index),
                    cut: FPCutFileState.shared.contains(item.url)
                )
            } else {
                cell.setSelected(gridSelectionIndexes.contains(index))
                cell.setCut(FPCutFileState.shared.contains(item.url), animated: false)
            }
            nextVisibleCells.append(cell)
        }
        gridItemViews = nextVisibleCells

        renderedGridIndexes = visibleIndexes
        renderedGridColumns = layout.columns
        renderedGridIconSize = visibleIconSize
        renderedGridItemCount = filteredItems.count
        renderedGridViewportWidth = viewportWidth
        renderedGridContentHeight = layout.contentHeight
        synchronizeGridHoverWithPointer(animated: false)

        if animateAppear, !swipeEffectActive,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            playGridAppearAnimation()
        }
    }

    // Каскадное появление ячеек при входе в папку: короткий fade + подъём,
    // только presentation-слой (модельные значения не трогаются, поэтому
    // переиспользование ячеек и снимки волны остаются корректными).
    private func playGridAppearAnimation() {
        let ordered = gridItemViews.sorted { left, right in
            if abs(left.frame.minY - right.frame.minY) > 0.5 {
                return left.frame.minY > right.frame.minY
            }
            return left.frame.minX < right.frame.minX
        }
        let now = CACurrentMediaTime()
        for (order, cell) in ordered.enumerated() {
            guard let cellLayer = cell.layer else { continue }
            cellLayer.removeAnimation(forKey: "qyvro.appear")
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            let rise = CABasicAnimation(keyPath: "transform.translation.y")
            rise.fromValue = -7
            rise.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [fade, rise]
            group.duration = 0.24
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.beginTime = now + Double(min(order, 26)) * 0.011
            group.fillMode = .backwards
            group.isRemovedOnCompletion = true
            cellLayer.add(group, forKey: "qyvro.appear")
        }
    }

    private func makeGridCell() -> FileGridCellView {
        let cell = FileGridCellView()
        cell.onSelect = { [weak self] selectedIndex, extending, selectingRange in
            self?.selectGridItem(at: selectedIndex, extending: extending, selectingRange: selectingRange)
        }
        cell.shouldPreserveSelectionForDrag = { [weak self] selectedIndex in
            guard let self else { return false }
            return self.gridSelectionIndexes.count > 1 && self.gridSelectionIndexes.contains(selectedIndex)
        }
        cell.onOpen = { [weak self] in
            self?.openSelection(nil)
        }
        cell.onMenu = { [weak self] in
            self?.contextMenu()
        }
        cell.onDrag = { [weak self] selectedIndex in
            guard let self else { return [] }
            if !self.gridSelectionIndexes.contains(selectedIndex) {
                self.selectGridItem(at: selectedIndex, extending: false)
            }
            return self.selectedItems.map(\.url)
        }
        cell.onToggleFlag = { [weak self] selectedIndex in
            self?.toggleFlag(at: selectedIndex)
        }
        return cell
    }

    /// Отметка щелчком по звёздочке в углу плитки — для случаев, когда
    /// открывать превью ради одного файла не хочется.
    private func toggleFlag(at index: Int) {
        guard filteredItems.indices.contains(index) else { return }
        let item = filteredItems[index]
        guard !item.isDirectory else { return }
        let flagged = FPFinderTagStore.isFlagged(item.finderTags ?? [])
        do {
            try FPFinderTagStore.setFlag(!flagged, on: item.url)
        } catch {
            showError("Не удалось изменить отметку: \(error.localizedDescription)")
            return
        }
        DirectorySnapshotCache.shared.invalidate(currentURL)
        loadCurrentDirectory(asynchronously: true, preservingGridPosition: true)
    }

    private func clearGridViews() {
        for view in gridItemViews {
            view.removeFromSuperview()
            if reusableGridItemViews.count < 96 {
                reusableGridItemViews.append(view)
            }
        }
        gridItemViews.removeAll()
        for header in gridSectionHeaderViews.values {
            header.removeFromSuperview()
        }
        gridSectionHeaderViews.removeAll()
        cancelThumbnailRequests(except: [])
        invalidateGridRenderCache()
    }

    private func invalidateGridRenderCache() {
        renderedGridIndexes = nil
        renderedGridColumns = 0
        renderedGridIconSize = 0
        renderedGridItemCount = 0
        renderedGridViewportWidth = 0
        renderedGridContentHeight = 0
        cachedGridLayout = nil
    }

    private func gridCellHeight(for _: Int, maxPreviewSide: CGFloat) -> CGFloat {
        // A thumbnail is asynchronous presentation data, not layout data.
        // Reserving the final height from the first placeholder frame prevents
        // rows, section headers and the current scroll position from moving as
        // previews arrive in batches.
        maxPreviewSide + 60
    }

    private func makeGridLayout(viewportWidth: CGFloat) -> GridLayout {
        let baseItemSize = gridItemSize
        if let cachedGridLayout,
           abs(cachedGridLayout.viewportWidth - viewportWidth) < 0.5,
           abs(cachedGridLayout.itemSize.height - baseItemSize.height) < 0.5 {
            return cachedGridLayout
        }

        let inset: CGFloat = 12
        let preferredColumnSpacing = FPStyle.gridSpacing
        let minimumColumnSpacing = min(preferredColumnSpacing, max(8, preferredColumnSpacing * 0.35))
        let rowSpacing = min(max(FPStyle.gridSpacing * 0.55, 8), 20)
        let available = max(viewportWidth - inset * 2, baseItemSize.width)
        let columns = max(1, Int((available + minimumColumnSpacing) / (baseItemSize.width + minimumColumnSpacing)))
        // Keep equal outer insets at every window width. The thumbnail itself
        // retains its aspect and size; only the cell slot absorbs the remainder.
        let columnSpacing: CGFloat
        let flexibleItemWidth: CGFloat
        if columns > 1 {
            let naturalSpacing = (available - CGFloat(columns) * baseItemSize.width) / CGFloat(columns - 1)
            columnSpacing = min(preferredColumnSpacing, max(minimumColumnSpacing, naturalSpacing))
            flexibleItemWidth = max(
                baseItemSize.width,
                (available - CGFloat(columns - 1) * columnSpacing) / CGFloat(columns)
            )
        } else {
            columnSpacing = 0
            flexibleItemWidth = baseItemSize.width
        }
        let itemSize = NSSize(width: flexibleItemWidth, height: baseItemSize.height)
        let rowPitch = itemSize.height + rowSpacing
        let spacing = columnSpacing
        let leadingInset = inset
        // The fast first-pass list intentionally has no dates yet. Do not
        // present that transient state as a real "Без даты" section; the
        // complete metadata pass will restore the normal date groups.
        let grouped = FPPreferences.groupLargeFoldersByDate
            && filteredItems.count >= 24
            && virtualTagTitle == nil
            && !isShowingLightweightDirectoryItems
        let sourceSections = makeDateGridSections(grouped: grouped)

        var sectionLayouts: [GridSectionLayout] = []
        let positions: [Int: GridItemPosition]
        if let cachedGridPositions,
           cachedGridPositions.grouped == grouped,
           cachedGridPositions.revision == gridDataRevision {
            positions = cachedGridPositions.positions
        } else {
            var built: [Int: GridItemPosition] = [:]
            built.reserveCapacity(filteredItems.count)
            for (sectionIndex, source) in sourceSections.enumerated() {
                for (position, itemIndex) in source.indexes.enumerated() {
                    built[itemIndex] = GridItemPosition(sectionIndex: sectionIndex, position: position)
                }
            }
            positions = built
            cachedGridPositions = (grouped, gridDataRevision, built)
        }
        var topOffset = inset
        for source in sourceSections {
            let isExpanded = expandedGridSections.contains(source.id)
            let displayed = grouped && !isExpanded
                ? Array(source.indexes.prefix(columns))
                : source.indexes
            let headerHeight: CGFloat = grouped ? 40 : 0
            let headerTop = topOffset
            let itemsTop = headerTop + headerHeight
            let rows = Int(ceil(Double(displayed.count) / Double(columns)))
            var rowOffsets: [CGFloat] = []
            var rowHeights: [CGFloat] = []
            var rowsHeight: CGFloat = 0
            if rows > 0 {
                rowOffsets.reserveCapacity(rows)
                rowHeights.reserveCapacity(rows)
                for row in 0..<rows {
                    let start = row * columns
                    let end = min(displayed.count, start + columns)
                    let height = displayed[start..<end]
                        .map { gridCellHeight(for: $0, maxPreviewSide: visibleIconSize) }
                        .max() ?? itemSize.height
                    rowOffsets.append(rowsHeight)
                    rowHeights.append(height)
                    rowsHeight += height
                    if row + 1 < rows {
                        rowsHeight += rowSpacing
                    }
                }
            }
            sectionLayouts.append(
                GridSectionLayout(
                    id: source.id,
                    title: grouped ? source.title : nil,
                    totalCount: source.indexes.count,
                    expanded: isExpanded,
                    headerTop: headerTop,
                    headerHeight: headerHeight,
                    itemsTop: itemsTop,
                    displayedIndexes: displayed,
                    rowCount: rows,
                    rowOffsets: rowOffsets,
                    rowHeights: rowHeights,
                    itemsHeight: rowsHeight
                )
            )
            topOffset = itemsTop + rowsHeight + (grouped ? 4 : 0)
        }

        let viewportHeight = max(gridScrollView.contentView.bounds.height, 1)
        let contentHeight = max(viewportHeight, topOffset + inset)

        let layout = GridLayout(
            viewportWidth: viewportWidth,
            itemSize: itemSize,
            inset: inset,
            spacing: spacing,
            rowPitch: rowPitch,
            columns: columns,
            leadingInset: leadingInset,
            contentWidth: viewportWidth,
            contentHeight: contentHeight,
            sections: sectionLayouts,
            positions: positions,
            grouped: grouped
        )
        cachedGridLayout = layout
        return layout
    }

    private func gridFrame(for index: Int, layout: GridLayout) -> NSRect {
        guard let position = layout.positions[index], position.sectionIndex < layout.sections.count else { return .zero }
        let section = layout.sections[position.sectionIndex]
        guard position.position < section.displayedIndexes.count,
              section.displayedIndexes[position.position] == index else { return .zero }
        let column = position.position % layout.columns
        let row = position.position / layout.columns
        guard row < section.rowOffsets.count, row < section.rowHeights.count else { return .zero }
        let x = layout.columns == 1
            ? max(layout.inset, (layout.viewportWidth - layout.itemSize.width) / 2)
            : layout.leadingInset + CGFloat(column) * (layout.itemSize.width + layout.spacing)
        let cellHeight = gridCellHeight(for: index, maxPreviewSide: visibleIconSize)
        // Align metadata baselines along the bottom of the row. Wide previews
        // therefore do not leave an invisible square-height tail underneath.
        let y = layout.contentHeight
            - section.itemsTop
            - section.rowOffsets[row]
            - section.rowHeights[row]
        return NSRect(x: x, y: y, width: layout.itemSize.width, height: cellHeight)
    }

    private func gridIndex(at point: NSPoint) -> Int? {
        let layout = makeGridLayout(viewportWidth: max(currentGridViewportWidth(), 220))
        let distanceFromTop = layout.contentHeight - point.y
        guard distanceFromTop >= 0 else { return nil }

        for section in layout.sections where section.rowCount > 0 {
            let itemsBottom = section.itemsTop + section.itemsHeight
            guard distanceFromTop >= section.itemsTop, distanceFromTop <= itemsBottom else { continue }
            let localY = distanceFromTop - section.itemsTop
            guard let row = section.rowOffsets.indices.first(where: {
                localY >= section.rowOffsets[$0]
                    && localY <= section.rowOffsets[$0] + section.rowHeights[$0]
            }) else { return nil }
            let xInGrid = point.x - layout.leadingInset
            guard xInGrid >= 0 else { return nil }
            let column = layout.columns == 1 ? 0 : Int(floor(xInGrid / (layout.itemSize.width + layout.spacing)))
            guard column >= 0, column < layout.columns else { return nil }
            let position = row * layout.columns + column
            guard position >= 0, position < section.displayedIndexes.count else { return nil }
            let index = section.displayedIndexes[position]
            return gridFrame(for: index, layout: layout).contains(point) ? index : nil
        }
        return nil
    }

    private func makeDateGridSections(grouped: Bool) -> [(id: String, title: String, indexes: [Int])] {
        if let cachedDateSections,
           cachedDateSections.grouped == grouped,
           cachedDateSections.revision == gridDataRevision {
            return cachedDateSections.sections
        }
        guard grouped else {
            let sections = [("all", "", Array(filteredItems.indices))]
            cachedDateSections = (grouped, gridDataRevision, sections)
            return sections
        }

        struct Bucket {
            var title: String
            var sortDate: Date
            var indexes: [Int]
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: today) ?? today
        let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: today) ?? today
        let monthFormatter = DateFormatter()
        monthFormatter.locale = Locale(identifier: "ru_RU")
        monthFormatter.dateFormat = "LLLL yyyy"

        var buckets: [String: Bucket] = [:]
        for (index, item) in filteredItems.enumerated() {
            let date = item.created ?? item.modified ?? Date.distantPast
            let day = calendar.startOfDay(for: date)
            let id: String
            let title: String
            let sortDate: Date
            if day >= today {
                id = "today"
                title = "Сегодня"
                sortDate = today
            } else if day >= yesterday {
                id = "yesterday"
                title = "Вчера"
                sortDate = yesterday
            } else if day >= sevenDaysAgo {
                id = "last7"
                title = "Предыдущие 7 дней"
                sortDate = sevenDaysAgo
            } else if day >= thirtyDaysAgo {
                id = "last30"
                title = "Предыдущие 30 дней"
                sortDate = thirtyDaysAgo
            } else if date == Date.distantPast {
                id = "undated"
                title = "Без даты"
                sortDate = Date.distantPast
            } else {
                let components = calendar.dateComponents([.year, .month], from: date)
                id = String(format: "month-%04d-%02d", components.year ?? 0, components.month ?? 0)
                title = monthFormatter.string(from: date).capitalized(with: Locale(identifier: "ru_RU"))
                sortDate = calendar.date(from: components) ?? date
            }

            if buckets[id] == nil {
                buckets[id] = Bucket(title: title, sortDate: sortDate, indexes: [])
            }
            buckets[id]?.indexes.append(index)
        }

        let sections = buckets
            .map { (id: $0.key, title: $0.value.title, sortDate: $0.value.sortDate, indexes: $0.value.indexes) }
            .sorted { $0.sortDate > $1.sortDate }
            .map { ($0.id, $0.title, $0.indexes) }
        cachedDateSections = (grouped, gridDataRevision, sections)
        return sections
    }

    private func handleGridMouseDown(at point: NSPoint, event: NSEvent) {
        guard viewMode == .largeIcons else { return }
        if let index = gridIndex(at: point) {
            selectGridItem(
                at: index,
                extending: event.modifierFlags.contains(.command),
                selectingRange: event.modifierFlags.contains(.shift)
            )
            if event.clickCount >= 2 {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.gridSelectionIndexes.contains(index) else { return }
                    self.openSelection(nil)
                }
            }
        } else if event.clickCount >= 2 {
            goBack(nil)
        } else if !event.modifierFlags.contains(.command) {
            activate()
            window?.makeFirstResponder(self)
            gridSelectionIndexes.removeAll()
            updateGridSelection()
            footerLabel.stringValue = footerText()
            notifySelectionChanged()
        }
    }

    private func beginGridMarquee(at point: NSPoint, event: NSEvent) -> Bool {
        guard viewMode == .largeIcons,
              event.clickCount < 2,
              gridIndex(at: point) == nil else { return false }
        activate()
        window?.makeFirstResponder(self)
        let keepsExistingSelection = event.modifierFlags.contains(.command)
        gridMarqueeBaseSelection = keepsExistingSelection ? gridSelectionIndexes : []
        if !keepsExistingSelection {
            gridSelectionIndexes.removeAll()
            gridSelectionAnchor = nil
            updateGridSelection()
            footerLabel.stringValue = footerText()
            notifySelectionChanged()
        }
        if gridSelectionMarquee.superview !== gridContentView {
            gridSelectionMarquee.removeFromSuperview()
            gridContentView.addSubview(gridSelectionMarquee, positioned: .above, relativeTo: nil)
        }
        gridSelectionMarquee.frame = NSRect(origin: point, size: .zero)
        gridSelectionMarquee.isHidden = true
        return true
    }

    private func updateGridMarquee(rect: NSRect) {
        guard viewMode == .largeIcons else { return }
        let normalized = rect.standardized
        gridSelectionMarquee.frame = normalized
        gridSelectionMarquee.isHidden = normalized.width < 2 && normalized.height < 2
        gridContentView.addSubview(gridSelectionMarquee, positioned: .above, relativeTo: nil)

        let layout = makeGridLayout(viewportWidth: max(currentGridViewportWidth(), 220))
        var indexes = gridMarqueeBaseSelection
        if normalized.width >= 1 || normalized.height >= 1 {
            for index in layout.positions.keys {
                let frame = gridFrame(for: index, layout: layout).insetBy(dx: 5, dy: 5)
                if frame.intersects(normalized) {
                    indexes.insert(index)
                }
            }
        }
        gridSelectionIndexes = indexes
        if let last = indexes.last {
            gridSelectionAnchor = last
        }
        updateGridSelection()
        footerLabel.stringValue = footerText()
        notifySelectionChanged()
    }

    private func endGridMarquee() {
        gridSelectionMarquee.isHidden = true
        gridSelectionMarquee.frame = .zero
        gridMarqueeBaseSelection.removeAll()
        footerLabel.stringValue = footerText()
        syncFolderPocketToSelection()
        notifySelectionChanged()
    }

    func handleHorizontalSwipe(deltaX: CGFloat, fallback: () -> Void = {}) {
        guard deltaX != 0 else {
            fallback()
            return
        }
        let shouldGoBack = FPPreferences.invertedSwipeNavigation ? deltaX > 0 : deltaX < 0
        if swipeEffectActive {
            guard appendParallelHistoryTransition(
                goesBack: shouldGoBack,
                deltaX: deltaX
            ) else { return }
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            return
        }
        guard canNavigateHistory(from: historyIndex, goesBack: shouldGoBack) else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        performAnimatedHistoryNavigation(goesBack: shouldGoBack, deltaX: deltaX)
    }

    func navigateHistoryWithWave(goesBack: Bool) {
        let deltaX: CGFloat
        if FPPreferences.invertedSwipeNavigation {
            deltaX = goesBack ? 1 : -1
        } else {
            deltaX = goesBack ? -1 : 1
        }
        handleHorizontalSwipe(deltaX: deltaX)
    }

    func beginHorizontalSwipe() {
        swipeVisualResetWorkItem?.cancel()
        swipeVisualResetWorkItem = nil
        pendingSwipeDeltaX = 0
    }

    private func installSwipeWaveOverlay() -> (host: NSView, rect: NSRect) {
        let host = self
        let contentFrame = convert(contentArea.bounds, from: contentArea)
        // Fill the complete working strip between the fixed toolbar and footer.
        // The actual file grid keeps its layout inset, but the visual wave is not
        // clipped to that inset, so no rectangular frame is visible around it.
        let lowerEdge = max(bounds.minY, contentFrame.minY - 8)
        let upperEdge = min(bounds.maxY, contentFrame.maxY + 8)
        let effectFrame = NSRect(
            x: bounds.minX,
            y: lowerEdge,
            width: bounds.width,
            height: max(upperEdge - lowerEdge, 2)
        ).integral
        if swipeWaveOverlay.superview !== host {
            swipeWaveOverlay.removeFromSuperview()
            swipeWaveOverlay.translatesAutoresizingMaskIntoConstraints = true
            swipeWaveOverlay.autoresizingMask = [.width]
            swipeWaveOverlay.frame = effectFrame
            host.addSubview(swipeWaveOverlay, positioned: .above, relativeTo: nil)
        } else {
            swipeWaveOverlay.frame = effectFrame
        }
        return (host, effectFrame)
    }

    func updateHorizontalSwipe(deltaX: CGFloat, progress: CGFloat) {
        let goesBack = FPPreferences.invertedSwipeNavigation ? deltaX > 0 : deltaX < 0
        let originIndex = activeHistoryTargetIndex
            ?? historyIndex
        let canNavigate = canNavigateHistory(from: originIndex, goesBack: goesBack)
        guard canNavigate else {
            pendingSwipeDeltaX = 0
            return
        }
        // The tracker commits as soon as the live gesture crosses its threshold;
        // this value is retained only for direction/progress bookkeeping.
        pendingSwipeDeltaX = deltaX
    }

    func finishHorizontalSwipe(committed: Bool) {
        swipeVisualResetWorkItem?.cancel()
        swipeVisualResetWorkItem = nil
        pendingSwipeDeltaX = 0
    }

    private func resetSwipeVisuals() {
        swipeVisualResetWorkItem = nil
        guard !swipeEffectActive else { return }
        pendingSwipeDeltaX = 0
    }

    private func scheduleSwipeVisualReset() {
        swipeVisualResetWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.resetSwipeVisuals() }
        swipeVisualResetWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.05, execute: work)
    }

    private func canNavigateHistory(from index: Int, goesBack: Bool) -> Bool {
        let target = index + (goesBack ? -1 : 1)
        return target >= 0 && target < history.count
    }

    @discardableResult
    private func appendParallelHistoryTransition(
        goesBack: Bool,
        deltaX: CGFloat
    ) -> Bool {
        guard swipeEffectActive else { return false }
        let originIndex = activeHistoryTargetIndex
            ?? historyIndex
        let targetIndex = originIndex + (goesBack ? -1 : 1)
        guard isValidHistoryTarget(at: targetIndex) else { return false }

        // Every physical gesture receives its own immutable clock. Starting a
        // later crest never changes the duration or progress of an older one.
        swipeWaveOverlay.appendParallelPulse(direction: deltaX)
        activeHistoryTargetIndex = targetIndex
        historyIndex = targetIndex
        loadActiveHistoryTarget(
            at: targetIndex,
            transitionGeneration: historyTransitionGeneration
        )
        return true
    }

    private func isValidHistoryTarget(at index: Int) -> Bool {
        guard index >= 0, index < history.count else { return false }
        let entry = history[index]
        if entry.tagTitle != nil {
            return true
        }
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: entry.url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func loadActiveHistoryTarget(
        at targetIndex: Int,
        transitionGeneration: Int
    ) {
        guard isValidHistoryTarget(at: targetIndex) else { return }
        let targetEntry = history[targetIndex]
        isChangingHistory = true
        applyHistoryEntry(targetEntry) { [weak self] in
            DispatchQueue.main.async {
                guard let self,
                      self.swipeEffectActive,
                      self.historyTransitionGeneration == transitionGeneration,
                      self.activeHistoryTargetIndex == targetIndex else { return }
                self.contentArea.layoutSubtreeIfNeeded()
                guard self.swipeWaveOverlay.captureDestination(from: self) else {
                    self.swipeWaveOverlay.cancelImmediately()
                    self.finishHistoryTransition(generation: transitionGeneration)
                    return
                }
            }
        }
        isChangingHistory = false
    }

    private func finishHistoryTransition(generation: Int) {
        guard historyTransitionGeneration == generation else { return }
        swipeEffectActive = false
        activeHistoryTargetIndex = nil
        imageLoadQueue.isSuspended = false
    }

    @discardableResult
    private func performAnimatedHistoryNavigation(goesBack: Bool, deltaX: CGFloat) -> Bool {
        guard !swipeEffectActive else { return false }
        let targetIndex = historyIndex + (goesBack ? -1 : 1)
        guard isValidHistoryTarget(at: targetIndex) else { return false }
        return startAnimatedHistoryTransition(
            targetIndex: targetIndex,
            deltaX: deltaX
        )
    }

    @discardableResult
    private func startAnimatedHistoryTransition(
        targetIndex: Int,
        deltaX: CGFloat
    ) -> Bool {
        guard !swipeEffectActive, isValidHistoryTarget(at: targetIndex) else { return false }
        historyTransitionGeneration += 1
        let generation = historyTransitionGeneration
        let transitionArea = installSwipeWaveOverlay()
        // Preview decoding is CPU/GPU heavy in large folders. Let the three
        // thumbnail workers finish their current image, but do not start more
        // work until the sub-second navigation transition is over.
        imageLoadQueue.isSuspended = true
        let prepared = swipeWaveOverlay.prepareTransition(
            capturing: transitionArea.host,
            rect: transitionArea.rect,
            hiding: [tableScrollView, gridScrollView],
            direction: deltaX
        )
        guard prepared else {
            isChangingHistory = true
            historyIndex = targetIndex
            applyHistoryEntry(history[targetIndex]) { [weak self] in
                DispatchQueue.main.async {
                    self?.imageLoadQueue.isSuspended = false
                }
            }
            isChangingHistory = false
            return true
        }

        swipeEffectActive = true
        activeHistoryTargetIndex = targetIndex
        historyIndex = targetIndex
        // The first crest starts immediately. Further physical gestures append
        // equally long crests to this same composition instead of accelerating
        // this one or waiting in a sequential queue.
        swipeWaveOverlay.play { [weak self] in
            self?.finishHistoryTransition(generation: generation)
        }
        loadActiveHistoryTarget(
            at: targetIndex,
            transitionGeneration: generation
        )
        return true
    }

    private func positionSwipeIndicator() {
        let travel = (1 - swipeIndicator.progress) * 15
        let x = swipeIndicator.goesBack
            ? -34 - travel
            : bounds.width - 32 + travel
        swipeIndicator.frame.origin = NSPoint(
            x: x,
            y: max(52, bounds.midY - swipeIndicator.frame.height / 2)
        )
    }

    private func handleGridMenu(at point: NSPoint) -> NSMenu {
        if let index = gridIndex(at: point), !gridSelectionIndexes.contains(index) {
            selectGridItem(at: index, extending: false)
        }
        return contextMenu()
    }

    private func gridDragURLs(at point: NSPoint) -> [URL] {
        guard viewMode == .largeIcons, let index = gridIndex(at: point) else { return [] }
        if !gridSelectionIndexes.contains(index) {
            selectGridItem(at: index, extending: false)
        }
        return selectedItems.map(\.url)
    }

    private func gridDragImage(at point: NSPoint) -> NSImage? {
        guard let index = gridIndex(at: point), index < filteredItems.count else { return nil }
        return displayImage(for: filteredItems[index], size: min(max(visibleIconSize, 48), 96))
    }

    private func validateGridDrop(at point: NSPoint, urls: [URL]) -> NSDragOperation {
        guard let target = gridDropTarget(at: point, urls: urls) else { return [] }
        return urls.contains { $0.standardizedFileURL.deletingLastPathComponent().path != target.path } ? .move : []
    }

    private func performGridDrop(at point: NSPoint, urls: [URL]) -> Bool {
        guard let target = gridDropTarget(at: point, urls: urls) else { return false }

        startTransfer(urls: urls, to: target, move: true)
        return true
    }

    @discardableResult
    func moveDroppedItemsIntoCurrentFolder(_ urls: [URL]) -> Bool {
        guard let target = physicalDropDestinationURL, !urls.isEmpty else { return false }
        return moveDroppedItems(urls, to: target)
    }

    @discardableResult
    func moveDroppedItems(_ urls: [URL], to destination: URL) -> Bool {
        let target = destination.standardizedFileURL
        guard !urls.isEmpty else { return false }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        let movable = urls.contains { source in
            let standardized = source.standardizedFileURL
            return standardized.deletingLastPathComponent().path != target.path
                && standardized.path != target.path
                && !isSameOrAncestor(standardized, of: target)
        }
        guard movable else { return false }
        startTransfer(urls: urls, to: target, move: true)
        return true
    }

    private func gridDropTarget(at point: NSPoint, urls: [URL]) -> URL? {
        guard !urls.isEmpty else { return nil }
        let target: URL
        if let index = gridIndex(at: point), index < filteredItems.count, filteredItems[index].isDirectory {
            target = filteredItems[index].url.standardizedFileURL
        } else {
            target = currentURL.standardizedFileURL
        }
        for source in urls {
            let sourceURL = source.standardizedFileURL
            if sourceURL.path == target.path || isSameOrAncestor(sourceURL, of: target) {
                return nil
            }
        }
        return target
    }

    private func isSameOrAncestor(_ possibleAncestor: URL, of descendant: URL) -> Bool {
        let ancestorPath = possibleAncestor.standardizedFileURL.path
        let descendantPath = descendant.standardizedFileURL.path
        return descendantPath == ancestorPath || descendantPath.hasPrefix(ancestorPath + "/")
    }

    private func uniqueDestination(for source: URL, in folder: URL) -> URL {
        var candidate = folder.appendingPathComponent(source.lastPathComponent)
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }

        let extensionPart = source.pathExtension
        let baseName = extensionPart.isEmpty
            ? source.lastPathComponent
            : source.deletingPathExtension().lastPathComponent

        var index = 2
        while true {
            let name = extensionPart.isEmpty ? "\(baseName) \(index)" : "\(baseName) \(index).\(extensionPart)"
            candidate = folder.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }

    private func visibleGridIndexes(layout: GridLayout) -> [Int] {
        guard !filteredItems.isEmpty else { return [] }
        let rawVisibleRect = gridScrollView.contentView.bounds
        let visibleHeight = min(layout.contentHeight, max(rawVisibleRect.height, 640))
        let visibleRect = rawVisibleRect.height > 1
            ? rawVisibleRect
            : NSRect(
                x: 0,
                y: max(0, layout.contentHeight - visibleHeight),
                width: layout.viewportWidth,
                height: visibleHeight
            )

        let buffer = layout.rowPitch * 1.5
        let visibleTop = max(0, layout.contentHeight - visibleRect.maxY - buffer)
        let visibleBottom = min(layout.contentHeight, layout.contentHeight - visibleRect.minY + buffer)
        var indexes: [Int] = []

        for section in layout.sections where section.rowCount > 0 {
            let sectionTop = section.itemsTop
            let sectionBottom = section.itemsTop + section.itemsHeight
            guard sectionBottom >= visibleTop, sectionTop <= visibleBottom else { continue }
            for row in section.rowOffsets.indices {
                let rowTop = section.itemsTop + section.rowOffsets[row]
                let rowBottom = rowTop + section.rowHeights[row]
                guard rowBottom >= visibleTop, rowTop <= visibleBottom else { continue }
                let start = row * layout.columns
                let end = min(section.displayedIndexes.count, start + layout.columns)
                if start < end {
                    indexes.append(contentsOf: section.displayedIndexes[start..<end])
                }
            }
        }
        return indexes
    }

    private func updateGridSectionHeaders(layout: GridLayout) {
        let visibleIDs = Set(layout.sections.compactMap { $0.title == nil ? nil : $0.id })
        let staleIDs = gridSectionHeaderViews.keys.filter { !visibleIDs.contains($0) }
        for id in staleIDs {
            gridSectionHeaderViews.removeValue(forKey: id)?.removeFromSuperview()
        }

        for section in layout.sections {
            guard let title = section.title else { continue }
            let header = gridSectionHeaderViews[section.id] ?? GridSectionHeaderView()
            if header.superview == nil {
                gridContentView.addSubview(header)
            }
            header.onToggle = { [weak self] id in
                self?.toggleGridSection(id)
            }
            header.configure(
                id: section.id,
                title: title,
                totalCount: section.totalCount,
                expanded: section.expanded,
                canToggle: section.totalCount > layout.columns
            )
            header.frame = NSRect(
                x: 0,
                y: layout.contentHeight - section.headerTop - section.headerHeight,
                width: layout.contentWidth,
                height: section.headerHeight
            )
            gridSectionHeaderViews[section.id] = header
        }
    }

    private func toggleGridSection(_ id: String) {
        if expandedGridSections.contains(id) {
            expandedGridSections.remove(id)
        } else {
            expandedGridSections.insert(id)
        }
        invalidateGridRenderCache()
        rebuildGridViews()
    }

    private func scrollGridToTop(contentHeight: CGFloat) {
        let clipView = gridScrollView.contentView
        let y = max(0, contentHeight - clipView.bounds.height)
        clipView.scroll(to: NSPoint(x: 0, y: y))
        gridScrollView.reflectScrolledClipView(clipView)
    }

    private func saveCurrentFolderViewState() {
        guard virtualTagTitle == nil, virtualSearchTitle == nil else { return }
        let key = currentURL.standardizedFileURL.path
        let anchorPath = gridSelectionAnchor.flatMap { index -> String? in
            guard filteredItems.indices.contains(index) else { return nil }
            return filteredItems[index].url.standardizedFileURL.path
        }
        folderViewStates[key] = FolderViewState(
            gridScroll: captureGridScrollState(),
            tableOrigin: tableScrollView.contentView.bounds.origin,
            selectedPaths: Set(selectedItems.map { $0.url.standardizedFileURL.path }),
            selectionAnchorPath: anchorPath
        )
        // Keep the in-memory navigation cache bounded even after a very long
        // session. The newest path is retained; older states can be recreated.
        if folderViewStates.count > 160, let staleKey = folderViewStates.keys.first(where: { $0 != key }) {
            folderViewStates.removeValue(forKey: staleKey)
        }
    }

    private func captureGridScrollState() -> GridScrollState? {
        guard viewMode == .largeIcons else { return nil }
        let clipView = gridScrollView.contentView
        guard clipView.bounds.height > 1, gridContentView.frame.height > 1 else { return nil }
        let layout = makeGridLayout(viewportWidth: max(currentGridViewportWidth(), 220))
        let viewportTop = clipView.bounds.maxY
        let topOffset = max(0, layout.contentHeight - viewportTop)
        let anchor = visibleGridIndexes(layout: layout)
            .compactMap { index -> (path: String, offset: CGFloat)? in
                guard filteredItems.indices.contains(index) else { return nil }
                let frame = gridFrame(for: index, layout: layout)
                guard frame.width > 1 else { return nil }
                return (filteredItems[index].url.standardizedFileURL.path, frame.maxY - viewportTop)
            }
            .min { abs($0.offset) < abs($1.offset) }
        return GridScrollState(
            topOffset: topOffset,
            anchorPath: anchor?.path,
            anchorOffsetFromViewportTop: anchor?.offset ?? 0
        )
    }

    private func restoreGridScrollState(_ state: GridScrollState) {
        guard viewMode == .largeIcons else { return }
        let clipView = gridScrollView.contentView
        let layout = makeGridLayout(viewportWidth: max(currentGridViewportWidth(), 220))
        let maximumY = max(0, layout.contentHeight - clipView.bounds.height)
        let targetY: CGFloat
        if let anchorPath = state.anchorPath,
           let index = filteredIndexByPath[anchorPath] {
            let frame = gridFrame(for: index, layout: layout)
            let desiredViewportTop = frame.maxY - state.anchorOffsetFromViewportTop
            targetY = min(max(desiredViewportTop - clipView.bounds.height, 0), maximumY)
        } else {
            targetY = min(max(layout.contentHeight - clipView.bounds.height - state.topOffset, 0), maximumY)
        }
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: targetY))
        gridScrollView.reflectScrolledClipView(clipView)
    }

    @objc private func gridBoundsChanged(_ notification: Notification) {
        guard viewMode == .largeIcons, !isRebuildingGrid else { return }
        // Moving the document under a stationary cursor does not reliably
        // generate `mouseExited` for AppKit tracking areas. Re-evaluate hover
        // from the real pointer on every bounds change so recycled cells cannot
        // leave grey "ghost" selections behind while scrolling.
        synchronizeGridHoverWithPointer(animated: false)
        // During live window resize `layout()` owns the geometry updates. A
        // second full rebuild from NSClipView bounds notifications was racing it
        // and recycling cells under the cursor, which looked like glitching.
        if inLiveResize {
            gridScrollWorkItem?.cancel()
            return
        }
        gridScrollWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.rebuildGridViews()
        }
        gridScrollWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.012, execute: workItem)
    }

    private func synchronizeGridHoverWithPointer(animated: Bool) {
        guard let window, viewMode == .largeIcons, !gridScrollView.isHidden else {
            gridItemViews.forEach { $0.setPointerHover(false, animated: animated) }
            return
        }
        let windowPoint = window.mouseLocationOutsideOfEventStream
        let clipPoint = gridScrollView.contentView.convert(windowPoint, from: nil)
        let pointerInsideViewport = gridScrollView.contentView.bounds.contains(clipPoint)
        let documentPoint = gridContentView.convert(windowPoint, from: nil)
        var matchedCell = false
        for cell in gridItemViews {
            let hovered = pointerInsideViewport
                && !matchedCell
                && !cell.isHidden
                && cell.frame.contains(documentPoint)
            cell.setPointerHover(hovered, animated: animated)
            if hovered {
                matchedCell = true
            }
        }
    }

    private func selectGridItem(at index: Int, extending: Bool, selectingRange: Bool = false) {
        guard index >= 0, index < filteredItems.count else { return }
        activate()
        window?.makeFirstResponder(self)
        // A plain press on any member of a multi-selection must keep the group
        // intact so the following drag moves every selected file together.
        if !extending, !selectingRange,
           gridSelectionIndexes.count > 1,
           gridSelectionIndexes.contains(index) {
            updateGridSelection()
            footerLabel.stringValue = footerText()
            return
        }
        if selectingRange, let anchor = gridSelectionAnchor {
            let layout = makeGridLayout(viewportWidth: max(currentGridViewportWidth(), 220))
            let visualOrder = layout.sections.flatMap(\.displayedIndexes)
            if let anchorPosition = visualOrder.firstIndex(of: anchor),
               let targetPosition = visualOrder.firstIndex(of: index) {
                let lower = min(anchorPosition, targetPosition)
                let upper = max(anchorPosition, targetPosition)
                let visualRange = IndexSet(visualOrder[lower...upper])
                if extending {
                    gridSelectionIndexes.formUnion(visualRange)
                } else {
                    gridSelectionIndexes = visualRange
                }
            } else {
                gridSelectionIndexes = IndexSet(integer: index)
                gridSelectionAnchor = index
            }
        } else if extending {
            if gridSelectionIndexes.contains(index) {
                gridSelectionIndexes.remove(index)
            } else {
                gridSelectionIndexes.insert(index)
            }
            gridSelectionAnchor = index
        } else {
            gridSelectionIndexes = IndexSet(integer: index)
            gridSelectionAnchor = index
        }
        updateGridSelection()
        footerLabel.stringValue = footerText()
        syncFolderPocketToSelection()
        notifySelectionChanged()
    }

    private func syncFolderPocketToSelection() {
        guard folderPocketController?.isVisible == true,
              selectedItems.count == 1,
              let folder = selectedItems.first,
              folder.isDirectory else { return }
        folderPocketController?.follow(folder: folder.url)
    }

    private func notifySelectionChanged() {
        onSelectionChanged?(selectedItems)
    }

    private func updateGridSelection() {
        for cell in gridItemViews {
            cell.setSelected(gridSelectionIndexes.contains(cell.itemIndex))
        }
    }

    private func scrollGridItemToVisible(_ index: Int) {
        let layout = makeGridLayout(viewportWidth: max(currentGridViewportWidth(), 220))
        guard index >= 0, index < filteredItems.count else { return }
        gridContentView.scrollToVisible(gridFrame(for: index, layout: layout).insetBy(dx: -12, dy: -12))
    }

    private func moveGridSelection(by delta: Int) {
        guard viewMode == .largeIcons, !filteredItems.isEmpty else { return }
        let current = gridSelectionIndexes.first ?? 0
        let next = min(max(current + delta, 0), filteredItems.count - 1)
        selectGridItem(at: next, extending: false)
        scrollGridItemToVisible(next)
    }

    private func addColumn(identifier: String, title: String, width: CGFloat) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.headerCell = FPTableHeaderCell(textCell: title)
        column.width = width
        column.minWidth = identifier == "name" ? 180 : 70
        column.sortDescriptorPrototype = NSSortDescriptor(key: identifier, ascending: true)
        tableView.addTableColumn(column)
    }

    private func symbolButton(
        _ symbol: String,
        fallback: String,
        tooltip: String,
        action: Selector,
        button: NSButton = NSButton()
    ) -> NSButton {
        if #available(macOS 11.0, *), let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) {
            image.size = NSSize(width: 16, height: 16)
            button.image = image
            button.title = ""
        } else {
            button.title = fallback
            button.font = .systemFont(ofSize: 11, weight: .medium)
        }
        button.bezelStyle = .inline
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = FPStyle.orange
        button.toolTip = tooltip
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.wantsLayer = true
        button.layer?.backgroundColor = FPStyle.controlStrong.cgColor
        button.layer?.cornerRadius = FPStyle.isCyberEditorial ? 5 : 9
        button.layer?.borderColor = FPStyle.stroke.cgColor
        button.layer?.borderWidth = 0.5
        button.widthAnchor.constraint(equalToConstant: 32).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }

    private var visibleIconSize: CGFloat {
        switch viewMode {
        case .list:
            return 18
        case .smallIcons:
            return min(max(iconSize, 24), 56)
        case .largeIcons:
            return min(max(iconSize, 56), 144)
        }
    }

    private func updateTableRowHeight() {
        switch viewMode {
        case .list:
            tableView.rowHeight = CGFloat(22 + (min(viewScale, 28) / 28) * 20)
        case .smallIcons:
            tableView.rowHeight = visibleIconSize + 10
        case .largeIcons:
            tableView.rowHeight = visibleIconSize + 14
        }
    }

    func navigate(to url: URL, addingToHistory: Bool = true, loadCompletion: (() -> Void)? = nil) {
        activate()
        folderPocketController?.closePocket()
        var resolved = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory) {
            showError("Путь не найден.")
            loadCompletion?()
            return
        }
        if !isDirectory.boolValue {
            resolved = resolved.deletingLastPathComponent()
        }

        let isSameDirectory = virtualTagTitle == nil
            && virtualSearchTitle == nil
            && currentURL.standardizedFileURL == resolved.standardizedFileURL

        if !isSameDirectory {
            saveCurrentFolderViewState()
            pendingFolderViewState = folderViewStates[resolved.standardizedFileURL.path]
        }
        virtualTagKey = nil
        virtualTagTitle = nil
        virtualSearchTitle = nil
        currentURL = resolved
        pathField.stringValue = resolved.path
        breadcrumbPathView.update(url: resolved)
        searchField.stringValue = ""
        showError("")

        recordHistoryIfNeeded(HistoryEntry(url: resolved, tagKey: nil, tagTitle: nil), adding: addingToHistory)

        // Каскадное появление ячеек — только при обычном переходе в другую
        // папку. Во время wave-перехода сеткой управляет оверлей волны, и
        // дополнительная анимация испортила бы его снимки.
        gridAppearAnimationPending = !isSameDirectory && !swipeEffectActive

        startWatchingCurrentDirectory()
        // `currentURL` is initialized with startURL before the first navigate.
        // Invalidating on that apparent same-directory navigation discarded a
        // perfectly valid persisted snapshot on every app launch. Preserve
        // scroll only when there is actually something on screen already.
        let shouldPreserveGrid = isSameDirectory && !items.isEmpty
        loadCurrentDirectory(
            asynchronously: true,
            preservingGridPosition: shouldPreserveGrid,
            completion: loadCompletion
        )
        onURLChanged?(self)
    }

    func showTaggedItems(tagKey: String?, title: String, addingToHistory: Bool = true) {
        activate()
        stopWatchingCurrentDirectory()
        virtualTagKey = tagKey
        virtualTagTitle = title
        pathField.stringValue = "Теги / \(title)"
        breadcrumbPathView.updateVirtualPath("Теги  ›  \(title)")
        searchField.stringValue = ""
        showError("")
        recordHistoryIfNeeded(HistoryEntry(url: currentURL, tagKey: tagKey, tagTitle: title), adding: addingToHistory)
        loadCurrentDirectory()
        onURLChanged?(self)
    }

    func showSearchResults(_ urls: [URL], query: String) {
        activate()
        stopWatchingCurrentDirectory()
        loadGeneration += 1
        virtualTagKey = nil
        virtualTagTitle = nil
        virtualSearchTitle = "Поиск: \(query)"
        pathField.stringValue = "Поиск на Mac / \(query)"
        breadcrumbPathView.updateVirtualPath("Поиск на Mac  ›  \(query)")
        searchField.stringValue = ""
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .fileSizeKey, .creationDateKey,
            .contentModificationDateKey, .localizedTypeDescriptionKey, .isHiddenKey,
            .tagNamesKey
        ]
        items = urls.prefix(800).compactMap { fileItem(for: $0, keys: keys, includeHidden: false) }
        sortItems()
        applyFilter()
        showError("")
        onURLChanged?(self)
    }

    private func recordHistoryIfNeeded(_ entry: HistoryEntry, adding: Bool) {
        guard adding, !isChangingHistory else { return }
        if historyIndex >= 0, historyIndex < history.count, history[historyIndex] == entry {
            return
        }
        if historyIndex + 1 < history.count {
            history.removeSubrange((historyIndex + 1)..<history.count)
        }
        history.append(entry)
        historyIndex = history.count - 1
    }

    private func applyHistoryEntry(_ entry: HistoryEntry, completion: (() -> Void)? = nil) {
        if let title = entry.tagTitle {
            currentURL = entry.url
            showTaggedItems(tagKey: entry.tagKey, title: title, addingToHistory: false)
            completion?()
        } else {
            navigate(to: entry.url, addingToHistory: false, loadCompletion: completion)
        }
    }

    func loadCurrentDirectory(
        asynchronously: Bool = false,
        preservingGridPosition: Bool = false,
        completion: (() -> Void)? = nil
    ) {
        loadGeneration += 1
        let generation = loadGeneration
        isShowingLightweightDirectoryItems = false
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey,
            .localizedTypeDescriptionKey,
            .isHiddenKey,
            .tagNamesKey
        ]

        if virtualSearchTitle != nil {
            completion?()
            return
        }
        if virtualTagTitle != nil {
            loadTaggedItems(keys: keys, preservingGridPosition: preservingGridPosition)
            completion?()
            return
        }

        if asynchronously {
            let url = currentURL
            let includeHidden = showHiddenFiles
            var displayedSnapshot = false
            if let cachedItems = DirectorySnapshotCache.shared.items(for: url, includeHidden: includeHidden) {
                items = cachedItems
                sortItems()
                applyFilter(preservingGridPosition: preservingGridPosition)
                showError("")
                // The snapshot is fresh and its saved directory modification
                // date still matches. The filesystem watcher will tell us
                // about later changes, so a second 3000-file metadata walk here
                // only caused the startup flash and unnecessary load.
                completion?()
                return
            } else if let staleItems = DirectorySnapshotCache.shared.staleItems(for: url, includeHidden: includeHidden) {
                items = staleItems
                sortItems()
                applyFilter(preservingGridPosition: preservingGridPosition)
                footerLabel.stringValue = footerText() + " - обновление..."
                displayedSnapshot = true
            } else if !preservingGridPosition {
                items = []
                filteredItems = []
                filteredIndexByPath = [:]
                tableView.reloadData()
                gridSelectionIndexes.removeAll()
                invalidateGridRenderCache()
                rebuildGridViews()
                footerLabel.stringValue = "Загрузка..."
            } else {
                footerLabel.stringValue = footerText() + " - обновление..."
            }
            showError("")
            activeDirectoryLoadURL = url.standardizedFileURL
            let completesFromSnapshot = displayedSnapshot
            // A lightweight list is useful only for the first presentation of
            // a new directory. During an in-place refresh the existing complete
            // grid must remain visible until the complete replacement is ready.
            let shouldPublishQuickList = !displayedSnapshot && !preservingGridPosition && items.isEmpty
            if completesFromSnapshot {
                completion?()
            }

            directoryLoadQueue.async { [weak self] in
                guard let self else { return }
                let result: Result<[FileItem], Error>
                var quickItems: [FileItem] = []
                var completedFromQuickList = false
                do {
                    let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
                    let urls = try self.fileManager.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: nil,
                        options: options
                    )
                    quickItems = urls.compactMap {
                        self.lightweightFileItem(for: $0, includeHidden: includeHidden)
                    }
                    completedFromQuickList = shouldPublishQuickList && !quickItems.isEmpty
                    if completedFromQuickList {
                        let initialItems = quickItems
                        DispatchQueue.main.async { [weak self] in
                            guard let self,
                                  self.loadGeneration == generation,
                                  self.currentURL == url,
                                  self.virtualTagTitle == nil else { return }
                            self.isShowingLightweightDirectoryItems = true
                            self.items = initialItems
                            self.sortItems()
                            self.applyFilter(preservingGridPosition: preservingGridPosition)
                            self.footerLabel.stringValue = self.footerText() + " - метаданные..."
                            self.showError("")
                            completion?()
                        }
                    }
                    // Metadata can be slow for thousands of files or cloud
                    // placeholders. Never drop a visible URL merely because one
                    // resourceValues call failed; keep its lightweight entry.
                    let loaded = urls.compactMap { candidate in
                        self.fileItem(for: candidate, keys: keys, includeHidden: includeHidden)
                            ?? self.lightweightFileItem(for: candidate, includeHidden: includeHidden)
                    }
                    result = .success(loaded)
                } catch {
                    result = .failure(error)
                }

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    defer { self.finishDirectoryLoad(for: url) }
                    guard self.loadGeneration == generation,
                          self.currentURL == url,
                          self.virtualTagTitle == nil else { return }
                    let hadInitialContent = displayedSnapshot || completedFromQuickList
                    switch result {
                    case .success(let loaded):
                        self.synchronizeFinderTagAssignments(from: loaded)
                        DirectorySnapshotCache.shared.store(loaded, for: url, includeHidden: includeHidden)
                        if displayedSnapshot, self.directoryItemsMatch(self.items, loaded) {
                            self.footerLabel.stringValue = self.footerText()
                            self.showError("")
                            if !hadInitialContent { completion?() }
                            return
                        }
                        self.isShowingLightweightDirectoryItems = false
                        self.items = loaded
                        self.sortItems()
                        self.applyFilter(
                            preservingGridPosition: preservingGridPosition
                                || displayedSnapshot
                                || completedFromQuickList
                        )
                        self.showError("")
                        if !hadInitialContent { completion?() }
                    case .failure(let error):
                        if hadInitialContent {
                            self.isShowingLightweightDirectoryItems = false
                            self.footerLabel.stringValue = self.footerText()
                            self.showError(error.localizedDescription)
                            return
                        }
                        self.isShowingLightweightDirectoryItems = false
                        self.items = []
                        self.filteredItems = []
                        self.filteredIndexByPath = [:]
                        self.tableView.reloadData()
                        self.rebuildGridViews()
                        self.footerLabel.stringValue = "0 элементов"
                        self.showError(error.localizedDescription)
                        completion?()
                    }
                }
            }
            return
        }

        do {
            let options: FileManager.DirectoryEnumerationOptions = showHiddenFiles ? [] : [.skipsHiddenFiles]
            let urls = try fileManager.contentsOfDirectory(at: currentURL, includingPropertiesForKeys: keys, options: options)
            items = urls.compactMap { fileItem(for: $0, keys: keys) }
            DirectorySnapshotCache.shared.store(items, for: currentURL, includeHidden: showHiddenFiles)
            sortItems()
            applyFilter(preservingGridPosition: preservingGridPosition)
            showError("")
            completion?()
        } catch {
            items = []
            filteredItems = []
            filteredIndexByPath = [:]
            tableView.reloadData()
            rebuildGridViews()
            footerLabel.stringValue = "0 элементов"
            showError(error.localizedDescription)
            completion?()
        }
    }

    func refreshCurrentDirectory(force: Bool = false) {
        guard virtualTagTitle == nil, virtualSearchTitle == nil else { return }
        let standardizedURL = currentURL.standardizedFileURL
        // Returning from Quick Look only makes the window key again; it does
        // not modify the directory. If the cache's directory timestamp and the
        // currently displayed items still match, do absolutely no UI work.
        if !force,
           let cached = DirectorySnapshotCache.shared.items(for: standardizedURL, includeHidden: showHiddenFiles),
           directoryItemsMatch(items, cached) {
            return
        }
        if activeDirectoryLoadURL == standardizedURL {
            pendingDirectoryRefreshURL = standardizedURL
            return
        }
        let now = Date()
        if !force, now.timeIntervalSince(lastAutomaticRefresh) < 0.65 { return }
        lastAutomaticRefresh = now
        DirectorySnapshotCache.shared.invalidate(currentURL)
        loadCurrentDirectory(asynchronously: true, preservingGridPosition: true)
    }

    private func finishDirectoryLoad(for url: URL) {
        let standardizedURL = url.standardizedFileURL
        if activeDirectoryLoadURL == standardizedURL {
            activeDirectoryLoadURL = nil
        }
        guard pendingDirectoryRefreshURL == standardizedURL else { return }
        pendingDirectoryRefreshURL = nil
        guard currentURL.standardizedFileURL == standardizedURL,
              virtualTagTitle == nil,
              virtualSearchTitle == nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.refreshCurrentDirectory(force: true)
        }
    }

    private func startWatchingCurrentDirectory() {
        stopWatchingCurrentDirectory()
        guard virtualTagTitle == nil, virtualSearchTitle == nil else { return }
        let watchedURL = currentURL.standardizedFileURL
        let generation = directoryWatchGeneration

        // `open()` may wait for a sleeping external/network volume. Never let
        // that hold the main thread during launch or tab restoration.
        directoryWatchQueue.async { [weak self] in
            let descriptor = Darwin.open(watchedURL.path, O_EVTONLY | O_NONBLOCK)
            guard descriptor >= 0 else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.directoryWatchGeneration == generation,
                      self.virtualTagTitle == nil,
                      self.virtualSearchTitle == nil,
                      self.currentURL.standardizedFileURL == watchedURL else {
                    Darwin.close(descriptor)
                    return
                }

                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: descriptor,
                    eventMask: [.write, .delete, .rename, .attrib, .extend, .link, .revoke],
                    queue: self.directoryLoadQueue
                )
                source.setEventHandler { [weak self] in
                    DispatchQueue.main.async {
                        self?.scheduleDirectoryRefresh(for: watchedURL)
                    }
                }
                source.setCancelHandler {
                    Darwin.close(descriptor)
                }
                self.directoryWatcher = source
                source.resume()
            }
        }
    }

    private func stopWatchingCurrentDirectory() {
        directoryWatchGeneration &+= 1
        directoryRefreshWorkItem?.cancel()
        directoryRefreshWorkItem = nil
        directoryWatcher?.cancel()
        directoryWatcher = nil
    }

    private func scheduleDirectoryRefresh(for watchedURL: URL) {
        guard virtualTagTitle == nil,
              virtualSearchTitle == nil,
              currentURL.standardizedFileURL == watchedURL else { return }
        directoryRefreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.currentURL.standardizedFileURL == watchedURL,
                  self.virtualTagTitle == nil,
                  self.virtualSearchTitle == nil else { return }
            self.refreshCurrentDirectory(force: true)
        }
        directoryRefreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24, execute: work)
    }

    private func loadTaggedItems(keys: [URLResourceKey], preservingGridPosition: Bool = false) {
        let map = folderColorMap()
        let paths = map.compactMap { path, colorKey -> String? in
            if let virtualTagKey {
                return colorKey == virtualTagKey ? path : nil
            }
            return FPTag.color(for: colorKey) == nil ? nil : path
        }

        items = paths
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .compactMap { path in
                let url = URL(fileURLWithPath: path)
                guard fileManager.fileExists(atPath: url.path) else { return nil }
                return fileItem(for: url, keys: keys)
            }

        sortItems()
        applyFilter(preservingGridPosition: preservingGridPosition)
        showError("")
    }

    private func fileItem(for url: URL, keys: [URLResourceKey], includeHidden: Bool? = nil) -> FileItem? {
        do {
            let values = try url.resourceValues(forKeys: Set(keys))
            let name = url.lastPathComponent
            let isHidden = values.isHidden ?? name.hasPrefix(".")
            if !(includeHidden ?? showHiddenFiles) && isHidden { return nil }
            let isDir = values.isDirectory ?? false
            let kind = localizedKind(for: url, isDirectory: isDir, fallback: values.localizedTypeDescription)
            return FileItem(
                url: url,
                name: name,
                isDirectory: isDir,
                size: isDir ? nil : Int64(values.fileSize ?? 0),
                created: values.creationDate,
                modified: values.contentModificationDate,
                kind: kind,
                isHidden: isHidden,
                finderTags: (values.tagNames ?? []).isEmpty
                    ? nil
                    : FPFinderTagStore.tags(for: url)
            )
        } catch {
            return nil
        }
    }

    private func lightweightFileItem(for url: URL, includeHidden: Bool) -> FileItem? {
        let name = url.lastPathComponent
        let isHidden = name.hasPrefix(".")
        if !includeHidden && isHidden { return nil }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        let folder = isDirectory.boolValue
        return FileItem(
            url: url,
            name: name,
            isDirectory: folder,
            size: nil,
            created: nil,
            modified: nil,
            kind: localizedKind(for: url, isDirectory: folder, fallback: nil),
            isHidden: isHidden,
            finderTags: nil
        )
    }

    private func synchronizeFinderTagAssignments(from loaded: [FileItem]) {
        var assignments = folderColorMap()
        var changed = false

        for item in loaded {
            let path = item.url.standardizedFileURL.path
            let finderTags = item.finderTags ?? []
            if let finderTag = FPFinderTagStore.preferredTag(for: item.url, among: finderTags) {
                let key = FPTagStore.shared.key(for: finderTag)
                if assignments[path] != key {
                    assignments[path] = key
                    changed = true
                }
            } else if FPFinderTagStore.hasManagedRecord(for: item.url) {
                FPFinderTagStore.reconcileMissingTags(for: item.url)
                if assignments.removeValue(forKey: path) != nil {
                    changed = true
                }
            }
        }

        if changed {
            UserDefaults.standard.set(assignments, forKey: "FolderColors")
        }
    }

    private func localizedKind(for url: URL, isDirectory: Bool, fallback: String?) -> String {
        if isDirectory { return "Папка" }

        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg":
            return "Изображение JPEG"
        case "png":
            return "Изображение PNG"
        case "heic", "heif":
            return "Изображение HEIC"
        case "gif":
            return "Изображение GIF"
        case "webp":
            return "Изображение WebP"
        case "pdf":
            return "PDF-документ"
        case "txt", "md", "rtf":
            return "Текстовый документ"
        case "mov", "mp4", "m4v", "avi", "mkv":
            return "Видео"
        case "mp3", "wav", "aiff", "m4a", "flac":
            return "Аудио"
        case "zip", "rar", "7z", "tar", "gz":
            return "Архив"
        case "app":
            return "Приложение"
        case "command", "sh", "zsh", "bash":
            return "Скрипт"
        case "alias":
            return "Ярлык"
        default:
            break
        }

        return fallback?.replacingOccurrences(of: "File", with: "Файл") ?? "Файл"
    }

    private func sortItems() {
        let descriptor = tableView.sortDescriptors.first ?? NSSortDescriptor(key: "created", ascending: false)
        let key = descriptor.key ?? "name"
        let ascending = descriptor.ascending

        items.sort { left, right in
            if (key == "name" || key == "kind"), left.isDirectory != right.isDirectory {
                return left.isDirectory && !right.isDirectory
            }

            let result: ComparisonResult
            switch key {
            case "size":
                result = compareNumbers(left.size ?? -1, right.size ?? -1)
            case "created":
                result = (left.created ?? Date.distantPast).compare(right.created ?? Date.distantPast)
            case "modified":
                result = (left.modified ?? Date.distantPast).compare(right.modified ?? Date.distantPast)
            case "kind":
                result = left.kind.localizedStandardCompare(right.kind)
            default:
                result = left.name.localizedStandardCompare(right.name)
            }

            if result == .orderedSame {
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private var currentSortKey: String {
        tableView.sortDescriptors.first?.key ?? "created"
    }

    private var currentSortAscending: Bool {
        tableView.sortDescriptors.first?.ascending ?? false
    }

    private func syncSortControl() {
        let key = currentSortKey
        let title = sortOptions.first(where: { $0.key == key })?.title ?? "Имя"
        sortButton.title = title
        sortButton.ascending = currentSortAscending
        sortButton.needsDisplay = true
    }

    @objc private func showSortMenu(_ sender: NSButton) {
        activate()
        let menu = NSMenu()
        for option in sortOptions {
            let item = NSMenuItem(title: option.title, action: #selector(sortMenuItemSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.key
            item.state = option.key == currentSortKey ? .on : .off
            item.attributedTitle = NSAttributedString(
                string: option.title,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                    .foregroundColor: FPStyle.orange
                ]
            )
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func sortMenuItemSelected(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        let ascending = key == currentSortKey ? !currentSortAscending : defaultAscending(for: key)
        applySort(key: key, ascending: ascending)
    }

    private func applySort(key: String, ascending: Bool) {
        activate()
        tableView.sortDescriptors = [NSSortDescriptor(key: key, ascending: ascending)]
        syncSortControl()
        sortItems()
        applyFilter()
    }

    private func defaultAscending(for key: String) -> Bool {
        switch key {
        case "created", "modified", "size":
            return false
        default:
            return true
        }
    }

    private func directoryItemsMatch(_ left: [FileItem], _ right: [FileItem]) -> Bool {
        guard left.count == right.count else { return false }
        let signatures = Dictionary(uniqueKeysWithValues: left.map {
            ($0.url.standardizedFileURL.path, ($0.modified?.timeIntervalSince1970 ?? 0, $0.size ?? -1, $0.isDirectory))
        })
        for item in right {
            guard let signature = signatures[item.url.standardizedFileURL.path],
                  signature.0 == (item.modified?.timeIntervalSince1970 ?? 0),
                  signature.1 == (item.size ?? -1),
                  signature.2 == item.isDirectory else { return false }
        }
        return true
    }

    private func compareNumbers(_ left: Int64, _ right: Int64) -> ComparisonResult {
        if left == right { return .orderedSame }
        return left < right ? .orderedAscending : .orderedDescending
    }

    private func applyFilter(preservingGridPosition: Bool = false) {
        let savedFolderState = preservingGridPosition ? nil : pendingFolderViewState
        let restoresSavedFolder = savedFolderState != nil
        let scrollState = preservingGridPosition ? captureGridScrollState() : savedFolderState?.gridScroll
        let selectedPaths: Set<String> = preservingGridPosition
            ? Set(selectedItems.map { $0.url.standardizedFileURL.path })
            : (savedFolderState?.selectedPaths ?? [])
        let anchorPath: String? = preservingGridPosition
            ? gridSelectionAnchor.flatMap { index in
                guard index >= 0, index < filteredItems.count else { return nil }
                return filteredItems[index].url.standardizedFileURL.path
            }
            : savedFolderState?.selectionAnchorPath
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            filteredItems = items
        } else {
            filteredItems = items.filter { item in
                item.name.localizedCaseInsensitiveContains(query) ||
                item.kind.localizedCaseInsensitiveContains(query)
            }
        }
        filteredIndexByPath = Dictionary(uniqueKeysWithValues: filteredItems.enumerated().map { ($0.element.url.path, $0.offset) })
        gridDataRevision += 1
        cachedDateSections = nil
        cachedGridPositions = nil
        tableView.reloadData()
        if preservingGridPosition || restoresSavedFolder {
            let restored = IndexSet(selectedPaths.compactMap { filteredIndexByPath[$0] })
            gridSelectionIndexes = restored
            gridSelectionAnchor = anchorPath.flatMap { filteredIndexByPath[$0] } ?? restored.first
            tableView.selectRowIndexes(restored, byExtendingSelection: false)
        } else {
            gridSelectionIndexes.removeAll()
            gridSelectionAnchor = nil
            tableView.deselectAll(nil)
        }
        resetGridScrollOnNextRebuild = !preservingGridPosition
            && (!restoresSavedFolder || (viewMode == .largeIcons && savedFolderState?.gridScroll == nil))
        invalidateGridRenderCache()
        rebuildGridViews()
        if let scrollState {
            restoreGridScrollState(scrollState)
        } else if let savedFolderState, viewMode != .largeIcons {
            tableScrollView.contentView.scroll(to: savedFolderState.tableOrigin)
            tableScrollView.reflectScrolledClipView(tableScrollView.contentView)
        }
        if restoresSavedFolder {
            pendingFolderViewState = nil
        }
        footerLabel.stringValue = footerText()
        notifySelectionChanged()
    }

    private func footerText() -> String {
        let selected = selectedItems.count
        let folders = filteredItems.filter { $0.isDirectory }.count
        let files = filteredItems.count - folders
        var text = "\(filteredItems.count) элементов - \(folders) папок - \(files) файлов"
        if selected > 0 {
            text += " - выбрано \(selected)"
        }
        // Счёт идёт по дате изменения файла: отметка ставится в момент
        // разбора, поэтому «отмечено сегодня» и «разобрано сегодня» — это про
        // одни и те же файлы. Считается по видимой папке, без обхода диска.
        let flaggedToday = filteredItems.filter { item in
            guard !item.isDirectory,
                  FPFinderTagStore.isFlagged(item.finderTags ?? []),
                  let modified = item.modified else { return false }
            return Calendar.current.isDateInToday(modified)
        }.count
        if flaggedToday > 0 {
            text += " - ★ сегодня: \(flaggedToday)"
        }
        return text
    }

    private func showError(_ message: String) {
        errorLabel.stringValue = message
    }

    private func updateViewModeVisibility() {
        updateTableRowHeight()
        tableView.reloadData()
        rebuildGridViews()
        tableScrollView.isHidden = viewMode == .largeIcons
        gridScrollView.isHidden = viewMode != .largeIcons
        updateModeButtons()
        updateViewModeToggleButton()
    }

    @objc func viewModeChanged(_ sender: NSButton) {
        activate()
        viewMode = ExplorerViewMode(rawValue: sender.tag) ?? .list
        UserDefaults.standard.set(viewMode.rawValue, forKey: "ViewMode")
        updateViewModeVisibility()
    }

    @objc private func toggleViewMode(_ sender: Any?) {
        activate()
        viewMode = viewMode == .largeIcons ? .list : .largeIcons
        UserDefaults.standard.set(viewMode.rawValue, forKey: "ViewMode")
        updateViewModeVisibility()
    }

    func toggleViewModeFromCommand() {
        applyViewScale(viewMode == .largeIcons ? 18 : 58, reload: true)
    }

    @objc func iconSizeChanged(_ sender: Any?) {
        viewScaleChanged(sender)
    }

    @objc private func showViewScalePopover(_ sender: NSButton) {
        if let popover = viewScalePopover, popover.isShown {
            popover.close()
            return
        }

        viewScaleRail.value = viewScale
        viewScaleRail.target = self
        viewScaleRail.action = #selector(viewScaleChanged(_:))
        viewScaleRail.toolTip = "Внизу — список, вверху — крупнее плитки"
        viewScaleRail.translatesAutoresizingMaskIntoConstraints = false

        func modeIcon(_ symbol: String, tooltip: String, size: CGFloat) -> NSImageView {
            let view = NSImageView()
            view.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
            view.contentTintColor = FPStyle.text
            view.imageScaling = .scaleProportionallyDown
            view.toolTip = tooltip
            view.widthAnchor.constraint(equalToConstant: 24).isActive = true
            view.heightAnchor.constraint(equalToConstant: size).isActive = true
            return view
        }

        let icons = NSStackView(views: [
            modeIcon("square.grid.2x2.fill", tooltip: "Крупные плитки", size: 24),
            NSView(),
            modeIcon("square.grid.3x3", tooltip: "Плитки", size: 20),
            NSView(),
            modeIcon("list.bullet", tooltip: "Список", size: 18)
        ])
        icons.orientation = .vertical
        icons.alignment = .centerX
        icons.distribution = .fill
        icons.translatesAutoresizingMaskIntoConstraints = false

        let body = NSStackView(views: [icons, viewScaleRail])
        body.orientation = .horizontal
        body.spacing = 5
        body.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 8)
        body.translatesAutoresizingMaskIntoConstraints = false

        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 86, height: 166))
        root.material = .menu
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 12
        root.layer?.masksToBounds = true
        root.layer?.borderColor = FPStyle.stroke.cgColor
        root.layer?.borderWidth = 0.5
        root.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            body.topAnchor.constraint(equalTo: root.topAnchor),
            body.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            viewScaleRail.widthAnchor.constraint(equalToConstant: 24),
            viewScaleRail.heightAnchor.constraint(equalToConstant: 146),
            icons.widthAnchor.constraint(equalToConstant: 28)
        ])

        let controller = NSViewController()
        controller.view = root
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = root.frame.size
        popover.contentViewController = controller
        viewScalePopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    @objc private func viewScaleChanged(_ sender: Any?) {
        applyViewScale(viewScaleRail.value, reload: true)
    }

    private func applyViewScale(_ newValue: Double, reload: Bool) {
        activate()
        let oldMode = viewMode
        viewScale = min(max(newValue, 0), 100)
        if viewScale <= 28 {
            viewMode = .list
            iconSize = CGFloat(16 + (viewScale / 28) * 16)
        } else {
            viewMode = .largeIcons
            iconSize = CGFloat(48 + ((viewScale - 28) / 72) * 96)
        }
        UserDefaults.standard.set(viewScale, forKey: "ViewScale")
        UserDefaults.standard.set(Double(iconSize), forKey: "IconSize")
        UserDefaults.standard.set(viewMode.rawValue, forKey: "ViewMode")
        updateViewScaleButton()
        guard reload else { return }
        if oldMode != viewMode {
            updateViewModeVisibility()
            return
        }
        iconResizeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.updateTableRowHeight()
            self.tableView.reloadData()
            self.invalidateGridRenderCache()
            self.rebuildGridViews()
        }
        iconResizeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.045, execute: workItem)
    }

    private func updateViewScaleButton() {
        let mode = viewScale <= 28 ? "Список" : "Плитки"
        viewScaleButton.title = "\(mode)  \(Int(viewScale))%"
        let symbol = viewScale <= 28 ? "list.bullet" : "square.grid.2x2"
        if #available(macOS 11.0, *) {
            viewScaleButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: mode)
        }
        viewScaleButton.toolTip = "Вид и размер: \(mode.lowercased()), \(Int(viewScale))%. Нажмите для настройки"
    }

    @objc func filterChanged(_ sender: Any?) {
        activate()
        applyFilter()
    }

    func focusPath() {
        activate()
        pathField.stringValue = virtualTagTitle == nil ? currentURL.path : pathField.stringValue
        breadcrumbPathView.isHidden = true
        pathField.isHidden = false
        window?.makeFirstResponder(pathField)
        pathField.currentEditor()?.selectAll(nil)
    }

    private func finishPathEditing() {
        pathField.isHidden = true
        breadcrumbPathView.isHidden = false
        if let virtualSearchTitle {
            breadcrumbPathView.updateVirtualPath(virtualSearchTitle)
        } else if let virtualTagTitle {
            breadcrumbPathView.updateVirtualPath("Теги  ›  \(virtualTagTitle)")
        } else {
            breadcrumbPathView.update(url: currentURL)
        }
    }

    func focusSearch() {
        activate()
        if let onFocusSearch {
            onFocusSearch()
        } else {
            window?.makeFirstResponder(searchField)
        }
    }

    func setSearchQuery(_ query: String) {
        if searchField.stringValue != query {
            searchField.stringValue = query
        }
        applyFilter()
    }

    @objc override func selectAll(_ sender: Any?) {
        if viewMode == .largeIcons {
            gridSelectionIndexes = IndexSet(integersIn: filteredItems.indices)
            updateGridSelection()
            footerLabel.stringValue = footerText()
            notifySelectionChanged()
        } else {
            tableView.selectAll(sender)
        }
    }

    func focusFiles() {
        activate()
        window?.makeFirstResponder(viewMode == .largeIcons ? self : tableView)
    }

    @objc func goBack(_ sender: Any?) {
        activate()
        guard historyIndex > 0 else { return }
        isChangingHistory = true
        historyIndex -= 1
        applyHistoryEntry(history[historyIndex])
        isChangingHistory = false
    }

    private func showBackHistoryMenu(from button: FPLongPressButton) {
        guard historyIndex > 0 else {
            NSSound.beep()
            return
        }
        let menu = NSMenu(title: "История")
        let lowerBound = max(0, historyIndex - 18)
        for index in stride(from: historyIndex - 1, through: lowerBound, by: -1) {
            let entry = history[index]
            let title: String
            if let tagTitle = entry.tagTitle {
                title = "Теги: \(tagTitle)"
            } else {
                let name = entry.url.lastPathComponent.isEmpty ? "/" : entry.url.lastPathComponent
                let parent = entry.url.deletingLastPathComponent().path
                    .replacingOccurrences(
                        of: FileManager.default.homeDirectoryForCurrentUser.path,
                        with: "~"
                    )
                title = "\(name)  —  \(parent)"
            }
            let item = NSMenuItem(
                title: title,
                action: #selector(openHistoryEntryFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = index
            item.image = NSImage(
                systemSymbolName: entry.tagTitle == nil ? "folder" : "tag",
                accessibilityDescription: nil
            )
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
    }

    @objc private func openHistoryEntryFromMenu(_ sender: NSMenuItem) {
        guard let targetIndex = sender.representedObject as? Int,
              isValidHistoryTarget(at: targetIndex),
              targetIndex != historyIndex else { return }
        guard !swipeEffectActive else {
            NSSound.beep()
            return
        }
        let goesBack = targetIndex < historyIndex
        let deltaX: CGFloat
        if FPPreferences.invertedSwipeNavigation {
            deltaX = goesBack ? 1 : -1
        } else {
            deltaX = goesBack ? -1 : 1
        }
        _ = startAnimatedHistoryTransition(
            targetIndex: targetIndex,
            deltaX: deltaX
        )
    }

    @objc func goForward(_ sender: Any?) {
        activate()
        guard historyIndex + 1 < history.count else { return }
        isChangingHistory = true
        historyIndex += 1
        applyHistoryEntry(history[historyIndex])
        isChangingHistory = false
    }

    @objc func goUp(_ sender: Any?) {
        activate()
        let parent = currentURL.deletingLastPathComponent()
        guard parent.path != currentURL.path else { return }
        navigate(to: parent)
    }

    @objc func reload(_ sender: Any?) {
        activate()
        loadCurrentDirectory()
    }

    @objc func toggleHidden(_ sender: Any?) {
        activate()
        showHiddenFiles.toggle()
        UserDefaults.standard.set(showHiddenFiles, forKey: "ShowHiddenFiles")
        loadCurrentDirectory()
    }

    @objc func openSelection(_ sender: Any?) {
        activate()
        guard let item = selectedItems.first else { return }
        if item.isDirectory {
            navigate(to: item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    @objc func openSelectionInNewTab(_ sender: Any?) {
        activate()
        let url = selectedItems.first.map { $0.isDirectory ? $0.url : $0.url.deletingLastPathComponent() } ?? currentURL
        onOpenURLInNewTab?(url)
    }

    @objc func openSelectionInNewPane(_ sender: Any?) {
        activate()
        let url = selectedItems.first.map { $0.isDirectory ? $0.url : $0.url.deletingLastPathComponent() } ?? currentURL
        onOpenURLInNewPane?(url)
    }

    @objc func quickLookSelection(_ sender: Any?) {
        activate()
        if let item = selectedItems.first, selectedItems.count == 1, item.isDirectory {
            if folderPocketController == nil {
                let controller = FolderPocketController(parentView: self)
                controller.onClose = { [weak self] in self?.window?.makeFirstResponder(self) }
                folderPocketController = controller
            }
            folderPocketController?.toggle(folder: item.url)
            return
        }
        guard let selected = selectedItems.first, !selected.isDirectory else {
            NSSound.beep()
            return
        }

        // Give Quick Look one stable gallery for the whole session instead of
        // rebuilding its data source for every arrow press. QLPreviewPanel then
        // keeps already visited previews alive, while the explicit thumbnail
        // warmer in AppDelegate makes neighbouring images appear immediately.
        let entries = filteredItems.enumerated().compactMap { index, item -> FPQuickLookGalleryEntry? in
            guard !item.isDirectory else { return nil }
            return FPQuickLookGalleryEntry(url: item.url, visualIndex: index)
        }
        guard let initialIndex = entries.firstIndex(where: {
            $0.url.standardizedFileURL == selected.url.standardizedFileURL
        }) else {
            return
        }
        let request = FPQuickLookRequest(
            entries: entries,
            initialIndex: initialIndex,
            columnCount: viewMode == .largeIcons ? max(1, gridColumnCount) : 1,
            onIndexChanged: { [weak self] url in
                self?.select(url: url)
            }
        )
        onQuickLook?(request)
    }

    @objc func revealSelection(_ sender: Any?) {
        activate()
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else {
            NSWorkspace.shared.activateFileViewerSelecting([currentURL])
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc func newFolder(_ sender: Any?) {
        activate()
        let destinationFolder: URL
        if virtualTagTitle != nil {
            guard virtualTagKey != nil else {
                NSSound.beep()
                showError("Для новой папки выбери конкретный цветовой тег")
                return
            }
            destinationFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
        } else {
            destinationFolder = currentURL
        }
        let name = uniqueFolderName(in: destinationFolder)
        let newURL = destinationFolder.appendingPathComponent(name, isDirectory: true)
        do {
            try fileManager.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: newURL, withIntermediateDirectories: false)
            if let tagKey = virtualTagKey,
               let tag = FPTag.all.first(where: { $0.key == tagKey }) {
                try FPFinderTagStore.setQyvroTag(tag, on: newURL)
                var assignments = folderColorMap()
                assignments[newURL.standardizedFileURL.path] = tagKey
                UserDefaults.standard.set(assignments, forKey: "FolderColors")
            }
            DirectorySnapshotCache.shared.invalidate(destinationFolder)
            loadCurrentDirectory()
            select(url: newURL)
            renameSelection(nil)
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func uniqueFolderName(in folder: URL) -> String {
        let base = "Новая папка"
        var candidate = base
        var index = 2
        while fileManager.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
            candidate = "\(base) \(index)"
            index += 1
        }
        return candidate
    }

    @objc func renameSelection(_ sender: Any?) {
        activate()
        guard selectedItems.count == 1, let item = selectedItems.first else { return }

        let alert = NSAlert()
        alert.messageText = "Переименовать"
        alert.informativeText = item.name
        alert.addButton(withTitle: "Переименовать")
        alert.addButton(withTitle: "Отмена")

        let field = NSTextField(string: item.name)
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        if alert.runModal() == .alertFirstButtonReturn {
            let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty, newName != item.name, !newName.contains("/") else { return }
            let destination = item.url.deletingLastPathComponent().appendingPathComponent(newName)
            do {
                try fileManager.moveItem(at: item.url, to: destination)
                var assignments = folderColorMap()
                if let tagKey = assignments.removeValue(forKey: item.url.standardizedFileURL.path) {
                    assignments[destination.standardizedFileURL.path] = tagKey
                    UserDefaults.standard.set(assignments, forKey: "FolderColors")
                }
                FPFinderTagStore.moveManagedRecord(from: item.url, to: destination)
                DirectorySnapshotCache.shared.invalidate(item.url.deletingLastPathComponent())
                QyvroFileOperationHistory.shared.recordRename([(item.url, destination)])
                loadCurrentDirectory()
                select(url: destination)
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    @objc func showInspector(_ sender: Any?) {
        activate()
        guard !selectedItems.isEmpty else { NSSound.beep(); return }
        if inspectorController == nil {
            inspectorController = FileInspectorController()
        }
        inspectorController?.show(items: selectedItems)
    }

    @objc private func showInspectorAndCalculateFolderSize(_ sender: Any?) {
        showInspector(sender)
        inspectorController?.calculateFolderSizes()
    }

    @objc func batchRenameSelection(_ sender: Any?) {
        activate()
        let targets = selectedItems.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard targets.count >= 2 else {
            NSSound.beep()
            showError("Для пакетного переименования выбери минимум два объекта")
            return
        }

        let alert = NSAlert()
        alert.messageText = "Пакетное переименование"
        alert.informativeText = "Доступны {name} — исходное имя и {n} — порядковый номер. Расширения файлов сохраняются."
        alert.addButton(withTitle: "Переименовать \(targets.count)")
        alert.addButton(withTitle: "Отмена")

        let templateField = NSTextField(string: "{name}-{n}")
        templateField.placeholderString = "Шаблон имени"
        let startField = NSTextField(string: "1")
        startField.placeholderString = "Первый номер"
        startField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let form = NSStackView(views: [
            settingsFormRow(title: "Шаблон", control: templateField),
            settingsFormRow(title: "Начать с", control: startField)
        ])
        form.orientation = .vertical
        form.alignment = .width
        form.spacing = 8
        form.frame = NSRect(x: 0, y: 0, width: 420, height: 68)
        alert.accessoryView = form
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let template = templateField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = Int(startField.stringValue) ?? 1
        guard !template.isEmpty, !template.contains("/") else {
            showError("Шаблон имени пустой или содержит /")
            return
        }

        var destinations: [(item: FileItem, url: URL)] = []
        var destinationPaths = Set<String>()
        let sourcePaths = Set(targets.map { $0.url.standardizedFileURL.path })
        for (offset, item) in targets.enumerated() {
            let base = item.isDirectory || item.url.pathExtension.isEmpty
                ? item.name
                : item.url.deletingPathExtension().lastPathComponent
            var newBase = template
                .replacingOccurrences(of: "{name}", with: base)
                .replacingOccurrences(of: "{n}", with: "\(start + offset)")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            newBase = newBase.replacingOccurrences(of: ":", with: "-")
            guard !newBase.isEmpty else { showError("Получилось пустое имя"); return }
            let newName = (!item.isDirectory && !item.url.pathExtension.isEmpty)
                ? "\(newBase).\(item.url.pathExtension)"
                : newBase
            let destination = item.url.deletingLastPathComponent().appendingPathComponent(newName)
            let destinationPath = destination.standardizedFileURL.path
            guard destinationPaths.insert(destinationPath).inserted else {
                showError("Шаблон создаёт одинаковые имена")
                return
            }
            if fileManager.fileExists(atPath: destinationPath), !sourcePaths.contains(destinationPath) {
                showError("Уже существует: \(newName)")
                return
            }
            destinations.append((item, destination))
        }

        var staged: [(temporary: URL, destination: URL, original: URL)] = []
        do {
            for pair in destinations {
                let temporary = pair.item.url.deletingLastPathComponent()
                    .appendingPathComponent(".astra-rename-\(UUID().uuidString)")
                try fileManager.moveItem(at: pair.item.url, to: temporary)
                staged.append((temporary, pair.url, pair.item.url))
            }
            for pair in staged {
                try fileManager.moveItem(at: pair.temporary, to: pair.destination)
            }
            QyvroFileOperationHistory.shared.recordRename(
                staged.map { (original: $0.original, renamed: $0.destination) }
            )
            DirectorySnapshotCache.shared.invalidate(currentURL)
            loadCurrentDirectory(asynchronously: true)
        } catch {
            for pair in staged where fileManager.fileExists(atPath: pair.temporary.path) {
                try? fileManager.moveItem(at: pair.temporary, to: pair.original)
            }
            showError("Переименование остановлено: \(error.localizedDescription)")
        }
    }

    private func settingsFormRow(title: String, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = FPStyle.dimText
        label.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        return row
    }

    @objc func trashSelection(_ sender: Any?) {
        activate()
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = urls.count == 1 ? "Переместить объект в корзину?" : "Переместить \(urls.count) объектов в корзину?"
        alert.informativeText = "Будет использована системная корзина macOS. Безвозвратно ничего не удаляется."
        alert.addButton(withTitle: "В корзину")
        alert.addButton(withTitle: "Отмена")
        alert.alertStyle = .warning

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var errors: [String] = []
        var trashedRecords: [QyvroTrashRecord] = []
        for url in urls {
            do {
                var resultingURL: NSURL?
                try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
                if let trashURL = resultingURL as URL? {
                    trashedRecords.append(.init(original: url, trashURL: trashURL))
                }
            } catch {
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        QyvroFileOperationHistory.shared.recordTrash(trashedRecords)
        let removedPaths = Set(trashedRecords.map { $0.original.standardizedFileURL.path })
        items.removeAll { removedPaths.contains($0.url.standardizedFileURL.path) }
        DirectorySnapshotCache.shared.invalidate(currentURL)
        applyFilter(preservingGridPosition: true)
        loadCurrentDirectory(asynchronously: true, preservingGridPosition: true)
        if !errors.isEmpty {
            showError(errors.joined(separator: " | "))
        }
    }

    func copySelectedPaths() {
        activate()
        let paths = selectedItems.map { $0.url.path }
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    @objc func copyFiles(_ sender: Any?) {
        writeFilesToPasteboard(cutting: false)
    }

    @objc func cutFiles(_ sender: Any?) {
        writeFilesToPasteboard(cutting: true)
    }

    @objc func pasteFiles(_ sender: Any?) {
        activate()
        let pasteboard = NSPasteboard.general
        let urls = fileURLs(from: pasteboard)
        guard !urls.isEmpty else { NSSound.beep(); return }
        let cutting = pasteboard.string(forType: cutPasteboardType) == "1"
        startTransfer(urls: urls, to: currentURL, move: cutting)
        if cutting {
            FPCutFileState.shared.clear()
            pasteboard.clearContents()
        }
    }

    private func writeFilesToPasteboard(cutting: Bool) {
        activate()
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { NSSound.beep(); return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        pasteboard.setString(cutting ? "1" : "0", forType: cutPasteboardType)
        if cutting {
            FPCutFileState.shared.set(urls: urls, pasteboard: pasteboard)
        } else {
            FPCutFileState.shared.clear()
        }
    }

    private func startTransfer(urls: [URL], to target: URL, move: Bool, alwaysKeepBoth: Bool = false) {
        var tasks: [FileTransferController.Task] = []
        for rawSource in urls {
            let source = rawSource.standardizedFileURL
            guard fileManager.fileExists(atPath: source.path),
                  source.deletingLastPathComponent().path != target.path,
                  !isSameOrAncestor(source, of: target) else { continue }

            let directDestination = target.appendingPathComponent(source.lastPathComponent)
            if !fileManager.fileExists(atPath: directDestination.path) {
                tasks.append(.init(source: source, destination: directDestination, move: move, replaceExisting: false))
                continue
            }

            if alwaysKeepBoth {
                tasks.append(.init(source: source, destination: uniqueDestination(for: source, in: target), move: move, replaceExisting: false))
                continue
            }

            let alert = NSAlert()
            alert.messageText = "Объект «\(source.lastPathComponent)» уже существует"
            alert.informativeText = "Выбери, как поступить. При замене старый объект сначала попадёт в корзину."
            alert.addButton(withTitle: "Заменить")
            alert.addButton(withTitle: "Сохранить оба")
            alert.addButton(withTitle: "Пропустить")
            alert.addButton(withTitle: "Отменить всё")
            alert.alertStyle = .warning
            let response = alert.runModal()
            switch response.rawValue {
            case NSApplication.ModalResponse.alertFirstButtonReturn.rawValue:
                tasks.append(.init(source: source, destination: directDestination, move: move, replaceExisting: true))
            case NSApplication.ModalResponse.alertSecondButtonReturn.rawValue:
                tasks.append(.init(source: source, destination: uniqueDestination(for: source, in: target), move: move, replaceExisting: false))
            case NSApplication.ModalResponse.alertThirdButtonReturn.rawValue:
                continue
            default:
                return
            }
        }

        guard !tasks.isEmpty else { return }
        if transferController == nil { transferController = FileTransferController() }
        transferController?.run(tasks: tasks, parent: window) { [weak self] completed, errors in
            guard let self else { return }
            QyvroFileOperationHistory.shared.recordTransfer(completed)
            DirectorySnapshotCache.shared.invalidate(target)
            for source in urls {
                DirectorySnapshotCache.shared.invalidate(source.deletingLastPathComponent())
            }
            self.loadCurrentDirectory(asynchronously: true, preservingGridPosition: true)
            if let first = completed.first?.destination,
               first.deletingLastPathComponent().path == self.currentURL.path {
                self.select(url: first)
            }
            self.showError(errors.joined(separator: " | "))
        }
    }

    @objc func duplicateSelection(_ sender: Any?) {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { NSSound.beep(); return }
        startTransfer(urls: urls, to: currentURL, move: false, alwaysKeepBoth: true)
    }

    @objc func compressSelectionToZIP(_ sender: Any?) {
        activate()
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { NSSound.beep(); return }

        let parentPaths = Set(urls.map { $0.deletingLastPathComponent().standardizedFileURL.path })
        guard parentPaths.count == 1, let parentPath = parentPaths.first else {
            showError("Для одного ZIP выбери объекты из одной папки")
            NSSound.beep()
            return
        }
        let parent = URL(fileURLWithPath: parentPath, isDirectory: true)
        let baseName: String
        if urls.count == 1 {
            let item = urls[0]
            baseName = item.pathExtension.isEmpty
                ? item.lastPathComponent
                : item.deletingPathExtension().lastPathComponent
        } else {
            baseName = "Архив"
        }
        let template = parent.appendingPathComponent("\(baseName).zip")
        let destination = uniqueDestination(for: template, in: parent)

        let executable: URL
        let arguments: [String]
        let workingDirectory: URL?
        if urls.count == 1, selectedItems.first?.isDirectory == true {
            executable = URL(fileURLWithPath: "/usr/bin/ditto")
            arguments = [
                "-c", "-k", "--sequesterRsrc", "--keepParent",
                urls[0].path, destination.path
            ]
            workingDirectory = nil
        } else {
            executable = URL(fileURLWithPath: "/usr/bin/zip")
            // `./` keeps a legitimate filename beginning with "-" from being
            // interpreted as a command-line switch by Info-ZIP.
            arguments = ["-qry", destination.path]
                + urls.map { "./\($0.lastPathComponent)" }
            workingDirectory = parent
        }

        footerLabel.stringValue = urls.count == 1
            ? "Создаю \(destination.lastPathComponent)…"
            : "Сжимаю \(urls.count) объектов…"
        runArchiveProcess(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                DirectorySnapshotCache.shared.invalidate(parent)
                self.loadCurrentDirectory(asynchronously: true, preservingGridPosition: true) {
                    DispatchQueue.main.async {
                        self.select(url: destination)
                        self.footerLabel.stringValue = "Создан \(destination.lastPathComponent)"
                    }
                }
            case .failure(let error):
                try? FileManager.default.removeItem(at: destination)
                self.showError("ZIP не создан: \(error.localizedDescription)")
            }
        }
    }

    @objc func extractSelectedZIP(_ sender: Any?) {
        activate()
        guard selectedItems.count == 1,
              let archive = selectedItems.first,
              !archive.isDirectory,
              archive.url.pathExtension.lowercased() == "zip" else {
            NSSound.beep()
            return
        }

        let parent = archive.url.deletingLastPathComponent()
        let baseName = archive.url.deletingPathExtension().lastPathComponent
        let template = parent.appendingPathComponent(baseName, isDirectory: true)
        let destination = uniqueDestination(for: template, in: parent)
        let temporaryDestination = parent.appendingPathComponent(
            ".qyvro-unpack-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(at: temporaryDestination, withIntermediateDirectories: false)
        } catch {
            showError("Не удалось создать папку: \(error.localizedDescription)")
            return
        }

        footerLabel.stringValue = "Распаковываю \(archive.name)…"
        runArchiveProcess(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", archive.url.path, temporaryDestination.path],
            workingDirectory: nil
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                do {
                    try self.finalizeExtractedZIP(
                        temporaryDirectory: temporaryDestination,
                        destination: destination,
                        expectedRootName: baseName
                    )
                    DirectorySnapshotCache.shared.invalidate(parent)
                    self.loadCurrentDirectory(asynchronously: true, preservingGridPosition: true) {
                        DispatchQueue.main.async {
                            self.select(url: destination)
                            self.footerLabel.stringValue = "Распаковано в \(destination.lastPathComponent)"
                        }
                    }
                } catch {
                    try? FileManager.default.removeItem(at: temporaryDestination)
                    try? FileManager.default.removeItem(at: destination)
                    self.showError("Архив не распакован: \(error.localizedDescription)")
                }
            case .failure(let error):
                try? FileManager.default.removeItem(at: temporaryDestination)
                self.showError("Архив не распакован: \(error.localizedDescription)")
            }
        }
    }

    private func finalizeExtractedZIP(
        temporaryDirectory: URL,
        destination: URL,
        expectedRootName: String
    ) throws {
        let manager = FileManager.default
        let extracted = try manager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ).filter { $0.lastPathComponent != "__MACOSX" && $0.lastPathComponent != ".DS_Store" }

        if extracted.count == 1,
           extracted[0].lastPathComponent == expectedRootName,
           (try? extracted[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            try manager.moveItem(at: extracted[0], to: destination)
        } else {
            try manager.createDirectory(at: destination, withIntermediateDirectories: false)
            for item in extracted {
                try manager.moveItem(
                    at: item,
                    to: destination.appendingPathComponent(item.lastPathComponent)
                )
            }
        }
        try? manager.removeItem(at: temporaryDirectory)
    }

    private func runArchiveProcess(
        executable: URL,
        arguments: [String],
        workingDirectory: URL?,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectory
            process.standardOutput = FileHandle.nullDevice
            let errorPipe = Pipe()
            process.standardError = errorPipe
            do {
                try process.run()
                process.waitUntilExit()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorText = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if process.terminationStatus == 0 {
                    DispatchQueue.main.async { completion(.success(())) }
                } else {
                    let description = (errorText?.isEmpty == false)
                        ? errorText!
                        : "системная утилита завершилась с кодом \(process.terminationStatus)"
                    let error = NSError(
                        domain: "Qyvro.Archive",
                        code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: description]
                    )
                    DispatchQueue.main.async { completion(.failure(error)) }
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    @objc func newTextFile(_ sender: Any?) {
        activate()
        let template = currentURL.appendingPathComponent("Новый документ.txt")
        let destination = uniqueDestination(for: template, in: currentURL)
        do {
            try Data().write(to: destination, options: .atomic)
            DirectorySnapshotCache.shared.invalidate(currentURL)
            loadCurrentDirectory(asynchronously: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.select(url: destination)
                self?.renameSelection(nil)
            }
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc func openInTerminal(_ sender: Any?) {
        activate()
        let folder = selectedItems.first.map { $0.isDirectory ? $0.url : $0.url.deletingLastPathComponent() } ?? currentURL
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app", isDirectory: true)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: configuration) { [weak self] _, error in
            if let error { DispatchQueue.main.async { self?.showError(error.localizedDescription) } }
        }
    }

    @objc private func convertSelectedHEICToPNG(_ sender: Any?) {
        let sources = selectedItems
            .filter { !$0.isDirectory && ["heic", "heif"].contains($0.url.pathExtension.lowercased()) }
            .map(\.url)
        convertImages(sources, to: .png)
    }

    @objc private func convertSelectedPNGToJPEG(_ sender: Any?) {
        let sources = selectedItems
            .filter { !$0.isDirectory && $0.url.pathExtension.lowercased() == "png" }
            .map(\.url)
        convertImages(sources, to: .jpeg)
    }

    private func convertImages(_ sources: [URL], to target: FPImageConversionTarget) {
        guard !sources.isEmpty else {
            NSSound.beep()
            return
        }
        activate()
        footerLabel.stringValue = sources.count == 1
            ? "Конвертирую \(sources[0].lastPathComponent)…"
            : "Конвертирую \(sources.count) изображений…"
        FPImageConverter.convert(urls: sources, to: target) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let outputs):
                DirectorySnapshotCache.shared.invalidate(self.currentURL)
                self.loadCurrentDirectory(
                    asynchronously: true,
                    preservingGridPosition: true
                ) { [weak self] in
                    guard let self else { return }
                    if let first = outputs.first {
                        self.select(url: first)
                    }
                    self.footerLabel.stringValue = outputs.count == 1
                        ? "Создан \(outputs[0].lastPathComponent)"
                        : "Создано изображений: \(outputs.count)"
                }
            case .failure(let error):
                self.footerLabel.stringValue = self.footerText()
                self.showError(error.localizedDescription)
            }
        }
    }

    /// Приложения, в которые файлы уходят чаще всего.
    ///
    /// Отдельными пунктами первого уровня, а не внутри «Открыть с помощью»:
    /// в ежедневной работе это два клика против четырёх.
    private static let photoshopExtensions: Set<String> = [
        "png", "jpg", "jpeg", "tif", "tiff", "psd", "psb", "heic", "heif",
        "webp", "gif", "bmp", "raw", "dng", "cr2", "nef", "arw"
    ]
    /// Premiere принимает и кадры, и видео — раскадровки и футаж живут в
    /// одном проекте.
    private static let premiereExtensions: Set<String> =
        photoshopExtensions.union([
            "mp4", "mov", "m4v", "avi", "mkv", "mxf", "mpg", "mpeg",
            "wav", "mp3", "aac", "aif", "aiff"
        ])

    private static let creativeApps: [
        (title: String, bundleIdentifiers: [String], extensions: Set<String>)
    ] = [
        ("Открыть в Photoshop", ["com.adobe.Photoshop"], photoshopExtensions),
        (
            "Открыть в Premiere Pro",
            ["com.adobe.PremierePro", "com.adobe.AfterEffects"],
            premiereExtensions
        )
    ]

    private func installedCreativeApp(matching identifiers: [String]) -> URL? {
        for identifier in identifiers {
            if let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: identifier
            ) {
                return url
            }
        }
        // Adobe меняет идентификаторы от версии к версии (…Photoshop-2024 и
        // подобные), поэтому запасной путь — поиск по префиксу имени бандла.
        guard let prefix = identifiers.first?.split(separator: ".").last.map(String.init) else {
            return nil
        }
        let applicationDirectories = ["/Applications", NSHomeDirectory() + "/Applications"]
        for directory in applicationDirectories {
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
            if let match = names.first(where: {
                $0.hasSuffix(".app") && $0.localizedCaseInsensitiveContains(prefix)
            }) {
                return URL(fileURLWithPath: directory).appendingPathComponent(match)
            }
        }
        return nil
    }

    @objc private func openSelectionInCreativeApp(_ sender: NSMenuItem) {
        guard let applicationURL = sender.representedObject as? URL else {
            NSSound.beep()
            return
        }
        let urls = selectedItems.filter { !$0.isDirectory }.map(\.url)
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(
            urls,
            withApplicationAt: applicationURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    private var selectedResizableImages: [URL] {
        selectedItems
            .filter { !$0.isDirectory && FPImageResizer.isSupported($0.url) }
            .map(\.url)
    }

    @objc private func resizeSelectedImagesFromMenu(_ sender: NSMenuItem) {
        guard let maxSide = sender.representedObject as? Int else {
            NSSound.beep()
            return
        }
        resizeImages(selectedResizableImages, maxSide: maxSide)
    }

    @objc private func resizeSelectedImagesToCustomSize(_ sender: Any?) {
        let sources = selectedResizableImages
        guard !sources.isEmpty else {
            NSSound.beep()
            return
        }
        activate()

        let alert = NSAlert()
        alert.messageText = "Ресайз изображений"
        alert.informativeText = sources.count == 1
            ? "Длинная сторона \(sources[0].lastPathComponent), пикселей:"
            : "Длинная сторона для \(sources.count) изображений, пикселей:"
        alert.addButton(withTitle: "Уменьшить")
        alert.addButton(withTitle: "Отмена")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = String(FPImageResizer.presetMaxSides[0])
        field.alignment = .left
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let maxSide = Int(field.stringValue.trimmingCharacters(in: .whitespaces)),
              maxSide >= 16, maxSide <= 30_000 else {
            showError("Введите число от 16 до 30000.")
            return
        }
        resizeImages(sources, maxSide: maxSide)
    }

    private func resizeImages(_ sources: [URL], maxSide: Int) {
        guard !sources.isEmpty else {
            NSSound.beep()
            return
        }
        activate()
        footerLabel.stringValue = sources.count == 1
            ? "Уменьшаю \(sources[0].lastPathComponent) до \(maxSide)px…"
            : "Уменьшаю изображений: \(sources.count) до \(maxSide)px…"
        FPImageResizer.resize(urls: sources, maxSide: maxSide) { [weak self] outcome in
            guard let self else { return }
            guard !outcome.resized.isEmpty else {
                self.footerLabel.stringValue = self.footerText()
                if outcome.failed.isEmpty {
                    // Ничего не сделано только потому, что уменьшать было нечего.
                    self.footerLabel.stringValue = sources.count == 1
                        ? "\(sources[0].lastPathComponent) уже не больше \(maxSide)px"
                        : "Все выбранные изображения уже не больше \(maxSide)px"
                } else {
                    self.showError(
                        "Не удалось уменьшить: \(outcome.failed.joined(separator: ", "))"
                    )
                }
                return
            }
            DirectorySnapshotCache.shared.invalidate(self.currentURL)
            self.loadCurrentDirectory(
                asynchronously: true,
                preservingGridPosition: true
            ) { [weak self] in
                guard let self else { return }
                if let first = outcome.resized.first {
                    self.select(url: first)
                }
                var summary = outcome.resized.count == 1
                    ? "Создан \(outcome.resized[0].lastPathComponent)"
                    : "Уменьшено изображений: \(outcome.resized.count)"
                if !outcome.skipped.isEmpty {
                    summary += " · пропущено (уже меньше): \(outcome.skipped.count)"
                }
                if !outcome.failed.isEmpty {
                    summary += " · ошибок: \(outcome.failed.count)"
                }
                self.footerLabel.stringValue = summary
            }
        }
    }

    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Открыть", action: #selector(openSelection(_:)), keyEquivalent: "")
        if selectedItems.count == 1, selectedItems.first?.isDirectory == false {
            let openWithItem = NSMenuItem(title: "Открыть с помощью", action: nil, keyEquivalent: "")
            let openWithMenu = NSMenu()
            let applications = NSWorkspace.shared.urlsForApplications(toOpen: selectedItems[0].url)
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            for application in applications.prefix(12) {
                let item = NSMenuItem(
                    title: application.deletingPathExtension().lastPathComponent,
                    action: #selector(openSelectionWithApplication(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = application
                item.image = NSWorkspace.shared.icon(forFile: application.path)
                item.image?.size = NSSize(width: 16, height: 16)
                openWithMenu.addItem(item)
            }
            menu.setSubmenu(openWithMenu, for: openWithItem)
            menu.addItem(openWithItem)
        }
        menu.addItem(withTitle: "Открыть в новой вкладке", action: #selector(openSelectionInNewTab(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Открыть в новой панели", action: #selector(openSelectionInNewPane(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Быстрый просмотр", action: #selector(quickLookSelection(_:)), keyEquivalent: "")
        if !selectedItems.isEmpty,
           let airDrop = NSSharingService(named: .sendViaAirDrop),
           airDrop.canPerform(withItems: selectedItems.map(\.url)) {
            let airDropItem = menu.addItem(
                withTitle: "Поделиться через AirDrop…",
                action: #selector(shareSelectionViaAirDrop(_:)),
                keyEquivalent: ""
            )
            airDropItem.image = NSImage(
                systemSymbolName: "airdrop",
                accessibilityDescription: "AirDrop"
            )
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Новая папка", action: #selector(newFolder(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Новый текстовый файл", action: #selector(newTextFile(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Переименовать", action: #selector(renameSelection(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Пакетное переименование...", action: #selector(batchRenameSelection(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Свойства", action: #selector(showInspector(_:)), keyEquivalent: "")
        if selectedItems.contains(where: \.isDirectory) {
            menu.addItem(
                withTitle: selectedItems.filter(\.isDirectory).count == 1
                    ? "Посчитать размер папки"
                    : "Посчитать размер папок",
                action: #selector(showInspectorAndCalculateFolderSize(_:)),
                keyEquivalent: ""
            )
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Копировать", action: #selector(copyFiles(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Вырезать", action: #selector(cutFiles(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Вставить", action: #selector(pasteFiles(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Дублировать", action: #selector(duplicateSelection(_:)), keyEquivalent: "")
        if !selectedItems.isEmpty {
            menu.addItem(NSMenuItem.separator())
            let compressTitle = selectedItems.count == 1
                ? "Сжать в ZIP"
                : "Сжать \(selectedItems.count) объектов в ZIP"
            menu.addItem(
                withTitle: compressTitle,
                action: #selector(compressSelectionToZIP(_:)),
                keyEquivalent: ""
            )
            if selectedItems.count == 1,
               selectedItems[0].url.pathExtension.lowercased() == "zip" {
                menu.addItem(
                    withTitle: "Распаковать ZIP в папку",
                    action: #selector(extractSelectedZIP(_:)),
                    keyEquivalent: ""
                )
            }
        }
        let selectedHEICCount = selectedItems.filter {
            !$0.isDirectory && ["heic", "heif"].contains($0.url.pathExtension.lowercased())
        }.count
        let selectedPNGCount = selectedItems.filter {
            !$0.isDirectory && $0.url.pathExtension.lowercased() == "png"
        }.count
        if selectedHEICCount > 0 || selectedPNGCount > 0 {
            let convertItem = NSMenuItem(title: "Конвертировать", action: nil, keyEquivalent: "")
            let convertMenu = NSMenu()
            if selectedHEICCount > 0 {
                let heicItem = convertMenu.addItem(
                    withTitle: selectedHEICCount == 1 ? "HEIC → PNG" : "HEIC → PNG (\(selectedHEICCount))",
                    action: #selector(convertSelectedHEICToPNG(_:)),
                    keyEquivalent: ""
                )
                heicItem.target = self
            }
            if selectedPNGCount > 0 {
                let pngItem = convertMenu.addItem(
                    withTitle: selectedPNGCount == 1 ? "PNG → JPEG" : "PNG → JPEG (\(selectedPNGCount))",
                    action: #selector(convertSelectedPNGToJPEG(_:)),
                    keyEquivalent: ""
                )
                pngItem.target = self
            }
            menu.setSubmenu(convertMenu, for: convertItem)
            menu.addItem(convertItem)
        }
        let selectedFiles = selectedItems.filter { !$0.isDirectory }
        if !selectedFiles.isEmpty {
            var addedCreativeApp = false
            for app in Self.creativeApps {
                // Пункт появляется, только если приложение действительно
                // откроет всё выделенное. Иначе видео можно было отправить в
                // Photoshop одним промахом мыши.
                let allSupported = selectedFiles.allSatisfy {
                    app.extensions.contains($0.url.pathExtension.lowercased())
                }
                guard allSupported,
                      let applicationURL = installedCreativeApp(
                          matching: app.bundleIdentifiers
                      ) else { continue }
                let item = menu.addItem(
                    withTitle: app.title,
                    action: #selector(openSelectionInCreativeApp(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = applicationURL
                item.image = NSWorkspace.shared.icon(forFile: applicationURL.path)
                item.image?.size = NSSize(width: 16, height: 16)
                addedCreativeApp = true
            }
            if addedCreativeApp { menu.addItem(.separator()) }
        }
        let resizableImages = selectedResizableImages
        if !resizableImages.isEmpty {
            let resizeItem = NSMenuItem(title: "Ресайз", action: nil, keyEquivalent: "")
            let resizeMenu = NSMenu()
            let countSuffix = resizableImages.count == 1 ? "" : " (\(resizableImages.count))"
            for maxSide in FPImageResizer.presetMaxSides {
                let item = resizeMenu.addItem(
                    withTitle: "Длинная сторона \(maxSide)px\(countSuffix)",
                    action: #selector(resizeSelectedImagesFromMenu(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = maxSide
            }
            resizeMenu.addItem(.separator())
            let customItem = resizeMenu.addItem(
                withTitle: "Свой размер…",
                action: #selector(resizeSelectedImagesToCustomSize(_:)),
                keyEquivalent: ""
            )
            customItem.target = self
            menu.setSubmenu(resizeMenu, for: resizeItem)
            menu.addItem(resizeItem)
        }
        if selectedItems.contains(where: { $0.isDirectory }) {
            let colorItem = NSMenuItem(title: "Цвет папки", action: nil, keyEquivalent: "")
            let colorMenu = NSMenu()
            for option in folderColorOptions() {
                let item = NSMenuItem(title: option.title, action: #selector(setFolderColorFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = [
                    "color": option.key ?? "",
                    "paths": selectedItems.filter { $0.isDirectory }.map { $0.url.path }
                ]
                colorMenu.addItem(item)
            }
            menu.setSubmenu(colorMenu, for: colorItem)
            menu.addItem(colorItem)
            let iconItem = NSMenuItem(title: "Значок папки", action: nil, keyEquivalent: "")
            let iconMenu = NSMenu()
            let choose = NSMenuItem(title: "Выбрать изображение...", action: #selector(chooseFolderIcon(_:)), keyEquivalent: "")
            choose.target = self
            iconMenu.addItem(choose)
            let remove = NSMenuItem(title: "Вернуть обычный значок", action: #selector(removeFolderIcon(_:)), keyEquivalent: "")
            remove.target = self
            iconMenu.addItem(remove)
            menu.setSubmenu(iconMenu, for: iconItem)
            menu.addItem(iconItem)
        }
        menu.addItem(withTitle: "Скопировать путь", action: #selector(copyPathsFromMenu(_:)), keyEquivalent: "")
        if selectedItems.count == 1, selectedItems.first?.isDirectory == false {
            menu.addItem(withTitle: "Скопировать SHA-256", action: #selector(copySHA256(_:)), keyEquivalent: "")
        }
        menu.addItem(withTitle: "Открыть в Terminal", action: #selector(openInTerminal(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Показать в Finder", action: #selector(revealSelection(_:)), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Переместить в корзину", action: #selector(trashSelection(_:)), keyEquivalent: "")
        for item in menu.items {
            item.target = self
        }
        return menu
    }

    @objc private func openSelectionWithApplication(_ sender: NSMenuItem) {
        guard let application = sender.representedObject as? URL,
              let file = selectedItems.first?.url else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([file], withApplicationAt: application, configuration: configuration)
    }

    @objc private func shareSelectionViaAirDrop(_ sender: Any?) {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty,
              let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: urls) else {
            NSSound.beep()
            return
        }
        service.perform(withItems: urls)
    }

    @objc private func copyPathsFromMenu(_ sender: Any?) {
        copySelectedPaths()
    }

    @objc private func copySHA256(_ sender: Any?) {
        guard selectedItems.count == 1, let file = selectedItems.first, !file.isDirectory else { return }
        footerLabel.stringValue = "Вычисляю SHA-256…"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let handle = try FileHandle(forReadingFrom: file.url)
                defer { try? handle.close() }
                var hasher = SHA256()
                while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                    hasher.update(data: chunk)
                }
                let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                DispatchQueue.main.async {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(hash, forType: .string)
                    self?.footerLabel.stringValue = "SHA-256 скопирован"
                }
            } catch {
                DispatchQueue.main.async { self?.showError(error.localizedDescription) }
            }
        }
    }

    @objc private func setFolderColorFromMenu(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String: Any],
              let color = payload["color"] as? String,
              let paths = payload["paths"] as? [String] else { return }
        applyFolderColor(color.isEmpty ? nil : color, to: paths.map { URL(fileURLWithPath: $0) })
    }

    @objc private func chooseFolderIcon(_ sender: Any?) {
        let folders = selectedItems.filter(\.isDirectory).map(\.url)
        guard !folders.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["png", "jpg", "jpeg", "heic", "webp", "tiff"].compactMap { UTType(filenameExtension: $0) }
        panel.message = folders.count == 1
            ? "Выбери изображение для папки \(folders[0].lastPathComponent)"
            : "Выбери изображение для \(folders.count) папок"
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let failed = folders.filter { !CustomFolderIconStore.shared.setIcon(from: source, for: $0) }
        refreshVisibleItems(paths: Set(folders.map(\.path)))
        if !failed.isEmpty {
            showError("Не удалось сохранить значок для \(failed.count) папок")
        }
    }

    @objc private func removeFolderIcon(_ sender: Any?) {
        let folders = selectedItems.filter(\.isDirectory).map(\.url)
        folders.forEach { CustomFolderIconStore.shared.removeIcon(for: $0) }
        refreshVisibleItems(paths: Set(folders.map(\.path)))
    }

    func applyFolderColor(_ color: String?, to urls: [URL]) {
        guard !urls.isEmpty else { return }
        var map = folderColorMap()
        let selectedTag = color.flatMap { key in
            FPTag.all.first(where: { $0.key == key })
        }
        var failed: [URL] = []

        for url in urls {
            let path = url.standardizedFileURL.path
            let legacyManagedTitle = map[path].flatMap { key in
                FPTag.all.first(where: { $0.key == key })?.title
            }
            do {
                let remainingTags = try FPFinderTagStore.setQyvroTag(
                    selectedTag,
                    on: url,
                    legacyManagedTitle: legacyManagedTitle
                )
                if let selectedTag {
                    map[path] = selectedTag.key
                } else if let remaining = FPFinderTagStore.preferredTag(for: url, among: remainingTags) {
                    map[path] = FPTagStore.shared.key(for: remaining)
                } else {
                    map.removeValue(forKey: path)
                }
                DirectorySnapshotCache.shared.invalidate(url.deletingLastPathComponent())
            } catch {
                failed.append(url)
            }
        }
        UserDefaults.standard.set(map, forKey: "FolderColors")
        if virtualTagTitle != nil {
            loadCurrentDirectory()
        } else {
            refreshVisibleItems(paths: Set(urls.map { $0.standardizedFileURL.path }))
        }
        if !failed.isEmpty {
            if failed.count == 1 {
                showError("Не удалось изменить Finder-тег: \(failed[0].lastPathComponent)")
            } else {
                showError("Не удалось изменить Finder-тег для \(failed.count) элементов")
            }
        }
    }

    private func refreshVisibleItems(paths: Set<String>) {
        var rows = IndexSet()
        for (index, item) in filteredItems.enumerated() where paths.contains(item.url.path) {
            rows.insert(index)
        }
        guard !rows.isEmpty else { return }

        tableView.reloadData(
            forRowIndexes: rows,
            columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
        )

        guard viewMode == .largeIcons else { return }
        for cell in gridItemViews where rows.contains(cell.itemIndex) {
            let item = filteredItems[cell.itemIndex]
            cell.configure(
                item: item,
                image: displayImage(for: item, size: visibleIconSize),
                imageSize: visibleIconSize,
                selected: gridSelectionIndexes.contains(cell.itemIndex),
                cut: FPCutFileState.shared.contains(item.url)
            )
        }
    }

    private func select(url: URL) {
        guard let index = filteredItems.firstIndex(where: { $0.url == url }) else { return }
        if viewMode == .largeIcons {
            gridSelectionIndexes = IndexSet(integer: index)
            updateGridSelection()
            scrollGridItemToVisible(index)
            focusFiles()
            notifySelectionChanged()
        } else {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            tableView.scrollRowToVisible(index)
        }
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === pathField || field === searchField else { return }
        setFieldFocusGlow(field, active: true)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === pathField || field === searchField {
            setFieldFocusGlow(field, active: false)
        }
        guard field == pathField else { return }
        navigateToPath(from: field)
        finishPathEditing()
    }

    // Аккуратное свечение активного поля (путь/поиск) вместо системного
    // фокус-кольца — подсказывает, куда пойдёт ввод, и не спорит с тёмной темой.
    private func setFieldFocusGlow(_ field: NSTextField, active: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            field.layer?.borderColor = (active ? FPStyle.accent.withAlphaComponent(0.62) : FPStyle.stroke).cgColor
            field.layer?.borderWidth = active ? 1 : 0.5
            field.layer?.shadowColor = FPStyle.accent.cgColor
            field.layer?.shadowOpacity = active ? 0.28 : 0
            field.layer?.shadowRadius = 5
            field.layer?.shadowOffset = .zero
        }
    }

    @objc private func pathSubmitted(_ sender: NSTextField) {
        navigateToPath(from: sender)
        finishPathEditing()
        focusFiles()
    }

    private func navigateToPath(from field: NSTextField) {
        let path = (field.stringValue as NSString).expandingTildeInPath
        navigate(to: URL(fileURLWithPath: path))
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredItems.count
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row >= 0, row < filteredItems.count else { return nil }
        return filteredItems[row].url as NSURL
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        activate()
        footerLabel.stringValue = footerText()
        syncFolderPocketToSelection()
        notifySelectionChanged()
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        syncSortControl()
        sortItems()
        applyFilter()
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = PanelRowView()
        rowView.rowColor = row.isMultiple(of: 2) ? FPStyle.rowA : FPStyle.rowB
        if filteredItems.indices.contains(row) {
            rowView.alphaValue = FPCutFileState.shared.contains(filteredItems[row].url) ? 0.42 : 1
        }
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0 && row < filteredItems.count, let column = tableColumn else { return nil }
        let item = filteredItems[row]
        switch column.identifier.rawValue {
        case "name":
            return nameCell(for: item)
        case "size":
            return textCell(identifier: "SizeCell", text: item.isDirectory ? "-" : byteString(item.size ?? 0), alignment: .right)
        case "created":
            return textCell(identifier: "CreatedCell", text: item.created.map { dateFormatter.string(from: $0) } ?? "-", alignment: .left)
        case "modified":
            return textCell(identifier: "ModifiedCell", text: item.modified.map { dateFormatter.string(from: $0) } ?? "-", alignment: .left)
        case "kind":
            return textCell(identifier: "KindCell", text: item.kind, alignment: .left)
        default:
            return textCell(identifier: "TextCell", text: "", alignment: .left)
        }
    }

    private func nameCell(for item: FileItem) -> NSTableCellView {
        let size = visibleIconSize
        let identifier = NSUserInterfaceItemIdentifier("NameCell-\(Int(size))")
        if let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView,
           let textField = cell.textField,
           let imageView = cell.imageView {
            textField.stringValue = item.name
            textField.textColor = item.isHidden ? .tertiaryLabelColor : .labelColor
            imageView.image = displayImage(for: item, size: size)
            textField.font = .systemFont(ofSize: viewMode == .largeIcons ? 13 : 12, weight: .regular)
            textField.toolTip = hoverTooltip(for: item, availableWidth: tableNameTextWidth(iconSize: size))
            return cell
        }

        let cell = NSTableCellView()
        cell.identifier = identifier

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = displayImage(for: item, size: size)

        let textField = NSTextField(labelWithString: item.name)
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.lineBreakMode = .byTruncatingMiddle
        textField.textColor = item.isHidden ? .tertiaryLabelColor : .labelColor
        textField.font = .systemFont(ofSize: viewMode == .largeIcons ? 13 : 12, weight: .regular)
        textField.toolTip = hoverTooltip(for: item, availableWidth: tableNameTextWidth(iconSize: size))

        cell.addSubview(imageView)
        cell.addSubview(textField)
        cell.imageView = imageView
        cell.textField = textField

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: size),
            imageView.heightAnchor.constraint(equalToConstant: size),
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 7),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])

        return cell
    }

    private func tableNameTextWidth(iconSize: CGFloat) -> CGFloat {
        let nameWidth = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("name"))?.width ?? 280
        return max(40, nameWidth - iconSize - 24)
    }

    private func hoverTooltip(for item: FileItem, availableWidth: CGFloat) -> String? {
        let font = NSFont.systemFont(ofSize: viewMode == .largeIcons ? 13 : 12, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let width = (item.name as NSString).size(withAttributes: attrs).width
        guard width > availableWidth else { return nil }
        if item.isDirectory {
            return item.name
        }
        let size = ByteCountFormatter.string(fromByteCount: item.size ?? 0, countStyle: .file)
        return "\(item.name)\nРазмер: \(size)"
    }

    private func displayImage(for item: FileItem, size: CGFloat) -> NSImage {
        if item.isDirectory {
            if let custom = CustomFolderIconStore.shared.image(for: item.url) {
                return custom
            }
            return coloredFolderIcon(color: folderColor(for: item.url) ?? FPStyle.defaultFolder, size: size)
        }

        let key = thumbnailKey(for: item, size: size)
        if let cached = thumbnailCache[key] {
            return cached
        }
        if let cached = ThumbnailDiskCache.shared.image(for: key) {
            storeThumbnail(cached, key: key, persist: false)
            return cached
        }

        requestThumbnail(for: item.url, size: size, key: key)

        return WorkspaceIconCache.shared.icon(for: item.url, size: size)
    }

    private func requestThumbnail(for url: URL, size: CGFloat, key: String) {
        guard !pendingThumbnailKeys.contains(key) else { return }
        pendingThumbnailKeys.insert(key)

        ThumbnailDiskCache.shared.loadFromDisk(for: key) { [weak self] image in
            guard let self, self.pendingThumbnailKeys.contains(key) else { return }
            if let image {
                self.pendingThumbnailKeys.remove(key)
                self.storeThumbnail(image, key: key, persist: false)
                self.reloadNameCell(for: url)
                return
            }
            if self.isImageFile(url) {
                self.generateImagePreview(for: url, size: size, key: key)
            } else if self.isVideoFile(url) {
                self.generateVideoPreview(for: url, size: size, key: key)
            } else {
                self.requestQuickLookThumbnail(for: url, size: size, key: key)
            }
        }
    }

    private func generateImagePreview(for url: URL, size: CGFloat, key: String) {
        let pixelSize = max(96, Int((size * (NSScreen.main?.backingScaleFactor ?? 2)).rounded()))
        var operation: BlockOperation!
        operation = BlockOperation { [weak self] in
            guard !operation.isCancelled else { return }
            let image = autoreleasepool { self?.downsampledImage(at: url, maxPixelSize: pixelSize) }
            guard !operation.isCancelled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pendingThumbnailKeys.contains(key), !operation.isCancelled else { return }
                self.thumbnailOperations.removeValue(forKey: key)
                self.pendingThumbnailKeys.remove(key)
                guard let image else { return }
                self.storeThumbnail(image, key: key)
                self.reloadNameCell(for: url)
            }
        }
        thumbnailOperations[key] = operation
        imageLoadQueue.addOperation(operation)
    }

    private func requestQuickLookThumbnail(for url: URL, size: CGFloat, key: String) {
        // The key is inserted before the disk-cache lookup. Requiring it to be
        // absent here made every non-image request return immediately, which is
        // why MP4/PDF files were stuck on generic document icons.
        guard pendingThumbnailKeys.contains(key) else { return }

        if #available(macOS 10.15, *) {
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: size, height: size),
                scale: min(NSScreen.main?.backingScaleFactor ?? 2, 2),
                representationTypes: [.thumbnail, .icon]
            )
            quickLookRequests[key] = request
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, _ in
                guard let self else { return }
                DispatchQueue.main.async {
                    guard self.pendingThumbnailKeys.contains(key) else { return }
                    self.quickLookRequests.removeValue(forKey: key)
                    self.pendingThumbnailKeys.remove(key)
                    guard let image = thumbnail?.nsImage else { return }
                    self.storeThumbnail(image, key: key)
                    self.reloadNameCell(for: url)
                }
            }
        } else {
            pendingThumbnailKeys.remove(key)
        }
    }

    private func generateVideoPreview(for url: URL, size: CGFloat, key: String) {
        guard pendingThumbnailKeys.contains(key) else { return }
        let scale = min(NSScreen.main?.backingScaleFactor ?? 2, 2)
        let pixelSize = max(128, size * scale)
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: pixelSize, height: pixelSize)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        videoThumbnailGenerators[key] = generator
        let previewTime = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.generateCGImageAsynchronously(for: previewTime) { [weak self] image, _, _ in
            DispatchQueue.main.async {
                guard let self, self.pendingThumbnailKeys.contains(key) else { return }
                self.videoThumbnailGenerators.removeValue(forKey: key)
                guard let image else {
                    self.requestQuickLookThumbnail(for: url, size: size, key: key)
                    return
                }
                self.pendingThumbnailKeys.remove(key)
                let thumbnail = NSImage(
                    cgImage: image,
                    size: NSSize(width: image.width, height: image.height)
                )
                self.storeThumbnail(thumbnail, key: key)
                self.reloadNameCell(for: url)
            }
        }
    }

    private func storeThumbnail(_ image: NSImage, key: String, persist: Bool = true) {
        if thumbnailCache.count >= 320 {
            for staleKey in Array(thumbnailCache.keys.prefix(80)) {
                thumbnailCache.removeValue(forKey: staleKey)
            }
        }
        thumbnailCache[key] = image
        if persist {
            ThumbnailDiskCache.shared.store(image, for: key)
        }
    }

    private func cancelThumbnailRequests(except allowedKeys: Set<String>) {
        let keysToCancel = pendingThumbnailKeys.subtracting(allowedKeys)
        guard !keysToCancel.isEmpty else { return }
        for key in keysToCancel {
            thumbnailOperations.removeValue(forKey: key)?.cancel()
            if let request = quickLookRequests.removeValue(forKey: key) {
                QLThumbnailGenerator.shared.cancel(request)
            }
            if let generator = videoThumbnailGenerators.removeValue(forKey: key) {
                generator.cancelAllCGImageGeneration()
            }
            pendingThumbnailKeys.remove(key)
        }
    }

    private func downsampledImage(at url: URL, maxPixelSize: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private func reloadNameCell(for url: URL) {
        guard let index = filteredIndexByPath[url.path] else { return }
        let rows = IndexSet(integer: index)
        if viewMode == .largeIcons {
            for cell in gridItemViews where cell.itemIndex == index {
                let item = filteredItems[cell.itemIndex]
                cell.configure(
                    item: item,
                    image: displayImage(for: item, size: visibleIconSize),
                    imageSize: visibleIconSize,
                    selected: gridSelectionIndexes.contains(cell.itemIndex),
                    cut: FPCutFileState.shared.contains(item.url)
                )
            }
        } else {
            tableView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
        }
    }

    private func thumbnailKey(for item: FileItem, size: CGFloat) -> String {
        let modified = Int64((item.modified ?? .distantPast).timeIntervalSince1970)
        return "\(item.url.standardizedFileURL.path)|\(modified)|\(Int(size.rounded()))"
    }

    private func isImageFile(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "heic", "heif", "webp", "gif", "tiff", "tif", "bmp"].contains(url.pathExtension.lowercased())
    }

    private func isVideoFile(_ url: URL) -> Bool {
        ["mp4", "mov", "m4v", "avi", "mkv", "webm"].contains(url.pathExtension.lowercased())
    }

    private func centerCroppedThumbnail(from source: NSImage, size: CGFloat) -> NSImage {
        let target = NSSize(width: size, height: size)
        let sourceSize = resolvedImageSize(source)
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            source.size = target
            return source
        }

        let scale = max(size / sourceSize.width, size / sourceSize.height)
        let drawSize = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let drawRect = NSRect(
            x: (size - drawSize.width) / 2,
            y: (size - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )

        let output = NSImage(size: target)
        output.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        let clip = NSBezierPath(roundedRect: NSRect(origin: .zero, size: target), xRadius: min(10, size * 0.12), yRadius: min(10, size * 0.12))
        clip.addClip()
        source.draw(in: drawRect, from: NSRect(origin: .zero, size: sourceSize), operation: .sourceOver, fraction: 1)
        output.unlockFocus()
        return output
    }

    private func resolvedImageSize(_ image: NSImage) -> NSSize {
        if image.size.width > 0, image.size.height > 0 {
            return image.size
        }
        if let representation = image.representations.first {
            return NSSize(width: representation.pixelsWide, height: representation.pixelsHigh)
        }
        return .zero
    }

    private func folderColorOptions() -> [(title: String, key: String?)] {
        [("По умолчанию", nil)] + FPTag.all.map { ($0.title, $0.key) }
    }

    private func folderColorMap() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: "FolderColors") as? [String: String] ?? [:]
    }

    private func folderColor(for url: URL) -> NSColor? {
        guard let name = folderColorMap()[url.path] else { return nil }
        switch name {
        case let key where FPTag.color(for: key) != nil:
            return FPTag.color(for: key)
        case "teal":
            return FPStyle.accent
        case "pink":
            return NSColor(calibratedRed: 0.92, green: 0.30, blue: 0.58, alpha: 1)
        default:
            return nil
        }
    }

    private func coloredFolderIcon(color: NSColor, size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let rect = NSRect(x: size * 0.06, y: size * 0.15, width: size * 0.88, height: size * 0.62)
        let tabRect = NSRect(x: size * 0.10, y: size * 0.62, width: size * 0.38, height: size * 0.20)
        color.withAlphaComponent(0.88).setFill()
        NSBezierPath(roundedRect: tabRect, xRadius: max(2, size * 0.08), yRadius: max(2, size * 0.08)).fill()
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: max(3, size * 0.10), yRadius: max(3, size * 0.10)).fill()
        NSColor.black.withAlphaComponent(0.22).setStroke()
        NSBezierPath(roundedRect: rect, xRadius: max(3, size * 0.10), yRadius: max(3, size * 0.10)).stroke()
        image.unlockFocus()
        return image
    }

    private func textCell(identifier: String, text: String, alignment: NSTextAlignment) -> NSTextField {
        let viewID = NSUserInterfaceItemIdentifier(identifier)
        if let field = tableView.makeView(withIdentifier: viewID, owner: self) as? NSTextField {
            field.stringValue = text
            field.alignment = alignment
            return field
        }

        let field = NSTextField(labelWithString: text)
        field.identifier = viewID
        field.font = .systemFont(ofSize: 12)
        field.textColor = FPStyle.text
        field.lineBreakMode = .byTruncatingMiddle
        field.alignment = alignment
        return field
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
