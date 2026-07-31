import Cocoa
import ImageIO
import UniformTypeIdentifiers
import CoreImage
import AVFoundation
import Carbon.HIToolbox
let appDisplayName = "Qyvro"

struct FileItem: Codable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64?
    let created: Date?
    let modified: Date?
    let kind: String
    let isHidden: Bool
    let finderTags: [FPFinderTag]?
}

struct FPQuickLookGalleryEntry {
    let url: URL
    let visualIndex: Int
}

struct FPQuickLookRequest {
    let entries: [FPQuickLookGalleryEntry]
    let initialIndex: Int
    let columnCount: Int
    let onIndexChanged: ((URL) -> Void)?
    /// Запрос от простого выбора файла в сетке: он подставляет кадр в уже
    /// открытый просмотрщик, но сам его не открывает. Иначе каждое нажатие
    /// на файл распахивало бы окно просмотра.
    var updatesOpenPreviewOnly: Bool = false
    /// Ровно два выделенных файла открываются сразу шторкой: это и есть
    /// понятный способ сказать «сравни вот эти два».
    var opensAsCurtain: Bool = false
    /// Второй кадр для шторки: выделенные файлы могут стоять в ленте далеко
    /// друг от друга, поэтому соседним индексом его не угадать.
    var curtainSecondIndex: Int?
}

enum FPDirectorySizeCalculator {
    static func calculate(urls: [URL], completion: @escaping (Result<Int64, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var total: Int64 = 0
            let keys: Set<URLResourceKey> = [
                .isRegularFileKey,
                .fileSizeKey,
                .fileAllocatedSizeKey,
                .totalFileAllocatedSizeKey
            ]
            for folder in urls {
                    guard let enumerator = FileManager.default.enumerator(
                        at: folder,
                        includingPropertiesForKeys: Array(keys),
                        options: [],
                    errorHandler: { _, _ in true }
                ) else {
                    continue
                }
                for case let fileURL as URL in enumerator {
                    autoreleasepool {
                        guard let values = try? fileURL.resourceValues(forKeys: keys),
                              values.isRegularFile == true else { return }
                        total += Int64(
                            values.totalFileAllocatedSize
                                ?? values.fileAllocatedSize
                                ?? values.fileSize
                                ?? 0
                        )
                    }
                }
            }
            DispatchQueue.main.async { completion(.success(total)) }
        }
    }
}

enum FPImageConversionTarget {
    case png
    case jpeg

    var pathExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        }
    }
}

enum FPImageConverter {
    private static let queue = DispatchQueue(label: "Qyvro.ImageConversion", qos: .userInitiated)

    static func convert(
        urls: [URL],
        to target: FPImageConversionTarget,
        completion: @escaping (Result<[URL], Error>) -> Void
    ) {
        queue.async {
            do {
                let context = CIContext(options: [.cacheIntermediates: false])
                guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
                    throw conversionError("Не удалось создать цветовое пространство sRGB")
                }
                var outputs: [URL] = []
                for sourceURL in urls {
                    guard var image = CIImage(
                        contentsOf: sourceURL,
                        options: [.applyOrientationProperty: true]
                    ) else {
                        throw conversionError("Не удалось прочитать \(sourceURL.lastPathComponent)")
                    }
                    let extent = image.extent.integral
                    guard !extent.isInfinite, !extent.isEmpty else {
                        throw conversionError("Некорректный размер \(sourceURL.lastPathComponent)")
                    }
                    image = image.transformed(
                        by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y)
                    )
                    let destination = uniqueDestination(for: sourceURL, extension: target.pathExtension)
                    switch target {
                    case .png:
                        try context.writePNGRepresentation(
                            of: image,
                            to: destination,
                            format: .RGBA8,
                            colorSpace: colorSpace
                        )
                    case .jpeg:
                        // JPEG has no alpha channel. Compositing over white
                        // prevents transparent PNGs from unexpectedly becoming black.
                        let white = CIImage(color: .white).cropped(to: image.extent)
                        let flattened = image.composited(over: white)
                        try context.writeJPEGRepresentation(
                            of: flattened,
                            to: destination,
                            colorSpace: colorSpace,
                            options: [
                                CIImageRepresentationOption(
                                    rawValue: kCGImageDestinationLossyCompressionQuality as String
                                ): 0.92
                            ]
                        )
                    }
                    outputs.append(destination)
                }
                DispatchQueue.main.async { completion(.success(outputs)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private static func uniqueDestination(for source: URL, extension newExtension: String) -> URL {
        let folder = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        var destination = folder.appendingPathComponent("\(base).\(newExtension)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(base) \(suffix).\(newExtension)")
            suffix += 1
        }
        return destination
    }

    private static func conversionError(_ message: String) -> Error {
        NSError(
            domain: "Qyvro.ImageConversion",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

/// Разрешение и длительность файла для подписи под плиткой.
///
/// Читается вне главного потока и кэшируется: в папке на полторы тысячи
/// файлов синхронный разбор заголовков подвесил бы прокрутку. Ключ кэша
/// включает дату изменения, поэтому пересохранённый файл читается заново.
struct FPMediaInfo {
    let pixelWidth: Int
    let pixelHeight: Int
    /// Секунды; заполняется только для видео и звука.
    let duration: Double?

    var pixelSizeText: String { "\(pixelWidth)×\(pixelHeight)" }

    var durationText: String? {
        guard let duration, duration.isFinite, duration >= 1 else { return nil }
        let total = Int(duration.rounded())
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

/// Подпись под плиткой: тип, разрешение, длительность, вес — одной строкой.
///
/// Разрешение встаёт на место слова «Изображение»: строка остаётся одна,
/// высота плитки не меняется, а число, по которому идёт вся работа с
/// лимитами сервисов, видно без захода в свойства.
enum FPTileCaption {
    static func shortKind(for item: FileItem) -> String {
        let ext = item.url.pathExtension.uppercased()
        return ext.isEmpty ? item.kind : ext
    }

    static func text(for item: FileItem, media: FPMediaInfo?) -> String {
        if item.isDirectory { return "Папка" }
        var parts: [String] = []
        if let media {
            // Тип не дублируется: расширение уже видно в имени строкой выше.
            // У видео к разрешению добавляется длительность, и вчетвером
            // (тип, разрешение, время, вес) строка не влезала в ширину
            // плитки — её обрезало посередине.
            parts.append(media.pixelSizeText)
            if let duration = media.durationText { parts.append(duration) }
        } else {
            parts.append(shortKind(for: item))
        }
        if let size = item.size {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        return parts.joined(separator: " • ")
    }
}

enum FPMediaInfoCache {
    private static let lock = NSLock()
    private static var storage: [String: FPMediaInfo] = [:]
    private static var inFlight: Set<String> = []
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
        return queue
    }()

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "webp", "gif", "bmp"
    ]
    static let movieExtensions: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mkv", "webm"
    ]

    static func isSupported(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return imageExtensions.contains(ext) || movieExtensions.contains(ext)
    }

    private static func key(for url: URL, modified: Date?) -> String {
        "\(url.standardizedFileURL.path)|\(modified?.timeIntervalSince1970 ?? 0)"
    }

    static func cached(for url: URL, modified: Date?) -> FPMediaInfo? {
        let cacheKey = key(for: url, modified: modified)
        lock.lock()
        defer { lock.unlock() }
        return storage[cacheKey]
    }

    /// Ставит чтение в очередь. `completion` вызывается на главном потоке
    /// только если что-то удалось прочитать.
    static func load(
        for url: URL,
        modified: Date?,
        completion: @escaping (FPMediaInfo) -> Void
    ) {
        guard isSupported(url) else { return }
        let cacheKey = key(for: url, modified: modified)
        lock.lock()
        if let existing = storage[cacheKey] {
            lock.unlock()
            completion(existing)
            return
        }
        guard !inFlight.contains(cacheKey) else {
            lock.unlock()
            return
        }
        inFlight.insert(cacheKey)
        lock.unlock()

        queue.addOperation {
            let info = read(url)
            lock.lock()
            inFlight.remove(cacheKey)
            if let info { storage[cacheKey] = info }
            lock.unlock()
            guard let info else { return }
            DispatchQueue.main.async { completion(info) }
        }
    }

    private static func read(_ url: URL) -> FPMediaInfo? {
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) {
            // Заголовок читается без декодирования пикселей.
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                    as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
            return FPMediaInfo(pixelWidth: width, pixelHeight: height, duration: nil)
        }
        guard movieExtensions.contains(ext) else { return nil }
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { return nil }
        // preferredTransform учитывает поворот: вертикальное видео обязано
        // показываться как 1080×1920, а не как 1920×1080.
        let natural = track.naturalSize.applying(track.preferredTransform)
        let width = Int(abs(natural.width).rounded())
        let height = Int(abs(natural.height).rounded())
        guard width > 0, height > 0 else { return nil }
        let seconds = CMTimeGetSeconds(asset.duration)
        return FPMediaInfo(
            pixelWidth: width,
            pixelHeight: height,
            duration: seconds.isFinite ? seconds : nil
        )
    }

    static func removeAll() {
        lock.lock()
        storage.removeAll(keepingCapacity: false)
        lock.unlock()
    }
}

/// Уменьшение картинок до заданной длинной стороны.
///
/// Пропорции сохраняются, оригинал не трогается — результат кладётся рядом с
/// суффиксом `_maxN`. Работа идёт через `sips`, как в исходной утилите
/// MaxSide5999: он умеет все растровые форматы, которые показывает Qyvro,
/// включая те, для которых у Core Image нет писателя (webp, gif).
enum FPImageResizer {
    /// Готовые пресеты для подменю. 5999 — исходный сценарий: многие стоки и
    /// соцсети отклоняют изображения от 6000px по любой стороне.
    static let presetMaxSides: [Int] = [5999, 4096, 2560, 2048, 1024]

    static let supportedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "webp", "gif", "bmp"
    ]

    struct Outcome {
        var resized: [URL] = []
        /// Файлы, которые и так были не больше лимита.
        var skipped: [String] = []
        var failed: [String] = []
    }

    private static let queue = DispatchQueue(label: "Qyvro.ImageResize", qos: .userInitiated)

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    static func resize(
        urls: [URL],
        maxSide: Int,
        completion: @escaping (Outcome) -> Void
    ) {
        queue.async {
            var outcome = Outcome()
            for sourceURL in urls {
                let name = sourceURL.lastPathComponent
                guard let pixelSize = pixelSize(of: sourceURL) else {
                    outcome.failed.append(name)
                    continue
                }
                guard Int(max(pixelSize.width, pixelSize.height).rounded()) > maxSide else {
                    outcome.skipped.append(name)
                    continue
                }
                guard let destination = availableDestination(for: sourceURL, maxSide: maxSide) else {
                    outcome.failed.append(name)
                    continue
                }
                if runSips(source: sourceURL, destination: destination, maxSide: maxSide) {
                    outcome.resized.append(destination)
                } else {
                    try? FileManager.default.removeItem(at: destination)
                    outcome.failed.append(name)
                }
            }
            let result = outcome
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0,
              height.doubleValue > 0 else { return nil }
        return CGSize(width: width.doubleValue, height: height.doubleValue)
    }

    private static func availableDestination(for source: URL, maxSide: Int) -> URL? {
        let folder = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        let fileManager = FileManager.default

        var candidate = folder.appendingPathComponent("\(base)_max\(maxSide)").appendingPathExtension(ext)
        if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        for index in 1...9_999 {
            candidate = folder
                .appendingPathComponent("\(base)_max\(maxSide)_\(index)")
                .appendingPathExtension(ext)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// `sips` сам определяет входной формат, но без явного `-s format` он для
    /// части расширений пишет результат в формате по умолчанию. Задаём формат
    /// там, где он однозначно выводится из расширения.
    private static func sipsFormat(for pathExtension: String) -> String? {
        switch pathExtension.lowercased() {
        case "jpg", "jpeg": return "jpeg"
        case "png": return "png"
        case "tif", "tiff": return "tiff"
        case "heic", "heif": return "heic"
        case "gif": return "gif"
        default: return nil
        }
    }

    private static func runSips(source: URL, destination: URL, maxSide: Int) -> Bool {
        var arguments: [String] = []
        if let format = sipsFormat(for: source.pathExtension) {
            arguments += ["-s", "format", format]
        }
        arguments += ["-Z", String(maxSide), source.path, "--out", destination.path]

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return false
        }
        return task.terminationStatus == 0
            && FileManager.default.fileExists(atPath: destination.path)
    }
}

final class DirectorySnapshotCache {
    private struct Entry: Codable {
        let savedAt: Date
        let directoryModified: Date?
        let items: [FileItem]
    }

    static let shared = DirectorySnapshotCache()
    private let lock = NSLock()
    private let persistenceQueue = DispatchQueue(label: "Qyvro.DirectoryCache", qos: .utility)
    private let fileURL: URL
    private var entries: [String: Entry] = [:]

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("Qyvro", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("directory-snapshots-v2.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        }
    }

    func items(for url: URL, includeHidden: Bool) -> [FileItem]? {
        let key = cacheKey(url: url, includeHidden: includeHidden)
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key], Date().timeIntervalSince(entry.savedAt) < 60 * 60 else { return nil }
        if let cachedModified = entry.directoryModified, let modified, abs(cachedModified.timeIntervalSince(modified)) > 0.5 {
            return nil
        }
        return entry.items
    }

    func staleItems(for url: URL, includeHidden: Bool) -> [FileItem]? {
        let key = cacheKey(url: url, includeHidden: includeHidden)
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key], Date().timeIntervalSince(entry.savedAt) < 24 * 60 * 60 else { return nil }
        return entry.items
    }

    func store(_ items: [FileItem], for url: URL, includeHidden: Bool) {
        let key = cacheKey(url: url, includeHidden: includeHidden)
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        lock.lock()
        entries[key] = Entry(savedAt: Date(), directoryModified: modified, items: items)
        if entries.count > 24,
           let oldest = entries.min(by: { $0.value.savedAt < $1.value.savedAt })?.key {
            entries.removeValue(forKey: oldest)
        }
        let snapshot = entries
        lock.unlock()

        let fileURL = self.fileURL
        persistenceQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func invalidate(_ url: URL) {
        let prefix = url.standardizedFileURL.path + "|"
        lock.lock()
        entries = entries.filter { !$0.key.hasPrefix(prefix) }
        let snapshot = entries
        lock.unlock()
        let fileURL = self.fileURL
        persistenceQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func cacheKey(url: URL, includeHidden: Bool) -> String {
        "\(url.standardizedFileURL.path)|\(includeHidden ? 1 : 0)"
    }
}

final class ThumbnailDiskCache {
    static let shared = ThumbnailDiskCache()

    private let memory = NSCache<NSString, NSImage>()
    private let ioQueue = DispatchQueue(label: "Qyvro.ThumbnailDiskCache", qos: .utility)
    private let folderURL: URL

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        folderURL = base.appendingPathComponent("Qyvro/Thumbnails-v3", isDirectory: true)
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        memory.countLimit = 900
        memory.totalCostLimit = 220 * 1024 * 1024
        trimDiskCacheIfNeeded()
    }

    func image(for key: String) -> NSImage? {
        memory.object(forKey: key as NSString)
    }

    func loadFromDisk(for key: String, completion: @escaping (NSImage?) -> Void) {
        if let image = image(for: key) {
            completion(image)
            return
        }
        let url = cacheURL(for: key)
        ioQueue.async { [weak self] in
            guard let self else { return }
            let image = autoreleasepool { NSImage(contentsOf: url) }
            if let image {
                self.memory.setObject(image, forKey: key as NSString, cost: self.cost(of: image))
            }
            DispatchQueue.main.async { completion(image) }
        }
    }

    func store(_ image: NSImage, for key: String) {
        memory.setObject(image, forKey: key as NSString, cost: cost(of: image))
        let url = cacheURL(for: key)
        ioQueue.async {
            autoreleasepool {
                guard let tiff = image.tiffRepresentation else { return }
                guard let bitmap = NSBitmapImageRep(data: tiff),
                      let data = bitmap.representation(using: .png, properties: [:]) else { return }
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    func removeAll() {
        memory.removeAllObjects()
        let folderURL = self.folderURL
        ioQueue.async {
            try? FileManager.default.removeItem(at: folderURL)
            try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        }
    }

    private func cacheURL(for key: String) -> URL {
        folderURL.appendingPathComponent(String(format: "%016llx.png", stableHash(key)))
    }

    private func stableHash(_ value: String) -> UInt64 {
        value.utf8.reduce(UInt64(1469598103934665603)) { hash, byte in
            (hash ^ UInt64(byte)) &* 1099511628211
        }
    }

    private func cost(of image: NSImage) -> Int {
        let size = image.size
        return max(1, Int(size.width * size.height * 4))
    }

    private func trimDiskCacheIfNeeded() {
        let folderURL = self.folderURL
        ioQueue.async {
            let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ), files.count > 1800 else { return }
            let sorted = files.sorted {
                let left = (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                return left < right
            }
            for file in sorted.prefix(max(0, files.count - 1400)) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}

final class WorkspaceIconCache {
    static let shared = WorkspaceIconCache()
    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 160
    }

    func icon(for url: URL, size: CGFloat) -> NSImage {
        let type = url.pathExtension.lowercased()
        let key = "\(type.isEmpty ? "file" : type)|\(Int(size.rounded()))" as NSString
        if let image = cache.object(forKey: key) { return image }
        let contentType = UTType(filenameExtension: type) ?? .data
        let image = NSWorkspace.shared.icon(for: contentType)
        image.size = NSSize(width: size, height: size)
        cache.setObject(image, forKey: key)
        return image
    }
}

final class CustomFolderIconStore {
    static let shared = CustomFolderIconStore()
    private let defaultsKey = "CustomFolderIconsV1"
    private let folderURL: URL
    private let cache = NSCache<NSString, NSImage>()

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        folderURL = base.appendingPathComponent("Qyvro/FolderIcons", isDirectory: true)
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        cache.countLimit = 120
    }

    func image(for folder: URL) -> NSImage? {
        let path = folder.standardizedFileURL.path
        if let image = cache.object(forKey: path as NSString) { return image }
        guard let fileName = mapping()[path] else { return nil }
        let fileURL = folderURL.appendingPathComponent(fileName)
        guard let image = NSImage(contentsOf: fileURL) else {
            removeIcon(for: folder)
            return nil
        }
        cache.setObject(image, forKey: path as NSString)
        return image
    }

    @discardableResult
    func setIcon(from source: URL, for folder: URL) -> Bool {
        guard let image = NSImage(contentsOf: source), let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        let path = folder.standardizedFileURL.path
        let fileName = String(format: "%016llx.png", stableHash(path))
        do {
            try data.write(to: folderURL.appendingPathComponent(fileName), options: .atomic)
            var map = mapping()
            map[path] = fileName
            UserDefaults.standard.set(map, forKey: defaultsKey)
            cache.setObject(image, forKey: path as NSString)
            return true
        } catch {
            return false
        }
    }

    func removeIcon(for folder: URL) {
        let path = folder.standardizedFileURL.path
        var map = mapping()
        if let fileName = map.removeValue(forKey: path) {
            try? FileManager.default.removeItem(at: folderURL.appendingPathComponent(fileName))
        }
        UserDefaults.standard.set(map, forKey: defaultsKey)
        cache.removeObject(forKey: path as NSString)
    }

    private func mapping() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }

    private func stableHash(_ value: String) -> UInt64 {
        value.utf8.reduce(UInt64(1469598103934665603)) { hash, byte in
            (hash ^ UInt64(byte)) &* 1099511628211
        }
    }
}

enum ExplorerViewMode: Int {
    case list = 0
    case smallIcons = 1
    case largeIcons = 2
}

enum FPThemeStyleVariant: String {
    case classic
    case cyberEditorial
}

enum FPStyle {
    private static func storedColor(_ key: String, fallback: NSColor) -> NSColor {
        guard let data = UserDefaults.standard.data(forKey: key),
              let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) else {
            return fallback
        }
        return color
    }

    static func saveColor(_ color: NSColor, key: String) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: true) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func opacity(_ key: String, fallback: CGFloat) -> CGFloat {
        guard UserDefaults.standard.object(forKey: key) != nil else { return fallback }
        return CGFloat(UserDefaults.standard.double(forKey: key))
    }

    static var styleVariant: FPThemeStyleVariant {
        FPThemeStyleVariant(
            rawValue: UserDefaults.standard.string(forKey: "ThemeStyleVariant") ?? ""
        ) ?? .classic
    }

    static var isCyberEditorial: Bool {
        styleVariant == .cyberEditorial
    }

    static func headingFont(ofSize size: CGFloat, weight: NSFont.Weight = .semibold) -> NSFont {
        guard isCyberEditorial else {
            return .systemFont(ofSize: size, weight: weight)
        }
        let name = weight.rawValue >= NSFont.Weight.semibold.rawValue
            ? "AvenirNextCondensed-DemiBold"
            : "AvenirNextCondensed-Medium"
        return NSFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }

    static func bodyFont(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        guard isCyberEditorial else {
            return .systemFont(ofSize: size, weight: weight)
        }
        let name = weight.rawValue >= NSFont.Weight.semibold.rawValue
            ? "AvenirNext-DemiBold"
            : "AvenirNext-Medium"
        return NSFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }

    static func migrateCyberEditorialForVersionTwo() {
        guard styleVariant == .cyberEditorial,
              !UserDefaults.standard.bool(forKey: "CyberEditorialPaletteV2") else { return }
        let defaults = UserDefaults.standard
        saveColor(NSColor(calibratedRed: 0.018, green: 0.016, blue: 0.024, alpha: 1), key: "ThemeWindowColor")
        saveColor(NSColor(calibratedRed: 0.030, green: 0.028, blue: 0.039, alpha: 1), key: "ThemePaneColor")
        saveColor(NSColor(calibratedRed: 0.022, green: 0.019, blue: 0.030, alpha: 1), key: "ThemeSidebarColor")
        saveColor(NSColor(calibratedRed: 0.025, green: 0.022, blue: 0.035, alpha: 1), key: "ThemeBarColor")
        saveColor(NSColor(calibratedRed: 0.839, green: 1.0, blue: 0.247, alpha: 1), key: "ThemeAccentColor")
        saveColor(NSColor(calibratedRed: 0.941, green: 0.267, blue: 0.365, alpha: 1), key: "ThemeOrangeColor")
        saveColor(NSColor(calibratedRed: 0.0, green: 0.878, blue: 1.0, alpha: 1), key: "ThemeFolderColor")
        saveColor(NSColor(calibratedRed: 0.957, green: 0.945, blue: 0.918, alpha: 1), key: "ThemeTextColor")
        saveColor(NSColor(calibratedRed: 0.635, green: 0.620, blue: 0.640, alpha: 1), key: "ThemeDimTextColor")
        saveColor(NSColor(calibratedRed: 0.185, green: 0.020, blue: 0.055, alpha: 1), key: "ThemeGradientStart")
        saveColor(NSColor(calibratedRed: 0.055, green: 0.030, blue: 0.105, alpha: 1), key: "ThemeGradientEnd")
        defaults.set(0.70, forKey: "ThemePaneOpacity")
        defaults.set(0.72, forKey: "ThemeSidebarOpacity")
        defaults.set(true, forKey: "ThemeGradientEnabled")
        defaults.set(true, forKey: "CyberEditorialPaletteV2")
    }

    // Обновлённая палитра по умолчанию (v1.1): глубокий графит с холодным
    // сине-серым подтоном вместо коричневого — спокойнее и современнее.
    // Пользовательские цвета из настроек по-прежнему имеют приоритет.
    static var window: NSColor { storedColor("ThemeWindowColor", fallback: NSColor(calibratedRed: 0.071, green: 0.079, blue: 0.094, alpha: 0.90)) }
    static var sidebar: NSColor {
        storedColor("ThemeSidebarColor", fallback: NSColor(calibratedRed: 0.157, green: 0.183, blue: 0.238, alpha: 1))
            .withAlphaComponent(opacity("ThemeSidebarOpacity", fallback: 0.44))
    }
    /// Прозрачность окна просмотрщика. Настраивается в параметрах темы:
    /// кому-то нужен плотный фон под тёмную картинку, кому-то — стекло.
    static var previewOpacity: CGFloat {
        guard UserDefaults.standard.object(forKey: "PreviewWindowOpacity") != nil else {
            return 0.88
        }
        return min(max(opacity("PreviewWindowOpacity", fallback: 0.88), 0.35), 1)
    }

    static var pane: NSColor {
        storedColor("ThemePaneColor", fallback: NSColor(calibratedRed: 0.122, green: 0.136, blue: 0.157, alpha: 1))
            .withAlphaComponent(opacity("ThemePaneOpacity", fallback: 0.58))
    }
    static var settingsWindow: NSColor {
        storedColor("ThemeSettingsWindowColor", fallback: window.withAlphaComponent(1))
            .withAlphaComponent(opacity("ThemeSettingsWindowOpacity", fallback: 0.88))
    }
    static var tagWindow: NSColor {
        storedColor("ThemeTagWindowColor", fallback: sidebar.withAlphaComponent(1))
            .withAlphaComponent(opacity("ThemeTagWindowOpacity", fallback: 0.82))
    }
    static var paneInactive: NSColor { pane.withAlphaComponent(max(0.42, pane.alphaComponent - 0.08)) }
    static var bar: NSColor { storedColor("ThemeBarColor", fallback: NSColor(calibratedRed: 0.133, green: 0.148, blue: 0.171, alpha: 0.78)) }
    static var tabBar: NSColor {
        if isCyberEditorial {
            return bar.blended(withFraction: 0.44, of: .black)?.withAlphaComponent(0.95) ?? bar
        }
        return bar.blended(withFraction: 0.28, of: .black)?.withAlphaComponent(0.82) ?? bar
    }
    static var tab: NSColor {
        isCyberEditorial
            ? NSColor(calibratedWhite: 0.060, alpha: 0.92)
            : NSColor(calibratedRed: 0.172, green: 0.190, blue: 0.216, alpha: 0.92)
    }
    static var tabInactive: NSColor {
        isCyberEditorial
            ? NSColor(calibratedWhite: 0.018, alpha: 0.68)
            : NSColor(calibratedRed: 0.104, green: 0.115, blue: 0.132, alpha: 0.60)
    }
    static var field: NSColor {
        isCyberEditorial
            ? NSColor(calibratedWhite: 0.012, alpha: 0.76)
            : NSColor(calibratedRed: 0.116, green: 0.128, blue: 0.148, alpha: 0.70)
    }
    static var control: NSColor {
        NSColor(calibratedWhite: 1.0, alpha: isCyberEditorial ? 0.055 : 0.075)
    }
    static var controlStrong: NSColor {
        isCyberEditorial
            ? NSColor(calibratedWhite: 1.0, alpha: 0.075)
            : NSColor(calibratedWhite: 1.0, alpha: 0.115)
    }
    static var rowA: NSColor { pane.withAlphaComponent(min(0.78, pane.alphaComponent + 0.02)) }
    static var rowB: NSColor { storedColor("ThemePaneColor", fallback: NSColor(calibratedRed: 0.101, green: 0.113, blue: 0.131, alpha: 1)).withAlphaComponent(0.62) }
    static var rowSelection: NSColor { accent.withAlphaComponent(0.32) }
    static var stroke: NSColor {
        isCyberEditorial
            ? NSColor(calibratedWhite: 1.0, alpha: 0.105)
            : NSColor(calibratedWhite: 1.0, alpha: 0.10)
    }
    static var text: NSColor { storedColor("ThemeTextColor", fallback: NSColor(calibratedWhite: 0.912, alpha: 1)) }
    static var dimText: NSColor { storedColor("ThemeDimTextColor", fallback: NSColor(calibratedWhite: 0.673, alpha: 1)) }
    static var accent: NSColor { storedColor("ThemeAccentColor", fallback: NSColor(calibratedRed: 0.00, green: 0.758, blue: 0.798, alpha: 1)) }
    static var accentFill: NSColor { accent.withAlphaComponent(0.58) }
    static var orange: NSColor { storedColor("ThemeOrangeColor", fallback: NSColor(calibratedRed: 1.00, green: 0.645, blue: 0.262, alpha: 1)) }
    static var orangeFill: NSColor { orange.withAlphaComponent(0.84) }
    static var defaultFolder: NSColor { storedColor("ThemeFolderColor", fallback: accent) }
    static var gradientStart: NSColor { storedColor("ThemeGradientStart", fallback: NSColor(calibratedRed: 0.118, green: 0.146, blue: 0.220, alpha: 1)) }
    static var gradientEnd: NSColor { storedColor("ThemeGradientEnd", fallback: NSColor(calibratedRed: 0.040, green: 0.075, blue: 0.096, alpha: 1)) }
    static var gradientEnabled: Bool {
        guard UserDefaults.standard.object(forKey: "ThemeGradientEnabled") != nil else { return true }
        return UserDefaults.standard.bool(forKey: "ThemeGradientEnabled")
    }
    static let danger = NSColor(calibratedRed: 0.90, green: 0.22, blue: 0.18, alpha: 1)
    static var gridSpacing: CGFloat {
        guard UserDefaults.standard.object(forKey: "GridSpacing") != nil else { return 2 }
        return min(max(CGFloat(UserDefaults.standard.double(forKey: "GridSpacing")), 2), 36)
    }
}

enum FPPreferences {
    static let defaultSwipeSensitivity = 60.0

    static var swipeSensitivity: Double {
        guard UserDefaults.standard.object(forKey: "SwipeSensitivity") != nil else {
            return defaultSwipeSensitivity
        }
        return min(max(UserDefaults.standard.double(forKey: "SwipeSensitivity"), 10), 100)
    }

    /// Держать ли окно проводника поверх остальных постоянно.
    static var keepsExplorerOnTop: Bool {
        UserDefaults.standard.bool(forKey: "AlwaysOnTop")
    }

    /// Схлопывать ли производные файлы в одну стопку.
    static var collapsesFileVersions: Bool {
        UserDefaults.standard.bool(forKey: "CollapseFileVersions")
    }

    static var swipeThreshold: CGFloat {
        CGFloat(190 - swipeSensitivity * 1.45)
    }

    static func migrateGestureSettingsForVersionOne() {
        let migrationKey = "QyvroGestureSettingsMigratedForVersionOne"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }

        // Older builds wrote the old default (10) even when the user only
        // changed an unrelated theme control. Treat that exact legacy value as
        // an untouched default; deliberately customised values are preserved.
        let stored = UserDefaults.standard.object(forKey: "SwipeSensitivity") == nil
            ? nil
            : UserDefaults.standard.double(forKey: "SwipeSensitivity")
        if stored == nil || abs((stored ?? 10) - 10) < 0.001 {
            UserDefaults.standard.set(defaultSwipeSensitivity, forKey: "SwipeSensitivity")
        }
        UserDefaults.standard.set(true, forKey: migrationKey)
    }

    static var invertedSwipeNavigation: Bool {
        guard UserDefaults.standard.object(forKey: "SwipeNavigationInverted") != nil else { return true }
        return UserDefaults.standard.bool(forKey: "SwipeNavigationInverted")
    }

    static var groupLargeFoldersByDate: Bool {
        guard UserDefaults.standard.object(forKey: "GroupLargeFoldersByDate") != nil else { return true }
        return UserDefaults.standard.bool(forKey: "GroupLargeFoldersByDate")
    }

    static var sidebarAnimationDuration: Double {
        guard UserDefaults.standard.object(forKey: "SidebarAnimationDuration") != nil else { return 0.74 }
        return min(max(UserDefaults.standard.double(forKey: "SidebarAnimationDuration"), 0.5), 2.0)
    }

    static var swipeWaveSmoothness: Double {
        guard UserDefaults.standard.object(forKey: "SwipeWaveSmoothness") != nil else { return 0.84 }
        return min(max(UserDefaults.standard.double(forKey: "SwipeWaveSmoothness"), 0.25), 1.0)
    }

    static var swipeWaveStrength: Double {
        guard UserDefaults.standard.object(forKey: "SwipeWaveStrength") != nil else { return 0.76 }
        return min(max(UserDefaults.standard.double(forKey: "SwipeWaveStrength"), 0.2), 1.0)
    }

    static var swipeWaveDuration: Double {
        guard UserDefaults.standard.object(forKey: "SwipeWaveDuration") != nil else { return 0.92 }
        return min(max(UserDefaults.standard.double(forKey: "SwipeWaveDuration"), 0.70), 1.2)
    }

    static var swipeWaveWidth: Double {
        guard UserDefaults.standard.object(forKey: "SwipeWaveWidth") != nil else { return 0.78 }
        return min(max(UserDefaults.standard.double(forKey: "SwipeWaveWidth"), 0.30), 1.20)
    }

    static var swipeWaveBlur: Double {
        guard UserDefaults.standard.object(forKey: "SwipeWaveBlur") != nil else { return 0.46 }
        return min(max(UserDefaults.standard.double(forKey: "SwipeWaveBlur"), 0), 1)
    }

    static var swipeWaveExposure: Double {
        guard UserDefaults.standard.object(forKey: "SwipeWaveExposure") != nil else { return 0.78 }
        return min(max(UserDefaults.standard.double(forKey: "SwipeWaveExposure"), 0), 1.40)
    }

    static var swipeWaveGlow: Double {
        guard UserDefaults.standard.object(forKey: "SwipeWaveGlow") != nil else { return 0.54 }
        return min(max(UserDefaults.standard.double(forKey: "SwipeWaveGlow"), 0), 1.20)
    }

    static var swipeWaveTint: Double {
        guard UserDefaults.standard.object(forKey: "SwipeWaveTint") != nil else { return 0.38 }
        return min(max(UserDefaults.standard.double(forKey: "SwipeWaveTint"), 0), 1)
    }

    static var swipeWaveTilt: Double {
        guard UserDefaults.standard.object(forKey: "SwipeWaveTilt") != nil else { return 13 }
        return min(max(UserDefaults.standard.double(forKey: "SwipeWaveTilt"), -35), 35)
    }

    static var summonHotKeyEnabled: Bool {
        guard UserDefaults.standard.object(forKey: "GlobalSummonHotKeyEnabled") != nil else { return true }
        return UserDefaults.standard.bool(forKey: "GlobalSummonHotKeyEnabled")
    }
}

enum QyvroClipboardShortcut {
    static let keyCode = UInt32(kVK_ANSI_V)
    static let carbonModifiers = UInt32(cmdKey | shiftKey)
    static let cocoaModifiers: NSEvent.ModifierFlags = [.command, .shift]
    static let displayName = "⇧⌘V"
}

// MARK: - Глобальные хоткеи ⌘E и ⇧⌘V
// Один Carbon-центр владеет всеми глобальными сочетаниями Qyvro. Так разные
// модули не устанавливают конкурирующие обработчики одного и того же события.
final class GlobalHotKeyCenter {
    static let shared = GlobalHotKeyCenter()
    var onSummon: (() -> Void)?
    var onClipboard: (() -> Void)?
    private var summonHotKeyRef: EventHotKeyRef?
    private var clipboardHotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    func setEnabled(_ enabled: Bool) {
        installHandlerIfNeeded()
        registerClipboardIfNeeded()
        if enabled {
            registerSummonIfNeeded()
        } else {
            unregisterSummon()
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            var actualSize = 0
            let readStatus = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                &actualSize,
                &identifier
            )
            guard readStatus == noErr else { return readStatus }
            let center = Unmanaged<GlobalHotKeyCenter>
                .fromOpaque(userData)
                .takeUnretainedValue()
            DispatchQueue.main.async {
                switch identifier.id {
                case 1: center.onSummon?()
                case 2: center.onClipboard?()
                default: break
                }
            }
            return noErr
        }
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            callback,
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        if status != noErr {
            NSLog("Qyvro: failed to install global hotkey handler (%d)", status)
        }
    }

    private func registerSummonIfNeeded() {
        guard summonHotKeyRef == nil else { return }
        let identifier = EventHotKeyID(
            signature: OSType(0x5159_5652),
            id: 1
        ) // 'QYVR'
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_E),
            UInt32(cmdKey),
            identifier,
            GetEventDispatcherTarget(),
            0,
            &summonHotKeyRef
        )
        if status != noErr {
            NSLog("Qyvro: failed to register ⌘E (%d)", status)
        }
    }

    private func registerClipboardIfNeeded() {
        guard clipboardHotKeyRef == nil else { return }
        let identifier = EventHotKeyID(
            signature: OSType(0x5159_5652),
            id: 2
        ) // 'QYVR'
        let status = RegisterEventHotKey(
            QyvroClipboardShortcut.keyCode,
            QyvroClipboardShortcut.carbonModifiers,
            identifier,
            GetEventDispatcherTarget(),
            0,
            &clipboardHotKeyRef
        )
        if status != noErr {
            NSLog("Qyvro: failed to register ⇧⌘V (%d)", status)
        }
    }

    private func unregisterSummon() {
        if let summonHotKeyRef {
            UnregisterEventHotKey(summonHotKeyRef)
        }
        summonHotKeyRef = nil
    }
}

struct FPThemePreset {
    let title: String
    let window: NSColor
    let pane: NSColor
    let sidebar: NSColor
    let bar: NSColor
    let folder: NSColor
    let accent: NSColor
    let orange: NSColor
    let gradientStart: NSColor
    let gradientEnd: NSColor
    let paneOpacity: Double
    let sidebarOpacity: Double
    var styleVariant: FPThemeStyleVariant = .classic

    static let all: [FPThemePreset] = [
        FPThemePreset(
            title: "Кислота",
            window: NSColor(calibratedRed: 0.012, green: 0.012, blue: 0.016, alpha: 1.0),
            pane: NSColor(calibratedRed: 0.020, green: 0.020, blue: 0.035, alpha: 1.0),
            sidebar: NSColor(calibratedRed: 0.016, green: 0.012, blue: 0.020, alpha: 1.0),
            bar: NSColor(calibratedRed: 0.016, green: 0.016, blue: 0.024, alpha: 1.0),
            folder: NSColor(calibratedRed: 0.000, green: 0.914, blue: 1.000, alpha: 1.0),
            accent: NSColor(calibratedRed: 0.890, green: 0.973, blue: 0.380, alpha: 1.0),
            orange: NSColor(calibratedRed: 0.980, green: 0.463, blue: 0.514, alpha: 1.0),
            gradientStart: NSColor(calibratedRed: 0.318, green: 0.047, blue: 0.078, alpha: 1.0),
            gradientEnd: NSColor(calibratedRed: 0.082, green: 0.039, blue: 0.188, alpha: 1.0),
            paneOpacity: 0.28,
            sidebarOpacity: 0.39,
            styleVariant: .cyberEditorial
        ),
        FPThemePreset(
            title: "Кислота тёплая",
            window: NSColor(calibratedRed: 0.016, green: 0.012, blue: 0.020, alpha: 1.0),
            pane: NSColor(calibratedRed: 0.024, green: 0.024, blue: 0.039, alpha: 1.0),
            sidebar: NSColor(calibratedRed: 0.020, green: 0.016, blue: 0.024, alpha: 1.0),
            bar: NSColor(calibratedRed: 0.020, green: 0.020, blue: 0.031, alpha: 1.0),
            folder: NSColor(calibratedRed: 0.000, green: 0.898, blue: 1.000, alpha: 1.0),
            accent: NSColor(calibratedRed: 0.867, green: 0.984, blue: 0.310, alpha: 1.0),
            orange: NSColor(calibratedRed: 0.961, green: 0.369, blue: 0.439, alpha: 1.0),
            gradientStart: NSColor(calibratedRed: 0.247, green: 0.031, blue: 0.063, alpha: 1.0),
            gradientEnd: NSColor(calibratedRed: 0.067, green: 0.031, blue: 0.141, alpha: 1.0),
            paneOpacity: 0.35,
            sidebarOpacity: 0.48,
            styleVariant: .cyberEditorial
        ),
        FPThemePreset(
            title: "Графит и янтарь",
            window: NSColor(calibratedRed: 0.055, green: 0.063, blue: 0.063, alpha: 1.0),
            pane: NSColor(calibratedRed: 0.106, green: 0.114, blue: 0.110, alpha: 1.0),
            sidebar: NSColor(calibratedRed: 0.341, green: 0.149, blue: 0.075, alpha: 1.0),
            bar: NSColor(calibratedRed: 0.149, green: 0.161, blue: 0.157, alpha: 1.0),
            folder: NSColor(calibratedRed: 0.000, green: 0.682, blue: 0.690, alpha: 1.0),
            accent: NSColor(calibratedRed: 0.000, green: 0.682, blue: 0.690, alpha: 1.0),
            orange: NSColor(calibratedRed: 1.000, green: 0.490, blue: 0.141, alpha: 1.0),
            gradientStart: NSColor(calibratedRed: 0.239, green: 0.114, blue: 0.059, alpha: 1.0),
            gradientEnd: NSColor(calibratedRed: 0.035, green: 0.090, blue: 0.086, alpha: 1.0),
            paneOpacity: 0.78,
            sidebarOpacity: 0.32
        ),
        FPThemePreset(
            title: "Ультрамарин",
            window: NSColor(calibratedRed: 0.012, green: 0.016, blue: 0.039, alpha: 1.0),
            pane: NSColor(calibratedRed: 0.027, green: 0.035, blue: 0.071, alpha: 1.0),
            sidebar: NSColor(calibratedRed: 0.016, green: 0.020, blue: 0.047, alpha: 1.0),
            bar: NSColor(calibratedRed: 0.020, green: 0.024, blue: 0.059, alpha: 1.0),
            folder: NSColor(calibratedRed: 0.353, green: 0.784, blue: 1.000, alpha: 1.0),
            accent: NSColor(calibratedRed: 0.302, green: 0.549, blue: 1.000, alpha: 1.0),
            orange: NSColor(calibratedRed: 1.000, green: 0.690, blue: 0.125, alpha: 1.0),
            gradientStart: NSColor(calibratedRed: 0.039, green: 0.102, blue: 0.290, alpha: 1.0),
            gradientEnd: NSColor(calibratedRed: 0.020, green: 0.039, blue: 0.133, alpha: 1.0),
            paneOpacity: 0.32,
            sidebarOpacity: 0.42,
            styleVariant: .cyberEditorial
        ),
        FPThemePreset(
            title: "Магента",
            window: NSColor(calibratedRed: 0.020, green: 0.012, blue: 0.027, alpha: 1.0),
            pane: NSColor(calibratedRed: 0.039, green: 0.024, blue: 0.051, alpha: 1.0),
            sidebar: NSColor(calibratedRed: 0.024, green: 0.012, blue: 0.031, alpha: 1.0),
            bar: NSColor(calibratedRed: 0.027, green: 0.016, blue: 0.039, alpha: 1.0),
            folder: NSColor(calibratedRed: 0.000, green: 0.878, blue: 0.816, alpha: 1.0),
            accent: NSColor(calibratedRed: 1.000, green: 0.231, blue: 0.831, alpha: 1.0),
            orange: NSColor(calibratedRed: 1.000, green: 0.820, blue: 0.400, alpha: 1.0),
            gradientStart: NSColor(calibratedRed: 0.227, green: 0.039, blue: 0.220, alpha: 1.0),
            gradientEnd: NSColor(calibratedRed: 0.051, green: 0.024, blue: 0.125, alpha: 1.0),
            paneOpacity: 0.3,
            sidebarOpacity: 0.4,
            styleVariant: .cyberEditorial
        ),
        FPThemePreset(
            title: "Токсик",
            window: NSColor(calibratedRed: 0.008, green: 0.024, blue: 0.016, alpha: 1.0),
            pane: NSColor(calibratedRed: 0.020, green: 0.047, blue: 0.031, alpha: 1.0),
            sidebar: NSColor(calibratedRed: 0.012, green: 0.027, blue: 0.020, alpha: 1.0),
            bar: NSColor(calibratedRed: 0.016, green: 0.035, blue: 0.024, alpha: 1.0),
            folder: NSColor(calibratedRed: 0.490, green: 0.976, blue: 0.753, alpha: 1.0),
            accent: NSColor(calibratedRed: 0.224, green: 1.000, blue: 0.533, alpha: 1.0),
            orange: NSColor(calibratedRed: 0.702, green: 0.420, blue: 1.000, alpha: 1.0),
            gradientStart: NSColor(calibratedRed: 0.039, green: 0.227, blue: 0.133, alpha: 1.0),
            gradientEnd: NSColor(calibratedRed: 0.016, green: 0.078, blue: 0.102, alpha: 1.0),
            paneOpacity: 0.3,
            sidebarOpacity: 0.4,
            styleVariant: .cyberEditorial
        ),
        FPThemePreset(
            title: "Плазма",
            window: NSColor(calibratedRed: 0.016, green: 0.008, blue: 0.035, alpha: 1.0),
            pane: NSColor(calibratedRed: 0.031, green: 0.016, blue: 0.059, alpha: 1.0),
            sidebar: NSColor(calibratedRed: 0.020, green: 0.012, blue: 0.039, alpha: 1.0),
            bar: NSColor(calibratedRed: 0.024, green: 0.012, blue: 0.047, alpha: 1.0),
            folder: NSColor(calibratedRed: 0.490, green: 0.827, blue: 0.988, alpha: 1.0),
            accent: NSColor(calibratedRed: 0.659, green: 0.333, blue: 0.969, alpha: 1.0),
            orange: NSColor(calibratedRed: 1.000, green: 0.373, blue: 0.635, alpha: 1.0),
            gradientStart: NSColor(calibratedRed: 0.180, green: 0.039, blue: 0.322, alpha: 1.0),
            gradientEnd: NSColor(calibratedRed: 0.039, green: 0.024, blue: 0.125, alpha: 1.0),
            paneOpacity: 0.3,
            sidebarOpacity: 0.42,
            styleVariant: .cyberEditorial
        ),
        FPThemePreset(
            title: "Лава",
            window: NSColor(calibratedRed: 0.024, green: 0.012, blue: 0.008, alpha: 1.0),
            pane: NSColor(calibratedRed: 0.047, green: 0.024, blue: 0.016, alpha: 1.0),
            sidebar: NSColor(calibratedRed: 0.027, green: 0.016, blue: 0.012, alpha: 1.0),
            bar: NSColor(calibratedRed: 0.035, green: 0.020, blue: 0.016, alpha: 1.0),
            folder: NSColor(calibratedRed: 1.000, green: 0.784, blue: 0.271, alpha: 1.0),
            accent: NSColor(calibratedRed: 1.000, green: 0.353, blue: 0.212, alpha: 1.0),
            orange: NSColor(calibratedRed: 1.000, green: 0.878, blue: 0.400, alpha: 1.0),
            gradientStart: NSColor(calibratedRed: 0.290, green: 0.071, blue: 0.024, alpha: 1.0),
            gradientEnd: NSColor(calibratedRed: 0.102, green: 0.039, blue: 0.071, alpha: 1.0),
            paneOpacity: 0.32,
            sidebarOpacity: 0.4,
            styleVariant: .cyberEditorial
        ),
        FPThemePreset(
            title: "Иней",
            window: NSColor(calibratedRed: 0.016, green: 0.024, blue: 0.039, alpha: 1.0),
            pane: NSColor(calibratedRed: 0.035, green: 0.051, blue: 0.078, alpha: 1.0),
            sidebar: NSColor(calibratedRed: 0.020, green: 0.027, blue: 0.047, alpha: 1.0),
            bar: NSColor(calibratedRed: 0.027, green: 0.039, blue: 0.063, alpha: 1.0),
            folder: NSColor(calibratedRed: 0.659, green: 0.910, blue: 1.000, alpha: 1.0),
            accent: NSColor(calibratedRed: 0.490, green: 0.910, blue: 1.000, alpha: 1.0),
            orange: NSColor(calibratedRed: 0.788, green: 0.839, blue: 0.910, alpha: 1.0),
            gradientStart: NSColor(calibratedRed: 0.071, green: 0.188, blue: 0.282, alpha: 1.0),
            gradientEnd: NSColor(calibratedRed: 0.027, green: 0.055, blue: 0.102, alpha: 1.0),
            paneOpacity: 0.34,
            sidebarOpacity: 0.44,
            styleVariant: .cyberEditorial
        ),
    ]
}

final class FPThemePresetController: NSObject {
    let windowColor: NSColorWell
    let paneColor: NSColorWell
    let sidebarColor: NSColorWell
    let barColor: NSColorWell
    let folderColor: NSColorWell
    let accentColor: NSColorWell
    let orangeColor: NSColorWell
    let gradientStartColor: NSColorWell
    let gradientEndColor: NSColorWell
    let paneOpacity: NSSlider
    let sidebarOpacity: NSSlider

    init(
        windowColor: NSColorWell,
        paneColor: NSColorWell,
        sidebarColor: NSColorWell,
        barColor: NSColorWell,
        folderColor: NSColorWell,
        accentColor: NSColorWell,
        orangeColor: NSColorWell,
        gradientStartColor: NSColorWell,
        gradientEndColor: NSColorWell,
        paneOpacity: NSSlider,
        sidebarOpacity: NSSlider
    ) {
        self.windowColor = windowColor
        self.paneColor = paneColor
        self.sidebarColor = sidebarColor
        self.barColor = barColor
        self.folderColor = folderColor
        self.accentColor = accentColor
        self.orangeColor = orangeColor
        self.gradientStartColor = gradientStartColor
        self.gradientEndColor = gradientEndColor
        self.paneOpacity = paneOpacity
        self.sidebarOpacity = sidebarOpacity
    }

    @objc func presetChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem - 1
        guard index >= 0, index < FPThemePreset.all.count else { return }
        let preset = FPThemePreset.all[index]
        windowColor.color = preset.window
        paneColor.color = preset.pane
        sidebarColor.color = preset.sidebar
        barColor.color = preset.bar
        folderColor.color = preset.folder
        accentColor.color = preset.accent
        orangeColor.color = preset.orange
        gradientStartColor.color = preset.gradientStart
        gradientEndColor.color = preset.gradientEnd
        paneOpacity.doubleValue = preset.paneOpacity
        sidebarOpacity.doubleValue = preset.sidebarOpacity
    }
}

extension Notification.Name {
    static let fpThemeDidChange = Notification.Name("FPThemeDidChange")
    static let fpTagsDidChange = Notification.Name("FPTagsDidChange")
}

struct FPTag {
    let title: String
    let key: String
    let color: NSColor

    static let builtIn: [FPTag] = [
        FPTag(title: "Красный", key: "red", color: NSColor(calibratedRed: 1.00, green: 0.27, blue: 0.25, alpha: 1)),
        FPTag(title: "Оранжевый", key: "orange", color: FPStyle.orange),
        FPTag(title: "Жёлтый", key: "yellow", color: NSColor(calibratedRed: 1.00, green: 0.84, blue: 0.02, alpha: 1)),
        FPTag(title: "Зелёный", key: "green", color: NSColor(calibratedRed: 0.10, green: 0.86, blue: 0.35, alpha: 1)),
        FPTag(title: "Синий", key: "blue", color: NSColor(calibratedRed: 0.08, green: 0.58, blue: 0.92, alpha: 1)),
        FPTag(title: "Лиловый", key: "purple", color: NSColor(calibratedRed: 0.78, green: 0.32, blue: 0.92, alpha: 1)),
        FPTag(title: "Серый", key: "gray", color: NSColor(calibratedWhite: 0.68, alpha: 1))
    ]

    static var all: [FPTag] { FPTagStore.shared.tags }

    static func color(for key: String) -> NSColor? {
        all.first(where: { $0.key == key })?.color
    }
}

private struct FPTagRecord: Codable {
    var title: String
    var key: String
    var red: Double
    var green: Double
    var blue: Double

    init(tag: FPTag) {
        let color = tag.color.usingColorSpace(.deviceRGB) ?? tag.color
        title = tag.title
        key = tag.key
        red = Double(color.redComponent)
        green = Double(color.greenComponent)
        blue = Double(color.blueComponent)
    }

    var tag: FPTag {
        FPTag(title: title, key: key, color: NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1))
    }
}

final class FPTagStore {
    static let shared = FPTagStore()
    private let defaultsKey = "QyvroTagDefinitionsV1"

    var tags: [FPTag] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let records = try? JSONDecoder().decode([FPTagRecord].self, from: data),
              !records.isEmpty else { return FPTag.builtIn }
        return records.map(\.tag)
    }

    func add(title: String, color: NSColor) {
        var values = tags
        values.append(FPTag(title: title, key: "custom-\(UUID().uuidString)", color: color))
        save(values)
    }

    func update(key: String, title: String, color: NSColor) {
        var values = tags
        guard let index = values.firstIndex(where: { $0.key == key }) else { return }
        values[index] = FPTag(title: title, key: key, color: color)
        save(values)
    }

    func remove(key: String) {
        let remaining = tags.filter { $0.key != key }
        guard !remaining.isEmpty else { return }
        save(remaining)
        var assignments = UserDefaults.standard.dictionary(forKey: "FolderColors") as? [String: String] ?? [:]
        assignments = assignments.filter { $0.value != key }
        UserDefaults.standard.set(assignments, forKey: "FolderColors")
    }

    func key(for finderTag: FPFinderTag) -> String {
        let foldedTitle = finderTag.title.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        if let existing = tags.first(where: {
            $0.title.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            ) == foldedTitle
        }) {
            return existing.key
        }

        var values = tags
        let imported = FPTag(
            title: finderTag.title,
            key: "finder-\(UUID().uuidString)",
            color: FPFinderTagStore.color(forFinderNumber: finderTag.colorNumber)
        )
        values.append(imported)
        save(values)
        return imported.key
    }

    private func save(_ values: [FPTag]) {
        guard let data = try? JSONEncoder().encode(values.map(FPTagRecord.init)) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
        NotificationCenter.default.post(name: .fpTagsDidChange, object: nil)
    }
}

/// Журнал действий пользователя.
///
/// Пишет в `~/Library/Logs/Qyvro/actions.log` всё, что человек делает в
/// приложении: нажатия, переходы, смену фильтров, работу с превью. Нужен,
/// чтобы разбирать баги по факту, а не по пересказу: в отчёте видно точную
/// последовательность действий, время между ними и что приложение ответило.
///
/// Пишется всегда, объём ограничен: при превышении предела старая половина
/// отбрасывается, поэтому файл не растёт бесконечно.
enum FPActionLog {
    private static let queue = DispatchQueue(label: "qyvro.actionlog", qos: .utility)
    private static let byteLimit = 512 * 1024
    private static var launchStamp = Date()

    static let directoryURL: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return base.appendingPathComponent("Logs/Qyvro", isDirectory: true)
    }()

    static var fileURL: URL { directoryURL.appendingPathComponent("actions.log") }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// Действие человека: нажатие, выбор пункта меню, жест.
    static func action(_ what: String, _ detail: String = "") {
        write("ДЕЙСТВИЕ", what, detail)
    }

    /// Ответ приложения на действие: что изменилось, сколько заняло.
    static func result(_ what: String, _ detail: String = "") {
        write("РЕЗУЛЬТАТ", what, detail)
    }

    /// Сбой или неожиданное состояние.
    static func problem(_ what: String, _ detail: String = "") {
        write("ПРОБЛЕМА", what, detail)
    }

    static func startSession(version: String) {
        launchStamp = Date()
        queue.async {
            try? FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
        }
        write("ЗАПУСК", "Qyvro \(version)", ProcessInfo.processInfo.operatingSystemVersionString)
    }

    private static func write(_ kind: String, _ what: String, _ detail: String) {
        let now = Date()
        queue.async {
            let since = String(format: "%.1f", now.timeIntervalSince(launchStamp))
            var line = "\(formatter.string(from: now))  +\(since)s  \(kind)  \(what)"
            if !detail.isEmpty { line += "  —  \(detail)" }
            line += "\n"
            guard let data = line.data(using: .utf8) else { return }
            let url = fileURL
            let manager = FileManager.default
            if !manager.fileExists(atPath: url.path) {
                try? manager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                try? data.write(to: url)
                return
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
            trimIfNeeded(url)
        }
    }

    private static func trimIfNeeded(_ url: URL) {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > byteLimit,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = lines.suffix(lines.count / 2).joined(separator: "\n")
        try? kept.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Фильтр ленты файлов.
///
/// Живёт рядом с сортировкой в нижней панели. Ключевой пункт — «отмечено
/// сегодня»: он собирает всё удачное за день в одно выделение, которое можно
/// разом перетащить в Фигму или на диск.
enum FPGridFilter: String, CaseIterable {
    case all
    case images
    case videos
    case flagged
    case flaggedToday
    case today
    case yesterday
    case week
    case heavy

    var title: String {
        switch self {
        case .all: return "Все файлы"
        case .images: return "Только картинки"
        case .videos: return "Только видео"
        case .flagged: return "★ Отмеченные"
        case .flaggedToday: return "★ Отмечено сегодня"
        case .today: return "Сегодня"
        case .yesterday: return "Вчера"
        case .week: return "За 7 дней"
        case .heavy: return "Больше 20 МБ"
        }
    }

    /// Короткая подпись для кнопки: в нижней панели мало места.
    var shortTitle: String {
        switch self {
        case .all: return "Фильтр"
        case .images: return "Картинки"
        case .videos: return "Видео"
        case .flagged: return "★"
        case .flaggedToday: return "★ сегодня"
        case .today: return "Сегодня"
        case .yesterday: return "Вчера"
        case .week: return "7 дней"
        case .heavy: return "> 20 МБ"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "line.3.horizontal.decrease"
        case .images: return "photo"
        case .videos: return "film"
        case .flagged, .flaggedToday: return "star.fill"
        case .today, .yesterday, .week: return "calendar"
        case .heavy: return "scalemass"
        }
    }

    func matches(_ item: FileItem) -> Bool {
        // Папки не прячутся никогда: иначе из отфильтрованной ленты нельзя
        // никуда перейти.
        if item.isDirectory { return true }
        let ext = item.url.pathExtension.lowercased()
        let calendar = Calendar.current
        switch self {
        case .all:
            return true
        case .images:
            return FPMediaInfoCache.imageExtensions.contains(ext)
        case .videos:
            return FPMediaInfoCache.movieExtensions.contains(ext)
        case .flagged:
            return FPFinderTagStore.isFlagged(item.finderTags ?? [])
        case .flaggedToday:
            guard FPFinderTagStore.isFlagged(item.finderTags ?? []) else { return false }
            // Время постановки отметки отдельно не хранится: метка пишется в
            // расширенный атрибут файла, а системе это меняет дату изменения
            // атрибутов. Её и спрашиваем — работает и для меток из Finder.
            let values = try? item.url.resourceValues(
                forKeys: [.attributeModificationDateKey]
            )
            guard let changed = values?.attributeModificationDate else { return false }
            return calendar.isDateInToday(changed)
        case .today:
            guard let date = item.created ?? item.modified else { return false }
            return calendar.isDateInToday(date)
        case .yesterday:
            guard let date = item.created ?? item.modified else { return false }
            return calendar.isDateInYesterday(date)
        case .week:
            guard let date = item.created ?? item.modified else { return false }
            guard let edge = calendar.date(byAdding: .day, value: -7, to: Date()) else { return false }
            return date >= edge
        case .heavy:
            return (item.size ?? 0) > 20 * 1024 * 1024
        }
    }
}

/// Подготовка файла к загрузке в нейросеть прямо в момент перетаскивания.
///
/// Seedance принимает картинки не длиннее 5999 точек по большей стороне и не
/// тяжелее 20 МБ. Обычное перетаскивание отдаёт оригинал, перетаскивание с
/// зажатым ⌥ — уже подготовленный JPEG. Файл делается заранее и отдаётся как
/// обычный, поэтому работает с любым получателем: браузером, Фигмой,
/// Телеграмом. Обещанные файлы macOS для этого не годятся — веб-страницы в
/// браузерах их не принимают.
enum FPUploadPrep {
    static let maxSide = 5999
    static let maxBytes = 20 * 1024 * 1024

    private static let directory: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("QyvroUpload", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Готовые файлы переживают повторные перетаскивания: подготовка тяжёлой
    /// картинки занимает секунду, платить её дважды за один файл незачем.
    private static var cache: [String: URL] = [:]

    /// Готовит файлы, только если при начале перетаскивания зажат ⌥.
    ///
    /// Клавиша выбрана намеренно: `fn` на этой машине занята диктовкой, а
    /// ⌥ при перетаскивании между приложениями и так означает «копировать»,
    /// так что смысл не спорит с системным.
    static func prepareIfRequested(_ urls: [URL], event: NSEvent) -> [URL] {
        guard event.modifierFlags.contains(.option) else { return urls }
        let prepared = prepare(urls)
        FPActionLog.action(
            "перетаскивание с ⌥: подготовлено к загрузке",
            "\(prepared.count) файлов, лимит \(maxSide)px и 20 МБ"
        )
        return prepared
    }

    static func canPrepare(_ url: URL) -> Bool {
        FPMediaInfoCache.imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// Возвращает подготовленные копии. Файлы, которые готовить не нужно или
    /// не получилось, отдаются как есть — перетаскивание не должно срываться
    /// из-за одной картинки.
    static func prepare(_ urls: [URL]) -> [URL] {
        urls.map { url in
            guard canPrepare(url) else { return url }
            let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]
            )
            let stamp = "\(url.path)|\(values?.fileSize ?? 0)|"
                + "\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
            if let ready = cache[stamp], FileManager.default.fileExists(atPath: ready.path) {
                return ready
            }
            guard let prepared = convert(url) else { return url }
            cache[stamp] = prepared
            return prepared
        }
    }

    private static func convert(_ url: URL) -> URL? {
        let name = url.deletingPathExtension().lastPathComponent
        let target = directory.appendingPathComponent("\(name).jpg")
        try? FileManager.default.removeItem(at: target)

        // Качество подбирается сверху вниз: сначала пробуем близкое к
        // исходному, и снижаем, только пока файл не влезает в лимит.
        for quality in ["0.92", "0.85", "0.75", "0.6"] {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
            task.arguments = [
                "-s", "format", "jpeg",
                "-s", "formatOptions", quality,
                "-Z", "\(maxSide)",
                url.path,
                "--out", target.path
            ]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            guard (try? task.run()) != nil else { return nil }
            task.waitUntilExit()
            guard task.terminationStatus == 0,
                  let size = try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                return nil
            }
            if size <= maxBytes { return target }
        }
        // Даже на минимальном качестве не влезло — отдаём что получилось.
        return FileManager.default.fileExists(atPath: target.path) ? target : nil
    }
}

/// Схлопывание версий одного файла в стопку.
///
/// В папке загрузок один и тот же кадр лежит в нескольких видах: оригинал,
/// уменьшенная копия `_max5999`, её JPEG-вариант, дубль от браузера `(1)`.
/// Лента показывает один представитель со счётчиком, остальные прячутся под
/// ним и раскрываются нажатием.
enum FPVersionGrouping {
    /// Общее имя для всех производных одного файла.
    ///
    /// Отбрасываются только заведомо служебные хвосты: наш собственный
    /// `_maxNNNN`, его номер при совпадении имён и скобочный дубль браузера.
    /// Просто числовой хвост не трогается — под него попали бы кадры
    /// последовательности вроде `shot_01` и `shot_02`.
    static func baseName(for url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent

        if let range = name.range(of: #"\s\(\d+\)$"#, options: .regularExpression) {
            name.removeSubrange(range)
        }
        if let range = name.range(of: #"_max\d+(_\d+)?$"#, options: .regularExpression) {
            name.removeSubrange(range)
        }
        return name
    }

    struct Group {
        let key: String
        let representative: FileItem
        let members: [FileItem]
    }

    /// Собирает элементы в группы, сохраняя исходный порядок ленты.
    static func groups(for items: [FileItem]) -> [Group] {
        var order: [String] = []
        var buckets: [String: [FileItem]] = [:]
        for item in items {
            let key = item.isDirectory ? item.url.path : baseName(for: item.url)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
        }
        return order.compactMap { key in
            guard let members = buckets[key], let first = members.first else { return nil }
            guard members.count > 1 else {
                return Group(key: key, representative: first, members: members)
            }
            // Представителем становится оригинал — файл, чьё имя совпадает с
            // общим. Если оригинала уже нет, берётся самый тяжёлый: он несёт
            // больше всего данных.
            let original = members.first {
                $0.url.deletingPathExtension().lastPathComponent == key
            }
            let heaviest = members.max { ($0.size ?? 0) < ($1.size ?? 0) }
            return Group(
                key: key,
                representative: original ?? heaviest ?? first,
                members: members
            )
        }
    }
}

/// Занятость диска с разбивкой по типам файлов.
///
/// Общий объём и свободное место берутся у самого тома — это точно и мгновенно.
/// Разбивка по типам считается Spotlight в фоне: обходить диск самим слишком
/// дорого, а индекс уже знает и тип, и размер каждого файла.
enum FPDiskUsage {
    struct Snapshot {
        var total: Int64 = 0
        var free: Int64 = 0
        var images: Int64 = 0
        var videos: Int64 = 0
        /// Занято всем остальным: система, программы, документы, архивы.
        var other: Int64 { max(0, total - free - images - videos) }
        var used: Int64 { max(0, total - free) }
        var hasBreakdown: Bool { images > 0 || videos > 0 }
    }

    private static var cached = Snapshot()
    private static var query: NSMetadataQuery?
    private static var observers: [NSObjectProtocol] = []

    static var snapshot: Snapshot { cached }

    /// Читает объём тома. Быстро, поэтому вызывается при каждом показе.
    static func refreshCapacity() {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]) else { return }
        cached.total = Int64(values.volumeTotalCapacity ?? 0)
        if let important = values.volumeAvailableCapacityForImportantUsage {
            cached.free = Int64(important)
        }
    }

    /// Запускает подсчёт по типам. Результат кэшируется на весь сеанс:
    /// пересчитывать его на каждый показ незачем, картина за минуты не меняется.
    static func refreshBreakdown(completion: @escaping () -> Void) {
        guard !cached.hasBreakdown, query == nil else {
            completion()
            return
        }
        let metadataQuery = NSMetadataQuery()
        // Область — домашняя папка, а не весь компьютер. Spotlight отдаёт
        // один и тот же файл по нескольким путям (обычный и через
        // /System/Volumes/Data), плюс облачные заглушки с логическим
        // размером. От этого разбивка насчитывала 1.95 ТБ видео на диске в
        // 466 ГБ. Домашняя папка — ровно то, что человеку интересно.
        metadataQuery.searchScopes = [NSMetadataQueryUserHomeScope]
        metadataQuery.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
            NSPredicate(format: "kMDItemContentTypeTree == %@", "public.image"),
            NSPredicate(format: "kMDItemContentTypeTree == %@", "public.movie")
        ])
        metadataQuery.valueListAttributes = [
            NSMetadataItemFSSizeKey,
            NSMetadataItemContentTypeTreeKey,
            NSMetadataItemPathKey
        ]

        let finish: (Notification) -> Void = { _ in
            metadataQuery.disableUpdates()
            var images: Int64 = 0
            var videos: Int64 = 0
            // Один файл может попасть в выдачу дважды под разными путями,
            // поэтому размеры складываются по уникальным путям.
            var counted = Set<String>()
            for index in 0..<metadataQuery.resultCount {
                guard let item = metadataQuery.result(at: index) as? NSMetadataItem,
                      let size = item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber
                else { continue }
                // Дерево типов запрашивается явно: без него атрибут приходил
                // пустым, всё уходило в одну корзину, и разбивка показывала
                // объёмы больше самого диска.
                let types = item.value(forAttribute: NSMetadataItemContentTypeTreeKey) as? [String] ?? []
                guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                      FPSpotlightSearch.isMeaningful(URL(fileURLWithPath: path)),
                      counted.insert(URL(fileURLWithPath: path).standardizedFileURL.path).inserted
                else { continue }
                if types.contains("public.movie") {
                    videos += size.int64Value
                } else if types.contains("public.image") {
                    images += size.int64Value
                }
            }
            // Страховка от завышения: сумма по типам не может превышать
            // занятое место. Если Spotlight всё же насчитал лишнего, доли
            // ужимаются пропорционально, а не показывают проценты больше ста.
            let used = max(cached.total - cached.free, 0)
            let claimed = images + videos
            if used > 0, claimed > used {
                let scale = Double(used) / Double(claimed)
                images = Int64(Double(images) * scale)
                videos = Int64(Double(videos) * scale)
                FPActionLog.problem(
                    "разбивка диска завышена",
                    "заявлено \(claimed / 1_048_576) МБ при занятых \(used / 1_048_576) МБ"
                )
            }
            cached.images = images
            cached.videos = videos
            metadataQuery.stop()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            query = nil
            FPActionLog.result(
                "разбивка диска посчитана",
                "картинки \(images / 1_048_576) МБ, видео \(videos / 1_048_576) МБ"
            )
            DispatchQueue.main.async { completion() }
        }

        observers.append(
            NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
                object: metadataQuery,
                queue: .main,
                using: finish
            )
        )
        query = metadataQuery
        metadataQuery.start()
    }
}
