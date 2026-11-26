import Cocoa

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("Qyvro Finder tag smoke test failed: \(message)\n", stderr)
        exit(1)
    }
}

do {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("QyvroFinderTagSmoke-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let file = root.appendingPathComponent("tagged.txt")
    try Data("Qyvro".utf8).write(to: file)
    let external = FPFinderTag(title: "Проект", colorNumber: 4)
    try FPFinderTagStore.write([external], to: file)

    guard let orange = FPTag.all.first(where: { $0.key == "orange" }) else {
        throw NSError(domain: "QyvroTests", code: 1)
    }
    try FPFinderTagStore.setQyvroTag(orange, on: file)
    let applied = FPFinderTagStore.tags(for: file)
    require(applied.contains(external), "existing Finder tag was overwritten")
    require(
        applied.contains(FPFinderTag(title: orange.title, colorNumber: 7)),
        "Qyvro tag was not written as a native Finder tag"
    )

    try FPFinderTagStore.setQyvroTag(nil, on: file)
    let removed = FPFinderTagStore.tags(for: file)
    require(removed == [external], "removing Qyvro tag removed or changed an external Finder tag")
    print("Qyvro Finder tag smoke test: PASS")
} catch {
    fputs("Qyvro Finder tag smoke test failed: \(error)\n", stderr)
    exit(1)
}
