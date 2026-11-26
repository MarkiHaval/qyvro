import AppKit
import Foundation

enum SmokeFailure: Error {
    case assertion(String)
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw SmokeFailure.assertion(message) }
}

do {
    let source = [
        FPSavedTabGroup(
            id: UUID(),
            name: "Монтаж",
            paths: ["/Users/test/Footage", "/Volumes/Project/Renders"],
            activeIndex: 1,
            updatedAt: Date(timeIntervalSince1970: 1_785_200_000)
        )
    ]
    let data = try JSONEncoder().encode(source)
    let decoded = try JSONDecoder().decode([FPSavedTabGroup].self, from: data)
    try require(decoded == source, "saved group changed after persistence round-trip")
    try require(decoded[0].paths.count == 2, "saved group lost a tab path")
    try require(decoded[0].activeIndex == 1, "saved group lost its active tab")
    print("Qyvro saved-tab-groups smoke test: PASS")
} catch {
    fputs("Qyvro saved-tab-groups smoke test: FAIL — \(error)\n", stderr)
    exit(1)
}
