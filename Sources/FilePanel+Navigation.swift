import Cocoa
import UniformTypeIdentifiers

extension FilePanel {
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

    func installSwipeWaveOverlay() -> (host: NSView, rect: NSRect) {
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

    func canNavigateHistory(from index: Int, goesBack: Bool) -> Bool {
        let target = index + (goesBack ? -1 : 1)
        return target >= 0 && target < history.count
    }

    @discardableResult
    func appendParallelHistoryTransition(
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

    func isValidHistoryTarget(at index: Int) -> Bool {
        guard index >= 0, index < history.count else { return false }
        let entry = history[index]
        if let archiveURL = entry.archiveURL {
            return fileManager.fileExists(atPath: archiveURL.path)
        }
        if entry.isRecents || entry.tagTitle != nil {
            return true
        }
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: entry.url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    func loadActiveHistoryTarget(
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

    func finishHistoryTransition(generation: Int) {
        guard historyTransitionGeneration == generation else { return }
        swipeEffectActive = false
        activeHistoryTargetIndex = nil
        imageLoadQueue.isSuspended = false
    }

    @discardableResult
    func performAnimatedHistoryNavigation(goesBack: Bool, deltaX: CGFloat) -> Bool {
        guard !swipeEffectActive else { return false }
        let targetIndex = historyIndex + (goesBack ? -1 : 1)
        guard isValidHistoryTarget(at: targetIndex) else { return false }
        return startAnimatedHistoryTransition(
            targetIndex: targetIndex,
            deltaX: deltaX
        )
    }

    @discardableResult
    func startAnimatedHistoryTransition(
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

    func positionSwipeIndicator() {
        let travel = (1 - swipeIndicator.progress) * 15
        let x = swipeIndicator.goesBack
            ? -34 - travel
            : bounds.width - 32 + travel
        swipeIndicator.frame.origin = NSPoint(
            x: x,
            y: max(52, bounds.midY - swipeIndicator.frame.height / 2)
        )
    }

    func navigate(to url: URL, addingToHistory: Bool = true, loadCompletion: (() -> Void)? = nil) {
        activate()
        stopRecentItemsQuery()
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
            && virtualArchiveURL == nil
            && currentURL.standardizedFileURL == resolved.standardizedFileURL

        if !isSameDirectory {
            let previousPath = currentURL.standardizedFileURL.path
            let resolvedParentPath = resolved.deletingLastPathComponent().standardizedFileURL.path
            if resolvedParentPath == previousPath {
                parentSortHints[previousPath] = (currentSortKey, currentSortAscending)
            }
            saveCurrentFolderViewState()
            pendingFolderViewState = folderViewStates[resolved.standardizedFileURL.path]
            applySavedFolderProfileIfPresent(for: resolved)
        }
        virtualTagKey = nil
        virtualTagTitle = nil
        virtualSearchTitle = nil
        virtualArchiveURL = nil
        virtualArchiveInternalPath = ""
        virtualArchiveEntryByURL = [:]
        currentURL = resolved
        QyvroRecentFoldersStore.shared.record(resolved)
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
        stopRecentItemsQuery()
        stopWatchingCurrentDirectory()
        virtualTagKey = tagKey
        virtualTagTitle = title
        virtualSearchTitle = nil
        virtualArchiveURL = nil
        virtualArchiveInternalPath = ""
        virtualArchiveEntryByURL = [:]
        pathField.stringValue = "\(L("Теги", "Tags")) / \(title)"
        breadcrumbPathView.updateVirtualPath("\(L("Теги", "Tags"))  ›  \(title)")
        searchField.stringValue = ""
        showError("")
        recordHistoryIfNeeded(HistoryEntry(url: currentURL, tagKey: tagKey, tagTitle: title), adding: addingToHistory)
        loadCurrentDirectory()
        onURLChanged?(self)
    }

    /// Виртуальная папка «Недавние»: все недавно созданные и загруженные файлы
    /// и папки на Mac, отсортированные строго от самых свежих сверху.
    ///
    /// Сначала мгновенно просматривает рабочие папки (`Downloads`, `Desktop`,
    /// `Documents`, `Pictures`, `Movies`, `~`), чтобы только что скачанный файл
    /// стал #1 ещё до индексации Spotlight, а затем дополняет выдачу индексом
    /// Spotlight за последние 14 дней по всей домашней папке.
    func showRecentItems(addingToHistory: Bool = true, loadCompletion: (() -> Void)? = nil) {
        activate()
        stopWatchingCurrentDirectory()
        stopRecentItemsQuery()
        virtualTagKey = nil
        virtualTagTitle = nil
        virtualArchiveURL = nil
        virtualArchiveInternalPath = ""
        virtualArchiveEntryByURL = [:]
        virtualSearchTitle = "Недавние"
        pathField.stringValue = L("Недавние файлы и папки", "Recent files & folders")
        breadcrumbPathView.updateVirtualPath(L("Недавние  ›  по дате создания", "Recents  ›  by date added"))
        searchField.stringValue = ""
        showError("")
        tableView.sortDescriptors = [NSSortDescriptor(key: "created", ascending: false)]
        syncSortControl()
        recordHistoryIfNeeded(
            HistoryEntry(url: currentURL, tagKey: nil, tagTitle: nil, isRecents: true),
            adding: addingToHistory
        )
        loadRecentItems(preservingGridPosition: false, completion: loadCompletion)
        onURLChanged?(self)
    }

    func stopRecentItemsQuery() {
        recentItemsQuery?.stop()
        recentItemsQuery = nil
        recentItemsObservers.forEach(NotificationCenter.default.removeObserver)
        recentItemsObservers.removeAll()
    }

    func loadRecentItems(preservingGridPosition: Bool = false, completion: (() -> Void)? = nil) {
        stopRecentItemsQuery()
        loadGeneration += 1
        let generation = loadGeneration
        let cutoff = Date().addingTimeInterval(-14 * 24 * 60 * 60)
        let includeHidden = showHiddenFiles

        // 1. Быстрый прямой проход по ключевым папкам (мгновенно ловит свежие
        // загрузки и новые папки ещё до обновления индекса Spotlight).
        directoryLoadQueue.async { [weak self] in
            guard let self else { return }
            let directItems = self.scanDirectRecentItems(cutoff: cutoff, includeHidden: includeHidden)
            DispatchQueue.main.async {
                guard self.loadGeneration == generation, self.isRecentItemsView else {
                    completion?()
                    return
                }
                self.items = directItems
                self.sortItems()
                self.applyFilter(preservingGridPosition: preservingGridPosition)
                completion?()
                self.startRecentSpotlightMerge(generation: generation, cutoff: cutoff, baseItems: directItems)
            }
        }
    }

    private func scanDirectRecentItems(cutoff: Date, includeHidden: Bool) -> [FileItem] {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser.standardizedFileURL
        let roots: [(url: URL, maxDepth: Int)] = [
            (home.appendingPathComponent("Downloads", isDirectory: true), 2),
            (home.appendingPathComponent("Desktop", isDirectory: true), 2),
            (home.appendingPathComponent("Documents", isDirectory: true), 2),
            (home.appendingPathComponent("Pictures", isDirectory: true), 2),
            (home.appendingPathComponent("Movies", isDirectory: true), 2),
            (home, 1)
        ]
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .fileSizeKey, .creationDateKey, .addedToDirectoryDateKey,
            .contentModificationDateKey, .localizedTypeDescriptionKey, .isHiddenKey, .tagNamesKey
        ]
        let keySet = Set(keys)
        var seen = Set<String>()
        var collected: [FileItem] = []

        func walk(_ folder: URL, depth: Int, maxDepth: Int) {
            guard depth <= maxDepth,
                  let urls = try? manager.contentsOfDirectory(
                      at: folder,
                      includingPropertiesForKeys: keys,
                      options: includeHidden ? [] : [.skipsHiddenFiles]
                  ) else { return }
            for url in urls {
                let path = url.standardizedFileURL.path
                guard seen.insert(path).inserted,
                      FPSpotlightSearch.isMeaningful(url),
                      let values = try? url.resourceValues(forKeys: keySet) else { continue }
                if !includeHidden, values.isHidden == true { continue }
                let isDir = values.isDirectory == true
                let effectiveCreated = max(
                    values.addedToDirectoryDate ?? .distantPast,
                    values.creationDate ?? .distantPast
                )
                if effectiveCreated >= cutoff {
                    let kind = localizedKind(for: url, isDirectory: isDir, fallback: values.localizedTypeDescription)
                    collected.append(FileItem(
                        url: url,
                        name: url.lastPathComponent,
                        isDirectory: isDir,
                        size: isDir ? nil : values.fileSize.map(Int64.init),
                        created: effectiveCreated,
                        modified: values.contentModificationDate,
                        kind: kind,
                        isHidden: values.isHidden == true,
                        finderTags: (values.tagNames?.isEmpty == false) ? FPFinderTagStore.tags(for: url) : []
                    ))
                }
                if isDir, depth < maxDepth, !url.pathExtension.lowercased().hasSuffix("app") {
                    walk(url, depth: depth + 1, maxDepth: maxDepth)
                }
            }
        }

        for root in roots where manager.fileExists(atPath: root.url.path) {
            walk(root.url, depth: 1, maxDepth: root.maxDepth)
        }
        collected.sort { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
        return Array(collected.prefix(320))
    }

    private func startRecentSpotlightMerge(generation: Int, cutoff: Date, baseItems: [FileItem]) {
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
            NSPredicate(format: "kMDItemFSCreationDate >= %@", cutoff as NSDate),
            NSPredicate(format: "kMDItemDateAdded >= %@", cutoff as NSDate)
        ])
        query.sortDescriptors = [
            NSSortDescriptor(key: NSMetadataItemFSCreationDateKey, ascending: false)
        ]

        let handleFinish: (Notification) -> Void = { [weak self] _ in
            guard let self, self.loadGeneration == generation, self.isRecentItemsView else { return }
            query.disableUpdates()
            var candidateURLs: [URL] = []
            for index in 0..<query.resultCount {
                guard let item = query.result(at: index) as? NSMetadataItem,
                      let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
                let url = URL(fileURLWithPath: path)
                guard FPSpotlightSearch.isMeaningful(url) else { continue }
                candidateURLs.append(url)
                if candidateURLs.count >= 450 { break }
            }
            self.stopRecentItemsQuery()
            let includeHidden = self.showHiddenFiles
            self.directoryLoadQueue.async { [weak self] in
                guard let self else { return }
                let keys: [URLResourceKey] = [
                    .isDirectoryKey, .fileSizeKey, .creationDateKey, .addedToDirectoryDateKey,
                    .contentModificationDateKey, .localizedTypeDescriptionKey, .isHiddenKey, .tagNamesKey
                ]
                let keySet = Set(keys)
                var byPath: [String: FileItem] = Dictionary(
                    uniqueKeysWithValues: baseItems.map { ($0.url.standardizedFileURL.path, $0) }
                )
                for url in candidateURLs {
                    let path = url.standardizedFileURL.path
                    guard byPath[path] == nil,
                          let values = try? url.resourceValues(forKeys: keySet) else { continue }
                    if !includeHidden, values.isHidden == true { continue }
                    let isDir = values.isDirectory == true
                    let effectiveCreated = max(
                        values.addedToDirectoryDate ?? .distantPast,
                        values.creationDate ?? .distantPast
                    )
                    guard effectiveCreated >= cutoff else { continue }
                    let kind = self.localizedKind(for: url, isDirectory: isDir, fallback: values.localizedTypeDescription)
                    byPath[path] = FileItem(
                        url: url,
                        name: url.lastPathComponent,
                        isDirectory: isDir,
                        size: isDir ? nil : values.fileSize.map(Int64.init),
                        created: effectiveCreated,
                        modified: values.contentModificationDate,
                        kind: kind,
                        isHidden: values.isHidden == true,
                        finderTags: (values.tagNames?.isEmpty == false) ? FPFinderTagStore.tags(for: url) : []
                    )
                }
                let merged = byPath.values
                    .sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
                    .prefix(320)
                let finalItems = Array(merged)
                DispatchQueue.main.async {
                    guard self.loadGeneration == generation, self.isRecentItemsView else { return }
                    self.items = finalItems
                    self.sortItems()
                    self.applyFilter(preservingGridPosition: true)
                }
            }
        }

        recentItemsObservers = [
            NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
                object: query,
                queue: .main,
                using: handleFinish
            )
        ]
        recentItemsQuery = query
        query.start()
    }

    func showSearchResults(_ urls: [URL], query: String) {
        activate()
        stopRecentItemsQuery()
        stopWatchingCurrentDirectory()
        loadGeneration += 1
        virtualTagKey = nil
        virtualTagTitle = nil
        virtualArchiveURL = nil
        virtualArchiveInternalPath = ""
        virtualArchiveEntryByURL = [:]
        virtualSearchTitle = "\(L("Поиск", "Search")): \(query)"
        pathField.stringValue = "\(L("Поиск на Mac", "Search Mac")) / \(query)"
        breadcrumbPathView.updateVirtualPath("\(L("Поиск на Mac", "Search Mac"))  ›  \(query)")
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

    func recordHistoryIfNeeded(_ entry: HistoryEntry, adding: Bool) {
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

    func openZipArchive(
        _ zipURL: URL,
        internalPath: String = "",
        addingToHistory: Bool = true,
        loadCompletion: (() -> Void)? = nil
    ) {
        let resolvedZip = zipURL.standardizedFileURL
        guard fileManager.fileExists(atPath: resolvedZip.path) else {
            showError(L("Архив не найден.", "Archive not found."))
            loadCompletion?()
            return
        }
        activate()
        stopRecentItemsQuery()
        stopWatchingCurrentDirectory()
        virtualTagKey = nil
        virtualTagTitle = nil
        virtualSearchTitle = nil
        virtualArchiveURL = resolvedZip
        let cleanInternal = internalPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        virtualArchiveInternalPath = cleanInternal
        currentURL = resolvedZip.deletingLastPathComponent()

        let crumbDisplay = cleanInternal.isEmpty
            ? "ZIP  ›  \(resolvedZip.lastPathComponent)"
            : "ZIP  ›  \(resolvedZip.lastPathComponent)  ›  \(cleanInternal.replacingOccurrences(of: "/", with: "  ›  "))"
        pathField.stringValue = cleanInternal.isEmpty ? resolvedZip.path : "\(resolvedZip.path) / \(cleanInternal)"
        breadcrumbPathView.updateVirtualPath(crumbDisplay)
        searchField.stringValue = ""
        showError("")

        recordHistoryIfNeeded(
            HistoryEntry(
                url: resolvedZip.deletingLastPathComponent(),
                tagKey: nil,
                tagTitle: nil,
                isRecents: false,
                archiveURL: resolvedZip,
                archiveInternalPath: cleanInternal
            ),
            adding: addingToHistory
        )

        loadGeneration += 1
        let generation = loadGeneration
        directoryLoadQueue.async { [weak self] in
            let entries = QyvroZipArchiveService.shared.listChildren(
                in: resolvedZip,
                internalDirectory: cleanInternal
            )
            var entryMap: [String: String] = [:]
            let syntheticRoot = URL(fileURLWithPath: "/.qyvro-zip/\(resolvedZip.lastPathComponent)", isDirectory: true)
            let builtItems: [FileItem] = entries.map { entry in
                let trimmed = entry.internalPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let itemURL = syntheticRoot.appendingPathComponent(trimmed, isDirectory: entry.isDirectory)
                entryMap[itemURL.path] = entry.internalPath
                let ext = itemURL.pathExtension.uppercased()
                let kind = entry.isDirectory
                    ? L("Папка в ZIP", "Folder in ZIP")
                    : (ext.isEmpty ? L("Файл в ZIP", "File in ZIP") : "\(ext) · ZIP")
                return FileItem(
                    url: itemURL,
                    name: entry.name,
                    isDirectory: entry.isDirectory,
                    size: entry.isDirectory ? nil : entry.uncompressedSize,
                    created: entry.modified,
                    modified: entry.modified,
                    kind: kind,
                    isHidden: entry.name.hasPrefix("."),
                    finderTags: []
                )
            }
            DispatchQueue.main.async {
                guard let self, self.loadGeneration == generation, self.virtualArchiveURL == resolvedZip else {
                    loadCompletion?()
                    return
                }
                self.virtualArchiveEntryByURL = entryMap
                self.items = builtItems
                self.sortItems()
                self.applyFilter(preservingGridPosition: false)
                self.onURLChanged?(self)
                loadCompletion?()
            }
        }
    }

    func applyHistoryEntry(_ entry: HistoryEntry, completion: (() -> Void)? = nil) {
        if let archiveURL = entry.archiveURL {
            openZipArchive(
                archiveURL,
                internalPath: entry.archiveInternalPath ?? "",
                addingToHistory: false,
                loadCompletion: completion
            )
        } else if entry.isRecents {
            currentURL = entry.url
            showRecentItems(addingToHistory: false, loadCompletion: completion)
        } else if let title = entry.tagTitle {
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
        if let archiveURL = virtualArchiveURL {
            openZipArchive(archiveURL, internalPath: virtualArchiveInternalPath, addingToHistory: false, loadCompletion: completion)
            return
        }
        if isRecentItemsView {
            loadRecentItems(preservingGridPosition: preservingGridPosition, completion: completion)
            return
        }
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
                updateEmptyState(isLoading: true)
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
        if isRecentItemsView {
            let now = Date()
            if force || now.timeIntervalSince(lastAutomaticRefresh) >= 1.2 {
                lastAutomaticRefresh = now
                loadRecentItems(preservingGridPosition: true)
            }
            return
        }
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

    func finishDirectoryLoad(for url: URL) {
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

    func startWatchingCurrentDirectory() {
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

    func stopWatchingCurrentDirectory() {
        directoryWatchGeneration &+= 1
        directoryRefreshWorkItem?.cancel()
        directoryRefreshWorkItem = nil
        directoryWatcher?.cancel()
        directoryWatcher = nil
    }

    func scheduleDirectoryRefresh(for watchedURL: URL) {
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

    func loadTaggedItems(keys: [URLResourceKey], preservingGridPosition: Bool = false) {
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

    func fileItem(for url: URL, keys: [URLResourceKey], includeHidden: Bool? = nil) -> FileItem? {
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

    func lightweightFileItem(for url: URL, includeHidden: Bool) -> FileItem? {
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

    func synchronizeFinderTagAssignments(from loaded: [FileItem]) {
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

    func localizedKind(for url: URL, isDirectory: Bool, fallback: String?) -> String {
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

    func sortItems() {
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

    var currentSortKey: String {
        tableView.sortDescriptors.first?.key ?? "created"
    }

    var currentSortAscending: Bool {
        tableView.sortDescriptors.first?.ascending ?? false
    }

    func syncSortControl() {
        let key = currentSortKey
        let title = sortOptions.first(where: { $0.key == key })?.title ?? "Имя"
        sortButton.title = title
        sortButton.ascending = currentSortAscending
        sortButton.needsDisplay = true
    }

    @objc func showSortMenu(_ sender: NSButton) {
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

    @objc func sortMenuItemSelected(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        let ascending = key == currentSortKey ? !currentSortAscending : defaultAscending(for: key)
        applySort(key: key, ascending: ascending)
    }

    func applySort(key: String, ascending: Bool) {
        activate()
        tableView.sortDescriptors = [NSSortDescriptor(key: key, ascending: ascending)]
        syncSortControl()
        if virtualTagTitle == nil && virtualSearchTitle == nil {
            FPFolderProfileStore.shared.record(for: currentURL, sortKey: key, sortAscending: ascending)
        }
        sortItems()
        applyFilter()
    }

    func applySavedFolderProfileIfPresent(for url: URL) {
        guard let profile = FPFolderProfileStore.shared.profile(for: url) else { return }
        if let sortKey = profile.sortKey, let ascending = profile.sortAscending {
            tableView.sortDescriptors = [NSSortDescriptor(key: sortKey, ascending: ascending)]
            syncSortControl()
        }
        if let scale = profile.viewScale, abs(scale - viewScale) > 0.5 {
            let oldMode = viewMode
            viewScale = min(max(scale, 0), 100)
            if viewScale <= 28 {
                viewMode = .list
                iconSize = CGFloat(16 + (viewScale / 28) * 16)
            } else {
                viewMode = .largeIcons
                iconSize = CGFloat(48 + ((viewScale - 28) / 72) * 96)
            }
            updateViewScaleButton()
            if oldMode != viewMode {
                updateTableRowHeight()
                tableScrollView.isHidden = viewMode == .largeIcons
                gridScrollView.isHidden = viewMode != .largeIcons
                updateModeButtons()
                updateViewModeToggleButton()
            }
        }
    }

    func defaultAscending(for key: String) -> Bool {
        switch key {
        case "created", "modified", "size":
            return false
        default:
            return true
        }
    }

    func directoryItemsMatch(_ left: [FileItem], _ right: [FileItem]) -> Bool {
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

    func compareNumbers(_ left: Int64, _ right: Int64) -> ComparisonResult {
        if left == right { return .orderedSame }
        return left < right ? .orderedAscending : .orderedDescending
    }

    func applyFilter(preservingGridPosition: Bool = false) {
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
        if gridFilter != .all {
            filteredItems = filteredItems.filter { gridFilter.matches($0) }
        }
        applyVersionCollapsing()
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
        syncStudioHeader()
        updateEmptyState(isLoading: false)
        notifySelectionChanged()
    }

    @objc func goBack(_ sender: Any?) {
        activate()
        guard historyIndex > 0 else { return }
        isChangingHistory = true
        historyIndex -= 1
        applyHistoryEntry(history[historyIndex])
        isChangingHistory = false
    }

    func showBackHistoryMenu(from button: FPLongPressButton) {
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

    @objc func openHistoryEntryFromMenu(_ sender: NSMenuItem) {
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
        if let archiveURL = virtualArchiveURL {
            let trimmed = virtualArchiveInternalPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if trimmed.isEmpty {
                navigate(to: archiveURL.deletingLastPathComponent())
            } else {
                let parts = trimmed.split(separator: "/")
                let parentInternal = parts.dropLast().joined(separator: "/")
                openZipArchive(archiveURL, internalPath: parentInternal)
            }
            return
        }
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
        siblingParentPath = nil
        loadCurrentDirectory()
    }

    // MARK: - Переключение по соседним папкам (`‹ 5/21 ›`, `[` / `]`, `⌥←` / `⌥→`)

    var isGridTypeSelectActive: Bool {
        !typeSelectBuffer.isEmpty && Date().timeIntervalSince(typeSelectUpdatedAt) <= 0.85
    }

    private func siblingSortSpec(for parent: URL) -> (key: String, ascending: Bool) {
        if let profile = FPFolderProfileStore.shared.profile(for: parent),
           let key = profile.sortKey,
           let asc = profile.sortAscending {
            return (key, asc)
        }
        if let hint = parentSortHints[parent.standardizedFileURL.path] {
            return hint
        }
        return (currentSortKey, currentSortAscending)
    }

    private func displayNameForParent(_ parent: URL) -> String {
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL
        let std = parent.standardizedFileURL
        if std.path == home.path { return L("Дом", "Home") }
        if std.path == "/" { return "Macintosh HD" }
        return std.lastPathComponent
    }

    func refreshSiblingFoldersState() {
        let std = currentURL.standardizedFileURL
        let isRealFolder = !isRecentItemsView
            && virtualTagTitle == nil
            && virtualSearchTitle == nil
            && virtualArchiveURL == nil
            && std.path != "/"

        guard isRealFolder else {
            siblingScanGeneration += 1
            siblingFolders = []
            siblingParentPath = nil
            siblingCurrentIndex = 0
            studioHeaderView.updateSiblingFolders([], currentIndex: 0, parentName: "")
            return
        }

        let parent = std.deletingLastPathComponent().standardizedFileURL
        let parentPath = parent.path
        let parentDisplay = displayNameForParent(parent)

        // Если уже находимся в том же родителе — мгновенно обновляем счётчик из кэша,
        // чтобы перещёлкивание `[` / `]` не мигало и работало с нулевой задержкой.
        if siblingParentPath == parentPath,
           let cachedIdx = siblingFolders.firstIndex(where: { $0.standardizedFileURL.path == std.path }) {
            siblingCurrentIndex = cachedIdx
            studioHeaderView.updateSiblingFolders(siblingFolders, currentIndex: cachedIdx, parentName: parentDisplay)
        } else {
            studioHeaderView.updateSiblingFolders([], currentIndex: 0, parentName: parentDisplay)
        }

        let (sortKey, sortAscending) = siblingSortSpec(for: parent)
        let includeHidden = showHiddenFiles
        siblingScanGeneration += 1
        let generation = siblingScanGeneration

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let siblings = Self.sortedSiblingFolders(
                in: parent,
                sortKey: sortKey,
                ascending: sortAscending,
                showHidden: includeHidden
            )
            DispatchQueue.main.async {
                guard let self,
                      self.siblingScanGeneration == generation,
                      self.currentURL.standardizedFileURL.path == std.path else { return }
                self.siblingParentPath = parentPath
                self.siblingFolders = siblings
                if let idx = siblings.firstIndex(where: { $0.standardizedFileURL.path == std.path }) {
                    self.siblingCurrentIndex = idx
                    self.studioHeaderView.updateSiblingFolders(siblings, currentIndex: idx, parentName: parentDisplay)
                } else {
                    self.siblingCurrentIndex = 0
                    self.studioHeaderView.updateSiblingFolders([], currentIndex: 0, parentName: parentDisplay)
                }
            }
        }
    }

    @discardableResult
    func navigateToSiblingFolder(delta: Int) -> Bool {
        guard delta != 0 else { return false }
        let std = currentURL.standardizedFileURL
        guard !isRecentItemsView,
              virtualTagTitle == nil,
              virtualSearchTitle == nil,
              virtualArchiveURL == nil,
              std.path != "/" else { return false }

        let parent = std.deletingLastPathComponent().standardizedFileURL
        let parentPath = parent.path

        // Если кэш соседей ещё не прогрет (например, нажали `]` сразу после запуска),
        // синхронно подхватываем список соседей за ~1 мс.
        if siblingParentPath != parentPath || siblingFolders.isEmpty {
            let (sortKey, sortAscending) = siblingSortSpec(for: parent)
            let loaded = Self.sortedSiblingFolders(
                in: parent,
                sortKey: sortKey,
                ascending: sortAscending,
                showHidden: showHiddenFiles
            )
            siblingParentPath = parentPath
            siblingFolders = loaded
            siblingCurrentIndex = loaded.firstIndex(where: { $0.standardizedFileURL.path == std.path }) ?? 0
        }

        guard siblingFolders.count > 1,
              let currentIdx = siblingFolders.firstIndex(where: { $0.standardizedFileURL.path == std.path }) else {
            return false
        }

        let targetIdx = currentIdx + delta
        guard siblingFolders.indices.contains(targetIdx) else {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            return false
        }

        let targetURL = siblingFolders[targetIdx]
        siblingCurrentIndex = targetIdx
        studioHeaderView.updateSiblingFolders(
            siblingFolders,
            currentIndex: targetIdx,
            parentName: displayNameForParent(parent)
        )
        studioHeaderView.flashSiblingStep(delta: delta)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        FPActionLog.action("соседняя папка \(delta > 0 ? "→" : "←")", targetURL.lastPathComponent)
        navigate(to: targetURL, addingToHistory: true)
        restoreKeyboardFocusAfterSiblingJump()
        return true
    }

    func openSiblingFolder(_ url: URL) {
        let std = url.standardizedFileURL
        guard std.path != currentURL.standardizedFileURL.path else { return }
        if let idx = siblingFolders.firstIndex(where: { $0.standardizedFileURL.path == std.path }) {
            let delta = idx >= siblingCurrentIndex ? 1 : -1
            siblingCurrentIndex = idx
            studioHeaderView.flashSiblingStep(delta: delta)
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        FPActionLog.action("прыжок в соседнюю папку", std.lastPathComponent)
        navigate(to: std, addingToHistory: true)
        restoreKeyboardFocusAfterSiblingJump()
    }

    private func restoreKeyboardFocusAfterSiblingJump() {
        guard let window else { return }
        if window.firstResponder is NSTextView { return }
        window.makeFirstResponder(viewMode == .list ? tableView : self)
    }

    /// Возвращает список реальных подпапок внутри `parent` в том же порядке
    /// сортировки, что использует `FilePanel.sortItems()`.
    static func sortedSiblingFolders(
        in parent: URL,
        sortKey: String,
        ascending: Bool,
        showHidden: Bool
    ) -> [URL] {
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isPackageKey,
            .isHiddenKey,
            .creationDateKey,
            .contentModificationDateKey,
            .localizedTypeDescriptionKey
        ]
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        guard let raw = try? FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: keys,
            options: options
        ) else {
            return []
        }

        struct Entry {
            let url: URL
            let name: String
            let created: Date
            let modified: Date
            let kind: String
        }

        var folders: [Entry] = []
        folders.reserveCapacity(raw.count)
        for item in raw {
            guard let values = try? item.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == true,
                  values.isPackage != true else { continue }
            if !showHidden && values.isHidden == true { continue }
            folders.append(Entry(
                url: item.standardizedFileURL,
                name: item.lastPathComponent,
                created: values.creationDate ?? Date.distantPast,
                modified: values.contentModificationDate ?? Date.distantPast,
                kind: values.localizedTypeDescription ?? ""
            ))
        }

        folders.sort { left, right in
            let result: ComparisonResult
            switch sortKey {
            case "created":
                result = left.created.compare(right.created)
            case "modified":
                result = left.modified.compare(right.modified)
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

        return folders.map(\.url)
    }
}
