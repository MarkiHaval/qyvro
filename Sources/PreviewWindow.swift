import AVKit
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
    /// Видео показывается родным плеером, а не через Quick Look.
    ///
    /// У Quick Look внутри чужого окна панель воспроизведения пряталась по
    /// таймауту и не возвращалась при наведении: он не получал событий о
    /// движении мыши, а повлиять на это снаружи нельзя. Свой плеер даёт
    /// плавающие элементы управления, которыми управляем мы.
    private var playerView: AVPlayerView?
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
        playerView?.player?.pause()
        playerView?.removeFromSuperview()
        playerView = nil

        guard let url else {
            nameText = ""
            detailText = ""
            flagBadge.isHidden = true
            return
        }

        if FPMediaInfoCache.movieExtensions.contains(url.pathExtension.lowercased()) {
            // Видео идёт мимо Quick Look: свой плеер сам рисует плавающие
            // элементы управления и не зависит от того, доходят ли до него
            // события мыши через чужое окно.
            let player = AVPlayerView(frame: previewContainer.bounds)
            player.translatesAutoresizingMaskIntoConstraints = false
            player.controlsStyle = .floating
            player.showsFullScreenToggleButton = false
            player.videoGravity = .resizeAspect
            player.player = AVPlayer(url: url)
            previewContainer.addSubview(player)
            NSLayoutConstraint.activate([
                player.topAnchor.constraint(equalTo: previewContainer.topAnchor),
                player.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
                player.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
                player.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor)
            ])
            playerView = player
            nameText = url.lastPathComponent
            refreshFlag()
            refreshDetail(for: url)
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

    /// Показ и скрытие элементов управления оставлены самому плееру.
    ///
    /// Ручное переключение стиля прятало панель, но оставляло на кадре
    /// размытую плашку-подложку: она рисуется отдельно и не убирается вместе
    /// с кнопками. Родное поведение AVPlayerView прячет и то и другое.
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
        playerView?.player?.pause()
        playerView?.removeFromSuperview()
        playerView = nil
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
            ("V", "шторка"),
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

    func setPanesHidden(_ hidden: Bool) {
        stack.isHidden = hidden
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
    private let curtain = FPCurtainCompareView(frame: .zero)
    private var isCurtainMode = false
    private var curtainLoadedURLs: [URL] = []
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
        // Quick Look показывает элементы управления видео, пока видит движение
        // мыши внутри себя, и прячет их по таймауту. Окно обязано явно
        // запросить доставку этих событий: без запроса панель воспроизведения
        // пряталась и не возвращалась при наведении.
        window.acceptsMouseMovedEvents = true
        window.minSize = NSSize(width: 520, height: 420)
        // Жёсткий потолок размера. Кадры в 5504 точки шириной раз за разом
        // утягивали окно за границы экрана; ограничение сверху не даёт этому
        // случиться, каким бы ни было разрешение картинки.
        if let visible = NSScreen.main?.visibleFrame.size {
            window.maxSize = visible
        }
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
        paneCount = request.opensAsCurtain ? 2 : 1
        isCurtainMode = request.opensAsCurtain
        curtainLoadedURLs = []
        framedBeforeMaximize = nil
        if isCurtainMode { installCurtain() } else { curtain.removeFromSuperview() }
        let start = min(max(request.initialIndex, 0), max(entries.count - 1, 0))
        if isCurtainMode, let second = request.curtainSecondIndex {
            paneIndices = [start, min(max(second, 0), max(entries.count - 1, 0))]
        } else {
            paneIndices = (0..<paneCount).map { min(start + $0, max(entries.count - 1, 0)) }
        }
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
        // Потолок пересчитывается под текущий экран: у окна мог остаться
        // предел от другого монитора.
        window.maxSize = visible.size
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
        curtain.isHidden = !isCurtainMode
        // Панели под шторкой не нужны: они держали бы вторые копии тех же
        // кадров и рисовались впустую.
        contentView.setPanesHidden(isCurtainMode)
        updateCurtainImages()
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

    /// Включает сравнение шторкой поверх панелей.
    ///
    /// Шторке нужны ровно два кадра, поэтому при включении число панелей
    /// доводится до двух: иначе непонятно, какие варианты накладывать.
    private func toggleCurtain() {
        isCurtainMode.toggle()
        curtainLoadedURLs = []
        FPActionLog.action("шторка → \(isCurtainMode ? "включена" : "выключена")")
        if isCurtainMode {
            if paneCount < 2 {
                paneCount = 2
                normalizePaneIndices()
                rebuildPanes()
            }
            installCurtain()
        } else {
            curtain.removeFromSuperview()
        }
        refreshPanes()
    }

    private func installCurtain() {
        guard curtain.superview == nil else { return }
        // Окно возвращается к разумному размеру: до правки приоритетов оно
        // успевало раздуться, и след от этого оставался в сохранённой рамке.
        if let window, let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            let size = NSSize(
                width: min(window.frame.width, visible.width * 0.9),
                height: min(window.frame.height, visible.height * 0.9)
            )
            if size != window.frame.size {
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
        }
        curtain.translatesAutoresizingMaskIntoConstraints = false
        curtain.applyTheme()
        contentView.addSubview(curtain)
        NSLayoutConstraint.activate([
            curtain.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 40),
            curtain.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            curtain.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            curtain.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -32)
        ])
    }

    /// Готовит кадры для шторки.
    ///
    /// Изображения уменьшаются при чтении: наложить два кадра по 5504×3072
    /// в полном разрешении означает держать в памяти под 150 МБ и тормозить
    /// на каждом движении границы. Для сравнения деталей хватает размера
    /// вдвое больше экрана.
    private func updateCurtainImages() {
        guard isCurtainMode else { return }
        let urls = paneIndices.prefix(2).compactMap { index -> URL? in
            entries.indices.contains(index) ? entries[index].url : nil
        }
        guard urls.count == 2, urls != curtainLoadedURLs else { return }
        curtainLoadedURLs = urls
        let limit = Int(max(curtain.bounds.width, 900) * 2)
        DispatchQueue.global(qos: .userInitiated).async {
            let images = urls.map { Self.downscaled(url: $0, maxSide: limit) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurtainMode, self.curtainLoadedURLs == urls else { return }
                self.curtain.setImages(left: images.first ?? nil, right: images.last ?? nil)
            }
        }
    }

    /// Читает картинку сразу уменьшенной — полный размер для шторки не нужен.
    private static func downscaled(url: URL, maxSide: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
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
        case 9: toggleCurtain()                       // V — шторка
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

/// Сравнение шторкой: два кадра наложены друг на друга, между ними подвижная
/// вертикальная граница.
///
/// Панели рядом хороши, когда варианты различаются заметно. Когда разница в
/// деталях — цвет кожи, детализация ткани, — глазу нужно видеть их в одной
/// точке экрана. Шторка это и даёт: тянешь границу и видишь, где кадры
/// расходятся.
final class FPCurtainCompareView: NSView {
    private let leftView = NSImageView()
    private let rightView = NSImageView()
    private let leftClip = NSView()
    private let handle = FPLayerView(color: .clear)
    private let handleGrip = FPLayerView(color: .clear, cornerRadius: 9)
    private var position: CGFloat = 0.5
    private var isDragging = false

    /// Подпись рассказывает, что слева и что справа: без неё через минуту
    /// работы уже не помнишь, какой вариант с какой стороны.
    var onPositionChanged: ((CGFloat) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true

        for view in [leftView, rightView] {
            view.imageScaling = .scaleProportionallyUpOrDown
            view.animates = false
            view.translatesAutoresizingMaskIntoConstraints = false
            // Вид с картинкой требует размер по самому изображению. Без сброса
            // приоритетов два кадра 5504×3072 растягивали окно далеко за
            // пределы экрана.
            view.setContentHuggingPriority(.defaultLow, for: .horizontal)
            view.setContentHuggingPriority(.defaultLow, for: .vertical)
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        }
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        leftClip.wantsLayer = true
        leftClip.layer?.masksToBounds = true
        leftClip.translatesAutoresizingMaskIntoConstraints = false
        handle.translatesAutoresizingMaskIntoConstraints = false
        handleGrip.translatesAutoresizingMaskIntoConstraints = false

        addSubview(rightView)
        addSubview(leftClip)
        leftClip.addSubview(leftView)
        addSubview(handle)
        handle.addSubview(handleGrip)

        NSLayoutConstraint.activate([
            rightView.topAnchor.constraint(equalTo: topAnchor),
            rightView.leadingAnchor.constraint(equalTo: leadingAnchor),
            rightView.trailingAnchor.constraint(equalTo: trailingAnchor),
            rightView.bottomAnchor.constraint(equalTo: bottomAnchor),
            // Левый кадр всегда во всю ширину, обрезает его контейнер — иначе
            // картинка сжималась бы при движении границы вместо среза.
            leftView.topAnchor.constraint(equalTo: topAnchor),
            leftView.leadingAnchor.constraint(equalTo: leadingAnchor),
            leftView.widthAnchor.constraint(equalTo: widthAnchor),
            leftView.bottomAnchor.constraint(equalTo: bottomAnchor),
            leftClip.topAnchor.constraint(equalTo: topAnchor),
            leftClip.leadingAnchor.constraint(equalTo: leadingAnchor),
            leftClip.bottomAnchor.constraint(equalTo: bottomAnchor),
            handle.topAnchor.constraint(equalTo: topAnchor),
            handle.bottomAnchor.constraint(equalTo: bottomAnchor),
            handle.widthAnchor.constraint(equalToConstant: 24),
            handleGrip.centerXAnchor.constraint(equalTo: handle.centerXAnchor),
            handleGrip.centerYAnchor.constraint(equalTo: handle.centerYAnchor),
            handleGrip.widthAnchor.constraint(equalToConstant: 18),
            handleGrip.heightAnchor.constraint(equalToConstant: 44)
        ])
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func applyTheme() {
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.22).cgColor
        handleGrip.layer?.backgroundColor = FPStyle.orange.withAlphaComponent(0.92).cgColor
        handleGrip.layer?.borderColor = NSColor.black.withAlphaComponent(0.35).cgColor
        handleGrip.layer?.borderWidth = 1
    }

    func setImages(left: NSImage?, right: NSImage?) {
        leftView.image = left
        rightView.image = right
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let split = bounds.width * position
        leftClip.frame = NSRect(x: 0, y: 0, width: split, height: bounds.height)
        leftView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        handle.frame = NSRect(x: split - 12, y: 0, width: 24, height: bounds.height)
    }

    override func resetCursorRects() {
        addCursorRect(handle.frame, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        isDragging = abs(point.x - bounds.width * position) <= 18
        if isDragging { move(to: point.x) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        move(to: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
    }

    private func move(to x: CGFloat) {
        guard bounds.width > 1 else { return }
        position = min(max(x / bounds.width, 0), 1)
        needsLayout = true
        layoutSubtreeIfNeeded()
        onPositionChanged?(position)
    }
}
