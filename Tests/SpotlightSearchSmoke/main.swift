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
            NSMetadataItemFSNameKey: "заметки.txt",
            NSMetadataItemDisplayNameKey: "Заметки",
            NSMetadataItemTextContentKey: "Внутри документа упоминается маяк."
        ]),
        "Spotlight predicate did not match indexed file contents"
    )
    try require(
        predicate.evaluate(with: [
            NSMetadataItemFSNameKey: "маяк.png",
            NSMetadataItemDisplayNameKey: "маяк.png",
            NSMetadataItemTextContentKey: ""
        ]),
        "Spotlight predicate stopped matching file names"
    )
    try require(
        !predicate.evaluate(with: [
            NSMetadataItemFSNameKey: "остров.png",
            NSMetadataItemDisplayNameKey: "Остров",
            NSMetadataItemTextContentKey: "Море и скалы."
        ]),
        "Spotlight predicate matched unrelated metadata"
    )

    print("Qyvro Spotlight content-search smoke test: PASS")
} catch {
    fputs("Qyvro Spotlight content-search smoke test: FAIL — \(error)\n", stderr)
    exit(1)
}
