import Foundation

enum QuickLookSessionCacheSmokeError: Error {
    case failed(String)
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw QuickLookSessionCacheSmokeError.failed(message) }
}

do {
    let cache = FPQuickLookSessionCache<Int>()
    let paths = (0..<10).map { "/tmp/qyvro-preview-\($0).png" }

    for (index, path) in paths.enumerated() {
        cache[path] = index
    }
    try require(cache.count == 10, "the session cache evicted previously viewed images")
    for (index, path) in paths.enumerated() {
        try require(cache[path] == index, "the session cache lost image \(index)")
    }

    cache.removeAll()
    try require(cache.count == 0, "closing the preview did not clear the session cache")
    try require(paths.allSatisfy { cache[$0] == nil }, "a cached image survived session close")

    print("Qyvro Quick Look session-cache smoke test: PASS")
} catch {
    fputs("Qyvro Quick Look session-cache smoke test: FAIL — \(error)\n", stderr)
    exit(1)
}
