import Cocoa
import CryptoKit

/// Один элемент верхнего уровня в отчёте «Где пропало место?».
struct QyvroDiskEntry {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isHidden: Bool
    let bytes: Int64
    let itemCount: Int
}

/// Группа побитово одинаковых файлов (подтверждено SHA-256).
struct QyvroDuplicateGroup {
    let hash: String
    let fileSize: Int64
    /// Отсортированы от самого раннего (оригинал — индекс 0) к более новым копиям.
    var urls: [URL]

    var reclaimableBytes: Int64 {
        fileSize * Int64(max(0, urls.count - 1))
    }
}

/// Потокобезопасный токен отмены фонового сканирования диска.
final class QyvroDiskScanToken {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Быстрый многопоточный сканер веса прямых потомков папки.
///
/// Намеренно включает скрытые папки (`.npm`, `.cache`, `Library` и т. д.),
/// потому что именно в них чаще всего «исчезают» десятки гигабайт на macOS.
enum QyvroDiskScanner {
    /// Служебные точки монтирования в корне `/`, которые при обходе дали бы
    /// двойной подсчёт или зависли на виртуальных файловых системах.
    private static let skippedRootPaths: Set<String> = [
        "/dev",
        "/net",
        "/home",
        "/Volumes",
        "/System/Volumes"
    ]

    static func scan(
        rootURL: URL,
        token: QyvroDiskScanToken = QyvroDiskScanToken(),
        progress: ((Int64, Int) -> Void)? = nil,
        completion: @escaping ([QyvroDiskEntry], Int64) -> Void
    ) {
        let root = rootURL.standardizedFileURL
        DispatchQueue.global(qos: .userInitiated).async {
            let manager = FileManager.default
            let keys: Set<URLResourceKey> = [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .isHiddenKey,
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey,
                .fileSizeKey
            ]
            let children = (try? manager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: []
            )) ?? []

            let lock = NSLock()
            var entries: [QyvroDiskEntry] = []
            var totalBytes: Int64 = 0
            var totalItems = 0
            var lastProgressTime = CFAbsoluteTimeGetCurrent()

            let publishProgress: () -> Void = {
                guard let progress else { return }
                let now = CFAbsoluteTimeGetCurrent()
                lock.lock()
                let shouldEmit = now - lastProgressTime >= 0.12
                let bytesSnapshot = totalBytes
                let itemsSnapshot = totalItems
                if shouldEmit { lastProgressTime = now }
                lock.unlock()
                if shouldEmit {
                    DispatchQueue.main.async {
                        guard !token.isCancelled else { return }
                        progress(bytesSnapshot, itemsSnapshot)
                    }
                }
            }

            let queue = OperationQueue()
            queue.name = "Qyvro.DiskScanner"
            queue.qualityOfService = .userInitiated
            queue.maxConcurrentOperationCount = 4

            for child in children {
                let path = child.standardizedFileURL.path
                if root.path == "/", skippedRootPaths.contains(path) {
                    continue
                }
                let values = try? child.resourceValues(forKeys: keys)
                let isSymlink = values?.isSymbolicLink == true
                let isDir = !isSymlink && values?.isDirectory == true
                let isHidden = values?.isHidden == true || child.lastPathComponent.hasPrefix(".")

                if !isDir {
                    let size = Int64(
                        values?.totalFileAllocatedSize
                            ?? values?.fileAllocatedSize
                            ?? values?.fileSize
                            ?? 0
                    )
                    let entry = QyvroDiskEntry(
                        url: child,
                        name: child.lastPathComponent,
                        isDirectory: false,
                        isHidden: isHidden,
                        bytes: size,
                        itemCount: 1
                    )
                    lock.lock()
                    entries.append(entry)
                    totalBytes += size
                    totalItems += 1
                    lock.unlock()
                    continue
                }

                queue.addOperation {
                    guard !token.isCancelled else { return }
                    let stats = measureDirectory(
                        at: child,
                        token: token,
                        onBatch: { deltaBytes, deltaCount in
                            lock.lock()
                            totalBytes += deltaBytes
                            totalItems += deltaCount
                            lock.unlock()
                            publishProgress()
                        }
                    )
                    guard !token.isCancelled else { return }
                    let entry = QyvroDiskEntry(
                        url: child,
                        name: child.lastPathComponent,
                        isDirectory: true,
                        isHidden: isHidden,
                        bytes: stats.bytes,
                        itemCount: stats.count
                    )
                    lock.lock()
                    entries.append(entry)
                    lock.unlock()
                    publishProgress()
                }
            }

            queue.waitUntilAllOperationsAreFinished()
            guard !token.isCancelled else { return }

            lock.lock()
            let sorted = entries.sorted { lhs, rhs in
                if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            let finalTotal = sorted.reduce(Int64(0)) { $0 + $1.bytes }
            lock.unlock()

            DispatchQueue.main.async {
                guard !token.isCancelled else { return }
                completion(sorted, finalTotal)
            }
        }
    }

    private static func measureDirectory(
        at url: URL,
        token: QyvroDiskScanToken,
        onBatch: (Int64, Int) -> Void
    ) -> (bytes: Int64, count: Int) {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey
        ]
        guard let enumerator = manager.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return (0, 0)
        }

        var bytes: Int64 = 0
        var count = 0
        var batchBytes: Int64 = 0
        var batchCount = 0
        var iterations = 0

        for case let itemURL as URL in enumerator {
            iterations += 1
            if iterations & 255 == 0 {
                if token.isCancelled { return (bytes, count) }
                if batchCount > 0 {
                    onBatch(batchBytes, batchCount)
                    batchBytes = 0
                    batchCount = 0
                }
            }
            let values = try? itemURL.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { continue }
            guard values?.isRegularFile == true else { continue }
            let size = Int64(
                values?.totalFileAllocatedSize
                    ?? values?.fileAllocatedSize
                    ?? values?.fileSize
                    ?? 0
            )
            bytes += size
            count += 1
            batchBytes += size
            batchCount += 1
        }

        if batchCount > 0 {
            onBatch(batchBytes, batchCount)
        }
        return (bytes, count)
    }

    /// Находит самые тяжёлые отдельные файлы внутри `rootURL` (топ `limit` по размеру).
    static func scanLargestFiles(
        rootURL: URL,
        limit: Int = 150,
        token: QyvroDiskScanToken = QyvroDiskScanToken(),
        progress: ((Int64, Int) -> Void)? = nil,
        completion: @escaping ([QyvroDiskEntry], Int64) -> Void
    ) {
        let root = rootURL.standardizedFileURL
        DispatchQueue.global(qos: .userInitiated).async {
            let manager = FileManager.default
            let keys: [URLResourceKey] = [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .isHiddenKey,
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey,
                .fileSizeKey
            ]
            let keySet = Set(keys)
            guard let enumerator = manager.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [],
                errorHandler: { _, _ in true }
            ) else {
                DispatchQueue.main.async { completion([], 0) }
                return
            }

            var collected: [QyvroDiskEntry] = []
            var totalBytes: Int64 = 0
            var scannedCount = 0
            var lastEmit = CFAbsoluteTimeGetCurrent()

            for case let url as URL in enumerator {
                if scannedCount & 255 == 0 {
                    if token.isCancelled { return }
                    let now = CFAbsoluteTimeGetCurrent()
                    if let progress, now - lastEmit >= 0.12 {
                        lastEmit = now
                        let b = totalBytes
                        let c = scannedCount
                        DispatchQueue.main.async {
                            guard !token.isCancelled else { return }
                            progress(b, c)
                        }
                    }
                }
                let path = url.standardizedFileURL.path
                if root.path == "/", skippedRootPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                    enumerator.skipDescendants()
                    continue
                }
                scannedCount += 1
                guard let values = try? url.resourceValues(forKeys: keySet),
                      values.isSymbolicLink != true,
                      values.isRegularFile == true else { continue }
                let size = Int64(
                    values.totalFileAllocatedSize
                        ?? values.fileAllocatedSize
                        ?? values.fileSize
                        ?? 0
                )
                guard size > 0 else { continue }
                totalBytes += size
                collected.append(QyvroDiskEntry(
                    url: url,
                    name: url.lastPathComponent,
                    isDirectory: false,
                    isHidden: values.isHidden == true || url.lastPathComponent.hasPrefix("."),
                    bytes: size,
                    itemCount: 1
                ))
                // Периодически подрезаем буфер, чтобы на сотнях тысяч файлов не
                // раздувать память.
                if collected.count >= limit * 16 {
                    collected.sort { $0.bytes > $1.bytes }
                    collected = Array(collected.prefix(limit))
                }
            }

            guard !token.isCancelled else { return }
            collected.sort { $0.bytes > $1.bytes }
            let top = Array(collected.prefix(limit))
            let topSum = top.reduce(Int64(0)) { $0 + $1.bytes }
            DispatchQueue.main.async {
                guard !token.isCancelled else { return }
                completion(top, max(totalBytes, topSum))
            }
        }
    }

    /// Быстрый трёхступенчатый поиск дубликатов:
    /// 1) группировка по точному размеру файла (отсеивает >98% без чтения диска);
    /// 2) быстрый pre-hash первых 32 КБ + последних 32 КБ;
    /// 3) потоковый полный SHA-256 (чанками по 256 КБ, без пиков памяти).
    static func scanDuplicates(
        rootURL: URL,
        minBytes: Int64 = 512 * 1024,
        token: QyvroDiskScanToken = QyvroDiskScanToken(),
        progress: ((String, Int) -> Void)? = nil,
        completion: @escaping ([QyvroDuplicateGroup]) -> Void
    ) {
        let root = rootURL.standardizedFileURL
        DispatchQueue.global(qos: .userInitiated).async {
            let manager = FileManager.default
            let keys: [URLResourceKey] = [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .creationDateKey
            ]
            let keySet = Set(keys)
            guard let enumerator = manager.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else {
                DispatchQueue.main.async { completion([]) }
                return
            }

            var bySize: [Int64: [(url: URL, created: Date)]] = [:]
            var scanned = 0
            var lastEmit = CFAbsoluteTimeGetCurrent()

            for case let url as URL in enumerator {
                if scanned & 255 == 0 {
                    if token.isCancelled { return }
                    let now = CFAbsoluteTimeGetCurrent()
                    if let progress, now - lastEmit >= 0.14 {
                        lastEmit = now
                        let count = scanned
                        DispatchQueue.main.async {
                            guard !token.isCancelled else { return }
                            progress("Ищу кандидатов по размеру…", count)
                        }
                    }
                }
                let path = url.standardizedFileURL.path
                if root.path == "/", skippedRootPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                    enumerator.skipDescendants()
                    continue
                }
                if path.contains("/.git/") || path.contains("/node_modules/") {
                    continue
                }
                scanned += 1
                guard let values = try? url.resourceValues(forKeys: keySet),
                      values.isSymbolicLink != true,
                      values.isRegularFile == true,
                      let rawSize = values.fileSize else { continue }
                let size = Int64(rawSize)
                guard size >= minBytes else { continue }
                bySize[size, default: []].append((url, values.creationDate ?? .distantFuture))
            }

            let candidateBuckets = bySize.filter { $0.value.count >= 2 }
            guard !token.isCancelled else { return }

            var hashedCount = 0
            var groups: [QyvroDuplicateGroup] = []

            for (size, items) in candidateBuckets.sorted(by: { $0.key > $1.key }) {
                if token.isCancelled { return }
                // Шаг 2: быстрый отпечаток начала и конца файла
                var byQuickHash: [String: [(url: URL, created: Date)]] = [:]
                for entry in items {
                    if token.isCancelled { return }
                    if let quick = partialFingerprint(of: entry.url, fileSize: size) {
                        byQuickHash[quick, default: []].append(entry)
                    }
                }
                // Шаг 3: полный потоковый SHA-256 только для совпавших по pre-hash
                for bucket in byQuickHash.values where bucket.count >= 2 {
                    var byFullHash: [String: [(url: URL, created: Date)]] = [:]
                    for entry in bucket {
                        if token.isCancelled { return }
                        hashedCount += 1
                        let now = CFAbsoluteTimeGetCurrent()
                        if let progress, now - lastEmit >= 0.14 {
                            lastEmit = now
                            let c = hashedCount
                            DispatchQueue.main.async {
                                guard !token.isCancelled else { return }
                                progress("Сверяю SHA-256…", c)
                            }
                        }
                        if let digest = fullSHA256(of: entry.url, token: token) {
                            byFullHash[digest, default: []].append(entry)
                        }
                    }
                    for (digest, matches) in byFullHash where matches.count >= 2 {
                        let sortedURLs = matches
                            .sorted { $0.created < $1.created }
                            .map(\.url)
                        groups.append(QyvroDuplicateGroup(hash: digest, fileSize: size, urls: sortedURLs))
                    }
                }
            }

            guard !token.isCancelled else { return }
            groups.sort { lhs, rhs in
                if lhs.reclaimableBytes != rhs.reclaimableBytes {
                    return lhs.reclaimableBytes > rhs.reclaimableBytes
                }
                return lhs.fileSize > rhs.fileSize
            }
            let finalGroups = Array(groups.prefix(120))
            DispatchQueue.main.async {
                guard !token.isCancelled else { return }
                completion(finalGroups)
            }
        }
    }

    private static func partialFingerprint(of url: URL, fileSize: Int64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunk = 32 * 1024
        if let head = try? handle.read(upToCount: chunk), !head.isEmpty {
            hasher.update(data: head)
        }
        if fileSize > Int64(chunk * 2) {
            do {
                try handle.seek(toOffset: UInt64(fileSize) - UInt64(chunk))
                if let tail = try handle.read(upToCount: chunk), !tail.isEmpty {
                    hasher.update(data: tail)
                }
            } catch {
                return nil
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func fullSHA256(of url: URL, token: QyvroDiskScanToken) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if token.isCancelled { return nil }
            let data = autoreleasepool { try? handle.read(upToCount: 256 * 1024) }
            guard let data, !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Точка входа модуля «Где пропало место?».
final class QyvroDiskAnalyzerModule {
    static let shared = QyvroDiskAnalyzerModule()

    private var controller: QyvroDiskAnalyzerController?
    /// Открывает выбранную папку прямо в основном окне Qyvro.
    var onOpenFolderInExplorer: ((URL) -> Void)?

    func show(rootURL: URL? = nil) {
        let target = (rootURL ?? FileManager.default.homeDirectoryForCurrentUser).standardizedFileURL
        if controller == nil {
            controller = QyvroDiskAnalyzerController { [weak self] url in
                self?.onOpenFolderInExplorer?(url)
            }
        }
        controller?.present(rootURL: target)
    }
}

/// Цветная мини-полоса распределения самых тяжёлых объектов в шапке анализатора.
private final class QyvroDiskDistributionBar: NSView {
    private var shares: [(fraction: CGFloat, color: NSColor)] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(entries: [QyvroDiskEntry], totalBytes: Int64) {
        guard totalBytes > 0, !entries.isEmpty else {
            shares = []
            needsDisplay = true
            return
        }
        var items: [(CGFloat, NSColor)] = []
        var covered: Int64 = 0
        for entry in entries.prefix(5) where entry.bytes > 0 {
            let fraction = CGFloat(entry.bytes) / CGFloat(totalBytes)
            items.append((fraction, Self.color(forShare: fraction)))
            covered += entry.bytes
        }
        let remainder = max(0, totalBytes - covered)
        if remainder > 0 {
            items.append((CGFloat(remainder) / CGFloat(totalBytes), NSColor.white.withAlphaComponent(0.16)))
        }
        shares = items
        needsDisplay = true
    }

    static func color(forShare share: CGFloat) -> NSColor {
        if share >= 0.25 { return FPStyle.orange }
        if share >= 0.10 { return FPStyle.accent }
        if share >= 0.03 { return FPStyle.defaultFolder }
        return FPDiskUsagePalette.other
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4)
        NSColor.white.withAlphaComponent(0.07).setFill()
        track.fill()

        guard !shares.isEmpty, bounds.width > 4 else { return }
        let gap: CGFloat = 1.5
        var x: CGFloat = 0
        for (idx, part) in shares.enumerated() {
            let rawWidth = max(2, part.fraction * bounds.width)
            let drawWidth = max(1.5, rawWidth - (idx + 1 < shares.count ? gap : 0))
            part.color.setFill()
            NSRect(x: x, y: 0, width: drawWidth, height: bounds.height).fill()
            x += rawWidth
        }
    }
}

/// Пропорциональная полоса веса одного элемента в строке анализатора.
private final class QyvroWeightBarView: NSView {
    private var fraction: CGFloat = 0
    private var fillColor: NSColor = FPStyle.accent

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(fraction: CGFloat, color: NSColor) {
        self.fraction = min(max(fraction, 0), 1)
        self.fillColor = color
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        let track = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSColor.white.withAlphaComponent(0.08).setFill()
        track.fill()

        guard fraction > 0.0005 else { return }
        let width = max(4, bounds.width * fraction)
        let fill = NSBezierPath(
            roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height),
            xRadius: radius,
            yRadius: radius
        )
        fillColor.setFill()
        fill.fill()
    }
}

/// Строка результата в окне «Где пропало место?».
private final class QyvroDiskAnalyzerRowView: NSTableCellView {
    private let card = FPLayerView(color: .clear, cornerRadius: 10)
    private let iconView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let hiddenBadge = FPLayerView(color: .clear, cornerRadius: 4)
    private let hiddenLabel = NSTextField(labelWithString: "СКРЫТ.")
    private let subtitleField = NSTextField(labelWithString: "")
    private let weightBar = QyvroWeightBarView()
    private let sizeField = NSTextField(labelWithString: "")
    private let percentField = NSTextField(labelWithString: "")
    private let openButton = NSButton()
    private let finderButton = NSButton()
    private let shelfButton = NSButton()
    private let trashButton = NSButton()

    private var onOpen: (() -> Void)?
    private var onReveal: (() -> Void)?
    private var onShelf: (() -> Void)?
    private var onTrash: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildUI() {
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        nameField.font = FPStyle.bodyFont(ofSize: 12.5, weight: .semibold)
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameField.translatesAutoresizingMaskIntoConstraints = false

        hiddenLabel.font = FPStyle.headingFont(ofSize: 8.5, weight: .bold)
        hiddenLabel.translatesAutoresizingMaskIntoConstraints = false
        hiddenBadge.addSubview(hiddenLabel)
        hiddenBadge.translatesAutoresizingMaskIntoConstraints = false
        hiddenBadge.setContentHuggingPriority(.required, for: .horizontal)
        hiddenBadge.setContentCompressionResistancePriority(.required, for: .horizontal)

        let titleRow = NSStackView(views: [nameField, hiddenBadge])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 6
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        subtitleField.font = .systemFont(ofSize: 10.5, weight: .regular)
        subtitleField.lineBreakMode = .byTruncatingTail
        subtitleField.translatesAutoresizingMaskIntoConstraints = false

        sizeField.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .bold)
        sizeField.alignment = .right
        sizeField.setContentHuggingPriority(.required, for: .horizontal)
        sizeField.translatesAutoresizingMaskIntoConstraints = false

        percentField.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        percentField.alignment = .right
        percentField.setContentHuggingPriority(.required, for: .horizontal)
        percentField.translatesAutoresizingMaskIntoConstraints = false

        configureActionButton(openButton, symbol: "arrow.up.forward.square", tooltip: "Открыть в Qyvro", action: #selector(openPressed(_:)))
        configureActionButton(finderButton, symbol: "folder", tooltip: "Показать в Finder", action: #selector(revealPressed(_:)))
        configureActionButton(shelfButton, symbol: "tray.and.arrow.down", tooltip: "На полку сбора", action: #selector(shelfPressed(_:)))
        configureActionButton(trashButton, symbol: "trash", tooltip: "Переместить в корзину", action: #selector(trashPressed(_:)))

        let actions = NSStackView(views: [openButton, finderButton, shelfButton, trashButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 4
        actions.translatesAutoresizingMaskIntoConstraints = false

        let textColumn = NSStackView(views: [titleRow, subtitleField, weightBar])
        textColumn.orientation = .vertical
        textColumn.alignment = .leading
        textColumn.spacing = 3
        textColumn.translatesAutoresizingMaskIntoConstraints = false

        let sizeColumn = NSStackView(views: [sizeField, percentField])
        sizeColumn.orientation = .vertical
        sizeColumn.alignment = .trailing
        sizeColumn.spacing = 1
        sizeColumn.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(iconView)
        card.addSubview(textColumn)
        card.addSubview(sizeColumn)
        card.addSubview(actions)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            card.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),

            iconView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),

            hiddenLabel.leadingAnchor.constraint(equalTo: hiddenBadge.leadingAnchor, constant: 4),
            hiddenLabel.trailingAnchor.constraint(equalTo: hiddenBadge.trailingAnchor, constant: -4),
            hiddenLabel.topAnchor.constraint(equalTo: hiddenBadge.topAnchor, constant: 1),
            hiddenLabel.bottomAnchor.constraint(equalTo: hiddenBadge.bottomAnchor, constant: -1),

            textColumn.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            textColumn.trailingAnchor.constraint(equalTo: sizeColumn.leadingAnchor, constant: -12),
            textColumn.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            weightBar.widthAnchor.constraint(equalTo: textColumn.widthAnchor),
            weightBar.heightAnchor.constraint(equalToConstant: 5),

            sizeColumn.trailingAnchor.constraint(equalTo: actions.leadingAnchor, constant: -10),
            sizeColumn.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            sizeColumn.widthAnchor.constraint(greaterThanOrEqualToConstant: 74),

            actions.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            actions.centerYAnchor.constraint(equalTo: card.centerYAnchor)
        ])
    }

    private func configureActionButton(_ button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.isBordered = false
        button.bezelStyle = .inline
        button.imagePosition = .imageOnly
        button.toolTip = tooltip
        button.target = self
        button.action = action
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 11.0, *),
           let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) {
            img.size = NSSize(width: 12.5, height: 12.5)
            button.image = img
        }
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    func configure(
        entry: QyvroDiskEntry,
        totalBytes: Int64,
        maxEntryBytes: Int64,
        onOpen: @escaping () -> Void,
        onReveal: @escaping () -> Void,
        onShelf: @escaping () -> Void,
        onTrash: @escaping () -> Void
    ) {
        self.onOpen = onOpen
        self.onReveal = onReveal
        self.onShelf = onShelf
        self.onTrash = onTrash

        card.layer?.backgroundColor = FPStyle.control.cgColor
        card.layer?.borderColor = FPStyle.stroke.cgColor
        card.layer?.borderWidth = 0.6

        if entry.isDirectory, let custom = CustomFolderIconStore.shared.image(for: entry.url) {
            iconView.image = custom
        } else {
            iconView.image = NSWorkspace.shared.icon(forFile: entry.url.path)
        }
        nameField.stringValue = entry.name
        nameField.textColor = FPStyle.text

        hiddenBadge.isHidden = !entry.isHidden
        hiddenBadge.layer?.backgroundColor = FPStyle.dimText.withAlphaComponent(0.16).cgColor
        hiddenLabel.textColor = FPStyle.dimText

        if entry.isDirectory {
            let countText = entry.itemCount == 0
                ? "Пустая папка"
                : "Папка • \(NumberFormatter.localizedString(from: NSNumber(value: entry.itemCount), number: .decimal)) ф. — двойной клик чтобы войти"
            subtitleField.stringValue = countText
        } else {
            let ext = entry.url.pathExtension.uppercased()
            subtitleField.stringValue = ext.isEmpty ? "Файл" : "Файл • \(ext)"
        }
        subtitleField.textColor = FPStyle.dimText

        let share = totalBytes > 0 ? CGFloat(entry.bytes) / CGFloat(totalBytes) : 0
        let barFraction = maxEntryBytes > 0 ? CGFloat(entry.bytes) / CGFloat(maxEntryBytes) : 0
        let barColor = QyvroDiskDistributionBar.color(forShare: share)
        weightBar.configure(fraction: barFraction, color: barColor)

        sizeField.stringValue = ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file)
        sizeField.textColor = share >= 0.25 ? FPStyle.orange : FPStyle.text
        percentField.stringValue = String(format: "%.1f%%", Double(share * 100))
        percentField.textColor = FPStyle.dimText

        for btn in [openButton, finderButton, shelfButton] {
            btn.contentTintColor = FPStyle.dimText
            btn.layer?.backgroundColor = FPStyle.field.withAlphaComponent(0.6).cgColor
        }
        trashButton.contentTintColor = FPStyle.orange
        trashButton.layer?.backgroundColor = FPStyle.orange.withAlphaComponent(0.14).cgColor
    }

    @objc private func openPressed(_ sender: Any?) { onOpen?() }
    @objc private func revealPressed(_ sender: Any?) { onReveal?() }
    @objc private func shelfPressed(_ sender: Any?) { onShelf?() }
    @objc private func trashPressed(_ sender: Any?) { onTrash?() }
}

/// Окно анализатора дискового пространства «Где пропало место?».
final class QyvroDiskAnalyzerController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private enum AnalyzerTab: Int, CaseIterable {
        case folders = 0
        case largestFiles = 1
        case duplicates = 2

        var title: String {
            switch self {
            case .folders: return "Папки"
            case .largestFiles: return "Тяжёлые файлы"
            case .duplicates: return "Дубликаты (SHA-256)"
            }
        }
    }

    private enum DuplicateTableRow {
        case groupHeader(QyvroDuplicateGroup)
        case copyItem(url: URL, size: Int64, isOriginal: Bool, groupHash: String)
    }

    private let backdrop = FPAuxiliaryBackdrop()
    private let headerTitle = NSTextField(labelWithString: "ГДЕ ПРОПАЛО МЕСТО?")
    private let pathField = NSTextField(labelWithString: "")
    private let backButton = NSButton()
    private let targetPopup = NSPopUpButton()
    private let openRootButton = NSButton()
    private let refreshButton = NSButton()
    private let tabControl = NSSegmentedControl(
        labels: AnalyzerTab.allCases.map(\.title),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let cleanDuplicatesButton = NSButton()

    private let summaryCard = FPLayerView(color: .clear, cornerRadius: 12)
    private let spinner = NSProgressIndicator()
    private let summaryTitle = NSTextField(labelWithString: "")
    private let summaryHint = NSTextField(labelWithString: "")
    private let distributionBar = QyvroDiskDistributionBar()

    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "Папка пуста или нет доступа на чтение")

    private let onOpenInExplorer: (URL) -> Void
    private var currentRootURL: URL = FileManager.default.homeDirectoryForCurrentUser
    private var navigationStack: [URL] = []
    private var activeTab: AnalyzerTab = .folders
    private var entries: [QyvroDiskEntry] = []
    private var totalBytes: Int64 = 0
    private var duplicateGroups: [QyvroDuplicateGroup] = []
    private var duplicateRows: [DuplicateTableRow] = []
    private var currentToken: QyvroDiskScanToken?
    private var themeObserver: NSObjectProtocol?

    init(onOpenInExplorer: @escaping (URL) -> Void) {
        self.onOpenInExplorer = onOpenInExplorer
        let panel = EscapeClosingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 740, height: 550),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Где пропало место?"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.minSize = NSSize(width: 580, height: 420)
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init(window: panel)
        buildUI()
        themeObserver = NotificationCenter.default.addObserver(
            forName: .fpThemeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyTheme()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        currentToken?.cancel()
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
    }

    func present(rootURL: URL) {
        navigationStack.removeAll()
        rebuildTargetPopup(selecting: rootURL)
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startScan(at: rootURL)
    }

    private func buildUI() {
        guard let window else { return }
        let root = NSView(frame: window.contentRect(forFrameRect: window.frame))
        root.wantsLayer = true
        window.contentView = root
        root.addSubview(backdrop)

        headerTitle.font = FPStyle.headingFont(ofSize: 11.5, weight: .semibold)
        headerTitle.alignment = .center
        headerTitle.translatesAutoresizingMaskIntoConstraints = false

        configureToolbarButton(backButton, title: "Назад", symbol: "chevron.left", action: #selector(goBack(_:)))
        backButton.isEnabled = false

        targetPopup.translatesAutoresizingMaskIntoConstraints = false
        targetPopup.controlSize = .regular
        targetPopup.target = self
        targetPopup.action = #selector(targetPopupChanged(_:))

        configureToolbarButton(openRootButton, title: "В Qyvro", symbol: "arrow.up.forward.square", action: #selector(openCurrentInExplorer(_:)))
        configureToolbarButton(refreshButton, title: "", symbol: "arrow.clockwise", action: #selector(refreshScan(_:)))
        refreshButton.toolTip = "Пересканировать"

        let controlsRow = NSStackView(views: [backButton, targetPopup, openRootButton, refreshButton])
        controlsRow.orientation = .horizontal
        controlsRow.alignment = .centerY
        controlsRow.spacing = 8
        controlsRow.translatesAutoresizingMaskIntoConstraints = false

        tabControl.selectedSegment = 0
        tabControl.segmentStyle = .rounded
        tabControl.target = self
        tabControl.action = #selector(tabChanged(_:))
        tabControl.translatesAutoresizingMaskIntoConstraints = false

        configureToolbarButton(cleanDuplicatesButton, title: "Очистить лишние копии", symbol: "trash", action: #selector(cleanAllDuplicates(_:)))
        cleanDuplicatesButton.isHidden = true

        let tabsRow = NSStackView(views: [tabControl, NSView(), cleanDuplicatesButton])
        tabsRow.orientation = .horizontal
        tabsRow.alignment = .centerY
        tabsRow.spacing = 8
        tabsRow.translatesAutoresizingMaskIntoConstraints = false

        pathField.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        pathField.lineBreakMode = .byTruncatingHead
        pathField.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        summaryTitle.font = FPStyle.headingFont(ofSize: 13.5, weight: .semibold)
        summaryTitle.translatesAutoresizingMaskIntoConstraints = false

        summaryHint.font = .systemFont(ofSize: 11, weight: .regular)
        summaryHint.lineBreakMode = .byTruncatingTail
        summaryHint.translatesAutoresizingMaskIntoConstraints = false

        let summaryTopRow = NSStackView(views: [spinner, summaryTitle, NSView(), summaryHint])
        summaryTopRow.orientation = .horizontal
        summaryTopRow.alignment = .centerY
        summaryTopRow.spacing = 8
        summaryTopRow.translatesAutoresizingMaskIntoConstraints = false

        summaryCard.addSubview(summaryTopRow)
        summaryCard.addSubview(distributionBar)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("diskEntry"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = 56
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(tableDoubleClicked(_:))

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets()
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = FPStyle.bodyFont(ofSize: 12.5, weight: .medium)
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(headerTitle)
        root.addSubview(controlsRow)
        root.addSubview(tabsRow)
        root.addSubview(pathField)
        root.addSubview(summaryCard)
        root.addSubview(scroll)
        root.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: root.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            headerTitle.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            headerTitle.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            controlsRow.topAnchor.constraint(equalTo: headerTitle.bottomAnchor, constant: 12),
            controlsRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            controlsRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            backButton.heightAnchor.constraint(equalToConstant: 28),
            openRootButton.heightAnchor.constraint(equalToConstant: 28),
            refreshButton.widthAnchor.constraint(equalToConstant: 30),
            refreshButton.heightAnchor.constraint(equalToConstant: 28),

            tabsRow.topAnchor.constraint(equalTo: controlsRow.bottomAnchor, constant: 8),
            tabsRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            tabsRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            cleanDuplicatesButton.heightAnchor.constraint(equalToConstant: 26),

            pathField.topAnchor.constraint(equalTo: tabsRow.bottomAnchor, constant: 6),
            pathField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            pathField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),

            summaryCard.topAnchor.constraint(equalTo: pathField.bottomAnchor, constant: 8),
            summaryCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            summaryCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            summaryTopRow.topAnchor.constraint(equalTo: summaryCard.topAnchor, constant: 10),
            summaryTopRow.leadingAnchor.constraint(equalTo: summaryCard.leadingAnchor, constant: 12),
            summaryTopRow.trailingAnchor.constraint(equalTo: summaryCard.trailingAnchor, constant: -12),

            distributionBar.topAnchor.constraint(equalTo: summaryTopRow.bottomAnchor, constant: 8),
            distributionBar.leadingAnchor.constraint(equalTo: summaryCard.leadingAnchor, constant: 12),
            distributionBar.trailingAnchor.constraint(equalTo: summaryCard.trailingAnchor, constant: -12),
            distributionBar.bottomAnchor.constraint(equalTo: summaryCard.bottomAnchor, constant: -10),
            distributionBar.heightAnchor.constraint(equalToConstant: 8),

            scroll.topAnchor.constraint(equalTo: summaryCard.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)
        ])

        QyvroWindowResizeOverlay.install(
            in: root,
            insets: QyvroWindowResizeInsets(left: 8, right: 8, top: 6, bottom: 8, cornerSize: 14)
        )
        applyTheme()
    }

    private func configureToolbarButton(_ button: NSButton, title: String, symbol: String, action: Selector) {
        button.title = title
        button.isBordered = false
        button.bezelStyle = .inline
        button.font = FPStyle.bodyFont(ofSize: 11.5, weight: .semibold)
        button.target = self
        button.action = action
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        button.imageHugsTitle = true
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        button.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 11.0, *),
           let img = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            img.size = NSSize(width: 13, height: 13)
            button.image = img
        }
        if !title.isEmpty {
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 78).isActive = true
        }
    }

    private func applyTheme() {
        backdrop.applyTheme()
        headerTitle.textColor = FPStyle.dimText
        pathField.textColor = FPStyle.dimText
        summaryCard.layer?.backgroundColor = FPStyle.control.cgColor
        summaryCard.layer?.borderColor = FPStyle.stroke.cgColor
        summaryCard.layer?.borderWidth = 0.75
        summaryTitle.textColor = FPStyle.text
        summaryHint.textColor = FPStyle.dimText
        emptyLabel.textColor = FPStyle.dimText

        for btn in [backButton, openRootButton, refreshButton] {
            btn.contentTintColor = FPStyle.isObsidianAurora ? FPStyle.accent : FPStyle.orange
            btn.layer?.backgroundColor = FPStyle.control.cgColor
            btn.layer?.borderColor = FPStyle.stroke.cgColor
            btn.layer?.borderWidth = 0.6
        }
        let danger = NSColor(calibratedRed: 0.96, green: 0.42, blue: 0.44, alpha: 1)
        cleanDuplicatesButton.contentTintColor = danger
        cleanDuplicatesButton.layer?.backgroundColor = danger.withAlphaComponent(0.14).cgColor
        cleanDuplicatesButton.layer?.borderColor = danger.withAlphaComponent(0.40).cgColor
        cleanDuplicatesButton.layer?.borderWidth = 0.6
        tableView.reloadData()
    }

    private func rebuildTargetPopup(selecting selectedURL: URL) {
        targetPopup.removeAllItems()
        let home = FileManager.default.homeDirectoryForCurrentUser
        var presets: [(String, URL)] = [
            ("Дом (\(home.lastPathComponent))", home),
            ("Library (кэши и данные)", home.appendingPathComponent("Library", isDirectory: true)),
            ("Загрузки", home.appendingPathComponent("Downloads", isDirectory: true)),
            ("Документы", home.appendingPathComponent("Documents", isDirectory: true)),
            ("Программы", URL(fileURLWithPath: "/Applications", isDirectory: true))
        ]
        if let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey],
            options: [.skipHiddenVolumes]
        ) {
            for volume in volumes {
                let name = (try? volume.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? volume.lastPathComponent
                if !name.isEmpty {
                    presets.append(("Диск: \(name)", volume.standardizedFileURL))
                }
            }
        }

        let targetPath = selectedURL.standardizedFileURL.path
        var matchedIndex: Int?
        for (idx, preset) in presets.enumerated() {
            let item = NSMenuItem(title: preset.0, action: nil, keyEquivalent: "")
            item.representedObject = preset.1
            targetPopup.menu?.addItem(item)
            if preset.1.standardizedFileURL.path == targetPath {
                matchedIndex = idx
            }
        }
        if matchedIndex == nil {
            let custom = NSMenuItem(title: "Папка: \(selectedURL.lastPathComponent)", action: nil, keyEquivalent: "")
            custom.representedObject = selectedURL
            targetPopup.menu?.insertItem(custom, at: 0)
            matchedIndex = 0
        }
        targetPopup.menu?.addItem(.separator())
        let choose = NSMenuItem(title: "Выбрать другую папку…", action: nil, keyEquivalent: "")
        choose.representedObject = "choose"
        targetPopup.menu?.addItem(choose)

        if let matchedIndex {
            targetPopup.selectItem(at: matchedIndex)
        }
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        guard let next = AnalyzerTab(rawValue: sender.selectedSegment), next != activeTab else { return }
        activeTab = next
        startScan(at: currentRootURL)
    }

    private func rebuildDuplicateRows() {
        var rows: [DuplicateTableRow] = []
        for group in duplicateGroups where group.urls.count >= 2 {
            rows.append(.groupHeader(group))
            for (idx, url) in group.urls.enumerated() {
                rows.append(.copyItem(url: url, size: group.fileSize, isOriginal: idx == 0, groupHash: group.hash))
            }
        }
        duplicateRows = rows
        let totalReclaimable = duplicateGroups.reduce(Int64(0)) { $0 + $1.reclaimableBytes }
        cleanDuplicatesButton.isHidden = !(activeTab == .duplicates && totalReclaimable > 0)
    }

    private func startScan(at url: URL) {
        currentToken?.cancel()
        let token = QyvroDiskScanToken()
        currentToken = token
        currentRootURL = url.standardizedFileURL
        pathField.stringValue = currentRootURL.path
        backButton.isEnabled = !navigationStack.isEmpty
        entries = []
        totalBytes = 0
        duplicateGroups = []
        duplicateRows = []
        cleanDuplicatesButton.isHidden = true
        tableView.reloadData()
        distributionBar.update(entries: [], totalBytes: 0)
        emptyLabel.isHidden = true

        spinner.startAnimation(nil)

        switch activeTab {
        case .folders:
            summaryTitle.stringValue = "Сканирую папку…"
            summaryHint.stringValue = "Считаю размеры и скрытые кэши"
            FPActionLog.action("анализ диска (папки)", currentRootURL.path)
            QyvroDiskScanner.scan(
                rootURL: currentRootURL,
                token: token,
                progress: { [weak self] bytes, items in
                    guard let self else { return }
                    let sizeText = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                    self.summaryTitle.stringValue = "Найдено: \(sizeText)"
                    self.summaryHint.stringValue = "Проверено файлов: \(NumberFormatter.localizedString(from: NSNumber(value: items), number: .decimal))"
                },
                completion: { [weak self] result, total in
                    guard let self else { return }
                    self.spinner.stopAnimation(nil)
                    self.entries = result
                    self.totalBytes = total
                    let sizeText = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
                    self.summaryTitle.stringValue = "Всего: \(sizeText)"
                    self.summaryHint.stringValue = "Объектов: \(result.count) • Двойной клик открывает папку глубже"
                    self.emptyLabel.stringValue = "Папка пуста или нет доступа на чтение"
                    self.emptyLabel.isHidden = !result.isEmpty
                    self.distributionBar.update(entries: result, totalBytes: total)
                    self.tableView.reloadData()
                }
            )
        case .largestFiles:
            summaryTitle.stringValue = "Ищу самые тяжёлые файлы…"
            summaryHint.stringValue = "Топ-150 крупнейших файлов внутри выбранной папки"
            FPActionLog.action("анализ диска (тяжёлые файлы)", currentRootURL.path)
            QyvroDiskScanner.scanLargestFiles(
                rootURL: currentRootURL,
                limit: 150,
                token: token,
                progress: { [weak self] bytes, count in
                    guard let self else { return }
                    let sizeText = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                    self.summaryTitle.stringValue = "Просканировано: \(sizeText)"
                    self.summaryHint.stringValue = "Файлов: \(NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal))"
                },
                completion: { [weak self] result, total in
                    guard let self else { return }
                    self.spinner.stopAnimation(nil)
                    self.entries = result
                    self.totalBytes = total
                    let topSum = result.reduce(Int64(0)) { $0 + $1.bytes }
                    self.summaryTitle.stringValue = "Топ \(result.count) файлов: \(ByteCountFormatter.string(fromByteCount: topSum, countStyle: .file))"
                    self.summaryHint.stringValue = "Двойной клик открывает папку файла в Qyvro"
                    self.emptyLabel.stringValue = "Файлов не найдено"
                    self.emptyLabel.isHidden = !result.isEmpty
                    self.distributionBar.update(entries: result, totalBytes: max(topSum, 1))
                    self.tableView.reloadData()
                }
            )
        case .duplicates:
            summaryTitle.stringValue = "Ищу дубликаты (SHA-256)…"
            summaryHint.stringValue = "Проверяю файлы от 512 КБ по размеру и контрольной сумме"
            FPActionLog.action("анализ диска (дубликаты)", currentRootURL.path)
            QyvroDiskScanner.scanDuplicates(
                rootURL: currentRootURL,
                minBytes: 512 * 1024,
                token: token,
                progress: { [weak self] stage, count in
                    guard let self else { return }
                    self.summaryTitle.stringValue = stage
                    self.summaryHint.stringValue = "Проверено: \(NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal))"
                },
                completion: { [weak self] groups in
                    guard let self else { return }
                    self.spinner.stopAnimation(nil)
                    self.duplicateGroups = groups
                    self.rebuildDuplicateRows()
                    let reclaimable = groups.reduce(Int64(0)) { $0 + $1.reclaimableBytes }
                    let extraCopies = groups.reduce(0) { $0 + max(0, $1.urls.count - 1) }
                    if groups.isEmpty {
                        self.summaryTitle.stringValue = "Дубликатов не найдено"
                        self.summaryHint.stringValue = "В этой папке нет побитово одинаковых файлов от 512 КБ"
                        self.emptyLabel.stringValue = "Чисто — дубликатов нет"
                        self.emptyLabel.isHidden = false
                    } else {
                        let sizeText = ByteCountFormatter.string(fromByteCount: reclaimable, countStyle: .file)
                        self.summaryTitle.stringValue = "Можно освободить: \(sizeText)"
                        self.summaryHint.stringValue = "Групп дубликатов: \(groups.count) • Лишних копий: \(extraCopies) (оригинал сохраняется)"
                        self.emptyLabel.isHidden = true
                    }
                    let barEntries = groups.map {
                        QyvroDiskEntry(url: $0.urls[0], name: $0.urls[0].lastPathComponent, isDirectory: false, isHidden: false, bytes: $0.reclaimableBytes, itemCount: $0.urls.count)
                    }
                    self.distributionBar.update(entries: barEntries, totalBytes: max(reclaimable, 1))
                    self.tableView.reloadData()
                }
            )
        }
    }

    @objc private func goBack(_ sender: Any?) {
        guard let previous = navigationStack.popLast() else { return }
        rebuildTargetPopup(selecting: previous)
        startScan(at: previous)
    }

    @objc private func targetPopupChanged(_ sender: NSPopUpButton) {
        guard let represented = sender.selectedItem?.representedObject else { return }
        if let flag = represented as? String, flag == "choose" {
            let openPanel = NSOpenPanel()
            openPanel.canChooseFiles = false
            openPanel.canChooseDirectories = true
            openPanel.allowsMultipleSelection = false
            openPanel.directoryURL = currentRootURL
            if openPanel.runModal() == .OK, let url = openPanel.url {
                navigationStack.removeAll()
                rebuildTargetPopup(selecting: url)
                startScan(at: url)
            } else {
                rebuildTargetPopup(selecting: currentRootURL)
            }
            return
        }
        if let url = represented as? URL {
            navigationStack.removeAll()
            startScan(at: url)
        }
    }

    @objc private func openCurrentInExplorer(_ sender: Any?) {
        onOpenInExplorer(currentRootURL)
    }

    @objc private func refreshScan(_ sender: Any?) {
        startScan(at: currentRootURL)
    }

    @objc private func tableDoubleClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        if activeTab == .duplicates {
            guard duplicateRows.indices.contains(row) else { return }
            if case .copyItem(let url, _, _, _) = duplicateRows[row] {
                onOpenInExplorer(url)
            }
            return
        }
        guard entries.indices.contains(row) else { return }
        let entry = entries[row]
        if entry.isDirectory && activeTab == .folders {
            navigationStack.append(currentRootURL)
            rebuildTargetPopup(selecting: entry.url)
            startScan(at: entry.url)
        } else {
            onOpenInExplorer(entry.url)
        }
    }

    @objc private func cleanAllDuplicates(_ sender: Any?) {
        let copies = duplicateGroups.flatMap { Array($0.urls.dropFirst()) }
        guard !copies.isEmpty else { return }
        let reclaimable = duplicateGroups.reduce(Int64(0)) { $0 + $1.reclaimableBytes }
        let sizeText = ByteCountFormatter.string(fromByteCount: reclaimable, countStyle: .file)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Переместить \(copies.count) лишних копий в корзину?"
        alert.informativeText = "В каждой группе останется 1 самый ранний оригинал. Освободится \(sizeText) (отменяется через ⌘Z или корзину)."
        alert.addButton(withTitle: "В корзину (\(copies.count))")
        alert.addButton(withTitle: "Отмена")

        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            var records: [QyvroTrashRecord] = []
            for url in copies {
                var trashed: NSURL?
                if (try? FileManager.default.trashItem(at: url, resultingItemURL: &trashed)) != nil,
                   let trashedURL = trashed as URL? {
                    records.append(QyvroTrashRecord(original: url, trashURL: trashedURL))
                    DirectorySnapshotCache.shared.invalidate(url.deletingLastPathComponent())
                }
            }
            if !records.isEmpty {
                QyvroFileOperationHistory.shared.recordTrash(records)
                FPDiskUsage.refreshCapacity()
            }
            self.startScan(at: self.currentRootURL)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    private func trashDuplicateCopy(_ url: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Переместить копию «\(url.lastPathComponent)» в корзину?"
        alert.informativeText = url.deletingLastPathComponent().path
        alert.addButton(withTitle: "В корзину")
        alert.addButton(withTitle: "Отмена")

        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            var trashed: NSURL?
            if (try? FileManager.default.trashItem(at: url, resultingItemURL: &trashed)) != nil {
                if let trashedURL = trashed as URL? {
                    QyvroFileOperationHistory.shared.recordTrash([QyvroTrashRecord(original: url, trashURL: trashedURL)])
                }
                DirectorySnapshotCache.shared.invalidate(url.deletingLastPathComponent())
                for idx in self.duplicateGroups.indices {
                    self.duplicateGroups[idx].urls.removeAll { $0 == url }
                }
                self.duplicateGroups.removeAll { $0.urls.count < 2 }
                self.rebuildDuplicateRows()
                let reclaimable = self.duplicateGroups.reduce(Int64(0)) { $0 + $1.reclaimableBytes }
                self.summaryTitle.stringValue = self.duplicateGroups.isEmpty
                    ? "Дубликатов не осталось"
                    : "Можно освободить: \(ByteCountFormatter.string(fromByteCount: reclaimable, countStyle: .file))"
                self.emptyLabel.isHidden = !self.duplicateGroups.isEmpty
                self.tableView.reloadData()
                FPDiskUsage.refreshCapacity()
            }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    private func trashEntry(at row: Int) {
        guard entries.indices.contains(row) else { return }
        let entry = entries[row]
        let sizeText = ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Переместить «\(entry.name)» в корзину?"
        alert.informativeText = "Освободится примерно \(sizeText) (после очистки корзины). Файл можно будет вернуть из корзины."
        alert.addButton(withTitle: "В корзину")
        alert.addButton(withTitle: "Отмена")

        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                var trashedURL: NSURL?
                try FileManager.default.trashItem(at: entry.url, resultingItemURL: &trashedURL)
                if let trashed = trashedURL as URL? {
                    QyvroFileOperationHistory.shared.recordTrash([
                        QyvroTrashRecord(original: entry.url, trashURL: trashed)
                    ])
                }
                DirectorySnapshotCache.shared.invalidate(self.currentRootURL)
                if let idx = self.entries.firstIndex(where: { $0.url == entry.url }) {
                    let removed = self.entries.remove(at: idx)
                    self.totalBytes = max(0, self.totalBytes - removed.bytes)
                    self.summaryTitle.stringValue = "Всего: \(ByteCountFormatter.string(fromByteCount: self.totalBytes, countStyle: .file))"
                    self.summaryHint.stringValue = "Освобождено: \(sizeText) • Объектов: \(self.entries.count)"
                    self.distributionBar.update(entries: self.entries, totalBytes: self.totalBytes)
                    self.emptyLabel.isHidden = !self.entries.isEmpty
                    self.tableView.reloadData()
                }
                FPDiskUsage.refreshCapacity()
            } catch {
                let err = NSAlert()
                err.alertStyle = .warning
                err.messageText = "Не удалось переместить в корзину"
                err.informativeText = error.localizedDescription
                err.runModal()
            }
        }

        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        activeTab == .duplicates ? duplicateRows.count : entries.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if activeTab == .duplicates, duplicateRows.indices.contains(row) {
            if case .groupHeader = duplicateRows[row] { return 30 }
            return 44
        }
        return 56
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if activeTab == .duplicates {
            guard duplicateRows.indices.contains(row) else { return nil }
            switch duplicateRows[row] {
            case .groupHeader(let group):
                let cell = NSTableCellView()
                let sizeText = ByteCountFormatter.string(fromByteCount: group.fileSize, countStyle: .file)
                let saveText = ByteCountFormatter.string(fromByteCount: group.reclaimableBytes, countStyle: .file)
                let label = NSTextField(labelWithString: "\(group.urls.count) одинаковых файла · по \(sizeText) · можно освободить \(saveText)")
                label.font = FPStyle.headingFont(ofSize: 11.5, weight: .semibold)
                label.textColor = FPStyle.accent
                label.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(label)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                    label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
                    label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -4)
                ])
                return cell
            case .copyItem(let url, let size, let isOriginal, _):
                let id = NSUserInterfaceItemIdentifier("QyvroDuplicateRow")
                let cell = (tableView.makeView(withIdentifier: id, owner: self) as? QyvroDiskAnalyzerRowView)
                    ?? QyvroDiskAnalyzerRowView(frame: .zero)
                cell.identifier = id
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                let parentPath = url.deletingLastPathComponent().path.replacingOccurrences(of: home, with: "~")
                let badge = isOriginal ? " [оригинал]" : " [копия]"
                let entry = QyvroDiskEntry(
                    url: url,
                    name: "\(url.lastPathComponent)\(badge)  ·  \(parentPath)",
                    isDirectory: false,
                    isHidden: false,
                    bytes: size,
                    itemCount: 1
                )
                cell.configure(
                    entry: entry,
                    totalBytes: max(size * 2, 1),
                    maxEntryBytes: max(size, 1),
                    onOpen: { [weak self] in self?.onOpenInExplorer(url) },
                    onReveal: { NSWorkspace.shared.activateFileViewerSelecting([url]) },
                    onShelf: { QyvroDropShelfModule.shared.add(urls: [url], reveal: false) },
                    onTrash: { [weak self] in self?.trashDuplicateCopy(url) }
                )
                return cell
            }
        }
        guard entries.indices.contains(row) else { return nil }
        let entry = entries[row]
        let id = NSUserInterfaceItemIdentifier("QyvroDiskAnalyzerRow")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? QyvroDiskAnalyzerRowView)
            ?? QyvroDiskAnalyzerRowView(frame: .zero)
        cell.identifier = id
        let maxBytes = entries.first?.bytes ?? entry.bytes
        let displayEntry: QyvroDiskEntry
        if activeTab == .largestFiles {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let relDir = entry.url.deletingLastPathComponent().path.replacingOccurrences(of: home, with: "~")
            displayEntry = QyvroDiskEntry(
                url: entry.url,
                name: "\(entry.name)  ·  \(relDir)",
                isDirectory: false,
                isHidden: entry.isHidden,
                bytes: entry.bytes,
                itemCount: 1
            )
        } else {
            displayEntry = entry
        }
        cell.configure(
            entry: displayEntry,
            totalBytes: totalBytes,
            maxEntryBytes: maxBytes,
            onOpen: { [weak self] in
                self?.onOpenInExplorer(entry.url)
            },
            onReveal: {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            },
            onShelf: {
                QyvroDropShelfModule.shared.add(urls: [entry.url], reveal: false)
            },
            onTrash: { [weak self] in
                guard let self, let currentRow = self.entries.firstIndex(where: { $0.url == entry.url }) else { return }
                self.trashEntry(at: currentRow)
            }
        )
        return cell
    }
}
