import Cocoa

/// Какие края окна тянет пользователь. Комбинация двух смежных краёв даёт угол.
struct QyvroWindowResizeEdge: OptionSet, Hashable {
    let rawValue: Int

    static let left = QyvroWindowResizeEdge(rawValue: 1 << 0)
    static let right = QyvroWindowResizeEdge(rawValue: 1 << 1)
    static let top = QyvroWindowResizeEdge(rawValue: 1 << 2)
    static let bottom = QyvroWindowResizeEdge(rawValue: 1 << 3)

    var isHorizontal: Bool { contains(.left) || contains(.right) }
    var isVertical: Bool { contains(.top) || contains(.bottom) }
}

struct QyvroWindowResizeInsets {
    var left: CGFloat = 10
    var right: CGFloat = 10
    var top: CGFloat = 6
    var bottom: CGFloat = 8
    var cornerSize: CGFloat = 16
}

struct QyvroWindowResizeRegion: Equatable {
    let rect: NSRect
    let edge: QyvroWindowResizeEdge
}

/// Чистая геометрия захвата краёв и пересчёта рамки окна.
///
/// Вынесена отдельно от `NSView`, чтобы смоук-тест мог проверять все восемь
/// направлений, ограничения `minSize`/`maxSize`, упор в строку меню и
/// симметричный ресайз с `⌥` без поднятия живых окон.
enum QyvroWindowResizeGeometry {
    static func edge(
        at point: NSPoint,
        in bounds: NSRect,
        insets: QyvroWindowResizeInsets,
        excludedRects: [NSRect] = []
    ) -> QyvroWindowResizeEdge {
        guard bounds.width > 0, bounds.height > 0, bounds.contains(point) else { return [] }
        if excludedRects.contains(where: { $0.contains(point) }) { return [] }

        let nearLeft = point.x - bounds.minX <= insets.left
        let nearRight = bounds.maxX - point.x <= insets.right
        let nearBottom = point.y - bounds.minY <= insets.bottom
        let nearTop = bounds.maxY - point.y <= insets.top

        guard nearLeft || nearRight || nearBottom || nearTop else { return [] }

        var result: QyvroWindowResizeEdge = []
        if nearLeft && !nearRight { result.insert(.left) }
        if nearRight && !nearLeft { result.insert(.right) }
        if nearBottom && !nearTop { result.insert(.bottom) }
        if nearTop && !nearBottom { result.insert(.top) }

        let corner = max(insets.cornerSize, max(insets.left, insets.right, insets.top, insets.bottom))
        if result.contains(.left) || result.contains(.right) {
            if point.y - bounds.minY <= corner {
                result.insert(.bottom)
            } else if bounds.maxY - point.y <= corner {
                result.insert(.top)
            }
        }
        if result.contains(.bottom) || result.contains(.top) {
            if point.x - bounds.minX <= corner {
                result.insert(.left)
            } else if bounds.maxX - point.x <= corner {
                result.insert(.right)
            }
        }

        // На крошечном окне зоны могут пересечься: противоположные края не совмещаем.
        if result.contains(.left) && result.contains(.right) {
            result.remove(.right)
        }
        if result.contains(.top) && result.contains(.bottom) {
            result.remove(.top)
        }
        return result
    }

    /// Непересекающиеся полосы по краям и углам для курсоров.
    ///
    /// Центр окна остаётся полностью свободным от tracking-областей, поэтому
    /// движение мыши по сетке файлов не создаёт лишней нагрузки, а кнопки
    /// светофора вырезаются из верхнего левого угла.
    static func cursorRegions(
        in bounds: NSRect,
        insets: QyvroWindowResizeInsets,
        excludedRects: [NSRect] = []
    ) -> [QyvroWindowResizeRegion] {
        guard bounds.width > 40, bounds.height > 40 else { return [] }
        let corner = min(
            max(insets.cornerSize, max(insets.left, insets.right, insets.top, insets.bottom)),
            min(bounds.width, bounds.height) * 0.25
        )
        let leftW = min(insets.left, corner)
        let rightW = min(insets.right, corner)
        let bottomH = min(insets.bottom, corner)
        let topH = min(insets.top, corner)

        let raw: [QyvroWindowResizeRegion] = [
            // Четыре угловых L-фрагмента (по два прямоугольника на угол, без захвата внутренностей).
            QyvroWindowResizeRegion(
                rect: NSRect(x: bounds.minX, y: bounds.minY, width: leftW, height: corner),
                edge: [.left, .bottom]
            ),
            QyvroWindowResizeRegion(
                rect: NSRect(x: bounds.minX + leftW, y: bounds.minY, width: corner - leftW, height: bottomH),
                edge: [.left, .bottom]
            ),
            QyvroWindowResizeRegion(
                rect: NSRect(x: bounds.maxX - rightW, y: bounds.minY, width: rightW, height: corner),
                edge: [.right, .bottom]
            ),
            QyvroWindowResizeRegion(
                rect: NSRect(x: bounds.maxX - corner, y: bounds.minY, width: corner - rightW, height: bottomH),
                edge: [.right, .bottom]
            ),
            QyvroWindowResizeRegion(
                rect: NSRect(x: bounds.minX, y: bounds.maxY - corner, width: leftW, height: corner),
                edge: [.left, .top]
            ),
            QyvroWindowResizeRegion(
                rect: NSRect(x: bounds.minX + leftW, y: bounds.maxY - topH, width: corner - leftW, height: topH),
                edge: [.left, .top]
            ),
            QyvroWindowResizeRegion(
                rect: NSRect(x: bounds.maxX - rightW, y: bounds.maxY - corner, width: rightW, height: corner),
                edge: [.right, .top]
            ),
            QyvroWindowResizeRegion(
                rect: NSRect(x: bounds.maxX - corner, y: bounds.maxY - topH, width: corner - rightW, height: topH),
                edge: [.right, .top]
            ),
            // Четыре прямых края между углами.
            QyvroWindowResizeRegion(
                rect: NSRect(x: bounds.minX, y: bounds.minY + corner, width: leftW, height: bounds.height - corner * 2),
                edge: .left
            ),
            QyvroWindowResizeRegion(
                rect: NSRect(x: bounds.maxX - rightW, y: bounds.minY + corner, width: rightW, height: bounds.height - corner * 2),
                edge: .right
            ),
            QyvroWindowResizeRegion(
                rect: NSRect(x: bounds.minX + corner, y: bounds.minY, width: bounds.width - corner * 2, height: bottomH),
                edge: .bottom
            ),
            QyvroWindowResizeRegion(
                rect: NSRect(x: bounds.minX + corner, y: bounds.maxY - topH, width: bounds.width - corner * 2, height: topH),
                edge: .top
            )
        ]

        var result: [QyvroWindowResizeRegion] = []
        for region in raw where region.rect.width > 0.5 && region.rect.height > 0.5 {
            let pieces = subtract(excludedRects, from: region.rect)
            for piece in pieces where piece.width > 0.5 && piece.height > 0.5 {
                result.append(QyvroWindowResizeRegion(rect: piece, edge: region.edge))
            }
        }
        return result
    }

    static func resizedFrame(
        from startFrame: NSRect,
        edge: QyvroWindowResizeEdge,
        delta: NSPoint,
        minSize: NSSize,
        maxSize: NSSize,
        visibleFrame: NSRect?,
        symmetric: Bool
    ) -> NSRect {
        let minW = max(1, minSize.width)
        let minH = max(1, minSize.height)
        let maxW = max(minW, maxSize.width)
        let maxH = max(minH, maxSize.height)
        let factor: CGFloat = symmetric ? 2 : 1

        var frame = startFrame

        if edge.contains(.right) {
            let targetWidth = clamp(startFrame.width + delta.x * factor, min: minW, max: maxW)
            frame.size.width = targetWidth
            frame.origin.x = symmetric ? startFrame.midX - targetWidth / 2 : startFrame.minX
        } else if edge.contains(.left) {
            let targetWidth = clamp(startFrame.width - delta.x * factor, min: minW, max: maxW)
            frame.size.width = targetWidth
            frame.origin.x = symmetric ? startFrame.midX - targetWidth / 2 : startFrame.maxX - targetWidth
        }

        if edge.contains(.top) {
            var upperH = maxH
            if let visibleFrame, !symmetric {
                upperH = min(upperH, max(minH, visibleFrame.maxY - startFrame.minY))
            }
            var targetHeight = clamp(startFrame.height + delta.y * factor, min: minH, max: upperH)
            var originY = symmetric ? startFrame.midY - targetHeight / 2 : startFrame.minY
            if let visibleFrame, symmetric, originY + targetHeight > visibleFrame.maxY {
                let allowedHalf = max(minH / 2, visibleFrame.maxY - startFrame.midY)
                targetHeight = clamp(allowedHalf * 2, min: minH, max: maxH)
                originY = startFrame.midY - targetHeight / 2
            }
            frame.size.height = targetHeight
            frame.origin.y = originY
        } else if edge.contains(.bottom) {
            let targetHeight = clamp(startFrame.height - delta.y * factor, min: minH, max: maxH)
            frame.size.height = targetHeight
            frame.origin.y = symmetric ? startFrame.midY - targetHeight / 2 : startFrame.maxY - targetHeight
        }

        return NSRect(
            x: frame.origin.x.rounded(),
            y: frame.origin.y.rounded(),
            width: frame.size.width.rounded(),
            height: frame.size.height.rounded()
        )
    }

    /// Двойной щелчок по краю окна тянет этот край до границы экрана —
    /// так же ведут себя стандартные окна macOS.
    static func expandedFrame(
        from startFrame: NSRect,
        edge: QyvroWindowResizeEdge,
        maxSize: NSSize,
        visibleFrame: NSRect
    ) -> NSRect {
        var frame = startFrame
        if edge.contains(.left) {
            let newWidth = min(maxSize.width, frame.maxX - visibleFrame.minX)
            if newWidth > frame.width {
                frame.origin.x = frame.maxX - newWidth
                frame.size.width = newWidth
            }
        }
        if edge.contains(.right) {
            let newWidth = min(maxSize.width, visibleFrame.maxX - frame.minX)
            if newWidth > frame.width {
                frame.size.width = newWidth
            }
        }
        if edge.contains(.bottom) {
            let newHeight = min(maxSize.height, frame.maxY - visibleFrame.minY)
            if newHeight > frame.height {
                frame.origin.y = frame.maxY - newHeight
                frame.size.height = newHeight
            }
        }
        if edge.contains(.top) {
            let newHeight = min(maxSize.height, visibleFrame.maxY - frame.minY)
            if newHeight > frame.height {
                frame.size.height = newHeight
            }
        }
        return frame.integral
    }

    private static func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, lower), upper)
    }

    private static func subtract(_ cutouts: [NSRect], from rect: NSRect) -> [NSRect] {
        var pieces = [rect]
        for cutout in cutouts {
            var next: [NSRect] = []
            for piece in pieces {
                let overlap = piece.intersection(cutout)
                if overlap.isNull || overlap.isEmpty {
                    next.append(piece)
                    continue
                }
                if overlap.minX > piece.minX {
                    next.append(NSRect(x: piece.minX, y: piece.minY, width: overlap.minX - piece.minX, height: piece.height))
                }
                if overlap.maxX < piece.maxX {
                    next.append(NSRect(x: overlap.maxX, y: piece.minY, width: piece.maxX - overlap.maxX, height: piece.height))
                }
                if overlap.minY > piece.minY {
                    next.append(NSRect(x: overlap.minX, y: piece.minY, width: overlap.width, height: overlap.minY - piece.minY))
                }
                if overlap.maxY < piece.maxY {
                    next.append(NSRect(x: overlap.minX, y: overlap.maxY, width: overlap.width, height: piece.maxY - overlap.maxY))
                }
            }
            pieces = next
        }
        return pieces
    }
}

/// Прозрачная накладка по краям полупрозрачных окон Qyvro.
///
/// У стандартного `NSThemeFrame` внутренняя зона захвата края — всего 2–3 точки,
/// а полупрозрачное окно с `isMovableByWindowBackground = true` не имеет жёсткой
/// рамки: промах на пару пикселей внутрь начинал двигать окно вместо его ресайза.
/// Накладка продлевает родную зону захвата внутрь пустых полей окна (8–10 точек),
/// показывает нативный курсор ресайза даже на неактивном окне и полностью
/// пропускает клики в центре.
final class QyvroWindowResizeOverlay: NSView {
    private static let edgeUserInfoKey = "edge"

    private let insets: QyvroWindowResizeInsets
    private var edgeTrackingAreas: [NSTrackingArea] = []
    private var fullScreenObservers: [NSObjectProtocol] = []

    init(insets: QyvroWindowResizeInsets = QyvroWindowResizeInsets()) {
        self.insets = insets
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        fullScreenObservers.forEach(NotificationCenter.default.removeObserver)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @discardableResult
    static func install(
        in container: NSView,
        insets: QyvroWindowResizeInsets = QyvroWindowResizeInsets()
    ) -> QyvroWindowResizeOverlay {
        let overlay = QyvroWindowResizeOverlay(insets: insets)
        container.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: container.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return overlay
    }

    func bringToFront() {
        guard let superview, superview.subviews.last !== self else { return }
        superview.addSubview(self, positioned: .above, relativeTo: nil)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        fullScreenObservers.forEach(NotificationCenter.default.removeObserver)
        fullScreenObservers.removeAll()

        guard let window else { return }
        let center = NotificationCenter.default
        fullScreenObservers = [
            center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                self?.updateTrackingAreas()
            },
            center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                self?.updateTrackingAreas()
            }
        ]
        updateTrackingAreas()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden,
              let superview,
              let window,
              window.styleMask.contains(.resizable),
              !window.styleMask.contains(.fullScreen) else {
            return nil
        }
        let localPoint = convert(point, from: superview)
        let edge = QyvroWindowResizeGeometry.edge(
            at: localPoint,
            in: bounds,
            insets: insets,
            excludedRects: trafficLightExclusionRects()
        )
        return edge.isEmpty ? nil : self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in edgeTrackingAreas {
            removeTrackingArea(area)
        }
        edgeTrackingAreas.removeAll()

        guard let window,
              window.styleMask.contains(.resizable),
              !window.styleMask.contains(.fullScreen) else {
            return
        }

        let regions = QyvroWindowResizeGeometry.cursorRegions(
            in: bounds,
            insets: insets,
            excludedRects: trafficLightExclusionRects()
        )
        for region in regions {
            let area = NSTrackingArea(
                rect: region.rect,
                options: [.cursorUpdate, .activeAlways],
                owner: self,
                userInfo: [Self.edgeUserInfoKey: region.edge.rawValue]
            )
            addTrackingArea(area)
            edgeTrackingAreas.append(area)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        guard let raw = event.trackingArea?.userInfo?[Self.edgeUserInfoKey] as? Int else {
            super.cursorUpdate(with: event)
            return
        }
        let edge = QyvroWindowResizeEdge(rawValue: raw)
        Self.cursor(for: edge).set()
    }

    override func mouseDown(with event: NSEvent) {
        guard let window,
              window.styleMask.contains(.resizable),
              !window.styleMask.contains(.fullScreen) else {
            super.mouseDown(with: event)
            return
        }
        let localPoint = convert(event.locationInWindow, from: nil)
        let edge = QyvroWindowResizeGeometry.edge(
            at: localPoint,
            in: bounds,
            insets: insets,
            excludedRects: trafficLightExclusionRects()
        )
        guard !edge.isEmpty else {
            super.mouseDown(with: event)
            return
        }

        if event.clickCount == 2,
           let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            let expanded = QyvroWindowResizeGeometry.expandedFrame(
                from: window.frame,
                edge: edge,
                maxSize: window.maxSize,
                visibleFrame: visible
            )
            if expanded != window.frame {
                window.setFrame(expanded, display: true, animate: true)
            }
            return
        }

        let startMouse = NSEvent.mouseLocation
        let startFrame = window.frame
        let minSize = effectiveMinSize(for: window)
        let maxSize = window.maxSize
        let resizeCursor = Self.cursor(for: edge)

        resizeCursor.push()
        defer { NSCursor.pop() }

        window.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp],
            timeout: .infinity,
            mode: .eventTracking
        ) { nextEvent, stop in
            guard let nextEvent else {
                stop.pointee = true
                return
            }
            if nextEvent.type == .leftMouseUp {
                stop.pointee = true
                return
            }
            let currentMouse = NSEvent.mouseLocation
            let delta = NSPoint(
                x: currentMouse.x - startMouse.x,
                y: currentMouse.y - startMouse.y
            )
            let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame
            let target = QyvroWindowResizeGeometry.resizedFrame(
                from: startFrame,
                edge: edge,
                delta: delta,
                minSize: minSize,
                maxSize: maxSize,
                visibleFrame: visibleFrame,
                symmetric: nextEvent.modifierFlags.contains(.option)
            )
            if target != window.frame {
                window.setFrame(target, display: true)
            }
        }
    }

    private func effectiveMinSize(for window: NSWindow) -> NSSize {
        let contentMin = window.frameRect(forContentRect: NSRect(origin: .zero, size: window.contentMinSize)).size
        return NSSize(
            width: max(window.minSize.width, contentMin.width),
            height: max(window.minSize.height, contentMin.height)
        )
    }

    private func trafficLightExclusionRects() -> [NSRect] {
        guard let window else { return [] }
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        return buttons.compactMap { type in
            guard let button = window.standardWindowButton(type), !button.isHidden else { return nil }
            let rect = convert(button.bounds, from: button)
            return rect.insetBy(dx: -3, dy: -3)
        }
    }

    static func cursor(for edge: QyvroWindowResizeEdge) -> NSCursor {
        if #available(macOS 15.0, *) {
            switch edge {
            case .left:
                return .frameResize(position: .left, directions: .all)
            case .right:
                return .frameResize(position: .right, directions: .all)
            case .top:
                return .frameResize(position: .top, directions: .all)
            case .bottom:
                return .frameResize(position: .bottom, directions: .all)
            case [.left, .top]:
                return .frameResize(position: .topLeft, directions: .all)
            case [.right, .top]:
                return .frameResize(position: .topRight, directions: .all)
            case [.left, .bottom]:
                return .frameResize(position: .bottomLeft, directions: .all)
            case [.right, .bottom]:
                return .frameResize(position: .bottomRight, directions: .all)
            default:
                break
            }
        }
        if edge.isHorizontal && !edge.isVertical {
            return .resizeLeftRight
        }
        if edge.isVertical && !edge.isHorizontal {
            return .resizeUpDown
        }
        return .crosshair
    }
}
