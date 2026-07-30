import AppKit
import Carbon.HIToolbox

enum ClipboardShortcutSmokeError: Error {
    case failed(String)
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw ClipboardShortcutSmokeError.failed(message) }
}

do {
    try require(
        QyvroClipboardShortcut.keyCode == UInt32(kVK_ANSI_V),
        "clipboard shortcut stopped using the V key"
    )
    try require(
        QyvroClipboardShortcut.carbonModifiers == UInt32(cmdKey | shiftKey),
        "global clipboard shortcut is not Shift-Command-V"
    )
    try require(
        QyvroClipboardShortcut.carbonModifiers & UInt32(controlKey) == 0,
        "legacy Control-Command-V modifier is still registered"
    )
    try require(
        QyvroClipboardShortcut.cocoaModifiers == [.command, .shift],
        "menu shortcut does not match the global shortcut"
    )
    try require(
        QyvroClipboardShortcut.displayName == "⇧⌘V",
        "visible shortcut hint is stale"
    )
    print("Qyvro clipboard shortcut smoke test: PASS")
} catch {
    fputs("Qyvro clipboard shortcut smoke test: FAIL — \(error)\n", stderr)
    exit(1)
}
