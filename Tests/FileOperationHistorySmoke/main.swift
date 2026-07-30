import AppKit
import Foundation

enum SmokeFailure: Error {
    case assertion(String)
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw SmokeFailure.assertion(message) }
}

func waitForHistory(
    _ operation: (@escaping (Result<[URL], Error>) -> Void) -> Void
) throws {
    var output: Result<[URL], Error>?
    operation { output = $0 }
    while output == nil {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    _ = try output!.get()
}

let manager = QyvroFileOperationHistory.shared
let fileManager = FileManager.default
let root = fileManager.temporaryDirectory.appendingPathComponent("QyvroHistorySmoke-\(UUID().uuidString)", isDirectory: true)
let left = root.appendingPathComponent("left", isDirectory: true)
let right = root.appendingPathComponent("right", isDirectory: true)
try fileManager.createDirectory(at: left, withIntermediateDirectories: true)
try fileManager.createDirectory(at: right, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: root) }

do {
    // Move: undo returns the only copy to its source; redo moves it back.
    let moveSource = left.appendingPathComponent("move.txt")
    let moveDestination = right.appendingPathComponent("move.txt")
    try Data("move".utf8).write(to: moveSource)
    try fileManager.moveItem(at: moveSource, to: moveDestination)
    manager.recordTransfer([
        .init(source: moveSource, destination: moveDestination, move: true, replacedItemTrashURL: nil)
    ])
    try waitForHistory(manager.performUndo)
    try require(fileManager.fileExists(atPath: moveSource.path), "move undo did not restore source")
    try require(!fileManager.fileExists(atPath: moveDestination.path), "move undo left destination")
    try waitForHistory(manager.performRedo)
    try require(fileManager.fileExists(atPath: moveDestination.path), "move redo did not restore destination")

    // Copy: undo sends only the created copy to Trash; redo restores that exact copy.
    let copySource = left.appendingPathComponent("copy.txt")
    let copyDestination = right.appendingPathComponent("copy.txt")
    try Data("copy".utf8).write(to: copySource)
    try fileManager.copyItem(at: copySource, to: copyDestination)
    manager.recordTransfer([
        .init(source: copySource, destination: copyDestination, move: false, replacedItemTrashURL: nil)
    ])
    try waitForHistory(manager.performUndo)
    try require(fileManager.fileExists(atPath: copySource.path), "copy undo removed source")
    try require(!fileManager.fileExists(atPath: copyDestination.path), "copy undo left destination")
    try waitForHistory(manager.performRedo)
    try require(fileManager.fileExists(atPath: copyDestination.path), "copy redo did not restore destination")

    // Replacement: the displaced object must be restored on undo and preserved again on redo.
    let replacementSource = left.appendingPathComponent("replacement.txt")
    let replacementDestination = right.appendingPathComponent("replacement.txt")
    try Data("new".utf8).write(to: replacementSource)
    try Data("old".utf8).write(to: replacementDestination)
    var displacedTrash: NSURL?
    try fileManager.trashItem(at: replacementDestination, resultingItemURL: &displacedTrash)
    try fileManager.moveItem(at: replacementSource, to: replacementDestination)
    manager.recordTransfer([
        .init(
            source: replacementSource,
            destination: replacementDestination,
            move: true,
            replacedItemTrashURL: displacedTrash as URL?
        )
    ])
    try waitForHistory(manager.performUndo)
    let restoredOldData = try Data(contentsOf: replacementDestination)
    let restoredNewData = try Data(contentsOf: replacementSource)
    try require(String(data: restoredOldData, encoding: .utf8) == "old", "replacement undo lost old object")
    try require(String(data: restoredNewData, encoding: .utf8) == "new", "replacement undo lost moved object")
    try waitForHistory(manager.performRedo)
    let redoneNewData = try Data(contentsOf: replacementDestination)
    try require(String(data: redoneNewData, encoding: .utf8) == "new", "replacement redo lost new object")
    try waitForHistory(manager.performUndo)

    // Rename and Trash are reversible too.
    let renameOriginal = left.appendingPathComponent("before.txt")
    let renameDestination = left.appendingPathComponent("after.txt")
    try Data("rename".utf8).write(to: renameOriginal)
    try fileManager.moveItem(at: renameOriginal, to: renameDestination)
    manager.recordRename([(renameOriginal, renameDestination)])
    try waitForHistory(manager.performUndo)
    try require(fileManager.fileExists(atPath: renameOriginal.path), "rename undo failed")
    try waitForHistory(manager.performRedo)
    try require(fileManager.fileExists(atPath: renameDestination.path), "rename redo failed")

    let trashOriginal = left.appendingPathComponent("trash.txt")
    try Data("trash".utf8).write(to: trashOriginal)
    var trashResult: NSURL?
    try fileManager.trashItem(at: trashOriginal, resultingItemURL: &trashResult)
    manager.recordTrash([.init(original: trashOriginal, trashURL: trashResult! as URL)])
    try waitForHistory(manager.performUndo)
    try require(fileManager.fileExists(atPath: trashOriginal.path), "trash undo failed")
    try waitForHistory(manager.performRedo)
    try require(!fileManager.fileExists(atPath: trashOriginal.path), "trash redo failed")
    try waitForHistory(manager.performUndo)

    print("Qyvro file-operation history smoke test: PASS")
} catch {
    fputs("Qyvro file-operation history smoke test: FAIL — \(error.localizedDescription)\n", stderr)
    exit(1)
}
