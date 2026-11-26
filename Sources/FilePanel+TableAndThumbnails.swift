import AVFoundation
import Cocoa
import ImageIO
import QuickLookThumbnailing

extension FilePanel {
    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredItems.count
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row >= 0, row < filteredItems.count else { return nil }
        return filteredItems[row].url as NSURL
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        activate()
        footerLabel.stringValue = footerText()
        syncFolderPocketToSelection()
        notifySelectionChanged()
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        syncSortControl()
        if virtualTagTitle == nil && virtualSearchTitle == nil {
            FPFolderProfileStore.shared.record(for: currentURL, sortKey: currentSortKey, sortAscending: currentSortAscending)
        }
        sortItems()
        applyFilter()
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = PanelRowView()
        rowView.rowColor = row.isMultiple(of: 2) ? FPStyle.rowA : FPStyle.rowB
        if filteredItems.indices.contains(row) {
            rowView.alphaValue = FPCutFileState.shared.contains(filteredItems[row].url) ? 0.42 : 1
        }
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0 && row < filteredItems.count, let column = tableColumn else { return nil }
        let item = filteredItems[row]
        switch column.identifier.rawValue {
        case "name":
            return nameCell(for: item)
        case "size":
            return textCell(identifier: "SizeCell", text: item.isDirectory ? "-" : byteString(item.size ?? 0), alignment: .right)
        case "created":
            return textCell(identifier: "CreatedCell", text: item.created.map { dateFormatter.string(from: $0) } ?? "-", alignment: .left)
        case "modified":
            return textCell(identifier: "ModifiedCell", text: item.modified.map { dateFormatter.string(from: $0) } ?? "-", alignment: .left)
        case "kind":
            return textCell(identifier: "KindCell", text: item.kind, alignment: .left)
        default:
            return textCell(identifier: "TextCell", text: "", alignment: .left)
        }
    }

    func nameCell(for item: FileItem) -> NSTableCellView {
        let size = visibleIconSize
        let identifier = NSUserInterfaceItemIdentifier("NameCell-\(Int(size))")
        let isAurora = FPStyle.isObsidianAurora
        let nameFont = FPStyle.bodyFont(
            ofSize: viewMode == .largeIcons ? 13 : (isAurora ? 12.2 : 12),
            weight: isAurora ? .medium : .regular
        )
        let nameColor = item.isHidden ? FPStyle.dimText.withAlphaComponent(0.55) : FPStyle.text
        if let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView,
           let textField = cell.textField,
           let imageView = cell.imageView {
            textField.stringValue = item.name
            textField.textColor = nameColor
            imageView.image = displayImage(for: item, size: size)
            textField.font = nameFont
            textField.toolTip = hoverTooltip(for: item, availableWidth: tableNameTextWidth(iconSize: size))
            return cell
        }

        let cell = NSTableCellView()
        cell.identifier = identifier

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 5
        imageView.layer?.masksToBounds = true
        imageView.image = displayImage(for: item, size: size)

        let textField = NSTextField(labelWithString: item.name)
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.lineBreakMode = .byTruncatingMiddle
        textField.textColor = nameColor
        textField.font = nameFont
        textField.toolTip = hoverTooltip(for: item, availableWidth: tableNameTextWidth(iconSize: size))

        cell.addSubview(imageView)
        cell.addSubview(textField)
        cell.imageView = imageView
        cell.textField = textField

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: size),
            imageView.heightAnchor.constraint(equalToConstant: size),
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 9),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])

        return cell
    }

    func tableNameTextWidth(iconSize: CGFloat) -> CGFloat {
        let nameWidth = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("name"))?.width ?? 280
        return max(40, nameWidth - iconSize - 24)
    }

    func hoverTooltip(for item: FileItem, availableWidth: CGFloat) -> String? {
        let font = NSFont.systemFont(ofSize: viewMode == .largeIcons ? 13 : 12, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let width = (item.name as NSString).size(withAttributes: attrs).width
        guard width > availableWidth else { return nil }
        if item.isDirectory {
            return item.name
        }
        let size = ByteCountFormatter.string(fromByteCount: item.size ?? 0, countStyle: .file)
        return "\(item.name)\nРазмер: \(size)"
    }

    func displayImage(for item: FileItem, size: CGFloat) -> NSImage {
        if item.isDirectory {
            if let custom = CustomFolderIconStore.shared.image(for: item.url) {
                return custom
            }
            return coloredFolderIcon(color: folderColor(for: item.url) ?? FPStyle.defaultFolder, size: size)
        }

        let key = thumbnailKey(for: item, size: size)
        if let cached = ThumbnailDiskCache.shared.image(for: key) {
            return cached
        }

        requestThumbnail(for: item.url, size: size, key: key)

        return WorkspaceIconCache.shared.icon(for: item.url, size: size)
    }

    func requestThumbnail(for url: URL, size: CGFloat, key: String) {
        guard !pendingThumbnailKeys.contains(key) else { return }
        pendingThumbnailKeys.insert(key)

        ThumbnailDiskCache.shared.loadFromDisk(for: key) { [weak self] image in
            guard let self, self.pendingThumbnailKeys.contains(key) else { return }
            if let image {
                self.pendingThumbnailKeys.remove(key)
                self.storeThumbnail(image, key: key, persist: false)
                self.reloadNameCell(for: url)
                return
            }
            if self.isImageFile(url) {
                self.generateImagePreview(for: url, size: size, key: key)
            } else if self.isVideoFile(url) {
                self.generateVideoPreview(for: url, size: size, key: key)
            } else {
                self.requestQuickLookThumbnail(for: url, size: size, key: key)
            }
        }
    }

    func generateImagePreview(for url: URL, size: CGFloat, key: String) {
        let pixelSize = max(96, Int((size * (NSScreen.main?.backingScaleFactor ?? 2)).rounded()))
        var operation: BlockOperation!
        operation = BlockOperation { [weak self] in
            guard !operation.isCancelled else { return }
            let image = autoreleasepool { self?.downsampledImage(at: url, maxPixelSize: pixelSize) }
            guard !operation.isCancelled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pendingThumbnailKeys.contains(key), !operation.isCancelled else { return }
                self.thumbnailOperations.removeValue(forKey: key)
                self.pendingThumbnailKeys.remove(key)
                guard let image else { return }
                self.storeThumbnail(image, key: key)
                self.reloadNameCell(for: url)
            }
        }
        thumbnailOperations[key] = operation
        imageLoadQueue.addOperation(operation)
    }

    func requestQuickLookThumbnail(for url: URL, size: CGFloat, key: String) {
        // The key is inserted before the disk-cache lookup. Requiring it to be
        // absent here made every non-image request return immediately, which is
        // why MP4/PDF files were stuck on generic document icons.
        guard pendingThumbnailKeys.contains(key) else { return }

        if #available(macOS 10.15, *) {
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: size, height: size),
                scale: min(NSScreen.main?.backingScaleFactor ?? 2, 2),
                representationTypes: [.thumbnail, .icon]
            )
            quickLookRequests[key] = request
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, _ in
                guard let self else { return }
                DispatchQueue.main.async {
                    guard self.pendingThumbnailKeys.contains(key) else { return }
                    self.quickLookRequests.removeValue(forKey: key)
                    self.pendingThumbnailKeys.remove(key)
                    guard let image = thumbnail?.nsImage else { return }
                    self.storeThumbnail(image, key: key)
                    self.reloadNameCell(for: url)
                }
            }
        } else {
            pendingThumbnailKeys.remove(key)
        }
    }

    func generateVideoPreview(for url: URL, size: CGFloat, key: String) {
        guard pendingThumbnailKeys.contains(key) else { return }
        let scale = min(NSScreen.main?.backingScaleFactor ?? 2, 2)
        let pixelSize = max(128, size * scale)
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: pixelSize, height: pixelSize)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        videoThumbnailGenerators[key] = generator
        let previewTime = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.generateCGImageAsynchronously(for: previewTime) { [weak self] image, _, _ in
            DispatchQueue.main.async {
                guard let self, self.pendingThumbnailKeys.contains(key) else { return }
                self.videoThumbnailGenerators.removeValue(forKey: key)
                guard let image else {
                    self.requestQuickLookThumbnail(for: url, size: size, key: key)
                    return
                }
                self.pendingThumbnailKeys.remove(key)
                let thumbnail = NSImage(
                    cgImage: image,
                    size: NSSize(width: image.width, height: image.height)
                )
                self.storeThumbnail(thumbnail, key: key)
                self.reloadNameCell(for: url)
            }
        }
    }

    func storeThumbnail(_ image: NSImage, key: String, persist: Bool = true) {
        ThumbnailDiskCache.shared.store(image, for: key, persist: persist)
    }

    func cancelThumbnailRequests(except allowedKeys: Set<String>) {
        let keysToCancel = pendingThumbnailKeys.subtracting(allowedKeys)
        guard !keysToCancel.isEmpty else { return }
        for key in keysToCancel {
            thumbnailOperations.removeValue(forKey: key)?.cancel()
            if let request = quickLookRequests.removeValue(forKey: key) {
                QLThumbnailGenerator.shared.cancel(request)
            }
            if let generator = videoThumbnailGenerators.removeValue(forKey: key) {
                generator.cancelAllCGImageGeneration()
            }
            pendingThumbnailKeys.remove(key)
        }
    }

    func downsampledImage(at url: URL, maxPixelSize: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    func reloadNameCell(for url: URL) {
        guard let index = filteredIndexByPath[url.path] else { return }
        let rows = IndexSet(integer: index)
        if viewMode == .largeIcons {
            for cell in gridItemViews where cell.itemIndex == index {
                let item = filteredItems[cell.itemIndex]
                cell.configure(
                    item: item,
                    image: displayImage(for: item, size: visibleIconSize),
                    imageSize: visibleIconSize,
                    selected: gridSelectionIndexes.contains(cell.itemIndex),
                    cut: FPCutFileState.shared.contains(item.url),
                    versionCount: versionGroupCounts[item.url.path] ?? 0,
                    flagLevel: flagLevel(for: item)
                )
            }
        } else {
            tableView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
        }
    }

    func thumbnailKey(for item: FileItem, size: CGFloat) -> String {
        let modified = Int64((item.modified ?? .distantPast).timeIntervalSince1970)
        return "\(item.url.standardizedFileURL.path)|\(modified)|\(Int(size.rounded()))"
    }

    func isImageFile(_ url: URL) -> Bool {
        FPMediaInfoCache.imageExtensions.contains(url.pathExtension.lowercased())
    }

    func isVideoFile(_ url: URL) -> Bool {
        FPMediaInfoCache.movieExtensions.contains(url.pathExtension.lowercased())
    }

    func folderColorOptions() -> [(title: String, key: String?)] {
        [("По умолчанию", nil)] + FPTag.all.map { ($0.title, $0.key) }
    }

    func folderColorMap() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: "FolderColors") as? [String: String] ?? [:]
    }

    func folderColor(for url: URL) -> NSColor? {
        guard let name = folderColorMap()[url.path] else { return nil }
        switch name {
        case let key where FPTag.color(for: key) != nil:
            return FPTag.color(for: key)
        case "teal":
            return FPStyle.accent
        case "pink":
            return NSColor(calibratedRed: 0.92, green: 0.30, blue: 0.58, alpha: 1)
        default:
            return nil
        }
    }
}

/// Единый рендерер минималистичных V4-иконок папок (используется в сетке,
/// списке и боковой панели предпросмотра).
enum FPFolderIconRenderer {
    static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 180
        return c
    }()

    static func invalidateCache() {
        cache.removeAllObjects()
    }

    static func icon(color: NSColor, size: CGFloat) -> NSImage {
        let aurora = FPStyle.isObsidianAurora
        let style = FPFolderIconStyle.current
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        let key = String(
            format: "%@_%@_%.3f_%.3f_%.3f_%.3f_%d",
            aurora ? "v4" : "v2",
            style.rawValue,
            rgb.redComponent,
            rgb.greenComponent,
            rgb.blueComponent,
            rgb.alphaComponent,
            Int(size.rounded())
        ) as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            if aurora {
                guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
                ctx.saveGState()
                ctx.setAllowsAntialiasing(true)
                ctx.setShouldAntialias(true)

                let s = size
                let small = s < 26
                let leftX = s * 0.06
                let rightX = s * 0.94
                let w = rightX - leftX
                let baseY = s * 0.16
                let bodyH = s * 0.515
                let shoulderY = baseY + bodyH + s * 0.048
                let tabTopY = baseY + bodyH + s * 0.155
                let r = max(2.2, s * 0.092)
                let tabEndX = leftX + w * 0.34
                let slopeEndX = leftX + w * 0.45
                let tabR = max(1.8, s * 0.068)

                let backPath = NSBezierPath()
                backPath.move(to: NSPoint(x: leftX, y: baseY + r))
                backPath.line(to: NSPoint(x: leftX, y: tabTopY - tabR))
                backPath.curve(
                    to: NSPoint(x: leftX + tabR, y: tabTopY),
                    controlPoint1: NSPoint(x: leftX, y: tabTopY),
                    controlPoint2: NSPoint(x: leftX, y: tabTopY)
                )
                backPath.line(to: NSPoint(x: tabEndX - tabR * 0.35, y: tabTopY))
                backPath.curve(
                    to: NSPoint(x: slopeEndX, y: shoulderY),
                    controlPoint1: NSPoint(x: tabEndX + s * 0.032, y: tabTopY),
                    controlPoint2: NSPoint(x: slopeEndX - s * 0.042, y: shoulderY)
                )
                backPath.line(to: NSPoint(x: rightX - r, y: shoulderY))
                backPath.curve(
                    to: NSPoint(x: rightX, y: shoulderY - r),
                    controlPoint1: NSPoint(x: rightX, y: shoulderY),
                    controlPoint2: NSPoint(x: rightX, y: shoulderY)
                )
                backPath.line(to: NSPoint(x: rightX, y: baseY + r))
                backPath.curve(
                    to: NSPoint(x: rightX - r, y: baseY),
                    controlPoint1: NSPoint(x: rightX, y: baseY),
                    controlPoint2: NSPoint(x: rightX, y: baseY)
                )
                backPath.line(to: NSPoint(x: leftX + r, y: baseY))
                backPath.curve(
                    to: NSPoint(x: leftX, y: baseY + r),
                    controlPoint1: NSPoint(x: leftX, y: baseY),
                    controlPoint2: NSPoint(x: leftX, y: baseY)
                )
                backPath.close()

                let darkAnchor = NSColor(srgbRed: 0.085, green: 0.076, blue: 0.080, alpha: 1)
                let backTop: NSColor
                let backBot: NSColor
                let frontTop: NSColor
                let frontBot: NSColor

                switch style {
                case .matteDuo:
                    backTop = color.blended(withFraction: 0.25, of: darkAnchor) ?? color
                    backBot = color.blended(withFraction: 0.50, of: darkAnchor) ?? color
                    let slateTop = NSColor(srgbRed: 0.210, green: 0.192, blue: 0.190, alpha: 1)
                    let slateBot = NSColor(srgbRed: 0.138, green: 0.126, blue: 0.128, alpha: 1)
                    frontTop = slateTop.blended(withFraction: 0.15, of: color) ?? slateTop
                    frontBot = slateBot.blended(withFraction: 0.09, of: color) ?? slateBot
                case .monotoneSatin:
                    backTop = color.blended(withFraction: 0.54, of: darkAnchor) ?? color
                    backBot = color.blended(withFraction: 0.70, of: darkAnchor) ?? color
                    frontTop = color.blended(withFraction: 0.40, of: darkAnchor) ?? color
                    frontBot = color.blended(withFraction: 0.60, of: darkAnchor) ?? color
                case .swissSeam:
                    let chTop = NSColor(srgbRed: 0.175, green: 0.162, blue: 0.168, alpha: 1)
                    let chBot = NSColor(srgbRed: 0.115, green: 0.108, blue: 0.114, alpha: 1)
                    backTop = chTop.blended(withFraction: 0.10, of: color) ?? chTop
                    backBot = chBot
                    let fTop = NSColor(srgbRed: 0.215, green: 0.200, blue: 0.208, alpha: 1)
                    let fBot = NSColor(srgbRed: 0.145, green: 0.135, blue: 0.142, alpha: 1)
                    frontTop = fTop.blended(withFraction: 0.08, of: color) ?? fTop
                    frontBot = fBot.blended(withFraction: 0.05, of: color) ?? fBot
                }

                if !small {
                    ctx.saveGState()
                    ctx.setShadow(
                        offset: CGSize(width: 0, height: -s * 0.026),
                        blur: s * 0.062,
                        color: NSColor.black.withAlphaComponent(0.46).cgColor
                    )
                    backBot.setFill()
                    backPath.fill()
                    ctx.restoreGState()
                }
                if let backGrad = NSGradient(starting: backBot, ending: backTop) {
                    backGrad.draw(in: backPath, angle: 90)
                } else {
                    backTop.setFill()
                    backPath.fill()
                }

                if style == .swissSeam {
                    NSColor.white.withAlphaComponent(0.08).setStroke()
                    backPath.lineWidth = max(0.65, s * 0.009)
                    backPath.stroke()

                    let seamH = max(2.0, s * 0.036)
                    let seamRect = NSRect(
                        x: leftX + s * 0.05,
                        y: baseY + bodyH - seamH * 0.32,
                        width: w - s * 0.10,
                        height: seamH
                    )
                    (color.blended(withFraction: 0.12, of: .white) ?? color)
                        .withAlphaComponent(0.92)
                        .setFill()
                    NSBezierPath(roundedRect: seamRect, xRadius: seamH / 2, yRadius: seamH / 2).fill()
                }

                let frontRect = NSRect(x: leftX, y: baseY, width: w, height: bodyH)
                let frontPath = NSBezierPath(roundedRect: frontRect, xRadius: r, yRadius: r)

                if !small {
                    ctx.saveGState()
                    ctx.setShadow(
                        offset: CGSize(width: 0, height: s * 0.010),
                        blur: s * 0.024,
                        color: NSColor.black.withAlphaComponent(0.32).cgColor
                    )
                    frontBot.setFill()
                    frontPath.fill()
                    ctx.restoreGState()
                }
                if let frontGrad = NSGradient(starting: frontBot, ending: frontTop) {
                    frontGrad.draw(in: frontPath, angle: 90)
                } else {
                    frontTop.setFill()
                    frontPath.fill()
                }

                ctx.saveGState()
                frontPath.addClip()
                let lipH = max(0.9, s * 0.013)
                NSColor.white.withAlphaComponent(small ? 0.18 : 0.14).setFill()
                NSRect(x: frontRect.minX, y: frontRect.maxY - lipH, width: frontRect.width, height: lipH).fill()
                ctx.restoreGState()

                NSColor.white.withAlphaComponent(small ? 0.10 : 0.075).setStroke()
                frontPath.lineWidth = max(0.65, s * 0.009)
                frontPath.stroke()
                ctx.restoreGState()
            } else {
                let rect = NSRect(x: size * 0.06, y: size * 0.15, width: size * 0.88, height: size * 0.62)
                let tabRect = NSRect(x: size * 0.10, y: size * 0.62, width: size * 0.38, height: size * 0.20)
                color.withAlphaComponent(0.88).setFill()
                NSBezierPath(roundedRect: tabRect, xRadius: max(2, size * 0.08), yRadius: max(2, size * 0.08)).fill()
                color.setFill()
                NSBezierPath(roundedRect: rect, xRadius: max(3, size * 0.10), yRadius: max(3, size * 0.10)).fill()
                NSColor.black.withAlphaComponent(0.22).setStroke()
                NSBezierPath(roundedRect: rect, xRadius: max(3, size * 0.10), yRadius: max(3, size * 0.10)).stroke()
            }
            return true
        }
        cache.setObject(image, forKey: key)
        return image
    }
}

extension FilePanel {
    func coloredFolderIcon(color: NSColor, size: CGFloat) -> NSImage {
        FPFolderIconRenderer.icon(color: color, size: size)
    }

    func textCell(identifier: String, text: String, alignment: NSTextAlignment) -> NSTableCellView {
        let viewID = NSUserInterfaceItemIdentifier(identifier)
        let isAurora = FPStyle.isObsidianAurora
        let isNumericOrDate = (identifier == "SizeCell" || identifier == "CreatedCell" || identifier == "ModifiedCell")
        let font: NSFont
        if isNumericOrDate {
            font = isAurora
                ? FPStyle.monoMetaFont(ofSize: 10.8, weight: .regular)
                : .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        } else {
            font = FPStyle.bodyFont(ofSize: 11.5, weight: .regular)
        }
        let color = isAurora ? FPStyle.dimText : FPStyle.text.withAlphaComponent(0.85)

        if let cell = tableView.makeView(withIdentifier: viewID, owner: self) as? NSTableCellView,
           let field = cell.textField {
            field.stringValue = text
            field.alignment = alignment
            field.font = font
            field.textColor = color
            return cell
        }

        let cell = NSTableCellView()
        cell.identifier = viewID
        let field = NSTextField(labelWithString: text)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingMiddle
        field.alignment = alignment
        cell.addSubview(field)
        cell.textField = field
        // Щедрый правый отступ у «Размера» (14 pt) и левый у остальных колонок (10 pt),
        // чтобы числа «30,8 MB» никогда не слипались с датой «26 Nov 2026».
        let leading: CGFloat = alignment == .right ? 4 : 10
        let trailing: CGFloat = alignment == .right ? -14 : -8
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: leading),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: trailing),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
