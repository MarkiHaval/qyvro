import Cocoa

enum QuickLookGeometrySmokeError: Error {
    case failed(String)
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw QuickLookGeometrySmokeError.failed(message) }
}

do {
    let visibleFrame = NSRect(x: 0, y: 0, width: 1_440, height: 900)
    let intrinsic = NSSize(width: 1_024, height: 768)
    let first = FPQuickLookPanelSizing.contentSize(
        for: intrinsic,
        visibleFrame: visibleFrame
    )
    let same = FPQuickLookPanelSizing.contentSize(
        for: intrinsic,
        visibleFrame: visibleFrame
    )
    let near = NSSize(width: first.width + 8, height: first.height - 7)

    try require(first == same, "equal-resolution images produced different panel sizes")
    try require(
        FPQuickLookPanelSizing.isEquivalent(first, same),
        "equal panel sizes triggered another resize"
    )
    try require(
        FPQuickLookPanelSizing.isEquivalent(first, near),
        "minor metadata rounding triggered another resize"
    )

    let smallLandscape = FPQuickLookPanelSizing.contentSize(
        for: NSSize(width: 320, height: 180),
        visibleFrame: visibleFrame
    )
    let largeLandscape = FPQuickLookPanelSizing.contentSize(
        for: NSSize(width: 3_840, height: 2_160),
        visibleFrame: visibleFrame
    )
    try require(
        FPQuickLookPanelSizing.isEquivalent(
            smallLandscape,
            largeLandscape,
            tolerance: 1
        ),
        "small images were not enlarged to the same fitted preview geometry"
    )
    try require(
        smallLandscape.width >= visibleFrame.width * 0.80,
        "landscape preview did not use the available screen width"
    )

    let anchor = NSPoint(x: 720, y: 450)
    let frameA = FPQuickLookPanelSizing.anchoredFrame(
        frameSize: NSSize(width: 920, height: 680),
        center: anchor,
        visibleFrame: visibleFrame
    )
    let frameB = FPQuickLookPanelSizing.anchoredFrame(
        frameSize: NSSize(width: 920, height: 680),
        center: anchor,
        visibleFrame: visibleFrame
    )
    try require(frameA == frameB, "stable session anchor produced a drifting window")

    try require(
        !FPQuickLookPresentationState.windowed.suppressesAutomaticResize,
        "windowed Quick Look stopped adapting to the current image"
    )
    for state in [
        FPQuickLookPresentationState.enteringFullScreen,
        .fullScreen,
        .exitingFullScreen
    ] {
        try require(
            state.suppressesAutomaticResize,
            "full-screen transition allowed panel geometry to jump"
        )
        try require(
            state.isFullScreenOrTransitioning,
            "full-screen escape handling lost its presentation state"
        )
    }

    print("Qyvro Quick Look geometry smoke test: PASS")
} catch {
    fputs("Qyvro Quick Look geometry smoke test: FAIL — \(error)\n", stderr)
    exit(1)
}
