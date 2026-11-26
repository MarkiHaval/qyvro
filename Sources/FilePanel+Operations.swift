import Cocoa
import UniformTypeIdentifiers

extension FilePanel {
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
        // Два выделенных файла — это просьба сравнить их, а не листать: окно
        // открывается сразу шторкой с обоими кадрами.
        let picked = selectedItems.filter { !$0.isDirectory }
        let opensAsCurtain = picked.count == 2
        var startIndex = initialIndex
        if opensAsCurtain,
           let first = entries.firstIndex(where: {
               $0.url.standardizedFileURL == picked[0].url.standardizedFileURL
           }) {
            startIndex = first
        }
        let request = FPQuickLookRequest(
            entries: entries,
            initialIndex: startIndex,
            columnCount: viewMode == .largeIcons ? max(1, gridColumnCount) : 1,
            onIndexChanged: { [weak self] url in
                self?.select(url: url)
            },
            opensAsCurtain: opensAsCurtain,
            curtainSecondIndex: opensAsCurtain
                ? entries.firstIndex(where: {
                    $0.url.standardizedFileURL == picked[1].url.standardizedFileURL
                })
                : nil
        )
        FPActionLog.action(
            "превью открыто",
            selectedItems.count == 2
                ? "два файла — шторка"
                : selected.url.lastPathComponent
        )
        onQuickLook?(request)
    }

    /// Подставляет выбранный файл в открытый просмотрщик.
    ///
    /// Просмотрщик остаётся на экране, пока человек ходит по сетке: выбрал
    /// другой файл — он встал в выделенную панель сравнения. Если окна нет,
    /// запрос ничего не делает.
    func pushSelectionToOpenPreview() {
        guard let selected = selectedItems.first, !selected.isDirectory else { return }
        let entries = filteredItems.enumerated().compactMap { index, item -> FPQuickLookGalleryEntry? in
            guard !item.isDirectory else { return nil }
            return FPQuickLookGalleryEntry(url: item.url, visualIndex: index)
        }
        guard let initialIndex = entries.firstIndex(where: {
            $0.url.standardizedFileURL == selected.url.standardizedFileURL
        }) else { return }
        onQuickLook?(
            FPQuickLookRequest(
                entries: entries,
                initialIndex: initialIndex,
                columnCount: viewMode == .largeIcons ? max(1, gridColumnCount) : 1,
                onIndexChanged: { [weak self] url in self?.select(url: url) },
                updatesOpenPreviewOnly: true
            )
        )
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
        if isRecentItemsView || virtualSearchTitle != nil {
            NSSound.beep()
            showError("Открой обычную папку, чтобы создать новую папку")
            return
        }
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

    func uniqueFolderName(in folder: URL) -> String {
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
        guard selectedItems.count == 1, let item = selectedItems.first,
              let window else { return }

        let sheet = FPRenameSheet()
        renameSheet = sheet
        sheet.present(name: item.name, over: window) { [weak self] newName in
            guard let self else { return }
            self.renameSheet = nil
            guard let newName else { return }
            FPActionLog.action("переименование", "\(item.name) → \(newName)")
            self.applyRename(item: item, newName: newName)
        }
    }

    func applyRename(item: FileItem, newName: String) {
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
            showToast("Переименовано в «\(newName)»", symbol: "pencil.line", withUndo: true)
        } catch {
            showError(error.localizedDescription)
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

    @objc func showInspectorAndCalculateFolderSize(_ sender: Any?) {
        // `FileInspectorController.show(items:)` уже автоматически запускает
        // рекурсивный подсчёт размера папок — повторный вызов не нужен.
        showInspector(sender)
    }

    @objc func batchRenameSelection(_ sender: Any?) {
        activate()
        let targets = selectedItems.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard targets.count >= 2 else {
            NSSound.beep()
            showError("Для пакетного переименования выбери минимум два объекта")
            return
        }

        let controller = FPBatchRenameController(items: targets) { [weak self] pairs in
            self?.performBatchRename(pairs)
        }
        batchRenameController = controller
        controller.present(over: window)
    }

    func performBatchRename(_ destinations: [(item: FileItem, destination: URL)]) {
        guard !destinations.isEmpty else { return }
        var staged: [(temporary: URL, destination: URL, original: URL)] = []
        do {
            for pair in destinations {
                let temporary = pair.item.url.deletingLastPathComponent()
                    .appendingPathComponent(".qyvro-rename-\(UUID().uuidString)")
                try fileManager.moveItem(at: pair.item.url, to: temporary)
                staged.append((temporary, pair.destination, pair.item.url))
            }
            for pair in staged {
                try fileManager.moveItem(at: pair.temporary, to: pair.destination)
                var assignments = folderColorMap()
                if let tagKey = assignments.removeValue(forKey: pair.original.standardizedFileURL.path) {
                    assignments[pair.destination.standardizedFileURL.path] = tagKey
                    UserDefaults.standard.set(assignments, forKey: "FolderColors")
                }
                FPFinderTagStore.moveManagedRecord(from: pair.original, to: pair.destination)
            }
            QyvroFileOperationHistory.shared.recordRename(
                staged.map { (original: $0.original, renamed: $0.destination) }
            )
            let affectedDirs = Set(staged.map { $0.destination.deletingLastPathComponent() })
            affectedDirs.forEach { DirectorySnapshotCache.shared.invalidate($0) }
            loadCurrentDirectory(asynchronously: true, preservingGridPosition: true)
            showToast("Переименовано объектов: \(staged.count)", symbol: "pencil.line", withUndo: true)
        } catch {
            for pair in staged where fileManager.fileExists(atPath: pair.temporary.path) {
                try? fileManager.moveItem(at: pair.temporary, to: pair.original)
            }
            showError("Переименование остановлено: \(error.localizedDescription)")
        }
    }

    func settingsFormRow(title: String, control: NSView) -> NSView {
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

        // Подтверждения нет намеренно: файлы уходят в системную корзину, а не
        // стираются, и любое удаление отменяется через историю операций. При
        // разборе пачки диалог на каждый файл был бы главным тормозом — в
        // просмотрщике удаление и так мгновенное, сетка должна вести себя так
        // же.
        FPActionLog.action(
            "в корзину: \(urls.count) объектов",
            urls.count == 1 ? urls[0].lastPathComponent : ""
        )

        let targetFolder = currentURL
        // Перенос в корзину выполняется в фоне: на сетевых дисках и внешних
        // накопителях `trashItem` может блокировать поток на секунды.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let manager = FileManager.default
            var errors: [String] = []
            var trashedRecords: [QyvroTrashRecord] = []
            for url in urls {
                do {
                    var resultingURL: NSURL?
                    try manager.trashItem(at: url, resultingItemURL: &resultingURL)
                    if let trashURL = resultingURL as URL? {
                        trashedRecords.append(.init(original: url, trashURL: trashURL))
                    }
                } catch {
                    errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                QyvroFileOperationHistory.shared.recordTrash(trashedRecords)
                DirectorySnapshotCache.shared.invalidate(targetFolder)
                guard let self else { return }
                let removedPaths = Set(trashedRecords.map { $0.original.standardizedFileURL.path })
                if !removedPaths.isEmpty {
                    self.items.removeAll { removedPaths.contains($0.url.standardizedFileURL.path) }
                    self.applyFilter(preservingGridPosition: true)
                    let msg = trashedRecords.count == 1
                        ? "В корзине: \(trashedRecords[0].original.lastPathComponent)"
                        : "Перемещено в корзину: \(trashedRecords.count)"
                    self.showToast(msg, symbol: "trash.fill", withUndo: true)
                }
                if self.currentURL.standardizedFileURL == targetFolder.standardizedFileURL {
                    self.loadCurrentDirectory(asynchronously: true, preservingGridPosition: true)
                }
                if !errors.isEmpty {
                    self.showError(errors.joined(separator: " | "))
                }
            }
        }
    }

    func copySelectedPaths() {
        activate()
        let paths = selectedItems.map { $0.url.path }
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        showToast(paths.count == 1 ? "Путь скопирован" : "Скопировано путей: \(paths.count)", symbol: "doc.on.doc.fill")
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

    func writeFilesToPasteboard(cutting: Bool) {
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

    func startTransfer(urls: [URL], to target: URL, move: Bool, alwaysKeepBoth: Bool = false) {
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
            if !completed.isEmpty {
                let verb = move ? "Перенесено" : "Скопировано"
                let label = completed.count == 1
                    ? "\(verb): \(completed[0].destination.lastPathComponent)"
                    : "\(verb): \(completed.count)"
                self.showToast(label, symbol: move ? "arrow.right.circle.fill" : "doc.on.doc.fill", withUndo: true)
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
                        self.showToast("Создан архив \(destination.lastPathComponent)", symbol: "doc.zipper")
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

    func finalizeExtractedZIP(
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

    func runArchiveProcess(
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
                // Читаем stderr ДО waitUntilExit: если дочерний процесс выведет
                // больше 64 КБ, буфер pipe забьётся и waitUntilExit зависнет.
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
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
        if isRecentItemsView || virtualSearchTitle != nil || virtualTagTitle != nil {
            NSSound.beep()
            showError("Открой обычную папку, чтобы создать текстовый файл")
            return
        }
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

    @objc func convertSelectedHEICToPNG(_ sender: Any?) {
        let sources = selectedItems
            .filter { !$0.isDirectory && ["heic", "heif"].contains($0.url.pathExtension.lowercased()) }
            .map(\.url)
        convertImages(sources, to: .png)
    }

    @objc func convertSelectedPNGToJPEG(_ sender: Any?) {
        let sources = selectedItems
            .filter { !$0.isDirectory && $0.url.pathExtension.lowercased() == "png" }
            .map(\.url)
        convertImages(sources, to: .jpeg)
    }

    func convertImages(_ sources: [URL], to target: FPImageConversionTarget) {
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
    static let photoshopExtensions: Set<String> = [
        "png", "jpg", "jpeg", "tif", "tiff", "psd", "psb", "heic", "heif",
        "webp", "gif", "bmp", "raw", "dng", "cr2", "nef", "arw"
    ]
    /// Premiere принимает и кадры, и видео — раскадровки и футаж живут в
    /// одном проекте.
    static let premiereExtensions: Set<String> =
        photoshopExtensions.union([
            "mp4", "mov", "m4v", "avi", "mkv", "mxf", "mpg", "mpeg",
            "wav", "mp3", "aac", "aif", "aiff"
        ])

    static let creativeApps: [
        (title: String, bundleIdentifiers: [String], extensions: Set<String>)
    ] = [
        ("Открыть в Photoshop", ["com.adobe.Photoshop"], photoshopExtensions),
        (
            "Открыть в Premiere Pro",
            ["com.adobe.PremierePro", "com.adobe.AfterEffects"],
            premiereExtensions
        )
    ]

    func installedCreativeApp(matching identifiers: [String]) -> URL? {
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

    @objc func openSelectionInCreativeApp(_ sender: NSMenuItem) {
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

    var selectedResizableImages: [URL] {
        selectedItems
            .filter { !$0.isDirectory && FPImageResizer.isSupported($0.url) }
            .map(\.url)
    }

    @objc func resizeSelectedImagesFromMenu(_ sender: NSMenuItem) {
        guard let maxSide = sender.representedObject as? Int else {
            NSSound.beep()
            return
        }
        resizeImages(selectedResizableImages, maxSide: maxSide)
    }

    @objc func resizeSelectedImagesToCustomSize(_ sender: Any?) {
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

    func resizeImages(_ sources: [URL], maxSide: Int) {
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
}
