import AppKit

extension Notification.Name {
    static let fpCutFileStateDidChange = Notification.Name("FPCutFileStateDidChange")
}

/// Visual state for files prepared with ⌘X. The actual move contract remains
/// on NSPasteboard; this object only keeps every open tab visually in sync.
final class FPCutFileState {
    static let shared = FPCutFileState()

    private var paths = Set<String>()
    private var pasteboardChangeCount = -1

    private init() {}

    func set(urls: [URL], pasteboard: NSPasteboard) {
        paths = Set(urls.map { $0.standardizedFileURL.path })
        pasteboardChangeCount = pasteboard.changeCount
        notify()
    }

    func clear() {
        guard !paths.isEmpty else { return }
        paths.removeAll()
        pasteboardChangeCount = -1
        notify()
    }

    func contains(_ url: URL) -> Bool {
        guard pasteboardChangeCount == NSPasteboard.general.changeCount else { return false }
        return paths.contains(url.standardizedFileURL.path)
    }

    private func notify() {
        NotificationCenter.default.post(name: .fpCutFileStateDidChange, object: self)
    }
}
