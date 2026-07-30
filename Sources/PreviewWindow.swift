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
    private let captionBar = NSVisualEffectView()
    private let nameField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private let flagBadge = FPSelectedFlagBadge()
    private let focusRing = FPLayerView(color: .clear, cornerRadius: 10)

    private(set) var url: URL?
    var onToggleFlag: ((URL) -> Void)?
    var onActivate: ((FPPreviewPane) -> Void)?

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
        previewContainer.layer?.cornerRadius = 10
        previewContainer.layer?.masksToBounds = true
        previewContainer.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.32).cgColor

        captionBar.translatesAutoresizingMaskIntoConstraints = false
        captionBar.material = .hudWindow
        captionBar.blendingMode = .withinWindow
        captionBar.state = .active
        captionBar.wantsLayer = true
        captionBar.layer?.cornerRadius = 8

        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.font = FPStyle.bodyFont(ofSize: 12, weight: .semibold)
        nameField.textColor = FPStyle.text
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        detailField.translatesAutoresizingMaskIntoConstraints = false
        detailField.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        detailField.textColor = FPStyle.dimText
        detailField.alignment = .right
        detailField.setContentHuggingPriority(.required, for: .horizontal)

        flagBadge.translatesAutoresizingMaskIntoConstraints = false
        flagBadge.onToggle = { [weak self] in
            guard let self, let url = self.url else { return }
            self.onToggleFlag?(url)
        }

        addSubview(focusRing)
        addSubview(previewContainer)
        addSubview(captionBar)
        captionBar.addSubview(nameField)
        captionBar.addSubview(detailField)
        addSubview(flagBadge)

        NSLayoutConstraint.activate([
            previewContainer.topAnchor.constraint(equalTo: topAnchor),
            previewContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            previewContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            previewContainer.bottomAnchor.constraint(equalTo: captionBar.topAnchor, constant: -8),

            focusRing.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: -2),
            focusRing.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: -2),
            focusRing.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: 2),
            focusRing.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: 2),

            captionBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            captionBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            captionBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            captionBar.heightAnchor.constraint(equalToConstant: 30),

            nameField.leadingAnchor.constraint(equalTo: captionBar.leadingAnchor, constant: 10),
            nameField.centerYAnchor.constraint(equalTo: captionBar.centerYAnchor),
            detailField.leadingAnchor.constraint(
                greaterThanOrEqualTo: nameField.trailingAnchor,
                constant: 10
            ),
            detailField.trailingAnchor.constraint(equalTo: captionBar.trailingAnchor, constant: -10),
            detailField.centerYAnchor.constraint(equalTo: captionBar.centerYAnchor),

            // Отметка живёт в правом верхнем углу самого кадра — так её видно
            // не выходя из просмотра, ради чего просмотрщик и делался.
            flagBadge.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -10),
            flagBadge.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 10),
            flagBadge.widthAnchor.constraint(equalToConstant: 26),
            flagBadge.heightAnchor.constraint(equalToConstant: 26)
        ])
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
        self.url = url
        // QLPreviewView пересоздаётся под каждый файл: повторное присвоение
        // previewItem у живого экземпляра иногда оставляет на экране кадр от
        // предыдущего файла, пока новый декодируется.
        previewView?.close()
        previewView?.removeFromSuperview()
        previewView = nil

        guard let url else {
            nameField.stringValue = ""
            detailField.stringValue = ""
            flagBadge.isHidden = true
            return
        }

        let view = QLPreviewView(frame: previewContainer.bounds, style: .normal)
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
            view.previewItem = url as NSURL
            previewView = view
        }

        nameField.stringValue = url.lastPathComponent
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

        detailField.stringValue = compose(
            FPMediaInfoCache.cached(for: url, modified: modified)
        )
        FPMediaInfoCache.load(for: url, modified: modified) { [weak self] media in
            guard let self, self.url == url else { return }
            self.detailField.stringValue = compose(media)
        }
    }

    func teardown() {
        previewView?.close()
        previewView?.removeFromSuperview()
        previewView = nil
        url = nil
    }
}

/// Содержимое окна: одна, две или три панели рядом.
final class FPPreviewContentView: NSView {
    private let stack = NSStackView()
    private(set) var panes: [FPPreviewPane] = []
    var onKeyDown: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = FPStyle.gradientEnd.cgColor

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 12
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
    private var index = 0
    private var paneCount = 1
    private var focusedPane = 0
    private var onIndexChanged: ((URL) -> Void)?

    /// Сетка под окном должна догонять удаление и отметку сразу.
    var onNeedsRefresh: (() -> Void)?

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
        window.minSize = NSSize(width: 520, height: 420)
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
        index = min(max(request.initialIndex, 0), max(entries.count - 1, 0))
        focusedPane = 0
        rebuildPanes()
        centerOnActiveScreen()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(contentView)
        refreshPanes()
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
        index = min(max(index, 0), entries.count - 1)
        for (offset, pane) in contentView.panes.enumerated() {
            let position = index + offset
            pane.show(url: entries.indices.contains(position) ? entries[position].url : nil)
        }
        focusedPane = min(focusedPane, paneCount - 1)
        updateFocusRings()
        updateTitle()
        onIndexChanged?(entries[index].url)
    }

    private func updateTitle() {
        let position = "\(index + 1) из \(entries.count)"
        window?.title = paneCount > 1
            ? "\(position)  ·  сравнение \(paneCount)"
            : position
    }

    private var focusedURL: URL? {
        let position = index + focusedPane
        return entries.indices.contains(position) ? entries[position].url : nil
    }

    private func move(by delta: Int) {
        guard !entries.isEmpty else { return }
        // В режиме сравнения шаг равен числу панелей: пачка вариантов
        // пролистывается группами, а не по одному со сдвигом.
        let step = delta * paneCount
        let next = index + step
        guard next >= 0, next < entries.count else { return }
        index = next
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
        let removed = index + focusedPane
        entries.remove(at: removed)
        onNeedsRefresh?()
        guard !entries.isEmpty else {
            close()
            return
        }
        if index >= entries.count { index = max(0, entries.count - paneCount) }
        refreshPanes()
    }

    private func cyclePaneCount() {
        paneCount = paneCount % 3 + 1
        focusedPane = 0
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
        contentView.panes.forEach { $0.teardown() }
        entries.removeAll()
        onIndexChanged = nil
    }
}
