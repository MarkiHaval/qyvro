import Cocoa

enum WindowResizeSmokeError: Error {
    case failed(String)
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw WindowResizeSmokeError.failed(message) }
}

do {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)

    // 1. Геометрия зон захвата и углов.
    let bounds = NSRect(x: 0, y: 0, width: 1_200, height: 800)
    let insets = QyvroWindowResizeInsets(left: 10, right: 10, top: 6, bottom: 8, cornerSize: 16)
    let trafficLight = NSRect(x: 11, y: 774, width: 64, height: 20)

    try require(
        QyvroWindowResizeGeometry.edge(at: NSPoint(x: 5, y: 400), in: bounds, insets: insets, excludedRects: [trafficLight]) == .left,
        "left edge grab zone missed at x=5"
    )
    try require(
        QyvroWindowResizeGeometry.edge(at: NSPoint(x: 1_194, y: 400), in: bounds, insets: insets, excludedRects: [trafficLight]) == .right,
        "right edge grab zone missed at x=1194"
    )
    try require(
        QyvroWindowResizeGeometry.edge(at: NSPoint(x: 600, y: 4), in: bounds, insets: insets, excludedRects: [trafficLight]) == .bottom,
        "bottom edge grab zone missed at y=4"
    )
    try require(
        QyvroWindowResizeGeometry.edge(at: NSPoint(x: 600, y: 797), in: bounds, insets: insets, excludedRects: [trafficLight]) == .top,
        "top edge grab zone missed at y=797"
    )
    try require(
        QyvroWindowResizeGeometry.edge(at: NSPoint(x: 6, y: 6), in: bounds, insets: insets, excludedRects: [trafficLight]) == [.left, .bottom],
        "bottom-left corner grab zone missed"
    )
    try require(
        QyvroWindowResizeGeometry.edge(at: NSPoint(x: 1_195, y: 796), in: bounds, insets: insets, excludedRects: [trafficLight]) == [.right, .top],
        "top-right corner grab zone missed"
    )
    try require(
        QyvroWindowResizeGeometry.edge(at: NSPoint(x: 20, y: 785), in: bounds, insets: insets, excludedRects: [trafficLight]).isEmpty,
        "traffic light exclusion rect was intercepted"
    )
    try require(
        QyvroWindowResizeGeometry.edge(at: NSPoint(x: 200, y: 400), in: bounds, insets: insets, excludedRects: [trafficLight]).isEmpty,
        "window interior should not trigger resize"
    )

    let regions = QyvroWindowResizeGeometry.cursorRegions(in: bounds, insets: insets, excludedRects: [trafficLight])
    try require(!regions.isEmpty, "cursor regions should not be empty")
    try require(
        !regions.contains(where: { $0.rect.intersects(trafficLight) }),
        "cursor regions must not overlap traffic light buttons"
    )

    // 2. Пересчёт рамки окна при перетаскивании.
    let startFrame = NSRect(x: 200, y: 120, width: 1_000, height: 700)
    let minSize = NSSize(width: 680, height: 460)
    let maxSize = NSSize(width: 2_000, height: 1_200)
    let visible = NSRect(x: 0, y: 0, width: 1_728, height: 1_050)

    let narrowedLeft = QyvroWindowResizeGeometry.resizedFrame(
        from: startFrame,
        edge: .left,
        delta: NSPoint(x: 500, y: 0),
        minSize: minSize,
        maxSize: maxSize,
        visibleFrame: visible,
        symmetric: false
    )
    try require(
        narrowedLeft.width == 680 && narrowedLeft.maxX == startFrame.maxX,
        "left edge clamp drifted right edge: \(narrowedLeft)"
    )

    let widenedRight = QyvroWindowResizeGeometry.resizedFrame(
        from: startFrame,
        edge: .right,
        delta: NSPoint(x: 140, y: 0),
        minSize: minSize,
        maxSize: maxSize,
        visibleFrame: visible,
        symmetric: false
    )
    try require(
        widenedRight.width == 1_140 && widenedRight.minX == startFrame.minX,
        "right edge resize shifted origin: \(widenedRight)"
    )

    let clampedTop = QyvroWindowResizeGeometry.resizedFrame(
        from: startFrame,
        edge: .top,
        delta: NSPoint(x: 0, y: 600),
        minSize: minSize,
        maxSize: maxSize,
        visibleFrame: visible,
        symmetric: false
    )
    try require(
        clampedTop.maxY <= visible.maxY && clampedTop.minY == startFrame.minY,
        "top edge exceeded visible screen top: \(clampedTop)"
    )

    let symmetricResize = QyvroWindowResizeGeometry.resizedFrame(
        from: startFrame,
        edge: .right,
        delta: NSPoint(x: 50, y: 0),
        minSize: minSize,
        maxSize: maxSize,
        visibleFrame: visible,
        symmetric: true
    )
    try require(
        symmetricResize.width == 1_100 && symmetricResize.midX == startFrame.midX,
        "option symmetric resize did not preserve center: \(symmetricResize)"
    )

    let expandedRight = QyvroWindowResizeGeometry.expandedFrame(
        from: startFrame,
        edge: .right,
        maxSize: maxSize,
        visibleFrame: visible
    )
    try require(
        expandedRight.maxX == visible.maxX && expandedRight.minX == startFrame.minX,
        "double-click right edge did not expand to visible screen edge: \(expandedRight)"
    )

    // 3. Живое окно проводника: 5 и 10 вкладок не блокируют сужение, правый край
    //    не перекрыт скрытым previewSidebar, а боковая панель свободно тянется.
    let savedLayout = UserDefaults.standard.string(forKey: QyvroWorkspaceLayout.defaultsKey)
    UserDefaults.standard.set(QyvroWorkspaceLayout.classicSidebar.rawValue, forKey: QyvroWorkspaceLayout.defaultsKey)
    defer {
        if let savedLayout {
            UserDefaults.standard.set(savedLayout, forKey: QyvroWorkspaceLayout.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: QyvroWorkspaceLayout.defaultsKey)
        }
    }
    let home = FileManager.default.homeDirectoryForCurrentUser
    let session = FPWindowSession(
        panes: [
            FPPaneSession(
                tabPaths: Array(repeating: home.path, count: 5),
                activeIndex: 0
            )
        ],
        activePaneIndex: 0,
        paneFractions: [1.0],
        alwaysOnTop: false,
        frameX: 120,
        frameY: 110,
        frameWidth: 1_220,
        frameHeight: 760
    )
    let controller = ExplorerWindowController(startURL: home, session: session, quickLookHandler: { _ in })
    guard let window = controller.window, let contentView = window.contentView else {
        throw WindowResizeSmokeError.failed("ExplorerWindowController created no window")
    }

    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.35))
    window.layoutIfNeeded()

    // Добавляем ещё 5 вкладок (всего 10): окно не должно раздуваться.
    let widthBeforeTabs = window.frame.width
    for _ in 0..<5 {
        controller.workspace.newTab(nil)
    }
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
    window.layoutIfNeeded()
    try require(
        abs(window.frame.width - widthBeforeTabs) <= 1,
        "opening 10 tabs forced window width from \(widthBeforeTabs) to \(window.frame.width)"
    )

    // Сужаем окно до 680 pt с 10 открытыми вкладками.
    var narrowFrame = window.frame
    narrowFrame.size.width = 680
    window.setFrame(narrowFrame, display: false)
    window.layoutIfNeeded()
    try require(
        window.frame.width <= 685,
        "window with 10 tabs refused to narrow to 680 pt (got \(window.frame.width))"
    )

    // Проверяем, что накладка ловит клики внутри расширенных полей по обоим краям,
    // а центр окна пропускает насквозь.
    let w = contentView.bounds.width
    let h = contentView.bounds.height
    let leftHit = contentView.hitTest(NSPoint(x: 6, y: h / 2))
    let rightHit = contentView.hitTest(NSPoint(x: w - 6, y: h / 2))
    let bottomHit = contentView.hitTest(NSPoint(x: w / 2, y: 4))
    let centerHit = contentView.hitTest(NSPoint(x: w / 2, y: h / 2))
    try require(leftHit is QyvroWindowResizeOverlay, "left inner margin (x=6) did not hit resize overlay")
    try require(rightHit is QyvroWindowResizeOverlay, "right inner margin (x=w-6) did not hit resize overlay")
    try require(bottomHit is QyvroWindowResizeOverlay, "bottom inner margin (y=4) did not hit resize overlay")
    try require(!(centerHit is QyvroWindowResizeOverlay), "interior click was captured by resize overlay")

    // Проверяем, что при скрытом previewSidebar у rootSplitView ровно 2 панели (нет призрачного разделителя на правом краю).
    if !controller.workspace.isPreviewPanelVisible,
       let rootSplit = contentView.subviews.first(where: { $0 is NSSplitView }) as? NSSplitView {
        try require(
            rootSplit.arrangedSubviews.count == 2,
            "hidden previewSidebar stayed in rootSplitView (\(rootSplit.arrangedSubviews.count) subviews)"
        )
        // Проверяем, что боковая панель действительно меняет ширину (не заблокирована TagDropButton width==210).
        var wideFrame = window.frame
        wideFrame.size.width = 1_220
        window.setFrame(wideFrame, display: false)
        window.layoutIfNeeded()
        rootSplit.setPosition(340, ofDividerAt: 0)
        rootSplit.layoutSubtreeIfNeeded()
        let sidebarWidth = rootSplit.arrangedSubviews[0].frame.width
        try require(
            sidebarWidth >= 320,
            "sidebar width stayed stuck at \(sidebarWidth) instead of moving to 340"
        )
    }

    // 4. Проверяем, что одиночная вкладка при просторном окне сохраняет
    //    компактную ширину 134 pt (не схлопывается в пользу пустого спейсера).
    let singleTabController = ExplorerWindowController(startURL: home, session: nil, quickLookHandler: { _ in })
    if let singleWindow = singleTabController.window, let singleContent = singleWindow.contentView {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
        singleWindow.layoutIfNeeded()
        func findTabChip(in view: NSView) -> TabChip? {
            if let chip = view as? TabChip { return chip }
            for sub in view.subviews {
                if let found = findTabChip(in: sub) { return found }
            }
            return nil
        }
        if let chip = findTabChip(in: singleContent) {
            try require(
                chip.frame.width >= 130 && chip.frame.width <= 140,
                "single tab expected compact ~134 pt width, got \(chip.frame.width) pt"
            )
        }
    }

    print("Qyvro window resize smoke test: PASS")
} catch {
    fputs("Qyvro window resize smoke test: FAIL — \(error)\n", stderr)
    exit(1)
}
