import Cocoa
import Quartz

extension Notification.Name {
    static let qyvroLayoutDidChange = Notification.Name("QyvroLayoutDidChange")
}

/// Архитектура рабочего пространства Qyvro — переключается на лету без
/// перезапуска приложения.
enum QyvroWorkspaceLayout: String, CaseIterable {
    /// Флагман V4: парящий скруглённый «остров» внутри тёмной рамки,
    /// крупный editorial-заголовок папки, встроенный поиск и капсулы быстрого
    /// перехода/фильтрации — без боковой панели и без нижнего дока.
    case studioCanvas
    /// Edge-to-edge галерея без боковой панели + плавающий стеклянный док снизу
    /// и парящие вкладки-капсулы сверху.
    case floatingDock
    /// Узкая скульптурная иконочная рейка слева с кольцевым индикатором диска,
    /// чистая верхняя шапка и вкладки в нижней полосе.
    case edgeRail
    /// Классический полноразмерный сайдбар слева и вкладки сверху.
    case classicSidebar

    static let defaultsKey = "QyvroWorkspaceLayoutV3"

    static var current: QyvroWorkspaceLayout {
        if let raw = UserDefaults.standard.string(forKey: defaultsKey),
           let parsed = QyvroWorkspaceLayout(rawValue: raw) {
            return parsed
        }
        return FPStyle.isObsidianAurora ? .studioCanvas : .classicSidebar
    }

    static func setCurrent(_ layout: QyvroWorkspaceLayout) {
        guard current != layout else { return }
        UserDefaults.standard.set(layout.rawValue, forKey: defaultsKey)
        FPActionLog.action("макет окна → \(layout.title)")
        NotificationCenter.default.post(name: .qyvroLayoutDidChange, object: nil)
    }

    var title: String {
        switch self {
        case .studioCanvas: return L("Студия · Остров (V4)", "Studio · Island (V4)")
        case .floatingDock: return L("Подиум · Док снизу", "Podium · Bottom Dock")
        case .edgeRail: return L("Рейл · Узкая панель", "Edge Rail")
        case .classicSidebar: return L("Сайдбар · Классика", "Classic Sidebar")
        }
    }

    var shortTitle: String {
        switch self {
        case .studioCanvas: return L("Студия", "Studio")
        case .floatingDock: return L("Подиум", "Podium")
        case .edgeRail: return L("Рейл", "Rail")
        case .classicSidebar: return L("Сайдбар", "Sidebar")
        }
    }

    var symbol: String {
        switch self {
        case .studioCanvas: return "macwindow.on.rectangle"
        case .floatingDock: return "dock.rectangle"
        case .edgeRail: return "sidebar.squares.leading"
        case .classicSidebar: return "sidebar.left"
        }
    }
}

/// Скульптурный фон V3 «Аврора»: 90% бархатного обсидиана + органичная
/// световая дуга с мягким оптическим рифлением стекла и микрозерном против
/// бандинга. Рендерится один раз в кэшированный `CGImage` при смене темы,
/// поэтому вообще не нагружает прокрутку и анимации.
final class QyvroAuroraBackdropView: NSView {
    private static var renderedCache: [String: CGImage] = [:]
    private let artLayer = CALayer()
    private let topSpecularRim = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        artLayer.contentsGravity = .resize
        artLayer.magnificationFilter = .linear
        artLayer.minificationFilter = .trilinear
        artLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(artLayer)

        topSpecularRim.startPoint = CGPoint(x: 0.0, y: 0.5)
        topSpecularRim.endPoint = CGPoint(x: 1.0, y: 0.5)
        topSpecularRim.locations = [0.0, 0.25, 0.52, 0.78, 1.0]
        topSpecularRim.actions = ["colors": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(topSpecularRim)

        refreshTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        artLayer.frame = bounds
        topSpecularRim.frame = NSRect(x: 0, y: max(0, bounds.height - 1), width: bounds.width, height: 1)
    }

    func refreshTheme() {
        let active = FPStyle.isObsidianAurora
        isHidden = !active
        guard active else { return }

        let base = FPStyle.window
        let start = FPStyle.gradientStart
        let end = FPStyle.gradientEnd
        let accent = FPStyle.accent
        let enabled = FPStyle.gradientEnabled
        let paneOpacity = min(max(FPStyle.pane.alphaComponent, 0.15), 1.0)

        let key = Self.cacheKey(base: base, start: start, end: end, accent: accent, enabled: enabled, opacity: paneOpacity)
        if let cached = Self.renderedCache[key] {
            artLayer.contents = cached
        } else if let generated = Self.renderAuroraImage(
            base: base,
            start: start,
            end: end,
            accent: accent,
            gradientEnabled: enabled,
            paneOpacity: paneOpacity
        ) {
            if Self.renderedCache.count > 12 { Self.renderedCache.removeAll() }
            Self.renderedCache[key] = generated
            artLayer.contents = generated
        }

        topSpecularRim.colors = [
            NSColor.clear.cgColor,
            NSColor.white.withAlphaComponent(0.10).cgColor,
            accent.withAlphaComponent(0.24).cgColor,
            NSColor.white.withAlphaComponent(0.10).cgColor,
            NSColor.clear.cgColor
        ]
        needsLayout = true
    }

    private static func cacheKey(
        base: NSColor,
        start: NSColor,
        end: NSColor,
        accent: NSColor,
        enabled: Bool,
        opacity: CGFloat
    ) -> String {
        func sig(_ c: NSColor) -> String {
            let rgb = c.usingColorSpace(.deviceRGB) ?? c
            return String(format: "%.2f,%.2f,%.2f", rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
        }
        return "\(sig(base))|\(sig(start))|\(sig(end))|\(sig(accent))|\(enabled ? 1 : 0)|\(Int((opacity * 100).rounded()))"
    }

    private static func renderAuroraImage(
        base: NSColor,
        start: NSColor,
        end: NSColor,
        accent: NSColor,
        gradientEnabled: Bool,
        paneOpacity: CGFloat
    ) -> CGImage? {
        let width = 1024
        let height = 640
        let w = CGFloat(width)
        let h = CGFloat(height)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // 1. Глубокая обсидиановая или полупрозрачная стеклянная основа:
        //    при низком `paneOpacity` (как в «Стекло · Vision») живой фон рабочего
        //    стола мягко просвечивает сквозь матовое стекло macOS.
        let baseAlpha = min(0.95, 0.34 + paneOpacity * 0.85)
        let deepBase = base.blended(withFraction: 0.32, of: .black) ?? base
        ctx.setFillColor(deepBase.withAlphaComponent(baseAlpha).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        if gradientEnabled {
            func drawRadialBlob(
                center: CGPoint,
                innerRadius: CGFloat = 0,
                outerRadius: CGFloat,
                colors: [(NSColor, CGFloat)],
                scaleX: CGFloat = 1,
                scaleY: CGFloat = 1,
                rotation: CGFloat = 0
            ) {
                let cgColors = colors.map { $0.0.cgColor } as CFArray
                let locations = colors.map { $0.1 }
                guard let grad = CGGradient(colorsSpace: cs, colors: cgColors, locations: locations) else { return }
                ctx.saveGState()
                ctx.translateBy(x: center.x, y: center.y)
                if rotation != 0 { ctx.rotate(by: rotation) }
                ctx.scaleBy(x: scaleX, y: scaleY)
                ctx.drawRadialGradient(
                    grad,
                    startCenter: .zero,
                    startRadius: innerRadius,
                    endCenter: .zero,
                    endRadius: outerRadius,
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                )
                ctx.restoreGState()
            }

            let glowStrength = min(1.15, 0.62 + paneOpacity * 0.68)
            let warmHighlight = accent.blended(withFraction: 0.24, of: .white) ?? accent

            // 2. Deep-Glow: широкий атмосферный ореол (верхняя дуга + правый горизонт)
            //    с экспоненциальным затуханием, как оптический Deep Glow без жёстких границ.
            drawRadialBlob(
                center: CGPoint(x: w * 0.82, y: h * 0.82),
                outerRadius: w * 0.72,
                colors: [
                    (start.withAlphaComponent(0.36 * glowStrength), 0.0),
                    (start.withAlphaComponent(0.22 * glowStrength), 0.22),
                    (start.withAlphaComponent(0.10 * glowStrength), 0.48),
                    (end.withAlphaComponent(0.04 * glowStrength), 0.74),
                    (NSColor.clear, 1.0)
                ],
                scaleX: 1.34,
                scaleY: 0.90,
                rotation: -0.28
            )

            // 2b. Вторая точка оптического Deep Glow в левой верхней кромке шапки —
            //     даёт мягкий студийный свет на весь горизонт окна.
            drawRadialBlob(
                center: CGPoint(x: w * 0.14, y: h * 0.92),
                outerRadius: w * 0.56,
                colors: [
                    (accent.withAlphaComponent(0.28 * glowStrength), 0.0),
                    (start.withAlphaComponent(0.14 * glowStrength), 0.28),
                    (start.withAlphaComponent(0.05 * glowStrength), 0.58),
                    (NSColor.clear, 1.0)
                ],
                scaleX: 1.38,
                scaleY: 0.72,
                rotation: 0.14
            )

            // 3. Светящееся внутреннее ядро Deep Glow (мягкий оптический пик внутри дуги).
            drawRadialBlob(
                center: CGPoint(x: w * 0.76, y: h * 0.68),
                outerRadius: w * 0.34,
                colors: [
                    (warmHighlight.withAlphaComponent(0.24 * glowStrength), 0.0),
                    (accent.withAlphaComponent(0.14 * glowStrength), 0.28),
                    (start.withAlphaComponent(0.06 * glowStrength), 0.56),
                    (NSColor.clear, 1.0)
                ],
                scaleX: 0.74,
                scaleY: 1.32,
                rotation: 0.38
            )

            // 4. Глубокий противовес в нижнем левом и нижнем правом краях —
            //    создаёт объём и глубину без превращения фона в «кислотный суп».
            drawRadialBlob(
                center: CGPoint(x: w * 0.18, y: h * 0.14),
                outerRadius: w * 0.58,
                colors: [
                    (end.withAlphaComponent(0.30 * glowStrength), 0.0),
                    (end.withAlphaComponent(0.14 * glowStrength), 0.34),
                    (end.withAlphaComponent(0.04 * glowStrength), 0.66),
                    (NSColor.clear, 1.0)
                ],
                scaleX: 1.26,
                scaleY: 0.88,
                rotation: 0.24
            )

            drawRadialBlob(
                center: CGPoint(x: w * 0.86, y: h * 0.12),
                outerRadius: w * 0.44,
                colors: [
                    (end.withAlphaComponent(0.22 * glowStrength), 0.0),
                    (end.withAlphaComponent(0.08 * glowStrength), 0.44),
                    (NSColor.clear, 1.0)
                ],
                scaleX: 1.18,
                scaleY: 0.84,
                rotation: -0.18
            )

            // 5. Тёмное «ядро спокойствия» в рабочей зоне файлов — гарантирует
            //    идеальный контраст подписей и превью поверх глубокого градиента.
            drawRadialBlob(
                center: CGPoint(x: w * 0.46, y: h * 0.46),
                outerRadius: w * 0.42,
                colors: [
                    (deepBase.withAlphaComponent(0.32 * baseAlpha), 0.0),
                    (deepBase.withAlphaComponent(0.12 * baseAlpha), 0.56),
                    (NSColor.clear, 1.0)
                ],
                scaleX: 1.16,
                scaleY: 1.0
            )

            // 6. Деликатное оптическое рифление (fluted glass):
            //    едва заметные вертикальные рёбра света по правой дуге.
            let ribCount = 36
            let ribWidth = (w * 0.48) / CGFloat(ribCount)
            let startX = w * 0.52
            for i in 0..<ribCount {
                let t = CGFloat(i) / CGFloat(ribCount)
                let envelope = sin(t * .pi)
                let x = startX + CGFloat(i) * ribWidth
                let ribRect = CGRect(x: x, y: 0, width: ribWidth, height: h)
                let colors = [
                    NSColor.white.withAlphaComponent(0.020 * envelope).cgColor,
                    NSColor.clear.cgColor,
                    NSColor.black.withAlphaComponent(0.026 * envelope).cgColor
                ] as CFArray
                if let ribGrad = CGGradient(colorsSpace: cs, colors: colors, locations: [0.0, 0.45, 1.0]) {
                    ctx.saveGState()
                    ctx.clip(to: ribRect)
                    ctx.drawLinearGradient(
                        ribGrad,
                        start: CGPoint(x: x, y: 0),
                        end: CGPoint(x: x + ribWidth, y: 0),
                        options: []
                    )
                    ctx.restoreGState()
                }
            }
        }

        // 7. Органичное плёночное микрозерно (треугольное распределение):
        //    убирает 8-битный бандинг на Deep Glow градиентах и даёт тактильную
        //    фактуру в светящихся зонах, сохраняя глубокий чистый чёрный в тенях.
        if let rawPtr = ctx.data {
            let pixels = rawPtr.assumingMemoryBound(to: UInt8.self)
            var state: UInt32 = 0x9E3779B9
            let totalBytes = width * height * 4
            var offset = 0
            while offset < totalBytes {
                state = state &* 1664525 &+ 1013904223
                let u1 = Int((state >> 24) & 0x7) // 0..7
                state = state &* 1664525 &+ 1013904223
                let u2 = Int((state >> 24) & 0x7) // 0..7
                // Треугольное распределение (-7..+7), мягко масштабируется по яркости пикселя.
                let r = Int(pixels[offset])
                let g = Int(pixels[offset + 1])
                let b = Int(pixels[offset + 2])
                let luma = (r + g + b) / 3
                let scale = luma > 28 ? 3 : 2
                let delta = ((u1 - u2) * scale) / 5
                pixels[offset] = UInt8(clamping: r + delta)
                pixels[offset + 1] = UInt8(clamping: g + delta)
                pixels[offset + 2] = UInt8(clamping: b + delta)
                offset += 4
            }
        }

        return ctx.makeImage()
    }
}

/// Чистая бесшовная шапка таблицы в режиме «Список»: убирает системные серые
/// капсулы и тёмные «заглушки» по краям macOS `.inset`, рисует тонкий hairline.
final class QyvroTableHeaderView: NSTableHeaderView {
    override func draw(_ dirtyRect: NSRect) {
        // Не вызываем super.draw, чтобы macOS не подкладывал серую плашку под ячейки.
        guard let tableView else { return }
        for (idx, column) in tableView.tableColumns.enumerated() {
            let rect = headerRect(ofColumn: idx)
            guard rect.intersects(dirtyRect) else { continue }
            column.headerCell.draw(withFrame: rect, in: self)
        }
        // Одна тонкая линия-разделитель под заголовками колонок.
        FPStyle.stroke.withAlphaComponent(0.75).setFill()
        NSRect(x: 8, y: bounds.maxY - 1, width: max(0, bounds.width - 16), height: 0.75).fill()
    }
}

/// Кнопка-цель для папок в «Подиуме» (нижний док) и «Рейле» (боковая рейка):
/// поддерживает клик, наведение с мягкой стеклянной подсветкой и перетаскивание
/// файлов прямо на значок для переноса в папку.
final class QyvroDockFolderButton: NSButton {
    var folderURL: URL?
    var onFilesDropped: (([URL], URL) -> Bool)?
    var isCurrentLocation = false {
        didSet { updateAppearance() }
    }
    var customTint: NSColor? {
        didSet { updateAppearance() }
    }
    private var trackingAreaRef: NSTrackingArea?
    private var isHovering = false
    private let activeDot = CALayer()
    private let compactSize: CGFloat

    init(symbol: String, tooltip: String, url: URL? = nil, size: CGFloat = 34) {
        self.folderURL = url
        self.compactSize = size
        super.init(frame: .zero)
        title = ""
        isBordered = false
        bezelStyle = .inline
        imagePosition = .imageOnly
        toolTip = tooltip
        wantsLayer = true
        layer?.cornerRadius = size >= 36 ? 11 : 10
        translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 11.0, *),
           let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) {
            let cfg = NSImage.SymbolConfiguration(pointSize: size >= 36 ? 15.5 : 14.5, weight: .medium)
            image = img.withSymbolConfiguration(cfg) ?? img
        }
        activeDot.cornerRadius = 2
        activeDot.isHidden = true
        layer?.addSublayer(activeDot)

        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
        if url != nil {
            registerForDraggedTypes([.fileURL])
        }
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        activeDot.frame = NSRect(x: bounds.midX - 5, y: 2, width: 10, height: 2.5)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateAppearance(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateAppearance(animated: true)
    }

    func updateAppearance(animated: Bool = false) {
        let accent = FPStyle.accent
        let bg: CGColor
        let border: CGColor
        let borderWidth: CGFloat
        let tint: NSColor

        if isCurrentLocation {
            bg = accent.withAlphaComponent(0.16).cgColor
            border = accent.withAlphaComponent(0.42).cgColor
            borderWidth = 0.8
            tint = accent
        } else if isHovering {
            bg = NSColor.white.withAlphaComponent(0.10).cgColor
            border = NSColor.white.withAlphaComponent(0.14).cgColor
            borderWidth = 0.6
            tint = customTint ?? FPStyle.text
        } else {
            bg = NSColor.clear.cgColor
            border = NSColor.clear.cgColor
            borderWidth = 0
            tint = customTint ?? FPStyle.dimText
        }

        let apply = {
            self.layer?.backgroundColor = bg
            self.layer?.borderColor = border
            self.layer?.borderWidth = borderWidth
            self.contentTintColor = tint
            self.activeDot.backgroundColor = accent.cgColor
            self.activeDot.isHidden = !self.isCurrentLocation
        }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.allowsImplicitAnimation = true
                apply()
            }
        } else {
            apply()
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard folderURL != nil, !droppedURLs(sender).isEmpty else { return [] }
        layer?.backgroundColor = FPStyle.accent.withAlphaComponent(0.24).cgColor
        layer?.borderColor = FPStyle.accent.cgColor
        layer?.borderWidth = 1.4
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        updateAppearance()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        updateAppearance()
        guard let dest = folderURL else { return false }
        let urls = droppedURLs(sender)
        guard !urls.isEmpty else { return false }
        return onFilesDropped?(urls, dest) ?? false
    }

    private func droppedURLs(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
    }
}

/// Кольцевой мини-индикатор заполнения диска (вдохновлён референсом с
/// круговыми кольцами на тёмной капсуле). Клик открывает «Где пропало место?».
final class QyvroCircularGaugeButton: NSControl {
    var onClick: (() -> Void)?
    private var snapshot = FPDiskUsage.Snapshot()
    private var isHovering = false
    private var trackingRef: NSTrackingArea?
    private let showPercentLabel: Bool

    init(showPercentLabel: Bool) {
        self.showPercentLabel = showPercentLabel
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        widthAnchor.constraint(equalToConstant: showPercentLabel ? 44 : 34).isActive = true
        heightAnchor.constraint(equalToConstant: showPercentLabel ? 52 : 34).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ value: FPDiskUsage.Snapshot) {
        snapshot = value
        if value.total > 0 {
            let free = ByteCountFormatter.string(fromByteCount: value.free, countStyle: .file)
            let pct = Int((value.usedFraction * 100).rounded())
            toolTip = "Диск занят на \(pct)% · Свободно \(free) — нажмите для анализа «Где пропало место?»"
        } else {
            toolTip = "Где пропало место?"
        }
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingRef { removeTrackingArea(trackingRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovering {
            NSColor.white.withAlphaComponent(0.09).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        }

        let ringSize: CGFloat = showPercentLabel ? 30 : 24
        let ringRect = NSRect(
            x: bounds.midX - ringSize / 2,
            y: showPercentLabel ? bounds.height - ringSize - 3 : bounds.midY - ringSize / 2,
            width: ringSize,
            height: ringSize
        )
        let center = NSPoint(x: ringRect.midX, y: ringRect.midY)
        let radius = ringSize / 2 - 2.5

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        NSColor.white.withAlphaComponent(0.12).setStroke()
        track.lineWidth = 2.6
        track.stroke()

        let used = CGFloat(min(max(snapshot.usedFraction, 0), 1))
        if used > 0.01 {
            let arc = NSBezierPath()
            arc.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: 90,
                endAngle: 90 - used * 360,
                clockwise: true
            )
            let ringColor = snapshot.freeFraction < 0.10 ? FPStyle.orange : FPStyle.accent
            ringColor.setStroke()
            arc.lineWidth = 2.8
            arc.lineCapStyle = .round
            arc.stroke()
        }

        let pct = snapshot.total > 0 ? Int((snapshot.usedFraction * 100).rounded()) : 0
        if showPercentLabel {
            if #available(macOS 11.0, *),
               let icon = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: nil) {
                let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [FPStyle.text]))
                let tinted = icon.withSymbolConfiguration(cfg) ?? icon
                tinted.draw(in: NSRect(x: center.x - 6.5, y: center.y - 6.5, width: 13, height: 13))
            }
            let text = "\(pct)%" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold),
                .foregroundColor: FPStyle.dimText
            ]
            let sz = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: bounds.midX - sz.width / 2, y: 2), withAttributes: attrs)
        } else {
            let text = "\(pct)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .bold),
                .foregroundColor: FPStyle.text
            ]
            let sz = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: center.x - sz.width / 2, y: center.y - sz.height / 2), withAttributes: attrs)
        }
    }
}

/// Плавающий стеклянный док для макета «Подиум» (вдохновлён Ron Design +
/// светящаяся капсула ввода из референсов): все папки, диски, теги, поиск,
/// анализатор диска и настройки под рукой внизу, не съедая 240 px ширины.
final class QyvroFloatingDockView: NSView {
    var onOpenRecents: (() -> Void)?
    var onOpenURL: ((URL) -> Void)?
    var onMoveFilesToURL: (([URL], URL) -> Bool)?
    var onShowVolumesMenu: ((NSView) -> Void)?
    var onShowTagsMenu: ((NSView) -> Void)?
    var onFocusSearch: (() -> Void)?
    var onAnalyzeDisk: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private let backdrop = NSVisualEffectView()
    private let tintLayer = CALayer()
    private let topRimLayer = CAGradientLayer()
    private let stack = NSStackView()
    private var folderButtons: [QyvroDockFolderButton] = []
    private var recentsButton: QyvroDockFolderButton?
    private let diskGauge = QyvroCircularGaugeButton(showPercentLabel: false)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 19
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.55
        layer?.shadowRadius = 22
        layer?.shadowOffset = NSSize(width: 0, height: -8)

        backdrop.material = .hudWindow
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 19
        backdrop.layer?.masksToBounds = true
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)

        tintLayer.cornerRadius = 19
        tintLayer.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        backdrop.layer?.addSublayer(tintLayer)

        topRimLayer.startPoint = CGPoint(x: 0.0, y: 0.5)
        topRimLayer.endPoint = CGPoint(x: 1.0, y: 0.5)
        topRimLayer.locations = [0.0, 0.20, 0.50, 0.80, 1.0]
        topRimLayer.actions = ["colors": NSNull(), "bounds": NSNull(), "position": NSNull()]
        backdrop.layer?.addSublayer(topRimLayer)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(stack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            stack.topAnchor.constraint(equalTo: backdrop.topAnchor),
            stack.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor)
        ])

        diskGauge.onClick = { [weak self] in self?.onAnalyzeDisk?() }
        rebuildItems()
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        tintLayer.frame = backdrop.bounds
        topRimLayer.frame = NSRect(x: 16, y: max(0, backdrop.bounds.height - 1), width: max(0, backdrop.bounds.width - 32), height: 1)
    }

    func rebuildItems() {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        folderButtons.removeAll()

        let home = FileManager.default.homeDirectoryForCurrentUser

        let recents = QyvroDockFolderButton(symbol: "clock.arrow.circlepath", tooltip: "Недавние файлы и папки (⌥⌘R)")
        recents.target = self
        recents.action = #selector(recentsPressed(_:))
        recentsButton = recents
        stack.addArrangedSubview(recents)

        stack.addArrangedSubview(makeDivider())

        let places: [(String, String, URL)] = [
            ("house", "Дом", home),
            ("menubar.rectangle", "Рабочий стол", home.appendingPathComponent("Desktop", isDirectory: true)),
            ("arrow.down.circle", "Загрузки", home.appendingPathComponent("Downloads", isDirectory: true)),
            ("doc.text", "Документы", home.appendingPathComponent("Documents", isDirectory: true)),
            ("photo", "Изображения", home.appendingPathComponent("Pictures", isDirectory: true)),
            ("film", "Видео", home.appendingPathComponent("Movies", isDirectory: true)),
            ("app.badge", "Программы", URL(fileURLWithPath: "/Applications", isDirectory: true))
        ]
        for place in places {
            let btn = QyvroDockFolderButton(symbol: place.0, tooltip: "\(place.1) · можно перетащить файлы", url: place.2)
            btn.target = self
            btn.action = #selector(folderPressed(_:))
            btn.onFilesDropped = { [weak self] urls, dest in
                self?.onMoveFilesToURL?(urls, dest) ?? false
            }
            folderButtons.append(btn)
            stack.addArrangedSubview(btn)
        }

        stack.addArrangedSubview(makeDivider())

        let drivesBtn = QyvroDockFolderButton(symbol: "externaldrive", tooltip: "Диски и закреплённые папки")
        drivesBtn.target = self
        drivesBtn.action = #selector(drivesPressed(_:))
        stack.addArrangedSubview(drivesBtn)

        let tagsBtn = QyvroDockFolderButton(symbol: "tag", tooltip: "Теги Finder")
        tagsBtn.target = self
        tagsBtn.action = #selector(tagsPressed(_:))
        stack.addArrangedSubview(tagsBtn)

        let searchBtn = QyvroDockFolderButton(symbol: "magnifyingglass", tooltip: "Поиск (⌘F)")
        searchBtn.target = self
        searchBtn.action = #selector(searchPressed(_:))
        stack.addArrangedSubview(searchBtn)

        stack.addArrangedSubview(makeDivider())

        stack.addArrangedSubview(diskGauge)

        let settingsBtn = QyvroDockFolderButton(symbol: "slider.horizontal.3", tooltip: "Настройки и темы (⌘,)")
        settingsBtn.target = self
        settingsBtn.action = #selector(settingsPressed(_:))
        stack.addArrangedSubview(settingsBtn)

        applyTheme()
    }

    func updateActiveLocation(url: URL?, isRecents: Bool) {
        recentsButton?.isCurrentLocation = isRecents
        let currentPath = url?.standardizedFileURL.path
        for btn in folderButtons {
            btn.isCurrentLocation = !isRecents && btn.folderURL?.standardizedFileURL.path == currentPath
        }
    }

    func updateDisk(_ snapshot: FPDiskUsage.Snapshot) {
        diskGauge.update(snapshot)
    }

    func applyTheme() {
        tintLayer.backgroundColor = FPStyle.window.withAlphaComponent(0.76).cgColor
        backdrop.layer?.borderColor = NSColor.white.withAlphaComponent(0.11).cgColor
        backdrop.layer?.borderWidth = 0.75
        topRimLayer.colors = [
            NSColor.clear.cgColor,
            NSColor.white.withAlphaComponent(0.14).cgColor,
            FPStyle.accent.withAlphaComponent(0.45).cgColor,
            NSColor.white.withAlphaComponent(0.14).cgColor,
            NSColor.clear.cgColor
        ]
        for case let btn as QyvroDockFolderButton in stack.arrangedSubviews {
            btn.updateAppearance()
        }
        diskGauge.needsDisplay = true
    }

    private func makeDivider() -> NSView {
        let v = FPLayerView(color: NSColor.white.withAlphaComponent(0.10))
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return v
    }

    @objc private func recentsPressed(_ sender: Any?) { onOpenRecents?() }
    @objc private func folderPressed(_ sender: QyvroDockFolderButton) {
        guard let url = sender.folderURL else { return }
        onOpenURL?(url)
    }
    @objc private func drivesPressed(_ sender: NSButton) { onShowVolumesMenu?(sender) }
    @objc private func tagsPressed(_ sender: NSButton) { onShowTagsMenu?(sender) }
    @objc private func searchPressed(_ sender: Any?) { onFocusSearch?() }
    @objc private func settingsPressed(_ sender: Any?) { onOpenSettings?() }
}

/// Узкая скульптурная иконочная рейка слева для макета «Рейл» (вдохновлён
/// референсом с тёмной кромкой и кольцевыми индикаторами процентов).
final class QyvroEdgeRailView: NSView {
    var onOpenRecents: (() -> Void)?
    var onOpenURL: ((URL) -> Void)?
    var onMoveFilesToURL: (([URL], URL) -> Bool)?
    var onShowVolumesMenu: ((NSView) -> Void)?
    var onOpenTag: ((String, String) -> Void)?
    var onApplyTag: ((String, [URL]) -> Void)?
    var onFocusSearch: (() -> Void)?
    var onAnalyzeDisk: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private let capsule = FPLayerView(color: .clear, cornerRadius: 18)
    private let topStack = NSStackView()
    private let tagDotsStack = NSStackView()
    private let bottomStack = NSStackView()
    private var folderButtons: [QyvroDockFolderButton] = []
    private var recentsButton: QyvroDockFolderButton?
    private let diskGauge = QyvroCircularGaugeButton(showPercentLabel: true)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        addSubview(capsule)

        [topStack, bottomStack].forEach {
            $0.orientation = .vertical
            $0.alignment = .centerX
            $0.spacing = 4
            $0.translatesAutoresizingMaskIntoConstraints = false
            capsule.addSubview($0)
        }
        tagDotsStack.orientation = .vertical
        tagDotsStack.alignment = .centerX
        tagDotsStack.spacing = 6
        tagDotsStack.translatesAutoresizingMaskIntoConstraints = false
        capsule.addSubview(tagDotsStack)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 74),
            capsule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            capsule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            capsule.topAnchor.constraint(equalTo: topAnchor, constant: 42),
            capsule.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),

            topStack.topAnchor.constraint(equalTo: capsule.topAnchor, constant: 8),
            topStack.centerXAnchor.constraint(equalTo: capsule.centerXAnchor),

            tagDotsStack.topAnchor.constraint(greaterThanOrEqualTo: topStack.bottomAnchor, constant: 8),
            tagDotsStack.centerXAnchor.constraint(equalTo: capsule.centerXAnchor),
            tagDotsStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomStack.topAnchor, constant: -8),

            bottomStack.bottomAnchor.constraint(equalTo: capsule.bottomAnchor, constant: -8),
            bottomStack.centerXAnchor.constraint(equalTo: capsule.centerXAnchor)
        ])

        diskGauge.onClick = { [weak self] in self?.onAnalyzeDisk?() }
        rebuildItems()
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func rebuildItems() {
        [topStack, tagDotsStack, bottomStack].forEach { stack in
            stack.arrangedSubviews.forEach {
                stack.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
        }
        folderButtons.removeAll()

        let home = FileManager.default.homeDirectoryForCurrentUser

        let searchBtn = QyvroDockFolderButton(symbol: "magnifyingglass", tooltip: "Поиск (⌘F)", size: 30)
        searchBtn.target = self
        searchBtn.action = #selector(searchPressed(_:))
        topStack.addArrangedSubview(searchBtn)

        let recents = QyvroDockFolderButton(symbol: "clock.arrow.circlepath", tooltip: "Недавние (⌥⌘R)", size: 30)
        recents.target = self
        recents.action = #selector(recentsPressed(_:))
        recentsButton = recents
        topStack.addArrangedSubview(recents)

        let places: [(String, String, URL)] = [
            ("house", "Дом", home),
            ("arrow.down.circle", "Загрузки", home.appendingPathComponent("Downloads", isDirectory: true)),
            ("doc.text", "Документы", home.appendingPathComponent("Documents", isDirectory: true)),
            ("menubar.rectangle", "Рабочий стол", home.appendingPathComponent("Desktop", isDirectory: true)),
            ("photo", "Изображения", home.appendingPathComponent("Pictures", isDirectory: true)),
            ("app.badge", "Программы", URL(fileURLWithPath: "/Applications", isDirectory: true))
        ]
        for place in places {
            let btn = QyvroDockFolderButton(symbol: place.0, tooltip: place.1, url: place.2, size: 30)
            btn.target = self
            btn.action = #selector(folderPressed(_:))
            btn.onFilesDropped = { [weak self] urls, dest in
                self?.onMoveFilesToURL?(urls, dest) ?? false
            }
            folderButtons.append(btn)
            topStack.addArrangedSubview(btn)
        }

        let drivesBtn = QyvroDockFolderButton(symbol: "externaldrive", tooltip: "Диски и закреплённые папки", size: 30)
        drivesBtn.target = self
        drivesBtn.action = #selector(drivesPressed(_:))
        topStack.addArrangedSubview(drivesBtn)

        // Компактная матрица 2×3 цветных точек тегов не раздувает минимальную
        // высоту окна и смотрится аккуратно внутри узкой 58-pt капсулы.
        let tags = Array(FPTag.all.prefix(6))
        var pairIndex = 0
        while pairIndex < tags.count {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 6
            for offset in 0..<2 where pairIndex + offset < tags.count {
                let tag = tags[pairIndex + offset]
                let dot = QyvroRailTagDotButton(tag: tag)
                dot.onOpen = { [weak self] key, title in self?.onOpenTag?(key, title) }
                dot.onDropURLs = { [weak self] key, urls in self?.onApplyTag?(key, urls) }
                row.addArrangedSubview(dot)
            }
            tagDotsStack.addArrangedSubview(row)
            pairIndex += 2
        }

        bottomStack.addArrangedSubview(diskGauge)

        let settingsBtn = QyvroDockFolderButton(symbol: "slider.horizontal.3", tooltip: "Настройки и темы (⌘,)", size: 30)
        settingsBtn.target = self
        settingsBtn.action = #selector(settingsPressed(_:))
        bottomStack.addArrangedSubview(settingsBtn)

        applyTheme()
    }

    func updateActiveLocation(url: URL?, isRecents: Bool) {
        recentsButton?.isCurrentLocation = isRecents
        let currentPath = url?.standardizedFileURL.path
        for btn in folderButtons {
            btn.isCurrentLocation = !isRecents && btn.folderURL?.standardizedFileURL.path == currentPath
        }
    }

    func updateDisk(_ snapshot: FPDiskUsage.Snapshot) {
        diskGauge.update(snapshot)
    }

    func applyTheme() {
        capsule.layer?.backgroundColor = FPStyle.window.withAlphaComponent(0.74).cgColor
        capsule.layer?.borderColor = NSColor.white.withAlphaComponent(0.09).cgColor
        capsule.layer?.borderWidth = 0.75
        for case let btn as QyvroDockFolderButton in topStack.arrangedSubviews + bottomStack.arrangedSubviews {
            btn.updateAppearance()
        }
        diskGauge.needsDisplay = true
    }

    @objc private func searchPressed(_ sender: Any?) { onFocusSearch?() }
    @objc private func recentsPressed(_ sender: Any?) { onOpenRecents?() }
    @objc private func folderPressed(_ sender: QyvroDockFolderButton) {
        guard let url = sender.folderURL else { return }
        onOpenURL?(url)
    }
    @objc private func drivesPressed(_ sender: NSButton) { onShowVolumesMenu?(sender) }
    @objc private func settingsPressed(_ sender: Any?) { onOpenSettings?() }
}

private final class QyvroRailTagDotButton: NSControl {
    private let tagKey: String
    private let tagTitle: String
    private let tagColor: NSColor
    var onOpen: ((String, String) -> Void)?
    var onDropURLs: ((String, [URL]) -> Void)?
    private var isHovering = false
    private var isDragOver = false
    private var trackingRef: NSTrackingArea?

    init(tag: FPTag) {
        self.tagKey = tag.key
        self.tagTitle = tag.title
        self.tagColor = tag.color
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = "Тег «\(tag.title)» · перетащите файлы чтобы пометить"
        widthAnchor.constraint(equalToConstant: 20).isActive = true
        heightAnchor.constraint(equalToConstant: 20).isActive = true
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingRef { removeTrackingArea(trackingRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingRef = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovering = false; needsDisplay = true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) { onOpen?(tagKey, tagTitle) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isDragOver = true; needsDisplay = true; return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDragOver = false; needsDisplay = true
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDragOver = false; needsDisplay = true
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onDropURLs?(tagKey, urls)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let dotSize: CGFloat = (isHovering || isDragOver) ? 12 : 9.5
        let rect = NSRect(
            x: bounds.midX - dotSize / 2,
            y: bounds.midY - dotSize / 2,
            width: dotSize,
            height: dotSize
        )
        if isHovering || isDragOver {
            tagColor.withAlphaComponent(0.28).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: -3, dy: -3)).fill()
        }
        tagColor.setFill()
        NSBezierPath(ovalIn: rect).fill()
    }
}


/// Горизонтальный скроллер для ленты капсул: при переполнении на узком окне
/// позволяет крутить капсулы как трекпадом, так и обычным колесом мыши.
private final class QyvroHorizontalPillScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard let doc = documentView, doc.bounds.width > contentView.bounds.width + 1 else {
            super.scrollWheel(with: event)
            return
        }
        let primaryDelta: CGFloat
        if abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) {
            primaryDelta = event.scrollingDeltaX
        } else {
            primaryDelta = event.scrollingDeltaY
        }
        guard abs(primaryDelta) > 0.01 else { return }
        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1.0 : 12.0
        let maxX = max(0, doc.bounds.width - contentView.bounds.width)
        let nextX = min(max(0, contentView.bounds.origin.x - primaryDelta * multiplier), maxX)
        contentView.scroll(to: NSPoint(x: nextX, y: 0))
        reflectScrolledClipView(contentView)
    }
}

/// Контейнер с мягкой маской затухания по краям: включается автоматически
/// только когда содержимое реально не помещается по ширине (на узких окнах),
/// чтобы ни одна капсула никогда не обрезалась жёстким вертикальным срезом.
private final class QyvroFadeMaskContainer: NSView {
    private let maskGradient = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        maskGradient.startPoint = CGPoint(x: 0, y: 0.5)
        maskGradient.endPoint = CGPoint(x: 1, y: 0.5)
        maskGradient.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "colors": NSNull(),
            "locations": NSNull()
        ]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateFade(leadingFade: Bool, trailingFade: Bool) {
        guard let rootLayer = layer else { return }
        guard (leadingFade || trailingFade), bounds.width > 32 else {
            rootLayer.mask = nil
            return
        }
        let fadeFraction = min(0.14, max(0.04, 24.0 / bounds.width))
        let clear = NSColor.clear.cgColor
        let opaque = NSColor.black.cgColor
        maskGradient.frame = bounds
        maskGradient.colors = [
            leadingFade ? clear : opaque,
            opaque,
            opaque,
            trailingFade ? clear : opaque
        ]
        maskGradient.locations = [
            0.0,
            NSNumber(value: Double(leadingFade ? fadeFraction : 0.0)),
            NSNumber(value: Double(trailingFade ? (1.0 - fadeFraction) : 1.0)),
            1.0
        ]
        if rootLayer.mask !== maskGradient {
            rootLayer.mask = maskGradient
        }
    }
}

/// Тактильная студийная капсула-кнопка для макета V4 «Студия · Остров».
///
/// Активная локация подсвечивается тёплым/тематическим дымчатым акцентным
/// стеклом (без слепящего белого и без холодного серого), а сегменты фильтров
/// живут в едином утопленном стеклянной лотке. Папки принимают drag-and-drop.
final class QyvroStudioPillButton: NSButton {
    enum Style {
        /// Капсула перехода по папкам: активная — дымчатое стекло в цвете темы.
        case locationGlass
        /// Сегмент быстрого фильтра внутри утопленного лотка.
        case filterSegment
    }

    var folderURL: URL?
    var filterOption: FPGridFilter?
    var onFilesDropped: (([URL], URL) -> Bool)?
    var isSelectedPill = false {
        didSet { updateAppearance(animated: false) }
    }

    private let pillStyle: Style
    private let labelText: String
    private let symbolName: String?
    private let sheenLayer = CAGradientLayer()
    private var trackingRef: NSTrackingArea?
    private var isHovering = false
    private var isDragTarget = false

    init(
        title: String,
        symbol: String? = nil,
        url: URL? = nil,
        filter: FPGridFilter? = nil,
        style: Style = .locationGlass
    ) {
        self.labelText = title
        self.symbolName = symbol
        self.folderURL = url
        self.filterOption = filter
        self.pillStyle = style
        super.init(frame: .zero)

        isBordered = false
        bezelStyle = .inline
        imagePosition = symbol == nil ? .noImage : .imageLeading
        imageHugsTitle = true
        alignment = .center
        wantsLayer = true
        let pillHeight: CGFloat = style == .filterSegment ? 22 : 26
        layer?.cornerRadius = pillHeight / 2
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        heightAnchor.constraint(equalToConstant: pillHeight).isActive = true

        sheenLayer.startPoint = CGPoint(x: 0.5, y: 1.0)
        sheenLayer.endPoint = CGPoint(x: 0.5, y: 0.0)
        sheenLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "colors": NSNull(),
            "opacity": NSNull()
        ]
        layer?.insertSublayer(sheenLayer, at: 0)

        if url != nil {
            registerForDraggedTypes([.fileURL])
        }
        updateAppearance(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        sheenLayer.frame = bounds
    }

    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        let height: CGFloat = pillStyle == .filterSegment ? 22 : 26
        let extra: CGFloat
        if pillStyle == .filterSegment {
            extra = labelText.count <= 1 ? 14 : 15
        } else {
            extra = symbolName == nil ? 15 : 17
        }
        return NSSize(width: max(pillStyle == .filterSegment ? 26 : 36, base.width + extra), height: height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingRef { removeTrackingArea(trackingRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateAppearance(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateAppearance(animated: true)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private var themeNeutralTint: NSColor {
        FPStyle.text.blended(withFraction: 0.22, of: FPStyle.accent) ?? FPStyle.text
    }

    func updateAppearance(animated: Bool = false) {
        let bg: NSColor
        let border: NSColor
        let borderWidth: CGFloat
        let fg: NSColor
        let iconTint: NSColor
        let weight: NSFont.Weight
        let showSheen: Bool
        let tint = themeNeutralTint

        if isDragTarget {
            bg = FPStyle.accent.withAlphaComponent(0.28)
            border = FPStyle.accent
            borderWidth = 1.15
            fg = FPStyle.text
            iconTint = FPStyle.accent
            weight = .semibold
            showSheen = true
        } else if isSelectedPill {
            switch pillStyle {
            case .locationGlass:
                // Насыщенное, но спокойное дымчатое акцентное стекло в тон темы —
                // без выбивающегося белого пятна на тёмном стекле.
                bg = FPStyle.accent.withAlphaComponent(0.22)
                border = FPStyle.accent.withAlphaComponent(0.64)
                borderWidth = 0.85
                fg = FPStyle.text
                iconTint = FPStyle.accent
                weight = .semibold
                showSheen = true
            case .filterSegment:
                bg = FPStyle.accent.withAlphaComponent(0.20)
                border = FPStyle.accent.withAlphaComponent(0.46)
                borderWidth = 0.7
                fg = FPStyle.accent
                iconTint = FPStyle.accent
                weight = .semibold
                showSheen = false
            }
        } else if isHovering {
            bg = tint.withAlphaComponent(pillStyle == .filterSegment ? 0.085 : 0.095)
            border = pillStyle == .filterSegment
                ? NSColor.clear
                : tint.withAlphaComponent(0.16)
            borderWidth = pillStyle == .filterSegment ? 0 : 0.5
            fg = FPStyle.text
            iconTint = FPStyle.accent.withAlphaComponent(0.88)
            weight = .medium
            showSheen = false
        } else {
            bg = pillStyle == .filterSegment
                ? NSColor.clear
                : tint.withAlphaComponent(0.042)
            border = pillStyle == .filterSegment
                ? NSColor.clear
                : tint.withAlphaComponent(0.082)
            borderWidth = pillStyle == .filterSegment ? 0 : 0.5
            fg = FPStyle.text.withAlphaComponent(pillStyle == .filterSegment ? 0.64 : 0.74)
            iconTint = FPStyle.dimText.withAlphaComponent(0.84)
            weight = .medium
            showSheen = false
        }

        let fontSize: CGFloat = pillStyle == .filterSegment ? 11.2 : 11.5
        let font = FPStyle.bodyFont(ofSize: fontSize, weight: weight)
        let titleAttr = NSAttributedString(
            string: labelText,
            attributes: [
                .font: font,
                .foregroundColor: fg,
                .kern: 0.05
            ]
        )
        let sheenColors: [CGColor] = [
            FPStyle.accent.withAlphaComponent(0.18).cgColor,
            NSColor.clear.cgColor
        ]

        let apply = {
            self.layer?.backgroundColor = bg.cgColor
            self.layer?.borderColor = border.cgColor
            self.layer?.borderWidth = borderWidth
            self.sheenLayer.colors = sheenColors
            self.sheenLayer.opacity = showSheen ? 1 : 0
            self.attributedTitle = titleAttr
            if let symbolName = self.symbolName, #available(macOS 11.0, *),
               let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: self.labelText) {
                let cfg = NSImage.SymbolConfiguration(pointSize: 10.8, weight: weight)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [iconTint]))
                let tinted = img.withSymbolConfiguration(cfg) ?? img
                tinted.isTemplate = false
                self.image = tinted
            }
            self.contentTintColor = iconTint
        }

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.13
                ctx.allowsImplicitAnimation = true
                apply()
            }
        } else {
            apply()
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard folderURL != nil, !droppedURLs(sender).isEmpty else { return [] }
        isDragTarget = true
        updateAppearance(animated: true)
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDragTarget = false
        updateAppearance(animated: true)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDragTarget = false
        updateAppearance(animated: true)
        guard let dest = folderURL else { return false }
        let urls = droppedURLs(sender)
        guard !urls.isEmpty else { return false }
        return onFilesDropped?(urls, dest) ?? false
    }

    private func droppedURLs(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
    }
}

/// Кнопка-сегмент внутри капсулы переключения соседних папок (`‹  5 / 21  ›`).
private final class QyvroStepperSegmentButton: NSButton {
    private var trackingRef: NSTrackingArea?
    private var isHovered = false
    private var isFlashing = false

    override var mouseDownCanMoveWindow: Bool { false }

    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        isBordered = false
        bezelStyle = .inline
        setButtonType(.momentaryChange)
        layer?.cornerRadius = cornerRadius
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingRef { removeTrackingArea(trackingRef) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        refreshAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        refreshAppearance()
    }

    func flashAccent() {
        isFlashing = true
        refreshAppearance()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            guard let self else { return }
            self.isFlashing = false
            self.refreshAppearance()
        }
    }

    func refreshAppearance() {
        let tint = FPStyle.text.blended(withFraction: 0.22, of: FPStyle.accent) ?? FPStyle.text
        if isFlashing {
            layer?.backgroundColor = FPStyle.accent.withAlphaComponent(0.26).cgColor
            contentTintColor = FPStyle.orange
        } else if isHovered && isEnabled {
            layer?.backgroundColor = tint.withAlphaComponent(0.13).cgColor
            contentTintColor = FPStyle.text
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            contentTintColor = FPStyle.dimText
        }
    }
}

/// Компактный переключатель соседних папок `‹  5 / 21  ›` в шапке Studio V4.
/// Клик по стрелкам переходит к предыдущей/следующей соседней папке (`[` / `]`),
/// а клик по счётчику открывает список всех папок на этом уровне.
final class QyvroSiblingFolderStepper: FPLayerView {
    var onStep: ((Int) -> Void)?
    var onSelectURL: ((URL) -> Void)?

    private let prevBtn = QyvroStepperSegmentButton(cornerRadius: 10)
    private let indexBtn = QyvroStepperSegmentButton(cornerRadius: 8)
    private let nextBtn = QyvroStepperSegmentButton(cornerRadius: 10)
    private var siblings: [URL] = []
    private var currentIndex: Int = 0
    private var parentName: String = ""

    override var mouseDownCanMoveWindow: Bool { false }

    init() {
        super.init(color: .clear, cornerRadius: 12)
        translatesAutoresizingMaskIntoConstraints = false
        layer?.borderWidth = 0.65
        isHidden = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        prevBtn.imagePosition = .imageOnly
        prevBtn.target = self
        prevBtn.action = #selector(prevPressed)

        nextBtn.imagePosition = .imageOnly
        nextBtn.target = self
        nextBtn.action = #selector(nextPressed)

        if #available(macOS 11.0, *) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 9.5, weight: .semibold)
            prevBtn.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: L("Предыдущая папка", "Previous folder"))?
                .withSymbolConfiguration(cfg)
            nextBtn.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: L("Следующая папка", "Next folder"))?
                .withSymbolConfiguration(cfg)
        }

        indexBtn.target = self
        indexBtn.action = #selector(indexPressed(_:))
        indexBtn.setContentHuggingPriority(.required, for: .horizontal)
        indexBtn.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [prevBtn, indexBtn, nextBtn])
        row.orientation = .horizontal
        row.spacing = 1
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),

            prevBtn.widthAnchor.constraint(equalToConstant: 21),
            prevBtn.heightAnchor.constraint(equalToConstant: 21),
            indexBtn.heightAnchor.constraint(equalToConstant: 21),
            indexBtn.widthAnchor.constraint(greaterThanOrEqualToConstant: 42),
            nextBtn.widthAnchor.constraint(equalToConstant: 21),
            nextBtn.heightAnchor.constraint(equalToConstant: 21)
        ])
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(siblings: [URL], currentIndex: Int, parentName: String) {
        self.siblings = siblings
        self.currentIndex = currentIndex
        self.parentName = parentName

        guard siblings.count > 1, siblings.indices.contains(currentIndex) else {
            isHidden = true
            return
        }
        isHidden = false

        let hasPrev = currentIndex > 0
        let hasNext = currentIndex + 1 < siblings.count
        prevBtn.isEnabled = hasPrev
        prevBtn.alphaValue = hasPrev ? 1.0 : 0.28
        nextBtn.isEnabled = hasNext
        nextBtn.alphaValue = hasNext ? 1.0 : 0.28

        prevBtn.toolTip = hasPrev
            ? L("Предыдущая папка: \(siblings[currentIndex - 1].lastPathComponent)  ([)", "Previous folder: \(siblings[currentIndex - 1].lastPathComponent)  ([)")
            : L("Это первая папка", "First sibling folder")
        nextBtn.toolTip = hasNext
            ? L("Следующая папка: \(siblings[currentIndex + 1].lastPathComponent)  (])", "Next folder: \(siblings[currentIndex + 1].lastPathComponent)  (])")
            : L("Это последняя папка", "Last sibling folder")
        indexBtn.toolTip = parentName.isEmpty
            ? L("Соседние папки — нажмите для выбора ([ / ])", "Sibling folders — click to jump ([ / ])")
            : L("Папки в «\(parentName)» — нажмите для выбора ([ / ])", "Folders in \"\(parentName)\" — click to jump ([ / ])")

        renderIndexLabel()
        prevBtn.refreshAppearance()
        nextBtn.refreshAppearance()
    }

    func flashStep(delta: Int) {
        if delta < 0 {
            prevBtn.flashAccent()
        } else if delta > 0 {
            nextBtn.flashAccent()
        }
    }

    func applyTheme() {
        let tint = FPStyle.text.blended(withFraction: 0.22, of: FPStyle.accent) ?? FPStyle.text
        layer?.backgroundColor = tint.withAlphaComponent(0.065).cgColor
        layer?.borderColor = tint.withAlphaComponent(0.11).cgColor
        prevBtn.refreshAppearance()
        indexBtn.refreshAppearance()
        nextBtn.refreshAppearance()
        if !siblings.isEmpty && siblings.indices.contains(currentIndex) {
            renderIndexLabel()
        }
    }

    private func renderIndexLabel() {
        let str = NSMutableAttributedString()
        str.append(NSAttributedString(
            string: " \(currentIndex + 1)",
            attributes: [
                .font: FPStyle.monoMetaFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: FPStyle.text
            ]
        ))
        str.append(NSAttributedString(
            string: "/\(siblings.count) ",
            attributes: [
                .font: FPStyle.monoMetaFont(ofSize: 10, weight: .regular),
                .foregroundColor: FPStyle.dimText.withAlphaComponent(0.76)
            ]
        ))
        indexBtn.attributedTitle = str
    }

    @objc private func prevPressed() {
        guard currentIndex > 0 else { return }
        prevBtn.flashAccent()
        onStep?(-1)
    }

    @objc private func nextPressed() {
        guard currentIndex + 1 < siblings.count else { return }
        nextBtn.flashAccent()
        onStep?(1)
    }

    @objc private func indexPressed(_ sender: NSButton) {
        guard siblings.count > 1 else { return }
        let menu = NSMenu()
        let folderImg: NSImage?
        if #available(macOS 11.0, *) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            folderImg = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg)
            folderImg?.isTemplate = true
        } else {
            folderImg = nil
        }

        if !parentName.isEmpty {
            let header = NSMenuItem(
                title: L("\(parentName)  ·  \(siblings.count) папок", "\(parentName)  ·  \(siblings.count) folders"),
                action: nil,
                keyEquivalent: ""
            )
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(.separator())
        }

        for (idx, url) in siblings.enumerated() {
            let item = NSMenuItem(
                title: "\(idx + 1).  \(url.lastPathComponent)",
                action: #selector(siblingMenuPicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = url
            item.image = folderImg
            item.state = (idx == currentIndex) ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 5), in: sender)
    }

    @objc private func siblingMenuPicked(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onSelectURL?(url)
    }
}

/// Editorial-шапка для макета V4 «Студия · Остров»:
/// 1-я строка — стрелки истории, крупное имя папки (Avenir Next Editorial) +
/// счётчик + переключатель соседних папок (`‹ 5/21 ›`) + кликабельный родитель
/// и встроенная капсула поиска («Папка / Мак»).
/// 2-я строка — тематические дымчатые капсулы локаций с автозатуханием краёв
/// при узком окне + кнопка быстрого перехода `⌘J`.
final class QyvroStudioHeaderView: NSView, NSTextFieldDelegate {
    var onGoBack: (() -> Void)?
    var onLongPressBack: ((NSButton) -> Void)?
    var onGoForward: (() -> Void)?
    var onGoUp: (() -> Void)?
    var onStepSiblingFolder: ((Int) -> Void)?
    var onOpenSiblingFolder: ((URL) -> Void)?
    var onRequestPathEdit: (() -> Void)?
    var onOpenRecents: (() -> Void)?
    var onOpenURL: ((URL) -> Void)?
    var onMoveFilesToURL: (([URL], URL) -> Bool)?
    var onShowVolumesMenu: ((NSView) -> Void)?
    var onShowBookmarksMenu: ((NSView) -> Void)?
    var onShowTagsMenu: ((NSView) -> Void)?
    var onFuzzyJump: (() -> Void)?
    var onPickFilter: ((FPGridFilter) -> Void)?
    var onSearchTextChanged: ((String) -> Void)?
    var onToggleSearchScope: (() -> Void)?

    private let backBtn = FPLongPressButton()
    private let fwdBtn = NSButton()
    private let upBtn = NSButton()
    private let titleLabel = NSTextField(labelWithString: "")
    private let countPill = FPLayerView(color: .clear, cornerRadius: 9)
    private let countLabel = NSTextField(labelWithString: "")
    private let siblingStepper = QyvroSiblingFolderStepper()
    private let parentButton = NSButton()

    private let bookmarksBtn = NSButton()
    private let gitPill = FPLayerView(color: .clear, cornerRadius: 9, borderColor: .clear, borderWidth: 1)
    private let gitLabel = NSTextField(labelWithString: "")
    private var gitFetchGeneration = 0
    private var lastStudioTitleArgs: (title: String, parent: String?, count: Int, url: URL?, isRecents: Bool)?
    private let searchCapsule = FPLayerView(color: .clear, cornerRadius: 15)
    private let searchIcon = NSImageView()
    private let searchField = CenteredTextField()
    private let searchScopeBtn = NSButton()

    private let locationsFadeContainer = QyvroFadeMaskContainer()
    private let locationsScroll = QyvroHorizontalPillScrollView()
    private let locationsStack = NSStackView()
    private let filtersTray = FPLayerView(color: .clear, cornerRadius: 13)
    private let filtersStack = NSStackView()
    private let fuzzyJumpBtn = QyvroStudioPillButton(title: "⌘J", symbol: "bolt.horizontal")
    private let bottomHairline = FPLayerView(color: .clear)

    private var recentsPill: QyvroStudioPillButton?
    private var locationPills: [QyvroStudioPillButton] = []
    private var filterPills: [QyvroStudioPillButton] = []
    private var isGlobalSearch = false
    private var suppressSearchNotification = false
    private var scrollBoundsObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        buildUI()
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let scrollBoundsObserver {
            NotificationCenter.default.removeObserver(scrollBoundsObserver)
        }
    }

    override func layout() {
        super.layout()
        updateLocationsFadeMask()
    }

    private func buildUI() {
        backBtn.onLongPress = { [weak self] btn in self?.onLongPressBack?(btn) }
        configureCircleButton(backBtn, symbol: "chevron.left", tooltip: "Назад · удерживайте для истории", action: #selector(backPressed(_:)))
        configureCircleButton(fwdBtn, symbol: "chevron.right", tooltip: "Вперёд", action: #selector(forwardPressed(_:)))
        configureCircleButton(upBtn, symbol: "arrow.up", tooltip: "В родительскую папку", action: #selector(upPressed(_:)))

        let navCluster = NSStackView(views: [backBtn, fwdBtn, upBtn])
        navCluster.orientation = .horizontal
        navCluster.spacing = 4
        navCluster.alignment = .centerY
        navCluster.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        countLabel.font = FPStyle.monoMetaFont(ofSize: 10, weight: .medium)
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countPill.addSubview(countLabel)
        countPill.setContentHuggingPriority(.required, for: .horizontal)
        countPill.setContentCompressionResistancePriority(.required, for: .horizontal)

        parentButton.isBordered = false
        parentButton.bezelStyle = .inline
        parentButton.font = FPStyle.bodyFont(ofSize: 12, weight: .medium)
        parentButton.target = self
        parentButton.action = #selector(upPressed(_:))
        parentButton.toolTip = L(
            "Перейти на уровень выше (двойной клик по заголовку — ввести путь ⌘L)",
            "Go to parent folder (double-click title to enter path ⌘L)"
        )
        parentButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        parentButton.translatesAutoresizingMaskIntoConstraints = false

        gitLabel.font = FPStyle.monoMetaFont(ofSize: 10, weight: .medium)
        gitLabel.lineBreakMode = .byTruncatingTail
        gitLabel.translatesAutoresizingMaskIntoConstraints = false
        gitPill.addSubview(gitLabel)
        gitPill.isHidden = true
        gitPill.setContentHuggingPriority(.required, for: .horizontal)
        gitPill.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            gitLabel.leadingAnchor.constraint(equalTo: gitPill.leadingAnchor, constant: 8),
            gitLabel.trailingAnchor.constraint(equalTo: gitPill.trailingAnchor, constant: -8),
            gitLabel.centerYAnchor.constraint(equalTo: gitPill.centerYAnchor),
            gitPill.heightAnchor.constraint(equalToConstant: 20)
        ])

        siblingStepper.onStep = { [weak self] delta in
            self?.onStepSiblingFolder?(delta)
        }
        siblingStepper.onSelectURL = { [weak self] url in
            self?.onOpenSiblingFolder?(url)
        }

        let heroCluster = NSStackView(views: [navCluster, titleLabel, countPill, siblingStepper, parentButton, gitPill])
        heroCluster.orientation = .horizontal
        heroCluster.spacing = 8
        heroCluster.alignment = .centerY
        heroCluster.detachesHiddenViews = true
        heroCluster.translatesAutoresizingMaskIntoConstraints = false

        // Встроенная капсула поиска.
        if #available(macOS 11.0, *) {
            searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Поиск")
        }
        searchIcon.imageScaling = .scaleProportionallyDown
        searchIcon.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Поиск…"
        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.focusRingType = .none
        searchField.drawsBackground = false
        searchField.font = FPStyle.bodyFont(ofSize: 12.5, weight: .medium)
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchSubmitted(_:))
        searchField.translatesAutoresizingMaskIntoConstraints = false

        searchScopeBtn.title = "Папка"
        searchScopeBtn.isBordered = false
        searchScopeBtn.bezelStyle = .inline
        searchScopeBtn.font = FPStyle.bodyFont(ofSize: 10.2, weight: .semibold)
        searchScopeBtn.target = self
        searchScopeBtn.action = #selector(scopePressed(_:))
        searchScopeBtn.toolTip = "Переключить поиск: текущая папка / весь Mac"
        searchScopeBtn.wantsLayer = true
        searchScopeBtn.layer?.cornerRadius = 9
        searchScopeBtn.translatesAutoresizingMaskIntoConstraints = false

        searchCapsule.addSubview(searchIcon)
        searchCapsule.addSubview(searchField)
        searchCapsule.addSubview(searchScopeBtn)
        let preferredSearchWidth = searchCapsule.widthAnchor.constraint(equalToConstant: 232)
        preferredSearchWidth.priority = NSLayoutConstraint.Priority(240)
        preferredSearchWidth.isActive = true
        searchCapsule.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true

        configureCircleButton(bookmarksBtn, symbol: "bookmark", tooltip: L("Закладки и закреплённые папки", "Bookmarks & pinned folders"), action: #selector(bookmarksPressed(_:)))

        filtersStack.orientation = .horizontal
        filtersStack.spacing = 2
        filtersStack.alignment = .centerY
        filtersStack.translatesAutoresizingMaskIntoConstraints = false
        filtersTray.addSubview(filtersStack)
        filtersTray.setContentHuggingPriority(.required, for: .horizontal)
        filtersTray.setContentCompressionResistancePriority(.required, for: .horizontal)

        let heroRow = NSView()
        heroRow.translatesAutoresizingMaskIntoConstraints = false
        heroRow.addSubview(heroCluster)
        heroRow.addSubview(filtersTray)
        heroRow.addSubview(bookmarksBtn)
        heroRow.addSubview(searchCapsule)

        // Строка 2: компактная лента быстрых папок на всю ширину + кнопка быстрого прыжка ⌘J.
        locationsStack.orientation = .horizontal
        locationsStack.spacing = 4.5
        locationsStack.alignment = .centerY
        locationsStack.translatesAutoresizingMaskIntoConstraints = false

        let locDoc = NSView()
        locDoc.translatesAutoresizingMaskIntoConstraints = false
        locDoc.addSubview(locationsStack)
        locationsScroll.documentView = locDoc
        locationsScroll.drawsBackground = false
        locationsScroll.borderType = .noBorder
        locationsScroll.hasHorizontalScroller = false
        locationsScroll.hasVerticalScroller = false
        locationsScroll.automaticallyAdjustsContentInsets = false
        locationsScroll.contentInsets = NSEdgeInsets()
        locationsScroll.translatesAutoresizingMaskIntoConstraints = false
        locationsScroll.contentView.postsBoundsChangedNotifications = true
        scrollBoundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: locationsScroll.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.updateLocationsFadeMask()
        }

        locationsFadeContainer.addSubview(locationsScroll)
        locationsFadeContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        locationsFadeContainer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(180), for: .horizontal)

        fuzzyJumpBtn.target = self
        fuzzyJumpBtn.action = #selector(fuzzyJumpPressed(_:))
        fuzzyJumpBtn.toolTip = L("Мгновенный переход к папке (⌘J)", "Fuzzy Jump to Folder (⌘J)")
        fuzzyJumpBtn.setContentHuggingPriority(.required, for: .horizontal)
        fuzzyJumpBtn.setContentCompressionResistancePriority(.required, for: .horizontal)

        let pillRow = NSView()
        pillRow.translatesAutoresizingMaskIntoConstraints = false
        pillRow.addSubview(locationsFadeContainer)
        pillRow.addSubview(fuzzyJumpBtn)

        addSubview(heroRow)
        addSubview(pillRow)
        addSubview(bottomHairline)

        NSLayoutConstraint.activate([
            countLabel.leadingAnchor.constraint(equalTo: countPill.leadingAnchor, constant: 7),
            countLabel.trailingAnchor.constraint(equalTo: countPill.trailingAnchor, constant: -7),
            countLabel.topAnchor.constraint(equalTo: countPill.topAnchor, constant: 2),
            countLabel.bottomAnchor.constraint(equalTo: countPill.bottomAnchor, constant: -2),

            searchCapsule.heightAnchor.constraint(equalToConstant: 28),
            searchIcon.leadingAnchor.constraint(equalTo: searchCapsule.leadingAnchor, constant: 10),
            searchIcon.centerYAnchor.constraint(equalTo: searchCapsule.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 13),
            searchIcon.heightAnchor.constraint(equalToConstant: 13),
            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 6),
            searchField.trailingAnchor.constraint(equalTo: searchScopeBtn.leadingAnchor, constant: -5),
            searchField.centerYAnchor.constraint(equalTo: searchCapsule.centerYAnchor),
            searchField.heightAnchor.constraint(equalToConstant: 22),
            searchScopeBtn.trailingAnchor.constraint(equalTo: searchCapsule.trailingAnchor, constant: -4),
            searchScopeBtn.centerYAnchor.constraint(equalTo: searchCapsule.centerYAnchor),
            searchScopeBtn.widthAnchor.constraint(equalToConstant: 44),
            searchScopeBtn.heightAnchor.constraint(equalToConstant: 20),

            filtersStack.leadingAnchor.constraint(equalTo: filtersTray.leadingAnchor, constant: 2),
            filtersStack.trailingAnchor.constraint(equalTo: filtersTray.trailingAnchor, constant: -2),
            filtersStack.topAnchor.constraint(equalTo: filtersTray.topAnchor, constant: 2),
            filtersStack.bottomAnchor.constraint(equalTo: filtersTray.bottomAnchor, constant: -2),
            filtersTray.heightAnchor.constraint(equalToConstant: 26),

            heroRow.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            heroRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            heroRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            heroRow.heightAnchor.constraint(equalToConstant: 32),

            heroCluster.leadingAnchor.constraint(equalTo: heroRow.leadingAnchor),
            heroCluster.centerYAnchor.constraint(equalTo: heroRow.centerYAnchor),
            heroCluster.trailingAnchor.constraint(lessThanOrEqualTo: filtersTray.leadingAnchor, constant: -10),
            filtersTray.trailingAnchor.constraint(equalTo: bookmarksBtn.leadingAnchor, constant: -7),
            filtersTray.centerYAnchor.constraint(equalTo: heroRow.centerYAnchor),
            bookmarksBtn.trailingAnchor.constraint(equalTo: searchCapsule.leadingAnchor, constant: -7),
            bookmarksBtn.centerYAnchor.constraint(equalTo: heroRow.centerYAnchor),
            searchCapsule.trailingAnchor.constraint(equalTo: heroRow.trailingAnchor),
            searchCapsule.centerYAnchor.constraint(equalTo: heroRow.centerYAnchor),

            locationsStack.leadingAnchor.constraint(equalTo: locDoc.leadingAnchor),
            locationsStack.trailingAnchor.constraint(equalTo: locDoc.trailingAnchor),
            locationsStack.topAnchor.constraint(equalTo: locDoc.topAnchor),
            locationsStack.bottomAnchor.constraint(equalTo: locDoc.bottomAnchor),
            locDoc.heightAnchor.constraint(equalTo: locationsScroll.contentView.heightAnchor),

            locationsScroll.leadingAnchor.constraint(equalTo: locationsFadeContainer.leadingAnchor),
            locationsScroll.trailingAnchor.constraint(equalTo: locationsFadeContainer.trailingAnchor),
            locationsScroll.topAnchor.constraint(equalTo: locationsFadeContainer.topAnchor),
            locationsScroll.bottomAnchor.constraint(equalTo: locationsFadeContainer.bottomAnchor),

            pillRow.topAnchor.constraint(equalTo: heroRow.bottomAnchor, constant: 5),
            pillRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            pillRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            pillRow.heightAnchor.constraint(equalToConstant: 24),

            locationsFadeContainer.leadingAnchor.constraint(equalTo: pillRow.leadingAnchor),
            locationsFadeContainer.trailingAnchor.constraint(equalTo: fuzzyJumpBtn.leadingAnchor, constant: -8),
            locationsFadeContainer.topAnchor.constraint(equalTo: pillRow.topAnchor),
            locationsFadeContainer.bottomAnchor.constraint(equalTo: pillRow.bottomAnchor),
            fuzzyJumpBtn.trailingAnchor.constraint(equalTo: pillRow.trailingAnchor),
            fuzzyJumpBtn.centerYAnchor.constraint(equalTo: pillRow.centerYAnchor),

            bottomHairline.topAnchor.constraint(equalTo: pillRow.bottomAnchor, constant: 6),
            bottomHairline.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            bottomHairline.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            bottomHairline.heightAnchor.constraint(equalToConstant: 0.75),
            bottomHairline.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        rebuildLocationAndFilterPills()
    }

    private func updateLocationsFadeMask() {
        let clipWidth = locationsScroll.contentView.bounds.width
        let docWidth = locationsScroll.documentView?.fittingSize.width
            ?? locationsScroll.documentView?.bounds.width
            ?? 0
        let scrollX = locationsScroll.contentView.bounds.origin.x
        let overflows = docWidth > clipWidth + 1.5
        let leadingFade = overflows && scrollX > 2
        let trailingFade = overflows && (scrollX + clipWidth < docWidth - 2)
        locationsFadeContainer.updateFade(leadingFade: leadingFade, trailingFade: trailingFade)
    }

    private func configureCircleButton(_ btn: NSButton, symbol: String, tooltip: String, action: Selector) {
        btn.title = ""
        btn.isBordered = false
        btn.bezelStyle = .inline
        btn.imagePosition = .imageOnly
        btn.toolTip = tooltip
        btn.target = self
        btn.action = action
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 14
        btn.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 11.0, *),
           let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 11.5, weight: .semibold)
            btn.image = img.withSymbolConfiguration(cfg) ?? img
        }
        btn.widthAnchor.constraint(equalToConstant: 28).isActive = true
        btn.heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    private func rebuildLocationAndFilterPills() {
        locationsStack.arrangedSubviews.forEach {
            locationsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        filtersStack.arrangedSubviews.forEach {
            filtersStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        locationPills.removeAll()
        filterPills.removeAll()

        let home = FileManager.default.homeDirectoryForCurrentUser

        let recents = QyvroStudioPillButton(title: L("Недавние", "Recents"), symbol: "clock.arrow.circlepath")
        recents.target = self
        recents.action = #selector(recentsPressed(_:))
        recentsPill = recents
        locationsStack.addArrangedSubview(recents)

        let places: [(String, String, URL)] = [
            (L("Загрузки", "Downloads"), "arrow.down.circle", home.appendingPathComponent("Downloads", isDirectory: true)),
            (L("Документы", "Documents"), "doc.text", home.appendingPathComponent("Documents", isDirectory: true)),
            (L("Стол", "Desktop"), "menubar.rectangle", home.appendingPathComponent("Desktop", isDirectory: true)),
            (L("Дом", "Home"), "house", home),
            (L("Фото", "Pictures"), "photo", home.appendingPathComponent("Pictures", isDirectory: true)),
            (L("Программы", "Apps"), "app.badge", URL(fileURLWithPath: "/Applications", isDirectory: true))
        ]
        for place in places {
            let pill = QyvroStudioPillButton(title: place.0, symbol: place.1, url: place.2)
            pill.target = self
            pill.action = #selector(locationPillPressed(_:))
            pill.onFilesDropped = { [weak self] urls, dest in
                self?.onMoveFilesToURL?(urls, dest) ?? false
            }
            locationPills.append(pill)
            locationsStack.addArrangedSubview(pill)
        }

        let drivesPill = QyvroStudioPillButton(title: L("Диски", "Drives"), symbol: "externaldrive")
        drivesPill.target = self
        drivesPill.action = #selector(volumesPressed(_:))
        locationsStack.addArrangedSubview(drivesPill)

        let tagsPill = QyvroStudioPillButton(title: L("Теги", "Tags"), symbol: "tag")
        tagsPill.target = self
        tagsPill.action = #selector(tagsPressed(_:))
        locationsStack.addArrangedSubview(tagsPill)

        let quickFilters: [(String, FPGridFilter)] = [
            (L("Все", "All"), .all),
            (L("Фото", "Photos"), .images),
            (L("Видео", "Videos"), .videos),
            ("★", .flagged)
        ]
        for entry in quickFilters {
            let pill = QyvroStudioPillButton(title: entry.0, filter: entry.1, style: .filterSegment)
            pill.target = self
            pill.action = #selector(filterPillPressed(_:))
            filterPills.append(pill)
            filtersStack.addArrangedSubview(pill)
        }
        updateFilter(.all)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            let pt = convert(event.locationInWindow, from: nil)
            if pt.y > bounds.height - 40 {
                onRequestPathEdit?()
                return
            }
        }
        window?.performDrag(with: event)
    }

    @objc private func fuzzyJumpPressed(_ sender: Any?) {
        onFuzzyJump?()
    }

    func updateTitle(_ title: String, parentSubtitle: String?, itemCount: Int, url: URL?, isRecents: Bool) {
        lastStudioTitleArgs = (title, parentSubtitle, itemCount, url, isRecents)
        let displayFont = FPStyle.displayFont(ofSize: 22, weight: .semibold)
        titleLabel.attributedStringValue = NSAttributedString(
            string: title,
            attributes: [
                .font: displayFont,
                .foregroundColor: FPStyle.text,
                .kern: -0.55
            ]
        )
        countLabel.font = FPStyle.monoMetaFont(ofSize: 10, weight: .medium)
        countLabel.stringValue = "\(itemCount)"
        countPill.isHidden = itemCount == 0
        if let parentSubtitle, !parentSubtitle.isEmpty, !isRecents {
            parentButton.font = FPStyle.bodyFont(ofSize: 12, weight: .medium)
            parentButton.title = "← \(parentSubtitle)"
            parentButton.isHidden = false
        } else {
            parentButton.isHidden = true
        }

        // Аккуратный Git-бейдж (только внутри git-репозиториев, асинхронно).
        gitFetchGeneration += 1
        let gen = gitFetchGeneration
        if let url, !isRecents {
            QyvroGitStatusProvider.shared.fetchStatus(for: url) { [weak self] summary in
                guard let self, self.gitFetchGeneration == gen else { return }
                if let summary {
                    self.gitLabel.stringValue = "⎇ \(summary.badgeText)"
                    self.gitLabel.textColor = summary.dirtyCount > 0 ? FPStyle.orange : FPStyle.dimText
                    self.gitPill.layer?.backgroundColor = (summary.dirtyCount > 0
                        ? FPStyle.accent.withAlphaComponent(0.11)
                        : FPStyle.control.withAlphaComponent(0.55)).cgColor
                    self.gitPill.layer?.borderColor = (summary.dirtyCount > 0
                        ? FPStyle.accent.withAlphaComponent(0.28)
                        : FPStyle.stroke.withAlphaComponent(0.55)).cgColor
                    self.gitPill.isHidden = false
                } else {
                    self.gitPill.isHidden = true
                }
            }
        } else {
            gitPill.isHidden = true
        }

        recentsPill?.isSelectedPill = isRecents
        let activePath = url?.standardizedFileURL.path
        var activePill: QyvroStudioPillButton? = isRecents ? recentsPill : nil
        for pill in locationPills {
            let selected = !isRecents && pill.folderURL?.standardizedFileURL.path == activePath
            pill.isSelectedPill = selected
            if selected { activePill = pill }
        }
        if let activePill, let doc = locationsScroll.documentView {
            let frameInDoc = doc.convert(activePill.bounds, from: activePill).insetBy(dx: -18, dy: 0)
            doc.scrollToVisible(frameInDoc)
        }
        updateLocationsFadeMask()
    }

    func updateSiblingFolders(_ siblings: [URL], currentIndex: Int, parentName: String) {
        siblingStepper.update(siblings: siblings, currentIndex: currentIndex, parentName: parentName)
    }

    func flashSiblingStep(delta: Int) {
        siblingStepper.flashStep(delta: delta)
    }

    func updateFilter(_ filter: FPGridFilter) {
        for pill in filterPills {
            pill.isSelectedPill = (pill.filterOption == filter)
        }
    }

    func updateSearch(query: String, isGlobalScope: Bool) {
        isGlobalSearch = isGlobalScope
        if searchField.stringValue != query {
            suppressSearchNotification = true
            searchField.stringValue = query
            suppressSearchNotification = false
        }
        searchScopeBtn.title = isGlobalScope ? L("Мак", "Mac") : L("Папка", "Folder")
        searchField.placeholderString = isGlobalScope ? L("Найти на Mac…", "Search Mac…") : L("Поиск в папке…", "Search folder…")
        applySearchScopeTheme()
    }

    func refreshLocalization() {
        let activeFilter = filterPills.first(where: \.isSelectedPill)?.filterOption ?? .all
        rebuildLocationAndFilterPills()
        updateFilter(activeFilter)
        searchScopeBtn.title = isGlobalSearch ? L("Мак", "Mac") : L("Папка", "Folder")
        searchField.placeholderString = isGlobalSearch ? L("Найти на Mac…", "Search Mac…") : L("Поиск в папке…", "Search folder…")
        if let args = lastStudioTitleArgs {
            updateTitle(args.title, parentSubtitle: args.parent, itemCount: args.count, url: args.url, isRecents: args.isRecents)
        }
        applyTheme()
    }

    var isSearchFieldFocused: Bool {
        window?.firstResponder === searchField.currentEditor()
    }

    func focusSearchField() {
        window?.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil)
    }

    func restoreSearchFocusPreservingCaret() {
        guard let window else { return }
        let loc = searchField.currentEditor()?.selectedRange.location ?? searchField.stringValue.utf16.count
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            window.makeFirstResponder(self.searchField)
            let len = self.searchField.stringValue.utf16.count
            self.searchField.currentEditor()?.selectedRange = NSRange(location: min(loc, len), length: 0)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if !searchField.stringValue.isEmpty {
                searchField.stringValue = ""
                onSearchTextChanged?("")
            }
            window?.makeFirstResponder(superview)
            return true
        }
        return false
    }

    func applyTheme() {
        let tint = FPStyle.text.blended(withFraction: 0.22, of: FPStyle.accent) ?? FPStyle.text
        for btn in [backBtn, fwdBtn, upBtn, bookmarksBtn] {
            btn.contentTintColor = FPStyle.dimText
            btn.layer?.backgroundColor = tint.withAlphaComponent(0.055).cgColor
            btn.layer?.borderColor = tint.withAlphaComponent(0.08).cgColor
            btn.layer?.borderWidth = 0.5
        }
        countPill.layer?.backgroundColor = tint.withAlphaComponent(0.07).cgColor
        countLabel.textColor = FPStyle.dimText
        siblingStepper.applyTheme()
        parentButton.contentTintColor = FPStyle.dimText.withAlphaComponent(0.78)
        fuzzyJumpBtn.updateAppearance()
        parentButton.font = FPStyle.bodyFont(ofSize: 12, weight: .medium)

        searchCapsule.layer?.backgroundColor = NSColor(calibratedWhite: 0.015, alpha: 0.44).cgColor
        searchCapsule.layer?.borderColor = tint.withAlphaComponent(0.095).cgColor
        searchCapsule.layer?.borderWidth = 0.5
        searchIcon.contentTintColor = FPStyle.dimText
        searchField.font = FPStyle.bodyFont(ofSize: 12.5, weight: .medium)
        searchField.textColor = FPStyle.text
        searchScopeBtn.font = FPStyle.bodyFont(ofSize: 10.2, weight: .semibold)
        applySearchScopeTheme()

        filtersTray.layer?.backgroundColor = NSColor(calibratedWhite: 0.01, alpha: 0.36).cgColor
        filtersTray.layer?.borderColor = tint.withAlphaComponent(0.085).cgColor
        filtersTray.layer?.borderWidth = 0.5

        bottomHairline.setColor(tint.withAlphaComponent(0.075))

        for case let pill as QyvroStudioPillButton in locationsStack.arrangedSubviews + filtersStack.arrangedSubviews {
            pill.updateAppearance(animated: false)
        }
        updateLocationsFadeMask()
    }

    private func applySearchScopeTheme() {
        let tint = FPStyle.text.blended(withFraction: 0.22, of: FPStyle.accent) ?? FPStyle.text
        searchScopeBtn.layer?.backgroundColor = (isGlobalSearch
            ? FPStyle.accent.withAlphaComponent(0.22)
            : tint.withAlphaComponent(0.075)).cgColor
        searchScopeBtn.contentTintColor = isGlobalSearch ? FPStyle.accent : FPStyle.dimText
    }

    func controlTextDidChange(_ obj: Notification) {
        guard !suppressSearchNotification, obj.object as? NSTextField === searchField else { return }
        onSearchTextChanged?(searchField.stringValue)
    }

    @objc private func searchSubmitted(_ sender: Any?) {
        onSearchTextChanged?(searchField.stringValue)
    }

    @objc private func scopePressed(_ sender: Any?) { onToggleSearchScope?() }
    @objc private func backPressed(_ sender: Any?) { onGoBack?() }
    @objc private func forwardPressed(_ sender: Any?) { onGoForward?() }
    @objc private func upPressed(_ sender: Any?) { onGoUp?() }
    @objc private func recentsPressed(_ sender: Any?) { onOpenRecents?() }
    @objc private func locationPillPressed(_ sender: QyvroStudioPillButton) {
        guard let url = sender.folderURL else { return }
        onOpenURL?(url)
    }
    @objc private func volumesPressed(_ sender: NSButton) { onShowVolumesMenu?(sender) }
    @objc private func bookmarksPressed(_ sender: NSButton) { onShowBookmarksMenu?(sender) }
    @objc private func tagsPressed(_ sender: NSButton) { onShowTagsMenu?(sender) }
    @objc private func filterPillPressed(_ sender: QyvroStudioPillButton) {
        guard let filter = sender.filterOption else { return }
        onPickFilter?(filter)
    }
}

// MARK: - Пустое состояние (Empty State)

final class QyvroEmptyStateView: NSView {
    var onPrimaryAction: (() -> Void)?

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        isHidden = true

        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 36).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 36).isActive = true

        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.alignment = .center
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        actionButton.isBordered = false
        actionButton.bezelStyle = .inline
        actionButton.wantsLayer = true
        actionButton.layer?.cornerRadius = 13
        actionButton.target = self
        actionButton.action = #selector(actionPressed(_:))
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let stack = NSStackView(views: [iconView, titleLabel, subtitleLabel, actionButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 7
        stack.setCustomSpacing(12, after: iconView)
        stack.setCustomSpacing(14, after: subtitleLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -14),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 320)
        ])
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(symbol: String, title: String, subtitle: String, actionTitle: String?) {
        if #available(macOS 11.0, *),
           let img = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 30, weight: .light)
            iconView.image = img.withSymbolConfiguration(cfg) ?? img
        }
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        if let actionTitle {
            actionButton.isHidden = false
            actionButton.attributedTitle = NSAttributedString(
                string: "  \(actionTitle)  ",
                attributes: [
                    .font: FPStyle.bodyFont(ofSize: 12, weight: .medium),
                    .foregroundColor: FPStyle.accent
                ]
            )
        } else {
            actionButton.isHidden = true
        }
        applyTheme()
    }

    func applyTheme() {
        iconView.contentTintColor = FPStyle.dimText.withAlphaComponent(0.45)
        titleLabel.font = FPStyle.headingFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = FPStyle.text.withAlphaComponent(0.88)
        subtitleLabel.font = FPStyle.bodyFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = FPStyle.dimText.withAlphaComponent(0.75)
        actionButton.layer?.backgroundColor = FPStyle.accent.withAlphaComponent(0.16).cgColor
        actionButton.layer?.borderColor = FPStyle.accent.withAlphaComponent(0.45).cgColor
        actionButton.layer?.borderWidth = 0.75
    }

    @objc private func actionPressed(_ sender: Any?) {
        onPrimaryAction?()
    }
}

// MARK: - Плавающая капсула действий при мультивыделении (2+ объекта)

final class QyvroSelectionActionBar: NSVisualEffectView {
    var onCompare: (() -> Void)?
    var onAddToShelf: (() -> Void)?
    var onCompressZIP: (() -> Void)?
    var onBatchRename: (() -> Void)?
    var onTrash: (() -> Void)?
    var onClearSelection: (() -> Void)?

    private let summaryLabel = NSTextField(labelWithString: "")
    private let compareBtn = NSButton()
    private let shelfBtn = NSButton()
    private let zipBtn = NSButton()
    private let renameBtn = NSButton()
    private let trashBtn = NSButton()
    private let clearBtn = NSButton()
    private var visible = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.masksToBounds = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.42
        layer?.shadowRadius = 16
        layer?.shadowOffset = NSSize(width: 0, height: -4)
        alphaValue = 0
        isHidden = true

        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.setContentHuggingPriority(.required, for: .horizontal)

        configureAction(compareBtn, title: L("Сравнить", "Compare"), symbol: "rectangle.split.2x1", action: #selector(comparePressed(_:)))
        configureAction(shelfBtn, title: L("Полка", "Shelf"), symbol: "tray.and.arrow.down", action: #selector(shelfPressed(_:)))
        configureAction(zipBtn, title: "ZIP", symbol: "doc.zipper", action: #selector(zipPressed(_:)))
        configureAction(renameBtn, title: L("Переименовать", "Rename"), symbol: "pencil.line", action: #selector(renamePressed(_:)))
        configureAction(trashBtn, title: L("В корзину", "Trash"), symbol: "trash", isDestructive: true, action: #selector(trashPressed(_:)))
        configureClose(clearBtn)

        let stack = NSStackView(views: [summaryLabel, compareBtn, shelfBtn, zipBtn, renameBtn, trashBtn, clearBtn])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.detachesHiddenViews = true
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 12, bottom: 5, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configureAction(_ btn: NSButton, title: String, symbol: String, isDestructive: Bool = false, action: Selector) {
        btn.isBordered = false
        btn.bezelStyle = .inline
        btn.imagePosition = .imageLeading
        btn.imageHugsTitle = true
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 11
        btn.target = self
        btn.action = action
        btn.tag = isDestructive ? 1 : 0
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.heightAnchor.constraint(equalToConstant: 24).isActive = true
        btn.title = title
        if #available(macOS 11.0, *),
           let img = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .medium)
            btn.image = img.withSymbolConfiguration(cfg) ?? img
        }
    }

    private func configureClose(_ btn: NSButton) {
        btn.isBordered = false
        btn.bezelStyle = .inline
        btn.imagePosition = .imageOnly
        btn.toolTip = "Снять выделение (Esc)"
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 11
        btn.target = self
        btn.action = #selector(clearPressed(_:))
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.widthAnchor.constraint(equalToConstant: 22).isActive = true
        btn.heightAnchor.constraint(equalToConstant: 22).isActive = true
        if #available(macOS 11.0, *),
           let img = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Снять выделение") {
            let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            btn.image = img.withSymbolConfiguration(cfg) ?? img
        }
    }

    func update(selectedItems: [FileItem]) {
        guard selectedItems.count >= 2 else {
            setBarVisible(false)
            return
        }
        let nonDirs = selectedItems.filter { !$0.isDirectory }
        let bytes = nonDirs.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        var text = L("Выбрано \(selectedItems.count)", "\(selectedItems.count) selected")
        if bytes > 0 {
            text += " · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
        }
        summaryLabel.stringValue = text
        compareBtn.title = L("Сравнить", "Compare")
        shelfBtn.title = L("Полка", "Shelf")
        renameBtn.title = L("Переименовать", "Rename")
        trashBtn.title = L("В корзину", "Trash")
        compareBtn.isHidden = !(selectedItems.count == 2 && nonDirs.count == 2)
        applyTheme()
        setBarVisible(true)
    }

    private func setBarVisible(_ show: Bool) {
        guard visible != show else { return }
        visible = show
        if show {
            isHidden = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, !self.visible else { return }
                self.isHidden = true
            })
        }
    }

    func applyTheme() {
        let tint = FPStyle.text.blended(withFraction: 0.22, of: FPStyle.accent) ?? FPStyle.text
        layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 0.84).cgColor
        layer?.borderColor = tint.withAlphaComponent(0.16).cgColor
        layer?.borderWidth = 0.75

        summaryLabel.font = FPStyle.monoMetaFont(ofSize: 10.8, weight: .medium)
        summaryLabel.textColor = FPStyle.text.withAlphaComponent(0.88)

        let danger = NSColor(calibratedRed: 0.96, green: 0.40, blue: 0.42, alpha: 1)
        for btn in [compareBtn, shelfBtn, zipBtn, renameBtn, trashBtn] {
            let destructive = btn.tag == 1
            let isPrimary = btn === compareBtn
            let fg: NSColor
            let bg: NSColor
            if destructive {
                fg = danger
                bg = danger.withAlphaComponent(0.14)
            } else if isPrimary {
                fg = FPStyle.accent
                bg = FPStyle.accent.withAlphaComponent(0.20)
            } else {
                fg = FPStyle.text.withAlphaComponent(0.90)
                bg = tint.withAlphaComponent(0.08)
            }
            btn.layer?.backgroundColor = bg.cgColor
            btn.contentTintColor = fg
            btn.attributedTitle = NSAttributedString(
                string: " \(btn.title.trimmingCharacters(in: .whitespaces)) ",
                attributes: [
                    .font: FPStyle.bodyFont(ofSize: 11.2, weight: .medium),
                    .foregroundColor: fg
                ]
            )
        }
        clearBtn.contentTintColor = FPStyle.dimText
        clearBtn.layer?.backgroundColor = tint.withAlphaComponent(0.06).cgColor
    }

    @objc private func comparePressed(_ sender: Any?) { onCompare?() }
    @objc private func shelfPressed(_ sender: Any?) { onAddToShelf?() }
    @objc private func zipPressed(_ sender: Any?) { onCompressZIP?() }
    @objc private func renamePressed(_ sender: Any?) { onBatchRename?() }
    @objc private func trashPressed(_ sender: Any?) { onTrash?() }
    @objc private func clearPressed(_ sender: Any?) { onClearSelection?() }
}

// MARK: - Лёгкий стеклянный тост с кнопкой «Отменить ⌘Z»

final class QyvroToastBanner: NSVisualEffectView {
    private let iconView = NSImageView()
    private let messageLabel = NSTextField(labelWithString: "")
    private let undoButton = NSButton()
    private var undoHandler: (() -> Void)?
    private var dismissWorkItem: DispatchWorkItem?
    private var isShowing = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
        alphaValue = 0
        isHidden = true

        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 14).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 14).isActive = true

        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        undoButton.isBordered = false
        undoButton.bezelStyle = .inline
        undoButton.wantsLayer = true
        undoButton.layer?.cornerRadius = 10
        undoButton.target = self
        undoButton.action = #selector(undoPressed(_:))
        undoButton.translatesAutoresizingMaskIntoConstraints = false
        undoButton.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let stack = NSStackView(views: [iconView, messageLabel, undoButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.detachesHiddenViews = true
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 12, bottom: 5, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(message: String, symbol: String = "checkmark.circle.fill", undoTitle: String? = nil, onUndo: (() -> Void)? = nil) {
        dismissWorkItem?.cancel()
        undoHandler = onUndo
        if #available(macOS 11.0, *),
           let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            iconView.image = img.withSymbolConfiguration(cfg) ?? img
        }
        messageLabel.stringValue = message
        if let undoTitle, onUndo != nil {
            undoButton.isHidden = false
            undoButton.attributedTitle = NSAttributedString(
                string: "  \(undoTitle)  ",
                attributes: [
                    .font: FPStyle.bodyFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: FPStyle.accent
                ]
            )
        } else {
            undoButton.isHidden = true
        }
        applyTheme()
        isShowing = true
        isHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            animator().alphaValue = 1
        }
        let work = DispatchWorkItem { [weak self] in
            self?.dismiss()
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (onUndo != nil ? 4.0 : 2.6), execute: work)
    }

    func dismiss() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        guard isShowing else { return }
        isShowing = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.isShowing else { return }
            self.isHidden = true
        })
    }

    func applyTheme() {
        let tint = FPStyle.text.blended(withFraction: 0.22, of: FPStyle.accent) ?? FPStyle.text
        layer?.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 0.88).cgColor
        layer?.borderColor = tint.withAlphaComponent(0.16).cgColor
        layer?.borderWidth = 0.75
        iconView.contentTintColor = FPStyle.accent
        messageLabel.font = FPStyle.bodyFont(ofSize: 11.8, weight: .medium)
        messageLabel.textColor = FPStyle.text
        undoButton.layer?.backgroundColor = FPStyle.accent.withAlphaComponent(0.18).cgColor
    }

    @objc private func undoPressed(_ sender: Any?) {
        let action = undoHandler
        undoHandler = nil
        dismiss()
        action?()
    }
}
