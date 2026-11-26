import Cocoa
private struct FPStoredColor: Codable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init(_ color: NSColor) {
        let converted = color.usingColorSpace(.deviceRGB) ?? color
        red = Double(converted.redComponent)
        green = Double(converted.greenComponent)
        blue = Double(converted.blueComponent)
        alpha = Double(converted.alphaComponent)
    }

    var color: NSColor {
        NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
    }
}

struct FPCommandEntry {
    let title: String
    let subtitle: String
    let symbol: String
    let action: () -> Void
}

final class CommandPaletteController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private var commands: [FPCommandEntry] = []
    private var filtered: [FPCommandEntry] = []
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?

    init() {
        let panel = EscapeClosingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .utilityWindow, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Палитра команд"
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init(window: panel)
        panel.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        removeOutsideClickMonitors()
    }

    func show(commands: [FPCommandEntry]) {
        self.commands = commands
        filtered = commands
        searchField.stringValue = ""
        tableView.reloadData()
        if !filtered.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(searchField)
        installOutsideClickMonitors()
    }

    private func installOutsideClickMonitors() {
        removeOutsideClickMonitors()
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window !== self.window { self.close() }
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.close() }
        }
    }

    private func removeOutsideClickMonitors() {
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        localClickMonitor = nil
        globalClickMonitor = nil
    }

    func windowWillClose(_ notification: Notification) {
        removeOutsideClickMonitors()
    }

    private func buildUI() {
        guard let window else { return }
        let effect = FPAuxiliaryBackdrop(frame: .zero)
        window.contentView = effect

        searchField.placeholderString = "Найти действие..."
        searchField.font = .systemFont(ofSize: 15, weight: .medium)
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = true
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(executeSelected(_:))
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        column.width = 500
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = 48
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(executeSelected(_:))
        tableView.allowsEmptySelection = false

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(searchField)
        effect.addSubview(scroll)
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 18),
            searchField.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -18),
            searchField.topAnchor.constraint(equalTo: effect.topAnchor, constant: 42),
            searchField.heightAnchor.constraint(equalToConstant: 38),
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -14)
        ])
    }

    func controlTextDidChange(_ obj: Notification) {
        updateFilter()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            moveSelection(by: 1)
            return true
        }
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            moveSelection(by: -1)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            executeSelected(searchField)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            close()
            return true
        }
        return false
    }

    private func moveSelection(by delta: Int) {
        guard !filtered.isEmpty else { return }
        let current = tableView.selectedRow >= 0 ? tableView.selectedRow : 0
        let next = (current + delta + filtered.count) % filtered.count
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    private func updateFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filtered = query.isEmpty ? commands : commands.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.subtitle.localizedCaseInsensitiveContains(query)
        }
        tableView.reloadData()
        if !filtered.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filtered.indices.contains(row) else { return nil }
        let command = filtered[row]
        let cell = NSTableCellView()
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: command.symbol, accessibilityDescription: command.title)
        icon.contentTintColor = FPStyle.isObsidianAurora ? FPStyle.accent : FPStyle.orange
        icon.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: command.title)
        title.font = FPStyle.headingFont(ofSize: 13, weight: .semibold)
        title.textColor = FPStyle.text
        let subtitle = NSTextField(labelWithString: command.subtitle)
        subtitle.font = FPStyle.bodyFont(ofSize: 11, weight: .regular)
        subtitle.textColor = FPStyle.dimText
        let labels = NSStackView(views: [title, subtitle])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(icon)
        cell.addSubview(labels)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            labels.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            labels.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    @objc private func executeSelected(_ sender: Any?) {
        if sender as AnyObject? === searchField {
            updateFilter()
        }
        let row = tableView.selectedRow >= 0 ? tableView.selectedRow : 0
        guard filtered.indices.contains(row) else { NSSound.beep(); return }
        let action = filtered[row].action
        close()
        DispatchQueue.main.async { action() }
    }
}

private struct FPUserTheme: Codable {
    var name: String
    var window: FPStoredColor
    var pane: FPStoredColor
    var sidebar: FPStoredColor
    var bar: FPStoredColor
    var folder: FPStoredColor
    var accent: FPStoredColor
    var orange: FPStoredColor
    var gradientStart: FPStoredColor
    var gradientEnd: FPStoredColor
    var paneOpacity: Double
    var sidebarOpacity: Double
    var gridSpacing: Double
    var swipeSensitivity: Double
    var invertedSwipe: Bool
    var grouped: Bool
    var gradientEnabled: Bool
    var text: FPStoredColor? = nil
    var dimText: FPStoredColor? = nil
    var sidebarAnimationDuration: Double? = nil
    var settingsWindow: FPStoredColor? = nil
    var tagWindow: FPStoredColor? = nil
    var settingsWindowOpacity: Double? = nil
    var tagWindowOpacity: Double? = nil
    var swipeWaveSmoothness: Double? = nil
    var swipeWaveStrength: Double? = nil
    var swipeWaveDuration: Double? = nil
    var swipeWaveWidth: Double? = nil
    var swipeWaveBlur: Double? = nil
    var swipeWaveExposure: Double? = nil
    var swipeWaveGlow: Double? = nil
    var swipeWaveTint: Double? = nil
    var swipeWaveTilt: Double? = nil
    var styleVariant: String? = nil
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private weak var backgroundTintView: FPBackgroundTintView?
    private let layoutPopup = NSPopUpButton()
    private let folderStylePopup = NSPopUpButton()
    private let languagePopup = NSPopUpButton()
    private let presetPopup = NSPopUpButton()
    private let windowColor = ThemeColorWell()
    private let paneColor = ThemeColorWell()
    private let sidebarColor = ThemeColorWell()
    private let barColor = ThemeColorWell()
    private let folderColor = ThemeColorWell()
    private let accentColor = ThemeColorWell()
    private let orangeColor = ThemeColorWell()
    private let textColor = ThemeColorWell()
    private let dimTextColor = ThemeColorWell()
    private let gradientStartColor = ThemeColorWell()
    private let gradientEndColor = ThemeColorWell()
    private let settingsWindowColor = ThemeColorWell()
    private let tagWindowColor = ThemeColorWell()
    private let paneOpacity = NSSlider()
    private let sidebarOpacity = NSSlider()
    private let settingsWindowOpacity = NSSlider()
    private let tagWindowOpacity = NSSlider()
    private let gridSpacing = NSSlider()
    private let swipeSensitivity = NSSlider()
    private let sidebarAnimationDuration = NSSlider()
    private let swipeWaveSmoothness = NSSlider()
    private let swipeWaveStrength = NSSlider()
    private let swipeWaveDuration = NSSlider()
    private let swipeWaveWidth = NSSlider()
    private let swipeWaveBlur = NSSlider()
    private let swipeWaveExposure = NSSlider()
    private let swipeWaveGlow = NSSlider()
    private let swipeWaveTint = NSSlider()
    private let swipeWaveTilt = NSSlider()
    private let invertedSwipe = NSButton(checkboxWithTitle: L("Вправо = назад", "Swipe right = back"), target: nil, action: nil)
    private let grouped = NSButton(checkboxWithTitle: L("Группы по датам", "Group by date"), target: nil, action: nil)
    private let gradientEnabled = NSButton(checkboxWithTitle: L("Мягкий градиент", "Deep-glow gradient"), target: nil, action: nil)
    private let summonHotKey = NSButton(checkboxWithTitle: L("⌘E вызывает Qyvro", "⌘E summons Qyvro"), target: nil, action: nil)
    private var valueLabels: [ObjectIdentifier: NSTextField] = [:]
    private var suppressChanges = false
    private var userThemes: [FPUserTheme] = []
    private var transitionGeneration = 0

    init() {
        let window = EscapeClosingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Настройки Qyvro"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.minSize = NSSize(width: 720, height: 440)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init(window: window)
        window.delegate = self
        loadUserThemes()
        buildUI()
        loadCurrentValues()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        presentAnimated(sender)
    }

    func toggle(_ sender: Any?) {
        guard let window else { return }
        if window.isVisible {
            hideAnimated()
        } else {
            presentAnimated(sender)
        }
    }

    private func presentAnimated(_ sender: Any?) {
        guard let window else { return }
        transitionGeneration += 1
        let generation = transitionGeneration
        loadUserThemes()
        rebuildPresetMenu()
        loadCurrentValues()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        FPWindowPresentationAnimator.show(window) {
            window.makeKeyAndOrderFront(sender)
        } completion: { [weak self, weak window] in
            guard let self, let window, self.transitionGeneration == generation else { return }
            window.alphaValue = 1
        }
    }

    private func hideAnimated() {
        guard let window, window.isVisible else { return }
        transitionGeneration += 1
        let generation = transitionGeneration
        FPWindowPresentationAnimator.hide(window) { [weak self, weak window] in
            guard let self, let window, self.transitionGeneration == generation else { return }
            window.orderOut(nil)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hideAnimated()
        return false
    }

    private func buildUI() {
        guard let window else { return }
        let effect = NSVisualEffectView()
        // Тот же материал, что у остальных вспомогательных окон.
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = effect

        let backgroundTint = FPBackgroundTintView(color: FPStyle.settingsWindow)
        backgroundTintView = backgroundTint
        effect.addSubview(backgroundTint)
        // Едва заметный тон градиента темы поверх заливки: без него окно
        // настроек оставалось плоским и выпадало из общего оформления.
        let themeTint = FPBackgroundGradientView()
        themeTint.translatesAutoresizingMaskIntoConstraints = false
        themeTint.setColors(
            FPStyle.gradientEnabled
                ? [
                    FPStyle.gradientStart.withAlphaComponent(0.16),
                    FPStyle.gradientEnd.withAlphaComponent(0.16)
                ]
                : [
                    FPStyle.window.withAlphaComponent(0.16),
                    FPStyle.window.withAlphaComponent(0.16)
                ]
        )
        effect.addSubview(themeTint)
        NSLayoutConstraint.activate([
            backgroundTint.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            backgroundTint.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            backgroundTint.topAnchor.constraint(equalTo: effect.topAnchor),
            backgroundTint.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            themeTint.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            themeTint.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            themeTint.topAnchor.constraint(equalTo: effect.topAnchor),
            themeTint.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
        ])

        let title = NSTextField(labelWithString: L("НАСТРОЙКИ", "SETTINGS"))
        // Заголовок как рубрики проводника, а не системным полужирным.
        title.font = FPStyle.headingFont(ofSize: 17, weight: .semibold)
        title.textColor = FPStyle.text
        let subtitle = NSTextField(labelWithString: L("Изменения сразу видны во всех окнах проводника", "Changes apply live across all explorer windows"))
        subtitle.font = FPStyle.bodyFont(ofSize: 11, weight: .regular)
        subtitle.textColor = FPStyle.dimText
        let heading = NSStackView(views: [title, subtitle])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 3

        layoutPopup.target = self
        layoutPopup.action = #selector(layoutChanged(_:))
        layoutPopup.removeAllItems()
        for layout in QyvroWorkspaceLayout.allCases {
            layoutPopup.addItem(withTitle: layout.title)
        }
        if let idx = QyvroWorkspaceLayout.allCases.firstIndex(of: QyvroWorkspaceLayout.current) {
            layoutPopup.selectItem(at: idx)
        }
        layoutPopup.widthAnchor.constraint(equalToConstant: 168).isActive = true

        presetPopup.target = self
        presetPopup.action = #selector(presetChanged(_:))
        presetPopup.widthAnchor.constraint(equalToConstant: 210).isActive = true
        rebuildPresetMenu()
        let savePreset = actionButton(L("Сохранить", "Save"), symbol: "plus", action: #selector(savePreset(_:)))
        let deletePreset = actionButton("", symbol: "trash", action: #selector(deletePreset(_:)))
        let presetControls = NSStackView(views: [layoutPopup, presetPopup, savePreset, deletePreset])
        presetControls.orientation = .horizontal
        presetControls.spacing = 6
        presetControls.alignment = .centerY

        let header = NSStackView(views: [heading, NSView(), presetControls])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 16
        header.translatesAutoresizingMaskIntoConstraints = false

        configureColorWells()
        configureSlider(paneOpacity, min: 0.10, max: 1, value: Double(FPStyle.pane.alphaComponent))
        configureSlider(sidebarOpacity, min: 0.08, max: 0.85, value: Double(FPStyle.sidebar.alphaComponent))
        configureSlider(settingsWindowOpacity, min: 0.45, max: 1, value: Double(FPStyle.settingsWindow.alphaComponent))
        configureSlider(tagWindowOpacity, min: 0.45, max: 1, value: Double(FPStyle.tagWindow.alphaComponent))
        configureSlider(gridSpacing, min: 2, max: 36, value: Double(FPStyle.gridSpacing))
        configureSlider(swipeSensitivity, min: 10, max: 100, value: FPPreferences.swipeSensitivity)
        swipeSensitivity.numberOfTickMarks = 10
        swipeSensitivity.allowsTickMarkValuesOnly = false
        swipeSensitivity.toolTip = "Насколько короткого горизонтального жеста достаточно для перехода назад или вперёд"
        configureSlider(sidebarAnimationDuration, min: 0.5, max: 2.0, value: FPPreferences.sidebarAnimationDuration)
        configureSlider(swipeWaveSmoothness, min: 0.25, max: 1.0, value: FPPreferences.swipeWaveSmoothness)
        configureSlider(swipeWaveStrength, min: 0.2, max: 1.0, value: FPPreferences.swipeWaveStrength)
        configureSlider(swipeWaveDuration, min: 0.70, max: 1.2, value: FPPreferences.swipeWaveDuration)
        configureSlider(swipeWaveWidth, min: 0.30, max: 1.20, value: FPPreferences.swipeWaveWidth)
        configureSlider(swipeWaveBlur, min: 0, max: 1, value: FPPreferences.swipeWaveBlur)
        configureSlider(swipeWaveExposure, min: 0, max: 1.40, value: FPPreferences.swipeWaveExposure)
        configureSlider(swipeWaveGlow, min: 0, max: 1.20, value: FPPreferences.swipeWaveGlow)
        configureSlider(swipeWaveTint, min: 0, max: 1, value: FPPreferences.swipeWaveTint)
        configureSlider(swipeWaveTilt, min: -35, max: 35, value: FPPreferences.swipeWaveTilt)
        [invertedSwipe, grouped, gradientEnabled, summonHotKey].forEach {
            $0.target = self
            $0.action = #selector(controlChanged(_:))
            $0.contentTintColor = FPStyle.orange
            $0.font = .systemFont(ofSize: 13, weight: .medium)
        }
        summonHotKey.toolTip = "Глобальное сочетание: окно Qyvro появляется на текущем рабочем столе из любого приложения"

        folderStylePopup.target = self
        folderStylePopup.action = #selector(folderStyleChanged(_:))
        folderStylePopup.removeAllItems()
        for style in FPFolderIconStyle.allCases {
            folderStylePopup.addItem(withTitle: style.title)
        }
        if let idx = FPFolderIconStyle.allCases.firstIndex(of: FPFolderIconStyle.current) {
            folderStylePopup.selectItem(at: idx)
        }
        folderStylePopup.widthAnchor.constraint(equalToConstant: 156).isActive = true

        languagePopup.target = self
        languagePopup.action = #selector(languageChanged(_:))
        languagePopup.removeAllItems()
        for lang in FPAppLanguage.allCases {
            languagePopup.addItem(withTitle: lang.title)
        }
        if let idx = FPAppLanguage.allCases.firstIndex(of: FPLocalization.selectedLanguage) {
            languagePopup.selectItem(at: idx)
        }
        languagePopup.widthAnchor.constraint(equalToConstant: 156).isActive = true

        let appearance = settingsSection(title: L("Оформление", "Appearance"), rows: [
            popupRow(L("Язык / Language", "Language"), languagePopup),
            popupRow(L("Стиль папок", "Folder Style"), folderStylePopup),
            colorRow(L("Фон окна", "Window Base"), windowColor),
            colorRow(L("Фон проводника", "Pane Surface"), paneColor),
            colorRow(L("Панель слева", "Sidebar"), sidebarColor),
            colorRow(L("Верхняя панель", "Toolbar"), barColor),
            colorRow(L("Папки", "Folder Color"), folderColor),
            colorRow(L("Акцент 1", "Primary Accent"), accentColor),
            colorRow(L("Акцент 2", "Warm Accent"), orangeColor),
            colorRow(L("Основной текст", "Primary Text"), textColor),
            colorRow(L("Вторичный текст", "Secondary Text"), dimTextColor),
            colorRow(L("Окно настроек", "Settings Window"), settingsWindowColor),
            colorRow(L("Окно тегов", "Tags Window"), tagWindowColor),
            colorRow(L("Градиент: начало", "Gradient Start"), gradientStartColor),
            colorRow(L("Градиент: конец", "Gradient End"), gradientEndColor)
        ])
        let behavior = settingsSection(title: L("Пространство и управление", "Workspace & Gestures"), rows: [
            sliderRow(L("Прозрачность фона", "Pane Opacity"), paneOpacity, format: { "\(Int($0 * 100))%" }),
            sliderRow(L("Прозрачность слева", "Sidebar Opacity"), sidebarOpacity, format: { "\(Int($0 * 100))%" }),
            sliderRow(L("Окно настроек", "Settings Opacity"), settingsWindowOpacity, format: { "\(Int($0 * 100))%" }),
            sliderRow(L("Окно тегов", "Tags Opacity"), tagWindowOpacity, format: { "\(Int($0 * 100))%" }),
            sliderRow(L("Расстояние в сетке", "Grid Spacing"), gridSpacing, format: { "\(Int($0)) px" }),
            sliderRow(L("Чувствительность жеста", "Swipe Sensitivity"), swipeSensitivity, format: { "\(Int($0))%" }),
            sliderRow(L("Анимация панели", "Panel Animation"), sidebarAnimationDuration, format: { String(format: "%.1f s", $0) }),
            sliderRow(L("Плавность волны", "Wave Smoothness"), swipeWaveSmoothness, format: { "\(Int($0 * 100))%" }),
            sliderRow(L("Амплитуда волны", "Wave Strength"), swipeWaveStrength, format: { "\(Int($0 * 100))%" }),
            sliderRow(L("Ширина волны", "Wave Width"), swipeWaveWidth, format: { "\(Int($0 * 100))%" }),
            sliderRow(L("Размытие волны", "Wave Blur"), swipeWaveBlur, format: { "\(Int($0 * 100))%" }),
            sliderRow(L("Экспозиция", "Exposure"), swipeWaveExposure, format: { "\(Int($0 * 100))%" }),
            sliderRow("Deep glow", swipeWaveGlow, format: { "\(Int($0 * 100))%" }),
            sliderRow(L("Цветовой оттенок", "Color Tint"), swipeWaveTint, format: { "\(Int($0 * 100))%" }),
            sliderRow(L("Наклон волны", "Wave Tilt"), swipeWaveTilt, format: { "\(Int($0))°" }),
            sliderRow(L("Длительность волны", "Wave Duration"), swipeWaveDuration, format: { String(format: "%.2f s", $0) }),
            toggleRow(L("Навигация", "Navigation"), invertedSwipe),
            toggleRow(L("Большие папки", "Large Folders"), grouped),
            toggleRow(L("Градиент", "Gradient"), gradientEnabled),
            toggleRow(L("Горячая клавиша", "Global Hotkey"), summonHotKey)
        ])

        let divider = FPLayerView(color: FPStyle.stroke.withAlphaComponent(0.55))
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        let contentStack = NSStackView(views: [appearance, divider, behavior])
        contentStack.orientation = .horizontal
        contentStack.alignment = .top
        contentStack.spacing = 14
        contentStack.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 8, right: 6)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let document = FPFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: document.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            contentStack.widthAnchor.constraint(equalToConstant: 632)
        ])

        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let reset = actionButton(L("Сбросить настройки", "Reset Defaults"), symbol: "arrow.counterclockwise", action: #selector(resetSettings(_:)))
        let clearCache = actionButton(L("Очистить кэш", "Clear Cache"), symbol: "trash.slash", action: #selector(clearThumbnailCache(_:)))
        let checkUpdates = actionButton(
            L("Обновления (v\(QyvroUpdateChecker.shared.currentVersion))", "Updates (v\(QyvroUpdateChecker.shared.currentVersion))"),
            symbol: "arrow.triangle.2.circlepath",
            action: #selector(checkUpdatesPressed(_:))
        )
        let footer = NSStackView(views: [reset, clearCache, NSView(), checkUpdates])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(header)
        effect.addSubview(scroll)
        effect.addSubview(footer)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -18),
            header.topAnchor.constraint(equalTo: effect.topAnchor, constant: 34),
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 18),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 18),
            footer.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -18),
            footer.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -12),
            footer.heightAnchor.constraint(equalToConstant: 30)
        ])
    }

    private func configureColorWells() {
        NSColorPanel.shared.showsAlpha = true
        for well in [windowColor, paneColor, sidebarColor, barColor, folderColor, accentColor, orangeColor, textColor, dimTextColor, settingsWindowColor, tagWindowColor, gradientStartColor, gradientEndColor] {
            well.target = self
            well.action = #selector(controlChanged(_:))
            well.suggestedColorsProvider = { themeSuggestedColors() }
            well.isBordered = true
            well.widthAnchor.constraint(equalToConstant: 44).isActive = true
            well.heightAnchor.constraint(equalToConstant: 21).isActive = true
        }
    }

    private func configureSlider(_ slider: NSSlider, min: Double, max: Double, value: Double) {
        slider.minValue = min
        slider.maxValue = max
        slider.doubleValue = value
        slider.isContinuous = true
        // Заполненная часть ползунка красится акцентом темы. Без этого она
        // берёт системный акцент macOS — оранжевый, независимо от того, какие
        // цвета выбраны в приложении.
        if #available(macOS 10.12.2, *) {
            slider.trackFillColor = FPStyle.accent
        }
        slider.target = self
        slider.action = #selector(controlChanged(_:))
        slider.widthAnchor.constraint(equalToConstant: 138).isActive = true
    }

    private func settingsSection(title: String, rows: [NSView]) -> NSView {
        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 15, weight: .semibold)
        titleField.textColor = FPStyle.text
        let separator = FPLayerView(color: FPStyle.stroke.withAlphaComponent(0.55))
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let stack = NSStackView(views: [titleField, separator] + rows)
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 4, right: 2)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func label(_ title: String) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.font = .systemFont(ofSize: 13, weight: .medium)
        field.textColor = FPStyle.text
        field.maximumNumberOfLines = 2
        field.lineBreakMode = .byWordWrapping
        field.cell?.wraps = true
        field.widthAnchor.constraint(equalToConstant: 148).isActive = true
        return field
    }

    private func colorRow(_ title: String, _ well: NSColorWell) -> NSView {
        let row = NSStackView(views: [label(title), NSView(), well])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.heightAnchor.constraint(equalToConstant: 25).isActive = true
        return row
    }

    private func popupRow(_ title: String, _ popup: NSPopUpButton) -> NSView {
        let row = NSStackView(views: [label(title), NSView(), popup])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.heightAnchor.constraint(equalToConstant: 27).isActive = true
        return row
    }

    private func sliderRow(_ title: String, _ slider: NSSlider, format: @escaping (Double) -> String) -> NSView {
        let value = NSTextField(labelWithString: format(slider.doubleValue))
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        value.textColor = FPStyle.orange
        value.alignment = .right
        value.widthAnchor.constraint(equalToConstant: 42).isActive = true
        valueLabels[ObjectIdentifier(slider)] = value
        slider.identifier = NSUserInterfaceItemIdentifier(title)
        let row = NSStackView(views: [label(title), NSView(), slider, value])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        row.heightAnchor.constraint(equalToConstant: title == "Чувствительность срабатывания" ? 36 : 27).isActive = true
        return row
    }

    private func toggleRow(_ title: String, _ button: NSButton) -> NSView {
        let row = NSStackView(views: [label(title), NSView(), button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.heightAnchor.constraint(equalToConstant: 27).isActive = true
        return row
    }

    private func actionButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .inline
        button.isBordered = false
        button.font = .systemFont(ofSize: 12.5, weight: .medium)
        button.contentTintColor = FPStyle.text
        if #available(macOS 11.0, *), let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            button.image = image
            button.imagePosition = .imageLeading
        }
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.layer?.backgroundColor = FPStyle.controlStrong.cgColor
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    private func loadCurrentValues() {
        suppressChanges = true
        windowColor.color = FPStyle.window.withAlphaComponent(1)
        paneColor.color = FPStyle.pane.withAlphaComponent(1)
        sidebarColor.color = FPStyle.sidebar.withAlphaComponent(1)
        barColor.color = FPStyle.bar.withAlphaComponent(1)
        folderColor.color = FPStyle.defaultFolder
        accentColor.color = FPStyle.accent
        orangeColor.color = FPStyle.orange
        textColor.color = FPStyle.text
        dimTextColor.color = FPStyle.dimText
        settingsWindowColor.color = FPStyle.settingsWindow.withAlphaComponent(1)
        tagWindowColor.color = FPStyle.tagWindow.withAlphaComponent(1)
        gradientStartColor.color = FPStyle.gradientStart
        gradientEndColor.color = FPStyle.gradientEnd
        paneOpacity.doubleValue = UserDefaults.standard.object(forKey: "ThemePaneOpacity") == nil ? 0.74 : UserDefaults.standard.double(forKey: "ThemePaneOpacity")
        sidebarOpacity.doubleValue = UserDefaults.standard.object(forKey: "ThemeSidebarOpacity") == nil ? 0.30 : UserDefaults.standard.double(forKey: "ThemeSidebarOpacity")
        settingsWindowOpacity.doubleValue = UserDefaults.standard.object(forKey: "ThemeSettingsWindowOpacity") == nil ? 0.88 : UserDefaults.standard.double(forKey: "ThemeSettingsWindowOpacity")
        tagWindowOpacity.doubleValue = UserDefaults.standard.object(forKey: "ThemeTagWindowOpacity") == nil ? 0.82 : UserDefaults.standard.double(forKey: "ThemeTagWindowOpacity")
        gridSpacing.doubleValue = Double(FPStyle.gridSpacing)
        swipeSensitivity.doubleValue = FPPreferences.swipeSensitivity
        sidebarAnimationDuration.doubleValue = FPPreferences.sidebarAnimationDuration
        swipeWaveSmoothness.doubleValue = FPPreferences.swipeWaveSmoothness
        swipeWaveStrength.doubleValue = FPPreferences.swipeWaveStrength
        swipeWaveDuration.doubleValue = FPPreferences.swipeWaveDuration
        swipeWaveWidth.doubleValue = FPPreferences.swipeWaveWidth
        swipeWaveBlur.doubleValue = FPPreferences.swipeWaveBlur
        swipeWaveExposure.doubleValue = FPPreferences.swipeWaveExposure
        swipeWaveGlow.doubleValue = FPPreferences.swipeWaveGlow
        swipeWaveTint.doubleValue = FPPreferences.swipeWaveTint
        swipeWaveTilt.doubleValue = FPPreferences.swipeWaveTilt
        invertedSwipe.state = FPPreferences.invertedSwipeNavigation ? .on : .off
        grouped.state = FPPreferences.groupLargeFoldersByDate ? .on : .off
        gradientEnabled.state = FPStyle.gradientEnabled ? .on : .off
        summonHotKey.state = FPPreferences.summonHotKeyEnabled ? .on : .off
        if let idx = QyvroWorkspaceLayout.allCases.firstIndex(of: QyvroWorkspaceLayout.current) {
            layoutPopup.selectItem(at: idx)
        }
        if let idx = FPFolderIconStyle.allCases.firstIndex(of: FPFolderIconStyle.current) {
            folderStylePopup.selectItem(at: idx)
        }
        updateValueLabels()
        suppressChanges = false
    }

    @objc private func folderStyleChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard FPFolderIconStyle.allCases.indices.contains(index) else { return }
        FPFolderIconStyle.setCurrent(FPFolderIconStyle.allCases[index])
    }

    @objc private func controlChanged(_ sender: Any?) {
        guard !suppressChanges else { return }
        writeCurrentValues()
        updateValueLabels()
        NotificationCenter.default.post(name: .fpThemeDidChange, object: nil)
    }

    private func writeCurrentValues() {
        FPStyle.saveColor(windowColor.color, key: "ThemeWindowColor")
        FPStyle.saveColor(paneColor.color, key: "ThemePaneColor")
        FPStyle.saveColor(sidebarColor.color, key: "ThemeSidebarColor")
        FPStyle.saveColor(barColor.color, key: "ThemeBarColor")
        FPStyle.saveColor(folderColor.color, key: "ThemeFolderColor")
        FPStyle.saveColor(accentColor.color, key: "ThemeAccentColor")
        FPStyle.saveColor(orangeColor.color, key: "ThemeOrangeColor")
        FPStyle.saveColor(textColor.color, key: "ThemeTextColor")
        FPStyle.saveColor(dimTextColor.color, key: "ThemeDimTextColor")
        FPStyle.saveColor(settingsWindowColor.color, key: "ThemeSettingsWindowColor")
        FPStyle.saveColor(tagWindowColor.color, key: "ThemeTagWindowColor")
        FPStyle.saveColor(gradientStartColor.color, key: "ThemeGradientStart")
        FPStyle.saveColor(gradientEndColor.color, key: "ThemeGradientEnd")
        UserDefaults.standard.set(paneOpacity.doubleValue, forKey: "ThemePaneOpacity")
        UserDefaults.standard.set(sidebarOpacity.doubleValue, forKey: "ThemeSidebarOpacity")
        UserDefaults.standard.set(settingsWindowOpacity.doubleValue, forKey: "ThemeSettingsWindowOpacity")
        UserDefaults.standard.set(tagWindowOpacity.doubleValue, forKey: "ThemeTagWindowOpacity")
        UserDefaults.standard.set(gridSpacing.doubleValue, forKey: "GridSpacing")
        UserDefaults.standard.set(swipeSensitivity.doubleValue, forKey: "SwipeSensitivity")
        UserDefaults.standard.set(sidebarAnimationDuration.doubleValue, forKey: "SidebarAnimationDuration")
        UserDefaults.standard.set(swipeWaveSmoothness.doubleValue, forKey: "SwipeWaveSmoothness")
        UserDefaults.standard.set(swipeWaveStrength.doubleValue, forKey: "SwipeWaveStrength")
        UserDefaults.standard.set(swipeWaveDuration.doubleValue, forKey: "SwipeWaveDuration")
        UserDefaults.standard.set(swipeWaveWidth.doubleValue, forKey: "SwipeWaveWidth")
        UserDefaults.standard.set(swipeWaveBlur.doubleValue, forKey: "SwipeWaveBlur")
        UserDefaults.standard.set(swipeWaveExposure.doubleValue, forKey: "SwipeWaveExposure")
        UserDefaults.standard.set(swipeWaveGlow.doubleValue, forKey: "SwipeWaveGlow")
        UserDefaults.standard.set(swipeWaveTint.doubleValue, forKey: "SwipeWaveTint")
        UserDefaults.standard.set(swipeWaveTilt.doubleValue, forKey: "SwipeWaveTilt")
        UserDefaults.standard.set(invertedSwipe.state == .on, forKey: "SwipeNavigationInverted")
        UserDefaults.standard.set(grouped.state == .on, forKey: "GroupLargeFoldersByDate")
        UserDefaults.standard.set(gradientEnabled.state == .on, forKey: "ThemeGradientEnabled")
        UserDefaults.standard.set(summonHotKey.state == .on, forKey: "GlobalSummonHotKeyEnabled")
        FPStyle.invalidateCache()
        GlobalHotKeyCenter.shared.setEnabled(summonHotKey.state == .on)
        backgroundTintView?.setColor(
            settingsWindowColor.color.withAlphaComponent(CGFloat(settingsWindowOpacity.doubleValue))
        )
    }

    private func updateValueLabels() {
        valueLabels[ObjectIdentifier(paneOpacity)]?.stringValue = "\(Int(paneOpacity.doubleValue * 100))%"
        valueLabels[ObjectIdentifier(sidebarOpacity)]?.stringValue = "\(Int(sidebarOpacity.doubleValue * 100))%"
        valueLabels[ObjectIdentifier(settingsWindowOpacity)]?.stringValue = "\(Int(settingsWindowOpacity.doubleValue * 100))%"
        valueLabels[ObjectIdentifier(tagWindowOpacity)]?.stringValue = "\(Int(tagWindowOpacity.doubleValue * 100))%"
        valueLabels[ObjectIdentifier(gridSpacing)]?.stringValue = "\(Int(gridSpacing.doubleValue)) px"
        valueLabels[ObjectIdentifier(swipeSensitivity)]?.stringValue = "\(Int(swipeSensitivity.doubleValue))%"
        valueLabels[ObjectIdentifier(sidebarAnimationDuration)]?.stringValue = String(format: "%.1f c", sidebarAnimationDuration.doubleValue)
        valueLabels[ObjectIdentifier(swipeWaveSmoothness)]?.stringValue = "\(Int(swipeWaveSmoothness.doubleValue * 100))%"
        valueLabels[ObjectIdentifier(swipeWaveStrength)]?.stringValue = "\(Int(swipeWaveStrength.doubleValue * 100))%"
        valueLabels[ObjectIdentifier(swipeWaveDuration)]?.stringValue = String(format: "%.2f c", swipeWaveDuration.doubleValue)
        valueLabels[ObjectIdentifier(swipeWaveWidth)]?.stringValue = "\(Int(swipeWaveWidth.doubleValue * 100))%"
        valueLabels[ObjectIdentifier(swipeWaveBlur)]?.stringValue = "\(Int(swipeWaveBlur.doubleValue * 100))%"
        valueLabels[ObjectIdentifier(swipeWaveExposure)]?.stringValue = "\(Int(swipeWaveExposure.doubleValue * 100))%"
        valueLabels[ObjectIdentifier(swipeWaveGlow)]?.stringValue = "\(Int(swipeWaveGlow.doubleValue * 100))%"
        valueLabels[ObjectIdentifier(swipeWaveTint)]?.stringValue = "\(Int(swipeWaveTint.doubleValue * 100))%"
        valueLabels[ObjectIdentifier(swipeWaveTilt)]?.stringValue = "\(Int(swipeWaveTilt.doubleValue))°"
    }

    private func snapshot(name: String) -> FPUserTheme {
        FPUserTheme(
            name: name,
            window: FPStoredColor(windowColor.color), pane: FPStoredColor(paneColor.color),
            sidebar: FPStoredColor(sidebarColor.color), bar: FPStoredColor(barColor.color),
            folder: FPStoredColor(folderColor.color), accent: FPStoredColor(accentColor.color),
            orange: FPStoredColor(orangeColor.color), gradientStart: FPStoredColor(gradientStartColor.color),
            gradientEnd: FPStoredColor(gradientEndColor.color), paneOpacity: paneOpacity.doubleValue,
            sidebarOpacity: sidebarOpacity.doubleValue, gridSpacing: gridSpacing.doubleValue,
            swipeSensitivity: swipeSensitivity.doubleValue, invertedSwipe: invertedSwipe.state == .on,
            grouped: grouped.state == .on, gradientEnabled: gradientEnabled.state == .on,
            text: FPStoredColor(textColor.color), dimText: FPStoredColor(dimTextColor.color),
            sidebarAnimationDuration: sidebarAnimationDuration.doubleValue,
            settingsWindow: FPStoredColor(settingsWindowColor.color), tagWindow: FPStoredColor(tagWindowColor.color),
            settingsWindowOpacity: settingsWindowOpacity.doubleValue, tagWindowOpacity: tagWindowOpacity.doubleValue,
            swipeWaveSmoothness: swipeWaveSmoothness.doubleValue,
            swipeWaveStrength: swipeWaveStrength.doubleValue,
            swipeWaveDuration: swipeWaveDuration.doubleValue,
            swipeWaveWidth: swipeWaveWidth.doubleValue,
            swipeWaveBlur: swipeWaveBlur.doubleValue,
            swipeWaveExposure: swipeWaveExposure.doubleValue,
            swipeWaveGlow: swipeWaveGlow.doubleValue,
            swipeWaveTint: swipeWaveTint.doubleValue,
            swipeWaveTilt: swipeWaveTilt.doubleValue,
            styleVariant: FPStyle.styleVariant.rawValue
        )
    }

    private func apply(_ theme: FPUserTheme) {
        suppressChanges = true
        windowColor.color = theme.window.color
        paneColor.color = theme.pane.color
        sidebarColor.color = theme.sidebar.color
        barColor.color = theme.bar.color
        folderColor.color = theme.folder.color
        accentColor.color = theme.accent.color
        orangeColor.color = theme.orange.color
        textColor.color = theme.text?.color ?? FPStyle.text
        dimTextColor.color = theme.dimText?.color ?? FPStyle.dimText
        settingsWindowColor.color = theme.settingsWindow?.color ?? theme.window.color
        tagWindowColor.color = theme.tagWindow?.color ?? theme.sidebar.color
        gradientStartColor.color = theme.gradientStart.color
        gradientEndColor.color = theme.gradientEnd.color
        paneOpacity.doubleValue = theme.paneOpacity
        sidebarOpacity.doubleValue = theme.sidebarOpacity
        settingsWindowOpacity.doubleValue = theme.settingsWindowOpacity ?? 0.88
        tagWindowOpacity.doubleValue = theme.tagWindowOpacity ?? 0.82
        gridSpacing.doubleValue = theme.gridSpacing
        swipeSensitivity.doubleValue = theme.swipeSensitivity
        sidebarAnimationDuration.doubleValue = theme.sidebarAnimationDuration ?? FPPreferences.sidebarAnimationDuration
        swipeWaveSmoothness.doubleValue = theme.swipeWaveSmoothness ?? FPPreferences.swipeWaveSmoothness
        swipeWaveStrength.doubleValue = theme.swipeWaveStrength ?? FPPreferences.swipeWaveStrength
        swipeWaveDuration.doubleValue = theme.swipeWaveDuration ?? FPPreferences.swipeWaveDuration
        swipeWaveWidth.doubleValue = theme.swipeWaveWidth ?? FPPreferences.swipeWaveWidth
        swipeWaveBlur.doubleValue = theme.swipeWaveBlur ?? FPPreferences.swipeWaveBlur
        swipeWaveExposure.doubleValue = theme.swipeWaveExposure ?? FPPreferences.swipeWaveExposure
        swipeWaveGlow.doubleValue = theme.swipeWaveGlow ?? FPPreferences.swipeWaveGlow
        swipeWaveTint.doubleValue = theme.swipeWaveTint ?? FPPreferences.swipeWaveTint
        swipeWaveTilt.doubleValue = theme.swipeWaveTilt ?? FPPreferences.swipeWaveTilt
        invertedSwipe.state = theme.invertedSwipe ? .on : .off
        grouped.state = theme.grouped ? .on : .off
        gradientEnabled.state = theme.gradientEnabled ? .on : .off
        suppressChanges = false
        UserDefaults.standard.set(
            theme.styleVariant ?? FPThemeStyleVariant.classic.rawValue,
            forKey: "ThemeStyleVariant"
        )
        writeCurrentValues()
        updateValueLabels()
        NotificationCenter.default.post(name: .fpThemeDidChange, object: nil)
    }

    @objc private func layoutChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard QyvroWorkspaceLayout.allCases.indices.contains(index) else { return }
        QyvroWorkspaceLayout.setCurrent(QyvroWorkspaceLayout.allCases[index])
    }

    @objc private func presetChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard index > 0 else { return }
        if index <= FPThemePreset.all.count {
            let preset = FPThemePreset.all[index - 1]
            apply(FPUserTheme(
                name: preset.title, window: FPStoredColor(preset.window), pane: FPStoredColor(preset.pane),
                sidebar: FPStoredColor(preset.sidebar), bar: FPStoredColor(preset.bar), folder: FPStoredColor(preset.folder),
                accent: FPStoredColor(preset.accent), orange: FPStoredColor(preset.orange),
                gradientStart: FPStoredColor(preset.gradientStart), gradientEnd: FPStoredColor(preset.gradientEnd),
                paneOpacity: preset.paneOpacity, sidebarOpacity: preset.sidebarOpacity,
                gridSpacing: Double(FPStyle.gridSpacing), swipeSensitivity: FPPreferences.swipeSensitivity,
                invertedSwipe: FPPreferences.invertedSwipeNavigation, grouped: FPPreferences.groupLargeFoldersByDate,
                gradientEnabled: true,
                text: FPStoredColor(preset.textColor),
                dimText: FPStoredColor(preset.dimTextColor),
                sidebarAnimationDuration: FPPreferences.sidebarAnimationDuration,
                settingsWindow: FPStoredColor(preset.window),
                tagWindow: FPStoredColor(preset.sidebar),
                settingsWindowOpacity: preset.styleVariant == .classic ? 0.88 : 0.94,
                tagWindowOpacity: preset.styleVariant == .classic ? 0.82 : 0.92,
                styleVariant: preset.styleVariant.rawValue
            ))
            return
        }
        let userIndex = index - FPThemePreset.all.count - 1
        guard userThemes.indices.contains(userIndex) else { return }
        apply(userThemes[userIndex])
    }

    @objc private func savePreset(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Сохранить свой пресет"
        alert.informativeText = "Он появится в списке готовых тем."
        alert.addButton(withTitle: "Сохранить")
        alert.addButton(withTitle: "Отмена")
        let field = NSTextField(string: "Моя тема")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 28)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let theme = snapshot(name: name)
        if let index = userThemes.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            userThemes[index] = theme
        } else {
            userThemes.append(theme)
        }
        saveUserThemes()
        rebuildPresetMenu()
        presetPopup.selectItem(withTitle: name)
    }

    @objc private func deletePreset(_ sender: Any?) {
        let index = presetPopup.indexOfSelectedItem - FPThemePreset.all.count - 1
        guard userThemes.indices.contains(index) else { NSSound.beep(); return }
        userThemes.remove(at: index)
        saveUserThemes()
        rebuildPresetMenu()
    }

    @objc private func resetSettings(_ sender: Any?) {
        for key in [
            "ThemeWindowColor", "ThemePaneColor", "ThemeSidebarColor", "ThemeBarColor", "ThemeFolderColor",
            "ThemeAccentColor", "ThemeOrangeColor", "ThemeTextColor", "ThemeDimTextColor", "ThemeGradientStart", "ThemeGradientEnd", "ThemeGradientEnabled",
            "ThemeSettingsWindowColor", "ThemeTagWindowColor", "ThemePaneOpacity", "ThemeSidebarOpacity",
            "ThemeSettingsWindowOpacity", "ThemeTagWindowOpacity", "GridSpacing", "SwipeSensitivity",
            "SwipeNavigationInverted", "GroupLargeFoldersByDate", "SidebarAnimationDuration",
            "SwipeWaveSmoothness", "SwipeWaveStrength", "SwipeWaveDuration", "SwipeWaveWidth",
            "SwipeWaveBlur", "SwipeWaveExposure", "SwipeWaveGlow", "SwipeWaveTint", "SwipeWaveTilt",
            "ThemeStyleVariant"
        ] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        FPStyle.invalidateCache()
        loadCurrentValues()
        NotificationCenter.default.post(name: .fpThemeDidChange, object: nil)
    }

    @objc private func clearThumbnailCache(_ sender: Any?) {
        ThumbnailDiskCache.shared.removeAll()
        QyvroPreviewImageCache.shared.removeAll()
        NotificationCenter.default.post(name: .fpThumbnailCacheDidClear, object: nil)
    }

    @objc private func languageChanged(_ sender: Any?) {
        let idx = languagePopup.indexOfSelectedItem
        guard FPAppLanguage.allCases.indices.contains(idx) else { return }
        FPLocalization.selectedLanguage = FPAppLanguage.allCases[idx]
    }

    @objc private func checkUpdatesPressed(_ sender: Any?) {
        QyvroUpdateChecker.shared.checkForUpdates(interactive: true)
    }

    private func rebuildPresetMenu() {
        presetPopup.removeAllItems()
        presetPopup.addItem(withTitle: L("Текущая настройка", "Current Settings"))
        for preset in FPThemePreset.all {
            presetPopup.addItem(withTitle: FPLocalization.localizedThemeTitle(preset.title))
            presetPopup.lastItem?.image = FPThemeSwatchRenderer.swatch(for: preset)
        }
        userThemes.forEach { presetPopup.addItem(withTitle: $0.name) }
    }

    private func loadUserThemes() {
        guard let data = UserDefaults.standard.data(forKey: "UserThemePresetsV1"),
              let themes = try? JSONDecoder().decode([FPUserTheme].self, from: data) else {
            userThemes = []
            return
        }
        userThemes = themes
    }

    private func saveUserThemes() {
        guard let data = try? JSONEncoder().encode(userThemes) else { return }
        UserDefaults.standard.set(data, forKey: "UserThemePresetsV1")
    }
}
