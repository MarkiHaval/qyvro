import Cocoa

enum GridGeometrySmokeError: Error {
    case failed(String)
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw GridGeometrySmokeError.failed(message) }
}

func nearlyEqual(_ lhs: NSRect, _ rhs: NSRect, tolerance: CGFloat = 0.01) -> Bool {
    abs(lhs.origin.x - rhs.origin.x) <= tolerance
        && abs(lhs.origin.y - rhs.origin.y) <= tolerance
        && abs(lhs.size.width - rhs.size.width) <= tolerance
        && abs(lhs.size.height - rhs.size.height) <= tolerance
}

func image(size: NSSize, color: NSColor) -> NSImage {
    let result = NSImage(size: size)
    result.lockFocus()
    color.setFill()
    NSRect(origin: .zero, size: size).fill()
    result.unlockFocus()
    return result
}

do {
    _ = NSApplication.shared
    let cell = FileGridCellView()
    cell.frame = NSRect(x: 0, y: 0, width: 180, height: 204)
    let item = FileItem(
        url: URL(fileURLWithPath: "/tmp/qyvro-grid-geometry.png"),
        name: "qyvro-grid-geometry.png",
        isDirectory: false,
        size: 1,
        created: nil,
        modified: nil,
        kind: "Изображение PNG",
        isHidden: false,
        finderTags: nil
    )

    let placeholder = image(size: NSSize(width: 144, height: 144), color: .gray)
    cell.configure(
        item: item,
        image: placeholder,
        imageSize: 144,
        selected: false,
        cut: false
    )
    cell.layoutSubtreeIfNeeded()
    guard let preview = cell.subviews.compactMap({ $0 as? NSImageView }).first,
          let title = cell.subviews.compactMap({ $0 as? NSTextField }).first(where: {
              $0.stringValue == item.name
          }) else {
        throw GridGeometrySmokeError.failed("grid cell did not create preview/title views")
    }
    let initialPreviewFrame = preview.frame
    let initialTitleFrame = title.frame

    for replacement in [
        image(size: NSSize(width: 1_200, height: 240), color: .orange),
        image(size: NSSize(width: 240, height: 1_200), color: .blue)
    ] {
        cell.configure(
            item: item,
            image: replacement,
            imageSize: 144,
            selected: false,
            cut: false
        )
        cell.layoutSubtreeIfNeeded()
        try require(
            nearlyEqual(preview.frame, initialPreviewFrame),
            "thumbnail aspect ratio changed the reserved preview slot"
        )
        try require(
            nearlyEqual(title.frame, initialTitleFrame),
            "thumbnail aspect ratio moved the file title"
        )
    }

    print("Qyvro stable grid geometry smoke test: PASS")
} catch {
    fputs("Qyvro stable grid geometry smoke test: FAIL — \(error)\n", stderr)
    exit(1)
}
