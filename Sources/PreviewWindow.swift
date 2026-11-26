import AVFoundation
import Cocoa
import ImageIO
import Quartz
import UniformTypeIdentifiers

/// Просмотрщик Qyvro вместо системной панели Quick Look.
///
/// Системная `QLPreviewPanel` не пускает внутрь свои элементы: нельзя
/// нарисовать значок отметки поверх кадра и нельзя показать два-три варианта
/// рядом. Растровые картинки декодируются напрямую через `CGImageSource` с
/// фоновой предзагрузкой соседей (открытие и листание за миллисекунды вместо
/// секунд на `QLPreviewView`), видео и аудио идут через `AVPlayerLayer`, а
/// документы (PDF, текст, PSD и т. д.) по-прежнему показывает `QLPreviewView`.

/// Потокобезопасный кэш декодированных картинок для мгновенного просмотрщика.
final class QyvroPreviewImageCache {
    static let shared = QyvroPreviewImageCache()

    private let cache = NSCache<NSString, NSImage>()
    private let lock = NSLock()
    private var inFlight: [String: [(NSImage?) -> Void]] = [:]
    private let decodeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Qyvro.PreviewImageDecode"
        queue.maxConcurrentOperationCount = 3
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init() {
        cache.countLimit = 18
        cache.totalCostLimit = 180 * 1024 * 1024
    }

    static func isDirectImage(_ url: URL) -> Bool {
        FPMediaInfoCache.imageExtensions.contains(url.pathExtension.lowercased())
    }

    static func targetPixelSize(for screen: NSScreen?) -> Int {
        let activeScreen = screen ?? NSScreen.main
        let maxPoints = max(activeScreen?.frame.width ?? 1600, activeScreen?.frame.height ?? 1000)
        let scale = max(activeScreen?.backingScaleFactor ?? 2.0, 1.0)
        let raw = Int((maxPoints * scale).rounded())
        return min(max(raw, 2048), 4096)
    }

    func cachedImage(for url: URL, maxPixelSize: Int) -> NSImage? {
        let key = cacheKey(for: url, maxPixelSize: maxPixelSize)
        return cache.object(forKey: key as NSString)
    }

    func load(url: URL, maxPixelSize: Int, completion: @escaping (NSImage?) -> Void) {
        let key = cacheKey(for: url, maxPixelSize: maxPixelSize)
        if let existing = cache.object(forKey: key as NSString) {
            completion(existing)
            return
        }

        lock.lock()
        if inFlight[key] != nil {
            inFlight[key]?.append(completion)
            lock.unlock()
            return
        }
        inFlight[key] = [completion]
        lock.unlock()

        decodeQueue.addOperation { [weak self] in
            let image = autoreleasepool { Self.decodeImage(url: url, maxPixelSize: maxPixelSize) }
            guard let self else { return }
            if let image {
                let cost = max(1, Int(image.size.width * image.size.height * 4))
                self.cache.setObject(image, forKey: key as NSString, cost: cost)
            }
            self.lock.lock()
            let callbacks = self.inFlight.removeValue(forKey: key) ?? []
            self.lock.unlock()
            DispatchQueue.main.async {
                for callback in callbacks {
                    callback(image)
                }
            }
        }
    }

    func prefetch(urls: [URL], maxPixelSize: Int) {
        for url in urls where Self.isDirectImage(url) {
            let key = cacheKey(for: url, maxPixelSize: maxPixelSize)
            if cache.object(forKey: key as NSString) != nil { continue }
            lock.lock()
            let alreadyRunning = inFlight[key] != nil
            if !alreadyRunning { inFlight[key] = [] }
            lock.unlock()
            if alreadyRunning { continue }

            decodeQueue.addOperation { [weak self] in
                let image = autoreleasepool { Self.decodeImage(url: url, maxPixelSize: maxPixelSize) }
                guard let self else { return }
                if let image {
                    let cost = max(1, Int(image.size.width * image.size.height * 4))
                    self.cache.setObject(image, forKey: key as NSString, cost: cost)
                }
                self.lock.lock()
                let callbacks = self.inFlight.removeValue(forKey: key) ?? []
                self.lock.unlock()
                guard !callbacks.isEmpty else { return }
                DispatchQueue.main.async {
                    for callback in callbacks {
                        callback(image)
                    }
                }
            }
        }
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    /// Декодирует растровое изображение сразу в нужном экранном масштабе.
    ///
    /// `kCGImageSourceShouldCacheImmediately` переносит распаковку пикселей в
    /// фоновый поток, чтобы главный поток не замирал при показе кадра.
    static func decodeImage(url: URL, maxPixelSize: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        if url.pathExtension.lowercased() == "gif", CGImageSourceGetCount(source) > 1 {
            return NSImage(contentsOf: url)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(256, maxPixelSize),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private func cacheKey(for url: URL, maxPixelSize: Int) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let stamp = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = values?.fileSize ?? 0
        return "\(url.standardizedFileURL.path)|\(size)|\(stamp)|\(maxPixelSize)"
    }
}

/// Круглая дымчатая капсула вокруг значка отметки без двойного срабатывания клика.
private final class FPFlagPillView: FPLayerView {
    var onClick: (() -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

/// Одна панель просмотра: кадр плюс наложенная поверх подпись и отметка.
final class FPPreviewPane: NSView {
    private let previewContainer = NSView()
    private var previewView: QLPreviewView?
    private var imageView: NSImageView?
    private var imageLoadGeneration: Int = 0
    /// Видео и аудио показываются своим плеером, а не через Quick Look.
    ///
    /// У Quick Look внутри чужого окна панель воспроизведения пряталась по
    /// таймауту и не возвращалась при наведении: он не получал событий о
    /// движении мыши, а повлиять на это снаружи нельзя. AVPlayerView эту
    /// проблему решал, но заводил свою: на любом controlsStyle подложка под
    /// его элементами управления гасла при наведении мышью на кадр, и
    /// публичного способа это выключить не нашлось. Голый AVPlayerLayer
    /// (см. FPPlayerLayerView) не приносит с собой вообще никакого чужого
    /// UI — кнопки и прогресс рисуем сами, см. FPMediaTransportBar.
    private var playerLayerView: FPPlayerLayerView?
    private var transportBar: FPMediaTransportBar?
    private static let audioExtensions: Set<String> = [
        "mp3", "wav", "aiff", "aif", "m4a", "flac", "aac"
    ]
    private static let cacheLimit = 4
    private var cache: [(url: URL, view: QLPreviewView)] = []
    private var previousURL: URL?
    private var nameText = ""
    private var detailText = ""
    private let flagPill = FPFlagPillView(color: .clear, cornerRadius: 14)
    private let flagBadge = FPSelectedFlagBadge()
    private let paneBadge = FPLayerView(color: .clear, cornerRadius: 10)
    private let paneBadgeIndexLabel = NSTextField(labelWithString: "")
    private let paneBadgeLabel = NSTextField(labelWithString: "")
    private let focusRing = FPLayerView(color: .clear, cornerRadius: 12)
    private var paneOrderNumber = 1
    private var flagTrackingArea: NSTrackingArea?
    private var isFlagHovered = false

    private(set) var url: URL?
    var onToggleFlag: ((URL) -> Void)?
    var onActivate: ((FPPreviewPane) -> Void)?
    /// Верхняя панель окна обновляет надпись, когда кадр сменился.
    var onCaptionChanged: (() -> Void)?
    var onGrabFrameRequested: (() -> Void)?

    var isFocused = false {
        didSet {
            updateFocusRing()
            refreshPaneBadge()
        }
    }

    var isMultiPane = false {
        didSet {
            applyTheme()
            refreshPaneBadge()
        }
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
        previewContainer.layer?.cornerRadius = FPStyle.isCyberEditorial ? 4 : 11
        previewContainer.layer?.masksToBounds = true

        flagPill.translatesAutoresizingMaskIntoConstraints = false
        flagPill.layer?.borderWidth = 0.75
        flagPill.onClick = { [weak self] in
            guard let self, let url = self.url else { return }
            self.onToggleFlag?(url)
        }

        flagBadge.translatesAutoresizingMaskIntoConstraints = false
        flagBadge.onToggle = { [weak self] in
            guard let self, let url = self.url else { return }
            self.onToggleFlag?(url)
        }

        paneBadge.translatesAutoresizingMaskIntoConstraints = false
        paneBadge.layer?.borderWidth = 0.6
        paneBadge.isHidden = true
        paneBadgeIndexLabel.translatesAutoresizingMaskIntoConstraints = false
        paneBadgeIndexLabel.font = FPStyle.monoMetaFont(ofSize: 10, weight: .bold)
        paneBadgeIndexLabel.setContentHuggingPriority(.required, for: .horizontal)
        paneBadgeIndexLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        paneBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        paneBadgeLabel.lineBreakMode = .byTruncatingMiddle
        paneBadgeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        paneBadge.addSubview(paneBadgeIndexLabel)
        paneBadge.addSubview(paneBadgeLabel)

        addSubview(focusRing)
        addSubview(previewContainer)
        addSubview(paneBadge)
        addSubview(flagPill)
        flagPill.addSubview(flagBadge)
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

            paneBadge.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 12),
            paneBadge.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 12),
            paneBadge.heightAnchor.constraint(equalToConstant: 22),
            paneBadge.trailingAnchor.constraint(lessThanOrEqualTo: flagPill.leadingAnchor, constant: -10),

            paneBadgeIndexLabel.leadingAnchor.constraint(equalTo: paneBadge.leadingAnchor, constant: 9),
            paneBadgeIndexLabel.centerYAnchor.constraint(equalTo: paneBadge.centerYAnchor),

            paneBadgeLabel.leadingAnchor.constraint(equalTo: paneBadgeIndexLabel.trailingAnchor, constant: 6),
            paneBadgeLabel.trailingAnchor.constraint(equalTo: paneBadge.trailingAnchor, constant: -9),
            paneBadgeLabel.centerYAnchor.constraint(equalTo: paneBadge.centerYAnchor),

            flagPill.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -12),
            flagPill.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 12),
            flagPill.widthAnchor.constraint(equalToConstant: 28),
            flagPill.heightAnchor.constraint(equalToConstant: 28),

            flagBadge.centerXAnchor.constraint(equalTo: flagPill.centerXAnchor),
            flagBadge.centerYAnchor.constraint(equalTo: flagPill.centerYAnchor),
            flagBadge.widthAnchor.constraint(equalToConstant: 20),
            flagBadge.heightAnchor.constraint(equalToConstant: 20)
        ])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let flagTrackingArea { removeTrackingArea(flagTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        flagTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let hovered = flagPill.frame.insetBy(dx: -8, dy: -8).contains(pt)
        if hovered != isFlagHovered {
            isFlagHovered = hovered
            refreshFlagPillAppearance()
        }
    }

    override func mouseExited(with event: NSEvent) {
        if isFlagHovered {
            isFlagHovered = false
            refreshFlagPillAppearance()
        }
    }

    func setPaneNumber(_ number: Int, multiPane: Bool) {
        paneOrderNumber = number
        isMultiPane = multiPane
    }

    /// Имя и метрики файла для верхней панели окна.
    var captionParts: (name: String, detail: String) {
        (nameText, detailText)
    }

    /// Кадр остаётся полностью непрозрачным на чистом студийном тёмном фоне:
    /// нейтральный обсидиан не искажает цветокоррекцию и не пропускает текст
    /// проводника сквозь поля 21:9.
    func applyTheme() {
        let aurora = FPStyle.isObsidianAurora
        let tint = FPStyle.text.blended(withFraction: 0.22, of: FPStyle.accent) ?? FPStyle.text
        previewContainer.layer?.cornerRadius = FPStyle.isCyberEditorial ? 4 : 11
        if isMultiPane {
            previewContainer.layer?.backgroundColor = NSColor(
                calibratedRed: 0.025,
                green: 0.024,
                blue: 0.032,
                alpha: 0.72
            ).cgColor
            previewContainer.layer?.borderWidth = 0.65
            previewContainer.layer?.borderColor = (aurora ? tint.withAlphaComponent(0.10) : FPStyle.stroke.withAlphaComponent(0.35)).cgColor
        } else {
            previewContainer.layer?.backgroundColor = NSColor.clear.cgColor
            previewContainer.layer?.borderWidth = 0
            previewContainer.layer?.borderColor = NSColor.clear.cgColor
        }
        paneBadge.layer?.backgroundColor = NSColor(calibratedRed: 0.055, green: 0.052, blue: 0.068, alpha: 0.80).cgColor
        paneBadge.layer?.borderColor = (aurora ? tint.withAlphaComponent(0.14) : FPStyle.stroke.withAlphaComponent(0.45)).cgColor
        refreshPaneBadge()
        refreshFlagPillAppearance()
        transportBar?.applyTheme()
        updateFocusRing()
    }

    private func refreshPaneBadge() {
        paneBadge.isHidden = !isMultiPane || nameText.isEmpty
        guard !paneBadge.isHidden else { return }
        paneBadgeIndexLabel.stringValue = "\(paneOrderNumber)"
        paneBadgeIndexLabel.textColor = isFocused ? FPStyle.orange : FPStyle.dimText
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        paneBadgeLabel.attributedStringValue = NSAttributedString(
            string: nameText,
            attributes: [
                .font: FPStyle.bodyFont(ofSize: 10.5, weight: .medium),
                .foregroundColor: FPStyle.text.withAlphaComponent(isFocused ? 0.94 : 0.72),
                .paragraphStyle: paragraph
            ]
        )
    }

    private func refreshFlagPillAppearance() {
        let level = flagBadge.level
        switch level {
        case .none:
            flagPill.layer?.backgroundColor = NSColor(
                calibratedRed: 0.055,
                green: 0.052,
                blue: 0.068,
                alpha: isFlagHovered ? 0.82 : 0.56
            ).cgColor
            flagPill.layer?.borderColor = NSColor.white.withAlphaComponent(isFlagHovered ? 0.24 : 0.12).cgColor
            flagPill.layer?.borderWidth = 0.75
            flagPill.alphaValue = isFlagHovered ? 1.0 : 0.74
        case .candidate:
            flagPill.layer?.backgroundColor = NSColor(calibratedRed: 0.06, green: 0.05, blue: 0.07, alpha: 0.86).cgColor
            flagPill.layer?.borderColor = FPStyle.orange.withAlphaComponent(0.68).cgColor
            flagPill.layer?.borderWidth = 1.0
            flagPill.alphaValue = 1.0
        case .confirmed:
            flagPill.layer?.backgroundColor = NSColor(calibratedRed: 0.06, green: 0.05, blue: 0.07, alpha: 0.86).cgColor
            flagPill.layer?.borderColor = FPStyle.accent.withAlphaComponent(0.75).cgColor
            flagPill.layer?.borderWidth = 1.0
            flagPill.alphaValue = 1.0
        }
    }

    private func updateFocusRing() {
        focusRing.layer?.borderColor = isFocused
            ? FPStyle.accent.withAlphaComponent(0.88).cgColor
            : NSColor.clear.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        onActivate?(self)
        super.mouseDown(with: event)
    }

    func show(url: URL?) {
        // Если файл тот же, кадр не трогается. Иначе при листании активной
        // панели соседние перезагружали ровно ту же картинку и мигали.
        if url == self.url, url != nil, (previewView != nil || imageView != nil || playerLayerView != nil) {
            refreshFlag()
            return
        }
        self.url = url
        imageLoadGeneration += 1
        let currentGeneration = imageLoadGeneration

        let ext = url?.pathExtension.lowercased() ?? ""
        let isFont = url.map(FPFontPreviewRenderer.isFontURL) ?? false
        let wantsDirectImage = isFont || (url.map(QyvroPreviewImageCache.isDirectImage) ?? false)

        // Готовые QL-кадры не выбрасываются, а откладываются: при листании
        // вперёд-назад по PDF/документам они не пересоздаются каждый раз.
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

        if !wantsDirectImage {
            imageView?.image = nil
            imageView?.removeFromSuperview()
            imageView = nil
        }

        transportBar?.detach()
        playerLayerView?.player?.pause()
        playerLayerView?.removeFromSuperview()
        playerLayerView = nil
        transportBar?.removeFromSuperview()
        transportBar = nil

        guard let url else {
            nameText = ""
            detailText = ""
            flagPill.isHidden = true
            paneBadge.isHidden = true
            return
        }

        if FPMediaInfoCache.movieExtensions.contains(ext) || Self.audioExtensions.contains(ext) {
            // Видео и аудио идут мимо Quick Look и мимо AVPlayerView — см.
            // комментарий у playerLayerView. Строка управления — отдельная
            // парящая стеклянная капсула под кадром, а не поверх него.
            let layerView = FPPlayerLayerView(frame: previewContainer.bounds)
            layerView.translatesAutoresizingMaskIntoConstraints = false
            let bar = FPMediaTransportBar(frame: .zero)
            bar.translatesAutoresizingMaskIntoConstraints = false
            let avPlayer = AVPlayer(url: url)
            layerView.player = avPlayer
            previewContainer.addSubview(layerView)
            previewContainer.addSubview(bar)
            NSLayoutConstraint.activate([
                layerView.topAnchor.constraint(equalTo: previewContainer.topAnchor),
                layerView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
                layerView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
                layerView.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -8),

                bar.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 12),
                bar.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -12),
                bar.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: -10),
                bar.heightAnchor.constraint(equalToConstant: 42)
            ])
            playerLayerView = layerView
            transportBar = bar
            bar.onGrabFrame = { [weak self] in self?.onGrabFrameRequested?() }
            bar.setShowsGrabFrame(FPMediaInfoCache.movieExtensions.contains(ext))
            bar.applyTheme()
            bar.attach(to: avPlayer)
            // Открыл превью — значит хочет посмотреть/послушать, а не сперва
            // прицелиться в кнопку play.
            avPlayer.play()
            nameText = url.lastPathComponent
            refreshPaneBadge()
            refreshFlag()
            refreshDetail(for: url)
            return
        }

        if isFont {
            let targetImageView = ensureImageView()
            targetImageView.animates = false
            targetImageView.image = FPFontPreviewRenderer.specimenImage(for: url)
            nameText = url.lastPathComponent
            refreshPaneBadge()
            refreshFlag()
            refreshDetail(for: url)
            return
        }

        if wantsDirectImage {
            let targetImageView = ensureImageView()
            targetImageView.animates = (ext == "gif")
            let maxPixels = QyvroPreviewImageCache.targetPixelSize(for: window?.screen)
            if let cached = QyvroPreviewImageCache.shared.cachedImage(for: url, maxPixelSize: maxPixels) {
                targetImageView.image = cached
            } else {
                targetImageView.image = nil
                QyvroPreviewImageCache.shared.load(url: url, maxPixelSize: maxPixels) { [weak self] decoded in
                    guard let self,
                          self.imageLoadGeneration == currentGeneration,
                          self.url == url else { return }
                    if let decoded {
                        self.ensureImageView().image = decoded
                    } else {
                        // Если системный ImageIO не справился с экзотическим файлом,
                        // откатываемся на Quick Look вместо пустого кадра.
                        self.imageView?.image = nil
                        self.imageView?.removeFromSuperview()
                        self.imageView = nil
                        self.showWithQuickLook(url: url)
                    }
                }
            }
            nameText = url.lastPathComponent
            refreshPaneBadge()
            refreshFlag()
            refreshDetail(for: url)
            return
        }

        showWithQuickLook(url: url)
        nameText = url.lastPathComponent
        refreshPaneBadge()
        refreshFlag()
        refreshDetail(for: url)
    }

    private func ensureImageView() -> NSImageView {
        if let imageView { return imageView }
        let view = NSImageView(frame: previewContainer.bounds)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageAlignment = .alignCenter
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        previewContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            view.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor)
        ])
        imageView = view
        return view
    }

    private func showWithQuickLook(url: URL) {
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
    }

    func refreshFlag() {
        guard let url else { return }
        flagPill.isHidden = false
        flagBadge.isHidden = false
        flagBadge.level = FPFinderTagStore.flagLevel(url: url)
        refreshFlagPillAppearance()
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

    /// Пауза/воспроизведение по клавише — для панелей без видео или аудио
    /// (картинка, PDF, текст) это просто ничего не делает.
    func togglePlayback() {
        guard let player = playerLayerView?.player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
        transportBar?.refreshPlayPauseIcon()
    }

    func toggleMute() {
        transportBar?.toggleMute()
    }

    var isShowingVideo: Bool {
        guard let url, playerLayerView?.player != nil else { return false }
        return FPMediaInfoCache.movieExtensions.contains(url.pathExtension.lowercased())
    }

    var isShowingAudio: Bool {
        guard let url, playerLayerView?.player != nil else { return false }
        return Self.audioExtensions.contains(url.pathExtension.lowercased())
    }

    func captureCurrentVideoFrame(completion: @escaping (Result<URL, Error>) -> Void) {
        guard let url,
              FPMediaInfoCache.movieExtensions.contains(url.pathExtension.lowercased()),
              let player = playerLayerView?.player,
              let asset = player.currentItem?.asset else {
            completion(.failure(NSError(
                domain: "QyvroPreview",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: L("Откройте видео, чтобы снять кадр.", "Open a video to grab a frame.")]
            )))
            return
        }

        let currentTime = player.currentTime()
        let seconds = currentTime.isNumeric && currentTime.seconds.isFinite ? max(0, currentTime.seconds) : 0
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let stamp = String(format: "%02d-%02d", mins, secs)
        let stem = url.deletingPathExtension().lastPathComponent
        let parent = url.deletingLastPathComponent()

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        generator.generateCGImageAsynchronously(for: currentTime) { cgImage, _, error in
            guard let cgImage else {
                let err = error ?? NSError(
                    domain: "QyvroPreview",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: L("Не удалось извлечь кадр.", "Could not extract video frame.")]
                )
                DispatchQueue.main.async { completion(.failure(err)) }
                return
            }

            let fm = FileManager.default
            var candidate = parent.appendingPathComponent("\(stem)_frame_\(stamp).png")
            var suffix = 2
            while fm.fileExists(atPath: candidate.path) {
                candidate = parent.appendingPathComponent("\(stem)_frame_\(stamp)_\(suffix).png")
                suffix += 1
            }

            guard let destination = CGImageDestinationCreateWithURL(
                candidate as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            ) else {
                let err = NSError(
                    domain: "QyvroPreview",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: L("Не удалось создать PNG-файл.", "Could not create PNG file.")]
                )
                DispatchQueue.main.async { completion(.failure(err)) }
                return
            }
            CGImageDestinationAddImage(destination, cgImage, nil)
            if CGImageDestinationFinalize(destination) {
                DispatchQueue.main.async {
                    QyvroFileOperationHistory.shared.recordCreated(candidate)
                    completion(.success(candidate))
                }
            } else {
                let err = NSError(
                    domain: "QyvroPreview",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: L("Ошибка записи PNG-файла.", "Failed to write PNG file.")]
                )
                DispatchQueue.main.async { completion(.failure(err)) }
            }
        }
    }

    func teardown() {
        imageLoadGeneration += 1
        imageView?.image = nil
        imageView?.removeFromSuperview()
        imageView = nil
        transportBar?.detach()
        playerLayerView?.player?.pause()
        playerLayerView?.removeFromSuperview()
        playerLayerView = nil
        transportBar?.removeFromSuperview()
        transportBar = nil
        previewView?.close()
        previewView?.removeFromSuperview()
        previewView = nil
        for entry in cache { entry.view.close() }
        cache.removeAll()
        previousURL = nil
        url = nil
    }
}

/// Голый видеослой без какого-либо чужого UI поверх.
///
/// `makeBackingLayer()` подставляет `AVPlayerLayer` вместо обычного слоя —
/// это штатный способ AppKit сделать вид хостом для чужого `CALayer`, без
/// ручной возни с порядком `wantsLayer`/`layer`. Кнопки и прогресс рисует
/// `FPMediaTransportBar` отдельно, этот вид только показывает картинку.
final class FPPlayerLayerView: NSView {
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func makeBackingLayer() -> CALayer { AVPlayerLayer() }

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }
}

/// Своя строка воспроизведения: кнопка паузы, бегунок, время.
///
/// AVPlayerView гасила подложку под своими кнопками при наведении мышью на
/// кадр — на `.floating`, и на `.inline` тоже, и публичного способа это
/// выключить не нашлось. Здесь чужого UI нет вообще, поэтому и тушить
/// нечему.
final class FPMediaTransportBar: NSView {
    private let background = FPLayerView(color: .clear, cornerRadius: 12)
    private let playPill = FPLayerView(color: .clear, cornerRadius: 14)
    private let playPauseButton = NSButton()
    private let currentTimeLabel = NSTextField(labelWithString: "00:00")
    private let durationLabel = NSTextField(labelWithString: "00:00")
    private let scrubber = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let grabPill = FPLayerView(color: .clear, cornerRadius: 8)
    private let grabFrameButton = NSButton()
    private var grabPillWidth: NSLayoutConstraint?
    private let muteButton = NSButton()
    private let volumeSlider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)

    private weak var player: AVPlayer?
    private var timeObserver: Any?
    var onGrabFrame: (() -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        buildLayout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildLayout() {
        background.translatesAutoresizingMaskIntoConstraints = false
        background.layer?.borderWidth = 0.75

        playPill.translatesAutoresizingMaskIntoConstraints = false
        playPill.layer?.borderWidth = 0.6

        playPauseButton.isBordered = false
        playPauseButton.bezelStyle = .inline
        playPauseButton.imagePosition = .imageOnly
        playPauseButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: L("Воспроизвести", "Play"))
        playPauseButton.target = self
        playPauseButton.action = #selector(togglePlayPause)
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false

        for label in [currentTimeLabel, durationLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
        }

        scrubber.isContinuous = true
        scrubber.target = self
        scrubber.action = #selector(scrub)
        scrubber.translatesAutoresizingMaskIntoConstraints = false

        grabPill.translatesAutoresizingMaskIntoConstraints = false
        grabPill.layer?.borderWidth = 0.6

        grabFrameButton.isBordered = false
        grabFrameButton.bezelStyle = .inline
        grabFrameButton.imagePosition = .imageOnly
        grabFrameButton.image = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: L("Снять кадр в PNG", "Grab PNG frame"))
        grabFrameButton.target = self
        grabFrameButton.action = #selector(grabFramePressed)
        grabFrameButton.translatesAutoresizingMaskIntoConstraints = false

        muteButton.isBordered = false
        muteButton.bezelStyle = .inline
        muteButton.imagePosition = .imageOnly
        muteButton.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: L("Звук", "Sound"))
        muteButton.target = self
        muteButton.action = #selector(toggleMute)
        muteButton.translatesAutoresizingMaskIntoConstraints = false

        volumeSlider.isContinuous = true
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged)
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false

        addSubview(background)
        addSubview(playPill)
        playPill.addSubview(playPauseButton)
        addSubview(currentTimeLabel)
        addSubview(scrubber)
        addSubview(durationLabel)
        addSubview(grabPill)
        grabPill.addSubview(grabFrameButton)
        addSubview(muteButton)
        addSubview(volumeSlider)

        let widthConstraint = grabPill.widthAnchor.constraint(equalToConstant: 28)
        grabPillWidth = widthConstraint

        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),

            playPill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            playPill.centerYAnchor.constraint(equalTo: centerYAnchor),
            playPill.widthAnchor.constraint(equalToConstant: 28),
            playPill.heightAnchor.constraint(equalToConstant: 28),

            playPauseButton.centerXAnchor.constraint(equalTo: playPill.centerXAnchor),
            playPauseButton.centerYAnchor.constraint(equalTo: playPill.centerYAnchor),
            playPauseButton.widthAnchor.constraint(equalToConstant: 22),
            playPauseButton.heightAnchor.constraint(equalToConstant: 22),

            currentTimeLabel.leadingAnchor.constraint(equalTo: playPill.trailingAnchor, constant: 8),
            currentTimeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            currentTimeLabel.widthAnchor.constraint(equalToConstant: 42),

            scrubber.leadingAnchor.constraint(equalTo: currentTimeLabel.trailingAnchor, constant: 8),
            scrubber.trailingAnchor.constraint(equalTo: durationLabel.leadingAnchor, constant: -8),
            scrubber.centerYAnchor.constraint(equalTo: centerYAnchor),

            durationLabel.trailingAnchor.constraint(equalTo: grabPill.leadingAnchor, constant: -10),
            durationLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            durationLabel.widthAnchor.constraint(equalToConstant: 42),

            grabPill.trailingAnchor.constraint(equalTo: muteButton.leadingAnchor, constant: -10),
            grabPill.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthConstraint,
            grabPill.heightAnchor.constraint(equalToConstant: 26),

            grabFrameButton.centerXAnchor.constraint(equalTo: grabPill.centerXAnchor),
            grabFrameButton.centerYAnchor.constraint(equalTo: grabPill.centerYAnchor),
            grabFrameButton.widthAnchor.constraint(equalToConstant: 22),
            grabFrameButton.heightAnchor.constraint(equalToConstant: 22),

            muteButton.trailingAnchor.constraint(equalTo: volumeSlider.leadingAnchor, constant: -6),
            muteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            muteButton.widthAnchor.constraint(equalToConstant: 18),
            muteButton.heightAnchor.constraint(equalToConstant: 18),

            volumeSlider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            volumeSlider.centerYAnchor.constraint(equalTo: centerYAnchor),
            volumeSlider.widthAnchor.constraint(equalToConstant: 64)
        ])
        applyTheme()
    }

    func applyTheme() {
        let aurora = FPStyle.isObsidianAurora
        let tint = FPStyle.text.blended(withFraction: 0.22, of: FPStyle.accent) ?? FPStyle.text
        background.layer?.backgroundColor = (aurora
            ? NSColor(calibratedRed: 0.068, green: 0.064, blue: 0.082, alpha: 0.90)
            : FPStyle.control.withAlphaComponent(0.92)).cgColor
        background.layer?.borderColor = (aurora
            ? tint.withAlphaComponent(0.14)
            : FPStyle.stroke.withAlphaComponent(0.55)).cgColor

        playPill.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        playPill.layer?.borderColor = tint.withAlphaComponent(0.14).cgColor
        playPauseButton.contentTintColor = FPStyle.text

        currentTimeLabel.textColor = FPStyle.text.withAlphaComponent(0.84)
        durationLabel.textColor = FPStyle.dimText

        if #available(macOS 10.12.2, *) {
            scrubber.trackFillColor = FPStyle.accent
            volumeSlider.trackFillColor = FPStyle.accent
        }

        grabPill.layer?.backgroundColor = FPStyle.orange.withAlphaComponent(0.14).cgColor
        grabPill.layer?.borderColor = FPStyle.orange.withAlphaComponent(0.36).cgColor
        grabFrameButton.contentTintColor = FPStyle.orange
        grabFrameButton.toolTip = L("Снять кадр в PNG (E)", "Grab PNG frame (E)")
        muteButton.contentTintColor = FPStyle.text.withAlphaComponent(0.86)
        muteButton.toolTip = L("Звук (M)", "Mute / Unmute (M)")
    }

    func setShowsGrabFrame(_ shows: Bool) {
        grabPill.isHidden = !shows
        grabPillWidth?.constant = shows ? 28 : 0
    }

    @objc private func grabFramePressed() {
        onGrabFrame?()
    }

    func attach(to player: AVPlayer) {
        detach()
        self.player = player
        player.volume = FPPreferences.previewVolume
        player.isMuted = FPPreferences.previewMuted
        volumeSlider.doubleValue = Double(player.volume)
        refreshPlayPauseIcon()
        refreshMuteIcon()
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            self?.tick(time: time)
        }
    }

    func detach() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player = nil
    }

    func refreshPlayPauseIcon() {
        let isPlaying = player?.timeControlStatus == .playing
        playPauseButton.image = NSImage(
            systemSymbolName: isPlaying ? "pause.fill" : "play.fill",
            accessibilityDescription: isPlaying ? "Пауза" : "Воспроизвести"
        )
    }

    private func tick(time: CMTime) {
        refreshPlayPauseIcon()
        let duration = player?.currentItem?.duration.seconds ?? 0
        if duration.isFinite, duration > 0 {
            scrubber.maxValue = duration
            durationLabel.stringValue = Self.format(duration)
        }
        let current = time.seconds
        guard current.isFinite else { return }
        scrubber.doubleValue = current
        currentTimeLabel.stringValue = Self.format(current)
    }

    @objc private func togglePlayPause() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
        refreshPlayPauseIcon()
    }

    @objc private func scrub() {
        guard let player else { return }
        let target = CMTime(seconds: scrubber.doubleValue, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTimeLabel.stringValue = Self.format(scrubber.doubleValue)
    }

    func refreshMuteIcon() {
        let isMuted = player?.isMuted ?? false
        muteButton.image = NSImage(
            systemSymbolName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
            accessibilityDescription: isMuted ? "Включить звук" : "Выключить звук"
        )
    }

    /// Тоже общий на все файлы, как и громкость: включил без звука — так и
    /// останется, пока не включишь обратно сам.
    @objc func toggleMute() {
        guard let player else { return }
        player.isMuted.toggle()
        UserDefaults.standard.set(player.isMuted, forKey: "PreviewMuted")
        refreshMuteIcon()
    }

    /// Громкость общая на все файлы: подвинул один раз — следующий
    /// предпросмотр открывается с тем же уровнем, а не снова со ста
    /// процентов.
    @objc private func volumeChanged() {
        guard let player else { return }
        let value = Float(volumeSlider.doubleValue)
        player.volume = value
        UserDefaults.standard.set(value, forKey: "PreviewVolume")
        // Двигать ползунок при заглушённом звуке и не слышать разницы —
        // так и не поймёшь, почему звука всё ещё нет.
        if player.isMuted, value > 0 {
            toggleMute()
        }
    }

    private static func format(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// Компактная стеклянная кнопка-иконка для шапки просмотрщика в стиле Studio V4.
private final class FPPreviewHeaderButton: NSButton {
    private var trackingAreaRef: NSTrackingArea?
    private var isHovered = false
    var isActiveState = false {
        didSet { applyAppearance() }
    }

    override var mouseDownCanMoveWindow: Bool { false }

    init(symbol: String, accessibility: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        wantsLayer = true
        isBordered = false
        bezelStyle = .inline
        imagePosition = .imageOnly
        setButtonType(.momentaryChange)
        layer?.cornerRadius = 7
        layer?.borderWidth = 0.65
        translatesAutoresizingMaskIntoConstraints = false
        self.target = target
        self.action = action
        setSymbol(symbol, accessibility: accessibility)
        applyAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setSymbol(_ symbol: String, accessibility: String) {
        if #available(macOS 11.0, *) {
            let config = NSImage.SymbolConfiguration(pointSize: 11.5, weight: .medium)
            let resolved = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility)
                ?? NSImage(systemSymbolName: "rectangle.lefthalf.filled", accessibilityDescription: accessibility)
            image = resolved?.withSymbolConfiguration(config)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        applyAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyAppearance()
    }

    func applyAppearance() {
        let tint = FPStyle.text.blended(withFraction: 0.22, of: FPStyle.accent) ?? FPStyle.text
        if isActiveState {
            layer?.backgroundColor = FPStyle.accent.withAlphaComponent(isHovered ? 0.28 : 0.20).cgColor
            layer?.borderColor = FPStyle.accent.withAlphaComponent(0.55).cgColor
            contentTintColor = FPStyle.orange
        } else if isHovered {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
            layer?.borderColor = tint.withAlphaComponent(0.18).cgColor
            contentTintColor = FPStyle.text
        } else {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.045).cgColor
            layer?.borderColor = tint.withAlphaComponent(0.10).cgColor
            contentTintColor = FPStyle.dimText
        }
    }
}

/// Содержимое окна просмотрщика: Studio V4 Darkroom Lightbox.
final class FPPreviewContentView: NSView {
    enum HintMode {
        case image
        case video
        case audio
        case compare
        case curtain
    }

    /// Подложка и фон вынесены отдельными видами: в темах «Аврора» рисуется
    /// тот же бархатный обсидиан с Deep Glow и микрозерном, что в главном окне,
    /// а кадр лежит внутри парящего нейтрального тёмного острова без паразитного
    /// оттенка и без просвечивания текста проводника.
    private let backdrop = NSVisualEffectView()
    private let backgroundGradientView = FPBackgroundGradientView()
    private let auroraBackdropView = QyvroAuroraBackdropView()
    private let topBar = NSView()
    private let leftHeaderStack = NSStackView()
    private let rightHeaderStack = NSStackView()
    private let indexPill = FPLayerView(color: .clear, cornerRadius: 7)
    private let indexLabel = NSTextField(labelWithString: "")
    private let nameButton = NSButton()
    private let statusPill = FPLayerView(color: .clear, cornerRadius: 7)
    private let copyHint = NSTextField(labelWithString: "")
    private let detailPill = FPLayerView(color: .clear, cornerRadius: 7)
    private let detailField = NSTextField(labelWithString: "")
    private lazy var compareButton = FPPreviewHeaderButton(
        symbol: "rectangle.split.2x1",
        accessibility: L("Сравнение панелей", "Compare panes"),
        target: self,
        action: #selector(comparePressed)
    )
    private lazy var curtainButton = FPPreviewHeaderButton(
        symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right",
        accessibility: L("Сравнение шторкой", "Split wipe compare"),
        target: self,
        action: #selector(curtainPressed)
    )
    private lazy var maximizeButton = FPPreviewHeaderButton(
        symbol: "arrow.up.left.and.arrow.down.right",
        accessibility: L("Во весь экран", "Maximize"),
        target: self,
        action: #selector(maximizePressed)
    )
    private let stageIsland = FPLayerView(color: .clear, cornerRadius: 16)
    private let stack = NSStackView()
    private let hintPill = FPLayerView(color: .clear, cornerRadius: 13)
    private let hintBar = NSTextField(labelWithString: "")
    private var resizeOverlay: QyvroWindowResizeOverlay?
    private var currentHintMode: HintMode = .image
    private(set) var panes: [FPPreviewPane] = []
    var onKeyDown: ((NSEvent) -> Bool)?
    var onCycleCompare: (() -> Void)?
    var onToggleCurtain: (() -> Void)?
    var onToggleMaximize: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        backdrop.material = .underWindowBackground
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backgroundGradientView.translatesAutoresizingMaskIntoConstraints = false
        auroraBackdropView.translatesAutoresizingMaskIntoConstraints = false

        topBar.translatesAutoresizingMaskIntoConstraints = false

        leftHeaderStack.orientation = .horizontal
        leftHeaderStack.alignment = .centerY
        leftHeaderStack.spacing = 8
        leftHeaderStack.detachesHiddenViews = true
        leftHeaderStack.translatesAutoresizingMaskIntoConstraints = false

        rightHeaderStack.orientation = .horizontal
        rightHeaderStack.alignment = .centerY
        rightHeaderStack.spacing = 6
        rightHeaderStack.detachesHiddenViews = true
        rightHeaderStack.translatesAutoresizingMaskIntoConstraints = false
        rightHeaderStack.setContentHuggingPriority(.required, for: .horizontal)
        rightHeaderStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        indexPill.translatesAutoresizingMaskIntoConstraints = false
        indexPill.layer?.borderWidth = 0.6
        indexPill.isHidden = true
        indexPill.setContentHuggingPriority(.required, for: .horizontal)
        indexPill.setContentCompressionResistancePriority(.required, for: .horizontal)
        indexLabel.font = FPStyle.monoMetaFont(ofSize: 10.5, weight: .semibold)
        indexLabel.alignment = .center
        indexLabel.translatesAutoresizingMaskIntoConstraints = false
        indexPill.addSubview(indexLabel)

        nameButton.isBordered = false
        nameButton.bezelStyle = .inline
        nameButton.alignment = .left
        nameButton.target = self
        nameButton.action = #selector(copyName(_:))
        nameButton.toolTip = L("Нажмите, чтобы скопировать имя файла", "Click to copy file name")
        nameButton.translatesAutoresizingMaskIntoConstraints = false
        nameButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameButton.setContentHuggingPriority(.defaultLow, for: .horizontal)

        statusPill.translatesAutoresizingMaskIntoConstraints = false
        statusPill.layer?.borderWidth = 0.65
        statusPill.isHidden = true
        statusPill.setContentHuggingPriority(.required, for: .horizontal)
        statusPill.setContentCompressionResistancePriority(.required, for: .horizontal)
        copyHint.alignment = .center
        copyHint.font = FPStyle.monoMetaFont(ofSize: 10, weight: .semibold)
        copyHint.stringValue = ""
        copyHint.translatesAutoresizingMaskIntoConstraints = false
        statusPill.addSubview(copyHint)

        detailPill.translatesAutoresizingMaskIntoConstraints = false
        detailPill.layer?.borderWidth = 0.6
        detailPill.isHidden = true
        detailPill.setContentHuggingPriority(.required, for: .horizontal)
        detailPill.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detailField.alignment = .right
        detailField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        detailField.lineBreakMode = .byTruncatingTail
        detailField.translatesAutoresizingMaskIntoConstraints = false
        detailPill.addSubview(detailField)

        stageIsland.translatesAutoresizingMaskIntoConstraints = false
        stageIsland.layer?.masksToBounds = true
        stageIsland.layer?.borderWidth = 0.75

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 8

        hintPill.translatesAutoresizingMaskIntoConstraints = false
        hintPill.layer?.borderWidth = 0.65

        hintBar.translatesAutoresizingMaskIntoConstraints = false
        hintBar.alignment = .center
        hintBar.lineBreakMode = .byTruncatingTail
        hintBar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hintBar.attributedStringValue = Self.hintText(for: currentHintMode)

        addSubview(backdrop)
        addSubview(backgroundGradientView)
        addSubview(auroraBackdropView)
        addSubview(topBar)
        topBar.addSubview(leftHeaderStack)
        topBar.addSubview(rightHeaderStack)

        leftHeaderStack.addArrangedSubview(indexPill)
        leftHeaderStack.addArrangedSubview(nameButton)
        leftHeaderStack.addArrangedSubview(statusPill)

        rightHeaderStack.addArrangedSubview(detailPill)
        rightHeaderStack.addArrangedSubview(compareButton)
        rightHeaderStack.addArrangedSubview(curtainButton)
        rightHeaderStack.addArrangedSubview(maximizeButton)

        addSubview(stageIsland)
        stageIsland.addSubview(stack)
        addSubview(hintPill)
        hintPill.addSubview(hintBar)

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),

            backgroundGradientView.topAnchor.constraint(equalTo: topAnchor),
            backgroundGradientView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundGradientView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundGradientView.bottomAnchor.constraint(equalTo: bottomAnchor),

            auroraBackdropView.topAnchor.constraint(equalTo: topAnchor),
            auroraBackdropView.leadingAnchor.constraint(equalTo: leadingAnchor),
            auroraBackdropView.trailingAnchor.constraint(equalTo: trailingAnchor),
            auroraBackdropView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Бесшовная верхняя полоса Studio V4 в одном ряду со светофором.
            topBar.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            topBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 78),
            topBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            topBar.heightAnchor.constraint(equalToConstant: 34),

            leftHeaderStack.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            leftHeaderStack.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            leftHeaderStack.trailingAnchor.constraint(lessThanOrEqualTo: rightHeaderStack.leadingAnchor, constant: -12),

            rightHeaderStack.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
            rightHeaderStack.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            indexPill.heightAnchor.constraint(equalToConstant: 22),
            indexLabel.leadingAnchor.constraint(equalTo: indexPill.leadingAnchor, constant: 8),
            indexLabel.trailingAnchor.constraint(equalTo: indexPill.trailingAnchor, constant: -8),
            indexLabel.centerYAnchor.constraint(equalTo: indexPill.centerYAnchor),

            statusPill.heightAnchor.constraint(equalToConstant: 22),
            copyHint.leadingAnchor.constraint(equalTo: statusPill.leadingAnchor, constant: 8),
            copyHint.trailingAnchor.constraint(equalTo: statusPill.trailingAnchor, constant: -8),
            copyHint.centerYAnchor.constraint(equalTo: statusPill.centerYAnchor),

            detailPill.heightAnchor.constraint(equalToConstant: 22),
            detailField.leadingAnchor.constraint(equalTo: detailPill.leadingAnchor, constant: 9),
            detailField.trailingAnchor.constraint(equalTo: detailPill.trailingAnchor, constant: -9),
            detailField.centerYAnchor.constraint(equalTo: detailPill.centerYAnchor),

            compareButton.widthAnchor.constraint(equalToConstant: 26),
            compareButton.heightAnchor.constraint(equalToConstant: 24),
            curtainButton.widthAnchor.constraint(equalToConstant: 26),
            curtainButton.heightAnchor.constraint(equalToConstant: 24),
            maximizeButton.widthAnchor.constraint(equalToConstant: 26),
            maximizeButton.heightAnchor.constraint(equalToConstant: 24),

            // Парящий тёмный остров Studio V4 — та же геометрия (10 pt), что и в проводнике.
            stageIsland.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 4),
            stageIsland.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stageIsland.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stageIsland.bottomAnchor.constraint(equalTo: hintPill.topAnchor, constant: -8),

            stack.topAnchor.constraint(equalTo: stageIsland.topAnchor, constant: 6),
            stack.leadingAnchor.constraint(equalTo: stageIsland.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: stageIsland.trailingAnchor, constant: -6),
            stack.bottomAnchor.constraint(equalTo: stageIsland.bottomAnchor, constant: -6),

            // Центрированная плавающая стеклянная капсула подсказок снизу.
            hintPill.centerXAnchor.constraint(equalTo: centerXAnchor),
            hintPill.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 14),
            hintPill.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            hintPill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            hintPill.heightAnchor.constraint(equalToConstant: 26),

            hintBar.leadingAnchor.constraint(equalTo: hintPill.leadingAnchor, constant: 14),
            hintBar.trailingAnchor.constraint(equalTo: hintPill.trailingAnchor, constant: -14),
            hintBar.centerYAnchor.constraint(equalTo: hintPill.centerYAnchor)
        ])
        resizeOverlay = QyvroWindowResizeOverlay.install(
            in: self,
            insets: QyvroWindowResizeInsets(left: 10, right: 10, top: 6, bottom: 9, cornerSize: 14)
        )
        applyTheme()
    }

    func keepResizeOverlayOnTop() {
        resizeOverlay?.bringToFront()
    }

    /// Монтирует шторку прямо внутрь тёмного острова просмотра с тем же отступом,
    /// что и у панелей.
    func mountCurtain(_ curtain: FPCurtainCompareView) {
        if curtain.superview !== stageIsland {
            curtain.removeFromSuperview()
            curtain.translatesAutoresizingMaskIntoConstraints = false
            stageIsland.addSubview(curtain)
            NSLayoutConstraint.activate([
                curtain.topAnchor.constraint(equalTo: stageIsland.topAnchor, constant: 6),
                curtain.leadingAnchor.constraint(equalTo: stageIsland.leadingAnchor, constant: 6),
                curtain.trailingAnchor.constraint(equalTo: stageIsland.trailingAnchor, constant: -6),
                curtain.bottomAnchor.constraint(equalTo: stageIsland.bottomAnchor, constant: -6)
            ])
        }
        keepResizeOverlayOnTop()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Компактная контекстная строка подсказок внутри стеклянной HUD-капсулы:
    /// показывает только реально нужные клавиши для текущего типа файла и режима.
    private static func hintText(for mode: HintMode) -> NSAttributedString {
        let pairs: [(String, String)]
        switch mode {
        case .video:
            pairs = [
                ("← →", L("листать", "browse")),
                ("S", L("пауза", "play")),
                ("M", L("звук", "mute")),
                ("E", L("кадр PNG", "PNG frame")),
                ("F", L("отметить", "mark")),
                ("T", L("экран", "zoom")),
                ("⌫", L("корзина", "trash")),
                ("Esc", L("закрыть", "close"))
            ]
        case .audio:
            pairs = [
                ("← →", L("листать", "browse")),
                ("S", L("пауза", "play")),
                ("M", L("звук", "mute")),
                ("F", L("отметить", "mark")),
                ("⌫", L("корзина", "trash")),
                ("Esc", L("закрыть", "close"))
            ]
        case .compare:
            pairs = [
                ("← →", L("листать", "browse")),
                ("1–3", L("панель", "pane")),
                ("F", L("отметить", "mark")),
                ("C", L("вид", "layout")),
                ("V", L("шторка", "wipe")),
                ("⌫", L("корзина", "trash")),
                ("Esc", L("закрыть", "close"))
            ]
        case .curtain:
            pairs = [
                ("← →", L("кадр", "frame")),
                ("V", L("выход из шторки", "exit wipe")),
                ("F", L("отметить", "mark")),
                ("T", L("экран", "zoom")),
                ("Esc", L("закрыть", "close"))
            ]
        case .image:
            pairs = [
                ("← →", L("листать", "browse")),
                ("F", L("отметить", "mark")),
                ("C", L("сравнить", "compare")),
                ("V", L("шторка", "wipe")),
                ("T", L("экран", "zoom")),
                ("⌫", L("корзина", "trash")),
                ("Esc", L("закрыть", "close"))
            ]
        }

        let line = NSMutableAttributedString()
        for (index, pair) in pairs.enumerated() {
            if index > 0 {
                line.append(NSAttributedString(
                    string: "   ·   ",
                    attributes: [
                        .font: FPStyle.bodyFont(ofSize: 10.5, weight: .regular),
                        .foregroundColor: FPStyle.dimText.withAlphaComponent(0.38)
                    ]
                ))
            }
            line.append(NSAttributedString(
                string: pair.0,
                attributes: [
                    .font: FPStyle.monoMetaFont(ofSize: 10.5, weight: .semibold),
                    .foregroundColor: FPStyle.orange
                ]
            ))
            line.append(NSAttributedString(
                string: " " + pair.1,
                attributes: [
                    .font: FPStyle.bodyFont(ofSize: 11, weight: .medium),
                    .foregroundColor: FPStyle.text.withAlphaComponent(0.74)
                ]
            ))
        }
        return line
    }

    func setHintMode(_ mode: HintMode) {
        currentHintMode = mode
        hintBar.attributedStringValue = Self.hintText(for: mode)
    }

    func updateHeaderState(
        indexText: String,
        compareCount: Int,
        isCurtain: Bool,
        isMaximized: Bool
    ) {
        indexLabel.stringValue = indexText
        indexPill.isHidden = indexText.isEmpty

        let compareSymbol = compareCount == 3 ? "rectangle.split.3x1" : "rectangle.split.2x1"
        compareButton.setSymbol(compareSymbol, accessibility: L("Сравнение панелей", "Compare panes"))
        compareButton.isActiveState = compareCount > 1 && !isCurtain
        compareButton.toolTip = L("Сравнить 1 / 2 / 3 кадра (C)", "Compare 1 / 2 / 3 frames (C)")

        curtainButton.isActiveState = isCurtain
        curtainButton.toolTip = L("Сравнение шторкой (V)", "Split wipe compare (V)")

        let maxSymbol = isMaximized
            ? "arrow.down.right.and.arrow.up.left"
            : "arrow.up.left.and.arrow.down.right"
        maximizeButton.setSymbol(maxSymbol, accessibility: L("Во весь экран", "Maximize"))
        maximizeButton.isActiveState = isMaximized
        maximizeButton.toolTip = L("Растянуть на экран (T)", "Toggle full screen size (T)")
    }

    func applyTheme() {
        let aurora = FPStyle.isObsidianAurora
        let cyber = FPStyle.isCyberEditorial
        let tint = FPStyle.text.blended(withFraction: 0.22, of: FPStyle.accent) ?? FPStyle.text

        if aurora {
            auroraBackdropView.refreshTheme()
            auroraBackdropView.isHidden = false
            auroraBackdropView.alphaValue = max(0.84, FPStyle.previewOpacity)
            backgroundGradientView.isHidden = true
            backgroundGradientView.setColors([.clear, .clear])
            backdrop.alphaValue = 1.0
        } else {
            auroraBackdropView.isHidden = true
            backgroundGradientView.isHidden = false
            let opacity = min(max(FPStyle.pane.alphaComponent, 0), 1)
            if cyber {
                backgroundGradientView.setColors(
                    FPStyle.gradientEnabled
                        ? [
                            FPStyle.gradientStart.withAlphaComponent(0.36),
                            FPStyle.window.withAlphaComponent(0.92),
                            FPStyle.gradientEnd.withAlphaComponent(0.32)
                        ]
                        : [
                            FPStyle.window.withAlphaComponent(0.92),
                            FPStyle.window.withAlphaComponent(0.92)
                        ]
                )
            } else {
                let gradientOpacity = min(0.88, 0.62 + opacity * 0.26)
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
            }
            backdrop.alphaValue = FPStyle.previewOpacity
            backgroundGradientView.alphaValue = max(0.75, FPStyle.previewOpacity)
        }

        // Нейтральный тёмный «остров» для точной цветопередачи без просвечивания текста позади.
        let darkroomAlpha = max(0.88, min(0.97, 0.72 + FPStyle.previewOpacity * 0.25))
        stageIsland.layer?.cornerRadius = cyber ? 6 : 16
        if aurora {
            stageIsland.layer?.backgroundColor = NSColor(
                calibratedRed: 0.043,
                green: 0.041,
                blue: 0.052,
                alpha: darkroomAlpha
            ).cgColor
            stageIsland.layer?.borderColor = tint.withAlphaComponent(0.12).cgColor
        } else {
            let darkPane = FPStyle.pane.blended(withFraction: 0.45, of: .black) ?? FPStyle.pane
            stageIsland.layer?.backgroundColor = darkPane.withAlphaComponent(darkroomAlpha).cgColor
            stageIsland.layer?.borderColor = FPStyle.stroke.withAlphaComponent(0.55).cgColor
        }

        indexPill.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        indexPill.layer?.borderColor = (aurora ? tint.withAlphaComponent(0.12) : FPStyle.stroke.withAlphaComponent(0.45)).cgColor
        indexLabel.textColor = FPStyle.dimText

        detailPill.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.045).cgColor
        detailPill.layer?.borderColor = (aurora ? tint.withAlphaComponent(0.10) : FPStyle.stroke.withAlphaComponent(0.45)).cgColor
        detailField.textColor = FPStyle.dimText

        statusPill.layer?.backgroundColor = FPStyle.orange.withAlphaComponent(0.16).cgColor
        statusPill.layer?.borderColor = FPStyle.orange.withAlphaComponent(0.45).cgColor
        copyHint.textColor = FPStyle.orange

        hintPill.layer?.backgroundColor = (aurora
            ? NSColor(calibratedRed: 0.055, green: 0.052, blue: 0.068, alpha: 0.84)
            : FPStyle.bar.withAlphaComponent(0.82)).cgColor
        hintPill.layer?.borderColor = (aurora ? tint.withAlphaComponent(0.12) : FPStyle.stroke.withAlphaComponent(0.55)).cgColor
        hintBar.attributedStringValue = Self.hintText(for: currentHintMode)

        nameButton.toolTip = L("Нажмите, чтобы скопировать имя файла", "Click to copy file name")
        compareButton.applyAppearance()
        curtainButton.applyAppearance()
        maximizeButton.applyAppearance()

        panes.forEach { $0.applyTheme() }
    }

    func setCaption(name: String, detail: String) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byTruncatingMiddle
        nameButton.attributedTitle = NSAttributedString(
            string: name,
            attributes: [
                .font: FPStyle.headingFont(ofSize: 13, weight: .semibold),
                .foregroundColor: FPStyle.text,
                .paragraphStyle: paragraph
            ]
        )
        detailField.stringValue = detail
        detailPill.isHidden = detail.isEmpty
        copyHint.stringValue = ""
        statusPill.isHidden = true
    }

    func flashStatus(_ message: String) {
        let text = message.uppercased()
        copyHint.stringValue = text
        statusPill.isHidden = text.isEmpty
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            if self?.copyHint.stringValue == text {
                self?.copyHint.stringValue = ""
                self?.statusPill.isHidden = true
            }
        }
    }

    @objc private func copyName(_ sender: Any?) {
        let name = nameButton.title
        guard !name.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(name, forType: .string)
        FPActionLog.action("имя файла скопировано", name)
        flashStatus(L("скопировано", "copied"))
    }

    @objc private func comparePressed() {
        onCycleCompare?()
    }

    @objc private func curtainPressed() {
        onToggleCurtain?()
    }

    @objc private func maximizePressed() {
        onToggleMaximize?()
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
        let multi = target > 1
        for (idx, pane) in panes.enumerated() {
            pane.setPaneNumber(idx + 1, multiPane: multi)
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
    private var themeObservers: [NSObjectProtocol] = []

    /// Сетка под окном должна догонять удаление и отметку сразу.
    var onNeedsRefresh: (() -> Void)?

    var isPresenting: Bool { window?.isVisible == true }

    deinit {
        themeObservers.forEach(NotificationCenter.default.removeObserver)
    }

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
        // Раньше здесь стоял acceptsMouseMovedEvents = true — Quick Look так
        // держал панель воспроизведения видео живой при наведении. Тот путь
        // давно не используется: видео и аудио показывает свой плеер (см.
        // FPPlayerLayerView), а не Quick Look, так что флаг остался мёртвым
        // грузом. Ни картинкам, ни PDF, ни тексту через QLPreviewView он
        // тоже не нужен.
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
        contentView.onCycleCompare = { [weak self] in self?.cyclePaneCount() }
        contentView.onToggleCurtain = { [weak self] in self?.toggleCurtain() }
        contentView.onToggleMaximize = { [weak self] in self?.toggleMaximized() }

        let center = NotificationCenter.default
        let refreshUI: (Notification) -> Void = { [weak self] _ in
            guard let self else { return }
            self.contentView.applyTheme()
            self.curtain.applyTheme()
            self.updateTitle()
            self.refreshHeaderState()
        }
        themeObservers = [
            center.addObserver(forName: .fpThemeDidChange, object: nil, queue: .main, using: refreshUI),
            center.addObserver(forName: .fpLanguageDidChange, object: nil, queue: .main, using: refreshUI)
        ]
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
            refreshHeaderState()
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
            pane.onGrabFrameRequested = { [weak self] in self?.grabFocusedVideoFrame() }
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
        refreshHeaderState()
        updateCurtainImages()
        prefetchNeighbors()
        if let url = focusedURL { onIndexChanged?(url) }
    }

    private func refreshHeaderState() {
        let countText: String
        if entries.isEmpty {
            countText = ""
        } else if isCurtainMode {
            countText = L("\(focusedIndex + 1) / \(entries.count) · шторка", "\(focusedIndex + 1) / \(entries.count) · wipe")
        } else if paneCount > 1 {
            countText = "\(focusedIndex + 1) / \(entries.count) · \(paneCount)×"
        } else {
            countText = "\(focusedIndex + 1) / \(entries.count)"
        }
        contentView.updateHeaderState(
            indexText: countText,
            compareCount: paneCount,
            isCurtain: isCurtainMode,
            isMaximized: framedBeforeMaximize != nil
        )

        let mode: FPPreviewContentView.HintMode
        if isCurtainMode {
            mode = .curtain
        } else if paneCount > 1 {
            mode = .compare
        } else if contentView.panes.indices.contains(focusedPane) {
            let pane = contentView.panes[focusedPane]
            if pane.isShowingVideo {
                mode = .video
            } else if pane.isShowingAudio {
                mode = .audio
            } else {
                mode = .image
            }
        } else {
            mode = .image
        }
        contentView.setHintMode(mode)
    }

    private func prefetchNeighbors() {
        let center = focusedIndex
        let candidateIndices = [center + 1, center - 1, center + 2]
        let urls = candidateIndices.compactMap { idx -> URL? in
            entries.indices.contains(idx) ? entries[idx].url : nil
        }
        guard !urls.isEmpty else { return }
        let maxPixels = QyvroPreviewImageCache.targetPixelSize(for: window?.screen)
        QyvroPreviewImageCache.shared.prefetch(urls: urls, maxPixelSize: maxPixels)
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
        let position = L("\(focusedIndex + 1) из \(entries.count)", "\(focusedIndex + 1) of \(entries.count)")
        window?.title = paneCount > 1
            ? L("\(position)  ·  сравнение \(paneCount)", "\(position)  ·  compare \(paneCount)")
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
        let next = FPFinderTagStore.flagLevel(url: url).next
        FPActionLog.action("отметка → \(next)", url.lastPathComponent)
        guard (try? FPFinderTagStore.setFlagLevel(next, on: url)) != nil else {
            NSSound.beep()
            return
        }
        contentView.panes.forEach { $0.refreshFlag() }
        onNeedsRefresh?()
    }

    private func togglePlayback() {
        guard contentView.panes.indices.contains(focusedPane) else { return }
        contentView.panes[focusedPane].togglePlayback()
    }

    private func toggleMute() {
        guard contentView.panes.indices.contains(focusedPane) else { return }
        contentView.panes[focusedPane].toggleMute()
    }

    private func grabFocusedVideoFrame() {
        guard contentView.panes.indices.contains(focusedPane) else { return }
        let pane = contentView.panes[focusedPane]
        guard pane.isShowingVideo else {
            NSSound.beep()
            return
        }
        pane.captureCurrentVideoFrame { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let savedURL):
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                FPActionLog.action("кадр видео → PNG", savedURL.lastPathComponent)
                self.contentView.flashStatus(L("кадр → \(savedURL.lastPathComponent)", "saved → \(savedURL.lastPathComponent)"))
                self.onNeedsRefresh?()
            case .failure:
                NSSound.beep()
                self.contentView.flashStatus(L("ошибка сохранения кадра", "frame grab failed"))
            }
        }
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
            refreshHeaderState()
            return
        }
        framedBeforeMaximize = window.frame
        window.setFrame(visible, display: true, animate: true)
        refreshHeaderState()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        if let visible = (window?.screen ?? NSScreen.main)?.visibleFrame.size {
            window?.maxSize = visible
        }
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
        curtain.applyTheme()
        contentView.mountCurtain(curtain)
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
        curtain.setLabels(
            left: urls[0].lastPathComponent,
            right: urls[1].lastPathComponent
        )
        let limit = Int(max(curtain.bounds.width, 900) * 2)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let images = urls.map { QyvroPreviewImageCache.decodeImage(url: $0, maxPixelSize: limit) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurtainMode, self.curtainLoadedURLs == urls else { return }
                self.curtain.setImages(left: images.first ?? nil, right: images.last ?? nil)
            }
        }
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
        case 1: togglePlayback()                      // S — пауза/воспроизведение
        case 46: toggleMute()                         // M — звук
        case 14: grabFocusedVideoFrame()              // E — снять кадр видео в PNG
        case 8: cyclePaneCount()                      // C
        case 9: toggleCurtain()                       // V — шторка
        case 17: toggleMaximized()                    // T — на весь экран
        case 18, 19, 20:                               // 1, 2, 3 — выбор панели
            guard paneCount > 1 else { return false }
            let requested: Int
            switch event.keyCode {
            case 18: requested = 1
            case 19: requested = 2
            default: requested = 3
            }
            guard requested <= paneCount else { return true }
            focusedPane = requested - 1
            updateFocusRings()
            updateTitle()
            refreshCaption()
            refreshHeaderState()
            if let url = focusedURL { onIndexChanged?(url) }
        default: return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        removeKeyMonitor()
        contentView.panes.forEach { $0.teardown() }
        curtainLoadedURLs = []
        curtain.setImages(left: nil, right: nil)
        curtain.setLabels(left: "", right: "")
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
    private let dividerLine = FPLayerView(color: .clear)
    private let handleGrip = FPLayerView(color: .clear, cornerRadius: 17)
    private let handleIcon = NSImageView()
    private let leftBadge = FPLayerView(color: .clear, cornerRadius: 10)
    private let leftBadgeLabel = NSTextField(labelWithString: "")
    private let rightBadge = FPLayerView(color: .clear, cornerRadius: 10)
    private let rightBadgeLabel = NSTextField(labelWithString: "")
    private var leftName = ""
    private var rightName = ""
    private var position: CGFloat = 0.5
    private var isDragging = false

    /// Подпись рассказывает, что слева и что справа: без неё через минуту
    /// работы уже не помнишь, какой вариант с какой стороны.
    var onPositionChanged: ((CGFloat) -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
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
        dividerLine.translatesAutoresizingMaskIntoConstraints = false
        dividerLine.layer?.shadowColor = NSColor.black.cgColor
        dividerLine.layer?.shadowOpacity = 0.72
        dividerLine.layer?.shadowRadius = 3
        dividerLine.layer?.shadowOffset = .zero

        handleGrip.translatesAutoresizingMaskIntoConstraints = false
        handleGrip.layer?.shadowColor = NSColor.black.cgColor
        handleGrip.layer?.shadowOpacity = 0.55
        handleGrip.layer?.shadowRadius = 8
        handleGrip.layer?.shadowOffset = NSSize(width: 0, height: -2)

        handleIcon.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 11.0, *) {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            handleIcon.image = NSImage(systemSymbolName: "chevron.left.chevron.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
        }

        for (badge, label) in [(leftBadge, leftBadgeLabel), (rightBadge, rightBadgeLabel)] {
            badge.translatesAutoresizingMaskIntoConstraints = false
            badge.layer?.borderWidth = 0.65
            badge.isHidden = true
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            badge.addSubview(label)
        }

        addSubview(rightView)
        addSubview(leftClip)
        leftClip.addSubview(leftView)
        addSubview(leftBadge)
        addSubview(rightBadge)
        addSubview(handle)
        handle.addSubview(dividerLine)
        handle.addSubview(handleGrip)
        handleGrip.addSubview(handleIcon)

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

            leftBadge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            leftBadge.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            leftBadge.heightAnchor.constraint(equalToConstant: 24),
            leftBadge.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
            leftBadgeLabel.leadingAnchor.constraint(equalTo: leftBadge.leadingAnchor, constant: 10),
            leftBadgeLabel.trailingAnchor.constraint(equalTo: leftBadge.trailingAnchor, constant: -10),
            leftBadgeLabel.centerYAnchor.constraint(equalTo: leftBadge.centerYAnchor),

            rightBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            rightBadge.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            rightBadge.heightAnchor.constraint(equalToConstant: 24),
            rightBadge.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
            rightBadgeLabel.leadingAnchor.constraint(equalTo: rightBadge.leadingAnchor, constant: 10),
            rightBadgeLabel.trailingAnchor.constraint(equalTo: rightBadge.trailingAnchor, constant: -10),
            rightBadgeLabel.centerYAnchor.constraint(equalTo: rightBadge.centerYAnchor),

            handle.topAnchor.constraint(equalTo: topAnchor),
            handle.bottomAnchor.constraint(equalTo: bottomAnchor),
            handle.widthAnchor.constraint(equalToConstant: 36),

            dividerLine.centerXAnchor.constraint(equalTo: handle.centerXAnchor),
            dividerLine.topAnchor.constraint(equalTo: handle.topAnchor),
            dividerLine.bottomAnchor.constraint(equalTo: handle.bottomAnchor),
            dividerLine.widthAnchor.constraint(equalToConstant: 1.5),

            handleGrip.centerXAnchor.constraint(equalTo: handle.centerXAnchor),
            handleGrip.centerYAnchor.constraint(equalTo: handle.centerYAnchor),
            handleGrip.widthAnchor.constraint(equalToConstant: 34),
            handleGrip.heightAnchor.constraint(equalToConstant: 34),

            handleIcon.centerXAnchor.constraint(equalTo: handleGrip.centerXAnchor),
            handleIcon.centerYAnchor.constraint(equalTo: handleGrip.centerYAnchor)
        ])
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func applyTheme() {
        let tint = FPStyle.text.blended(withFraction: 0.22, of: FPStyle.accent) ?? FPStyle.text
        layer?.backgroundColor = NSColor.clear.cgColor
        dividerLine.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.84).cgColor
        handleGrip.layer?.backgroundColor = NSColor(calibratedRed: 0.06, green: 0.056, blue: 0.074, alpha: 0.90).cgColor
        handleGrip.layer?.borderColor = FPStyle.orange.withAlphaComponent(0.85).cgColor
        handleGrip.layer?.borderWidth = 1.25
        handleIcon.contentTintColor = FPStyle.text

        for badge in [leftBadge, rightBadge] {
            badge.layer?.backgroundColor = NSColor(calibratedRed: 0.055, green: 0.052, blue: 0.068, alpha: 0.84).cgColor
            badge.layer?.borderColor = tint.withAlphaComponent(0.14).cgColor
        }
        refreshBadges()
    }

    func setLabels(left: String, right: String) {
        leftName = left
        rightName = right
        refreshBadges()
    }

    private func refreshBadges() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        func format(_ tag: String, _ name: String) -> NSAttributedString {
            let line = NSMutableAttributedString()
            line.append(NSAttributedString(
                string: tag,
                attributes: [
                    .font: FPStyle.monoMetaFont(ofSize: 10.5, weight: .bold),
                    .foregroundColor: FPStyle.orange,
                    .paragraphStyle: paragraph
                ]
            ))
            line.append(NSAttributedString(
                string: "  \(name)",
                attributes: [
                    .font: FPStyle.bodyFont(ofSize: 11, weight: .medium),
                    .foregroundColor: FPStyle.text.withAlphaComponent(0.90),
                    .paragraphStyle: paragraph
                ]
            ))
            return line
        }
        leftBadge.isHidden = leftName.isEmpty
        rightBadge.isHidden = rightName.isEmpty
        if !leftName.isEmpty { leftBadgeLabel.attributedStringValue = format("A", leftName) }
        if !rightName.isEmpty { rightBadgeLabel.attributedStringValue = format("B", rightName) }
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
        handle.frame = NSRect(x: split - 18, y: 0, width: 36, height: bounds.height)
    }

    override func resetCursorRects() {
        addCursorRect(handle.frame, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        isDragging = abs(point.x - bounds.width * position) <= 22
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
