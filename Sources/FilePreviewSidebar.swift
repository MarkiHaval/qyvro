import AppKit
import ImageIO
import QuickLookThumbnailing

private final class FPPreviewImageView: NSImageView {
    /// NSImageView normally advertises the pixel size of its current image.
    /// A late Quick Look result must never be allowed to resize the inspector.
    override var intrinsicContentSize: NSSize { .zero }
}

/// A persistent Finder-style inspector that lives inside the explorer window.
/// It deliberately owns only presentation state; FilePanel remains the source
/// of truth for the current selection.
final class FilePreviewSidebar: NSVisualEffectView {
    var onClose: (() -> Void)?

    private let heading = NSTextField(labelWithString: "Предпросмотр")
    private let closeButton = NSButton()
    private let previewContainer = NSView()
    private let previewImage = FPPreviewImageView()
    private let previewSpinner = NSProgressIndicator()
    private let nameLabel = NSTextField(wrappingLabelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let detailsStack = NSStackView()
    private let emptyIcon = NSImageView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "Выберите файл или папку")
    private let copyPathButton = NSButton()
    private var representedPath: String?
    private var thumbnailRequest: QLThumbnailGenerator.Request?
    private var previewGeneration = 0
    private weak var folderSizeValueLabel: NSTextField?
    private weak var folderSizeSpinner: NSProgressIndicator?
    private let previewCache = NSCache<NSString, NSImage>()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Та же подложка, что у левой панели: настоящее размытие macOS
        // сквозь окно, а не плотная серая заливка поверх него.
        material = .underWindowBackground
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previewCache.countLimit = 80
        buildUI()
        applyTheme()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeChanged(_:)),
            name: .fpThemeDidChange,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let thumbnailRequest {
            QLThumbnailGenerator.shared.cancel(thumbnailRequest)
        }
        NotificationCenter.default.removeObserver(self)
    }

    func update(items: [FileItem]) {
        previewGeneration += 1
        if let thumbnailRequest {
            QLThumbnailGenerator.shared.cancel(thumbnailRequest)
            self.thumbnailRequest = nil
        }
        clearDetails()
        representedPath = nil
        copyPathButton.isHidden = true
        stopPreviewLoading()

        guard !items.isEmpty else {
            showEmptyState()
            return
        }

        emptyIcon.isHidden = true
        emptyLabel.isHidden = true
        previewContainer.isHidden = false
        nameLabel.isHidden = false
        summaryLabel.isHidden = false
        detailsStack.isHidden = false

        if items.count > 1 {
            configureMultiple(items)
        } else if let item = items.first {
            configureSingle(item)
        }
    }

    private func buildUI() {
        let aurora = FPStyle.isObsidianAurora
        heading.font = FPStyle.headingFont(ofSize: aurora ? 14 : 13.5, weight: .semibold)
        heading.stringValue = aurora ? "Предпросмотр" : "ПРЕДПРОСМОТР"
        heading.translatesAutoresizingMaskIntoConstraints = false

        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.toolTip = "Скрыть предпросмотр (⌥⌘P)"
        closeButton.target = self
        closeButton.action = #selector(closePressed(_:))
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.wantsLayer = true
        closeButton.layer?.cornerRadius = 7
        if #available(macOS 11.0, *) {
            closeButton.image = NSImage(
                systemSymbolName: "xmark",
                accessibilityDescription: "Скрыть предпросмотр"
            )
            closeButton.imagePosition = .imageOnly
        } else {
            closeButton.title = "×"
        }

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(heading)
        header.addSubview(closeButton)

        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.wantsLayer = true
        previewContainer.layer?.cornerRadius = FPStyle.isCyberEditorial ? 6 : 12
        previewContainer.layer?.borderWidth = 1
        previewContainer.layer?.borderWidth = 0.5
        previewContainer.layer?.masksToBounds = true

        previewImage.imageScaling = .scaleProportionallyUpOrDown
        previewImage.translatesAutoresizingMaskIntoConstraints = false
        previewImage.setContentHuggingPriority(.defaultLow, for: .horizontal)
        previewImage.setContentHuggingPriority(.defaultLow, for: .vertical)
        previewImage.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previewImage.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        previewContainer.addSubview(previewImage)

        previewSpinner.style = .spinning
        previewSpinner.controlSize = .small
        previewSpinner.isDisplayedWhenStopped = false
        previewSpinner.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(previewSpinner)

        emptyIcon.translatesAutoresizingMaskIntoConstraints = false
        emptyIcon.imageScaling = .scaleProportionallyUpOrDown
        if #available(macOS 11.0, *) {
            emptyIcon.image = NSImage(
                systemSymbolName: "rectangle.and.text.magnifyingglass",
                accessibilityDescription: nil
            )
        }
        emptyLabel.alignment = .center
        emptyLabel.font = FPStyle.bodyFont(ofSize: 12.5, weight: .medium)
        emptyLabel.stringValue = FPStyle.isObsidianAurora ? "Выберите файл или папку" : "ВЫБЕРИТЕ ФАЙЛ ИЛИ ПАПКУ"
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.alignment = .center
        nameLabel.font = FPStyle.headingFont(ofSize: 15, weight: .semibold)
        nameLabel.maximumNumberOfLines = 3
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.alignment = .center
        summaryLabel.font = FPStyle.bodyFont(ofSize: 11.5, weight: .medium)
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        detailsStack.orientation = .vertical
        detailsStack.alignment = .width
        detailsStack.spacing = 8
        detailsStack.translatesAutoresizingMaskIntoConstraints = false

        copyPathButton.title = "Скопировать путь"
        copyPathButton.font = FPStyle.headingFont(ofSize: 12.5, weight: .semibold)
        copyPathButton.isBordered = false
        copyPathButton.bezelStyle = .inline
        copyPathButton.target = self
        copyPathButton.action = #selector(copyPath(_:))
        copyPathButton.translatesAutoresizingMaskIntoConstraints = false
        copyPathButton.wantsLayer = true
        copyPathButton.layer?.cornerRadius = 8
        if #available(macOS 11.0, *) {
            copyPathButton.image = NSImage(
                systemSymbolName: "doc.on.doc",
                accessibilityDescription: nil
            )
            copyPathButton.imagePosition = .imageLeading
            // Без явного выравнивания AppKit прижимает связку «значок + текст»
            // к левому краю кнопки, и значок вылезал за скругление.
            copyPathButton.alignment = .center
            copyPathButton.imageHugsTitle = true
            copyPathButton.imageScaling = .scaleProportionallyDown
        }

        addSubview(header)
        addSubview(previewContainer)
        addSubview(emptyIcon)
        addSubview(emptyLabel)
        addSubview(nameLabel)
        addSubview(summaryLabel)
        addSubview(detailsStack)
        addSubview(copyPathButton)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 250),
            widthAnchor.constraint(lessThanOrEqualToConstant: 400),

            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.heightAnchor.constraint(equalToConstant: 48),
            heading.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 17),
            heading.centerYAnchor.constraint(equalTo: header.centerYAnchor, constant: 1),
            closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
            closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 28),
            closeButton.heightAnchor.constraint(equalToConstant: 28),

            previewContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            previewContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            previewContainer.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            previewContainer.heightAnchor.constraint(equalToConstant: 176),
            previewImage.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 8),
            previewImage.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -8),
            previewImage.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 8),
            previewImage.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: -8),
            previewSpinner.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            previewSpinner.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),

            emptyIcon.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            emptyIcon.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor, constant: -12),
            emptyIcon.widthAnchor.constraint(equalToConstant: 42),
            emptyIcon.heightAnchor.constraint(equalToConstant: 42),
            emptyLabel.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 18),
            emptyLabel.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -18),
            emptyLabel.topAnchor.constraint(equalTo: emptyIcon.bottomAnchor, constant: 12),

            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 17),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -17),
            nameLabel.topAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: 15),
            summaryLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            summaryLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            summaryLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 7),

            detailsStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 17),
            detailsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -17),
            detailsStack.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 20),

            copyPathButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 17),
            copyPathButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -17),
            copyPathButton.topAnchor.constraint(equalTo: detailsStack.bottomAnchor, constant: 14),
            copyPathButton.heightAnchor.constraint(equalToConstant: 30),
            copyPathButton.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16)
        ])

        showEmptyState()
    }

    private func showEmptyState() {
        previewContainer.isHidden = false
        previewImage.image = nil
        previewImage.alphaValue = 1
        stopPreviewLoading()
        emptyIcon.isHidden = false
        emptyLabel.isHidden = false
        nameLabel.isHidden = true
        summaryLabel.isHidden = true
        detailsStack.isHidden = true
        copyPathButton.isHidden = true
    }

    private func configureMultiple(_ items: [FileItem]) {
        stopPreviewLoading()
        let files = items.filter { !$0.isDirectory }
        let folders = items.count - files.count
        let totalSize = files.compactMap(\.size).reduce(0, +)
        previewImage.image = NSImage(
            systemSymbolName: "square.stack.3d.up.fill",
            accessibilityDescription: nil
        )
        previewImage.contentTintColor = FPStyle.accent
        nameLabel.stringValue = "Выбрано объектов: \(items.count)"
        summaryLabel.stringValue = "Несколько объектов"
        addDetail(title: "Файлы", value: "\(files.count)")
        addDetail(title: "Папки", value: "\(folders)")
        addDetail(
            title: "Размер файлов",
            value: ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
        )
    }

    private func configureSingle(_ item: FileItem) {
        nameLabel.stringValue = item.name
        summaryLabel.stringValue = item.kind
        representedPath = item.url.path
        copyPathButton.isHidden = false
        folderSizeValueLabel = nil
        folderSizeSpinner = nil

        if item.isDirectory {
            let sizeField = addDetail(title: "Размер", value: "Считаю…", showSpinner: true)
            folderSizeValueLabel = sizeField
            let generation = previewGeneration
            FPDirectorySizeCalculator.calculateDetailed(urls: [item.url]) { [weak self] result in
                guard let self, self.previewGeneration == generation else { return }
                self.folderSizeSpinner?.stopAnimation(nil)
                self.folderSizeSpinner?.isHidden = true
                if case .success(let summary) = result {
                    let sizeText = ByteCountFormatter.string(fromByteCount: summary.bytes, countStyle: .file)
                    let totalObjects = summary.fileCount + summary.folderCount
                    self.folderSizeValueLabel?.stringValue = "\(sizeText) · \(totalObjects) объ."
                } else {
                    self.folderSizeValueLabel?.stringValue = "Папка"
                }
            }
        } else {
            addDetail(
                title: "Размер",
                value: ByteCountFormatter.string(fromByteCount: item.size ?? 0, countStyle: .file)
            )
        }
        addDetail(title: "Создан", value: formatted(item.created))
        addDetail(title: "Изменён", value: formatted(item.modified))
        if let dimensions = imageDimensions(item.url) {
            addDetail(
                title: "Разрешение",
                value: "\(dimensions.width) × \(dimensions.height) px"
            )
        }
        addDetail(title: "Путь", value: item.url.deletingLastPathComponent().path)

        if item.isDirectory {
            stopPreviewLoading()
            let folderColor = CustomFolderIconStore.shared.image(for: item.url)
            if let folderColor {
                previewImage.image = folderColor
            } else if FPStyle.isObsidianAurora {
                let savedColors = UserDefaults.standard.dictionary(forKey: "FolderColors") as? [String: String] ?? [:]
                let savedKey = savedColors[item.url.standardizedFileURL.path]
                let tagColor = savedKey.flatMap { FPTag.color(for: $0) }
                    ?? (item.finderTags ?? []).compactMap { FPTag.color(for: $0.title.lowercased()) }.first
                previewImage.image = FPFolderIconRenderer.icon(color: tagColor ?? FPStyle.defaultFolder, size: 128)
            } else {
                previewImage.image = NSWorkspace.shared.icon(forFile: item.url.path)
            }
            previewImage.alphaValue = 1
            return
        }

        previewImage.contentTintColor = nil
        let cacheKey = item.url.standardizedFileURL.path as NSString
        if let cached = previewCache.object(forKey: cacheKey) {
            stopPreviewLoading()
            previewImage.image = cached
            previewImage.alphaValue = 1
            return
        }

        // Keep the final preview slot completely stable while Quick Look works.
        // A generic file icon flashing here looked like broken content and its
        // intrinsic size could push the split-view divider.
        previewImage.image = nil
        previewImage.alphaValue = 0
        previewSpinner.startAnimation(nil)
        let generation = previewGeneration
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: NSSize(width: 520, height: 360),
            scale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .all
        )
        thumbnailRequest = request
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            [weak self] representation, _ in
            DispatchQueue.main.async {
                guard let self,
                      self.previewGeneration == generation,
                      self.thumbnailRequest === request else { return }
                self.thumbnailRequest = nil
                self.previewSpinner.stopAnimation(nil)
                let image = representation?.nsImage
                    ?? NSWorkspace.shared.icon(forFile: item.url.path)
                self.previewCache.setObject(image, forKey: cacheKey)
                self.previewImage.image = image
                self.previewImage.alphaValue = 0
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                        ? 0
                        : 0.14
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    self.previewImage.animator().alphaValue = 1
                }
            }
        }
    }

    @discardableResult
    private func addDetail(title: String, value: String, showSpinner: Bool = false) -> NSTextField {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = FPStyle.bodyFont(ofSize: 11.2, weight: .medium)
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleLabel.widthAnchor.constraint(equalToConstant: 78).isActive = true

        let valueLabel = NSTextField(wrappingLabelWithString: value)
        // Цифры моноширинные: размеры и даты выстраиваются в колонку и не
        // прыгают при переключении файлов.
        valueLabel.font = FPStyle.isObsidianAurora
            ? FPStyle.monoMetaFont(ofSize: 11.2, weight: .regular)
            : .monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
        valueLabel.maximumNumberOfLines = title == "Путь" ? 2 : 1
        valueLabel.lineBreakMode = .byTruncatingMiddle
        valueLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var rowViews: [NSView] = [titleLabel]
        if showSpinner {
            let spin = NSProgressIndicator()
            spin.style = .spinning
            spin.controlSize = .small
            spin.isDisplayedWhenStopped = false
            spin.translatesAutoresizingMaskIntoConstraints = false
            spin.widthAnchor.constraint(equalToConstant: 12).isActive = true
            spin.heightAnchor.constraint(equalToConstant: 12).isActive = true
            spin.startAnimation(nil)
            folderSizeSpinner = spin
            rowViews.append(spin)
        }
        rowViews.append(valueLabel)

        let row = NSStackView(views: rowViews)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 7
        detailsStack.addArrangedSubview(row)
        titleLabel.textColor = FPStyle.dimText
        valueLabel.textColor = FPStyle.text
        return valueLabel
    }

    private func clearDetails() {
        for view in detailsStack.arrangedSubviews {
            detailsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private func formatted(_ date: Date?) -> String {
        guard let date else { return "—" }
        return Self.dateFormatter.string(from: date)
    }

    private func stopPreviewLoading() {
        previewSpinner.stopAnimation(nil)
        previewImage.alphaValue = 1
    }

    private func imageDimensions(_ url: URL) -> (width: Int, height: Int)? {
        FPMediaInfoCache.imageDimensions(at: url)
    }

    @objc private func closePressed(_ sender: Any?) {
        onClose?()
    }

    @objc private func copyPath(_ sender: Any?) {
        guard let representedPath else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(representedPath, forType: .string)
    }

    @objc private func themeChanged(_ notification: Notification) {
        applyTheme()
    }

    private func applyTheme() {
        let aurora = FPStyle.isObsidianAurora
        let tint = FPStyle.text.blended(withFraction: 0.22, of: FPStyle.accent) ?? FPStyle.text
        heading.stringValue = aurora ? "Предпросмотр" : "ПРЕДПРОСМОТР"
        heading.font = FPStyle.headingFont(ofSize: aurora ? 14 : 13.5, weight: .semibold)
        emptyLabel.stringValue = aurora ? "Выберите файл или папку" : "ВЫБЕРИТЕ ФАЙЛ ИЛИ ПАПКУ"

        layer?.backgroundColor = FPStyle.sidebar
            .withAlphaComponent(min(0.66, FPStyle.sidebar.alphaComponent + 0.18)).cgColor
        layer?.borderColor = (aurora ? tint.withAlphaComponent(0.09) : FPStyle.stroke).cgColor
        layer?.borderWidth = 0.5
        heading.textColor = FPStyle.text
        closeButton.contentTintColor = FPStyle.dimText
        closeButton.layer?.backgroundColor = (aurora ? tint.withAlphaComponent(0.06) : FPStyle.control).cgColor
        previewContainer.layer?.cornerRadius = FPStyle.isCyberEditorial ? 6 : 12
        previewContainer.layer?.backgroundColor = FPStyle.pane
            .withAlphaComponent(min(1, FPStyle.pane.alphaComponent + 0.10)).cgColor
        previewContainer.layer?.borderColor = (aurora ? tint.withAlphaComponent(0.09) : FPStyle.stroke).cgColor
        nameLabel.textColor = FPStyle.text
        nameLabel.font = FPStyle.headingFont(ofSize: 15, weight: .semibold)
        summaryLabel.textColor = aurora ? FPStyle.accent : FPStyle.orange
        emptyIcon.contentTintColor = FPStyle.dimText.withAlphaComponent(0.65)
        emptyLabel.textColor = FPStyle.dimText.withAlphaComponent(0.75)
        copyPathButton.font = FPStyle.bodyFont(ofSize: 12, weight: .medium)
        copyPathButton.contentTintColor = FPStyle.accent
        copyPathButton.layer?.backgroundColor = (aurora ? FPStyle.accent.withAlphaComponent(0.14) : FPStyle.control).cgColor
        copyPathButton.layer?.borderColor = (aurora ? FPStyle.accent.withAlphaComponent(0.36) : FPStyle.stroke.withAlphaComponent(0.8)).cgColor
        copyPathButton.layer?.borderWidth = aurora ? 0.75 : 1
        detailsStack.arrangedSubviews.forEach { row in
            guard let fields = (row as? NSStackView)?.arrangedSubviews
                .compactMap({ $0 as? NSTextField }),
                  fields.count == 2 else { return }
            fields[0].textColor = FPStyle.dimText
            fields[1].textColor = FPStyle.text
        }
    }
}
