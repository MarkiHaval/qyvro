// Не подключён к сборке. Накладка для перетаскивания края боковой
// панели. Заменена монитором событий: её hitTest сравнивал точку в
// системе координат надвью со своими границами и не срабатывал.

import Cocoa

final class FPSidebarResizeHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Точка приходит в системе координат надвью. Сравнивать её напрямую
        // с `bounds` нельзя: ручка шириной 12 точек стоит у края боковой
        // панели, далеко от начала координат, поэтому попадание не
        // срабатывало никогда и панель не тянулась.
        guard let superview else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        onDrag?(event.locationInWindow.x)
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.locationInWindow.x)
    }
}
