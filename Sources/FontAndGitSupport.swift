import Cocoa
import CoreText

/// Generates crisp editorial font thumbnails for grid/list tiles and a full
/// typographic specimen preview sheet for the built-in viewer (`Space`).
enum FPFontPreviewRenderer {
    static let fontExtensions: Set<String> = ["ttf", "otf", "ttc", "dfont"]

    private static let thumbCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        return cache
    }()

    static func isFontURL(_ url: URL) -> Bool {
        fontExtensions.contains(url.pathExtension.lowercased())
    }

    static func loadFontDescriptor(from url: URL) -> CTFontDescriptor? {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let first = descriptors.first else {
            return nil
        }
        return first
    }

    static func thumbnail(for url: URL, size: CGFloat) -> NSImage? {
        let bucket = Int((max(size, 32) / 16).rounded() * 16)
        let key = "\(url.standardizedFileURL.path)|\(bucket)|\(FPStyle.isObsidianAurora ? 1 : 0)" as NSString
        if let cached = thumbCache.object(forKey: key) {
            return cached
        }
        guard let descriptor = loadFontDescriptor(from: url) else { return nil }
        let s = CGFloat(bucket)
        let familyName = (CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let displayFont = CTFontCreateWithFontDescriptor(descriptor, max(16, s * 0.42), nil) as NSFont

        let image = NSImage(size: NSSize(width: s, height: s), flipped: false) { rect in
            let card = rect.insetBy(dx: s * 0.08, dy: s * 0.06)
            let radius = max(5, s * 0.11)
            let path = NSBezierPath(roundedRect: card, xRadius: radius, yRadius: radius)

            let topCol = NSColor(srgbRed: 0.145, green: 0.132, blue: 0.142, alpha: 1)
            let botCol = NSColor(srgbRed: 0.082, green: 0.075, blue: 0.085, alpha: 1)
            NSGradient(starting: botCol, ending: topCol)?.draw(in: path, angle: 90)

            FPStyle.stroke.withAlphaComponent(0.65).setStroke()
            path.lineWidth = max(0.8, s * 0.012)
            path.stroke()

            // Subtle warm top highlight
            if s >= 48 {
                let badgeH = max(14, s * 0.22)
                let sepY = card.minY + badgeH
                NSColor.white.withAlphaComponent(0.08).setFill()
                NSRect(x: card.minX + s * 0.08, y: sepY, width: card.width - s * 0.16, height: 0.75).fill()

                let metaPara = NSMutableParagraphStyle()
                metaPara.alignment = .center
                metaPara.lineBreakMode = .byTruncatingTail
                let labelStr = NSAttributedString(
                    string: familyName,
                    attributes: [
                        .font: FPStyle.monoMetaFont(ofSize: max(7.5, s * 0.095), weight: .medium),
                        .foregroundColor: FPStyle.orange.withAlphaComponent(0.88),
                        .paragraphStyle: metaPara
                    ]
                )
                labelStr.draw(in: NSRect(
                    x: card.minX + 5,
                    y: card.minY + (badgeH - labelStr.size().height) * 0.5,
                    width: card.width - 10,
                    height: badgeH
                ))
            }

            let aaPara = NSMutableParagraphStyle()
            aaPara.alignment = .center
            let aaStr = NSAttributedString(
                string: "Aa",
                attributes: [
                    .font: displayFont,
                    .foregroundColor: FPStyle.text,
                    .paragraphStyle: aaPara
                ]
            )
            let aaSize = aaStr.size()
            let contentMinY = s >= 48 ? card.minY + max(14, s * 0.22) : card.minY
            let contentH = card.maxY - contentMinY
            aaStr.draw(in: NSRect(
                x: card.minX + 4,
                y: contentMinY + (contentH - aaSize.height) * 0.5,
                width: card.width - 8,
                height: aaSize.height + 6
            ))
            return true
        }

        thumbCache.setObject(image, forKey: key)
        return image
    }

    static func specimenImage(for url: URL, canvasSize: NSSize = NSSize(width: 1120, height: 760)) -> NSImage? {
        guard let descriptor = loadFontDescriptor(from: url) else { return nil }
        let family = (CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let style = (CTFontDescriptorCopyAttribute(descriptor, kCTFontStyleNameAttribute) as? String) ?? "Regular"
        let psName = (CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String) ?? url.lastPathComponent

        let image = NSImage(size: canvasSize, flipped: true) { rect in
            let bg = NSColor(srgbRed: 0.070, green: 0.062, blue: 0.072, alpha: 1)
            bg.setFill()
            rect.fill()

            let padX: CGFloat = 56
            var y: CGFloat = 46

            // Header metadata
            let kicker = NSAttributedString(
                string: "\(url.pathExtension.uppercased())  ·  \(style)  ·  \(psName)",
                attributes: [
                    .font: FPStyle.monoMetaFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: FPStyle.orange
                ]
            )
            kicker.draw(at: NSPoint(x: padX, y: y))
            y += 28

            // Hero font name in the actual font
            let heroFont = CTFontCreateWithFontDescriptor(descriptor, 68, nil) as NSFont
            let heroStr = NSAttributedString(
                string: family,
                attributes: [.font: heroFont, .foregroundColor: FPStyle.text]
            )
            heroStr.draw(in: NSRect(x: padX, y: y, width: rect.width - padX * 2, height: 92))
            y += 96

            // Hairline divider
            NSColor.white.withAlphaComponent(0.10).setFill()
            NSRect(x: padX, y: y, width: rect.width - padX * 2, height: 1).fill()
            y += 26

            // Editorial size ramp (English + Cyrillic)
            let samples: [(CGFloat, String)] = [
                (40, "The quick brown fox jumps over the lazy dog."),
                (30, "Съешь же ещё этих мягких французских булок, да выпей чаю."),
                (22, "ABCDEFGHIJKLMNOPQRSTUVWXYZ  ·  0123456789"),
                (20, "abcdefghijklmnopqrstuvwxyz  ·  абвгдеёжзийклмнопрстуфхцчшщъыьэюя"),
                (16, "! @ # $ % ^ & * ( ) — – + = [ ] { } / \\ : ; \" ' , . ?  ·  5504×3072 · 18.4 MB")
            ]

            for (pt, text) in samples {
                let sizeTag = NSAttributedString(
                    string: "\(Int(pt)) pt",
                    attributes: [
                        .font: FPStyle.monoMetaFont(ofSize: 11, weight: .medium),
                        .foregroundColor: FPStyle.dimText
                    ]
                )
                sizeTag.draw(at: NSPoint(x: padX, y: y + max(0, (pt - 14) * 0.35)))

                let f = CTFontCreateWithFontDescriptor(descriptor, pt, nil) as NSFont
                let para = NSMutableParagraphStyle()
                para.lineBreakMode = .byTruncatingTail
                let line = NSAttributedString(
                    string: text,
                    attributes: [
                        .font: f,
                        .foregroundColor: FPStyle.text.withAlphaComponent(0.94),
                        .paragraphStyle: para
                    ]
                )
                line.draw(in: NSRect(x: padX + 62, y: y, width: rect.width - padX * 2 - 62, height: pt * 1.48))
                y += max(36, pt * 1.62)
            }

            // Large decorative glyph showcase at bottom
            y = max(y + 12, rect.height - 160)
            NSColor.white.withAlphaComponent(0.08).setFill()
            NSRect(x: padX, y: y - 16, width: rect.width - padX * 2, height: 1).fill()

            let specimenFont = CTFontCreateWithFontDescriptor(descriptor, 86, nil) as NSFont
            let glyphs = NSAttributedString(
                string: "Aa Bb Qq 0123456789 & ?",
                attributes: [
                    .font: specimenFont,
                    .foregroundColor: FPStyle.orange.withAlphaComponent(0.86)
                ]
            )
            glyphs.draw(in: NSRect(x: padX, y: y, width: rect.width - padX * 2, height: 120))
            return true
        }
        return image
    }
}

/// Renders tiny 14x14 circular palette swatches for the 17 themes in dropdown menus.
enum FPThemeSwatchRenderer {
    private static var cache: [String: NSImage] = [:]

    static func swatch(for preset: FPThemePreset) -> NSImage {
        let key = preset.title
        if let cached = cache[key] { return cached }
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            let inset = rect.insetBy(dx: 1, dy: 1)
            let circle = NSBezierPath(ovalIn: inset)
            if let grad = NSGradient(starting: preset.gradientEnd, ending: preset.accent) {
                grad.draw(in: circle, angle: 45)
            } else {
                preset.accent.setFill()
                circle.fill()
            }
            NSColor.white.withAlphaComponent(0.28).setStroke()
            circle.lineWidth = 0.8
            circle.stroke()
            return true
        }
        cache[key] = image
        return image
    }
}

/// Lightweight, non-blocking Git branch & dirty count detector for Studio header.
/// Returns `nil` immediately (<0.1ms) when a folder has no `.git` ancestor.
struct QyvroGitSummary: Equatable {
    let repoRoot: String
    let branch: String
    let dirtyCount: Int

    var badgeText: String {
        dirtyCount > 0 ? "\(branch) · \(dirtyCount)" : branch
    }
}

final class QyvroGitStatusProvider {
    static let shared = QyvroGitStatusProvider()

    private struct CacheEntry {
        let timestamp: Date
        let summary: QyvroGitSummary
    }

    private let queue = DispatchQueue(label: "Qyvro.GitStatus", qos: .utility)
    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]

    private init() {}

    func fetchStatus(for directory: URL, completion: @escaping (QyvroGitSummary?) -> Void) {
        let std = directory.standardizedFileURL
        queue.async { [weak self] in
            guard let self else { return }
            guard let repoRoot = Self.findGitRoot(startingAt: std) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            self.lock.lock()
            if let entry = self.cache[repoRoot], Date().timeIntervalSince(entry.timestamp) < 4.0 {
                self.lock.unlock()
                DispatchQueue.main.async { completion(entry.summary) }
                return
            }
            self.lock.unlock()

            let summary = Self.runGitStatus(in: repoRoot)
            if let summary {
                self.lock.lock()
                if self.cache.count > 24 { self.cache.removeAll() }
                self.cache[repoRoot] = CacheEntry(timestamp: Date(), summary: summary)
                self.lock.unlock()
            }
            DispatchQueue.main.async { completion(summary) }
        }
    }

    private static func findGitRoot(startingAt url: URL) -> String? {
        let fm = FileManager.default
        var current = url
        var depth = 0
        while depth < 12 {
            let dotGit = current.appendingPathComponent(".git")
            if fm.fileExists(atPath: dotGit.path) {
                return current.path
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
            depth += 1
        }
        return nil
    }

    private static func runGitStatus(in repoRoot: String) -> QyvroGitSummary? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", repoRoot, "status", "--porcelain=v1", "-b", "--untracked-files=normal"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8) else { return nil }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            guard let first = lines.first, first.hasPrefix("## ") else { return nil }
            var branchPart = String(first.dropFirst(3))
            if let dots = branchPart.range(of: "...") {
                branchPart = String(branchPart[..<dots.lowerBound])
            }
            if branchPart.hasPrefix("No commits yet on ") {
                branchPart = String(branchPart.dropFirst("No commits yet on ".count))
            } else if branchPart.hasPrefix("HEAD (no branch)") {
                branchPart = "detached"
            }
            let dirty = max(0, lines.count - 1)
            return QyvroGitSummary(repoRoot: repoRoot, branch: branchPart, dirtyCount: dirty)
        } catch {
            return nil
        }
    }
}
