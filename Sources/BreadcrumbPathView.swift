import AppKit

private final class FPBreadcrumbButton: NSButton {
    var representedURL: URL?
    var onNavigate: ((URL) -> Void)?
    var onOpenInNewTab: ((URL) -> Void)?
    var onMoveFiles: (([URL], URL) -> Bool)?
    private var trackingAreaReference: NSTrackingArea?
    private var isTerminalSegment = false

    init(title: String, url: URL, terminal: Bool) {
        representedURL = url
        isTerminalSegment = terminal
        super.init(frame: .zero)
        self.title = title
        target = self
        action = #selector(activateSegment(_:))
        isBordered = false
        bezelStyle = .inline
        font = .systemFont(ofSize: 12.5, weight: terminal ? .semibold : .medium)
        contentTintColor = terminal
            ? (FPStyle.isObsidianAurora ? FPStyle.text : FPStyle.orange)
            : (FPStyle.isObsidianAurora ? FPStyle.dimText : FPStyle.text)
        alignment = .center
        lineBreakMode = .byTruncatingMiddle
        toolTip = url.path
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = NSColor.clear.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        setContentCompressionResistancePriority(terminal ? NSLayoutConstraint.Priority(240) : NSLayoutConstraint.Priority(180), for: .horizontal)
        setContentHuggingPriority(NSLayoutConstraint.Priority(230), for: .horizontal)
        heightAnchor.constraint(equalToConstant: 24).isActive = true
        let minWidth = widthAnchor.constraint(greaterThanOrEqualToConstant: 30)
        minWidth.priority = NSLayoutConstraint.Priority(230)
        minWidth.isActive = true
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.13
            context.allowsImplicitAnimation = true
            layer?.backgroundColor = FPStyle.controlStrong.withAlphaComponent(0.92).cgColor
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.allowsImplicitAnimation = true
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    func refreshTheme() {
        contentTintColor = isTerminalSegment
            ? (FPStyle.isObsidianAurora ? FPStyle.text : FPStyle.orange)
            : (FPStyle.isObsidianAurora ? FPStyle.dimText : FPStyle.text)
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        canAccept(sender) ? .move : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        canAccept(sender) ? .move : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let target = representedURL else { return false }
        let objects = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        return !objects.isEmpty && (onMoveFiles?(objects, target) ?? false)
    }

    private func canAccept(_ sender: NSDraggingInfo) -> Bool {
        guard let target = representedURL,
              FileManager.default.fileExists(atPath: target.path) else { return false }
        let objects = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        return objects.contains { source in
            source.standardizedFileURL.deletingLastPathComponent().path != target.path
                && source.standardizedFileURL.path != target.path
        }
    }

    @objc private func activateSegment(_ sender: Any?) {
        guard let representedURL else { return }
        onNavigate?(representedURL)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard representedURL != nil else { return nil }
        let menu = NSMenu(title: "Путь")
        let newTab = NSMenuItem(title: "Открыть в новой вкладке", action: #selector(openSegmentInNewTab(_:)), keyEquivalent: "")
        newTab.target = self
        menu.addItem(newTab)
        let copy = NSMenuItem(title: "Скопировать путь", action: #selector(copySegmentPath(_:)), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
        let reveal = NSMenuItem(title: "Показать в Finder", action: #selector(revealSegmentInFinder(_:)), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)
        return menu
    }

    @objc private func openSegmentInNewTab(_ sender: Any?) {
        guard let representedURL else { return }
        onOpenInNewTab?(representedURL)
    }

    @objc private func copySegmentPath(_ sender: Any?) {
        guard let representedURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(representedURL.path, forType: .string)
    }

    @objc private func revealSegmentInFinder(_ sender: Any?) {
        guard let representedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([representedURL])
    }
}

/// Finder-style clickable path which keeps the full editable field available
/// through ⌘L or a double click.
final class FPBreadcrumbPathView: NSView {
    var onNavigate: ((URL) -> Void)?
    var onOpenInNewTab: ((URL) -> Void)?
    var onRequestEditing: (() -> Void)?
    var onMoveFiles: (([URL], URL) -> Bool)?

    private let stack = NSStackView()
    private let virtualLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.backgroundColor = FPStyle.field.cgColor
        layer?.borderColor = FPStyle.stroke.cgColor
        layer?.borderWidth = 0.5
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 9, bottom: 3, right: 9)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        virtualLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        virtualLabel.textColor = FPStyle.isObsidianAurora ? FPStyle.text : FPStyle.orange
        virtualLabel.lineBreakMode = .byTruncatingMiddle
        virtualLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 112),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onRequestEditing?()
            return
        }
        super.mouseDown(with: event)
    }

    func update(url: URL) {
        clear()
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let standardized = url.standardizedFileURL
        var segments: [(title: String, url: URL)] = []

        if standardized.path == home.path || standardized.path.hasPrefix(home.path + "/") {
            segments.append(("Дом", home))
            let relative = String(standardized.path.dropFirst(home.path.count))
                .split(separator: "/")
                .map(String.init)
            var cursor = home
            for component in relative {
                cursor.appendPathComponent(component, isDirectory: true)
                segments.append((component, cursor))
            }
        } else {
            var cursor = URL(fileURLWithPath: "/", isDirectory: true)
            segments.append(("Macintosh HD", cursor))
            for component in standardized.pathComponents.dropFirst() {
                cursor.appendPathComponent(component, isDirectory: true)
                segments.append((component, cursor))
            }
        }

        for (index, segment) in segments.enumerated() {
            if index > 0 {
                stack.addArrangedSubview(separator())
            }
            let button = FPBreadcrumbButton(
                title: segment.title,
                url: segment.url,
                terminal: index == segments.count - 1
            )
            button.onNavigate = { [weak self] url in self?.onNavigate?(url) }
            button.onOpenInNewTab = { [weak self] url in self?.onOpenInNewTab?(url) }
            button.onMoveFiles = { [weak self] urls, target in
                self?.onMoveFiles?(urls, target) ?? false
            }
            stack.addArrangedSubview(button)
        }
        appendTrailingSpacer()
    }

    func updateVirtualPath(_ title: String) {
        clear()
        virtualLabel.stringValue = title
        stack.addArrangedSubview(virtualLabel)
        appendTrailingSpacer()
    }

    func refreshTheme() {
        let aurora = FPStyle.isObsidianAurora
        layer?.cornerRadius = FPStyle.isCyberEditorial ? 5 : (aurora ? 10 : 12)
        layer?.backgroundColor = FPStyle.field.cgColor
        layer?.borderColor = (aurora ? NSColor.white.withAlphaComponent(0.08) : FPStyle.stroke).cgColor
        virtualLabel.textColor = aurora ? FPStyle.text : FPStyle.orange
        for case let button as FPBreadcrumbButton in stack.arrangedSubviews {
            button.refreshTheme()
        }
    }

    private func clear() {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func appendTrailingSpacer() {
        // NSStackView's default gravity areas place unused width before short
        // paths, which made “Дом › …” jump to the right edge. A dedicated
        // flexible tail consumes all spare space after the final segment, so
        // every path stays anchored to the same leading edge.
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.fittingSizeCompression, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.fittingSizeCompression, for: .horizontal)
        spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 1).isActive = true
        stack.addArrangedSubview(spacer)
    }

    private func separator() -> NSImageView {
        let view = NSImageView()
        if #available(macOS 11.0, *) {
            view.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        }
        view.contentTintColor = FPStyle.dimText.withAlphaComponent(0.72)
        view.imageScaling = .scaleProportionallyDown
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 7).isActive = true
        view.heightAnchor.constraint(equalToConstant: 12).isActive = true
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        return view
    }
}
