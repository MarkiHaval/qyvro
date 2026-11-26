import Foundation

enum SpotlightSearchSmokeError: Error {
    case failed(String)
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw SpotlightSearchSmokeError.failed(message) }
}

do {
    let predicate = FPSpotlightSearch.predicate(for: "маяк")
    try require(
        predicate.evaluate(with: [
            NSMetadataItemFSNameKey: "маяк.png",
            NSMetadataItemDisplayNameKey: "маяк.png"
        ]),
        "Spotlight predicate did not match file name"
    )
    try require(
        predicate.evaluate(with: [
            NSMetadataItemFSNameKey: "photo_01.png",
            NSMetadataItemDisplayNameKey: "Старый Маяк на закате"
        ]),
        "Spotlight predicate did not match display name case-insensitively"
    )
    try require(
        !predicate.evaluate(with: [
            NSMetadataItemFSNameKey: "заметки.txt",
            NSMetadataItemDisplayNameKey: "Заметки",
            NSMetadataItemTextContentKey: "Внутри документа упоминается маяк."
        ]),
        "Spotlight predicate unexpectedly matched slow text content"
    )
    try require(
        !predicate.evaluate(with: [
            NSMetadataItemFSNameKey: "остров.png",
            NSMetadataItemDisplayNameKey: "Остров"
        ]),
        "Spotlight predicate matched unrelated metadata"
    )
    try require(
        FPSpotlightSearch.isMeaningful(URL(fileURLWithPath: "/Users/test/Documents/маяк.png")),
        "Meaningful document was incorrectly filtered out"
    )
    try require(
        !FPSpotlightSearch.isMeaningful(URL(fileURLWithPath: "/Users/test/Library/Caches/маяк.png")),
        "Cache file should be filtered out"
    )
    try require(
        !FPSpotlightSearch.isMeaningful(URL(fileURLWithPath: "/Applications/Qyvro.app/Contents/Info.plist")),
        "App bundle internals should be filtered out"
    )

    print("Qyvro Spotlight search smoke test: PASS")
} catch {
    fputs("Qyvro Spotlight search smoke test: FAIL — \(error)\n", stderr)
    exit(1)
}
