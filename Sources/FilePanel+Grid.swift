import Cocoa
import Quartz

extension FilePanel {
    static func previewBoxHeight(for thumb: CGFloat) -> CGFloat {
        max(44, round(thumb * 0.78))
    }

    var gridItemSize: NSSize {
        let thumb = visibleIconSize
        let width = max(124, round(thumb * 1.12) + 12)
        let height = Self.previewBoxHeight(for: thumb) + 52
        return NSSize(width: width, height: height)
    }

    func currentGridViewportWidth() -> CGFloat {
        let contentWidth = gridScrollView.contentView.bounds.width
        if contentWidth > 1 {
            return contentWidth
        }
        return max(bounds.width - 20, 220)
    }

    func lightweightGridRelayout(width: CGFloat) {
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

    func rebuildGridViews() {
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
            // Боковое листание ряда меняет только сдвиг: набор видимых плиток,
            // ширина окна и высота содержимого остаются прежними. Без учёта
            // сдвига быстрый путь пропускал перестановку, и ряд не двигался,
            // хотя значение в модели менялось.
            let offsets = currentSectionOffsets(layout)
            if renderedGridColumns != layout.columns
                || abs(renderedGridViewportWidth - viewportWidth) >= 0.5
                || abs(renderedGridContentHeight - layout.contentHeight) >= 0.5
                || offsets != renderedSectionOffsets {
                for cell in gridItemViews {
                    cell.isHidden = false
                    cell.frame = gridFrame(for: cell.itemIndex, layout: layout)
                }
            }
            renderedGridColumns = layout.columns
            renderedGridViewportWidth = viewportWidth
            renderedGridContentHeight = layout.contentHeight
            renderedSectionOffsets = offsets
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
                    cut: FPCutFileState.shared.contains(item.url),
                    versionCount: versionGroupCounts[item.url.path] ?? 0,
                    flagLevel: flagLevel(for: item)
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
        renderedSectionOffsets = currentSectionOffsets(layout)
        synchronizeGridHoverWithPointer(animated: false)

        if animateAppear, !swipeEffectActive,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            playGridAppearAnimation()
        }
    }

    // Каскадное появление ячеек при входе в папку: короткий fade + подъём,
    // только presentation-слой (модельные значения не трогаются, поэтому
    // переиспользование ячеек и снимки волны остаются корректными).
    func playGridAppearAnimation() {
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

    func makeGridCell() -> FileGridCellView {
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
    func toggleFlag(at index: Int) {
        guard filteredItems.indices.contains(index) else { return }
        let item = filteredItems[index]
        guard !item.isDirectory else { return }
        // Ступень читается из самого файла, а не из кэша списка папки: в
        // быстром первом проходе метки там ещё не заполнены, и следующая
        // ступень всегда получалась «кандидат» — цвет не менялся никогда.
        let next = FPFinderTagStore.flagLevel(url: item.url).next
        do {
            try FPFinderTagStore.setFlagLevel(next, on: item.url)
            flagLevelOverrides[item.url.standardizedFileURL.path] = next
            FPActionLog.action("отметка → \(next)", item.name)
        } catch {
            showError("Не удалось изменить отметку: \(error.localizedDescription)")
            return
        }
        DirectorySnapshotCache.shared.invalidate(currentURL)
        loadCurrentDirectory(asynchronously: true, preservingGridPosition: true)
    }

    func clearGridViews() {
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

    func invalidateGridRenderCache() {
        renderedGridIndexes = nil
        renderedGridColumns = 0
        renderedGridIconSize = 0
        renderedGridItemCount = 0
        renderedGridViewportWidth = 0
        renderedGridContentHeight = 0
        cachedGridLayout = nil
    }

    func gridCellHeight(for _: Int, maxPreviewSide: CGFloat) -> CGFloat {
        // Stable editorial 5:4 / 3:2 slot height — eliminates tall empty air
        // above 16:9/4:3 media while keeping async thumbnails jitter-free.
        Self.previewBoxHeight(for: maxPreviewSide) + 52
    }

    func makeGridLayout(viewportWidth: CGFloat) -> GridLayout {
        let baseItemSize = gridItemSize
        if let cachedGridLayout,
           abs(cachedGridLayout.viewportWidth - viewportWidth) < 0.5,
           abs(cachedGridLayout.itemSize.height - baseItemSize.height) < 0.5 {
            return cachedGridLayout
        }

        let inset: CGFloat = 8
        let preferredColumnSpacing = min(FPStyle.gridSpacing, 10)
        let minimumColumnSpacing = min(preferredColumnSpacing, 8)
        let rowSpacing = min(max(FPStyle.gridSpacing * 0.40, 6), 12)
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
        var topOffset: CGFloat = 2
        for source in sourceSections {
            let isExpanded = expandedGridSections.contains(source.id)
            // Свёрнутая секция показывает весь свой состав в одну строку:
            // ряд листается вбок с Shift, поэтому обрезать его по числу
            // колонок больше не нужно.
            let isHorizontal = grouped && !isExpanded
            let displayed = source.indexes
            let headerHeight: CGFloat = grouped ? 28 : 0
            let headerTop = topOffset
            let itemsTop = headerTop + headerHeight
            let rows = isHorizontal
                ? (displayed.isEmpty ? 0 : 1)
                : Int(ceil(Double(displayed.count) / Double(columns)))
            var rowOffsets: [CGFloat] = []
            var rowHeights: [CGFloat] = []
            var rowsHeight: CGFloat = 0
            if rows > 0 {
                rowOffsets.reserveCapacity(rows)
                rowHeights.reserveCapacity(rows)
                for row in 0..<rows {
                    let start = row * columns
                    // Высота ряда считается по ограниченной выборке: в
                    // свёрнутой секции могут быть сотни файлов, обходить их
                    // все на каждом проходе раскладки слишком дорого.
                    let end = isHorizontal
                        ? min(displayed.count, 60)
                        : min(displayed.count, start + columns)
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
                    itemsHeight: rowsHeight,
                    isHorizontal: isHorizontal,
                    horizontalOffset: isHorizontal
                        ? (collapsedSectionOffsets[source.id] ?? 0)
                        : 0,
                    horizontalExtent: isHorizontal
                        ? max(
                            0,
                            CGFloat(displayed.count) * (itemSize.width + columnSpacing)
                                - columnSpacing
                                - (viewportWidth - inset * 2)
                        )
                        : 0
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

    func gridFrame(for index: Int, layout: GridLayout) -> NSRect {
        guard let position = layout.positions[index], position.sectionIndex < layout.sections.count else { return .zero }
        let section = layout.sections[position.sectionIndex]
        guard position.position < section.displayedIndexes.count,
              section.displayedIndexes[position.position] == index else { return .zero }
        let column = section.isHorizontal ? position.position : position.position % layout.columns
        let row = section.isHorizontal ? 0 : position.position / layout.columns
        guard row < section.rowOffsets.count, row < section.rowHeights.count else { return .zero }
        let x: CGFloat
        if section.isHorizontal {
            x = layout.leadingInset
                + CGFloat(column) * (layout.itemSize.width + layout.spacing)
                - section.horizontalOffset
        } else if layout.columns == 1 {
            x = max(layout.inset, (layout.viewportWidth - layout.itemSize.width) / 2)
        } else {
            x = layout.leadingInset + CGFloat(column) * (layout.itemSize.width + layout.spacing)
        }
        let cellHeight = gridCellHeight(for: index, maxPreviewSide: visibleIconSize)
        // Align metadata baselines along the bottom of the row. Wide previews
        // therefore do not leave an invisible square-height tail underneath.
        let y = layout.contentHeight
            - section.itemsTop
            - section.rowOffsets[row]
            - section.rowHeights[row]
        return NSRect(x: x, y: y, width: layout.itemSize.width, height: cellHeight)
    }

    /// Листает свёрнутый ряд под курсором. Возвращает false, если под
    /// курсором нет свёрнутой секции или ряд уже упёрся в край — тогда
    /// событие уходит дальше и работает обычная прокрутка.
    func scrollCollapsedSection(at point: NSPoint, by delta: CGFloat) -> Bool {
        guard viewMode == .largeIcons else { return false }
        let layout = makeGridLayout(viewportWidth: max(currentGridViewportWidth(), 220))
        let distanceFromTop = layout.contentHeight - point.y
        guard let section = layout.sections.first(where: { candidate in
            candidate.isHorizontal
                && distanceFromTop >= candidate.headerTop
                && distanceFromTop <= candidate.itemsTop + candidate.itemsHeight
        }), section.horizontalExtent > 0 else { return false }

        let current = collapsedSectionOffsets[section.id] ?? 0
        let next = min(max(current - delta, 0), section.horizontalExtent)
        guard abs(next - current) > 0.01 else { return false }
        collapsedSectionOffsets[section.id] = next
        // Раскладка кэшируется по ширине окна и высоте плитки, а сдвиг ряда в
        // ключ кэша не входит — без сброса возвращалась старая раскладка со
        // старым сдвигом, и ряд не двигался, хотя значение менялось.
        cachedGridLayout = nil
        FPActionLog.action(
            "ряд «\(section.title ?? section.id)» листается",
            "сдвиг \(Int(next)) из \(Int(section.horizontalExtent))"
        )
        rebuildGridViews()
        return true
    }

    /// Оставляет в ленте по одному представителю на группу версий.
    ///
    /// Раскрытые группы показываются целиком: человек мог развернуть стопку,
    /// чтобы сравнить оригинал с уменьшенной копией.
    func applyVersionCollapsing() {
        versionGroupCounts.removeAll()
        guard FPPreferences.collapsesFileVersions else { return }
        var result: [FileItem] = []
        for group in FPVersionGrouping.groups(for: filteredItems) {
            guard group.members.count > 1 else {
                result.append(group.representative)
                continue
            }
            if expandedVersionGroups.contains(group.key) {
                result.append(contentsOf: group.members)
                continue
            }
            versionGroupCounts[group.representative.url.path] = group.members.count
            result.append(group.representative)
        }
        filteredItems = result
    }

    /// Раскрывает или сворачивает стопку версий под выбранным файлом.
    func toggleVersionGroup(at index: Int) {
        guard filteredItems.indices.contains(index) else { return }
        let key = FPVersionGrouping.baseName(for: filteredItems[index].url)
        if expandedVersionGroups.contains(key) {
            expandedVersionGroups.remove(key)
            FPActionLog.action("стопка версий свёрнута", key)
        } else {
            expandedVersionGroups.insert(key)
            FPActionLog.action("стопка версий раскрыта", key)
        }
        loadCurrentDirectory(asynchronously: true, preservingGridPosition: true)
    }

    func currentSectionOffsets(_ layout: GridLayout) -> [String: CGFloat] {
        var result: [String: CGFloat] = [:]
        for section in layout.sections where section.isHorizontal {
            result[section.id] = section.horizontalOffset
        }
        return result
    }

    /// Ступень отметки для показа: изменённое в этом сеансе важнее кэша.
    func flagLevel(for item: FileItem) -> FPFinderTagStore.FlagLevel {
        if let override = flagLevelOverrides[item.url.standardizedFileURL.path] {
            return override
        }
        return FPFinderTagStore.flagLevel(item.finderTags ?? [])
    }

    func gridIndex(at point: NSPoint) -> Int? {
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
            let pitch = layout.itemSize.width + layout.spacing
            let position: Int
            if section.isHorizontal {
                // Свёрнутый ряд сдвинут вбок, и номер плитки считается от его
                // собственного начала, а не от левого края окна. Без учёта
                // сдвига клики после листания попадали мимо, а ограничение по
                // числу колонок отсекало всё, что уехало за первый экран, —
                // выделение переставало работать вовсе.
                guard pitch > 0 else { return nil }
                position = Int(floor((point.x - layout.leadingInset + section.horizontalOffset) / pitch))
            } else {
                let xInGrid = point.x - layout.leadingInset
                guard xInGrid >= 0 else { return nil }
                let column = layout.columns == 1 ? 0 : Int(floor(xInGrid / pitch))
                guard column >= 0, column < layout.columns else { return nil }
                position = row * layout.columns + column
            }
            guard position >= 0, position < section.displayedIndexes.count else { return nil }
            let index = section.displayedIndexes[position]
            return gridFrame(for: index, layout: layout).contains(point) ? index : nil
        }
        return nil
    }

    func makeDateGridSections(grouped: Bool) -> [(id: String, title: String, indexes: [Int])] {
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
                title = L("Сегодня", "Today")
                sortDate = today
            } else if day >= yesterday {
                id = "yesterday"
                title = L("Вчера", "Yesterday")
                sortDate = yesterday
            } else if day >= sevenDaysAgo {
                id = "last7"
                title = L("Предыдущие 7 дней", "Previous 7 Days")
                sortDate = sevenDaysAgo
            } else if day >= thirtyDaysAgo {
                id = "last30"
                title = L("Предыдущие 30 дней", "Previous 30 Days")
                sortDate = thirtyDaysAgo
            } else if date == Date.distantPast {
                id = "undated"
                title = L("Без даты", "Undated")
                sortDate = Date.distantPast
            } else {
                let components = calendar.dateComponents([.year, .month], from: date)
                id = String(format: "month-%04d-%02d", components.year ?? 0, components.month ?? 0)
                let locale = Locale(identifier: FPLocalization.isEnglish ? "en_US" : "ru_RU")
                monthFormatter.locale = locale
                title = monthFormatter.string(from: date).capitalized(with: locale)
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

    func handleGridMouseDown(at point: NSPoint, event: NSEvent) {
        guard viewMode == .largeIcons else { return }
        if let index = gridIndex(at: point) {
            // Звёздочка разбирается здесь: клики в сетке принимает холст, до
            // самих ячеек они не доходят, поэтому внутри ячейки поймать
            // нажатие на значок нельзя.
            if event.clickCount == 1,
               let cell = gridItemViews.first(where: { $0.itemIndex == index }) {
                if cell.flagBadgeContains(point) {
                    toggleFlag(at: index)
                    return
                }
                if cell.versionBadgeContains(point) {
                    toggleVersionGroup(at: index)
                    return
                }
            }
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

    func beginGridMarquee(at point: NSPoint, event: NSEvent) -> Bool {
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

    func updateGridMarquee(rect: NSRect) {
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

    func endGridMarquee() {
        gridSelectionMarquee.isHidden = true
        gridSelectionMarquee.frame = .zero
        gridMarqueeBaseSelection.removeAll()
        footerLabel.stringValue = footerText()
        syncFolderPocketToSelection()
        notifySelectionChanged()
    }

    func visibleGridIndexes(layout: GridLayout) -> [Int] {
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
                if section.isHorizontal {
                    // В свёрнутом ряду могут быть сотни файлов. Создаются
                    // только те плитки, что попадают в видимую ширину, плюс
                    // небольшой запас по краям.
                    let pitch = layout.itemSize.width + layout.spacing
                    guard pitch > 0 else { continue }
                    let leftEdge = section.horizontalOffset - pitch
                    let rightEdge = section.horizontalOffset + layout.viewportWidth + pitch
                    let first = max(0, Int(floor(leftEdge / pitch)))
                    let last = min(
                        section.displayedIndexes.count,
                        Int(ceil(rightEdge / pitch)) + 1
                    )
                    if first < last {
                        indexes.append(contentsOf: section.displayedIndexes[first..<last])
                    }
                    continue
                }
                let start = row * layout.columns
                let end = min(section.displayedIndexes.count, start + layout.columns)
                if start < end {
                    indexes.append(contentsOf: section.displayedIndexes[start..<end])
                }
            }
        }
        return indexes
    }

    func updateGridSectionHeaders(layout: GridLayout) {
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

    func toggleGridSection(_ id: String) {
        if expandedGridSections.contains(id) {
            expandedGridSections.remove(id)
        } else {
            expandedGridSections.insert(id)
        }
        invalidateGridRenderCache()
        rebuildGridViews()
    }

    func scrollGridToTop(contentHeight: CGFloat) {
        let clipView = gridScrollView.contentView
        let y = max(0, contentHeight - clipView.bounds.height)
        clipView.scroll(to: NSPoint(x: 0, y: y))
        gridScrollView.reflectScrolledClipView(clipView)
    }

    func saveCurrentFolderViewState() {
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

    func captureGridScrollState() -> GridScrollState? {
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

    func restoreGridScrollState(_ state: GridScrollState) {
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

    @objc func gridBoundsChanged(_ notification: Notification) {
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

    func synchronizeGridHoverWithPointer(animated: Bool) {
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

    func selectGridItem(at index: Int, extending: Bool, selectingRange: Bool = false) {
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
            gridSelectionCursor = index
        }
        updateGridSelection()
        footerLabel.stringValue = footerText()
        syncFolderPocketToSelection()
        notifySelectionChanged()
        pushSelectionToOpenPreview()
    }

    func syncFolderPocketToSelection() {
        guard folderPocketController?.isVisible == true,
              selectedItems.count == 1,
              let folder = selectedItems.first,
              folder.isDirectory else { return }
        folderPocketController?.follow(folder: folder.url)
    }

    func notifySelectionChanged() {
        let items = selectedItems
        selectionActionBar.update(selectedItems: items)
        onSelectionChanged?(items)
    }

    func updateGridSelection() {
        for cell in gridItemViews {
            cell.setSelected(gridSelectionIndexes.contains(cell.itemIndex))
        }
    }

    func scrollGridItemToVisible(_ index: Int) {
        let layout = makeGridLayout(viewportWidth: max(currentGridViewportWidth(), 220))
        guard index >= 0, index < filteredItems.count else { return }
        gridContentView.scrollToVisible(gridFrame(for: index, layout: layout).insetBy(dx: -12, dy: -12))
    }

    enum GridNavigationDirection {
        case left, right, up, down
    }

    func moveGridSelection(direction: GridNavigationDirection, extendingRange: Bool = false) {
        guard viewMode == .largeIcons, !filteredItems.isEmpty else { return }
        let layout = makeGridLayout(viewportWidth: max(currentGridViewportWidth(), 220))
        let visualOrder = layout.sections.flatMap(\.displayedIndexes)
        guard !visualOrder.isEmpty else { return }

        let base = gridSelectionCursor ?? gridSelectionAnchor ?? gridSelectionIndexes.first ?? visualOrder[0]
        let next: Int
        if let pos = layout.positions[base],
           layout.sections.indices.contains(pos.sectionIndex) {
            let section = layout.sections[pos.sectionIndex]
            let cols = max(1, layout.columns)
            switch direction {
            case .left:
                if let visualIdx = visualOrder.firstIndex(of: base), visualIdx > 0 {
                    next = visualOrder[visualIdx - 1]
                } else {
                    next = base
                }
            case .right:
                if let visualIdx = visualOrder.firstIndex(of: base), visualIdx + 1 < visualOrder.count {
                    next = visualOrder[visualIdx + 1]
                } else {
                    next = base
                }
            case .down:
                let currentCol: Int
                if section.expanded {
                    let candidate = pos.position + cols
                    if candidate < section.displayedIndexes.count {
                        next = section.displayedIndexes[candidate]
                        break
                    }
                    currentCol = pos.position % cols
                } else {
                    // В свёрнутой горизонтальной секции вычисляем визуальную колонку
                    // относительно текущего горизонтального сдвига ряда.
                    let step = layout.itemSize.width + layout.spacing
                    let offset = collapsedSectionOffsets[section.id] ?? 0
                    let visualX = CGFloat(pos.position) * step - offset
                    currentCol = max(0, min(cols - 1, Int((visualX / max(step, 1)).rounded())))
                }
                if pos.sectionIndex + 1 < layout.sections.count {
                    let nextSection = layout.sections[pos.sectionIndex + 1]
                    next = itemInSection(nextSection, visualColumn: currentCol, fromBottom: false, layout: layout) ?? base
                } else {
                    next = base
                }
            case .up:
                let currentCol: Int
                if section.expanded {
                    let candidate = pos.position - cols
                    if candidate >= 0 {
                        next = section.displayedIndexes[candidate]
                        break
                    }
                    currentCol = pos.position % cols
                } else {
                    let step = layout.itemSize.width + layout.spacing
                    let offset = collapsedSectionOffsets[section.id] ?? 0
                    let visualX = CGFloat(pos.position) * step - offset
                    currentCol = max(0, min(cols - 1, Int((visualX / max(step, 1)).rounded())))
                }
                if pos.sectionIndex > 0 {
                    let prevSection = layout.sections[pos.sectionIndex - 1]
                    next = itemInSection(prevSection, visualColumn: currentCol, fromBottom: true, layout: layout) ?? base
                } else {
                    next = base
                }
            }
        } else {
            let delta: Int
            switch direction {
            case .left: delta = -1
            case .right: delta = 1
            case .up: delta = -max(1, layout.columns)
            case .down: delta = max(1, layout.columns)
            }
            next = min(max(base + delta, 0), filteredItems.count - 1)
        }

        // Если выбранный элемент находится в свёрнутой горизонтальной секции за
        // пределами видимой ширины — плавно докручиваем горизонтальный сдвиг ряда.
        if let targetPos = layout.positions[next],
           layout.sections.indices.contains(targetPos.sectionIndex) {
            let targetSection = layout.sections[targetPos.sectionIndex]
            if !targetSection.expanded, layout.sections.count > 1 || targetSection.title != nil {
                let step = layout.itemSize.width + layout.spacing
                let itemLeft = CGFloat(targetPos.position) * step
                let itemRight = itemLeft + layout.itemSize.width
                let viewportSpan = max(1, layout.contentWidth - layout.leadingInset * 2)
                var offset = collapsedSectionOffsets[targetSection.id] ?? 0
                if itemLeft < offset {
                    offset = itemLeft
                } else if itemRight > offset + viewportSpan {
                    offset = max(0, itemRight - viewportSpan)
                }
                if abs(offset - (collapsedSectionOffsets[targetSection.id] ?? 0)) > 0.5 {
                    collapsedSectionOffsets[targetSection.id] = offset
                    rebuildGridViews()
                }
            }
        }

        if extendingRange {
            let anchor = gridSelectionAnchor ?? base
            gridSelectionAnchor = anchor
            gridSelectionCursor = next
            if let anchorIdx = visualOrder.firstIndex(of: anchor),
               let nextIdx = visualOrder.firstIndex(of: next) {
                let lo = min(anchorIdx, nextIdx)
                let hi = max(anchorIdx, nextIdx)
                gridSelectionIndexes = IndexSet(visualOrder[lo...hi])
            } else {
                gridSelectionIndexes = IndexSet(integersIn: min(anchor, next)...max(anchor, next))
            }
            updateGridSelection()
            footerLabel.stringValue = footerText()
            syncFolderPocketToSelection()
            notifySelectionChanged()
            scrollGridItemToVisible(next)
            return
        }
        gridSelectionCursor = next
        selectGridItem(at: next, extending: false)
        scrollGridItemToVisible(next)
    }

    private func itemInSection(
        _ section: GridSectionLayout,
        visualColumn: Int,
        fromBottom: Bool,
        layout: GridLayout
    ) -> Int? {
        guard !section.displayedIndexes.isEmpty else { return nil }
        let cols = max(1, layout.columns)
        if !section.expanded {
            let step = layout.itemSize.width + layout.spacing
            let offset = collapsedSectionOffsets[section.id] ?? 0
            let firstVisible = max(0, Int((offset / max(step, 1)).rounded()))
            let targetPos = min(max(firstVisible + visualColumn, 0), section.displayedIndexes.count - 1)
            return section.displayedIndexes[targetPos]
        }
        if !fromBottom {
            let targetPos = min(visualColumn, section.displayedIndexes.count - 1)
            return section.displayedIndexes[targetPos]
        }
        let lastRowStart = ((section.displayedIndexes.count - 1) / cols) * cols
        let targetPos = min(lastRowStart + visualColumn, section.displayedIndexes.count - 1)
        return section.displayedIndexes[targetPos]
    }

    func moveGridSelection(by delta: Int, extendingRange: Bool = false) {
        if delta == -1 {
            moveGridSelection(direction: .left, extendingRange: extendingRange)
        } else if delta == 1 {
            moveGridSelection(direction: .right, extendingRange: extendingRange)
        } else if delta < 0 {
            moveGridSelection(direction: .up, extendingRange: extendingRange)
        } else {
            moveGridSelection(direction: .down, extendingRange: extendingRange)
        }
    }

    /// Быстрый переход по первым буквам имени в режиме плиток (как в Finder).
    func handleGridTypeSelect(_ event: NSEvent) -> Bool {
        guard viewMode == .largeIcons,
              !filteredItems.isEmpty,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let characters = event.characters,
              characters.count == 1,
              let scalar = characters.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" || scalar == "." else {
            return false
        }
        let now = Date()
        if now.timeIntervalSince(typeSelectUpdatedAt) > 0.85 {
            typeSelectBuffer = characters
        } else {
            typeSelectBuffer += characters
        }
        typeSelectUpdatedAt = now

        let query = typeSelectBuffer.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let matchIndex = filteredItems.firstIndex {
            $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).hasPrefix(query)
        } ?? filteredItems.firstIndex {
            $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(query)
        }
        guard let matchIndex else { return true }
        selectGridItem(at: matchIndex, extending: false)
        scrollGridItemToVisible(matchIndex)
        return true
    }

    func refreshVisibleItems(paths: Set<String>) {
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
                cut: FPCutFileState.shared.contains(item.url),
                versionCount: versionGroupCounts[item.url.path] ?? 0,
                flagLevel: flagLevel(for: item)
            )
        }
    }

    func select(url: URL) {
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
}
