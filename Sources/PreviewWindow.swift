import Cocoa
import Quartz

/// Просмотрщик Qyvro вместо системной панели Quick Look.
///
/// Системная `QLPreviewPanel` не пускает внутрь свои элементы: нельзя
/// нарисовать значок отметки поверх кадра и нельзя показать два-три варианта
/// рядом. Здесь окно наше, а содержимое каждой панели рисует `QLPreviewView` —
/// та же самая система Quick Look, поэтому поддержка форматов остаётся полной
/// (картинки, видео с воспроизведением, PDF, текст), а декодеры писать не надо.

/// Одна панель просмотра: кадр плюс наложенная поверх подпись и отметка.
final class FPPreviewPane: NSView {
    private let previewContainer = NSView()
    private var previewView: QLPreviewView?
    private static let cacheLimit = 4
    private var cache: [(url: URL, view: QLPreviewView)] = []
    private var previousURL: URL?
    private var nameText = ""
    private var detailText = ""
    private let flagBadge = FPSelectedFlagBadge()
    private let focusRing = FPLayerView(color: .clear, cornerRadius: 10)

    private(set) var url: URL?
    var onToggleFlag: ((URL) -> Void)?
    var onActivate: ((FPPreviewPane) -> Void)?
    /// Верхняя панель окна обновляет надпись, когда кадр сменился.
    var onCaptionChanged: (() -> Void)?

    var isFocused = false {
        didSet { updateFocusRing() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        buildLayout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildLayout() {
        focusRing.translatesAutoresizingMaskIntoConstraints = false
        focusRing.layer?.borderWidth = 1.5
        focusRing.layer?.borderColor = NSColor.clear.cgColor

        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.wantsLayer = true
        previewContainer.layer?.cornerRadius = FPStyle.isCyberEditorial ? 4 : 8
        previewContainer.layer?.masksToBounds = true

        flagBadge.translatesAutoresizingMaskIntoConstraints = false
        flagBadge.onToggle = { [weak self] in
            guard let self, let url = self.url else { return }
            self.onToggleFlag?(url)
        }

        addSubview(focusRing)
        addSubview(previewContainer)
        addSubview(flagBadge)
        applyTheme()

        NSLayoutConstraint.activate([
            previewContainer.topAnchor.constraint(equalTo: topAnchor),
            previewContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            previewContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            previewContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            focusRing.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: -2),
            focusRing.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: -2),
            focusRing.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: 2),
            focusRing.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: 2),

            flagBadge.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -10),
            flagBadge.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 10),
            flagBadge.widthAnchor.constraint(equalToConstant: 24),
            flagBadge.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    /// Имя и метрики файла для верхней панели окна.
    var captionParts: (name: String, detail: String) {
        (nameText, detailText)
    }

    /// Кадр остаётся полностью непрозрачным: прозрачность относится к фону
    /// окна, а не к самой картинке — сквозь неё просвечивал рабочий стол.
    func applyTheme() {
        previewContainer.layer?.backgroundColor = NSColor.black
            .withAlphaComponent(0.22).cgColor
        updateFocusRing()
    }

    private func updateFocusRing() {
        focusRing.layer?.borderColor = isFocused
            ? FPStyle.accent.withAlphaComponent(0.85).cgColor
            : NSColor.clear.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        onActivate?(self)
        super.mouseDown(with: event)
    }

    func show(url: URL?) {
        // Если файл тот же, кадр не трогается. Иначе при листании активной
        // панели соседние перезагружали ровно ту же картинку и мигали.
        if url == self.url, url != nil, previewView != nil {
            refreshFlag()
            return
        }
        self.url = url
        // Готовые кадры не выбрасываются, а откладываются: при листании
        // вперёд-назад по одним и тем же файлам картинка декодировалась
        // заново каждый раз. Кэш небольшой — соседние кадры и есть то, между
        // чем человек ходит чаще всего.
        if let previewView, let previous = previousURL {
            previewView.removeFromSuperview()
            cache.removeAll { $0.url == previous }
            cache.append((previous, previewView))
            while cache.count > Self.cacheLimit {
                cache.removeFirst().view.close()
            }
        }
        previewView = nil
        previousURL = url

        guard let url else {
            nameText = ""
            detailText = ""
            flagBadge.isHidden = true
            return
        }

        let cached = cache.first(where: { $0.url == url })?.view
        if cached != nil { cache.removeAll { $0.url == url } }
        let view = cached ?? QLPreviewView(frame: previewContainer.bounds, style: .normal)
        view?.translatesAutoresizingMaskIntoConstraints = false
        view?.autostarts = false
        view?.shouldCloseWithWindow = false
        if let view {
            previewContainer.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: previewContainer.topAnchor),
                view.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
                view.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor)
            ])
            if cached == nil { view.previewItem = url as NSURL }
            previewView = view
        }

        nameText = url.lastPathComponent
        refreshFlag()
        refreshDetail(for: url)
    }

    func refreshFlag() {
        guard let url else { return }
        flagBadge.isHidden = false
        flagBadge.isFlagged = FPFinderTagStore.isFlagged(url: url)
    }

    private func refreshDetail(for url: URL) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize.map {
            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
        }
        let modified = values?.contentModificationDate

        func compose(_ media: FPMediaInfo?) -> String {
            var parts: [String] = []
            if let media {
                parts.append(media.pixelSizeText)
                if let duration = media.durationText { parts.append(duration) }
            }
            if let size { parts.append(size) }
            return parts.joined(separator: "  •  ")
        }

        detailText = compose(FPMediaInfoCache.cached(for: url, modified: modified))
        onCaptionChanged?()
        FPMediaInfoCache.load(for: url, modified: modified) { [weak self] media in
            guard let self, self.url == url else { return }
            self.detailText = compose(media)
            self.onCaptionChanged?()
        }
    }

    func teardown() {
        previewView?.close()
        previewView?.removeFromSuperview()
        previewView = nil
        for entry in cache { entry.view.close() }
        cache.removeAll()
        previousURL = nil
        url = nil
    }
}

/// Содержимое окна: одна, две или три панели рядом.
final class FPPreviewContentView: NSView {
    /// Подложка и градиент вынесены отдельными видами, а прозрачность
    /// применяется к ним. Раньше она стояла на всём окне, и вместе с фоном
    /// просвечивала сама картинка.
    private let backdrop = NSVisualEffectView()
    private let backgroundGradientView = FPBackgroundGradientView()
    private let topBar = NSVisualEffectView()
    private let nameButton = NSButton()
    private let detailField = NSTextField(labelWithString: "")
    private let copyHint = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private let hintBar = NSTextField(labelWithString: "")
    private(set) var panes: [FPPreviewPane] = []
    var onKeyDown: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        backdrop.material = .underWindowBackground
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backgroundGradientView.translatesAutoresizingMaskIntoConstraints = false

        // Верхняя панель повторяет панель проводника: то же стекло, та же
        // обводка и радиус. Кадр начинается сразу под ней, без зазора.
        topBar.material = .hudWindow
        topBar.blendingMode = .withinWindow
        topBar.state = .active
        topBar.wantsLayer = true
        topBar.layer?.cornerRadius = FPStyle.isCyberEditorial ? 5 : 9
        topBar.layer?.borderWidth = 1
        topBar.translatesAutoresizingMaskIntoConstraints = false

        nameButton.isBordered = false
        nameButton.bezelStyle = .inline
        nameButton.alignment = .left
        nameButton.target = self
        nameButton.action = #selector(copyName(_:))
        nameButton.toolTip = "Нажмите, чтобы скопировать имя файла"
        nameButton.translatesAutoresizingMaskIntoConstraints = false
        nameButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        detailField.alignment = .right
        detailField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        detailField.translatesAutoresizingMaskIntoConstraints = false
        detailField.setContentHuggingPriority(.required, for: .horizontal)

        copyHint.alignment = .center
        copyHint.font = FPStyle.headingFont(ofSize: 9.5, weight: .semibold)
        copyHint.stringValue = ""
        copyHint.translatesAutoresizingMaskIntoConstraints = false
        copyHint.setContentHuggingPriority(.required, for: .horizontal)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 10

        hintBar.translatesAutoresizingMaskIntoConstraints = false
        hintBar.alignment = .center
        hintBar.attributedStringValue = Self.hintText()

        addSubview(backdrop)
        addSubview(backgroundGradientView)
        addSubview(topBar)
        topBar.addSubview(nameButton)
        topBar.addSubview(copyHint)
        topBar.addSubview(detailField)
        addSubview(stack)
        addSubview(hintBar)

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            backgroundGradientView.topAnchor.constraint(equalTo: topAnchor),
            backgroundGradientView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundGradientView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundGradientView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Отступ слева освобождает место под кнопки светофора: панель
            // стоит с ними в одном ряду, поэтому пустой полосы сверху нет.
            topBar.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            topBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 78),
            topBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            topBar.heightAnchor.constraint(equalToConstant: 28),

            nameButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 10),
            nameButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            copyHint.leadingAnchor.constraint(equalTo: nameButton.trailingAnchor, constant: 6),
            copyHint.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            detailField.leadingAnchor.constraint(
                greaterThanOrEqualTo: copyHint.trailingAnchor,
                constant: 10
            ),
            detailField.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -10),
            detailField.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            stack.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 6),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.bottomAnchor.constraint(equalTo: hintBar.topAnchor, constant: -6),

            hintBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            hintBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            hintBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            hintBar.heightAnchor.constraint(equalToConstant: 17)
        ])
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Строка подсказок: клавиша выделена цветом темы, действие набрано
    /// капсом. Кегль подобран так, чтобы читалось с рабочего расстояния.
    private static func hintText() -> NSAttributedString {
        let pairs = [
            ("← →", "листать"),
            ("F", "отметить"),
            ("⌫", "в корзину"),
            ("C", "сравнение"),
            ("T", "во весь экран"),
            ("Esc", "закрыть")
        ]
        let line = NSMutableAttributedString()
        for (index, pair) in pairs.enumerated() {
            if index > 0 {
                line.append(NSAttributedString(
                    string: "      ",
                    attributes: [.font: NSFont.systemFont(ofSize: 12)]
                ))
            }
            line.append(NSAttributedString(
                string: pair.0,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold),
                    .foregroundColor: FPStyle.orange
                ]
            ))
            line.append(NSAttributedString(
                string: "  " + pair.1.uppercased(),
                attributes: [
                    .font: FPStyle.headingFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: FPStyle.text.withAlphaComponent(0.78),
                    .kern: 0.6
                ]
            ))
        }
        return line
    }

    func applyTheme() {
        let opacity = min(max(FPStyle.pane.alphaComponent, 0), 1)
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
        // Прозрачность применяется только к подложке, кадр её не наследует.
        backdrop.alphaValue = FPStyle.previewOpacity
        backgroundGradientView.alphaValue = FPStyle.previewOpacity
        topBar.alphaValue = FPStyle.previewOpacity
        topBar.layer?.backgroundColor = FPStyle.bar.withAlphaComponent(0.62).cgColor
        topBar.layer?.borderColor = FPStyle.stroke.withAlphaComponent(0.70).cgColor
        detailField.textColor = FPStyle.dimText
        copyHint.textColor = FPStyle.orange
        hintBar.attributedStringValue = Self.hintText()
        panes.forEach { $0.applyTheme() }
    }

    func setCaption(name: String, detail: String) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byTruncatingMiddle
        nameButton.attributedTitle = NSAttributedString(
            string: name,
            attributes: [
                .font: FPStyle.headingFont(ofSize: 12, weight: .semibold),
                .foregroundColor: FPStyle.text,
                .paragraphStyle: paragraph
            ]
        )
        detailField.stringValue = detail
        copyHint.stringValue = ""
    }

    @objc private func copyName(_ sender: Any?) {
        let name = nameButton.title
        guard !name.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(name, forType: .string)
        FPActionLog.action("имя файла скопировано", name)
        copyHint.stringValue = "СКОПИРОВАНО"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            self?.copyHint.stringValue = ""
        }
    }

    func setPaneCount(_ count: Int, configure: (FPPreviewPane) -> Void) {
        let target = max(1, min(3, count))
        while panes.count > target {
            let pane = panes.removeLast()
            pane.teardown()
            stack.removeArrangedSubview(pane)
            pane.removeFromSuperview()
        }
        while panes.count < target {
            let pane = FPPreviewPane(frame: .zero)
            configure(pane)
            panes.append(pane)
            stack.addArrangedSubview(pane)
        }
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }
}

/// Окно просмотрщика: навигация, разбор пачки, сравнение вариантов.
final class FPPreviewWindowController: NSWindowController, NSWindowDelegate {
    private let contentView = FPPreviewContentView(frame: NSRect(x: 0, y: 0, width: 1_100, height: 760))
    private var entries: [FPQuickLookGalleryEntry] = []
    /// Позиция каждой панели по отдельности.
    ///
    /// В сравнении панели листаются независимо: одну придерживаешь как
    /// эталон, вторую прогоняешь по вариантам. Общий индекс двигал обе
    /// сразу, и сравнивать было не с чем.
    private var paneIndices: [Int] = [0]
    private var paneCount = 1
    private var focusedPane = 0
    private var onIndexChanged: ((URL) -> Void)?
    /// Клавиши ловятся монитором, а не цепочкой респондеров: `QLPreviewView`
    /// внутри панели забирает фокус себе при создании, и `keyDown` до нашего
    /// содержимого не доходит.
    private var keyMonitor: Any?
    /// Рамка окна до растягивания на экран, чтобы вернуть её обратно.
    private var framedBeforeMaximize: NSRect?

    /// Сетка под окном должна догонять удаление и отметку сразу.
    var onNeedsRefresh: (() -> Void)?

    var isPresenting: Bool { window?.isVisible == true }

    /// Подставляет файл, выбранный в проводнике, в выделенную панель.
    ///
    /// Просмотрщик остаётся открытым: переключаешься в проводник, тыкаешь
    /// другой файл — он встаёт в ту панель, которая выделена, а соседние
    /// остаются на своих кадрах.
    func replaceFocusedPane(with request: FPQuickLookRequest) {
        guard isPresenting, !request.entries.isEmpty else { return }
        entries = request.entries
        onIndexChanged = request.onIndexChanged
        let target = min(max(request.initialIndex, 0), entries.count - 1)
        normalizePaneIndices()
        guard paneIndices.indices.contains(focusedPane) else { return }
        paneIndices[focusedPane] = target
        refreshPanes()
        window?.makeKeyAndOrderFront(nil)
    }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 760),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = FPStyle.gradientEnd
        window.isOpaque = false
        window.backgroundColor = .clear
        window.minSize = NSSize(width: 520, height: 420)
        // Зелёная кнопка растягивает окно по экрану, а не уводит в системный
        // полноэкранный режим: тот выносит окно на отдельный рабочий стол, и
        // перетаскивать файлы в проводник становится неудобно.
        // Окно должно появляться на том рабочем столе, где сейчас проводник.
        // Без этого macOS показывает его там, где оно открывалось в прошлый
        // раз, и пробел перебрасывал на другой рабочий стол.
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.collectionBehavior.insert(.moveToActiveSpace)
        super.init(window: window)
        window.delegate = self
        window.contentView = contentView
        contentView.onKeyDown = { [weak self] event in
            self?.handle(event) ?? false
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(_ request: FPQuickLookRequest) {
        entries = request.entries
        onIndexChanged = request.onIndexChanged
        // Каждый показ начинается с одной панели: режим сравнения не должен
        // переживать закрытие окна, иначе следующий пробел открывает пачку.
        paneCount = 1
        framedBeforeMaximize = nil
        let start = min(max(request.initialIndex, 0), max(entries.count - 1, 0))
        paneIndices = (0..<paneCount).map { min(start + $0, max(entries.count - 1, 0)) }
        focusedPane = 0
        contentView.applyTheme()
        rebuildPanes()
        centerOnActiveScreen()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        refreshPanes()
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown]
        ) { [weak self] event in
            guard let self,
                  let window = self.window,
                  window.isVisible else { return event }
            if event.type == .leftMouseDown {
                // Выбор панели ловится здесь, потому что QLPreviewView
                // занимает всю её площадь и забирает клики себе — до
                // mouseDown самой панели они не доходят. Событие не
                // съедается: воспроизведение и прокрутка внутри кадра
                // должны продолжать работать.
                guard event.window === window else { return event }
                self.focusPane(at: event)
                return event
            }
            guard window.isKeyWindow else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func focusPane(at event: NSEvent) {
        guard paneCount > 1 else { return }
        for (position, pane) in contentView.panes.enumerated() {
            let local = pane.convert(event.locationInWindow, from: nil)
            guard pane.bounds.contains(local) else { continue }
            guard position != focusedPane else { return }
            focusedPane = position
            updateFocusRings()
            updateTitle()
            refreshCaption()
            if let url = focusedURL { onIndexChanged?(url) }
            return
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func centerOnActiveScreen() {
        guard let window,
              let screen = NSApp.keyWindow?.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = NSSize(
            width: min(window.frame.width, visible.width * 0.9),
            height: min(window.frame.height, visible.height * 0.9)
        )
        window.setFrame(
            NSRect(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2,
                width: size.width,
                height: size.height
            ).integral,
            display: true
        )
    }

    private func rebuildPanes() {
        contentView.setPaneCount(paneCount) { [weak self] pane in
            pane.onToggleFlag = { [weak self] url in self?.toggleFlag(url) }
            pane.onCaptionChanged = { [weak self] in self?.refreshCaption() }
            pane.onActivate = { [weak self] pane in
                guard let self,
                      let position = self.contentView.panes.firstIndex(of: pane) else { return }
                self.focusedPane = position
                self.updateFocusRings()
            }
        }
        updateFocusRings()
    }

    private func updateFocusRings() {
        // Кольцо подсвечивает панель, к которой относятся ⌫ и F. При одной
        // панели подсвечивать нечего, выбор очевиден.
        for (position, pane) in contentView.panes.enumerated() {
            pane.isFocused = paneCount > 1 && position == focusedPane
        }
    }

    private func refreshPanes() {
        guard !entries.isEmpty else {
            close()
            return
        }
        normalizePaneIndices()
        for (offset, pane) in contentView.panes.enumerated() {
            let position = paneIndices.indices.contains(offset) ? paneIndices[offset] : 0
            pane.show(url: entries.indices.contains(position) ? entries[position].url : nil)
        }
        updateFocusRings()
        updateTitle()
        refreshCaption()
        if let url = focusedURL { onIndexChanged?(url) }
    }

    /// Верхняя строка показывает файл активной панели: при сравнении надпись
    /// должна относиться к той панели, с которой человек работает.
    private func refreshCaption() {
        guard contentView.panes.indices.contains(focusedPane) else { return }
        let parts = contentView.panes[focusedPane].captionParts
        contentView.setCaption(name: parts.name, detail: parts.detail)
    }

    private func normalizePaneIndices() {
        while paneIndices.count < paneCount {
            paneIndices.append(min((paneIndices.last ?? -1) + 1, entries.count - 1))
        }
        if paneIndices.count > paneCount {
            paneIndices.removeLast(paneIndices.count - paneCount)
        }
        paneIndices = paneIndices.map { min(max($0, 0), max(entries.count - 1, 0)) }
        focusedPane = min(max(focusedPane, 0), paneCount - 1)
    }

    private func updateTitle() {
        let position = "\(focusedIndex + 1) из \(entries.count)"
        window?.title = paneCount > 1
            ? "\(position)  ·  сравнение \(paneCount)"
            : position
    }

    private var focusedIndex: Int {
        paneIndices.indices.contains(focusedPane) ? paneIndices[focusedPane] : 0
    }

    private var focusedURL: URL? {
        entries.indices.contains(focusedIndex) ? entries[focusedIndex].url : nil
    }

    /// Стрелки двигают только выделенную панель. Соседние остаются на своих
    /// кадрах, иначе сравнение теряет смысл.
    private func move(by delta: Int) {
        guard !entries.isEmpty, paneIndices.indices.contains(focusedPane) else { return }
        let next = paneIndices[focusedPane] + delta
        guard next >= 0, next < entries.count else { return }
        paneIndices[focusedPane] = next
        refreshPanes()
    }

    private func toggleFlag(_ url: URL) {
        let flagged = FPFinderTagStore.isFlagged(url: url)
        guard (try? FPFinderTagStore.setFlag(!flagged, on: url)) != nil else {
            NSSound.beep()
            return
        }
        contentView.panes.forEach { $0.refreshFlag() }
        onNeedsRefresh?()
    }

    private func trashFocused() {
        guard let url = focusedURL else {
            NSSound.beep()
            return
        }
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
        let removed = focusedIndex
        entries.remove(at: removed)
        onNeedsRefresh?()
        guard !entries.isEmpty else {
            close()
            return
        }
        // Позиции соседних панелей сдвигаются вместе с удалённым элементом,
        // иначе они молча перескочили бы на другие кадры.
        paneIndices = paneIndices.map { $0 > removed ? $0 - 1 : $0 }
        refreshPanes()
    }

    /// Растягивает окно на видимую область экрана и возвращает обратно.
    func toggleMaximized() {
        guard let window,
              let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        if let previous = framedBeforeMaximize {
            framedBeforeMaximize = nil
            window.setFrame(previous, display: true, animate: true)
            return
        }
        framedBeforeMaximize = window.frame
        window.setFrame(visible, display: true, animate: true)
    }

    /// Системный полноэкранный режим перехватывается: зелёная кнопка и
    /// двойной щелчок по заголовку должны растягивать окно по экрану.
    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        toggleMaximized()
        return false
    }

    private func cyclePaneCount() {
        let previous = paneCount
        paneCount = paneCount % 3 + 1
        if paneCount > previous {
            // Новая панель встаёт на следующий кадр после последней, чтобы
            // сравнение сразу показывало разные файлы.
            let next = (paneIndices.max() ?? 0) + 1
            paneIndices.append(min(next, max(entries.count - 1, 0)))
        }
        focusedPane = min(focusedPane, paneCount - 1)
        rebuildPanes()
        refreshPanes()
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            return false
        }
        switch event.keyCode {
        case 123: move(by: -1)                        // ←
        case 124: move(by: 1)                         // →
        case 53, 49: close()                          // Esc, пробел
        case 51: trashFocused()                       // ⌫
        case 3: focusedURL.map(toggleFlag)            // F
        case 8: cyclePaneCount()                      // C
        case 17: toggleMaximized()                    // T — на весь экран
        case 18, 19, 20 where paneCount > 1:          // 1, 2, 3 — выбор панели
            let requested = Int(event.charactersIgnoringModifiers ?? "1") ?? 1
            guard requested >= 1, requested <= paneCount else { return true }
            focusedPane = requested - 1
            updateFocusRings()
        default: return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        removeKeyMonitor()
        contentView.panes.forEach { $0.teardown() }
        entries.removeAll()
        onIndexChanged = nil
    }
}
