import Cocoa
import Quartz
class FPLayerView: NSView {
    init(color: NSColor, cornerRadius: CGFloat = 0, borderColor: NSColor? = nil, borderWidth: CGFloat = 0) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = cornerRadius
        layer?.borderColor = borderColor?.cgColor
        layer?.borderWidth = borderWidth
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setColor(_ color: NSColor) {
        layer?.backgroundColor = color.cgColor
    }
}

/// A visual-only tint which never intercepts clicks or window dragging.
final class FPBackgroundTintView: FPLayerView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A gradient overlay placed above an `NSVisualEffectView`'s private blur
/// layers. Putting the gradient directly on the visual-effect view can make
/// AppKit composite the blur over it and wash the theme colors away.
final class FPBackgroundGradientView: NSView {
    private let gradientLayer = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        gradientLayer.locations = [0, 1]
        gradientLayer.startPoint = CGPoint(x: 0, y: 0)
        gradientLayer.endPoint = CGPoint(x: 1, y: 1)
        gradientLayer.actions = [
            "colors": NSNull(),
            "bounds": NSNull(),
            "position": NSNull()
        ]
        layer?.addSublayer(gradientLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        gradientLayer.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setColors(_ colors: [NSColor]) {
        if colors.count <= 1 {
            gradientLayer.locations = [0]
        } else {
            gradientLayer.locations = (0..<colors.count).map {
                NSNumber(value: Double($0) / Double(colors.count - 1))
            }
        }
        gradientLayer.colors = colors.map(\.cgColor)
    }
}

/// Extra visual language for the optional Cyber Editorial theme: three large
/// off-axis color glows. It is a single composited layer tree, so it does not
/// add per-file views or affect scrolling.
final class FPEditorialBackdropView: NSView {
    private let magentaGlow = CAGradientLayer()
    private let acidGlow = CAGradientLayer()
    private let violetGlow = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        [magentaGlow, acidGlow, violetGlow].forEach {
            $0.type = .radial
            $0.actions = [
                "colors": NSNull(),
                "bounds": NSNull(),
                "position": NSNull()
            ]
            layer?.addSublayer($0)
        }
        magentaGlow.startPoint = CGPoint(x: 0.86, y: 0.88)
        magentaGlow.endPoint = CGPoint(x: 0.16, y: 0.18)
        acidGlow.startPoint = CGPoint(x: 0.16, y: 0.18)
        acidGlow.endPoint = CGPoint(x: 0.78, y: 0.72)
        violetGlow.startPoint = CGPoint(x: 0.12, y: 0.86)
        violetGlow.endPoint = CGPoint(x: 0.82, y: 0.16)
        refreshTheme()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        magentaGlow.frame = bounds
        acidGlow.frame = bounds
        violetGlow.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func refreshTheme() {
        isHidden = !FPStyle.isCyberEditorial
        magentaGlow.colors = [
            FPStyle.orange.withAlphaComponent(0.20).cgColor,
            FPStyle.orange.withAlphaComponent(0.045).cgColor,
            NSColor.clear.cgColor
        ]
        magentaGlow.locations = [0, 0.40, 1]
        acidGlow.colors = [
            FPStyle.accent.withAlphaComponent(0.14).cgColor,
            FPStyle.accent.withAlphaComponent(0.025).cgColor,
            NSColor.clear.cgColor
        ]
        acidGlow.locations = [0, 0.38, 1]
        violetGlow.colors = [
            NSColor(calibratedRed: 0.545, green: 0.361, blue: 1.0, alpha: 0.15).cgColor,
            NSColor(calibratedRed: 0.545, green: 0.361, blue: 1.0, alpha: 0.02).cgColor,
            NSColor.clear.cgColor
        ]
        violetGlow.locations = [0, 0.42, 1]
        needsLayout = true
    }
}

final class EscapeClosingWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        guard !(event.type == .keyDown && event.keyCode == 53) else { performClose(nil); return }
        super.sendEvent(event)
    }
}

final class EscapeClosingPanel: NSPanel {
    override func sendEvent(_ event: NSEvent) {
        guard !(event.type == .keyDown && event.keyCode == 53) else { performClose(nil); return }
        super.sendEvent(event)
    }
}

final class TagManagerController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private weak var backgroundTintView: FPBackgroundTintView?
    var onShowAll: (() -> Void)?

    init() {
        let panel = EscapeClosingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 390),
            styleMask: [.titled, .closable, .utilityWindow, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Теги"
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init(window: panel)
        buildUI()
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged(_:)), name: .fpThemeDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        applyAppearance()
        reloadRows()
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in self?.reloadRows() }
    }

    private func buildUI() {
        guard let window else { return }
        let root = NSVisualEffectView()
        root.material = .sidebar
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        window.contentView = root

        let backgroundTint = FPBackgroundTintView(color: FPStyle.tagWindow)
        backgroundTintView = backgroundTint
        root.addSubview(backgroundTint)
        NSLayoutConstraint.activate([
            backgroundTint.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            backgroundTint.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            backgroundTint.topAnchor.constraint(equalTo: root.topAnchor),
            backgroundTint.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        let heading = NSTextField(labelWithString: "Имена и цвета тегов")
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        heading.textColor = FPStyle.text
        heading.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tag"))
        column.width = 360
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 38
        tableView.intercellSpacing = NSSize(width: 0, height: 3)
        tableView.backgroundColor = .clear
        tableView.delegate = self
        tableView.dataSource = self
        tableView.allowsEmptySelection = true
        tableView.doubleAction = #selector(editTag(_:))
        tableView.target = self
        tableView.autoresizingMask = [.width]
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let add = compactButton("Добавить", symbol: "plus", action: #selector(addTag(_:)))
        let edit = compactButton("Изменить", symbol: "pencil", action: #selector(editTag(_:)))
        let remove = compactButton("Удалить", symbol: "trash", action: #selector(removeTag(_:)))
        let showAll = compactButton("Все отмеченные", symbol: "tag", action: #selector(showAll(_:)))
        let actions = NSStackView(views: [add, edit, remove, NSView(), showAll])
        actions.orientation = .horizontal
        actions.spacing = 6
        actions.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(heading)
        root.addSubview(scrollView)
        root.addSubview(actions)
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 34),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            scrollView.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -10),
            actions.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            actions.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            actions.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            actions.heightAnchor.constraint(equalToConstant: 30)
        ])
        reloadRows()
    }

    @objc private func themeChanged(_ notification: Notification) {
        applyAppearance()
        tableView.reloadData()
    }

    private func applyAppearance() {
        backgroundTintView?.setColor(FPStyle.tagWindow)
    }

    private func reloadRows() {
        let width = max(scrollView.contentSize.width, 380)
        let height = max(CGFloat(FPTag.all.count) * (tableView.rowHeight + tableView.intercellSpacing.height), 1)
        tableView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        tableView.tableColumns.first?.width = width
        tableView.reloadData()
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func compactButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.bezelStyle = .inline
        button.font = .systemFont(ofSize: 11.5, weight: .medium)
        button.contentTintColor = FPStyle.text
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        button.layer?.backgroundColor = FPStyle.controlStrong.cgColor
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    func numberOfRows(in tableView: NSTableView) -> Int { FPTag.all.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard FPTag.all.indices.contains(row) else { return nil }
        let tag = FPTag.all[row]
        let cell = NSTableCellView()
        let dot = FPLayerView(color: tag.color, cornerRadius: 7)
        let title = NSTextField(labelWithString: tag.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = FPStyle.text
        title.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(dot)
        cell.addSubview(title)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            dot.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 14),
            dot.heightAnchor.constraint(equalToConstant: 14),
            title.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            title.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    @objc private func addTag(_ sender: Any?) { editDefinition(nil) }

    @objc private func editTag(_ sender: Any?) {
        let row = tableView.selectedRow
        guard FPTag.all.indices.contains(row) else { NSSound.beep(); return }
        editDefinition(FPTag.all[row])
    }

    private func editDefinition(_ tag: FPTag?) {
        NSColorPanel.shared.showsAlpha = false
        let alert = NSAlert()
        alert.messageText = tag == nil ? "Новый тег" : "Изменить тег"
        alert.addButton(withTitle: "Сохранить")
        alert.addButton(withTitle: "Отмена")
        let name = NSTextField(string: tag?.title ?? "Новый тег")
        name.placeholderString = "Название тега"
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.textColor = FPStyle.text
        name.focusRingType = .none
        name.widthAnchor.constraint(equalToConstant: 252).isActive = true
        name.heightAnchor.constraint(equalToConstant: 27).isActive = true
        let color = ThemeColorWell()
        color.color = tag?.color ?? FPStyle.accent
        color.suggestedColorsProvider = { themeSuggestedColors() }
        color.widthAnchor.constraint(equalToConstant: 54).isActive = true
        color.heightAnchor.constraint(equalToConstant: 27).isActive = true
        let row = NSStackView(views: [color, name])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        row.frame = NSRect(x: 0, y: 0, width: 316, height: 28)
        alert.accessoryView = row
        alert.layout()
        alert.window.initialFirstResponder = name
        DispatchQueue.main.async {
            alert.window.makeFirstResponder(name)
            name.selectText(nil)
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        if let tag {
            FPTagStore.shared.update(key: tag.key, title: title, color: color.color)
        } else {
            FPTagStore.shared.add(title: title, color: color.color)
        }
        reloadRows()
    }

    @objc private func removeTag(_ sender: Any?) {
        let row = tableView.selectedRow
        guard FPTag.all.indices.contains(row) else { NSSound.beep(); return }
        let tag = FPTag.all[row]
        let alert = NSAlert()
        alert.messageText = "Удалить тег «\(tag.title)»?"
        alert.informativeText = "Файлы останутся на месте, исчезнет только эта метка."
        alert.addButton(withTitle: "Удалить")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        FPTagStore.shared.remove(key: tag.key)
        reloadRows()
    }

    @objc private func showAll(_ sender: Any?) {
        onShowAll?()
        close()
    }
}

final class FPSidebarView: NSVisualEffectView {
    private let tintLayer = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .underWindowBackground
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        updateTint()
        tintLayer.locations = [0, 0.55, 1]
        tintLayer.startPoint = CGPoint(x: 0, y: 0)
        tintLayer.endPoint = CGPoint(x: 1, y: 1)
        tintLayer.actions = ["colors": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.insertSublayer(tintLayer, at: 0)
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged(_:)), name: .fpThemeDidChange, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        tintLayer.frame = bounds
    }

    @objc private func themeChanged(_ notification: Notification) {
        updateTint()
    }

    private func updateTint() {
        let tint = FPStyle.sidebar
        let opacity = min(max(tint.alphaComponent, 0), 1)
        if FPStyle.isCyberEditorial {
            tintLayer.colors = [
                FPStyle.window.withAlphaComponent(opacity * 0.72).cgColor,
                tint.withAlphaComponent(opacity * 0.80).cgColor,
                FPStyle.gradientStart.withAlphaComponent(opacity * 0.18).cgColor
            ]
            return
        }
        let shadowTint = tint.blended(withFraction: 0.34, of: .black) ?? tint
        tintLayer.colors = [
            tint.withAlphaComponent(opacity * 0.82).cgColor,
            tint.withAlphaComponent(opacity).cgColor,
            shadowTint.withAlphaComponent(opacity * 0.88).cgColor
        ]
    }
}

final class FPSidebarResizeHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        onDrag?(event.locationInWindow.x)
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.locationInWindow.x)
    }
}

class AnimatedSidebarButton: NSButton {
    private static weak var currentlyHoveredButton: AnimatedSidebarButton?
    private var textAnimationID = UUID()
    private var hoverTrackingArea: NSTrackingArea?
    private var hoverBackgroundActive = false
    private var preHoverBackgroundColor: CGColor?

    override func mouseDown(with event: NSEvent) {
        // Keep the current multi-selection intact until this click is known not to be a drag.
        animateActivation()
        super.mouseDown(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        setHoverBackgroundActive(true, animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHoverBackgroundActive(false, animated: true)
    }

    /// AppKit does not reliably emit `mouseExited` when a scroll view moves the
    /// hovered row under a stationary cursor. Re-evaluate from the current
    /// screen position so only the row physically under the pointer stays lit.
    func refreshHoverStateFromCurrentMouseLocation(animated: Bool = false) {
        guard let window, !isHidden else {
            setHoverBackgroundActive(false, animated: animated)
            return
        }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let localPoint = convert(windowPoint, from: nil)
        let shouldHover = bounds.contains(localPoint) && visibleRect.contains(localPoint)
        setHoverBackgroundActive(shouldHover, animated: animated)
    }

    private func setHoverBackgroundActive(_ active: Bool, animated: Bool) {
        if active {
            if let previous = Self.currentlyHoveredButton, previous !== self {
                previous.setHoverBackgroundActive(false, animated: animated)
            }
            Self.currentlyHoveredButton = self
        } else if Self.currentlyHoveredButton === self {
            Self.currentlyHoveredButton = nil
        }
        guard hoverBackgroundActive != active else { return }
        hoverBackgroundActive = active
        if !active {
            applyHoverBackground(preHoverBackgroundColor ?? NSColor.clear.cgColor, animated: animated)
            preHoverBackgroundColor = nil
            return
        }
        hoverBackgroundActive = true
        wantsLayer = true
        if layer?.cornerRadius == 0 {
            layer?.cornerRadius = 8
        }
        preHoverBackgroundColor = layer?.backgroundColor
        let base = preHoverBackgroundColor.flatMap { NSColor(cgColor: $0) }
        let baseAlpha = base?.alphaComponent ?? 0
        // Прозрачные кнопки получают лёгкую подложку, уже подкрашенные —
        // становятся чуть ярче; свой прежний фон вернётся при уходе курсора.
        let hoverColor = baseAlpha < 0.02
            ? FPStyle.control
            : NSColor(calibratedWhite: 1.0, alpha: min(0.20, baseAlpha + 0.05))
        applyHoverBackground(hoverColor.cgColor, animated: animated)
    }

    // Мягкая hover-подложка для кнопок боковой панели. Drag-подсветки
    // (BookmarkDropButton/TagDropButton) рисуют свой фон сами — их значения
    // не перетираются, потому что во время drag-сессии hover-события не идут.
    private func applyHoverBackground(_ color: CGColor, animated: Bool) {
        guard animated else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.backgroundColor = color
            CATransaction.commit()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            layer?.backgroundColor = color
        }
    }

    private func animateActivation() {
        let animationID = UUID()
        textAnimationID = animationID
        let baseTitle = NSMutableAttributedString(attributedString: attributedTitle)
        if baseTitle.length > 0 {
            baseTitle.addAttribute(.foregroundColor, value: FPStyle.text, range: NSRange(location: 0, length: baseTitle.length))
        }
        let steps = 38
        let duration = FPPreferences.sidebarAnimationDuration
        for step in 0...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration * Double(step) / Double(steps)) { [weak self] in
                guard let self, self.textAnimationID == animationID else { return }
                let progress = CGFloat(step) / CGFloat(steps)
                let animated = NSMutableAttributedString(attributedString: baseTitle)
                // A wide two-tone sweep reads as one continuous highlight instead of
                // a thin scanner line. The offset lobes also give the wave a diagonal feel.
                let waveCenter = -0.52 + progress * 2.04
                let waveWidth: CGFloat = 0.58
                let cyanCenter = waveCenter - 0.17
                let orangeCenter = waveCenter + 0.17
                for index in 0..<max(animated.length, 1) {
                    guard index < animated.length else { continue }
                    let characterPosition = animated.length <= 1 ? 0.5 : CGFloat(index) / CGFloat(animated.length - 1)
                    let cyanDistance = abs(characterPosition - cyanCenter)
                    let orangeDistance = abs(characterPosition - orangeCenter)
                    let cyanGlow = pow(max(0, 1 - cyanDistance / waveWidth), 1.65)
                    let orangeGlow = pow(max(0, 1 - orangeDistance / waveWidth), 1.65)
                    var color = FPStyle.text.blended(withFraction: cyanGlow * 0.96, of: FPStyle.accent) ?? FPStyle.text
                    color = color.blended(withFraction: orangeGlow * 0.92, of: FPStyle.orange) ?? color
                    animated.addAttribute(.foregroundColor, value: color, range: NSRange(location: index, length: 1))
                }
                self.attributedTitle = animated
                if step == steps { self.attributedTitle = baseTitle }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.08) { [weak self] in
            guard let self, self.textAnimationID == animationID else { return }
            self.attributedTitle = baseTitle
        }
    }
}

final class LocationButton: AnimatedSidebarButton {
    var locationURL: URL?
    var contextMenuProvider: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?() ?? super.menu(for: event)
    }
}

final class ViewScaleRail: NSControl {
    var value: Double = 50 {
        didSet {
            value = min(max(value, 0), 100)
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let track = NSRect(x: bounds.midX - 3, y: 8, width: 6, height: max(1, bounds.height - 16))
        let trackPath = NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3)
        FPStyle.controlStrong.setFill()
        trackPath.fill()

        let progress = NSRect(x: track.minX, y: track.minY, width: track.width, height: track.height * CGFloat(value / 100))
        let progressPath = NSBezierPath(roundedRect: progress, xRadius: 3, yRadius: 3)
        FPStyle.orange.setFill()
        progressPath.fill()

        let knobY = track.minY + track.height * CGFloat(value / 100)
        let knob = NSRect(x: bounds.midX - 8, y: knobY - 8, width: 16, height: 16)
        NSColor(calibratedWhite: 0.91, alpha: 1).setFill()
        NSBezierPath(ovalIn: knob).fill()
        FPStyle.stroke.setStroke()
        let outline = NSBezierPath(ovalIn: knob.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        outline.stroke()
    }

    override func mouseDown(with event: NSEvent) { updateValue(with: event) }
    override func mouseDragged(with event: NSEvent) { updateValue(with: event) }

    private func updateValue(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let usable = max(1, bounds.height - 16)
        value = Double((point.y - 8) / usable * 100)
        sendAction(action, to: target)
    }
}

func themeSuggestedColors() -> [NSColor] {
    let bases = [
        FPStyle.accent, FPStyle.orange, FPStyle.defaultFolder,
        FPStyle.gradientStart, FPStyle.gradientEnd,
        FPStyle.sidebar.withAlphaComponent(1), FPStyle.bar.withAlphaComponent(1)
    ]
    let variants = bases.flatMap { color -> [NSColor] in
        [
            color,
            color.blended(withFraction: 0.24, of: .white) ?? color,
            color.blended(withFraction: 0.22, of: .black) ?? color
        ]
    }
    var result: [NSColor] = []
    for color in variants {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        let signature = String(format: "%.2f-%.2f-%.2f", rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
        let alreadyIncluded = result.contains { existing in
            let value = existing.usingColorSpace(.deviceRGB) ?? existing
            return String(format: "%.2f-%.2f-%.2f", value.redComponent, value.greenComponent, value.blueComponent) == signature
        }
        if !alreadyIncluded { result.append(rgb.withAlphaComponent(1)) }
    }
    return Array(result.prefix(18))
}

final class ColorSwatchButton: NSButton {
    let swatchColor: NSColor
    var onPick: ((NSColor) -> Void)?

    init(color: NSColor) {
        swatchColor = color
        super.init(frame: .zero)
        title = ""
        isBordered = false
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = 7
        layer?.borderColor = FPStyle.stroke.cgColor
        layer?.borderWidth = 1
        target = self
        action = #selector(pick(_:))
        widthAnchor.constraint(equalToConstant: 27).isActive = true
        heightAnchor.constraint(equalToConstant: 27).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func pick(_ sender: Any?) { onPick?(swatchColor) }
}

final class ThemeColorWell: NSColorWell {
    var suggestedColorsProvider: (() -> [NSColor])?
    private var suggestionsPopover: NSPopover?

    override func mouseDown(with event: NSEvent) {
        showSuggestions()
    }

    private func showSuggestions() {
        if suggestionsPopover?.isShown == true {
            suggestionsPopover?.close()
            return
        }

        let colors = suggestedColorsProvider?() ?? themeSuggestedColors()
        var rows: [[NSView]] = []
        for start in stride(from: 0, to: colors.count, by: 6) {
            let row = Array(colors[start..<min(start + 6, colors.count)]).map { color -> NSView in
                let button = ColorSwatchButton(color: color)
                button.onPick = { [weak self] picked in self?.applyPickedColor(picked) }
                return button
            }
            rows.append(row)
        }
        while let lastCount = rows.last?.count, lastCount < 6 {
            let spacer = NSView()
            spacer.widthAnchor.constraint(equalToConstant: 27).isActive = true
            spacer.heightAnchor.constraint(equalToConstant: 27).isActive = true
            rows[rows.count - 1].append(spacer)
        }

        let title = NSTextField(labelWithString: "Цвета текущей темы")
        title.font = .systemFont(ofSize: 11.5, weight: .semibold)
        title.textColor = FPStyle.text
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 6
        grid.columnSpacing = 6
        let spectrum = NSButton(title: "Любой цвет…", target: self, action: #selector(openSystemColorPanel(_:)))
        spectrum.isBordered = false
        spectrum.bezelStyle = .inline
        spectrum.font = .systemFont(ofSize: 11.5, weight: .medium)
        spectrum.contentTintColor = FPStyle.orange
        spectrum.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: "Любой цвет")
        spectrum.imagePosition = .imageLeading
        spectrum.wantsLayer = true
        spectrum.layer?.cornerRadius = 7
        spectrum.layer?.backgroundColor = FPStyle.controlStrong.cgColor
        spectrum.heightAnchor.constraint(equalToConstant: 29).isActive = true

        let stack = NSStackView(views: [title, grid, spectrum])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 220, height: CGFloat(92 + rows.count * 33)))
        root.material = .menu
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 12
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        let controller = NSViewController()
        controller.view = root
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = root.frame.size
        popover.contentViewController = controller
        suggestionsPopover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxX)
    }

    private func applyPickedColor(_ picked: NSColor) {
        color = picked
        suggestionsPopover?.close()
        sendAction(action, to: target)
    }

    @objc private func openSystemColorPanel(_ sender: Any?) {
        suggestionsPopover?.close()
        let panel = NSColorPanel.shared
        panel.showsAlpha = true
        panel.color = color
        panel.setTarget(self)
        panel.setAction(#selector(systemColorChanged(_:)))
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func systemColorChanged(_ sender: NSColorPanel) {
        color = sender.color
        sendAction(action, to: target)
    }
}

func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
    let objects = pasteboard.readObjects(
        forClasses: [NSURL.self],
        options: [.urlReadingFileURLsOnly: true]
    ) as? [NSURL] ?? []
    let urls = objects.map { $0 as URL }
    if !urls.isEmpty { return urls }

    return pasteboard.string(forType: .string)?
        .split(whereSeparator: \.isNewline)
        .map { URL(fileURLWithPath: String($0)) } ?? []
}

final class BookmarkDropButton: AnimatedSidebarButton {
    var onURLsDropped: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .string])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(from: sender.draggingPasteboard).isEmpty else { return [] }
        setHover(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setHover(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setHover(false)
        let urls = fileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        onURLsDropped?(urls)
        return true
    }

    private func setHover(_ active: Bool) {
        layer?.backgroundColor = (active ? FPStyle.orangeFill.withAlphaComponent(0.42) : NSColor.clear).cgColor
        layer?.borderColor = (active ? FPStyle.orange : NSColor.clear).cgColor
        layer?.borderWidth = active ? 1 : 0
    }
}

final class TagDropButton: AnimatedSidebarButton {
    let tagKey: String?
    private let displayTitle: String
    private let tagColor: NSColor?
    var onApply: ((String?, [URL]) -> Void)?
    var onOpen: ((String?, String) -> Void)?

    init(title: String, key: String?, color: NSColor?) {
        tagKey = key
        displayTitle = title
        tagColor = color
        super.init(frame: .zero)
        configure(title: title)
        registerForDraggedTypes([.fileURL, .string])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(from: sender.draggingPasteboard).isEmpty else { return [] }
        setHover(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setHover(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setHover(false)
        let urls = fileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        onApply?(tagKey, urls)
        return true
    }

    private func configure(title: String) {
        self.title = title
        userInterfaceLayoutDirection = .leftToRight
        alignment = .left
        cell?.alignment = .left
        cell?.baseWritingDirection = .leftToRight
        bezelStyle = .inline
        isBordered = false
        imagePosition = .imageLeading
        if let tagColor {
            image = tagDot(color: tagColor)
        } else if #available(macOS 11.0, *) {
            image = NSImage(systemSymbolName: "tag", accessibilityDescription: title)
        }
        contentTintColor = tagColor ?? FPStyle.dimText
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.baseWritingDirection = .leftToRight
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: FPStyle.text,
                .paragraphStyle: paragraph
            ]
        )
        target = self
        action = #selector(applyToSelection(_:))
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderColor = NSColor.clear.cgColor
        layer?.borderWidth = 0
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        widthAnchor.constraint(equalToConstant: 210).isActive = true
    }

    private func tagDot(color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 12, height: 12)).fill()
        image.unlockFocus()
        return image
    }

    private func setHover(_ active: Bool) {
        layer?.backgroundColor = (active ? FPStyle.accentFill : NSColor.clear).cgColor
        layer?.borderColor = (active ? FPStyle.accent : NSColor.clear).cgColor
        layer?.borderWidth = active ? 1 : 0
    }

    @objc private func applyToSelection(_ sender: Any?) {
        onOpen?(tagKey, displayTitle)
    }
}

final class FPFlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class CenteredTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let textSize = cellSize(forBounds: rect)
        var centered = super.drawingRect(forBounds: rect)
        centered.origin.y = rect.origin.y + max(0, (rect.height - textSize.height) / 2) - 1
        centered.size.height = min(centered.height, textSize.height + 2)
        return centered
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}

final class CenteredTextField: NSTextField {
    override class var cellClass: AnyClass? {
        get { CenteredTextFieldCell.self }
        set {}
    }
}

final class FPToolbarButton: NSButton {
    private var trackingAreaReference: NSTrackingArea?
    private var restingBackground: CGColor?
    private var restingBorder: CGColor?
    private var isHovering = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard !isHovering else { return }
        isHovering = true
        restingBackground = layer?.backgroundColor
        restingBorder = layer?.borderColor
        animateLayer {
            self.layer?.backgroundColor = FPStyle.controlStrong.cgColor
            self.layer?.borderColor = FPStyle.accent.withAlphaComponent(0.42).cgColor
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard isHovering else { return }
        isHovering = false
        let background = restingBackground ?? FPStyle.control.cgColor
        let border = restingBorder ?? FPStyle.stroke.cgColor
        animateLayer {
            self.layer?.backgroundColor = background
            self.layer?.borderColor = border
        }
        restingBackground = nil
        restingBorder = nil
    }

    override func mouseDown(with event: NSEvent) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            super.mouseDown(with: event)
            return
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.08)
        layer?.setAffineTransform(CGAffineTransform(scaleX: 0.94, y: 0.94))
        CATransaction.commit()
        super.mouseDown(with: event)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.14)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        layer?.setAffineTransform(.identity)
        CATransaction.commit()
    }

    private func animateLayer(_ changes: () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            changes()
        }
    }
}

final class HorizontalSwipeTracker {
    private enum GestureAxis {
        case undecided
        case horizontal
        case vertical
    }

    private var accumulatedX: CGFloat = 0
    private var accumulatedY: CGFloat = 0
    private var beganSent = false
    private var didTrigger = false
    private var axis: GestureAxis = .undecided
    /// Ось завершившегося жеста; живёт ровно столько, сколько идёт его инерция.
    ///
    /// Раньше инерция гасилась по таймеру на 0.12 с, а macOS после резкого
    /// флика шлёт momentum-события ещё секунду-две. Остаток горизонтальной
    /// инерции проходил насквозь в NSScrollView и уводил сетку вбок под
    /// оверлеем: к моменту передачи кадра живая сетка стояла не там, где
    /// показанный снимок, и переход заканчивался рывком.
    private var momentumAxis: GestureAxis = .undecided

    func handle(
        _ event: NSEvent,
        began: (() -> Void)? = nil,
        progress: ((CGFloat, CGFloat) -> Void)? = nil,
        completion: ((Bool) -> Void)? = nil,
        action: (CGFloat) -> Void
    ) -> Bool {
        if event.momentumPhase != [] {
            let shouldConsume = axis == .horizontal || momentumAxis == .horizontal
            if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
                axis = .undecided
                momentumAxis = .undecided
            }
            return shouldConsume
        }
        let deltaX = event.scrollingDeltaX
        let deltaY = event.scrollingDeltaY
        let isEnding = event.phase == .ended || event.phase == .cancelled

        if event.phase == .began {
            accumulatedX = 0
            accumulatedY = 0
            beganSent = false
            didTrigger = false
            axis = .undecided
            // Новый жест отменяет инерцию предыдущего — macOS в этот момент
            // и сама обрывает momentum-поток.
            momentumAxis = .undecided
        }

        guard event.hasPreciseScrollingDeltas else { return false }
        accumulatedX += deltaX
        accumulatedY += deltaY

        if axis == .undecided {
            let horizontalDistance = abs(accumulatedX)
            let verticalDistance = abs(accumulatedY)
            let meaningfulDistance = max(horizontalDistance, verticalDistance)
            if meaningfulDistance >= 5.0 {
                if horizontalDistance >= max(5.0, verticalDistance * 1.38) {
                    axis = .horizontal
                } else if verticalDistance >= max(4.0, horizontalDistance * 1.12) {
                    axis = .vertical
                }
            }
            if axis == .undecided {
                if isEnding {
                    accumulatedX = 0
                    accumulatedY = 0
                    beganSent = false
                    didTrigger = false
                    axis = .undecided
                }
                // Do not swallow the first few points while the direction is still
                // ambiguous. Vertical scrolling must stay immediate and native.
                return false
            }
        }

        if axis == .vertical {
            if isEnding {
                momentumAxis = .vertical
                accumulatedX = 0
                accumulatedY = 0
                beganSent = false
                didTrigger = false
                axis = .undecided
            }
            return false
        }

        if axis == .horizontal {
            if !beganSent {
                beganSent = true
                began?()
            }
            let normalized = min(1.18, abs(accumulatedX) / max(FPPreferences.swipeThreshold, 1))
            progress?(accumulatedX, normalized)
            // Commit while the fingers are still moving. Waiting for `.ended`
            // made a short trackpad flick feel roughly half a second behind the
            // hand and also caused a second rapid physical gesture to arrive
            // before the first navigation had even been submitted.
            let activationThreshold = max(14, min(40, FPPreferences.swipeThreshold * 0.30))
            if !didTrigger, abs(accumulatedX) >= activationThreshold {
                didTrigger = true
                action(accumulatedX)
            }
        }

        if isEnding {
            let committed = event.phase != .cancelled
                && (didTrigger || abs(accumulatedX) >= FPPreferences.swipeThreshold * 0.72)
            if committed, !didTrigger {
                didTrigger = true
                action(accumulatedX)
            }
            completion?(committed)
            // Инерцию этого жеста гасим целиком — до её собственного
            // momentumPhase == .ended, а не по фиксированному таймауту.
            momentumAxis = .horizontal
            accumulatedX = 0
            accumulatedY = 0
            beganSent = false
            didTrigger = false
            axis = .undecided
        }
        return true
    }
}

final class SwipeNavigationIndicator: NSVisualEffectView {
    private let imageView = NSImageView()
    private let gradientLayer = CAGradientLayer()
    private var imageCenterConstraint: NSLayoutConstraint!
    private var hideWorkItem: DispatchWorkItem?
    private var acceptingUpdates = false
    private var displayedProgress: CGFloat = 0
    private(set) var goesBack = true
    private(set) var progress: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 32
        layer?.borderWidth = 0.6
        layer?.borderColor = FPStyle.stroke.withAlphaComponent(0.82).cgColor
        layer?.backgroundColor = FPStyle.bar.withAlphaComponent(0.70).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        gradientLayer.cornerRadius = 32
        gradientLayer.startPoint = CGPoint(x: 0.08, y: 0.95)
        gradientLayer.endPoint = CGPoint(x: 0.92, y: 0.05)
        gradientLayer.opacity = 0.26
        layer?.insertSublayer(gradientLayer, at: 0)
        alphaValue = 0
        isHidden = true
        imageView.imageScaling = .scaleProportionallyDown
        imageView.contentTintColor = FPStyle.orange
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        imageCenterConstraint = imageView.centerXAnchor.constraint(equalTo: centerXAnchor, constant: 14)
        NSLayoutConstraint.activate([
            imageCenterConstraint,
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 25),
            imageView.heightAnchor.constraint(equalToConstant: 25)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        gradientLayer.frame = bounds
    }

    func beginGesture() {
        hideWorkItem?.cancel()
        acceptingUpdates = true
        displayedProgress = 0
        isHidden = false
        alphaValue = 0
        scheduleAutoHide()
    }

    func update(goesBack: Bool, progress: CGFloat) {
        guard acceptingUpdates else { return }
        self.goesBack = goesBack
        let target = min(max(progress, 0), 1)
        displayedProgress += (target - displayedProgress) * 0.42
        self.progress = displayedProgress
        imageView.image = NSImage(
            systemSymbolName: goesBack ? "chevron.left" : "chevron.right",
            accessibilityDescription: goesBack ? "Назад" : "Вперёд"
        )
        imageView.image = imageView.image?.withSymbolConfiguration(.init(pointSize: 18, weight: .semibold))
        imageCenterConstraint.constant = goesBack ? 14 : -14
        isHidden = false
        gradientLayer.colors = goesBack
            ? [FPStyle.accent.withAlphaComponent(0.78).cgColor, FPStyle.orange.withAlphaComponent(0.88).cgColor]
            : [FPStyle.orange.withAlphaComponent(0.88).cgColor, FPStyle.accent.withAlphaComponent(0.78).cgColor]
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.09)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        layer?.opacity = Float(0.28 + self.progress * 0.70)
        gradientLayer.opacity = Float(0.16 + self.progress * 0.34)
        CATransaction.commit()
        alphaValue = 1
        layer?.backgroundColor = FPStyle.bar.blended(withFraction: self.progress * 0.18, of: FPStyle.accent)?.withAlphaComponent(0.78).cgColor
        scheduleAutoHide()
    }

    func finish(committed: Bool) {
        acceptingUpdates = false
        hideWorkItem?.cancel()
        hideWorkItem = nil
        dismiss(duration: committed ? 0.22 : 0.16)
    }

    private func scheduleAutoHide() {
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.acceptingUpdates = false
            self?.hideWorkItem = nil
            self?.dismiss(duration: 0.18)
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.92, execute: work)
    }

    private func dismiss(duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.isHidden = true
            self?.progress = 0
            self?.displayedProgress = 0
        }
    }
}

// The live history transition. It deliberately renders the snapshots at 1x and
// lets Core Animation scale the short-lived surface: the real pixel displacement
// remains visible, while the AMD GPU can sustain the animation without blocking
// AppKit on this Intel Mac.
