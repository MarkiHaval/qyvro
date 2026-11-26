import Cocoa

extension Notification.Name {
    static let qyvroDropShelfDidChange = Notification.Name("QyvroDropShelfDidChange")
}

/// Хранилище файлов и папок на «Полке временного сбора».
final class QyvroDropShelfStore {
    private(set) var urls: [URL] = []

    var count: Int { urls.count }
    var isEmpty: Bool { urls.isEmpty }

    @discardableResult
    func add(urls newURLs: [URL]) -> Int {
        let manager = FileManager.default
        var existing = Set(urls.map { $0.standardizedFileURL.path })
        var added = 0
        for raw in newURLs {
            let url = raw.standardizedFileURL
            guard manager.fileExists(atPath: url.path),
                  existing.insert(url.path).inserted else { continue }
            urls.append(url)
            added += 1
        }
        if added > 0 {
            NotificationCenter.default.post(name: .qyvroDropShelfDidChange, object: self)
        }
        return added
    }

    func remove(url: URL) {
        let target = url.standardizedFileURL.path
        let before = urls.count
        urls.removeAll { $0.standardizedFileURL.path == target }
        if urls.count != before {
            NotificationCenter.default.post(name: .qyvroDropShelfDidChange, object: self)
        }
    }

    func removeMissing() {
        let manager = FileManager.default
        let before = urls.count
        urls.removeAll { !manager.fileExists(atPath: $0.path) }
        if urls.count != before {
            NotificationCenter.default.post(name: .qyvroDropShelfDidChange, object: self)
        }
    }

    func clear() {
        guard !urls.isEmpty else { return }
        urls.removeAll()
        NotificationCenter.default.post(name: .qyvroDropShelfDidChange, object: self)
    }

    var totalKnownFileBytes: Int64 {
        urls.reduce(Int64(0)) { partial, url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            guard values?.isDirectory != true else { return partial }
            return partial + Int64(values?.fileSize ?? 0)
        }
    }
}

/// Единая точка управления «Полкой временного сбора».
final class QyvroDropShelfModule {
    static let shared = QyvroDropShelfModule()

    let store = QyvroDropShelfStore()
    private var controller: QyvroDropShelfController?
    /// Обработчик переноса/копирования собранных файлов в активную папку Qyvro.
    var onTransferToActiveFolder: (([URL], Bool) -> Bool)?

    func add(urls: [URL], reveal: Bool = false) {
        let added = store.add(urls: urls)
        if added > 0 {
            FPActionLog.action("полка сбора: добавлено \(added)", "всего \(store.count)")
        }
        if reveal {
            show()
        }
    }

    func toggle() {
        if let controller, controller.window?.isVisible == true {
            controller.window?.orderOut(nil)
        } else {
            show()
        }
    }

    func show() {
        store.removeMissing()
        if controller == nil {
            controller = QyvroDropShelfController(store: store) { [weak self] urls, move in
                self?.onTransferToActiveFolder?(urls, move) ?? false
            }
        }
        controller?.present()
    }
}

/// Кнопка «Полка» в верхней панели вкладок: показывает счётчик и принимает
/// перетаскивание файлов прямо на себя без предварительного открытия окна.
final class QyvroShelfToolbarButton: FPToolbarButton {
    var onURLsDropped: (([URL]) -> Void)?
    var onDragHoverEnded: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !droppedFileURLs(sender).isEmpty else { return [] }
        layer?.borderColor = FPStyle.accent.cgColor
        layer?.borderWidth = 1.5
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        layer?.borderColor = FPStyle.stroke.cgColor
        layer?.borderWidth = 0.5
        onDragHoverEnded?()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        layer?.borderColor = FPStyle.stroke.cgColor
        layer?.borderWidth = 0.5
        let urls = droppedFileURLs(sender)
        onDragHoverEnded?()
        guard !urls.isEmpty else { return false }
        onURLsDropped?(urls)
        return true
    }

    private func droppedFileURLs(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
    }
}

private final class QyvroShelfDropHostView: NSView {
    var onURLsDropped: (([URL]) -> Void)?
    private let dropRing = FPLayerView(color: .clear, cornerRadius: 14)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
        dropRing.isHidden = true
        dropRing.layer?.borderWidth = 2
        addSubview(dropRing)
        NSLayoutConstraint.activate([
            dropRing.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            dropRing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            dropRing.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            dropRing.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !extractURLs(sender).isEmpty else { return [] }
        dropRing.layer?.borderColor = FPStyle.accent.cgColor
        dropRing.layer?.backgroundColor = FPStyle.accent.withAlphaComponent(0.08).cgColor
        dropRing.isHidden = false
        addSubview(dropRing, positioned: .above, relativeTo: nil)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropRing.isHidden = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropRing.isHidden = true
        let urls = extractURLs(sender)
        guard !urls.isEmpty else { return false }
        onURLsDropped?(urls)
        return true
    }

    private func extractURLs(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
    }
}

/// Верхняя ручка «Перетащить всю пачку» — позволяет одним движением перенести
/// все собранные файлы из разных папок в Telegram, Figma, браузер или Finder.
private final class QyvroShelfBatchDragView: FPLayerView, NSDraggingSource {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "Потяните отсюда в нужное окно · ⌥ сожмёт картинки")
    private var mouseDownPoint: NSPoint?
    var urlsProvider: (() -> [URL])?

    override var mouseDownCanMoveWindow: Bool { false }

    init() {
        super.init(color: .clear, cornerRadius: 10)
        if #available(macOS 11.0, *) {
            iconView.image = NSImage(systemSymbolName: "hand.draw.fill", accessibilityDescription: nil)
        }
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = FPStyle.headingFont(ofSize: 12.5, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = FPStyle.bodyFont(ofSize: 10, weight: .medium)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(textStack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 46),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    func update(count: Int, bytes: Int64) {
        let sizeText = bytes > 0 ? " · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))" : ""
        titleLabel.stringValue = "Перетащить всё (\(count))\(sizeText)"
    }

    func applyTheme() {
        layer?.backgroundColor = FPStyle.accent.withAlphaComponent(0.14).cgColor
        layer?.borderColor = FPStyle.accent.withAlphaComponent(0.45).cgColor
        layer?.borderWidth = 1
        iconView.contentTintColor = FPStyle.accent
        titleLabel.textColor = FPStyle.text
        subtitleLabel.textColor = FPStyle.dimText
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) >= 4 else { return }
        mouseDownPoint = nil
        let rawURLs = urlsProvider?() ?? []
        guard !rawURLs.isEmpty else { return }
        let prepared = FPUploadPrep.prepareIfRequested(rawURLs, event: event)
        let draggingItems = prepared.enumerated().map { index, url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 44, height: 44)
            let offset = CGFloat(min(index, 4)) * 5
            item.setDraggingFrame(
                NSRect(x: point.x - 22 + offset, y: point.y - 22 - offset, width: 44, height: 44),
                contents: icon
            )
            return item
        }
        beginDraggingSession(with: draggingItems, event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : [.copy, .move]
    }
}

private final class QyvroShelfRowView: FPLayerView, NSDraggingSource {
    let url: URL
    var onRemove: ((URL) -> Void)?
    private let thumbView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let removeButton = NSButton()
    private var mouseDownPoint: NSPoint?

    override var mouseDownCanMoveWindow: Bool { false }

    init(url: URL) {
        self.url = url
        super.init(color: FPStyle.control, cornerRadius: 9, borderColor: FPStyle.stroke, borderWidth: 0.5)

        thumbView.imageScaling = .scaleProportionallyUpOrDown
        thumbView.wantsLayer = true
        thumbView.layer?.cornerRadius = 6
        thumbView.layer?.masksToBounds = true
        thumbView.translatesAutoresizingMaskIntoConstraints = false
        thumbView.image = NSWorkspace.shared.icon(forFile: url.path)

        if QyvroPreviewImageCache.isDirectImage(url) {
            QyvroPreviewImageCache.shared.load(url: url, maxPixelSize: 96) { [weak self] image in
                guard let self, let image else { return }
                self.thumbView.image = image
            }
        }

        nameLabel.stringValue = url.lastPathComponent
        nameLabel.font = FPStyle.headingFont(ofSize: 12, weight: .semibold)
        nameLabel.textColor = FPStyle.text
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        let parentName = url.deletingLastPathComponent().lastPathComponent
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        let sizePart: String
        if values?.isDirectory == true {
            sizePart = "Папка"
        } else if let bytes = values?.fileSize {
            sizePart = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        } else {
            sizePart = ""
        }
        detailLabel.stringValue = sizePart.isEmpty ? parentName : "\(parentName) · \(sizePart)"
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        detailLabel.textColor = FPStyle.dimText
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        let labels = NSStackView(views: [nameLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false

        removeButton.isBordered = false
        removeButton.bezelStyle = .inline
        removeButton.imagePosition = .imageOnly
        if #available(macOS 11.0, *) {
            let img = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Убрать с полки")
            img?.size = NSSize(width: 10, height: 10)
            removeButton.image = img
        } else {
            removeButton.title = "×"
        }
        removeButton.contentTintColor = FPStyle.dimText
        removeButton.toolTip = "Убрать с полки"
        removeButton.target = self
        removeButton.action = #selector(removePressed(_:))
        removeButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(thumbView)
        addSubview(labels)
        addSubview(removeButton)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 46),
            thumbView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            thumbView.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbView.widthAnchor.constraint(equalToConstant: 32),
            thumbView.heightAnchor.constraint(equalToConstant: 32),
            labels.leadingAnchor.constraint(equalTo: thumbView.trailingAnchor, constant: 10),
            labels.trailingAnchor.constraint(equalTo: removeButton.leadingAnchor, constant: -6),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            removeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: 20),
            removeButton.heightAnchor.constraint(equalToConstant: 20)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func removePressed(_ sender: Any?) {
        onRemove?(url)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            NSWorkspace.shared.open(url)
            return
        }
        mouseDownPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) >= 4 else { return }
        mouseDownPoint = nil
        let prepared = FPUploadPrep.prepareIfRequested([url], event: event)
        guard let dragURL = prepared.first else { return }
        let item = NSDraggingItem(pasteboardWriter: dragURL as NSURL)
        item.setDraggingFrame(thumbView.frame, contents: thumbView.image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : [.copy, .move]
    }
}

final class QyvroDropShelfController: NSWindowController {
    private let store: QyvroDropShelfStore
    private let onTransfer: ([URL], Bool) -> Bool
    private let backdrop = FPAuxiliaryBackdrop(frame: .zero)
    private let titleLabel = NSTextField(labelWithString: "ПОЛКА СБОРА")
    private let clearButton = NSButton()
    private let batchDragView = QyvroShelfBatchDragView()
    private let listStack = NSStackView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "Перетащите сюда файлы и папки из любых вкладок, чтобы собрать пачку и перенести одним движением.")
    private let moveHereButton = NSButton()
    private let copyHereButton = NSButton()
    private var observers: [NSObjectProtocol] = []

    init(store: QyvroDropShelfStore, onTransfer: @escaping ([URL], Bool) -> Bool) {
        self.store = store
        self.onTransfer = onTransfer
        let panel = EscapeClosingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 390, height: 430),
            styleMask: [.titled, .closable, .utilityWindow, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Полка сбора"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.minSize = NSSize(width: 320, height: 280)
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init(window: panel)
        buildUI()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .qyvroDropShelfDidChange, object: store, queue: .main) { [weak self] _ in
                self?.reload()
            },
            center.addObserver(forName: .fpThemeDidChange, object: nil, queue: .main) { [weak self] _ in
                self?.applyTheme()
                self?.reload()
            }
        ]
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func present() {
        reload()
        showWindow(nil)
        if let screen = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame, let window {
            if window.frame.origin == .zero {
                let origin = NSPoint(x: screen.maxX - window.frame.width - 28, y: screen.midY - window.frame.height / 2)
                window.setFrameOrigin(origin)
            }
        }
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildUI() {
        guard let window else { return }
        let host = QyvroShelfDropHostView(frame: window.contentRect(forFrameRect: window.frame))
        host.onURLsDropped = { [weak self] urls in
            self?.store.add(urls: urls)
        }
        window.contentView = host
        host.addSubview(backdrop)

        titleLabel.font = FPStyle.headingFont(ofSize: 11.5, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        configurePillButton(clearButton, title: "Очистить", symbol: "trash", tint: FPStyle.danger, action: #selector(clearShelf(_:)))
        configurePillButton(moveHereButton, title: "Перенести сюда", symbol: "arrow.right.doc.on.clipboard", tint: FPStyle.accent, action: #selector(moveAllHere(_:)))
        configurePillButton(copyHereButton, title: "Скопировать сюда", symbol: "doc.on.doc", tint: FPStyle.text, action: #selector(copyAllHere(_:)))

        batchDragView.urlsProvider = { [weak self] in
            self?.store.urls ?? []
        }

        listStack.orientation = .vertical
        listStack.alignment = .width
        listStack.spacing = 6
        listStack.translatesAutoresizingMaskIntoConstraints = false

        let document = FPFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(listStack)

        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets()
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = FPStyle.bodyFont(ofSize: 12, weight: .medium)
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSStackView(views: [moveHereButton, copyHereButton])
        footer.orientation = .horizontal
        footer.distribution = .fillEqually
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        host.addSubview(titleLabel)
        host.addSubview(clearButton)
        host.addSubview(batchDragView)
        host.addSubview(scroll)
        host.addSubview(emptyLabel)
        host.addSubview(footer)

        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: host.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: host.bottomAnchor),

            titleLabel.topAnchor.constraint(equalTo: host.topAnchor, constant: 12),
            titleLabel.centerXAnchor.constraint(equalTo: host.centerXAnchor),

            clearButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -14),
            clearButton.heightAnchor.constraint(equalToConstant: 24),

            batchDragView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            batchDragView.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 14),
            batchDragView.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -14),

            scroll.topAnchor.constraint(equalTo: batchDragView.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -14),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),

            listStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: document.topAnchor),
            listStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -4),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -24),

            footer.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 14),
            footer.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -14),
            footer.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -14),
            footer.heightAnchor.constraint(equalToConstant: 32)
        ])

        QyvroWindowResizeOverlay.install(
            in: host,
            insets: QyvroWindowResizeInsets(left: 8, right: 8, top: 6, bottom: 8, cornerSize: 14)
        )
        applyTheme()
    }

    private func configurePillButton(_ button: NSButton, title: String, symbol: String, tint: NSColor, action: Selector) {
        button.title = title
        button.isBordered = false
        button.bezelStyle = .inline
        button.font = FPStyle.headingFont(ofSize: 11.5, weight: .semibold)
        button.contentTintColor = tint
        if #available(macOS 11.0, *), let img = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            img.size = NSSize(width: 12.5, height: 12.5)
            button.image = img
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
        }
        button.target = self
        button.action = action
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.layer?.backgroundColor = FPStyle.controlStrong.cgColor
        button.layer?.borderColor = FPStyle.stroke.cgColor
        button.layer?.borderWidth = 0.6
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    private func applyTheme() {
        backdrop.applyTheme()
        titleLabel.textColor = FPStyle.dimText
        emptyLabel.textColor = FPStyle.dimText
        batchDragView.applyTheme()
    }

    private func reload() {
        store.removeMissing()
        for view in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let urls = store.urls
        let empty = urls.isEmpty
        emptyLabel.isHidden = !empty
        batchDragView.isHidden = empty
        clearButton.isEnabled = !empty
        moveHereButton.isEnabled = !empty
        copyHereButton.isEnabled = !empty
        batchDragView.update(count: urls.count, bytes: store.totalKnownFileBytes)

        for url in urls {
            let row = QyvroShelfRowView(url: url)
            row.onRemove = { [weak self] removedURL in
                self?.store.remove(url: removedURL)
            }
            listStack.addArrangedSubview(row)
        }
    }

    @objc private func clearShelf(_ sender: Any?) {
        store.clear()
    }

    @objc private func moveAllHere(_ sender: Any?) {
        let urls = store.urls
        guard !urls.isEmpty else { return }
        if onTransfer(urls, true) {
            store.clear()
        }
    }

    @objc private func copyAllHere(_ sender: Any?) {
        let urls = store.urls
        guard !urls.isEmpty else { return }
        _ = onTransfer(urls, false)
    }
}
