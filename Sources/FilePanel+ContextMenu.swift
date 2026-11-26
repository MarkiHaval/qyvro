import Cocoa
import CryptoKit
import UniformTypeIdentifiers

extension FilePanel {
    func handleGridMenu(at point: NSPoint) -> NSMenu {
        if let index = gridIndex(at: point), !gridSelectionIndexes.contains(index) {
            selectGridItem(at: index, extending: false)
        }
        return contextMenu()
    }

    func gridDragURLs(at point: NSPoint) -> [URL] {
        guard !isArchiveMode, viewMode == .largeIcons, let index = gridIndex(at: point) else { return [] }
        if !gridSelectionIndexes.contains(index) {
            selectGridItem(at: index, extending: false)
        }
        return selectedItems.map(\.url)
    }

    func gridDragImage(at point: NSPoint) -> NSImage? {
        guard let index = gridIndex(at: point), index < filteredItems.count else { return nil }
        return displayImage(for: filteredItems[index], size: min(max(visibleIconSize, 48), 96))
    }

    func validateGridDrop(at point: NSPoint, urls: [URL]) -> NSDragOperation {
        guard let target = gridDropTarget(at: point, urls: urls) else { return [] }
        return urls.contains { $0.standardizedFileURL.deletingLastPathComponent().path != target.path } ? .move : []
    }

    func performGridDrop(at point: NSPoint, urls: [URL]) -> Bool {
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

    func gridDropTarget(at point: NSPoint, urls: [URL]) -> URL? {
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

    func isSameOrAncestor(_ possibleAncestor: URL, of descendant: URL) -> Bool {
        let ancestorPath = possibleAncestor.standardizedFileURL.path
        let descendantPath = descendant.standardizedFileURL.path
        return descendantPath == ancestorPath || descendantPath.hasPrefix(ancestorPath + "/")
    }

    func uniqueDestination(for source: URL, in folder: URL) -> URL {
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

    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        if isArchiveMode {
            menu.addItem(withTitle: L("Открыть", "Open"), action: #selector(openSelection(_:)), keyEquivalent: "")
            menu.addItem(withTitle: L("Быстрый просмотр", "Quick Preview"), action: #selector(quickLookSelection(_:)), keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: L("Извлечь выбранное рядом с архивом", "Extract Selected Next to Archive"), action: #selector(extractSelectedArchiveEntriesNextToZip(_:)), keyEquivalent: "")
            menu.addItem(withTitle: L("Извлечь в папку…", "Extract to Folder…"), action: #selector(extractSelectedArchiveEntriesToFolder(_:)), keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: L("Выйти из архива", "Exit Archive"), action: #selector(exitArchiveMode(_:)), keyEquivalent: "")
            for item in menu.items { item.target = self }
            return menu
        }
        menu.addItem(withTitle: L("Открыть", "Open"), action: #selector(openSelection(_:)), keyEquivalent: "")
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
        if !selectedItems.isEmpty {
            let shelfItem = menu.addItem(
                withTitle: selectedItems.count == 1
                    ? "На полку сбора"
                    : "На полку сбора (\(selectedItems.count))",
                action: #selector(addSelectionToDropShelf(_:)),
                keyEquivalent: ""
            )
            if #available(macOS 11.0, *) {
                shelfItem.image = NSImage(
                    systemSymbolName: "tray.and.arrow.down",
                    accessibilityDescription: "На полку сбора"
                )
            }
        }
        if let firstFolder = selectedItems.first(where: \.isDirectory) {
            let analyzeItem = menu.addItem(
                withTitle: selectedItems.filter(\.isDirectory).count == 1
                    ? "Где пропало место в «\(firstFolder.name)»…"
                    : "Где пропало место…",
                action: #selector(analyzeSelectedFolderStorage(_:)),
                keyEquivalent: ""
            )
            if #available(macOS 11.0, *) {
                analyzeItem.image = NSImage(
                    systemSymbolName: "chart.pie.fill",
                    accessibilityDescription: "Анализ веса"
                )
            }
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
                    withTitle: L("Открыть как папку (без распаковки)", "Browse Archive (No Unzip)"),
                    action: #selector(browseSelectedZIP(_:)),
                    keyEquivalent: ""
                )
                menu.addItem(
                    withTitle: L("Распаковать ZIP в папку", "Unzip into Folder"),
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

    @objc func openSelectionWithApplication(_ sender: NSMenuItem) {
        guard let application = sender.representedObject as? URL,
              let file = selectedItems.first?.url else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([file], withApplicationAt: application, configuration: configuration)
    }

    @objc func shareSelectionViaAirDrop(_ sender: Any?) {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty,
              let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: urls) else {
            NSSound.beep()
            return
        }
        service.perform(withItems: urls)
    }

    @objc func copyPathsFromMenu(_ sender: Any?) {
        copySelectedPaths()
    }

    @objc func addSelectionToDropShelf(_ sender: Any?) {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        QyvroDropShelfModule.shared.add(urls: urls, reveal: false)
        footerLabel.stringValue = "На полке сбора: \(QyvroDropShelfModule.shared.store.count)"
    }

    @objc func analyzeSelectedFolderStorage(_ sender: Any?) {
        let target = selectedItems.first(where: \.isDirectory)?.url
            ?? physicalDropDestinationURL
            ?? FileManager.default.homeDirectoryForCurrentUser
        QyvroDiskAnalyzerModule.shared.show(rootURL: target)
    }

    @objc func copySHA256(_ sender: Any?) {
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

    @objc func setFolderColorFromMenu(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String: Any],
              let color = payload["color"] as? String,
              let paths = payload["paths"] as? [String] else { return }
        applyFolderColor(color.isEmpty ? nil : color, to: paths.map { URL(fileURLWithPath: $0) })
    }

    @objc func chooseFolderIcon(_ sender: Any?) {
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

    @objc func removeFolderIcon(_ sender: Any?) {
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
}
