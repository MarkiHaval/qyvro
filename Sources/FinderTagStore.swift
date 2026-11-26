import Cocoa
import Darwin

struct FPFinderTag: Codable, Equatable {
    let title: String
    let colorNumber: Int

    init(title: String, colorNumber: Int) {
        self.title = title
        self.colorNumber = max(0, min(7, colorNumber))
    }

    init(encodedValue: String) {
        let components = encodedValue.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        title = String(components.first ?? "")
        colorNumber = components.count > 1 ? (Int(components[1]) ?? 0) : 0
    }

    var encodedValue: String {
        colorNumber > 0 ? "\(title)\n\(colorNumber)" : title
    }
}

enum FPFinderTagStore {
    private static let attributeName = "com.apple.metadata:_kMDItemUserTags"
    private static let managedDefaultsKey = "QyvroManagedFinderTagsV1"
    private static let migrationDefaultsKey = "QyvroFinderTagsMigrationV1"

    static func tags(for url: URL) -> [FPFinderTag] {
        guard let data = extendedAttribute(named: attributeName, at: url),
              let values = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                as? [String] else {
            return []
        }
        return values.map(FPFinderTag.init(encodedValue:))
    }

    @discardableResult
    static func setQyvroTag(
        _ tag: FPTag?,
        on url: URL,
        legacyManagedTitle: String? = nil
    ) throws -> [FPFinderTag] {
        let path = url.standardizedFileURL.path
        var managed = managedTitles()
        let previousManagedTitle = managed[path]
        let titlesToRemove = [previousManagedTitle, legacyManagedTitle]
            .compactMap { $0 }
            .map(normalizedTitle)

        var values = tags(for: url).filter { finderTag in
            !titlesToRemove.contains(normalizedTitle(finderTag.title))
        }

        if let tag {
            values.removeAll { normalizedTitle($0.title) == normalizedTitle(tag.title) }
            values.insert(
                FPFinderTag(title: tag.title, colorNumber: finderColorNumber(for: tag)),
                at: 0
            )
            managed[path] = tag.title
        } else {
            managed.removeValue(forKey: path)
        }

        try write(values, to: url)
        saveManagedTitles(managed)
        return values
    }

    /// Метка «отобрано» — отдельная от цветных.
    ///
    /// Живёт настоящей меткой Finder, а не своей базой: переживает
    /// перемещение и переименование файла, видна в Finder и индексируется
    /// Spotlight, поэтому выборка «отмечено сегодня» не требует обхода папок.
    static let selectedFlagTitle = "★ Отобрано"
    /// Вторая ступень: файл не просто понравился, а точно идёт в работу.
    static let confirmedFlagTitle = "★★ Точно берём"
    private static let selectedFlagColorNumber = 5 // жёлтый
    private static let confirmedFlagColorNumber = 2 // зелёный

    /// Ступень отметки. Две ступени различаются цветом, а не числом значков:
    /// две звёздочки рядом на плитке читались бы хуже, чем один значок,
    /// сменивший цвет.
    enum FlagLevel: Int {
        case none = 0
        case candidate = 1
        case confirmed = 2

        /// Следующая ступень по кругу: нажатие перебирает их по очереди.
        var next: FlagLevel {
            switch self {
            case .none: return .candidate
            case .candidate: return .confirmed
            case .confirmed: return .none
            }
        }
    }

    static func flagLevel(_ values: [FPFinderTag]) -> FlagLevel {
        if values.contains(where: { normalizedTitle($0.title) == normalizedTitle(confirmedFlagTitle) }) {
            return .confirmed
        }
        if values.contains(where: { normalizedTitle($0.title) == normalizedTitle(selectedFlagTitle) }) {
            return .candidate
        }
        return .none
    }

    static func flagLevel(url: URL) -> FlagLevel {
        flagLevel(tags(for: url))
    }

    static func isFlagged(_ values: [FPFinderTag]) -> Bool {
        flagLevel(values) != .none
    }

    static func isFlagged(url: URL) -> Bool {
        isFlagged(tags(for: url))
    }

    /// Ставит ступень отметки, не трогая цветную метку файла.
    @discardableResult
    static func setFlagLevel(_ level: FlagLevel, on url: URL) throws -> [FPFinderTag] {
        var values = tags(for: url).filter {
            let title = normalizedTitle($0.title)
            return title != normalizedTitle(selectedFlagTitle)
                && title != normalizedTitle(confirmedFlagTitle)
        }
        switch level {
        case .none:
            break
        case .candidate:
            values.append(
                FPFinderTag(title: selectedFlagTitle, colorNumber: selectedFlagColorNumber)
            )
        case .confirmed:
            values.append(
                FPFinderTag(title: confirmedFlagTitle, colorNumber: confirmedFlagColorNumber)
            )
        }
        try write(values, to: url)
        return values
    }

    @discardableResult
    static func setFlag(_ flagged: Bool, on url: URL) throws -> [FPFinderTag] {
        try setFlagLevel(flagged ? .candidate : .none, on: url)
    }

    static func preferredTag(for url: URL, among values: [FPFinderTag]) -> FPFinderTag? {
        // Отметка «отобрано» не должна перекрашивать цветной кружок файла:
        // это независимая ось, у файла может быть и цвет, и отметка.
        let values = values.filter {
            let title = normalizedTitle($0.title)
            return title != normalizedTitle(selectedFlagTitle)
                && title != normalizedTitle(confirmedFlagTitle)
        }
        guard !values.isEmpty else { return nil }
        if let managedTitle = managedTitles()[url.standardizedFileURL.path],
           let managed = values.first(where: {
               normalizedTitle($0.title) == normalizedTitle(managedTitle)
           }) {
            return managed
        }
        let knownTitles = Set(FPTag.all.map { normalizedTitle($0.title) })
        return values.first(where: { knownTitles.contains(normalizedTitle($0.title)) }) ?? values.first
    }

    static func hasManagedRecord(for url: URL) -> Bool {
        managedTitles()[url.standardizedFileURL.path] != nil
    }

    static func reconcileMissingTags(for url: URL) {
        let path = url.standardizedFileURL.path
        var managed = managedTitles()
        guard managed.removeValue(forKey: path) != nil else { return }
        saveManagedTitles(managed)
    }

    static func moveManagedRecord(from source: URL, to destination: URL) {
        var managed = managedTitles()
        guard let value = managed.removeValue(forKey: source.standardizedFileURL.path) else { return }
        managed[destination.standardizedFileURL.path] = value
        saveManagedTitles(managed)
    }

    static func finderColorNumber(for tag: FPTag) -> Int {
        switch tag.key {
        case "gray": return 1
        case "green": return 2
        case "purple": return 3
        case "blue": return 4
        case "yellow": return 5
        case "red": return 6
        case "orange": return 7
        default:
            let color = tag.color.usingColorSpace(.deviceRGB) ?? tag.color
            let candidates: [(Int, NSColor)] = [
                (1, NSColor(calibratedWhite: 0.68, alpha: 1)),
                (2, NSColor(calibratedRed: 0.10, green: 0.86, blue: 0.35, alpha: 1)),
                (3, NSColor(calibratedRed: 0.78, green: 0.32, blue: 0.92, alpha: 1)),
                (4, NSColor(calibratedRed: 0.08, green: 0.58, blue: 0.92, alpha: 1)),
                (5, NSColor(calibratedRed: 1.00, green: 0.84, blue: 0.02, alpha: 1)),
                (6, NSColor(calibratedRed: 1.00, green: 0.27, blue: 0.25, alpha: 1)),
                (7, FPStyle.orange)
            ]
            return candidates.min(by: {
                colorDistance(color, $0.1) < colorDistance(color, $1.1)
            })?.0 ?? 0
        }
    }

    static func color(forFinderNumber number: Int) -> NSColor {
        switch number {
        case 1: return NSColor(calibratedWhite: 0.68, alpha: 1)
        case 2: return NSColor(calibratedRed: 0.10, green: 0.86, blue: 0.35, alpha: 1)
        case 3: return NSColor(calibratedRed: 0.78, green: 0.32, blue: 0.92, alpha: 1)
        case 4: return NSColor(calibratedRed: 0.08, green: 0.58, blue: 0.92, alpha: 1)
        case 5: return NSColor(calibratedRed: 1.00, green: 0.84, blue: 0.02, alpha: 1)
        case 6: return NSColor(calibratedRed: 1.00, green: 0.27, blue: 0.25, alpha: 1)
        case 7: return FPStyle.orange
        default: return NSColor(calibratedWhite: 0.68, alpha: 1)
        }
    }

    static func migrateLegacyAssignmentsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationDefaultsKey) else { return }
        let assignments = defaults.dictionary(forKey: "FolderColors") as? [String: String] ?? [:]
        for (path, key) in assignments {
            guard FileManager.default.fileExists(atPath: path),
                  let tag = FPTag.all.first(where: { $0.key == key }) else { continue }
            _ = try? setQyvroTag(tag, on: URL(fileURLWithPath: path), legacyManagedTitle: tag.title)
        }
        defaults.set(true, forKey: migrationDefaultsKey)
    }

    static func write(_ tags: [FPFinderTag], to url: URL) throws {
        if tags.isEmpty {
            let result = url.path.withCString { path in
                attributeName.withCString { name in
                    removexattr(path, name, 0)
                }
            }
            if result != 0, errno != ENOATTR {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return
        }

        let data = try PropertyListSerialization.data(
            fromPropertyList: tags.map(\.encodedValue),
            format: .binary,
            options: 0
        )
        let result = data.withUnsafeBytes { bytes in
            url.path.withCString { path in
                attributeName.withCString { name in
                    setxattr(path, name, bytes.baseAddress, data.count, 0, 0)
                }
            }
        }
        if result != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func extendedAttribute(named name: String, at url: URL) -> Data? {
        let size = url.path.withCString { path in
            name.withCString { attribute in
                getxattr(path, attribute, nil, 0, 0, 0)
            }
        }
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let readCount = data.withUnsafeMutableBytes { bytes in
            url.path.withCString { path in
                name.withCString { attribute in
                    getxattr(path, attribute, bytes.baseAddress, size, 0, 0)
                }
            }
        }
        guard readCount == size else { return nil }
        return data
    }

    private static func managedTitles() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: managedDefaultsKey) as? [String: String] ?? [:]
    }

    private static func saveManagedTitles(_ values: [String: String]) {
        UserDefaults.standard.set(values, forKey: managedDefaultsKey)
    }

    private static func normalizedTitle(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func colorDistance(_ lhs: NSColor, _ rhs: NSColor) -> Double {
        let left = lhs.usingColorSpace(.deviceRGB) ?? lhs
        let right = rhs.usingColorSpace(.deviceRGB) ?? rhs
        let red = Double(left.redComponent - right.redComponent)
        let green = Double(left.greenComponent - right.greenComponent)
        let blue = Double(left.blueComponent - right.blueComponent)
        return red * red + green * green + blue * blue
    }
}
