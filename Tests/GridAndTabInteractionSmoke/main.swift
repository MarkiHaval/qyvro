import AppKit
import ImageIO
import UniformTypeIdentifiers

enum InteractionSmokeError: Error {
    case failed(String)
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw InteractionSmokeError.failed(message) }
}

func makeSyntheticPNG(at url: URL, width: Int, height: Int, r: CGFloat, g: CGFloat, b: CGFloat) throws {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw InteractionSmokeError.failed("Failed to create CGContext")
    }
    ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw InteractionSmokeError.failed("Failed to create PNG image destination")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw InteractionSmokeError.failed("Failed to finalize PNG at \(url.path)")
    }
}

func runGridBottomLeftHitTest() throws {
    let scrollView = FileGridScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 500))
    let canvas = FileGridCanvasView(frame: NSRect(x: 0, y: 0, width: 640, height: 500))
    scrollView.documentView = canvas

    // Non-flipped canvas: row 0 sits near top, row 1 (bottom-left + bottom-second) sits near y=16.
    let topCell = FileGridCellView()
    topCell.frame = NSRect(x: 16, y: 240, width: 170, height: 204)
    let bottomLeftCell = FileGridCellView()
    bottomLeftCell.frame = NSRect(x: 16, y: 16, width: 170, height: 204)
    let bottomSecondCell = FileGridCellView()
    bottomSecondCell.frame = NSRect(x: 196, y: 16, width: 170, height: 204)
    canvas.addSubview(topCell)
    canvas.addSubview(bottomLeftCell)
    canvas.addSubview(bottomSecondCell)

    let bottomLeftPoint = NSPoint(x: 50, y: 50)
    try require(
        bottomSecondCell.hitTest(bottomLeftPoint) == nil,
        "Last FileGridCellView swallowed bottom-left click in superview coordinates"
    )
    try require(
        bottomLeftCell.hitTest(bottomLeftPoint) == nil,
        "FileGridCellView should pass clicks through to FileGridScrollView"
    )
    try require(
        scrollView.hitTest(bottomLeftPoint) === scrollView,
        "FileGridScrollView did not receive hitTest for bottom-left tile"
    )
}

func runTabDragAndInPlaceSelectionTest() throws {
    let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("qyvro-tab-smoke-\(UUID().uuidString)", isDirectory: true)
    let dirA = tempRoot.appendingPathComponent("Alpha", isDirectory: true)
    let dirB = tempRoot.appendingPathComponent("Beta", isDirectory: true)
    let dirC = tempRoot.appendingPathComponent("Gamma", isDirectory: true)
    try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dirC, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let pane = BrowserPane(startURL: dirA)
    pane.addTab(url: dirB, activate: true)
    pane.addTab(url: dirC, activate: true)

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
        styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isMovableByWindowBackground = true
    window.contentView = pane
    pane.frame = window.contentView!.bounds
    window.layoutIfNeeded()
    pane.layoutSubtreeIfNeeded()

    func collectTabChips(in view: NSView) -> [TabChip] {
        var found: [TabChip] = []
        if let chip = view as? TabChip { found.append(chip) }
        for child in view.subviews { found.append(contentsOf: collectTabChips(in: child)) }
        return found
    }

    let beforeChips = collectTabChips(in: pane)
    try require(beforeChips.count == 3, "Expected 3 TabChips, found \(beforeChips.count)")
    let themeFrame = window.contentView!.superview!
    for chip in beforeChips {
        try require(!chip.mouseDownCanMoveWindow, "TabChip must not move window on mouseDown")
        try require(chip.acceptsFirstMouse(for: nil), "TabChip should accept first mouse click")
        // Clicking the center of a TabChip (over its title label) in a fullSizeContentView
        // titlebar must hit TabChip itself (mouseDownCanMoveWindow == false), NOT NSTextField!
        let centerInWindow = chip.convert(NSPoint(x: chip.bounds.midX, y: chip.bounds.midY), to: nil)
        let hitView = themeFrame.hitTest(centerInWindow)
        try require(
            hitView === chip,
            "Titlebar hitTest at center of TabChip returned \(String(describing: hitView)) instead of TabChip"
        )
        try require(
            hitView?.mouseDownCanMoveWindow == false,
            "Hit view inside TabChip still allows window move, which hijacks tab dragging"
        )
        // Clicking the trailing close button must still hit the NSButton, not TabChip.
        let closeInWindow = chip.convert(NSPoint(x: chip.bounds.maxX - 16, y: chip.bounds.midY), to: nil)
        let closeHit = themeFrame.hitTest(closeInWindow)
        try require(
            closeHit is NSButton,
            "Close button hitTest returned \(String(describing: closeHit)) instead of NSButton"
        )
    }
    try require(beforeChips[2].isActiveTab, "Newest tab (index 2) should start active")

    // Selecting tab 0 must update TabChip views in-place rather than destroying them mid-mouseDown.
    pane.selectTab(number: 1)
    let afterChips = collectTabChips(in: pane)
    try require(afterChips.count == 3, "Expected 3 TabChips after selection")
    try require(afterChips[0] === beforeChips[0], "TabChip 0 was destroyed during selectTab — tab dragging would break")
    try require(afterChips[1] === beforeChips[1], "TabChip 1 was destroyed during selectTab")
    try require(afterChips[2] === beforeChips[2], "TabChip 2 was destroyed during selectTab")
    try require(afterChips[0].isActiveTab && !afterChips[2].isActiveTab, "Active tab visual state did not update in-place")

    // REAL mouse drag of Tab #2 ("Beta") left onto Tab #1 ("Alpha") must swap
    // them into ["Beta", "Alpha", "Gamma"] via synthetic NSEvents queued for
    // TabChip.mouseDown's window.trackEvents loop.
    let dragChips = collectTabChips(in: pane)
    let firstChip = dragChips[0]
    let secondChip = dragChips[1]
    let startPt = secondChip.convert(NSPoint(x: secondChip.bounds.midX, y: secondChip.bounds.midY), to: nil)
    let endPt = firstChip.convert(NSPoint(x: firstChip.bounds.minX + 12, y: firstChip.bounds.midY), to: nil)
    let baseTime = ProcessInfo.processInfo.systemUptime
    for step in 1...8 {
        let t = CGFloat(step) / 8.0
        let pt = NSPoint(x: startPt.x + (endPt.x - startPt.x) * t, y: startPt.y)
        let dragEvent = NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: pt,
            modifierFlags: [],
            timestamp: baseTime + Double(step) * 0.01,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )!
        NSApp.postEvent(dragEvent, atStart: false)
    }
    let upEvent = NSEvent.mouseEvent(
        with: .leftMouseUp,
        location: endPt,
        modifierFlags: [],
        timestamp: baseTime + 0.1,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 1,
        clickCount: 1,
        pressure: 1
    )!
    NSApp.postEvent(upEvent, atStart: false)
    let downEvent = NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: startPt,
        modifierFlags: [],
        timestamp: baseTime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 1,
        clickCount: 1,
        pressure: 1
    )!
    secondChip.mouseDown(with: downEvent)

    let draggedSession = pane.sessionState
    try require(
        URL(fileURLWithPath: draggedSession.tabPaths[0]).lastPathComponent == "Beta"
            && URL(fileURLWithPath: draggedSession.tabPaths[1]).lastPathComponent == "Alpha"
            && URL(fileURLWithPath: draggedSession.tabPaths[2]).lastPathComponent == "Gamma",
        "Live NSEvent drag did not move Tab #2 (Beta) to index 0: \(draggedSession.tabPaths)"
    )

    // Pinning a tab moves it to index 0, renders compact icon-only pill, and
    // protects it from closeActiveTab when other tabs exist.
    pane.togglePinTab(at: 2) // Pin "Gamma" -> moves to index 0
    pane.layoutSubtreeIfNeeded()
    try require(pane.pinnedCount == 1, "Expected pinnedCount == 1 after togglePinTab")
    try require(
        URL(fileURLWithPath: pane.sessionState.tabPaths[0]).lastPathComponent == "Gamma",
        "Pinned tab should move to index 0: \(pane.sessionState.tabPaths)"
    )
    let pinnedChips = collectTabChips(in: pane)
    try require(pinnedChips[0].isPinned, "First TabChip should be marked isPinned")
    try require(
        pinnedChips[0].frame.width <= 42,
        "Pinned TabChip should be compact icon-only (got width \(pinnedChips[0].frame.width))"
    )
    pane.selectTab(number: 1) // Select pinned tab 0
    pane.closeActiveTab(nil)
    try require(
        pane.sessionState.tabPaths.count == 3,
        "closeActiveTab must not close a pinned tab while other tabs remain"
    )
    // Verify pinnedCount persists across BrowserPane(session:).
    let restoredPane = BrowserPane(session: pane.sessionState)
    try require(restoredPane.pinnedCount == 1, "Restored BrowserPane lost pinnedCount")

    // Unpin Gamma so subsequent close/reopen assertions test regular tabs.
    pane.togglePinTab(at: 0)
    try require(pane.pinnedCount == 0, "Unpinning should reset pinnedCount to 0")

    // Reordering tab 0 ("Gamma") to index 2 must move it to the end and keep it active.
    pane.selectTab(number: 1)
    pane.reorderTab(from: 0, to: 2)
    let session = pane.sessionState
    try require(session.tabPaths.count == 3, "Expected 3 tabs after reorder")
    try require(
        URL(fileURLWithPath: session.tabPaths[0]).lastPathComponent == "Beta"
            && URL(fileURLWithPath: session.tabPaths[1]).lastPathComponent == "Alpha"
            && URL(fileURLWithPath: session.tabPaths[2]).lastPathComponent == "Gamma",
        "Unexpected tab order after reorder: \(session.tabPaths)"
    )
    try require(session.activeIndex == 2, "Active index should follow moved tab to index 2, got \(session.activeIndex)")

    // Closing active tab ("Gamma") and calling reopenClosedTab must restore it.
    pane.closeActiveTab(nil)
    try require(pane.sessionState.tabPaths.count == 2, "Expected 2 tabs after closeActiveTab")
    try require(pane.canReopenClosedTab, "canReopenClosedTab should be true after closing a tab")
    pane.reopenClosedTab(nil)
    try require(
        pane.sessionState.tabPaths.count == 3
            && URL(fileURLWithPath: pane.sessionState.tabPaths[2]).lastPathComponent == "Gamma",
        "reopenClosedTab did not restore closed Gamma tab"
    )
}

func runViewModeAndSplitRestoreTests() throws {
    let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("qyvro-view-split-smoke-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    // Regression test for blank "Список 0%" view: applyViewScale(0, reload: false)
    // crossing from grid -> list MUST unhide tableScrollView and hide gridScrollView.
    let panel = FilePanel(startURL: tempRoot)
    panel.applyViewScale(100, reload: true)
    try require(panel.viewMode == .largeIcons && !panel.gridScrollView.isHidden && panel.tableScrollView.isHidden,
                "Expected grid mode visible at scale 100")
    panel.applyViewScale(0, reload: false)
    try require(
        panel.viewMode == .list && !panel.tableScrollView.isHidden && panel.gridScrollView.isHidden,
        "Crossing to Список 0% with reload:false left tableScrollView hidden (blank view regression)"
    )
    // Verify clean list table header and no ugly bottom horizontal scrollbar.
    try require(
        panel.tableView.headerView is QyvroTableHeaderView,
        "List tableView should use custom borderless QyvroTableHeaderView"
    )
    try require(
        !panel.tableScrollView.hasHorizontalScroller,
        "List tableScrollView must disable horizontal scrollbar"
    )
    try require(
        panel.tableView.columnAutoresizingStyle == .firstColumnOnlyAutoresizingStyle,
        "List tableView should flex name column so columns never overflow horizontally"
    )

    // Verify switching between all 3 workspace layouts and V3 <-> V2 themes works cleanly.
    let prevLayout = UserDefaults.standard.string(forKey: QyvroWorkspaceLayout.defaultsKey)
    let prevVariant = UserDefaults.standard.string(forKey: "ThemeStyleVariant")
    defer {
        if let prevLayout { UserDefaults.standard.set(prevLayout, forKey: QyvroWorkspaceLayout.defaultsKey) }
        else { UserDefaults.standard.removeObject(forKey: QyvroWorkspaceLayout.defaultsKey) }
        if let prevVariant { UserDefaults.standard.set(prevVariant, forKey: "ThemeStyleVariant") }
        else { UserDefaults.standard.removeObject(forKey: "ThemeStyleVariant") }
        FPStyle.invalidateCache()
    }
    let controller = ExplorerWindowController(startURL: tempRoot, session: nil, quickLookHandler: { _ in })
    guard let win = controller.window else {
        throw InteractionSmokeError.failed("ExplorerWindowController has no window")
    }
    for layout in QyvroWorkspaceLayout.allCases {
        QyvroWorkspaceLayout.setCurrent(layout)
        win.layoutIfNeeded()
    }
    if let v3Preset = FPThemePreset.all.first(where: { $0.styleVariant == .obsidianAurora }),
       let v2Preset = FPThemePreset.all.first(where: { $0.styleVariant == .cyberEditorial }) {
        FPStyle.applyBuiltInPreset(v3Preset)
        try require(FPStyle.isObsidianAurora, "Applying V3 Aurora preset did not activate obsidianAurora")
        FPStyle.applyBuiltInPreset(v2Preset)
        try require(FPStyle.isCyberEditorial, "Switching back to preserved V2 preset did not activate cyberEditorial")
    }

    // Split pane window restore: splitting and closing back to 1 pane must restore
    // the exact pre-split window frame width instead of shrinking the window small.
    let initialFrame = NSRect(x: 140, y: 120, width: 1080, height: 700)
    win.setFrame(initialFrame, display: false)
    win.layoutIfNeeded()
    controller.workspace.splitPane(nil)
    try require(controller.workspace.paneCount == 2, "Expected 2 panes after splitPane")
    controller.workspace.closeTab(nil)
    try require(controller.workspace.paneCount == 1, "Expected 1 pane after closing split pane")
    try require(
        abs(win.frame.width - initialFrame.width) < 1 && abs(win.frame.height - initialFrame.height) < 1,
        "Window did not restore pre-split frame \(initialFrame), got \(win.frame)"
    )
}

func runDropShelfAndDiskScannerTests() throws {
    let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("qyvro-shelf-disk-smoke-\(UUID().uuidString)", isDirectory: true)
    let heavyDir = tempRoot.appendingPathComponent("HeavyFolder", isDirectory: true)
    let hiddenCache = tempRoot.appendingPathComponent(".cache_test", isDirectory: true)
    try FileManager.default.createDirectory(at: heavyDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: hiddenCache, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let fileBig = heavyDir.appendingPathComponent("big.bin")
    let fileMedium = hiddenCache.appendingPathComponent("mid.bin")
    let fileSmall = tempRoot.appendingPathComponent("small.txt")
    try Data(repeating: 0xAB, count: 65_536).write(to: fileBig)
    try Data(repeating: 0xCD, count: 16_384).write(to: fileMedium)
    try Data("hello".utf8).write(to: fileSmall)

    // Drop Shelf store tests
    let store = QyvroDropShelfStore()
    try require(store.add(urls: [fileBig, fileSmall, fileBig]) == 2, "DropShelfStore should deduplicate identical URLs")
    try require(store.count == 2, "Expected 2 items on DropShelfStore")
    try require(store.totalKnownFileBytes == 65_536 + 5, "Unexpected DropShelfStore byte sum: \(store.totalKnownFileBytes)")
    store.remove(url: fileBig)
    try require(store.count == 1, "Expected 1 item after remove")
    store.clear()
    try require(store.isEmpty, "DropShelfStore should be empty after clear")

    // Disk Scanner tests
    let semaphore = DispatchSemaphore(value: 0)
    var scannedEntries: [QyvroDiskEntry] = []
    var scannedTotal: Int64 = 0
    QyvroDiskScanner.scan(rootURL: tempRoot) { entries, total in
        scannedEntries = entries
        scannedTotal = total
        semaphore.signal()
    }
    let deadline = Date().addingTimeInterval(5)
    while semaphore.wait(timeout: .now() + 0.02) == .timedOut && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    try require(scannedEntries.count == 3, "Expected 3 scanned entries, got \(scannedEntries.count)")
    try require(scannedEntries[0].name == "HeavyFolder", "Heaviest folder should sort first, got \(scannedEntries[0].name)")
    try require(scannedEntries[1].name == ".cache_test" && scannedEntries[1].isHidden, "Hidden cache folder should be included and flagged hidden")
    try require(scannedTotal >= 65_536 + 16_384, "Scanned total bytes too small: \(scannedTotal)")
}

func runDiskUsageMathTests() throws {
    // Reproduces screenshot values (13.9 GB, 9.56 GB, 432.74 GB, 38.18 GB on 494.38 GB):
    // naive rounding previously summed to 101%. Hamilton rounding must always sum to 100%.
    let percents = FPDiskUsage.roundedPercentages(
        for: [13_900, 9_560, 432_740, 38_180],
        total: 494_380
    )
    try require(
        percents.reduce(0, +) == 100,
        "Disk percentages summed to \(percents.reduce(0, +)) instead of 100: \(percents)"
    )

    var snap = FPDiskUsage.Snapshot()
    snap.total = 500_000
    snap.free = 50_000
    snap.images = 15_000
    snap.videos = 10_000
    snap.apps = 75_000
    snap.docsAndAudio = 25_000
    let occupied = FPDiskUsagePalette.occupiedSegments(for: snap)
    let shares = FPDiskUsagePalette.visualShares(
        for: occupied,
        total: snap.total,
        usedShare: CGFloat(snap.usedFraction),
        minVisualShare: 0.025
    )
    let shareSum = shares.reduce(0, +)
    try require(
        abs(shareSum - CGFloat(snap.usedFraction)) < 0.001,
        "Visual occupied shares (\(shareSum)) did not preserve exact usedFraction (\(snap.usedFraction))"
    )
}

func runStyleCacheAndPreviewDecodeTests() throws {
    let key = "ThemeAccentColor"
    let previous = UserDefaults.standard.data(forKey: key)
    defer {
        if let previous {
            UserDefaults.standard.set(previous, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        FPStyle.invalidateCache()
    }

    let firstColor = NSColor(calibratedRed: 0.12, green: 0.88, blue: 0.44, alpha: 1)
    FPStyle.saveColor(firstColor, key: key)
    let read1 = FPStyle.accent.usingColorSpace(.genericRGB)
    let read2 = FPStyle.accent.usingColorSpace(.genericRGB)
    try require(
        abs((read1?.greenComponent ?? 0) - 0.88) < 0.02
            && abs((read2?.greenComponent ?? 0) - 0.88) < 0.02,
        "FPStyle cached accent did not match saved color (got \(String(describing: read1)))"
    )

    let secondColor = NSColor(calibratedRed: 0.91, green: 0.21, blue: 0.65, alpha: 1)
    FPStyle.saveColor(secondColor, key: key)
    let read3 = FPStyle.accent.usingColorSpace(.genericRGB)
    try require(
        abs((read3?.redComponent ?? 0) - 0.91) < 0.02,
        "FPStyle cache did not invalidate when saving a new color (got \(String(describing: read3)))"
    )

    let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("qyvro-media-smoke-\(UUID().uuidString)", isDirectory: true)
    let dirA = tempRoot.appendingPathComponent("FolderA", isDirectory: true)
    let dirB = tempRoot.appendingPathComponent("FolderB", isDirectory: true)
    try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let imgA = dirA.appendingPathComponent("shot.png")
    let imgB = dirB.appendingPathComponent("shot.png")
    try makeSyntheticPNG(at: imgA, width: 640, height: 360, r: 0.9, g: 0.2, b: 0.1)
    try makeSyntheticPNG(at: imgB, width: 320, height: 320, r: 0.1, g: 0.4, b: 0.9)

    try require(QyvroPreviewImageCache.isDirectImage(imgA), "PNG should use direct image preview path")
    try require(
        QyvroPreviewImageCache.isDirectImage(URL(fileURLWithPath: "/tmp/render.avif")),
        "AVIF should use direct image preview path"
    )
    try require(
        !QyvroPreviewImageCache.isDirectImage(URL(fileURLWithPath: "/tmp/doc.pdf")),
        "PDF should remain on Quick Look preview path"
    )

    guard let decoded = QyvroPreviewImageCache.decodeImage(url: imgA, maxPixelSize: 320) else {
        throw InteractionSmokeError.failed("Direct preview decode returned nil for synthetic PNG")
    }
    try require(
        Int(decoded.size.width.rounded()) == 320 && Int(decoded.size.height.rounded()) == 180,
        "Unexpected decoded size \(decoded.size)"
    )

    let prepared = FPUploadPrep.prepare([imgA, imgB])
    try require(prepared.count == 2, "Expected 2 prepared upload URLs")
    try require(
        prepared[0].path != prepared[1].path,
        "FPUploadPrep collided identical filenames from different folders: \(prepared[0].path)"
    )
    try require(
        prepared[0].lastPathComponent == "shot.jpg" && prepared[1].lastPathComponent == "shot.jpg",
        "FPUploadPrep should preserve clean filename shot.jpg"
    )
    for url in prepared {
        try? FileManager.default.removeItem(at: url)
    }
}

do {
    let _ = NSApplication.shared
    try runGridBottomLeftHitTest()
    try runTabDragAndInPlaceSelectionTest()
    try runViewModeAndSplitRestoreTests()
    try runDropShelfAndDiskScannerTests()
    try runDiskUsageMathTests()
    try runStyleCacheAndPreviewDecodeTests()
    print("Qyvro grid, tab-drag, pinned-tabs, view-scale, split-restore, drop-shelf, disk-analyzer & preview smoke test: PASS")
} catch {
    fputs("Qyvro grid, tab-drag, disk, style-cache & preview smoke test: FAIL — \(error)\n", stderr)
    exit(1)
}
