import Cocoa
import Quartz
import QuickLookThumbnailing
import ImageIO
import AVFoundation
import Carbon.HIToolbox
extension Notification.Name {
    static let fpThumbnailCacheDidClear = Notification.Name("FPThumbnailCacheDidClear")
}

private final class FPQuickLookCachedImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private static let quickLookStillImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff",
        "bmp", "webp", "avif"
    ]
    private static let quickLookImageExtensions =
        quickLookStillImageExtensions.union(["gif"])
    private static let quickLookVideoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "webm"
    ]

    private var windowControllers: [ExplorerWindowController] = []
    private var quickLookRequest: FPQuickLookRequest?
    private var quickLookEventMonitor: Any?
    private var quickLookCacheGeneration = UUID()
    private let quickLookRepresentations = FPQuickLookSessionCache<QLThumbnailRepresentation>()
    private var quickLookThumbnailRequests: [String: QLThumbnailGenerator.Request] = [:]
    private var quickLookPrefetchWorkItems: [DispatchWorkItem] = []
    private var quickLookVisitedCacheWorkItems: [String: DispatchWorkItem] = [:]
    private var quickLookVisitCounts: [String: Int] = [:]
    private var quickLookCachedImageView: FPQuickLookCachedImageView?
    private var quickLookIntrinsicSizes: [String: NSSize] = [:]
    private var quickLookIntrinsicSizeTasks: [String: Task<Void, Never>] = [:]
    private var quickLookResizeWorkItem: DispatchWorkItem?
    private var quickLookWindowAnchorCenter: NSPoint?
    private var quickLookLastTargetContentSize: NSSize?
    private var quickLookPresentationState: FPQuickLookPresentationState = .windowed
    private var quickLookWindowedAnchorCenter: NSPoint?
    private var previewWindowController: FPPreviewWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var commandPaletteController: CommandPaletteController?
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
        FPFinderTagStore.migrateLegacyAssignmentsIfNeeded()
        buildMenu()
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

    private func showSystemQuickLook(_ request: FPQuickLookRequest) {
        guard !request.entries.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        endQuickLookSession(removeMonitor: false)
        quickLookRequest = request
        quickLookCacheGeneration = UUID()
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = min(max(request.initialIndex, 0), request.entries.count - 1)
        quickLookWindowAnchorCenter = centeredQuickLookAnchor(for: panel)
        let initialURL = request.entries[panel.currentPreviewItemIndex].url
        resizeQuickLookPanel(panel, for: initialURL)
        installQuickLookCachedImageView(in: panel)
        installQuickLookEventMonitor(for: panel)
        panel.makeKeyAndOrderFront(nil)
        // Для видео и прочих типов без заранее известного размера
        // `resizeQuickLookPanel` выходит раньше и геометрию не трогает. Панель
        // всё равно должна появиться по центру, а не там, где её оставил
        // системный Quick Look.
        centerQuickLookPanelIfNeeded(panel)
        quickLookIndexDidChange(panel.currentPreviewItemIndex)
    }

    private func centerQuickLookPanelIfNeeded(_ panel: QLPreviewPanel) {
        guard !panel.isInFullScreenMode,
              let anchorCenter = quickLookWindowAnchorCenter,
              let visibleFrame = quickLookHostScreen(for: panel)?.visibleFrame else { return }
        let targetFrame = FPQuickLookPanelSizing.anchoredFrame(
            frameSize: panel.frame.size,
            center: anchorCenter,
            visibleFrame: visibleFrame
        )
        guard hypot(
            targetFrame.origin.x - panel.frame.origin.x,
            targetFrame.origin.y - panel.frame.origin.y
        ) > 2 else { return }
        panel.setFrame(targetFrame, display: true, animate: false)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        quickLookRequest?.entries.count ?? 0
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard let entries = quickLookRequest?.entries,
              index >= 0,
              index < entries.count else { return nil }
        return entries[index].url as NSURL
    }

    func previewPanelWillClose(_ panel: QLPreviewPanel!) {
        endQuickLookSession(removeMonitor: true)
    }

    private func installQuickLookEventMonitor(for panel: QLPreviewPanel) {
        if let quickLookEventMonitor {
            NSEvent.removeMonitor(quickLookEventMonitor)
        }
        quickLookEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown]
        ) { [weak self, weak panel] event in
            guard let self, let panel, panel.isVisible else {
                return event
            }

            if event.type == .leftMouseDown {
                guard event.window === panel,
                      event.clickCount == 2,
                      self.isQuickLookTopBarHit(event, in: panel) else {
                    return event
                }
                self.toggleQuickLookPanelFullScreen(panel)
                return nil
            }

            guard panel.isKeyWindow,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
                return event
            }
            switch event.keyCode {
            case 53 where self.quickLookPresentationState.isFullScreenOrTransitioning
                || panel.isInFullScreenMode:
                self.exitQuickLookFullScreen(panel)
            case 123:
                self.moveQuickLook(panel: panel, by: -1) // ←
            case 124:
                self.moveQuickLook(panel: panel, by: 1)  // →
            case 125:
                self.moveQuickLookVertically(panel: panel, direction: 1)  // ↓
            case 126:
                self.moveQuickLookVertically(panel: panel, direction: -1) // ↑
            case 51:
                self.trashCurrentQuickLookItem(panel) // ⌫
            case 3:
                self.toggleQuickLookItemFlag(panel)   // F
            default: return event
            }
            return nil
        }
    }

    private func isQuickLookTopBarHit(
        _ event: NSEvent,
        in panel: QLPreviewPanel
    ) -> Bool {
        let point = event.locationInWindow
        guard point.x >= 0,
              point.x <= panel.frame.width,
              point.y >= 0,
              point.y <= panel.frame.height else { return false }

        if panel.isInFullScreenMode {
            // Quick Look hides the ordinary title bar in full screen. Keep a
            // small top-edge target so another double click can still return
            // to the windowed panel without affecting image navigation.
            return point.y >= panel.frame.height - 64
        }

        let contentTop = panel.contentLayoutRect.maxY
        if panel.frame.height - contentTop > 4 {
            return point.y >= contentTop
        }
        // Some macOS releases draw Quick Look under a full-size title bar, so
        // contentLayoutRect contains the toolbar as well.
        return point.y >= panel.frame.height - 64
    }

    private func toggleQuickLookPanelFullScreen(_ panel: QLPreviewPanel) {
        if panel.isInFullScreenMode || quickLookPresentationState == .fullScreen {
            exitQuickLookFullScreen(panel)
            return
        }
        guard quickLookPresentationState == .windowed else { return }

        quickLookPresentationState = .enteringFullScreen
        quickLookWindowedAnchorCenter = quickLookWindowAnchorCenter
        let didEnter = panel.enterFullScreenMode(
            panel.screen,
            withOptions: nil
        )
        guard didEnter else {
            quickLookPresentationState = .windowed
            quickLookWindowedAnchorCenter = nil
            NSSound.beep()
            return
        }

        quickLookPresentationState = .fullScreen
        refreshQuickLookOverlay(in: panel)
    }

    @objc private func toggleQuickLookFullScreen(_ sender: Any?) {
        guard let panel = QLPreviewPanel.sharedPreviewPanelExists()
                ? QLPreviewPanel.shared()
                : nil,
              panel.isVisible,
              quickLookRequest != nil else {
            NSSound.beep()
            return
        }
        toggleQuickLookPanelFullScreen(panel)
    }

    private func exitQuickLookFullScreen(_ panel: QLPreviewPanel) {
        guard quickLookPresentationState != .exitingFullScreen else { return }
        guard panel.isInFullScreenMode
                || quickLookPresentationState.isFullScreenOrTransitioning else {
            return
        }

        quickLookPresentationState = .exitingFullScreen
        if panel.isInFullScreenMode {
            panel.exitFullScreenMode(options: nil)
        }

        // Let Quick Look restore its own window before resuming our
        // per-file geometry. The request and session cache stay untouched.
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, panel.isVisible else { return }
            self.quickLookPresentationState = .windowed
            self.quickLookWindowAnchorCenter =
                self.quickLookWindowedAnchorCenter
                ?? self.centeredQuickLookAnchor(for: panel)
            self.quickLookWindowedAnchorCenter = nil
            self.quickLookLastTargetContentSize = nil
            self.refreshQuickLookOverlay(in: panel)
            self.resizeQuickLookPanelForCurrentItem(panel)
        }
    }

    private func refreshQuickLookOverlay(in panel: QLPreviewPanel) {
        installQuickLookCachedImageView(in: panel)
        guard let request = quickLookRequest,
              request.entries.indices.contains(panel.currentPreviewItemIndex) else {
            return
        }
        displayCachedQuickLookImage(
            for: request.entries[panel.currentPreviewItemIndex].url,
            in: panel
        )
    }

    private func resizeQuickLookPanelForCurrentItem(_ panel: QLPreviewPanel) {
        guard let request = quickLookRequest,
              request.entries.indices.contains(panel.currentPreviewItemIndex) else {
            return
        }
        resizeQuickLookPanel(
            panel,
            for: request.entries[panel.currentPreviewItemIndex].url
        )
    }

    private func moveQuickLook(panel: QLPreviewPanel, by delta: Int) {
        guard let request = quickLookRequest, !request.entries.isEmpty else { return }
        let oldIndex = min(max(panel.currentPreviewItemIndex, 0), request.entries.count - 1)
        let newIndex = min(max(oldIndex + delta, 0), request.entries.count - 1)
        guard newIndex != oldIndex else {
            NSSound.beep()
            return
        }
        panel.currentPreviewItemIndex = newIndex
        quickLookIndexDidChange(newIndex)
    }

    private func moveQuickLookVertically(panel: QLPreviewPanel, direction: Int) {
        guard let request = quickLookRequest, !request.entries.isEmpty else { return }
        let currentIndex = min(max(panel.currentPreviewItemIndex, 0), request.entries.count - 1)
        let currentVisualIndex = request.entries[currentIndex].visualIndex
        let targetVisualIndex = currentVisualIndex + direction * max(1, request.columnCount)
        let candidates = request.entries.indices.filter { index in
            direction > 0
                ? request.entries[index].visualIndex > currentVisualIndex
                : request.entries[index].visualIndex < currentVisualIndex
        }
        guard let newIndex = candidates.min(by: {
            abs(request.entries[$0].visualIndex - targetVisualIndex)
                < abs(request.entries[$1].visualIndex - targetVisualIndex)
        }) else {
            NSSound.beep()
            return
        }
        panel.currentPreviewItemIndex = newIndex
        quickLookIndexDidChange(newIndex)
    }

    /// Разбор пачки: ⌫ отправляет текущий кадр в корзину и сразу показывает
    /// следующий, не закрывая превью.
    ///
    /// Удаление проходит через системную корзину и записывается в историю
    /// операций, поэтому промах лечится обычной отменой — при скорости
    /// «пятьдесят картинок за подход» это обязательное условие.
    private func trashCurrentQuickLookItem(_ panel: QLPreviewPanel) {
        guard let request = quickLookRequest,
              request.entries.indices.contains(panel.currentPreviewItemIndex) else {
            NSSound.beep()
            return
        }
        let index = panel.currentPreviewItemIndex
        let url = request.entries[index].url

        var resultingURL: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        } catch {
            NSSound.beep()
            return
        }
        if let trashURL = resultingURL as URL? {
            QyvroFileOperationHistory.shared.recordTrash(
                [.init(original: url, trashURL: trashURL)]
            )
        }

        var entries = request.entries
        entries.remove(at: index)
        refreshPanelAfterQuickLookMutation()

        guard !entries.isEmpty else {
            panel.close()
            return
        }

        let nextIndex = min(index, entries.count - 1)
        quickLookRequest = FPQuickLookRequest(
            entries: entries,
            initialIndex: nextIndex,
            columnCount: request.columnCount,
            onIndexChanged: request.onIndexChanged
        )
        panel.reloadData()
        panel.currentPreviewItemIndex = nextIndex
        quickLookIndexDidChange(nextIndex)
    }

    /// F ставит и снимает отметку «отобрано», не выходя из просмотра.
    private func toggleQuickLookItemFlag(_ panel: QLPreviewPanel) {
        guard let request = quickLookRequest,
              request.entries.indices.contains(panel.currentPreviewItemIndex) else {
            NSSound.beep()
            return
        }
        let url = request.entries[panel.currentPreviewItemIndex].url
        let flagged = FPFinderTagStore.isFlagged(url: url)
        do {
            try FPFinderTagStore.setFlag(!flagged, on: url)
        } catch {
            NSSound.beep()
            return
        }
        refreshPanelAfterQuickLookMutation()
    }

    /// Сетка под превью должна догнать изменение сразу: значок отметки
    /// появляется, удалённый файл пропадает.
    private func refreshPanelAfterQuickLookMutation() {
        activeWorkspace?.refreshVisiblePanels(force: true)
    }

    private func quickLookIndexDidChange(_ index: Int) {
        guard let request = quickLookRequest,
              request.entries.indices.contains(index) else { return }
        let current = request.entries[index]
        let cacheKey = current.url.standardizedFileURL.path
        quickLookVisitCounts[cacheKey, default: 0] += 1
        request.onIndexChanged?(current.url)
        if let panel = QLPreviewPanel.shared(), panel.isVisible {
            displayCachedQuickLookImage(for: current.url, in: panel)
            scheduleQuickLookResize(
                panel,
                for: current.url,
                expectedIndex: index
            )
        }

        cacheVisitedQuickLookPreview(current.url)
        scheduleQuickLookPrefetch(request: request, currentIndex: index)
    }

    private func installQuickLookCachedImageView(in panel: QLPreviewPanel) {
        guard let contentView = panel.contentView else { return }
        let imageView = quickLookCachedImageView ?? FPQuickLookCachedImageView(frame: contentView.bounds)
        quickLookCachedImageView = imageView
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.animates = false
        imageView.alphaValue = 0
        imageView.autoresizingMask = [.width, .height]
        imageView.frame = contentView.bounds
        if imageView.superview !== contentView {
            imageView.removeFromSuperview()
            contentView.addSubview(imageView, positioned: .above, relativeTo: nil)
        }
    }

    private func displayCachedQuickLookImage(for url: URL, in panel: QLPreviewPanel) {
        installQuickLookCachedImageView(in: panel)
        guard let imageView = quickLookCachedImageView else { return }
        let key = url.standardizedFileURL.path
        guard isQuickLookStillImage(url),
              let representation = quickLookRepresentations[key] else {
            imageView.image = nil
            imageView.alphaValue = 0
            return
        }
        imageView.image = representation.nsImage
        imageView.alphaValue = 1
        imageView.superview?.addSubview(imageView, positioned: .above, relativeTo: nil)
    }

    private func isQuickLookStillImage(_ url: URL) -> Bool {
        Self.quickLookStillImageExtensions.contains(
            url.pathExtension.lowercased()
        )
    }

    private func cacheVisitedQuickLookPreview(_ url: URL) {
        guard isQuickLookStillImage(url) else { return }
        let key = url.standardizedFileURL.path
        guard quickLookRepresentations[key] == nil,
              quickLookThumbnailRequests[key] == nil,
              quickLookVisitedCacheWorkItems[key] == nil else { return }
        let generation = quickLookCacheGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.quickLookCacheGeneration == generation else { return }
            self.quickLookVisitedCacheWorkItems.removeValue(forKey: key)
            self.warmQuickLookPreview(url)
        }
        quickLookVisitedCacheWorkItems[key] = work
        // Let Quick Look start decoding the current file first. The persistent
        // session copy is prepared just after that and never evicted until the
        // panel closes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
    }

    private func scheduleQuickLookResize(
        _ panel: QLPreviewPanel,
        for url: URL,
        expectedIndex: Int
    ) {
        guard panel.isVisible,
              !quickLookPresentationState.suppressesAutomaticResize,
              !panel.isInFullScreenMode,
              panel.currentPreviewItemIndex == expectedIndex else { return }
        quickLookResizeWorkItem?.cancel()
        resizeQuickLookPanel(panel, for: url)

        // QLPreviewPanel can commit its own content-driven frame one run-loop
        // later. Reassert the same geometry after that swap so navigating to a
        // small file cannot leave the panel permanently shrunken.
        let expectedPath = url.standardizedFileURL.path
        let generation = quickLookCacheGeneration
        let workItem = DispatchWorkItem { [weak self, weak panel] in
            guard let self,
                  let panel,
                  self.quickLookCacheGeneration == generation,
                  panel.isVisible,
                  !self.quickLookPresentationState.suppressesAutomaticResize,
                  !panel.isInFullScreenMode,
                  panel.currentPreviewItemIndex == expectedIndex,
                  let request = self.quickLookRequest,
                  request.entries.indices.contains(expectedIndex),
                  request.entries[expectedIndex].url.standardizedFileURL.path == expectedPath else {
                return
            }
            self.resizeQuickLookPanel(panel, for: url)
        }
        quickLookResizeWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.10,
            execute: workItem
        )
    }

    /// Экран, на котором пользователь сейчас работает.
    ///
    /// `panel.screen` бесполезен до первого показа панели — у только что
    /// созданной `QLPreviewPanel.shared()` фрейм ещё нулевой. Поэтому опорным
    /// считается экран активного окна Qyvro, а панель уже подтягивается к нему.
    private func quickLookHostScreen(for panel: QLPreviewPanel) -> NSScreen? {
        if panel.isVisible, let panelScreen = panel.screen {
            return panelScreen
        }
        let hostWindow = windowControllers.first(where: { $0.window?.isKeyWindow == true })?.window
            ?? windowControllers.first(where: { $0.window?.isVisible == true })?.window
            ?? windowControllers.first?.window
        return hostWindow?.screen ?? NSScreen.main
    }

    /// Центр рабочей области экрана — точка привязки для новой сессии превью.
    ///
    /// Раньше привязка бралась из `panel.frame` ещё до `makeKeyAndOrderFront`,
    /// то есть из нулевого фрейма. Центр (0, 0) затем прижимался `anchoredFrame`
    /// к границам экрана, и окно предпросмотра открывалось в нижнем левом углу.
    private func centeredQuickLookAnchor(for panel: QLPreviewPanel) -> NSPoint {
        guard let visibleFrame = quickLookHostScreen(for: panel)?.visibleFrame else {
            return NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        }
        return NSPoint(x: visibleFrame.midX, y: visibleFrame.midY)
    }

    private func resizeQuickLookPanel(
        _ panel: QLPreviewPanel,
        for url: URL
    ) {
        guard !quickLookPresentationState.suppressesAutomaticResize,
              !panel.isInFullScreenMode else { return }
        guard let intrinsicSize = quickLookIntrinsicPointSize(for: url) else {
            scheduleQuickLookVideoSizeLoad(for: url)
            return
        }
        guard
              intrinsicSize.width > 1,
              intrinsicSize.height > 1 else { return }
        guard let visibleFrame = quickLookHostScreen(for: panel)?.visibleFrame else { return }

        let contentSize = FPQuickLookPanelSizing.contentSize(
            for: intrinsicSize,
            visibleFrame: visibleFrame
        )
        var targetFrame = panel.frameRect(
            forContentRect: NSRect(origin: .zero, size: contentSize)
        )
        let anchorCenter = quickLookWindowAnchorCenter
            ?? centeredQuickLookAnchor(for: panel)
        quickLookWindowAnchorCenter = anchorCenter
        targetFrame = FPQuickLookPanelSizing.anchoredFrame(
            frameSize: targetFrame.size,
            center: anchorCenter,
            visibleFrame: visibleFrame
        )
        quickLookLastTargetContentSize = contentSize

        let sizeDelta = hypot(
            targetFrame.width - panel.frame.width,
            targetFrame.height - panel.frame.height
        )
        let positionDelta = hypot(
            targetFrame.origin.x - panel.frame.origin.x,
            targetFrame.origin.y - panel.frame.origin.y
        )
        guard sizeDelta > 2 || positionDelta > 2 else { return }
        // Animating an NSWindow resize while Quick Look swaps and decodes its
        // content forces several expensive layouts for every arrow press.
        // Cached images then feel slower than they actually are. Commit the
        // final geometry once; Quick Look keeps its lightweight content
        // transition and decoded session images remain immediately visible.
        panel.setFrame(targetFrame, display: true, animate: false)
    }

    private func quickLookIntrinsicPointSize(for url: URL) -> NSSize? {
        let cacheKey = url.standardizedFileURL.path
        if let cached = quickLookIntrinsicSizes[cacheKey] {
            return cached
        }
        let extensionName = url.pathExtension.lowercased()
        if Self.quickLookImageExtensions.contains(extensionName),
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
           let height = properties[kCGImagePropertyPixelHeight] as? NSNumber {
            let backingScale = max(
                panelBackingScaleForQuickLook(),
                1
            )
            let size = NSSize(
                width: CGFloat(truncating: width) / backingScale,
                height: CGFloat(truncating: height) / backingScale
            )
            quickLookIntrinsicSizes[cacheKey] = size
            return size
        }

        if extensionName == "pdf",
           let document = CGPDFDocument(url as CFURL),
           let page = document.page(at: 1) {
            let size = page.getBoxRect(.mediaBox).size
            quickLookIntrinsicSizes[cacheKey] = size
            return size
        }
        return nil
    }

    private func scheduleQuickLookVideoSizeLoad(for url: URL) {
        let extensionName = url.pathExtension.lowercased()
        guard Self.quickLookVideoExtensions.contains(extensionName) else { return }
        let cacheKey = url.standardizedFileURL.path
        guard quickLookIntrinsicSizes[cacheKey] == nil,
              quickLookIntrinsicSizeTasks[cacheKey] == nil else { return }

        let generation = quickLookCacheGeneration
        let task = Task { @MainActor [weak self] in
            do {
                let asset = AVURLAsset(url: url)
                guard let track = try await asset.loadTracks(
                    withMediaType: .video
                ).first else {
                    self?.quickLookIntrinsicSizeTasks.removeValue(
                        forKey: cacheKey
                    )
                    return
                }
                async let naturalSize = track.load(.naturalSize)
                async let preferredTransform = track.load(.preferredTransform)
                let (loadedSize, loadedTransform) = try await (
                    naturalSize,
                    preferredTransform
                )
                let transformed = loadedSize.applying(loadedTransform)
                guard let self,
                      !Task.isCancelled,
                      self.quickLookCacheGeneration == generation else {
                    return
                }
                self.quickLookIntrinsicSizeTasks.removeValue(forKey: cacheKey)
                let size = NSSize(
                    width: abs(transformed.width),
                    height: abs(transformed.height)
                )
                guard size.width > 1, size.height > 1 else { return }
                self.quickLookIntrinsicSizes[cacheKey] = size

                guard let panel = QLPreviewPanel.shared(),
                      panel.isVisible,
                      let request = self.quickLookRequest,
                      request.entries.indices.contains(
                        panel.currentPreviewItemIndex
                      ),
                      request.entries[
                        panel.currentPreviewItemIndex
                      ].url.standardizedFileURL.path == cacheKey else {
                    return
                }
                self.resizeQuickLookPanel(panel, for: url)
            } catch {
                self?.quickLookIntrinsicSizeTasks.removeValue(forKey: cacheKey)
            }
        }
        quickLookIntrinsicSizeTasks[cacheKey] = task
    }

    private func panelBackingScaleForQuickLook() -> CGFloat {
        QLPreviewPanel.shared()?.screen?.backingScaleFactor
            ?? windowControllers.first?.window?.screen?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
    }

    private func scheduleQuickLookPrefetch(
        request: FPQuickLookRequest,
        currentIndex: Int
    ) {
        quickLookPrefetchWorkItems.forEach { $0.cancel() }
        quickLookPrefetchWorkItems.removeAll()

        let columns = max(1, request.columnCount)
        let orderedCandidates = [
            currentIndex + 1,
            currentIndex - 1,
            currentIndex + columns,
            currentIndex - columns
        ]
        var seen = Set<Int>()
        let candidates = orderedCandidates.filter {
            request.entries.indices.contains($0) && seen.insert($0).inserted
        }
        let desiredKeys = Set(candidates.map {
            request.entries[$0].url.standardizedFileURL.path
        })
        let visitedKeys = Set(quickLookVisitCounts.keys)
        let staleRequestKeys = quickLookThumbnailRequests.keys.filter {
            !desiredKeys.contains($0) && !visitedKeys.contains($0)
        }
        for key in staleRequestKeys {
            if let request = quickLookThumbnailRequests.removeValue(forKey: key) {
                QLThumbnailGenerator.shared.cancel(request)
            }
        }

        let generation = quickLookCacheGeneration
        for (order, candidate) in candidates.enumerated() {
            let url = request.entries[candidate].url
            let key = url.standardizedFileURL.path
            guard quickLookRepresentations[key] == nil,
                  quickLookThumbnailRequests[key] == nil else { continue }
            let work = DispatchWorkItem { [weak self] in
                guard let self,
                      self.quickLookCacheGeneration == generation,
                      QLPreviewPanel.shared()?.currentPreviewItemIndex == currentIndex else {
                    return
                }
                self.warmQuickLookPreview(url)
            }
            quickLookPrefetchWorkItems.append(work)
            DispatchQueue.main.asyncAfter(
                deadline: .now() + 0.045 + Double(order) * 0.055,
                execute: work
            )
        }
    }

    private func warmQuickLookPreview(_ url: URL) {
        let key = url.standardizedFileURL.path
        guard quickLookRepresentations[key] == nil,
              quickLookThumbnailRequests[key] == nil else { return }
        let generation = quickLookCacheGeneration
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: NSSize(width: 1600, height: 1000),
            scale: 1,
            representationTypes: .thumbnail
        )
        quickLookThumbnailRequests[key] = request
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            DispatchQueue.main.async {
                guard let self,
                      self.quickLookCacheGeneration == generation else { return }
                self.quickLookThumbnailRequests.removeValue(forKey: key)
                if let representation {
                    self.quickLookRepresentations[key] = representation
                    if let panel = QLPreviewPanel.shared(),
                       panel.isVisible,
                       let currentRequest = self.quickLookRequest,
                       currentRequest.entries.indices.contains(panel.currentPreviewItemIndex),
                       currentRequest.entries[panel.currentPreviewItemIndex].url.standardizedFileURL.path == key,
                       (self.quickLookVisitCounts[key] ?? 0) > 1 {
                        self.displayCachedQuickLookImage(
                            for: currentRequest.entries[panel.currentPreviewItemIndex].url,
                            in: panel
                        )
                    }
                }
            }
        }
    }

    private func endQuickLookSession(removeMonitor: Bool) {
        quickLookCacheGeneration = UUID()
        quickLookPrefetchWorkItems.forEach { $0.cancel() }
        quickLookPrefetchWorkItems.removeAll()
        quickLookVisitedCacheWorkItems.values.forEach { $0.cancel() }
        quickLookVisitedCacheWorkItems.removeAll()
        for request in quickLookThumbnailRequests.values {
            QLThumbnailGenerator.shared.cancel(request)
        }
        quickLookThumbnailRequests.removeAll()
        quickLookRepresentations.removeAll()
        quickLookVisitCounts.removeAll()
        quickLookCachedImageView?.removeFromSuperview()
        quickLookCachedImageView = nil
        quickLookIntrinsicSizeTasks.values.forEach { $0.cancel() }
        quickLookIntrinsicSizeTasks.removeAll()
        quickLookResizeWorkItem?.cancel()
        quickLookResizeWorkItem = nil
        quickLookIntrinsicSizes.removeAll()
        quickLookWindowAnchorCenter = nil
        quickLookLastTargetContentSize = nil
        quickLookPresentationState = .windowed
        quickLookWindowedAnchorCenter = nil
        quickLookRequest = nil
        if removeMonitor, let quickLookEventMonitor {
            NSEvent.removeMonitor(quickLookEventMonitor)
            self.quickLookEventMonitor = nil
        }
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        // ⇧⌘V is owned by the Carbon global hotkey. Giving the NSMenuItem the
        // same key equivalent can deliver the action twice while Qyvro is
        // active, so the menu remains a click-only fallback.
        let clipboardItem = appMenu.addItem(withTitle: "Буфер обмена", action: #selector(showClipboard(_:)), keyEquivalent: "")
        clipboardItem.target = self
        let settingsItem = appMenu.addItem(withTitle: "Настройки...", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Завершить \(appDisplayName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "Файл")
        fileMenu.addItem(withTitle: "Дублировать текущую вкладку", action: #selector(newWindow(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Новая вкладка", action: #selector(newTab(_:)), keyEquivalent: "t")
        fileMenu.addItem(withTitle: "Закрыть вкладку", action: #selector(closeTab(_:)), keyEquivalent: "w")
        fileMenu.addItem(withTitle: "Открыть папку...", action: #selector(openFolder(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Новая папка", action: #selector(newFolder(_:)), keyEquivalent: "N")
        fileMenu.addItem(withTitle: "Переименовать", action: #selector(renameSelection(_:)), keyEquivalent: "\r")
        let batchRename = fileMenu.addItem(withTitle: "Пакетное переименование...", action: #selector(batchRenameSelection(_:)), keyEquivalent: "r")
        batchRename.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(withTitle: "Инспектор", action: #selector(inspectSelection(_:)), keyEquivalent: "i")
        fileMenu.addItem(NSMenuItem.separator())
        let copyPathItem = fileMenu.addItem(withTitle: "Скопировать путь", action: #selector(copyPaths(_:)), keyEquivalent: "c")
        copyPathItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(withTitle: "Показать в Finder", action: #selector(revealSelection(_:)), keyEquivalent: "r")
        fileMenu.addItem(.separator())
        let logItem = fileMenu.addItem(
            withTitle: "Журнал действий…",
            action: #selector(revealActionLog(_:)),
            keyEquivalent: ""
        )
        logItem.target = self
        logItem.toolTip = "Открыть файл журнала: в нём видно, что и когда нажималось"
        fileMenu.addItem(withTitle: "Переместить в корзину", action: #selector(trashSelection(_:)), keyEquivalent: "\u{8}")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Правка")
        let undoItem = editMenu.addItem(withTitle: "Отменить", action: #selector(undoFileOperation(_:)), keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: "Повторить", action: #selector(redoFileOperation(_:)), keyEquivalent: "z")
        undoItem.target = self
        redoItem.target = self
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(NSMenuItem.separator())
        let cutItem = editMenu.addItem(withTitle: "Вырезать", action: #selector(cutFiles(_:)), keyEquivalent: "x")
        let copyItem = editMenu.addItem(withTitle: "Копировать", action: #selector(copyFiles(_:)), keyEquivalent: "c")
        let pasteItem = editMenu.addItem(withTitle: "Вставить", action: #selector(pasteFiles(_:)), keyEquivalent: "v")
        [cutItem, copyItem, pasteItem].forEach { $0.target = self }
        editMenu.addItem(withTitle: "Выбрать всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let goItem = NSMenuItem()
        let goMenu = NSMenu(title: "Переход")
        let historyBack = goMenu.addItem(
            withTitle: "Назад",
            action: #selector(goBack(_:)),
            keyEquivalent: "\u{F702}"
        )
        historyBack.keyEquivalentModifierMask = [.command]
        let historyForward = goMenu.addItem(
            withTitle: "Вперёд",
            action: #selector(goForward(_:)),
            keyEquivalent: "\u{F703}"
        )
        historyForward.keyEquivalentModifierMask = [.command]
        goMenu.addItem(withTitle: "В родительскую папку", action: #selector(goUp(_:)), keyEquivalent: "\u{2191}")
        goMenu.addItem(NSMenuItem.separator())
        for number in 1...9 {
            let title = number == 9 ? "Последняя вкладка" : "Вкладка \(number)"
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
        let viewMenu = NSMenu(title: "Вид")
        let quickLook = NSMenuItem(title: "Быстрый просмотр", action: #selector(quickLook(_:)), keyEquivalent: " ")
        quickLook.keyEquivalentModifierMask = []
        viewMenu.addItem(quickLook)
        let quickLookFullScreen = viewMenu.addItem(
            withTitle: "Полный экран Quick Look",
            action: #selector(toggleQuickLookFullScreen(_:)),
            keyEquivalent: "f"
        )
        quickLookFullScreen.keyEquivalentModifierMask = [.command, .control]
        let previewPanelItem = viewMenu.addItem(
            withTitle: "Панель предпросмотра",
            action: #selector(togglePreview(_:)),
            keyEquivalent: "p"
        )
        previewPanelItem.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(withTitle: "Новая панель", action: #selector(splitPane(_:)), keyEquivalent: "d")
        viewMenu.addItem(withTitle: "Обновить", action: #selector(reload(_:)), keyEquivalent: "r")
        viewMenu.addItem(withTitle: "Скрытые файлы", action: #selector(toggleHidden(_:)), keyEquivalent: ".")
        viewMenu.addItem(withTitle: "Фокус на путь", action: #selector(focusPath(_:)), keyEquivalent: "l")
        viewMenu.addItem(withTitle: "Фокус на поиск", action: #selector(focusSearch(_:)), keyEquivalent: "f")
        viewMenu.addItem(withTitle: "Переключить список / плитку", action: #selector(toggleViewMode(_:)), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Буфер обмена", action: #selector(showClipboard(_:)), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Палитра команд...", action: #selector(showCommandPalette(_:)), keyEquivalent: "k")
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Окно")
        // Глобальный ⌘E перехватывается Carbon-хоткеем раньше меню; пункт меню
        // остаётся для мыши и как подсказка о сочетании клавиш.
        windowMenu.addItem(withTitle: "Показать или скрыть Qyvro", action: #selector(summonExplorerWindow(_:)), keyEquivalent: "e")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        for item in fileMenu.items + goMenu.items + viewMenu.items + windowMenu.items {
            if item.action != nil {
                item.target = self
            }
        }

        NSApp.mainMenu = mainMenu
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

    @objc func showCommandPalette(_ sender: Any?) {
        if commandPaletteController == nil {
            commandPaletteController = CommandPaletteController()
        }
        let commands: [FPCommandEntry] = [
            FPCommandEntry(title: "Новая вкладка", subtitle: "Открыть текущую папку в соседней вкладке", symbol: "plus.square") { [weak self] in self?.activeWorkspace?.newTab(nil) },
            FPCommandEntry(title: "Новая панель", subtitle: "Разделить текущее окно", symbol: "rectangle.split.2x1") { [weak self] in self?.activeWorkspace?.splitPane(nil) },
            FPCommandEntry(title: "Новая папка", subtitle: "Создать папку в текущем каталоге", symbol: "folder.badge.plus") { [weak self] in self?.activeWorkspace?.newFolder(nil) },
            FPCommandEntry(title: "Новый текстовый файл", subtitle: "Создать пустой .txt и сразу переименовать", symbol: "doc.badge.plus") { [weak self] in self?.activeWorkspace?.newTextFile(nil) },
            FPCommandEntry(title: "Быстрый просмотр", subtitle: "Открыть выбранные объекты через Quick Look", symbol: "eye") { [weak self] in self?.activeWorkspace?.quickLook(nil) },
            FPCommandEntry(title: "Панель предпросмотра", subtitle: "Показать сведения справа — ⌥⌘P", symbol: "sidebar.right") { [weak self] in self?.activeWorkspace?.togglePreview(nil) },
            FPCommandEntry(title: "Инспектор", subtitle: "Показать сведения о выбранных объектах", symbol: "info.circle") { [weak self] in self?.activeWorkspace?.inspectSelection(nil) },
            FPCommandEntry(title: "Пакетное переименование", subtitle: "Переименовать несколько выбранных объектов", symbol: "textformat") { [weak self] in self?.activeWorkspace?.batchRenameSelection(nil) },
            FPCommandEntry(title: "Копировать файлы", subtitle: "Скопировать выбранные объекты — ⌘C", symbol: "doc.on.doc") { [weak self] in self?.activeWorkspace?.copyFiles(nil) },
            FPCommandEntry(title: "Вырезать файлы", subtitle: "Подготовить выбранные объекты к перемещению — ⌘X", symbol: "scissors") { [weak self] in self?.activeWorkspace?.cutFiles(nil) },
            FPCommandEntry(title: "Вставить файлы", subtitle: "Вставить в текущую папку — ⌘V", symbol: "doc.on.clipboard") { [weak self] in self?.activeWorkspace?.pasteFiles(nil) },
            FPCommandEntry(title: "Дублировать", subtitle: "Создать копии выбранных объектов", symbol: "plus.square.on.square") { [weak self] in self?.activeWorkspace?.duplicateSelection(nil) },
            FPCommandEntry(title: "Открыть в Terminal", subtitle: "Открыть текущую или выбранную папку в Terminal", symbol: "terminal") { [weak self] in self?.activeWorkspace?.openInTerminal(nil) },
            FPCommandEntry(title: "Список / плитка", subtitle: "Переключить представление текущей папки", symbol: "square.grid.2x2") { [weak self] in self?.activeWorkspace?.toggleViewMode(nil) },
            FPCommandEntry(title: "Фокус на путь", subtitle: "Перейти к строке текущего пути", symbol: "location") { [weak self] in self?.activeWorkspace?.focusPath(nil) },
            FPCommandEntry(title: "Фокус на поиск", subtitle: "Искать в текущей папке", symbol: "magnifyingglass") { [weak self] in self?.activeWorkspace?.focusSearch(nil) },
            FPCommandEntry(title: "Буфер обмена", subtitle: "Показать историю скопированного — \(QyvroClipboardShortcut.displayName)", symbol: "clipboard") { [weak self] in self?.showClipboard(nil) },
            FPCommandEntry(title: "Настройки", subtitle: "Темы, прозрачность, сетка и жесты", symbol: "slider.horizontal.3") { [weak self] in self?.showSettings(nil) }
        ]
        commandPaletteController?.show(commands: commands)
    }

    @objc private func showLegacySettings(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Настройки \(appDisplayName)"
        alert.informativeText = "Цвета применяются сразу после сохранения."
        alert.addButton(withTitle: "Сохранить")
        alert.addButton(withTitle: "Сбросить")
        alert.addButton(withTitle: "Отмена")

        let windowColor = NSColorWell(frame: NSRect(x: 0, y: 0, width: 70, height: 28))
        windowColor.color = FPStyle.window.withAlphaComponent(1)
        let paneColor = NSColorWell(frame: NSRect(x: 0, y: 0, width: 70, height: 28))
        paneColor.color = FPStyle.pane.withAlphaComponent(1)
        let sidebarColor = NSColorWell(frame: NSRect(x: 0, y: 0, width: 70, height: 28))
        sidebarColor.color = FPStyle.sidebar.withAlphaComponent(1)
        let barColor = NSColorWell(frame: NSRect(x: 0, y: 0, width: 70, height: 28))
        barColor.color = FPStyle.bar.withAlphaComponent(1)
        let folderColor = NSColorWell(frame: NSRect(x: 0, y: 0, width: 70, height: 28))
        folderColor.color = FPStyle.defaultFolder
        let accentColor = NSColorWell(frame: NSRect(x: 0, y: 0, width: 70, height: 28))
        accentColor.color = FPStyle.accent
        let orangeColor = NSColorWell(frame: NSRect(x: 0, y: 0, width: 70, height: 28))
        orangeColor.color = FPStyle.orange
        let gradientStartColor = NSColorWell(frame: NSRect(x: 0, y: 0, width: 70, height: 28))
        gradientStartColor.color = FPStyle.gradientStart
        let gradientEndColor = NSColorWell(frame: NSRect(x: 0, y: 0, width: 70, height: 28))
        gradientEndColor.color = FPStyle.gradientEnd

        let opacitySlider = NSSlider(value: UserDefaults.standard.object(forKey: "ThemePaneOpacity") == nil ? 0.74 : UserDefaults.standard.double(forKey: "ThemePaneOpacity"), minValue: 0.10, maxValue: 0.96, target: nil, action: nil)
        opacitySlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let sidebarOpacitySlider = NSSlider(value: UserDefaults.standard.object(forKey: "ThemeSidebarOpacity") == nil ? 0.30 : UserDefaults.standard.double(forKey: "ThemeSidebarOpacity"), minValue: 0.12, maxValue: 0.65, target: nil, action: nil)
        sidebarOpacitySlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let spacingSlider = NSSlider(value: Double(FPStyle.gridSpacing), minValue: 2, maxValue: 36, target: nil, action: nil)
        spacingSlider.numberOfTickMarks = 18
        spacingSlider.allowsTickMarkValuesOnly = false
        spacingSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let previewOpacitySlider = NSSlider(
            value: Double(FPStyle.previewOpacity),
            minValue: 0.35,
            maxValue: 1.0,
            target: nil,
            action: nil
        )
        previewOpacitySlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        previewOpacitySlider.toolTip = "Прозрачность окна просмотра"
        let wheelZoomSlider = NSSlider(
            value: FPPreferences.wheelZoomSensitivity,
            minValue: 10, maxValue: 150, target: nil, action: nil
        )
        wheelZoomSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        wheelZoomSlider.toolTip = "Насколько сильно Ctrl с колесом мыши меняет размер значков"
        let swipeSensitivitySlider = NSSlider(value: FPPreferences.swipeSensitivity, minValue: 10, maxValue: 100, target: nil, action: nil)
        swipeSensitivitySlider.numberOfTickMarks = 10
        swipeSensitivitySlider.widthAnchor.constraint(equalToConstant: 180).isActive = true

        let gradientToggle = NSButton(checkboxWithTitle: "Мягкий градиент", target: nil, action: nil)
        gradientToggle.state = FPStyle.gradientEnabled ? .on : .off
        let groupToggle = NSButton(checkboxWithTitle: "Группы по датам", target: nil, action: nil)
        groupToggle.state = FPPreferences.groupLargeFoldersByDate ? .on : .off
        let swipeModeToggle = NSButton(checkboxWithTitle: "Вправо = назад", target: nil, action: nil)
        swipeModeToggle.state = FPPreferences.invertedSwipeNavigation ? .on : .off

        let presetPopup = NSPopUpButton()
        presetPopup.addItem(withTitle: "Текущая настройка")
        for preset in FPThemePreset.all {
            presetPopup.addItem(withTitle: preset.title)
        }
        presetPopup.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let presetController = FPThemePresetController(
            windowColor: windowColor,
            paneColor: paneColor,
            sidebarColor: sidebarColor,
            barColor: barColor,
            folderColor: folderColor,
            accentColor: accentColor,
            orangeColor: orangeColor,
            gradientStartColor: gradientStartColor,
            gradientEndColor: gradientEndColor,
            paneOpacity: opacitySlider,
            sidebarOpacity: sidebarOpacitySlider
        )
        presetPopup.target = presetController
        presetPopup.action = #selector(FPThemePresetController.presetChanged(_:))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 8
        stack.addArrangedSubview(settingsRow(title: "Готовая тема", control: presetPopup))
        stack.addArrangedSubview(settingsRow(title: "Фон окна", control: windowColor))
        stack.addArrangedSubview(settingsRow(title: "Фон проводника", control: paneColor))
        stack.addArrangedSubview(settingsRow(title: "Панель слева", control: sidebarColor))
        stack.addArrangedSubview(settingsRow(title: "Верхняя панель", control: barColor))
        stack.addArrangedSubview(settingsRow(title: "Папки по умолчанию", control: folderColor))
        stack.addArrangedSubview(settingsRow(title: "Лазурный акцент", control: accentColor))
        stack.addArrangedSubview(settingsRow(title: "Оранжевый акцент", control: orangeColor))
        stack.addArrangedSubview(settingsRow(title: "Градиент: начало", control: gradientStartColor))
        stack.addArrangedSubview(settingsRow(title: "Градиент: конец", control: gradientEndColor))
        stack.addArrangedSubview(settingsRow(title: "Прозрачность фона", control: opacitySlider))
        stack.addArrangedSubview(settingsRow(title: "Прозрачность слева", control: sidebarOpacitySlider))
        stack.addArrangedSubview(settingsRow(title: "Прозрачность просмотра", control: previewOpacitySlider))
        stack.addArrangedSubview(settingsRow(title: "Расстояние в сетке", control: spacingSlider))
        stack.addArrangedSubview(settingsRow(title: "Чувствительность жеста", control: swipeSensitivitySlider))
        stack.addArrangedSubview(settingsRow(title: "Шаг колеса мыши", control: wheelZoomSlider))
        stack.addArrangedSubview(settingsRow(title: "Навигация", control: swipeModeToggle))
        stack.addArrangedSubview(settingsRow(title: "Большие папки", control: groupToggle))
        stack.addArrangedSubview(settingsRow(title: "Оформление", control: gradientToggle))
        stack.frame = NSRect(x: 0, y: 0, width: 410, height: 605)
        alert.accessoryView = stack

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            FPStyle.saveColor(windowColor.color, key: "ThemeWindowColor")
            FPStyle.saveColor(paneColor.color, key: "ThemePaneColor")
            FPStyle.saveColor(sidebarColor.color, key: "ThemeSidebarColor")
            FPStyle.saveColor(barColor.color, key: "ThemeBarColor")
            FPStyle.saveColor(folderColor.color, key: "ThemeFolderColor")
            FPStyle.saveColor(accentColor.color, key: "ThemeAccentColor")
            FPStyle.saveColor(orangeColor.color, key: "ThemeOrangeColor")
            FPStyle.saveColor(gradientStartColor.color, key: "ThemeGradientStart")
            FPStyle.saveColor(gradientEndColor.color, key: "ThemeGradientEnd")
            UserDefaults.standard.set(opacitySlider.doubleValue, forKey: "ThemePaneOpacity")
            UserDefaults.standard.set(sidebarOpacitySlider.doubleValue, forKey: "ThemeSidebarOpacity")
            UserDefaults.standard.set(previewOpacitySlider.doubleValue, forKey: "PreviewWindowOpacity")
            UserDefaults.standard.set(spacingSlider.doubleValue, forKey: "GridSpacing")
            UserDefaults.standard.set(swipeSensitivitySlider.doubleValue, forKey: "SwipeSensitivity")
            UserDefaults.standard.set(wheelZoomSlider.doubleValue, forKey: "WheelZoomSensitivity")
            UserDefaults.standard.set(swipeModeToggle.state == .on, forKey: "SwipeNavigationInverted")
            UserDefaults.standard.set(groupToggle.state == .on, forKey: "GroupLargeFoldersByDate")
            UserDefaults.standard.set(gradientToggle.state == .on, forKey: "ThemeGradientEnabled")
            NotificationCenter.default.post(name: .fpThemeDidChange, object: nil)
        case .alertSecondButtonReturn:
            for key in [
                "ThemeWindowColor", "ThemePaneColor", "ThemeSidebarColor", "ThemeBarColor",
                "ThemeFolderColor", "ThemeAccentColor", "ThemeOrangeColor",
                "ThemeGradientStart", "ThemeGradientEnd", "ThemeGradientEnabled",
                "ThemePaneOpacity", "ThemeSidebarOpacity", "PreviewWindowOpacity", "GridSpacing",
                "SwipeSensitivity", "WheelZoomSensitivity",
                "SwipeNavigationInverted", "GroupLargeFoldersByDate"
            ] {
                UserDefaults.standard.removeObject(forKey: key)
            }
            NotificationCenter.default.post(name: .fpThemeDidChange, object: nil)
        default:
            break
        }
    }

    private func settingsRow(title: String, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = FPStyle.text
        label.widthAnchor.constraint(equalToConstant: 155).isActive = true

        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undoFileOperation(_:)) {
            if let title = QyvroFileOperationHistory.shared.undoTitle {
                menuItem.title = "Отменить \(title)"
                return QyvroFileOperationHistory.shared.canUndo
            }
            menuItem.title = "Отменить"
            return NSApp.keyWindow?.firstResponder?.undoManager?.canUndo ?? false
        }
        if menuItem.action == #selector(redoFileOperation(_:)) {
            if let title = QyvroFileOperationHistory.shared.redoTitle {
                menuItem.title = "Повторить \(title)"
                return QyvroFileOperationHistory.shared.canRedo
            }
            menuItem.title = "Повторить"
            return NSApp.keyWindow?.firstResponder?.undoManager?.canRedo ?? false
        }
        if menuItem.action == #selector(toggleHidden(_:)) {
            menuItem.state = UserDefaults.standard.bool(forKey: "ShowHiddenFiles") ? .on : .off
        }
        if menuItem.action == #selector(togglePreview(_:)) {
            menuItem.state = activeWorkspace?.isPreviewPanelVisible == true ? .on : .off
        }
        if menuItem.action == #selector(toggleQuickLookFullScreen(_:)) {
            let panel = QLPreviewPanel.sharedPreviewPanelExists()
                ? QLPreviewPanel.shared()
                : nil
            let isFullScreen = panel?.isInFullScreenMode == true
                || quickLookPresentationState == .fullScreen
            menuItem.title = isFullScreen
                ? "Выйти из полного экрана Quick Look"
                : "Полный экран Quick Look"
            menuItem.state = isFullScreen ? .on : .off
            return panel?.isVisible == true && quickLookRequest != nil
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
