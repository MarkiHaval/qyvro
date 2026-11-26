import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ClipboardPasteSmokeError: Error {
    case failed(String)
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw ClipboardPasteSmokeError.failed(message) }
}

func makeLargePNGData(width: Int, height: Int) throws -> Data {
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
        throw ClipboardPasteSmokeError.failed("Failed to create CGContext")
    }
    ctx.setFillColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let cgImage = ctx.makeImage() else {
        throw ClipboardPasteSmokeError.failed("Failed to create CGImage")
    }
    let buffer = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil) else {
        throw ClipboardPasteSmokeError.failed("Failed to create PNG destination")
    }
    CGImageDestinationAddImage(dest, cgImage, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw ClipboardPasteSmokeError.failed("Failed to finalize PNG data")
    }
    return buffer as Data
}

do {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("qyvro-clipboard-smoke-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let store = QyvroClipboardStore(rootDirectory: tempDir)
    let pb = NSPasteboard.withUniqueName()
    defer { pb.releaseGlobally() }

    for value in ["Первая запись", "Вторая запись", "Третья запись"] {
        pb.clearContents()
        pb.setString(value, forType: .string)
        store.addPasteboard(pb)
    }

    try require(store.records.count == 3, "Expected 3 clipboard records, got \(store.records.count)")
    try require(
        store.records.map(\.title) == ["Третья запись", "Вторая запись", "Первая запись"],
        "Unexpected initial record order: \(store.records.map(\.title))"
    )

    // Windows Win+V behavior: pasting an older item puts it on the pasteboard,
    // marks it as an own change, and MUST NOT duplicate it or jump it to #1.
    let oldest = store.records[2]
    let wrote = store.writeToPasteboard(oldest, pasteboard: pb)
    try require(wrote, "writeToPasteboard returned false")
    try require(
        pb.string(forType: .string) == "Первая запись",
        "Pasteboard did not receive selected clipboard entry text"
    )
    try require(
        store.isOwnChange(pb.changeCount),
        "writeToPasteboard did not mark resulting pasteboard changeCount as own change"
    )

    // Simulate clipboard watcher polling right after our paste write.
    store.addPasteboard(pb)
    try require(
        store.records.count == 3,
        "Pasting from history duplicated the entry (count=\(store.records.count))"
    )
    try require(
        store.records.map(\.title) == ["Третья запись", "Вторая запись", "Первая запись"],
        "Pasting from history jumped entry to the top: \(store.records.map(\.title))"
    )

    // A genuine new copy afterwards must still be recorded normally at index 0.
    pb.clearContents()
    pb.setString("Новая четвёртая", forType: .string)
    store.addPasteboard(pb)
    try require(
        store.records.count == 4 && store.records[0].title == "Новая четвёртая",
        "Genuine user copy after own paste was not recorded"
    )

    // Preview thumbnail for large images must be downscaled to <= 180px instead of duplicating full-res.
    let bigPNG = try makeLargePNGData(width: 1200, height: 800)
    store.addScreenshot(data: bigPNG)
    try require(store.records.count == 5, "Screenshot was not added")
    let shotRecord = store.records[0]
    guard let previewFile = shotRecord.previewFile else {
        throw ClipboardPasteSmokeError.failed("Screenshot record missing previewFile")
    }
    let previewURL = tempDir.appendingPathComponent("payloads").appendingPathComponent(previewFile)
    guard let dims = FPMediaInfoCache.imageDimensions(at: previewURL) else {
        throw ClipboardPasteSmokeError.failed("Could not read saved preview dimensions")
    }
    try require(
        max(dims.width, dims.height) <= 180,
        "Preview PNG was not downscaled (got \(dims.width)x\(dims.height))"
    )

    print("Qyvro Windows-style clipboard paste smoke test: PASS")
} catch {
    fputs("Qyvro Windows-style clipboard paste smoke test: FAIL — \(error)\n", stderr)
    exit(1)
}
