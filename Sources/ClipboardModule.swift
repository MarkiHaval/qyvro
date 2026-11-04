import AppKit
import Carbon.HIToolbox
import CryptoKit

private enum QyvroClipKind: String, Codable {
    case text
    case image
    case screenshot
}

private struct QyvroClipRepresentation: Codable {
    let type: String
    let file: String
}

private struct QyvroClipRecord: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let kind: QyvroClipKind
    let title: String
    let detail: String
    let textLength: Int?
    let previewFile: String?
    let fingerprint: String
    let representations: [QyvroClipRepresentation]
}

private enum QyvroClipboardSaveError: LocalizedError {
    case notAnImage
    case missingPayload
    case downloadsUnavailable

    var errorDescription: String? {
        switch self {
        case .notAnImage:
            return "Этот элемент буфера не является изображением."
        case .missingPayload:
            return "Исходные данные изображения больше недоступны."
        case .downloadsUnavailable:
            return "Не удалось найти папку «Загрузки»."
        }
    }
}

private final class QyvroClipboardStore {
    static let changed = Notification.Name("QyvroClipboardStoreChanged")

    private(set) var records: [QyvroClipRecord] = []
    private let root: URL
    private let payloads: URL
    private let metadata: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let fileManager = FileManager.default

    init() {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        // Keep the standalone app's storage location so integrating Clipboard
        // into Qyvro does not discard the user's existing history.
        root = base.appendingPathComponent("QyvroClipboard", isDirectory: true)
        payloads = root.appendingPathComponent("Payloads", isDirectory: true)
        metadata = root.appendingPathComponent("history-v1.json")
        try? fileManager.createDirectory(at: payloads, withIntermediateDirectories: true)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        if let data = try? Data(contentsOf: metadata),
           let saved = try? decoder.decode([QyvroClipRecord].self, from: data) {
            records = saved.filter { record in
                record.representations.allSatisfy {
                    fileManager.fileExists(atPath: payloads.appendingPathComponent($0.file).path)
                }
            }
        }
    }

    func addPasteboard(_ pasteboard: NSPasteboard, kindOverride: QyvroClipKind? = nil) {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return }
        var representations: [(NSPasteboard.PasteboardType, Data)] = []
        for item in items {
            for type in item.types where shouldKeep(type) {
                guard let data = item.data(forType: type),
                      !data.isEmpty,
                      data.count <= 250 * 1024 * 1024 else { continue }
                representations.append((type, data))
            }
        }
        add(representations: representations, kindOverride: kindOverride)
    }

    func addScreenshot(data: Data) {
        add(representations: [(.png, data)], kindOverride: .screenshot)
    }

    func copy(_ record: QyvroClipRecord) {
        let item = NSPasteboardItem()
        for representation in record.representations {
            let fileURL = payloads.appendingPathComponent(representation.file)
            if let data = try? Data(contentsOf: fileURL) {
                item.setData(data, forType: NSPasteboard.PasteboardType(representation.type))
            }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

    func preview(for record: QyvroClipRecord) -> NSImage? {
        guard let file = record.previewFile else { return nil }
        return NSImage(contentsOf: payloads.appendingPathComponent(file))
    }

    func saveImageToDownloads(_ record: QyvroClipRecord) throws -> URL {
        guard record.kind == .image || record.kind == .screenshot else {
            throw QyvroClipboardSaveError.notAnImage
        }
        guard let downloads = fileManager.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first else {
            throw QyvroClipboardSaveError.downloadsUnavailable
        }

        let preferredTypes = [
            NSPasteboard.PasteboardType.png.rawValue,
            "public.jpeg",
            "public.heic",
            NSPasteboard.PasteboardType.tiff.rawValue
        ]
        let representation = preferredTypes.compactMap { preferred in
            record.representations.first { $0.type == preferred }
        }.first
        let sourceURL = representation.map {
            payloads.appendingPathComponent($0.file)
        } ?? record.previewFile.map {
            payloads.appendingPathComponent($0)
        }
        guard let sourceURL, let data = try? Data(contentsOf: sourceURL) else {
            throw QyvroClipboardSaveError.missingPayload
        }

        let fileExtension: String
        switch representation?.type {
        case "public.jpeg":
            fileExtension = "jpg"
        case "public.heic":
            fileExtension = "heic"
        case NSPasteboard.PasteboardType.tiff.rawValue:
            fileExtension = "tiff"
        default:
            fileExtension = "png"
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let prefix = record.kind == .screenshot ? "Qyvro Снимок" : "Qyvro Изображение"
        let baseName = "\(prefix) \(formatter.string(from: record.createdAt))"
        var destination = downloads.appendingPathComponent(
            "\(baseName).\(fileExtension)"
        )
        var suffix = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = downloads.appendingPathComponent(
                "\(baseName) \(suffix).\(fileExtension)"
            )
            suffix += 1
        }
        try data.write(to: destination, options: .atomic)
        return destination
    }

    func delete(_ record: QyvroClipRecord) {
        removeFiles(for: record)
        records.removeAll { $0.id == record.id }
        saveAndNotify()
    }

    func clear() {
        records.forEach(removeFiles)
        records.removeAll()
        saveAndNotify()
        NSPasteboard.general.clearContents()
    }

    private func add(
        representations: [(NSPasteboard.PasteboardType, Data)],
        kindOverride: QyvroClipKind?
    ) {
        guard !representations.isEmpty else { return }
        let preferred = representations.first(where: { $0.0 == .png })
            ?? representations.first(where: { $0.0 == .tiff })
            ?? representations.first(where: { $0.0 == .string })
            ?? representations[0]
        let fingerprint = SHA256.hash(data: preferred.1)
            .map { String(format: "%02x", $0) }
            .joined()
        if records.first?.fingerprint == fingerprint { return }

        let id = UUID()
        var stored: [QyvroClipRepresentation] = []
        for (index, representation) in representations.enumerated() {
            let fileName = "\(id.uuidString)-\(index).bin"
            do {
                try representation.1.write(
                    to: payloads.appendingPathComponent(fileName),
                    options: .atomic
                )
                stored.append(
                    QyvroClipRepresentation(type: representation.0.rawValue, file: fileName)
                )
            } catch {
                continue
            }
        }
        guard !stored.isEmpty else { return }

        let stringData = representations.first(where: { $0.0 == .string })?.1
        let string = stringData
            .flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let imageRepresentation = representations.first {
            $0.0 == .png || $0.0 == .tiff || $0.0.rawValue == "public.jpeg"
        }
        let image = imageRepresentation.flatMap { NSImage(data: $0.1) }
        let kind = kindOverride ?? (image == nil ? QyvroClipKind.text : .image)

        let title: String
        let detail: String
        if let string, !string.isEmpty, kind == .text {
            title = String(string.replacingOccurrences(of: "\n", with: " ").prefix(90))
            detail = "\(string.count) символов"
        } else if let image {
            let pixels = image.representations.first.map {
                "\($0.pixelsWide) × \($0.pixelsHigh) px"
            } ?? "Изображение"
            title = kind == .screenshot ? "Снимок экрана" : "Изображение"
            detail = pixels
        } else {
            title = "Данные буфера"
            detail = ByteCountFormatter.string(
                fromByteCount: Int64(preferred.1.count),
                countStyle: .file
            )
        }

        let previewFile = imageRepresentation.flatMap { representation -> String? in
            let extensionName = representation.0 == .png ? "png" : "tiff"
            let name = "\(id.uuidString)-preview.\(extensionName)"
            do {
                try representation.1.write(
                    to: payloads.appendingPathComponent(name),
                    options: .atomic
                )
                return name
            } catch {
                return nil
            }
        }

        records.insert(
            QyvroClipRecord(
                id: id,
                createdAt: Date(),
                kind: kind,
                title: title,
                detail: detail,
                textLength: string?.count,
                previewFile: previewFile,
                fingerprint: fingerprint,
                representations: stored
            ),
            at: 0
        )
        trim(to: 200)
        saveAndNotify()
    }

    private func trim(to limit: Int) {
        guard records.count > limit else { return }
        records.suffix(from: limit).forEach(removeFiles)
        records = Array(records.prefix(limit))
    }

    private func removeFiles(for record: QyvroClipRecord) {
        record.representations.forEach {
            try? fileManager.removeItem(at: payloads.appendingPathComponent($0.file))
        }
        if let file = record.previewFile {
            try? fileManager.removeItem(at: payloads.appendingPathComponent(file))
        }
    }

    private func shouldKeep(_ type: NSPasteboard.PasteboardType) -> Bool {
        let allowed: Set<String> = [
            NSPasteboard.PasteboardType.string.rawValue,
            NSPasteboard.PasteboardType.png.rawValue,
            NSPasteboard.PasteboardType.tiff.rawValue,
            NSPasteboard.PasteboardType.html.rawValue,
            NSPasteboard.PasteboardType.rtf.rawValue,
            NSPasteboard.PasteboardType.rtfd.rawValue,
            "public.jpeg",
            "public.heic",
            "public.url",
            "public.file-url"
        ]
        return allowed.contains(type.rawValue)
    }

    private func saveAndNotify() {
        if let data = try? encoder.encode(records) {
            try? data.write(to: metadata, options: .atomic)
        }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
}

private final class QyvroClipboardWatcher {
    private let store: QyvroClipboardStore
    private var timer: Timer?
    private var lastChange = NSPasteboard.general.changeCount

    init(store: QyvroClipboardStore) {
        self.store = store
    }

    func start() {
        guard timer == nil else { return }
        // Опрос идёт всегда, в том числе когда Qyvro в фоне: история буфера
        // ровно для того и нужна, чтобы ловить копирование в других
        // программах. Пропуск неактивного состояния терял всё, что человек
        // копировал в браузере или редакторе, — оставалась только последняя
        // запись, подхваченная при возврате в проводник.
        timer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChange else { return }
        lastChange = pasteboard.changeCount
        store.addPasteboard(pasteboard)
        QyvroCloudClipboardSync.shared.pasteboardChanged(pasteboard, changeCount: lastChange)
    }
}

private final class QyvroScreenshotWatcher {
    private let store: QyvroClipboardStore
    private var timer: Timer?
    private var startedAt = Date()
    private var seen = Set<String>()
    private let folder: URL
    private let scanQueue = DispatchQueue(label: "Qyvro.ScreenshotWatcher", qos: .utility)
    private var isScanning = false

    init(store: QyvroClipboardStore) {
        self.store = store
        let configured = UserDefaults.standard
            .persistentDomain(forName: "com.apple.screencapture")?["location"] as? String
        folder = configured.map {
            URL(
                fileURLWithPath: NSString(string: $0).expandingTildeInPath,
                isDirectory: true
            )
        } ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
    }

    func start() {
        guard timer == nil else { return }
        startedAt = Date().addingTimeInterval(-1)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        guard !isScanning else { return }
        isScanning = true
        scanQueue.async { [weak self] in
            guard let self else { return }
            let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: self.folder,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )) ?? []
            var screenshots: [Data] = []

            for url in urls {
                let fileExtension = url.pathExtension.lowercased()
                guard ["png", "jpg", "jpeg", "heic", "tiff"].contains(fileExtension),
                      !self.seen.contains(url.path),
                      let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true,
                      let modified = values.contentModificationDate,
                      modified >= self.startedAt else { continue }
                let lowerName = url.deletingPathExtension().lastPathComponent.lowercased()
                guard lowerName.contains("screenshot")
                    || lowerName.contains("screen shot")
                    || lowerName.contains("снимок экрана") else { continue }

                self.seen.insert(url.path)
                self.startedAt = max(self.startedAt, modified)
                let pngData: Data?
                if fileExtension == "png" {
                    pngData = try? Data(contentsOf: url)
                } else {
                    pngData = NSImage(contentsOf: url)?.qyvroClipboardPNGData
                }
                if let pngData {
                    screenshots.append(pngData)
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isScanning = false
                for pngData in screenshots {
                    self.store.addScreenshot(data: pngData)
                    let item = NSPasteboardItem()
                    item.setData(pngData, forType: .png)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([item])
                }
            }
        }
    }
}

private extension NSImage {
    var qyvroClipboardPNGData: Data? {
        guard let tiff = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

private final class QyvroClipboardGlassView: NSVisualEffectView {
    /// Тон кладётся отдельным видом поверх размытия.
    ///
    /// `NSVisualEffectView` не отдаёт под тон ни `draw(_:)`, ни цвет
    /// собственного слоя: материал перекрывает и то, и другое. Обе попытки
    /// красить его напрямую не дошли до экрана, и окно показывало голое
    /// размытие, сквозь которое просвечивали обои рабочего стола. Отдельный
    /// вид сверху — тот же приём, что и в подложке остальных окон.
    private let tintView = FPLayerView(color: .clear)

    var tint = FPStyle.pane {
        didSet { tintView.setColor(tint) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installTintView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installTintView()
    }

    private func installTintView() {
        wantsLayer = true
        tintView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tintView)
        NSLayoutConstraint.activate([
            tintView.topAnchor.constraint(equalTo: topAnchor),
            tintView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tintView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        tintView.setColor(tint)
    }
}

private final class QyvroClipboardButton: NSButton {
    init(
        title: String,
        symbol: String? = nil,
        tint: NSColor = FPStyle.text,
        symbolLeadingPadding: CGFloat = 0
    ) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        bezelStyle = .inline
        font = FPStyle.bodyFont(ofSize: 12, weight: .semibold)
        contentTintColor = tint
        wantsLayer = true
        layer?.cornerRadius = FPStyle.isCyberEditorial ? 5 : 8
        layer?.backgroundColor = FPStyle.control.cgColor
        layer?.borderColor = FPStyle.stroke.cgColor
        layer?.borderWidth = 0.5
        if let symbol {
            let source = NSImage(
                systemSymbolName: symbol,
                accessibilityDescription: title
            )
            image = symbolLeadingPadding > 0
                ? source?.qyvroImageWithLeadingPadding(symbolLeadingPadding)
                : source
            imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        }
        translatesAutoresizingMaskIntoConstraints = false
    }

    func applyTheme(tint: NSColor? = nil) {
        if let tint {
            contentTintColor = tint
        }
        layer?.backgroundColor = FPStyle.control.cgColor
        layer?.borderColor = FPStyle.stroke.cgColor
        layer?.borderWidth = FPStyle.isCyberEditorial ? 0.75 : 0.5
        layer?.cornerRadius = FPStyle.isCyberEditorial ? 5 : 8
        font = FPStyle.bodyFont(ofSize: 12, weight: .semibold)
        layer?.shadowColor = FPStyle.accent.cgColor
        layer?.shadowOpacity = FPStyle.isCyberEditorial ? 0.08 : 0
        layer?.shadowRadius = FPStyle.isCyberEditorial ? 8 : 0
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private extension NSImage {
    func qyvroImageWithLeadingPadding(_ padding: CGFloat) -> NSImage {
        let original = size
        let padded = NSImage(
            size: NSSize(width: original.width + padding, height: original.height),
            flipped: false
        ) { _ in
            self.draw(
                in: NSRect(
                    x: padding,
                    y: 0,
                    width: original.width,
                    height: original.height
                )
            )
            return true
        }
        padded.isTemplate = isTemplate
        return padded
    }
}

private final class QyvroClipRowView: NSTableCellView {
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onDelete: (() -> Void)?

    private let thumbnail = NSImageView()
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let copyButton = QyvroClipboardButton(
        title: "Скопировать",
        symbol: "doc.on.doc",
        tint: FPStyle.accent
    )
    private let saveButton = QyvroClipboardButton(
        title: "",
        symbol: "arrow.down.to.line",
        tint: FPStyle.accent
    )
    private let deleteButton = QyvroClipboardButton(
        title: "",
        symbol: "trash",
        tint: FPStyle.danger
    )
    private var saveButtonWidthConstraint: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = FPStyle.isCyberEditorial ? 6 : 12
        layer?.backgroundColor = FPStyle.controlStrong.cgColor
        layer?.borderColor = FPStyle.stroke.cgColor
        layer?.borderWidth = 1

        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = 8
        thumbnail.layer?.masksToBounds = true
        icon.contentTintColor = FPStyle.orange
        titleLabel.textColor = FPStyle.text
        titleLabel.font = FPStyle.bodyFont(ofSize: 13.5, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.textColor = FPStyle.dimText
        detailLabel.font = FPStyle.bodyFont(ofSize: 11.5)
        dateLabel.textColor = FPStyle.dimText
        dateLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        dateLabel.alignment = .right

        [thumbnail, icon, titleLabel, detailLabel, dateLabel, copyButton, saveButton, deleteButton]
            .forEach {
                $0.translatesAutoresizingMaskIntoConstraints = false
                addSubview($0)
            }
        copyButton.target = self
        copyButton.action = #selector(copyPressed)
        saveButton.target = self
        saveButton.action = #selector(savePressed)
        saveButton.toolTip = "Сохранить в Загрузки"
        deleteButton.target = self
        deleteButton.action = #selector(deletePressed)

        saveButtonWidthConstraint = saveButton.widthAnchor.constraint(equalToConstant: 32)
        NSLayoutConstraint.activate([
            thumbnail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            thumbnail.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbnail.widthAnchor.constraint(equalToConstant: 66),
            thumbnail.heightAnchor.constraint(equalToConstant: 54),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 30),
            icon.heightAnchor.constraint(equalToConstant: 30),
            titleLabel.leadingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: 14),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: dateLabel.leadingAnchor,
                constant: -8
            ),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
            dateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            dateLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            dateLabel.widthAnchor.constraint(equalToConstant: 72),
            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            deleteButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            deleteButton.widthAnchor.constraint(equalToConstant: 32),
            deleteButton.heightAnchor.constraint(equalToConstant: 28),
            saveButton.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -7),
            saveButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            saveButtonWidthConstraint,
            saveButton.heightAnchor.constraint(equalToConstant: 28),
            copyButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -7),
            copyButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            copyButton.widthAnchor.constraint(equalToConstant: 116),
            copyButton.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(record: QyvroClipRecord, image: NSImage?) {
        layer?.cornerRadius = FPStyle.isCyberEditorial ? 6 : 12
        layer?.backgroundColor = FPStyle.controlStrong.cgColor
        layer?.borderColor = FPStyle.stroke.cgColor
        icon.contentTintColor = FPStyle.orange
        titleLabel.textColor = FPStyle.text
        detailLabel.textColor = FPStyle.dimText
        dateLabel.textColor = FPStyle.dimText
        copyButton.applyTheme(tint: FPStyle.accent)
        saveButton.applyTheme(tint: FPStyle.accent)
        deleteButton.applyTheme(tint: FPStyle.danger)
        titleLabel.font = FPStyle.bodyFont(ofSize: 13.5, weight: .semibold)
        detailLabel.font = FPStyle.bodyFont(ofSize: 11.5)
        titleLabel.stringValue = record.title
        detailLabel.stringValue = record.detail
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        dateLabel.stringValue = formatter.localizedString(
            for: record.createdAt,
            relativeTo: Date()
        )
        thumbnail.image = image
        thumbnail.isHidden = image == nil
        let canSaveImage = record.kind == .image || record.kind == .screenshot
        saveButton.isHidden = !canSaveImage
        saveButtonWidthConstraint.constant = canSaveImage ? 32 : 0
        icon.isHidden = image != nil
        icon.image = NSImage(
            systemSymbolName: record.kind == .text ? "text.alignleft" : "photo",
            accessibilityDescription: nil
        )
    }

    @objc private func copyPressed() {
        onCopy?()
    }

    @objc private func savePressed() {
        onSave?()
    }

    @objc private func deletePressed() {
        onDelete?()
    }
}

private enum QyvroClipboardFilter: Int {
    case all
    case links
    case prompts
    case shortText
    case images
}

private final class QyvroClipboardViewController:
    NSViewController,
    NSTableViewDataSource,
    NSTableViewDelegate
{
    private let store: QyvroClipboardStore
    private let table = NSTableView()
    private let countLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(
        wrappingLabelWithString:
            "Пока пусто\nСкопируй текст или изображение — оно появится здесь"
    )
    private var filter: QyvroClipboardFilter = .all
    private var shown: [QyvroClipRecord] = []
    private var filterButtons: [QyvroClipboardButton] = []
    private weak var rootGlass: QyvroClipboardGlassView?
    private weak var sidebarGlass: QyvroClipboardGlassView?
    private weak var contentGlass: QyvroClipboardGlassView?
    private weak var editorialBackdrop: FPEditorialBackdropView?
    private weak var brandLabel: NSTextField?
    private weak var headingLabel: NSTextField?
    private weak var titleLabel: NSTextField?
    private weak var clearButton: QyvroClipboardButton?
    private weak var hintLabel: NSTextField?

    init(store: QyvroClipboardStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = QyvroClipboardGlassView()
        root.material = .underWindowBackground
        root.blendingMode = .behindWindow
        root.state = .active
        // Тот же тон, что у остальных вспомогательных окон: они должны
        // выглядеть частями одной программы, а не тремя разными.
        root.tint = FPStyle.window.withAlphaComponent(0.94)
        rootGlass = root
        view = root

        let editorial = FPEditorialBackdropView()
        editorialBackdrop = editorial
        root.addSubview(editorial)
        let sidebar = QyvroClipboardGlassView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .withinWindow
        sidebar.state = .active
        // Плотность высокая намеренно: сквозь редкую подложку просвечивают
        // обои рабочего стола и окрашивают весь буфер в их цвет.
        sidebar.tint = FPStyle.sidebar.withAlphaComponent(0.94)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebarGlass = sidebar
        let content = QyvroClipboardGlassView()
        content.material = .hudWindow
        content.blendingMode = .withinWindow
        content.state = .active
        content.tint = FPStyle.pane.withAlphaComponent(0.92)
        content.translatesAutoresizingMaskIntoConstraints = false
        contentGlass = content
        root.addSubview(sidebar)
        root.addSubview(content)

        let brand = NSTextField(labelWithString: "QYVRO")
        brand.font = FPStyle.headingFont(ofSize: 11, weight: .bold)
        brand.textColor = FPStyle.orange
        brand.translatesAutoresizingMaskIntoConstraints = false
        brandLabel = brand
        let heading = NSTextField(labelWithString: "БУФЕР")
        // Заголовки набраны как рубрики проводника: капс с разрядкой вместо
        // крупного жирного начертания — так окно выглядит частью программы.
        heading.font = FPStyle.headingFont(ofSize: 17, weight: .semibold)
        heading.textColor = FPStyle.text
        heading.translatesAutoresizingMaskIntoConstraints = false
        headingLabel = heading
        sidebar.addSubview(brand)
        sidebar.addSubview(heading)

        let filters: [(String, String, QyvroClipboardFilter)] = [
            ("Всё", "clock.arrow.circlepath", .all),
            ("Ссылки", "link", .links),
            ("Длинный текст", "text.quote", .prompts),
            ("Короткий текст", "text.alignleft", .shortText),
            ("Изображения", "photo", .images)
        ]
        var previous: NSView = heading
        for (title, symbol, value) in filters {
            let button = QyvroClipboardButton(
                title: title,
                symbol: symbol,
                tint: value == .all ? FPStyle.accent : FPStyle.text,
                symbolLeadingPadding: 9
            )
            button.tag = value.rawValue
            button.target = self
            button.action = #selector(filterPressed(_:))
            button.alignment = .left
            sidebar.addSubview(button)
            filterButtons.append(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 21),
                button.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -17),
                button.topAnchor.constraint(
                    equalTo: previous.bottomAnchor,
                    constant: previous === heading ? 27 : 6
                ),
                button.heightAnchor.constraint(equalToConstant: 36)
            ])
            previous = button
        }

        let clear = QyvroClipboardButton(
            title: "Очистить всё",
            symbol: "trash",
            tint: FPStyle.danger,
            symbolLeadingPadding: 9
        )
        clear.target = self
        clear.action = #selector(clearAll)
        clearButton = clear
        sidebar.addSubview(clear)
        let hint = NSTextField(
            wrappingLabelWithString: "\(QyvroClipboardShortcut.displayName) — открыть панель\n⌘V — обычная вставка"
        )
        hint.textColor = FPStyle.dimText
        hint.font = FPStyle.headingFont(ofSize: 10, weight: .semibold)
        hint.translatesAutoresizingMaskIntoConstraints = false
        hintLabel = hint
        sidebar.addSubview(hint)

        let title = NSTextField(labelWithString: "ИСТОРИЯ БУФЕРА")
        title.font = FPStyle.headingFont(ofSize: 15, weight: .semibold)
        title.textColor = FPStyle.text
        title.translatesAutoresizingMaskIntoConstraints = false
        titleLabel = title
        countLabel.textColor = FPStyle.dimText
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(title)
        content.addSubview(countLabel)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clip"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 9)
        table.rowHeight = 80
        table.delegate = self
        table.dataSource = self
        scroll.documentView = table
        content.addSubview(scroll)

        emptyLabel.alignment = .center
        emptyLabel.textColor = FPStyle.dimText
        emptyLabel.font = FPStyle.headingFont(ofSize: 12.5, weight: .semibold)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            editorial.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            editorial.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            editorial.topAnchor.constraint(equalTo: root.topAnchor),
            editorial.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 208),
            content.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            brand.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 21),
            brand.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 40),
            heading.leadingAnchor.constraint(equalTo: brand.leadingAnchor),
            heading.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 3),
            clear.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 21),
            clear.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -17),
            clear.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -16),
            clear.heightAnchor.constraint(equalToConstant: 36),
            hint.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 21),
            hint.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -16),
            hint.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -18),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 39),
            countLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),
            countLabel.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 23),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 18),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -15),
            emptyLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reload),
            name: QyvroClipboardStore.changed,
            object: store
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeChanged(_:)),
            name: .fpThemeDidChange,
            object: nil
        )
        applyTheme()
        reload()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func showAll() {
        filter = .all
        reload()
    }

    @objc private func reload() {
        shown = store.records.filter { record in
            switch filter {
            case .all:
                return true
            case .links:
                return record.kind == .text && isLink(record)
            case .prompts:
                return record.kind == .text && !isLink(record) && textLength(record) >= 220
            case .shortText:
                return record.kind == .text && !isLink(record) && textLength(record) < 220
            case .images:
                return record.kind == .image || record.kind == .screenshot
            }
        }
        countLabel.stringValue = "\(shown.count) элементов"
        emptyLabel.isHidden = !shown.isEmpty
        table.reloadData()
        filterButtons.forEach { button in
            let active = button.tag == filter.rawValue
            button.applyTheme(tint: active ? FPStyle.accent : FPStyle.text)
            button.layer?.backgroundColor = (
                active ? FPStyle.rowSelection : FPStyle.control
            ).cgColor
        }
    }

    @objc private func themeChanged(_ notification: Notification) {
        applyTheme()
        reload()
    }

    private func applyTheme() {
        // Плотность задаётся здесь одним местом: раньше те же значения
        // дублировались при создании окна и расходились между собой.
        rootGlass?.tint = FPStyle.window.withAlphaComponent(0.94)
        sidebarGlass?.tint = FPStyle.sidebar.withAlphaComponent(0.94)
        contentGlass?.tint = FPStyle.pane.withAlphaComponent(0.92)
        editorialBackdrop?.refreshTheme()
        brandLabel?.textColor = FPStyle.isCyberEditorial ? FPStyle.accent : FPStyle.orange
        headingLabel?.textColor = FPStyle.text
        headingLabel?.font = FPStyle.headingFont(ofSize: 23, weight: .bold)
        titleLabel?.textColor = FPStyle.text
        titleLabel?.font = FPStyle.headingFont(ofSize: 20, weight: .bold)
        brandLabel?.font = FPStyle.headingFont(ofSize: 11, weight: .bold)
        countLabel.textColor = FPStyle.dimText
        emptyLabel.textColor = FPStyle.dimText
        hintLabel?.textColor = FPStyle.dimText
        clearButton?.applyTheme(tint: FPStyle.danger)
        view.needsDisplay = true
    }

    private func textLength(_ record: QyvroClipRecord) -> Int {
        if let length = record.textLength { return length }
        let digits = record.detail.prefix { $0.isNumber }
        return Int(digits) ?? record.title.count
    }

    private func isLink(_ record: QyvroClipRecord) -> Bool {
        let value = record.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard value.hasPrefix("http://")
            || value.hasPrefix("https://")
            || value.hasPrefix("www.") else { return false }
        let candidate = value.hasPrefix("www.") ? "https://\(value)" : value
        return URL(string: candidate)?.host != nil
    }

    private func saveImage(_ record: QyvroClipRecord) {
        do {
            let url = try store.saveImageToDownloads(record)
            let previousValue = countLabel.stringValue
            countLabel.stringValue = "Сохранено: \(url.lastPathComponent)"
            NSSound(named: "Glass")?.play()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
                guard let self, self.countLabel.stringValue.hasPrefix("Сохранено:") else {
                    return
                }
                self.countLabel.stringValue = previousValue
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Не удалось сохранить изображение"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @objc private func filterPressed(_ sender: NSButton) {
        filter = QyvroClipboardFilter(rawValue: sender.tag) ?? .all
        reload()
    }

    @objc private func clearAll() {
        let alert = NSAlert()
        alert.messageText = "Очистить всю историю?"
        alert.informativeText =
            "Будут удалены сохранённые тексты и изображения, а также текущий системный буфер."
        alert.addButton(withTitle: "Очистить")
        alert.addButton(withTitle: "Отмена")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            store.clear()
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        shown.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        80
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard shown.indices.contains(row) else { return nil }
        let record = shown[row]
        let cell = QyvroClipRowView()
        cell.configure(record: record, image: store.preview(for: record))
        cell.onCopy = { [weak self] in
            self?.store.copy(record)
        }
        cell.onSave = { [weak self] in
            self?.saveImage(record)
        }
        cell.onDelete = { [weak self] in
            self?.store.delete(record)
        }
        return cell
    }
}

private final class QyvroClipboardPanel: NSPanel {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.keyCode == UInt16(kVK_Escape) {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        performClose(nil)
    }
}

final class QyvroClipboardModule: NSObject, NSWindowDelegate {
    static let shared = QyvroClipboardModule()

    private let store = QyvroClipboardStore()
    private lazy var clipboardWatcher = QyvroClipboardWatcher(store: store)
    private lazy var screenshotWatcher = QyvroScreenshotWatcher(store: store)
    private var panel: QyvroClipboardPanel?
    private var viewController: QyvroClipboardViewController?
    private var started = false
    private var transitionGeneration = 0

    private override init() {
        super.init()
    }

    func start() {
        guard !started else { return }
        started = true
        clipboardWatcher.start()
        screenshotWatcher.start()
        QyvroCloudClipboardSync.shared.start()
    }

    func show(activatePanel: Bool = true) {
        start()
        buildPanelIfNeeded()
        guard let panel, let viewController else { return }
        transitionGeneration += 1
        let generation = transitionGeneration
        viewController.showAll()
        if panel.isVisible {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            if activatePanel {
                panel.makeKey()
            }
            return
        }
        positionPanel(panel)
        FPWindowPresentationAnimator.show(panel) {
            panel.orderFrontRegardless()
            if activatePanel {
                panel.makeKey()
            }
        } completion: { [weak self, weak panel] in
            guard let self, let panel, self.transitionGeneration == generation else { return }
            panel.alphaValue = 1
        }
    }

    func toggle(activatePanel: Bool = true) {
        buildPanelIfNeeded()
        guard let panel else { return }
        let visibleOnCurrentSpace = panel.isVisible && panel.occlusionState.contains(.visible)
        if visibleOnCurrentSpace {
            hide()
        } else {
            if panel.isVisible {
                panel.orderOut(nil)
            }
            show(activatePanel: activatePanel)
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        transitionGeneration += 1
        let generation = transitionGeneration
        FPWindowPresentationAnimator.hide(panel) { [weak self, weak panel] in
            guard let self, let panel, self.transitionGeneration == generation else { return }
            panel.orderOut(nil)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    private func buildPanelIfNeeded() {
        guard panel == nil else { return }
        let clipboardPanel = QyvroClipboardPanel(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [
                .titled,
                .fullSizeContentView,
                .closable,
                .resizable,
                .nonactivatingPanel
            ],
            backing: .buffered,
            defer: false
        )
        let controller = QyvroClipboardViewController(store: store)
        clipboardPanel.title = "Буфер Qyvro"
        clipboardPanel.titlebarAppearsTransparent = true
        clipboardPanel.titleVisibility = .hidden
        clipboardPanel.isMovableByWindowBackground = true
        clipboardPanel.backgroundColor = .clear
        clipboardPanel.isOpaque = false
        clipboardPanel.hasShadow = true
        clipboardPanel.level = .floating
        clipboardPanel.hidesOnDeactivate = false
        clipboardPanel.becomesKeyOnlyIfNeeded = false
        clipboardPanel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        clipboardPanel.minSize = NSSize(width: 740, height: 500)
        clipboardPanel.contentViewController = controller
        clipboardPanel.delegate = self
        clipboardPanel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        clipboardPanel.standardWindowButton(.zoomButton)?.isHidden = true
        panel = clipboardPanel
        viewController = controller
    }

    private func positionPanel(_ panel: NSWindow) {
        let preferredScreen = NSApp.keyWindow?.screen
            ?? NSApp.mainWindow?.screen
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen = preferredScreen else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2 + 25
            )
        )
    }

}
