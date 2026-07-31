import Cocoa

/// Session-scoped storage for decoded Quick Look representations.
///
/// There is intentionally no eviction policy here: every file the user has
/// actually visited remains available for the lifetime of the open preview.
/// AppDelegate destroys the whole cache when the panel closes, so a long-lived
/// application process does not retain those images afterwards.
final class FPQuickLookSessionCache<Value> {
    private var storage: [String: Value] = [:]

    subscript(path: String) -> Value? {
        get { storage[path] }
        set { storage[path] = newValue }
    }

    var count: Int { storage.count }

    func removeAll() {
        storage.removeAll(keepingCapacity: false)
    }
}

/// Tracks Quick Look's presentation separately from its decoded-image cache.
///
/// Full-screen transitions temporarily own the panel geometry. Automatic
/// per-file sizing must stay paused until the panel returns to its ordinary
/// window, otherwise a newly selected image can snap the full-screen panel
/// back to its cached windowed frame.
enum FPQuickLookPresentationState {
    case windowed
    case enteringFullScreen
    case fullScreen
    case exitingFullScreen

    var suppressesAutomaticResize: Bool {
        self != .windowed
    }

    var isFullScreenOrTransitioning: Bool {
        self != .windowed
    }
}

/// Pure geometry shared by Quick Look and its regression test.
///
/// The target is deliberately derived from one session anchor instead of the
/// panel's current frame. Quick Look can nudge its own window while swapping
/// previews; feeding that changed frame back into the next resize caused the
/// window to drift a few points on every arrow press.
enum FPQuickLookPanelSizing {
    static func contentSize(
        for intrinsicSize: NSSize,
        visibleFrame: NSRect
    ) -> NSSize {
        let horizontalChrome: CGFloat = 88
        let verticalChrome: CGFloat = 112
        let maximumContent = NSSize(
            width: max(420, visibleFrame.width * 0.86),
            height: max(340, visibleFrame.height * 0.86)
        )
        let availablePreview = NSSize(
            width: max(maximumContent.width - horizontalChrome, 1),
            height: max(maximumContent.height - verticalChrome, 1)
        )
        // File resolution controls only the aspect ratio. Even a small source
        // should use the available preview area instead of opening as a tiny
        // window on a Retina display.
        let fit = min(
            availablePreview.width / max(intrinsicSize.width, 1),
            availablePreview.height / max(intrinsicSize.height, 1)
        )
        let fittedPreview = NSSize(
            width: intrinsicSize.width * fit,
            height: intrinsicSize.height * fit
        )
        return NSSize(
            width: min(
                maximumContent.width,
                max(360, fittedPreview.width + horizontalChrome)
            ),
            height: min(
                maximumContent.height,
                max(280, fittedPreview.height + verticalChrome)
            )
        )
    }

    static func anchoredFrame(
        frameSize: NSSize,
        center: NSPoint,
        visibleFrame: NSRect
    ) -> NSRect {
        var frame = NSRect(
            x: center.x - frameSize.width / 2,
            y: center.y - frameSize.height / 2,
            width: frameSize.width,
            height: frameSize.height
        )
        if frame.maxX > visibleFrame.maxX {
            frame.origin.x = visibleFrame.maxX - frame.width
        }
        if frame.minX < visibleFrame.minX {
            frame.origin.x = visibleFrame.minX
        }
        if frame.maxY > visibleFrame.maxY {
            frame.origin.y = visibleFrame.maxY - frame.height
        }
        if frame.minY < visibleFrame.minY {
            frame.origin.y = visibleFrame.minY
        }
        return frame.integral
    }

    /// Tiny metadata differences should not trigger another window resize.
    static func isEquivalent(
        _ lhs: NSSize?,
        _ rhs: NSSize,
        tolerance: CGFloat = 18
    ) -> Bool {
        guard let lhs else { return false }
        return abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }
}

enum FPSpotlightSearch {
    static func predicate(for text: String) -> NSPredicate {
        let pattern = "*\(text)*"
        return NSCompoundPredicate(orPredicateWithSubpredicates: [
            NSPredicate(
                format: "%K LIKE[cd] %@",
                NSMetadataItemFSNameKey,
                pattern
            ),
            NSPredicate(
                format: "%K LIKE[cd] %@",
                NSMetadataItemDisplayNameKey,
                pattern
            ),
            // Поиск по содержимому файлов убран: Spotlight обходил тексты
            // всех документов на диске, и запрос по имени файла тянулся
            // секундами. По имени и отображаемому имени выдача мгновенная.
            NSPredicate(
                format: "%K LIKE[cd] %@",
                NSMetadataItemFSNameKey,
                pattern
            )
        ])
    }
}
