import Cocoa
extension Notification.Name {
    static let fpThumbnailCacheDidClear = Notification.Name("FPThumbnailCacheDidClear")
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var windowControllers: [ExplorerWindowController] = []
    private var previewWindowController: FPPreviewWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var commandPaletteController: CommandPaletteController?
    private var fuzzyJumpController: QyvroFuzzyJumpController?
    private var sessionSaveWorkItem: DispatchWorkItem?
    private let sessionDefaultsKey = "QyvroWindowSessionV1"
    private var suppressExplorerReopenForClipboard = false
    private var clipboardReopenSuppressionGeneration = 0

    private var activeWorkspace: WorkspaceView? {
        if let controller = NSApp.keyWindow?.windowController as? ExplorerWindowController {
            return controller.workspace
        }
        return windowControllers.last { $0.window?.isVisible == true }?.workspace
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        FPActionLog.startSession(
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "?"
        )
        UserDefaults.standard.set(1500, forKey: "NSInitialToolTipDelay")
        FPPreferences.migrateGestureSettingsForVersionOne()
        FPStyle.migrateCyberEditorialForVersionTwo()
        FPStyle.migrateToObsidianAuroraVersionThree()
        FPStyle.migrateToStudioVersionFour()
        FPFinderTagStore.migrateLegacyAssignmentsIfNeeded()
        buildMenu()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languageChanged(_:)),
            name: .fpLanguageDidChange,
            object: nil
        )
        QyvroClipboardModule.shared.start()
        if let data = UserDefaults.standard.data(forKey: sessionDefaultsKey),
           let sessions = try? JSONDecoder().decode([FPWindowSession].self, from: data),
           !sessions.isEmpty {
            // Qyvro is deliberately a single-window file manager. Older
            // builds saved every open window independently, which reopened two
            // explorers after an update. Preserve all their folders by folding
            // the extra windows into tabs of one restored workspace.
            createWindow(session: mergedSingleWindowSession(from: sessions))
        } else {
            createWindow(session: nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        GlobalHotKeyCenter.shared.onSummon = { [weak self] in self?.summonExplorerWindow(nil) }
        GlobalHotKeyCenter.shared.onClipboard = { [weak self] in
            self?.toggleClipboardFromGlobalShortcut()
        }
        GlobalHotKeyCenter.shared.setEnabled(FPPreferences.summonHotKeyEnabled)
        verifyWindowAppeared()
    }

    /// Страховка на случай, если после запуска окно так и не появилось.
    ///
    /// Восстановление сессии иногда оставляло приложение вовсе без окон:
    /// процесс живой, значок в Доке есть, а показать нечего. Воспроизводится
    /// не всегда — похоже на гонку при развёртывании окна, — поэтому вместо
    /// поиска единственной причины проверяется результат. Если окна нет,
    /// открывается новое: пустой запуск для файлового менеджера бесполезен в
    /// любом случае.
    private func verifyWindowAppeared() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self else { return }
            let hasUsableWindow = self.windowControllers.contains { controller in
                guard let window = controller.window else { return false }
                return window.isVisible || window.isMiniaturized
            }
            guard !hasUsableWindow else { return }
            FPActionLog.action("после запуска окна не оказалось — открываю новое")
            self.createWindow(session: nil)
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // ⌘E из любого приложения: существующее окно Qyvro переезжает на текущий
    // рабочий стол (collectionBehavior .moveToActiveSpace), ничего не дублируя.
    @objc func summonExplorerWindow(_ sender: Any?) {
        let controller = (NSApp.keyWindow?.windowController as? ExplorerWindowController)
            ?? windowControllers.last(where: { $0.window?.isVisible == true })
            ?? windowControllers.last(where: { $0.window?.isMiniaturized == true })
            ?? windowControllers.last
        // Если живых окон не осталось — например, последнее закрыли крестиком —
        // вызов обязан открыть новое, иначе приложение работает без единого
        // окна и кажется зависшим.
        guard let controller,
              let window = controller.window,
              windowControllers.contains(where: { $0.window != nil }) else {
            createWindow(session: nil)
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // Повторное нажатие прячет проводник и возвращает фокус тому, с чем
        // человек работал. Так вызов превращается в переключатель: одна и та
        // же клавиша показывает окно и убирает его, не отвлекая на поиск
        // мышью.
        if NSApp.isActive,
           window.isVisible,
           !window.isMiniaturized,
           window.isKeyWindow {
            FPActionLog.action("проводник свёрнут повторным вызовом")
            window.level = .normal
            // Окно именно убирается с экрана, а не просто прячется вместе с
            // приложением. Скрытие снимается любой активацией — например
            // показом буфера по ⇧⌘V, — и тогда проводник всплывал рядом,
            // хотя его не звали. Убранное окно возвращается только явным
            // вызовом.
            window.orderOut(nil)
            NSApp.hide(nil)
            return
        }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        // Снятие скрытия обязательно и отдельно: `activate` спрятанное
        // приложение не разворачивает. Без этого вызова повторное нажатие
        // работало в одну сторону — спрятать могло, показать нет, и окно
        // выглядело пропавшим насовсем.
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Окно поднимается над всеми, включая чужие приложения: смысл вызова
        // в том, чтобы проводник оказался перед глазами сразу, а не встал
        // где-то в стопке. Уровень возвращается к обычному, как только окно
        // получило фокус, иначе оно мешало бы поверх всего остального.
        window.level = .floating
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        FPActionLog.action("вызов проводника поверх окон")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak window] in
            guard let window, !FPPreferences.keepsExplorerOnTop else { return }
            window.level = .normal
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveSessionNow()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        windowControllers
            .filter { $0.window?.isVisible == true && $0.window?.isMiniaturized == false }
            .forEach { $0.workspace.refreshVisiblePanels() }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Qyvro owns global ⌘E and the clipboard watcher. Closing the explorer
        // hides its window, while ⌘Q remains the explicit way to quit the app.
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // A nonactivating clipboard panel may briefly make AppKit send a
        // reopen request when every explorer window is hidden. ⇧⌘V must show
        // only the clipboard, never summon the file manager beside it.
        if suppressExplorerReopenForClipboard {
            return false
        }
        if !flag {
            summonExplorerWindow(nil)
        }
        return true
    }

    private func toggleClipboardFromGlobalShortcut() {
        clipboardReopenSuppressionGeneration += 1
        let generation = clipboardReopenSuppressionGeneration
        suppressExplorerReopenForClipboard = true
        QyvroClipboardModule.shared.toggle(activatePanel: false)

        // Keep the guard through the panel's 0.20 s presentation transition.
        // A newer shortcut press owns the new guard window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.clipboardReopenSuppressionGeneration == generation else { return }
            self.suppressExplorerReopenForClipboard = false
        }
    }

    @objc private func newWindow(_ sender: Any?) {
        if let workspace = activeWorkspace ?? windowControllers.first?.workspace {
            summonExplorerWindow(nil)
            workspace.newTab(sender)
        } else {
            createWindow(session: nil)
        }
    }

    private func createWindow(session: FPWindowSession?) {
        // There must never be two explorer windows. Auxiliary settings,
        // clipboard and Quick Look panels are intentionally not part of this
        // collection.
        guard windowControllers.isEmpty else {
            summonExplorerWindow(nil)
            return
        }
        let controller = ExplorerWindowController(
            startURL: FileManager.default.homeDirectoryForCurrentUser,
            session: session,
            quickLookHandler: { [weak self] request in self?.showQuickLook(request) }
        )
        controller.onSessionChanged = { [weak self] in self?.scheduleSessionSave() }
        windowControllers.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        scheduleSessionSave()
    }

    private func scheduleSessionSave() {
        sessionSaveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveSessionNow() }
        sessionSaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private func saveSessionNow() {
        guard let session = windowControllers.first?.sessionState,
              let data = try? JSONEncoder().encode([session]) else { return }
        UserDefaults.standard.set(data, forKey: sessionDefaultsKey)
    }

    private func mergedSingleWindowSession(from sessions: [FPWindowSession]) -> FPWindowSession {
        guard var primary = sessions.last else {
            preconditionFailure("mergedSingleWindowSession requires at least one session")
        }

        if primary.panes.isEmpty {
            primary.panes = [
                FPPaneSession(
                    tabPaths: [FileManager.default.homeDirectoryForCurrentUser.path],
                    activeIndex: 0
                )
            ]
            primary.activePaneIndex = 0
        }

        let destinationIndex = min(max(primary.activePaneIndex, 0), primary.panes.count - 1)
        var knownPaths = Set(primary.panes.flatMap(\.tabPaths))
        for oldWindow in sessions.dropLast() {
            for pane in oldWindow.panes {
                for path in pane.tabPaths where !path.isEmpty && knownPaths.insert(path).inserted {
                    primary.panes[destinationIndex].tabPaths.append(path)
                }
            }
        }
        let tabCount = primary.panes[destinationIndex].tabPaths.count
        primary.panes[destinationIndex].activeIndex = min(
            max(primary.panes[destinationIndex].activeIndex, 0),
            max(0, tabCount - 1)
        )
        return primary
    }

    /// Просмотр идёт через собственное окно: в системную панель Quick Look
    /// нельзя добавить ни значок отметки поверх кадра, ни вторую панель для
    /// сравнения вариантов.
    private func showQuickLook(_ request: FPQuickLookRequest) {
        guard !request.entries.isEmpty else { return }
        // Открытый просмотрщик не пересоздаётся: выбранный в проводнике файл
        // встаёт в выделенную панель, соседние остаются на своих кадрах.
        if let existing = previewWindowController, existing.isPresenting {
            existing.replaceFocusedPane(with: request)
            return
        }
        // Выбор файла в сетке не должен распахивать просмотрщик — он лишь
        // подставляет кадр в уже открытый.
        if request.updatesOpenPreviewOnly { return }
        let controller = previewWindowController ?? {
            let created = FPPreviewWindowController()
            created.onNeedsRefresh = { [weak self] in
                self?.activeWorkspace?.refreshVisiblePanels(force: true)
            }
            previewWindowController = created
            return created
        }()
        controller.present(request)
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let clipboardItem = appMenu.addItem(withTitle: L("Буфер обмена", "Clipboard History"), action: #selector(showClipboard(_:)), keyEquivalent: "")
        clipboardItem.target = self
        let settingsItem = appMenu.addItem(withTitle: L("Настройки…", "Settings…"), action: #selector(showSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        let updatesItem = appMenu.addItem(withTitle: L("Проверить обновления…", "Check for Updates…"), action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        updatesItem.target = self
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: L("Завершить \(appDisplayName)", "Quit \(appDisplayName)"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: L("Файл", "File"))
        fileMenu.addItem(withTitle: L("Дублировать текущую вкладку", "Duplicate Current Tab"), action: #selector(newWindow(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: L("Новая вкладка", "New Tab"), action: #selector(newTab(_:)), keyEquivalent: "t")
        let reopenTabItem = fileMenu.addItem(withTitle: L("Открыть закрытую вкладку", "Reopen Closed Tab"), action: #selector(reopenClosedTab(_:)), keyEquivalent: "t")
        reopenTabItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(withTitle: L("Закрыть вкладку", "Close Tab"), action: #selector(closeTab(_:)), keyEquivalent: "w")
        fileMenu.addItem(withTitle: L("Открыть папку…", "Open Folder…"), action: #selector(openFolder(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: L("Новая папка", "New Folder"), action: #selector(newFolder(_:)), keyEquivalent: "N")
        fileMenu.addItem(withTitle: L("Переименовать", "Rename"), action: #selector(renameSelection(_:)), keyEquivalent: "\r")
        let batchRename = fileMenu.addItem(withTitle: L("Пакетное переименование…", "Batch Rename…"), action: #selector(batchRenameSelection(_:)), keyEquivalent: "r")
        batchRename.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(withTitle: L("Инспектор", "Inspector"), action: #selector(inspectSelection(_:)), keyEquivalent: "i")
        fileMenu.addItem(NSMenuItem.separator())
        let copyPathItem = fileMenu.addItem(withTitle: L("Скопировать путь", "Copy Path"), action: #selector(copyPaths(_:)), keyEquivalent: "c")
        copyPathItem.keyEquivalentModifierMask = [.command, .shift]
        let revealItem = fileMenu.addItem(withTitle: L("Показать в Finder", "Reveal in Finder"), action: #selector(revealSelection(_:)), keyEquivalent: "r")
        revealItem.keyEquivalentModifierMask = [.command, .control]
        fileMenu.addItem(.separator())
        let logItem = fileMenu.addItem(
            withTitle: L("Журнал действий…", "Action Log…"),
            action: #selector(revealActionLog(_:)),
            keyEquivalent: ""
        )
        logItem.target = self
        logItem.toolTip = L("Открыть файл журнала: в нём видно, что и когда нажималось", "Reveal the action log file")
        fileMenu.addItem(withTitle: L("Переместить в корзину", "Move to Trash"), action: #selector(trashSelection(_:)), keyEquivalent: "\u{8}")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: L("Правка", "Edit"))
        let undoItem = editMenu.addItem(withTitle: L("Отменить", "Undo"), action: #selector(undoFileOperation(_:)), keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: L("Повторить", "Redo"), action: #selector(redoFileOperation(_:)), keyEquivalent: "z")
        undoItem.target = self
        redoItem.target = self
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(NSMenuItem.separator())
        let cutItem = editMenu.addItem(withTitle: L("Вырезать", "Cut"), action: #selector(cutFiles(_:)), keyEquivalent: "x")
        let copyItem = editMenu.addItem(withTitle: L("Копировать", "Copy"), action: #selector(copyFiles(_:)), keyEquivalent: "c")
        let pasteItem = editMenu.addItem(withTitle: L("Вставить", "Paste"), action: #selector(pasteFiles(_:)), keyEquivalent: "v")
        [cutItem, copyItem, pasteItem].forEach { $0.target = self }
        editMenu.addItem(withTitle: L("Выбрать всё", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let goItem = NSMenuItem()
        let goMenu = NSMenu(title: L("Переход", "Go"))
        let historyBack = goMenu.addItem(
            withTitle: L("Назад", "Back"),
            action: #selector(goBack(_:)),
            keyEquivalent: "\u{F702}"
        )
        historyBack.keyEquivalentModifierMask = [.command]
        let historyForward = goMenu.addItem(
            withTitle: L("Вперёд", "Forward"),
            action: #selector(goForward(_:)),
            keyEquivalent: "\u{F703}"
        )
        historyForward.keyEquivalentModifierMask = [.command]
        let goUpItem = goMenu.addItem(withTitle: L("В родительскую папку", "Enclosing Folder"), action: #selector(goUp(_:)), keyEquivalent: "\u{F700}")
        goUpItem.keyEquivalentModifierMask = [.command]
        let fuzzyJumpItem = goMenu.addItem(withTitle: L("Быстрый переход к папке…", "Fuzzy Jump to Folder…"), action: #selector(showFuzzyJump(_:)), keyEquivalent: "j")
        fuzzyJumpItem.keyEquivalentModifierMask = [.command]
        let recentsItem = goMenu.addItem(withTitle: L("Недавние файлы и папки", "Recent Files & Folders"), action: #selector(openRecents(_:)), keyEquivalent: "r")
        recentsItem.keyEquivalentModifierMask = [.command, .option]
        goMenu.addItem(NSMenuItem.separator())
        for number in 1...9 {
            let title = number == 9 ? L("Последняя вкладка", "Last Tab") : L("Вкладка \(number)", "Tab \(number)")
            let item = goMenu.addItem(
                withTitle: title,
                action: #selector(selectTabByNumber(_:)),
                keyEquivalent: String(number)
            )
            item.keyEquivalentModifierMask = [.command]
            item.tag = number
        }
        goItem.submenu = goMenu
        mainMenu.addItem(goItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: L("Вид", "View"))
        let quickLook = NSMenuItem(title: L("Быстрый просмотр", "Quick Preview"), action: #selector(quickLook(_:)), keyEquivalent: " ")
        quickLook.keyEquivalentModifierMask = []
        viewMenu.addItem(quickLook)
        let previewPanelItem = viewMenu.addItem(
            withTitle: L("Панель предпросмотра", "Preview & Inspector Sidebar"),
            action: #selector(togglePreview(_:)),
            keyEquivalent: "p"
        )
        previewPanelItem.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(withTitle: L("Новая панель", "Split Pane"), action: #selector(splitPane(_:)), keyEquivalent: "d")
        viewMenu.addItem(withTitle: L("Обновить", "Refresh"), action: #selector(reload(_:)), keyEquivalent: "r")
        viewMenu.addItem(withTitle: L("Скрытые файлы", "Show Hidden Files"), action: #selector(toggleHidden(_:)), keyEquivalent: ".")
        viewMenu.addItem(withTitle: L("Фокус на путь", "Focus Path"), action: #selector(focusPath(_:)), keyEquivalent: "l")
        viewMenu.addItem(withTitle: L("Фокус на поиск", "Focus Search"), action: #selector(focusSearch(_:)), keyEquivalent: "f")
        viewMenu.addItem(withTitle: L("Переключить список / плитку", "Toggle List / Grid"), action: #selector(toggleViewMode(_:)), keyEquivalent: "")
        let shelfItem = viewMenu.addItem(withTitle: L("Полка сбора", "Drop Shelf"), action: #selector(showDropShelf(_:)), keyEquivalent: "s")
        shelfItem.keyEquivalentModifierMask = [.command, .option]
        let diskAnalyzerItem = viewMenu.addItem(withTitle: L("Где пропало место?", "Disk Analyzer & Duplicates"), action: #selector(showDiskAnalyzer(_:)), keyEquivalent: "d")
        diskAnalyzerItem.keyEquivalentModifierMask = [.command, .option]
        let cycleLayoutItem = viewMenu.addItem(withTitle: L("Сменить макет окна", "Cycle Window Layout"), action: #selector(cycleWorkspaceLayout(_:)), keyEquivalent: "l")
        cycleLayoutItem.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(withTitle: L("Буфер обмена", "Clipboard History"), action: #selector(showClipboard(_:)), keyEquivalent: "")
        viewMenu.addItem(withTitle: L("Палитра команд…", "Command Palette…"), action: #selector(showCommandPalette(_:)), keyEquivalent: "k")
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: L("Окно", "Window"))
        windowMenu.addItem(withTitle: L("Показать или скрыть Qyvro", "Show or Hide Qyvro"), action: #selector(summonExplorerWindow(_:)), keyEquivalent: "e")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        for item in fileMenu.items + goMenu.items + viewMenu.items + windowMenu.items {
            if item.action != nil {
                item.target = self
            }
        }

        NSApp.mainMenu = mainMenu
    }

    @objc private func languageChanged(_ notification: Notification) {
        buildMenu()
        if let settings = settingsWindowController {
            let wasVisible = settings.window?.isVisible == true
            settings.close()
            settingsWindowController = nil
            if wasVisible {
                showSettings(nil)
            }
        }
        windowControllers.forEach { $0.workspace.refreshLocalization() }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        QyvroUpdateChecker.shared.checkForUpdates(interactive: true)
    }

    @objc func showFuzzyJump(_ sender: Any?) {
        if fuzzyJumpController == nil {
            fuzzyJumpController = QyvroFuzzyJumpController()
        }
        let currentFolder = activeWorkspace?.activeFolderURL ?? FileManager.default.homeDirectoryForCurrentUser
        let openTabs = activeWorkspace?.openTabURLs ?? []
        fuzzyJumpController?.present(currentFolder: currentFolder, openTabURLs: openTabs) { [weak self] url, inNewTab in
            guard let workspace = self?.activeWorkspace else { return }
            if inNewTab {
                workspace.openURLInNewTab(url)
            } else {
                workspace.openURLInActivePanel(url)
            }
        }
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.toggle(sender)
    }

    @objc func showClipboard(_ sender: Any?) {
        QyvroClipboardModule.shared.toggle()
    }

    @objc func showDropShelf(_ sender: Any?) {
        QyvroDropShelfModule.shared.toggle()
    }

    @objc func showDiskAnalyzer(_ sender: Any?) {
        if let workspace = activeWorkspace {
            workspace.openDiskAnalyzer(sender)
        } else {
            QyvroDiskAnalyzerModule.shared.show(rootURL: FileManager.default.homeDirectoryForCurrentUser)
        }
    }

    @objc func openRecents(_ sender: Any?) {
        activeWorkspace?.openRecents(sender)
    }

    @objc func cycleWorkspaceLayout(_ sender: Any?) {
        let all = QyvroWorkspaceLayout.allCases
        let current = QyvroWorkspaceLayout.current
        let nextIndex = ((all.firstIndex(of: current) ?? 0) + 1) % all.count
        QyvroWorkspaceLayout.setCurrent(all[nextIndex])
    }

    @objc func showCommandPalette(_ sender: Any?) {
        if commandPaletteController == nil {
            commandPaletteController = CommandPaletteController()
        }
        let commands: [FPCommandEntry] = [
            FPCommandEntry(title: L("Быстрый переход к папке (Fuzzy Jump)", "Fuzzy Jump to Folder"), subtitle: L("Мгновенный поиск по недавним, закладкам и подпапкам — ⌘J", "Jump across recent folders, bookmarks, and subfolders — ⌘J"), symbol: "bolt.horizontal.fill") { [weak self] in self?.showFuzzyJump(nil) },
            FPCommandEntry(title: L("Макет: Студия · Остров (V4)", "Layout: Studio · Island (V4)"), subtitle: L("Парящая скруглённая сцена, крупный заголовок и капсулы фильтров", "Frameless floating canvas, unified hero header, and recessed filter tray"), symbol: "macwindow.on.rectangle") {
                QyvroWorkspaceLayout.setCurrent(.studioCanvas)
            },
            FPCommandEntry(title: L("Макет: Подиум (док снизу)", "Layout: Podium (Bottom Dock)"), subtitle: L("Широкая галерея без боковой панели и плавающий стеклянный док", "Wide gallery with floating glass bottom dock"), symbol: "dock.rectangle") {
                QyvroWorkspaceLayout.setCurrent(.floatingDock)
            },
            FPCommandEntry(title: L("Макет: Рейл (узкая панель)", "Layout: Edge Rail"), subtitle: L("Иконочная рейка слева с кольцом диска и вкладки снизу", "Slim vertical icon rail with disk ring"), symbol: "sidebar.squares.leading") {
                QyvroWorkspaceLayout.setCurrent(.edgeRail)
            },
            FPCommandEntry(title: L("Макет: Сайдбар (классика)", "Layout: Classic Sidebar"), subtitle: L("Полноразмерная боковая панель слева и вкладки сверху", "Full Finder-style sidebar and top tabs"), symbol: "sidebar.left") {
                QyvroWorkspaceLayout.setCurrent(.classicSidebar)
            },
            FPCommandEntry(title: L("Папки: Графит + корешок", "Folders: Graphite + Spine"), subtitle: L("Минималистичная тёмная обложка с приглушённым корешком темы", "Minimalist matte graphite front with muted theme spine"), symbol: "folder") {
                FPFolderIconStyle.setCurrent(.matteDuo)
            },
            FPCommandEntry(title: L("Папки: Тёмный сатин", "Folders: Dark Satin"), subtitle: L("Монохромная матовая папка в глубоком тоне темы", "Monotone deep-tinted matte folder"), symbol: "folder.fill") {
                FPFolderIconStyle.setCurrent(.monotoneSatin)
            },
            FPCommandEntry(title: L("Папки: Швейцарский кант", "Folders: Swiss Seam"), subtitle: L("Матовый графит с тонкой акцентной линией в сгибе", "Matte graphite with a crisp accent hairline seam"), symbol: "folder.badge.gearshape") {
                FPFolderIconStyle.setCurrent(.swissSeam)
            },
            FPCommandEntry(title: L("Язык интерфейса: Русский / English", "Switch Language: English / Русский"), subtitle: L("Мгновенно переключить язык приложения", "Toggle interface language immediately"), symbol: "globe") {
                FPLocalization.selectedLanguage = FPLocalization.isEnglish ? .ru : .en
            },
            FPCommandEntry(title: L("Проверить обновления…", "Check for Updates…"), subtitle: L("Проверить последний релиз Qyvro на GitHub", "Check latest Qyvro release on GitHub"), symbol: "arrow.triangle.2.circlepath") { [weak self] in self?.checkForUpdates(nil) },
            FPCommandEntry(title: L("Недавние файлы и папки", "Recent Files & Folders"), subtitle: L("Все новые загрузки и файлы по дате создания — ⌥⌘R", "Recently created and downloaded items — ⌥⌘R"), symbol: "clock.arrow.circlepath") { [weak self] in self?.openRecents(nil) },
            FPCommandEntry(title: L("Полка временного сбора", "Drop Shelf"), subtitle: L("Собрать файлы из разных папок и перенести пачкой — ⌥⌘S", "Stage files across folders and move, copy, or drag out — ⌥⌘S"), symbol: "tray.and.arrow.down") { [weak self] in self?.showDropShelf(nil) },
            FPCommandEntry(title: L("Где пропало место? / Дубликаты SHA-256", "Disk Analyzer & SHA-256 Duplicates"), subtitle: L("Анализ тяжёлых папок, файлов и точных дубликатов — ⌥⌘D", "Analyze large folders, heavy files, and exact duplicates — ⌥⌘D"), symbol: "chart.pie.fill") { [weak self] in self?.showDiskAnalyzer(nil) },
            FPCommandEntry(title: L("Новая вкладка", "New Tab"), subtitle: L("Открыть текущую папку в соседней вкладке", "Open current folder in a new tab"), symbol: "plus.square") { [weak self] in self?.activeWorkspace?.newTab(nil) },
            FPCommandEntry(title: L("Новая панель", "Split Pane"), subtitle: L("Разделить текущее окно", "Split active window side by side"), symbol: "rectangle.split.2x1") { [weak self] in self?.activeWorkspace?.splitPane(nil) },
            FPCommandEntry(title: L("Новая папка", "New Folder"), subtitle: L("Создать папку в текущем каталоге", "Create a new folder here"), symbol: "folder.badge.plus") { [weak self] in self?.activeWorkspace?.newFolder(nil) },
            FPCommandEntry(title: L("Новый текстовый файл", "New Text File"), subtitle: L("Создать пустой .txt и сразу переименовать", "Create an empty .txt file"), symbol: "doc.badge.plus") { [weak self] in self?.activeWorkspace?.newTextFile(nil) },
            FPCommandEntry(title: L("Быстрый просмотр", "Quick Preview"), subtitle: L("Открыть выбранные объекты в просмотрщике — Space", "Open built-in media viewer — Space"), symbol: "eye") { [weak self] in self?.activeWorkspace?.quickLook(nil) },
            FPCommandEntry(title: L("Панель предпросмотра", "Preview & Inspector Sidebar"), subtitle: L("Показать сведения справа — ⌥⌘P", "Toggle right-side inspector — ⌥⌘P"), symbol: "sidebar.right") { [weak self] in self?.activeWorkspace?.togglePreview(nil) },
            FPCommandEntry(title: L("Пакетное переименование", "Studio Batch Rename"), subtitle: L("Переименовать несколько выбранных объектов — ⌘⇧R", "Batch rename with live preview — ⌘⇧R"), symbol: "textformat") { [weak self] in self?.activeWorkspace?.batchRenameSelection(nil) },
            FPCommandEntry(title: L("Открыть в Terminal", "Open in Terminal"), subtitle: L("Открыть текущую или выбранную папку в Terminal", "Open current folder in Terminal"), symbol: "terminal") { [weak self] in self?.activeWorkspace?.openInTerminal(nil) },
            FPCommandEntry(title: L("Список / плитка", "Toggle List / Grid"), subtitle: L("Переключить представление текущей папки", "Switch current folder view mode"), symbol: "square.grid.2x2") { [weak self] in self?.activeWorkspace?.toggleViewMode(nil) },
            FPCommandEntry(title: L("Буфер обмена", "Clipboard History"), subtitle: L("Показать историю скопированного — \(QyvroClipboardShortcut.displayName)", "Open clipboard history — \(QyvroClipboardShortcut.displayName)"), symbol: "clipboard") { [weak self] in self?.showClipboard(nil) },
            FPCommandEntry(title: L("Настройки", "Settings"), subtitle: L("Темы, язык, прозрачность, сетка и жесты — ⌘,", "Themes, language, opacity, grid, and gestures — ⌘,"), symbol: "slider.horizontal.3") { [weak self] in self?.showSettings(nil) }
        ]
        commandPaletteController?.show(commands: commands)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undoFileOperation(_:)) {
            if let title = QyvroFileOperationHistory.shared.undoTitle {
                menuItem.title = L("Отменить \(title)", "Undo \(title)")
                return QyvroFileOperationHistory.shared.canUndo
            }
            menuItem.title = L("Отменить", "Undo")
            return NSApp.keyWindow?.firstResponder?.undoManager?.canUndo ?? false
        }
        if menuItem.action == #selector(redoFileOperation(_:)) {
            if let title = QyvroFileOperationHistory.shared.redoTitle {
                menuItem.title = L("Повторить \(title)", "Redo \(title)")
                return QyvroFileOperationHistory.shared.canRedo
            }
            menuItem.title = L("Повторить", "Redo")
            return NSApp.keyWindow?.firstResponder?.undoManager?.canRedo ?? false
        }
        if menuItem.action == #selector(toggleHidden(_:)) {
            menuItem.state = UserDefaults.standard.bool(forKey: "ShowHiddenFiles") ? .on : .off
        }
        if menuItem.action == #selector(togglePreview(_:)) {
            menuItem.state = activeWorkspace?.isPreviewPanelVisible == true ? .on : .off
        }
        if menuItem.action == #selector(reopenClosedTab(_:)) {
            return activeWorkspace?.canReopenClosedTab == true
        }
        return true
    }

    @objc private func undoFileOperation(_ sender: Any?) {
        guard QyvroFileOperationHistory.shared.canUndo else {
            NSApp.sendAction(Selector(("undo:")), to: nil, from: sender)
            return
        }
        QyvroFileOperationHistory.shared.performUndo { [weak self] result in
            self?.finishFileHistoryOperation(result)
        }
    }

    @objc private func redoFileOperation(_ sender: Any?) {
        guard QyvroFileOperationHistory.shared.canRedo else {
            NSApp.sendAction(Selector(("redo:")), to: nil, from: sender)
            return
        }
        QyvroFileOperationHistory.shared.performRedo { [weak self] result in
            self?.finishFileHistoryOperation(result)
        }
    }

    private func finishFileHistoryOperation(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(directories):
            directories.forEach { DirectorySnapshotCache.shared.invalidate($0) }
            windowControllers.forEach { $0.workspace.refreshVisiblePanels(force: true) }
        case let .failure(error):
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Файловую операцию не удалось выполнить безопасно"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func openFolder(_ sender: Any?) { activeWorkspace?.openFolder(sender) }
    @objc private func newTab(_ sender: Any?) { activeWorkspace?.newTab(sender) }
    @objc private func reopenClosedTab(_ sender: Any?) { activeWorkspace?.reopenClosedTab(sender) }
    @objc private func closeTab(_ sender: Any?) { activeWorkspace?.closeTab(sender) }
    @objc private func selectTabByNumber(_ sender: NSMenuItem) { activeWorkspace?.selectTabByNumber(sender) }
    @objc private func splitPane(_ sender: Any?) { activeWorkspace?.splitPane(sender) }
    @objc private func newFolder(_ sender: Any?) { activeWorkspace?.newFolder(sender) }
    @objc private func renameSelection(_ sender: Any?) { activeWorkspace?.renameSelection(sender) }
    @objc private func batchRenameSelection(_ sender: Any?) { activeWorkspace?.batchRenameSelection(sender) }
    @objc private func inspectSelection(_ sender: Any?) { activeWorkspace?.inspectSelection(sender) }
    @objc private func togglePreview(_ sender: Any?) { activeWorkspace?.togglePreview(sender) }
    @objc private func toggleViewMode(_ sender: Any?) { activeWorkspace?.toggleViewMode(sender) }
    @objc private func trashSelection(_ sender: Any?) { activeWorkspace?.trashSelection(sender) }
    /// Открывает журнал действий. Файл нужен, чтобы разбирать баги по
    /// фактической последовательности нажатий, а не по пересказу.
    @objc private func revealActionLog(_ sender: Any?) {
        let url = FPActionLog.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSWorkspace.shared.activateFileViewerSelecting([FPActionLog.directoryURL])
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func revealSelection(_ sender: Any?) { activeWorkspace?.revealSelection(sender) }
    @objc private func copyPaths(_ sender: Any?) { activeWorkspace?.copyPaths(sender) }
    /// Идёт ли сейчас правка текста.
    ///
    /// Cmd+C, Cmd+X и Cmd+V в меню отвечают за операции с файлами. Внутри
    /// текстового поля человек ждёт от них работы с текстом, а получал
    /// копирование файла — так не работали ни переименование, ни строка
    /// поиска. Когда курсор стоит в поле, действие уходит по цепочке
    /// откликов в само поле.
    private var isEditingText: Bool {
        NSApp.keyWindow?.firstResponder is NSText
    }

    @objc private func copyFiles(_ sender: Any?) {
        guard !isEditingText else {
            NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: sender)
            return
        }
        activeWorkspace?.copyFiles(sender)
    }

    @objc private func cutFiles(_ sender: Any?) {
        guard !isEditingText else {
            NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: sender)
            return
        }
        activeWorkspace?.cutFiles(sender)
    }

    @objc private func pasteFiles(_ sender: Any?) {
        guard !isEditingText else {
            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: sender)
            return
        }
        activeWorkspace?.pasteFiles(sender)
    }
    @objc private func goBack(_ sender: Any?) { activeWorkspace?.goBack(sender) }
    @objc private func goForward(_ sender: Any?) { activeWorkspace?.goForward(sender) }
    @objc private func goUp(_ sender: Any?) { activeWorkspace?.goUp(sender) }
    @objc private func reload(_ sender: Any?) { activeWorkspace?.reload(sender) }
    @objc private func toggleHidden(_ sender: Any?) { activeWorkspace?.toggleHidden(sender) }
    @objc private func focusPath(_ sender: Any?) { activeWorkspace?.focusPath(sender) }
    @objc private func focusSearch(_ sender: Any?) { activeWorkspace?.focusSearch(sender) }
    @objc private func quickLook(_ sender: Any?) { activeWorkspace?.quickLook(sender) }
}
