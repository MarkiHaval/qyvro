import Cocoa
import Quartz
import QuickLookThumbnailing
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import AVFoundation
final class FilePanel: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSSearchFieldDelegate {
    struct GridItemPosition {
        let sectionIndex: Int
        let position: Int
    }

    struct GridSectionLayout {
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
        /// Свёрнутый ряд листается вбок и живёт со своим сдвигом.
        let isHorizontal: Bool
        let horizontalOffset: CGFloat
        let horizontalExtent: CGFloat
    }

    struct GridLayout {
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

    struct GridScrollState {
        let topOffset: CGFloat
        let anchorPath: String?
        let anchorOffsetFromViewportTop: CGFloat
    }

    struct FolderViewState {
        let gridScroll: GridScrollState?
        let tableOrigin: NSPoint
        let selectedPaths: Set<String>
        let selectionAnchorPath: String?
    }

    struct HistoryEntry: Equatable {
        let url: URL
        let tagKey: String?
        let tagTitle: String?
        var isRecents: Bool = false
    }

    let pathField = CenteredTextField()
    let breadcrumbPathView = FPBreadcrumbPathView()
    let pathContainer = NSView()
    let searchField = NSSearchField()
    let tableView = PanelTableView()
    let tableScrollView = NSScrollView()
    let gridScrollView = FileGridScrollView()
    let gridContentView = FileGridCanvasView()
    let contentArea = NSView()
    let gridSelectionMarquee = FileSelectionMarqueeView()
    let footerLabel = NSTextField(labelWithString: "")
    let errorLabel = NSTextField(labelWithString: "")
    let viewScaleRail = ViewScaleRail()
    let viewModeToggleButton = NSButton()
    let viewScaleButton = HoverButton()
    let sortButton = SortPillButton()
    let filterButton = SortPillButton()
    var gridFilter: FPGridFilter = .all
    let swipeIndicator = SwipeNavigationIndicator(frame: NSRect(x: 0, y: 0, width: 66, height: 68))
    let swipeWaveOverlay = SwipeSurfaceWaveView()
    let sortOptions: [(title: String, key: String)] = [
        ("Имя", "name"),
        ("Создан", "created"),
        ("Тип", "kind"),
        ("Дата изменения", "modified"),
        ("Размер", "size")
    ]
    var modeButtons: [NSButton] = []
    var navToolbarButtons: [NSButton] = []
    let studioHeaderView = QyvroStudioHeaderView()
    let emptyStateView = QyvroEmptyStateView()
    let selectionActionBar = QyvroSelectionActionBar()
    let toastBanner = QyvroToastBanner()
    weak var classicTopRowView: NSView?
    weak var rootContentStack: NSStackView?
    var isStudioLayoutMode = false
    var floatingDockBottomClearance: CGFloat = 0
    var onStudioShowVolumesMenu: ((NSView) -> Void)?
    var onStudioShowBookmarksMenu: ((NSView) -> Void)?
    var onStudioShowTagsMenu: ((NSView) -> Void)?
    var onStudioSearchChanged: ((String) -> Void)?
    var onStudioToggleSearchScope: (() -> Void)?
    let fileManager = FileManager.default
    let dateFormatter = DateFormatter()

    var items: [FileItem] = []
    var filteredItems: [FileItem] = []
    var filteredIndexByPath: [String: Int] = [:]
    static let folderIconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        return cache
    }()
    var pendingThumbnailKeys = Set<String>()
    var thumbnailOperations: [String: Operation] = [:]
    var quickLookRequests: [String: QLThumbnailGenerator.Request] = [:]
    var videoThumbnailGenerators: [String: AVAssetImageGenerator] = [:]
    var gridScrollWorkItem: DispatchWorkItem?
    var gridItemViews: [FileGridCellView] = []
    var reusableGridItemViews: [FileGridCellView] = []
    var gridSectionHeaderViews: [String: GridSectionHeaderView] = [:]
    var gridSelectionIndexes = IndexSet()
    var gridSelectionAnchor: Int?
    var gridSelectionCursor: Int?
    var gridMarqueeBaseSelection = IndexSet()
    var typeSelectBuffer = ""
    var typeSelectUpdatedAt = Date.distantPast
    var gridColumnCount = 1
    var lastGridWidth: CGFloat = 0
    var isRebuildingGrid = false
    var resetGridScrollOnNextRebuild = false
    var renderedGridIndexes: [Int]?
    var renderedGridColumns = 0
    var renderedGridIconSize: CGFloat = 0
    var renderedGridItemCount = 0
    var renderedGridViewportWidth: CGFloat = 0
    var renderedGridContentHeight: CGFloat = 0
    /// Сдвиги свёрнутых рядов на момент последней перерисовки.
    var renderedSectionOffsets: [String: CGFloat] = [:]
    var pinchReloadWorkItem: DispatchWorkItem?
    var cachedGridLayout: GridLayout?
    var expandedGridSections = Set<String>()
    /// Сдвиг свёрнутого ряда по горизонтали, по идентификатору секции.
    var collapsedSectionOffsets: [String: CGFloat] = [:]
    /// Раскрытые стопки версий. Схлопывание включается в меню фильтра.
    var expandedVersionGroups = Set<String>()
    /// Сколько файлов скрыто под представителем, по пути представителя.
    var versionGroupCounts: [String: Int] = [:]
    /// Ступени отметки, изменённые в этом сеансе, по пути файла.
    ///
    /// Снимок папки кэшируется, и сразу после нажатия в нём ещё лежит прежняя
    /// ступень: в плитке был один цвет, а в просмотрщике, который читает файл
    /// напрямую, уже другой. Читать метки с диска на каждую плитку нельзя —
    /// при прокрутке это сотни обращений, — поэтому изменённое держится в
    /// памяти и имеет приоритет над кэшем.
    var flagLevelOverrides: [String: FPFinderTagStore.FlagLevel] = [:]
    var renameSheet: FPRenameSheet?
    var batchRenameController: FPBatchRenameController?
    var folderViewStates: [String: FolderViewState] = [:]
    var pendingFolderViewState: FolderViewState?
    var history: [HistoryEntry] = []
    var historyIndex = -1
    var isChangingHistory = false
    var iconSize: CGFloat = 48
    var viewMode: ExplorerViewMode = .list
    var virtualTagKey: String?
    var virtualTagTitle: String?
    var virtualSearchTitle: String?
    let horizontalSwipeTracker = HorizontalSwipeTracker()
    var iconResizeWorkItem: DispatchWorkItem?
    var gridResizeWorkItem: DispatchWorkItem?
    var swipeVisualResetWorkItem: DispatchWorkItem?
    var swipeEffectActive = false
    var historyTransitionGeneration = 0
    var activeHistoryTargetIndex: Int?
    var gridAppearAnimationPending = false
    var pendingSwipeDeltaX: CGFloat = 0
    var pendingGridWidth: CGFloat = 0
    var gridRelayoutScheduled = false
    var viewScalePopover: NSPopover?
    var viewScale: Double = 58
    var gridDataRevision = 0
    var cachedDateSections: (grouped: Bool, revision: Int, sections: [(id: String, title: String, indexes: [Int])])?
    var cachedGridPositions: (grouped: Bool, revision: Int, positions: [Int: GridItemPosition])?
    var loadGeneration = 0
    var isShowingLightweightDirectoryItems = false
    var activeDirectoryLoadURL: URL?
    var pendingDirectoryRefreshURL: URL?
    var recentItemsQuery: NSMetadataQuery?
    var recentItemsObservers: [NSObjectProtocol] = []
    var directoryWatcher: DispatchSourceFileSystemObject?
    var directoryWatchGeneration = 0
    var directoryRefreshWorkItem: DispatchWorkItem?
    var lastAutomaticRefresh = Date.distantPast
    var inspectorController: FileInspectorController?
    var folderPocketController: FolderPocketController?
    var transferController: FileTransferController?
    let cutPasteboardType = NSPasteboard.PasteboardType("com.qyvro.files.cut-files")
    let directoryLoadQueue = DispatchQueue(label: "Qyvro.DirectoryLoad", qos: .utility)
    let directoryWatchQueue = DispatchQueue(
        label: "Qyvro.DirectoryWatchOpen",
        qos: .utility,
        attributes: .concurrent
    )
    let imageLoadQueue: OperationQueue = {
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

    var tabIconSymbol: String {
        if isRecentItemsView { return "clock.arrow.circlepath" }
        if virtualTagTitle != nil { return "tag.fill" }
        if virtualSearchTitle != nil { return "magnifyingglass" }
        let standardized = currentURL.standardizedFileURL
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL
        if standardized == home { return "house.fill" }
        if standardized == home.appendingPathComponent("Downloads") { return "arrow.down.circle.fill" }
        if standardized == home.appendingPathComponent("Documents") { return "doc.text.fill" }
        if standardized == home.appendingPathComponent("Desktop") { return "menubar.rectangle" }
        if standardized == home.appendingPathComponent("Pictures") { return "photo.fill" }
        if standardized == home.appendingPathComponent("Movies") { return "film.fill" }
        if standardized.path == "/Applications" { return "app.badge.fill" }
        if standardized.path == "/" { return "internaldrive.fill" }
        if FPDiskUsage.isEjectableVolume(at: standardized) { return "externaldrive.fill" }
        return "folder.fill"
    }

    var isRecentItemsView: Bool {
        virtualSearchTitle == "Недавние"
    }

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
        iconSize = storedIconSize > 0 ? min(max(CGFloat(storedIconSize), 48), 144) : 108
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
        stopRecentItemsQuery()
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
        case 51 where event.modifierFlags.contains(.command):
            trashSelection(nil)
        case 49:
            quickLookSelection(nil)
        case 53:
            handleEscapeKey()
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
            moveGridSelection(direction: .left, extendingRange: event.modifierFlags.contains(.shift))
        case 124 where !event.modifierFlags.contains(.command):
            moveGridSelection(direction: .right, extendingRange: event.modifierFlags.contains(.shift))
        case 126 where !event.modifierFlags.contains(.command):
            moveGridSelection(direction: .up, extendingRange: event.modifierFlags.contains(.shift))
        case 125 where !event.modifierFlags.contains(.command):
            moveGridSelection(direction: .down, extendingRange: event.modifierFlags.contains(.shift))
        case 123 where event.modifierFlags.contains(.command):
            navigateHistoryWithWave(goesBack: true)
        case 124 where event.modifierFlags.contains(.command):
            navigateHistoryWithWave(goesBack: false)
        case 126 where event.modifierFlags.contains(.command):
            goUp(nil)
        case 120:
            renameSelection(nil)
        default:
            if handleGridTypeSelect(event) { return }
            super.keyDown(with: event)
        }
    }

    func handleEscapeKey() {
        if folderPocketController?.isVisible == true {
            folderPocketController?.closePocket()
            return
        }
        if !searchField.stringValue.isEmpty {
            searchField.stringValue = ""
            onStudioSearchChanged?("")
            applyFilter()
            return
        }
        if gridFilter != .all {
            applyFilterFromSidebar(.all)
            return
        }
        clearSelection()
    }

    func clearSelection() {
        if viewMode == .largeIcons {
            guard !gridSelectionIndexes.isEmpty else { return }
            gridSelectionIndexes.removeAll()
            gridSelectionAnchor = nil
            gridSelectionCursor = nil
            updateGridSelection()
            footerLabel.stringValue = footerText()
            notifySelectionChanged()
        } else {
            guard !tableView.selectedRowIndexes.isEmpty else { return }
            tableView.deselectAll(nil)
            footerLabel.stringValue = footerText()
            notifySelectionChanged()
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

    @objc func themeChanged(_ notification: Notification) {
        let aurora = FPStyle.isObsidianAurora
        Self.folderIconCache.removeAllObjects()
        FPFolderIconRenderer.invalidateCache()
        layer?.backgroundColor = NSColor.clear.cgColor
        pathField.layer?.backgroundColor = FPStyle.field.cgColor
        pathField.textColor = aurora ? FPStyle.text : FPStyle.orange
        pathField.font = FPStyle.isCyberEditorial
            ? FPStyle.bodyFont(ofSize: 13, weight: .semibold)
            : (aurora ? .systemFont(ofSize: 13, weight: .medium) : .monospacedSystemFont(ofSize: 13, weight: .medium))
        pathField.layer?.cornerRadius = FPStyle.isCyberEditorial ? 5 : (aurora ? 10 : 12)
        breadcrumbPathView.refreshTheme()
        searchField.layer?.backgroundColor = FPStyle.field.cgColor
        searchField.font = FPStyle.bodyFont(ofSize: 12.5, weight: .medium)
        searchField.layer?.cornerRadius = FPStyle.isCyberEditorial ? 5 : 9
        for btn in navToolbarButtons {
            btn.contentTintColor = aurora ? FPStyle.dimText : FPStyle.orange
            btn.layer?.backgroundColor = (aurora ? FPStyle.control : FPStyle.controlStrong).cgColor
            btn.layer?.cornerRadius = FPStyle.isCyberEditorial ? 5 : 9
            btn.layer?.borderColor = (aurora ? NSColor.white.withAlphaComponent(0.08) : FPStyle.stroke).cgColor
        }
        tableView.backgroundColor = .clear
        tableScrollView.backgroundColor = .clear
        tableScrollView.layer?.backgroundColor = NSColor.clear.cgColor
        gridScrollView.backgroundColor = .clear
        gridScrollView.layer?.backgroundColor = NSColor.clear.cgColor
        gridContentView.layer?.backgroundColor = NSColor.clear.cgColor
        sortButton.needsDisplay = true
        filterButton.needsDisplay = true
        let auroraTint = FPStyle.text.blended(withFraction: 0.22, of: FPStyle.accent) ?? FPStyle.text
        footerLabel.font = aurora
            ? FPStyle.monoMetaFont(ofSize: 10.5, weight: .regular)
            : .systemFont(ofSize: 11)
        footerLabel.textColor = FPStyle.dimText.withAlphaComponent(aurora ? 0.80 : 1.0)
        viewScaleButton.font = aurora
            ? FPStyle.monoMetaFont(ofSize: 10.5, weight: .medium)
            : .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        viewScaleButton.contentTintColor = aurora ? FPStyle.text : FPStyle.orange
        viewScaleButton.layer?.backgroundColor = (aurora ? auroraTint.withAlphaComponent(0.055) : FPStyle.controlStrong).cgColor
        viewScaleButton.layer?.borderColor = (aurora ? auroraTint.withAlphaComponent(0.09) : FPStyle.stroke).cgColor
        viewScaleButton.layer?.cornerRadius = aurora ? 8 : 7
        studioHeaderView.applyTheme()
        emptyStateView.applyTheme()
        selectionActionBar.applyTheme()
        toastBanner.applyTheme()
        syncStudioHeader()
        updateViewScaleButton()
        updateTableRowHeight()
        tableView.headerView?.needsDisplay = true
        tableView.reloadData()
        invalidateGridRenderCache()
        rebuildGridViews()
    }

    func setFloatingDockClearance(_ clearance: CGFloat) {
        floatingDockBottomClearance = clearance
        updateContentStackInsets()
    }

    func setStudioMode(_ enabled: Bool) {
        isStudioLayoutMode = enabled
        studioHeaderView.isHidden = !enabled
        classicTopRowView?.isHidden = enabled && pathField.isHidden
        updateContentStackInsets()
        syncStudioHeader()
    }

    private func updateContentStackInsets() {
        if isStudioLayoutMode {
            rootContentStack?.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 10, right: 16)
        } else {
            rootContentStack?.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8 + floatingDockBottomClearance, right: 10)
        }
    }

    func syncStudioHeader() {
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL
        let title: String
        let parentSubtitle: String?
        if isRecentItemsView {
            title = "Недавние"
            parentSubtitle = nil
        } else if let virtualSearchTitle {
            title = virtualSearchTitle
            parentSubtitle = nil
        } else if let virtualTagTitle {
            title = virtualTagTitle
            parentSubtitle = "Теги"
        } else {
            let std = currentURL.standardizedFileURL
            if std.path == home.path {
                title = "Дом"
                parentSubtitle = nil
            } else if std.path == "/" {
                title = "Macintosh HD"
                parentSubtitle = nil
            } else {
                title = std.lastPathComponent
                let parent = std.deletingLastPathComponent().standardizedFileURL
                if parent.path == home.path {
                    parentSubtitle = "Дом"
                } else if parent.path == "/" {
                    parentSubtitle = "Macintosh HD"
                } else {
                    parentSubtitle = parent.lastPathComponent
                }
            }
        }
        studioHeaderView.updateTitle(
            title,
            parentSubtitle: parentSubtitle,
            itemCount: filteredItems.count,
            url: currentURL,
            isRecents: isRecentItemsView
        )
        studioHeaderView.updateFilter(gridFilter)
    }

    @objc func thumbnailCacheCleared(_ notification: Notification) {
        Self.folderIconCache.removeAllObjects()
        FPFolderIconRenderer.invalidateCache()
        cancelThumbnailRequests(except: [])
        tableView.reloadData()
        invalidateGridRenderCache()
        rebuildGridViews()
    }

    @objc func cutFileStateChanged(_ notification: Notification) {
        for cell in gridItemViews where filteredItems.indices.contains(cell.itemIndex) {
            cell.setCut(FPCutFileState.shared.contains(filteredItems[cell.itemIndex].url))
        }
        tableView.reloadData()
    }

    func activate() {
        onActivated?(self)
    }

    func buildUI() {
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
        breadcrumbPathView.onOpenInNewTab = { [weak self] url in
            self?.onOpenURLInNewTab?(url)
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
        let backBtn = symbolButton(
            "chevron.left",
            fallback: "<",
            tooltip: "Назад · удерживайте для истории",
            action: #selector(goBack(_:)),
            button: historyBackButton
        )
        let fwdBtn = symbolButton("chevron.right", fallback: ">", tooltip: "Вперёд", action: #selector(goForward(_:)))
        let upBtn = symbolButton("arrow.up", fallback: "Вверх", tooltip: "В родительскую папку", action: #selector(goUp(_:)))
        navToolbarButtons = [backBtn, fwdBtn, upBtn]
        let toolbar = NSStackView(views: navToolbarButtons)
        toolbar.orientation = .horizontal
        toolbar.spacing = 6
        toolbar.alignment = .centerY

        // Keep the path strip geometrically stable. NSStackView's gravity
        // distribution was shrinking the container to its text and moving it
        // across the row as the path length changed.
        let topRow = NSView()
        classicTopRowView = topRow
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
        contentArea.addSubview(emptyStateView)
        contentArea.addSubview(selectionActionBar)
        contentArea.addSubview(toastBanner)
        tableScrollView.translatesAutoresizingMaskIntoConstraints = false
        gridScrollView.translatesAutoresizingMaskIntoConstraints = false

        selectionActionBar.onCompare = { [weak self] in self?.quickLookSelection(nil) }
        selectionActionBar.onAddToShelf = { [weak self] in
            guard let self else { return }
            let urls = self.selectedItems.map(\.url)
            guard !urls.isEmpty else { return }
            QyvroDropShelfModule.shared.add(urls: urls, reveal: true)
            self.showToast("Добавлено на полку: \(urls.count)", symbol: "tray.and.arrow.down.fill")
        }
        selectionActionBar.onCompressZIP = { [weak self] in self?.compressSelectionToZIP(nil) }
        selectionActionBar.onBatchRename = { [weak self] in self?.batchRenameSelection(nil) }
        selectionActionBar.onTrash = { [weak self] in self?.trashSelection(nil) }
        selectionActionBar.onClearSelection = { [weak self] in self?.clearSelection() }

        NSLayoutConstraint.activate([
            tableScrollView.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            tableScrollView.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            tableScrollView.topAnchor.constraint(equalTo: contentArea.topAnchor),
            tableScrollView.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
            gridScrollView.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            gridScrollView.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            gridScrollView.topAnchor.constraint(equalTo: contentArea.topAnchor),
            gridScrollView.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
            emptyStateView.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            emptyStateView.topAnchor.constraint(equalTo: contentArea.topAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
            selectionActionBar.centerXAnchor.constraint(equalTo: contentArea.centerXAnchor),
            selectionActionBar.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor, constant: -14),
            toastBanner.centerXAnchor.constraint(equalTo: contentArea.centerXAnchor),
            toastBanner.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor, constant: -14)
        ])

        footerLabel.font = FPStyle.isObsidianAurora
            ? FPStyle.monoMetaFont(ofSize: 10.5, weight: .regular)
            : .systemFont(ofSize: 11)
        footerLabel.textColor = FPStyle.dimText.withAlphaComponent(FPStyle.isObsidianAurora ? 0.80 : 1.0)
        footerLabel.lineBreakMode = .byTruncatingTail
        footerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        errorLabel.font = FPStyle.bodyFont(ofSize: 11, weight: .medium)
        errorLabel.textColor = .systemRed
        errorLabel.lineBreakMode = .byTruncatingTail
        errorLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let sortControl = sortMenuControl()
        let filterControl = filterMenuControl()
        let sizeControl = iconSizeControl()
        let footerRow = NSStackView(
            views: [
                footerLabel, errorLabel, footerSpacer,
                filterControl, sortControl, sizeControl
            ]
        )
        footerRow.orientation = .horizontal
        footerRow.spacing = 8
        footerRow.alignment = .centerY

        studioHeaderView.isHidden = true
        studioHeaderView.onGoBack = { [weak self] in self?.goBack(nil) }
        studioHeaderView.onLongPressBack = { [weak self] btn in
            if let lp = btn as? FPLongPressButton {
                self?.showBackHistoryMenu(from: lp)
            }
        }
        studioHeaderView.onGoForward = { [weak self] in self?.goForward(nil) }
        studioHeaderView.onGoUp = { [weak self] in self?.goUp(nil) }
        studioHeaderView.onRequestPathEdit = { [weak self] in self?.focusPath() }
        studioHeaderView.onOpenRecents = { [weak self] in self?.showRecentItems() }
        studioHeaderView.onOpenURL = { [weak self] url in self?.navigate(to: url) }
        studioHeaderView.onMoveFilesToURL = { [weak self] urls, dest in
            self?.moveDroppedItems(urls, to: dest) ?? false
        }
        studioHeaderView.onShowVolumesMenu = { [weak self] anchor in self?.onStudioShowVolumesMenu?(anchor) }
        studioHeaderView.onShowBookmarksMenu = { [weak self] anchor in self?.onStudioShowBookmarksMenu?(anchor) }
        studioHeaderView.onShowTagsMenu = { [weak self] anchor in self?.onStudioShowTagsMenu?(anchor) }
        studioHeaderView.onPickFilter = { [weak self] filter in self?.applyFilterFromSidebar(filter) }
        studioHeaderView.onSearchTextChanged = { [weak self] text in self?.onStudioSearchChanged?(text) }
        studioHeaderView.onToggleSearchScope = { [weak self] in self?.onStudioToggleSearchScope?() }

        let content = NSStackView(views: [studioHeaderView, topRow, contentArea, footerRow])
        content.orientation = .vertical
        content.alignment = .width
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        content.translatesAutoresizingMaskIntoConstraints = false
        rootContentStack = content
        addSubview(content)
        addSubview(swipeIndicator)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentArea.heightAnchor.constraint(greaterThanOrEqualToConstant: 260)
        ])

        buildGrid()
        updateViewModeVisibility()
    }

    func updateModeButtons() {
        for button in modeButtons {
            let active = button.tag == viewMode.rawValue
            button.layer?.backgroundColor = (active ? FPStyle.orangeFill : NSColor.clear).cgColor
            button.contentTintColor = active ? .white : FPStyle.dimText
        }
    }

    func iconSizeControl() -> NSView {
        viewScaleButton.target = self
        viewScaleButton.action = #selector(showViewScalePopover(_:))
        viewScaleButton.onHover = { [weak self, weak viewScaleButton] in
            guard let self, let viewScaleButton, self.viewScalePopover?.isShown != true else { return }
            self.showViewScalePopover(viewScaleButton)
        }
        let aurora = FPStyle.isObsidianAurora
        let auroraTint = FPStyle.text.blended(withFraction: 0.22, of: FPStyle.accent) ?? FPStyle.text
        viewScaleButton.bezelStyle = .inline
        viewScaleButton.isBordered = false
        viewScaleButton.font = aurora
            ? FPStyle.monoMetaFont(ofSize: 10.5, weight: .medium)
            : .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        viewScaleButton.contentTintColor = aurora ? FPStyle.text : FPStyle.orange
        viewScaleButton.imagePosition = .imageLeading
        viewScaleButton.wantsLayer = true
        viewScaleButton.layer?.cornerRadius = aurora ? 8 : 7
        viewScaleButton.layer?.backgroundColor = (aurora ? auroraTint.withAlphaComponent(0.055) : FPStyle.controlStrong).cgColor
        viewScaleButton.layer?.borderColor = (aurora ? auroraTint.withAlphaComponent(0.09) : FPStyle.stroke).cgColor
        viewScaleButton.layer?.borderWidth = 0.5
        viewScaleButton.heightAnchor.constraint(equalToConstant: 26).isActive = true
        viewScaleButton.widthAnchor.constraint(equalToConstant: 102).isActive = true
        updateViewScaleButton()
        return viewScaleButton
    }

    func updateViewModeToggleButton() {
        let symbol = viewMode == .largeIcons ? "list.bullet" : "square.grid.2x2"
        let tooltip = viewMode == .largeIcons ? "Показать списком" : "Показать плиткой"
        if #available(macOS 11.0, *) {
            viewModeToggleButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        } else {
            viewModeToggleButton.title = viewMode == .largeIcons ? "≡" : "▦"
        }
        viewModeToggleButton.toolTip = tooltip
    }

    func sortMenuControl() -> NSView {
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

    func filterMenuControl() -> NSView {
        filterButton.target = self
        filterButton.action = #selector(showFilterMenu(_:))
        filterButton.sendAction(on: [.leftMouseDown])
        filterButton.toolTip = "Фильтр ленты"
        filterButton.isBordered = false
        filterButton.isTransparent = false
        filterButton.bezelStyle = .inline
        filterButton.alignment = .left
        filterButton.translatesAutoresizingMaskIntoConstraints = false
        filterButton.widthAnchor.constraint(equalToConstant: 108).isActive = true
        filterButton.heightAnchor.constraint(equalToConstant: 26).isActive = true
        syncFilterControl()
        return filterButton
    }

    func syncFilterControl() {
        filterButton.title = gridFilter.shortTitle
        // Активный фильтр подсвечен: иначе легко забыть, что лента урезана, и
        // решить, что файлы пропали.
        filterButton.contentTintColor = gridFilter == .all ? FPStyle.text : FPStyle.orange
        filterButton.needsDisplay = true
        studioHeaderView.updateFilter(gridFilter)
    }

    @objc func showFilterMenu(_ sender: Any?) {
        let menu = NSMenu()
        for option in FPGridFilter.allCases {
            let item = menu.addItem(
                withTitle: option.title,
                action: #selector(applyGridFilter(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = option.rawValue
            item.state = option == gridFilter ? .on : .off
            if option == .flaggedToday { menu.addItem(.separator()) }
        }
        menu.addItem(.separator())
        let collapse = menu.addItem(
            withTitle: "Схлопывать версии файлов",
            action: #selector(toggleVersionCollapsing(_:)),
            keyEquivalent: ""
        )
        collapse.target = self
        collapse.state = FPPreferences.collapsesFileVersions ? .on : .off
        collapse.toolTip = "Оригинал, уменьшенная копия и её JPEG показываются одной стопкой"
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: filterButton.bounds.height + 4),
            in: filterButton
        )
    }

    @objc func toggleVersionCollapsing(_ sender: Any?) {
        let next = !FPPreferences.collapsesFileVersions
        UserDefaults.standard.set(next, forKey: "CollapseFileVersions")
        expandedVersionGroups.removeAll()
        FPActionLog.action("схлопывание версий → \(next ? "включено" : "выключено")")
        loadCurrentDirectory(asynchronously: true, preservingGridPosition: true)
    }

    /// Фильтр, выбранный в панели занятости диска слева.
    func applyFilterFromSidebar(_ filter: FPGridFilter) {
        FPActionLog.action("занятость диска → \(filter.title)")
        gridFilter = filter
        syncFilterControl()
        loadCurrentDirectory(asynchronously: true, preservingGridPosition: true)
    }

    @objc func applyGridFilter(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let option = FPGridFilter(rawValue: raw) else { return }
        FPActionLog.action("фильтр → \(option.title)")
        gridFilter = option
        syncFilterControl()
        loadCurrentDirectory(asynchronously: true, preservingGridPosition: true)
    }

    func buildTable() {
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
        tableView.rowHeight = FPStyle.isObsidianAurora ? 30 : 26
        // Собственная бесшовная шапка и стиль `.plain` убирают системную серую
        // капсулу, чёрные «заглушки» по краям и нижний горизонтальный скроллбар.
        tableView.headerView = QyvroTableHeaderView(frame: NSRect(x: 0, y: 0, width: 640, height: 28))
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        if #available(macOS 11.0, *) {
            tableView.style = .plain
        }

        addColumn(identifier: "name", title: "Имя", width: 300)
        addColumn(identifier: "size", title: "Размер", width: 96)
        addColumn(identifier: "created", title: "Создан", width: 148)
        addColumn(identifier: "modified", title: "Изменён", width: 148)
        addColumn(identifier: "kind", title: "Тип", width: 126)
        tableView.sortDescriptors = [NSSortDescriptor(key: "created", ascending: false)]
        updateTableRowHeight()

        FPConfigurePrimaryScroller(tableScrollView)
        tableScrollView.hasHorizontalScroller = false
        tableScrollView.documentView = tableView
        tableScrollView.borderType = .noBorder
        tableScrollView.drawsBackground = false
        tableScrollView.backgroundColor = .clear
        tableScrollView.wantsLayer = true
        tableScrollView.layer?.cornerRadius = 10
        tableScrollView.layer?.masksToBounds = true
    }

    func buildGrid() {
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
        gridScrollView.onSectionScroll = { [weak self] point, delta in
            self?.scrollCollapsedSection(at: point, by: delta) ?? false
        }
        gridScrollView.onMagnify = { [weak self] amount in
            self?.applyPinchScale(amount)
        }
        gridScrollView.onZoomScroll = { [weak self] delta in
            // Шаг подбирается пользователем: у разных мышей щелчок колеса даёт
            // очень разную величину, единого правильного числа нет.
            self?.applyPinchScale(delta * 0.006 * CGFloat(FPPreferences.wheelZoomSensitivity))
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

    func addColumn(identifier: String, title: String, width: CGFloat) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        let headerCell = FPTableHeaderCell(textCell: title)
        headerCell.columnAlignment = identifier == "size" ? .right : .left
        column.headerCell = headerCell
        column.width = width
        column.minWidth = identifier == "name" ? 140 : (identifier == "size" ? 72 : 96)
        column.resizingMask = identifier == "name" ? [.autoresizingMask, .userResizingMask] : [.userResizingMask]
        column.sortDescriptorPrototype = NSSortDescriptor(key: identifier, ascending: true)
        tableView.addTableColumn(column)
    }

    func symbolButton(
        _ symbol: String,
        fallback: String,
        tooltip: String,
        action: Selector,
        button: NSButton = NSButton()
    ) -> NSButton {
        let aurora = FPStyle.isObsidianAurora
        if #available(macOS 11.0, *), let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) {
            image.size = NSSize(width: 15, height: 15)
            button.image = image
            button.title = ""
        } else {
            button.title = fallback
            button.font = .systemFont(ofSize: 11, weight: .medium)
        }
        button.bezelStyle = .inline
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = aurora ? FPStyle.dimText : FPStyle.orange
        button.toolTip = tooltip
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.wantsLayer = true
        button.layer?.backgroundColor = (aurora ? FPStyle.control : FPStyle.controlStrong).cgColor
        button.layer?.cornerRadius = FPStyle.isCyberEditorial ? 5 : 9
        button.layer?.borderColor = (aurora ? NSColor.white.withAlphaComponent(0.08) : FPStyle.stroke).cgColor
        button.layer?.borderWidth = 0.5
        button.widthAnchor.constraint(equalToConstant: 32).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }

    var visibleIconSize: CGFloat {
        switch viewMode {
        case .list:
            return FPStyle.isObsidianAurora ? 22 : 18
        case .smallIcons:
            return min(max(iconSize, 24), 56)
        case .largeIcons:
            return min(max(iconSize, 56), 144)
        }
    }

    func updateTableRowHeight() {
        switch viewMode {
        case .list:
            let base: CGFloat = FPStyle.isObsidianAurora ? 30 : 24
            tableView.rowHeight = base + CGFloat((min(viewScale, 28) / 28) * 18)
        case .smallIcons:
            tableView.rowHeight = visibleIconSize + 10
        case .largeIcons:
            tableView.rowHeight = visibleIconSize + 14
        }
    }

    func footerText() -> String {
        let selection = selectedItems
        let selected = selection.count
        let folders = filteredItems.filter { $0.isDirectory }.count
        let files = filteredItems.count - folders
        var text = "\(filteredItems.count) элементов - \(folders) папок - \(files) файлов"
        if selected > 0 {
            let selectedBytes = selection.reduce(Int64(0)) { partial, item in
                partial + (item.isDirectory ? 0 : (item.size ?? 0))
            }
            if selectedBytes > 0 {
                text += " - выбрано \(selected) (\(byteString(selectedBytes)))"
            } else {
                text += " - выбрано \(selected)"
            }
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

    func showError(_ message: String) {
        errorLabel.stringValue = message
    }

    func showToast(_ message: String, symbol: String = "checkmark.circle.fill", withUndo: Bool = false) {
        if withUndo && QyvroFileOperationHistory.shared.canUndo {
            toastBanner.show(message: message, symbol: symbol, undoTitle: "Отменить ⌘Z") { [weak self] in
                QyvroFileOperationHistory.shared.performUndo { result in
                    switch result {
                    case .success(let dirs):
                        dirs.forEach { DirectorySnapshotCache.shared.invalidate($0) }
                        self?.refreshCurrentDirectory(force: true)
                        self?.showToast("Действие отменено", symbol: "arrow.uturn.backward.circle.fill")
                    case .failure(let err):
                        self?.showError(err.localizedDescription)
                    }
                }
            }
        } else {
            toastBanner.show(message: message, symbol: symbol)
        }
    }

    func updateEmptyState(isLoading: Bool = false) {
        guard !isLoading, filteredItems.isEmpty else {
            emptyStateView.isHidden = true
            return
        }
        let hasQuery = !searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasQuery {
            emptyStateView.configure(
                symbol: "magnifyingglass",
                title: "Ничего не найдено",
                subtitle: "По запросу «\(searchField.stringValue)» нет совпадений в этой папке",
                actionTitle: "Очистить поиск"
            )
            emptyStateView.onPrimaryAction = { [weak self] in
                self?.searchField.stringValue = ""
                self?.onStudioSearchChanged?("")
                self?.applyFilter()
            }
        } else if gridFilter != .all {
            emptyStateView.configure(
                symbol: "line.3.horizontal.decrease.circle",
                title: "Нет подходящих файлов",
                subtitle: "В этой папке нет объектов для выбранного фильтра «\(gridFilter.title)»",
                actionTitle: "Показать все"
            )
            emptyStateView.onPrimaryAction = { [weak self] in
                self?.applyFilterFromSidebar(.all)
            }
        } else if isRecentItemsView {
            emptyStateView.configure(
                symbol: "clock.arrow.circlepath",
                title: "Недавних файлов пока нет",
                subtitle: "Новые загрузки и созданные файлы появятся здесь автоматически",
                actionTitle: nil
            )
            emptyStateView.onPrimaryAction = nil
        } else if virtualTagTitle != nil {
            emptyStateView.configure(
                symbol: "tag",
                title: "Нет объектов с этим тегом",
                subtitle: "Перетащи файлы или папки на тег, чтобы собрать их здесь",
                actionTitle: nil
            )
            emptyStateView.onPrimaryAction = nil
        } else if virtualSearchTitle != nil {
            emptyStateView.configure(
                symbol: "magnifyingglass",
                title: "На Mac ничего не найдено",
                subtitle: "Попробуй изменить запрос или искать внутри текущей папки",
                actionTitle: nil
            )
            emptyStateView.onPrimaryAction = nil
        } else {
            emptyStateView.configure(
                symbol: "folder",
                title: "Папка пуста",
                subtitle: "Перетащи сюда файлы или создай новую папку",
                actionTitle: "Новая папка"
            )
            emptyStateView.onPrimaryAction = { [weak self] in
                self?.newFolder(nil)
            }
        }
        emptyStateView.isHidden = false
    }

    func updateViewModeVisibility() {
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

    @objc func toggleViewMode(_ sender: Any?) {
        activate()
        viewMode = viewMode == .largeIcons ? .list : .largeIcons
        UserDefaults.standard.set(viewMode.rawValue, forKey: "ViewMode")
        updateViewModeVisibility()
    }

    func toggleViewModeFromCommand() {
        applyViewScale(viewMode == .largeIcons ? 18 : 58, reload: true)
    }

    @objc func showViewScalePopover(_ sender: NSButton) {
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

    /// Щипок двумя пальцами меняет размер значков.
    ///
    /// Перерисовка сетки на каждое событие жеста слишком дорога, поэтому
    /// шкала копится, а тяжёлая часть выполняется по завершении серии — жест
    /// остаётся плавным, а сетка не перестраивается сотни раз в секунду.
    func applyPinchScale(_ amount: CGFloat) {
        let next = min(max(viewScale + Double(amount) * 42, 0), 100)
        guard abs(next - viewScale) > 0.01 else { return }
        applyViewScale(next, reload: false)
        viewScaleRail.value = next
        pinchReloadWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.updateViewModeVisibility()
            FPActionLog.action("щипок: масштаб \(Int(self.viewScale))")
        }
        pinchReloadWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    @objc func viewScaleChanged(_ sender: Any?) {
        applyViewScale(viewScaleRail.value, reload: true)
    }

    func applyViewScale(_ newValue: Double, reload: Bool) {
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
        if virtualTagTitle == nil && virtualSearchTitle == nil {
            FPFolderProfileStore.shared.record(for: currentURL, viewScale: viewScale)
        }
        updateViewScaleButton()
        if oldMode != viewMode {
            // Переключение между списком и плитками обязано сразу обновлять
            // видимость `tableScrollView`/`gridScrollView`, даже при щипке
            // (`reload == false`), иначе плитки очищались, а список оставался скрыт.
            updateViewModeVisibility()
            return
        }
        guard reload else { return }
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

    func updateViewScaleButton() {
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
        if isStudioLayoutMode {
            classicTopRowView?.isHidden = false
        }
        pathField.stringValue = virtualTagTitle == nil ? currentURL.path : pathField.stringValue
        breadcrumbPathView.isHidden = true
        pathField.isHidden = false
        window?.makeFirstResponder(pathField)
        pathField.currentEditor()?.selectAll(nil)
    }

    func finishPathEditing() {
        pathField.isHidden = true
        breadcrumbPathView.isHidden = false
        if isStudioLayoutMode {
            classicTopRowView?.isHidden = true
        }
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
    func setFieldFocusGlow(_ field: NSTextField, active: Bool) {
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

    @objc func pathSubmitted(_ sender: NSTextField) {
        navigateToPath(from: sender)
        finishPathEditing()
        focusFiles()
    }

    func navigateToPath(from field: NSTextField) {
        let path = (field.stringValue as NSString).expandingTildeInPath
        navigate(to: URL(fileURLWithPath: path))
    }
}
