import AppKit

/// A quiet overlay scroller with a forgiving interaction zone.
///
/// The control itself stays wide enough to grab comfortably, but only draws a
/// thin translucent rail. Moving the pointer near the right edge reveals it;
/// clicking anywhere in the track jumps to that exact position.
final class FPJumpScroller: NSScroller {
    private weak var trackedScrollView: NSScrollView?
    private var proximityTrackingArea: NSTrackingArea?
    private var boundsObserver: NSObjectProtocol?
    private var fadeWorkItem: DispatchWorkItem?
    private var pointerIsNear = false

    override class func scrollerWidth(
        for controlSize: NSControl.ControlSize,
        scrollerStyle: NSScroller.Style
    ) -> CGFloat {
        // This is the hit target, not the visible rail. Overlay mode means it
        // does not steal space from the file grid.
        max(18, super.scrollerWidth(for: controlSize, scrollerStyle: scrollerStyle))
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        alphaValue = 0.12
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        alphaValue = 0.12
    }

    deinit {
        fadeWorkItem?.cancel()
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installProximityTrackingIfNeeded()
    }

    private func installProximityTrackingIfNeeded() {
        guard let scrollView = enclosingScrollView,
              trackedScrollView !== scrollView else { return }

        if let oldArea = proximityTrackingArea,
           let oldScrollView = trackedScrollView {
            oldScrollView.removeTrackingArea(oldArea)
        }
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
            self.boundsObserver = nil
        }

        trackedScrollView = scrollView
        let area = NSTrackingArea(
            rect: .zero,
            options: [
                .mouseEnteredAndExited,
                .mouseMoved,
                .activeInActiveApp,
                .inVisibleRect,
                .enabledDuringMouseDrag
            ],
            owner: self,
            userInfo: nil
        )
        scrollView.addTrackingArea(area)
        proximityTrackingArea = area

        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.revealTemporarily()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        updateProximity(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateProximity(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        pointerIsNear = false
        scheduleFade(after: 0.18)
    }

    private func updateProximity(with event: NSEvent) {
        guard let scrollView = trackedScrollView else { return }
        let point = scrollView.convert(event.locationInWindow, from: nil)
        let isNear = point.x >= scrollView.bounds.maxX - 46
        guard isNear != pointerIsNear else { return }
        pointerIsNear = isNear
        if isNear {
            reveal()
        } else {
            scheduleFade(after: 0.18)
        }
    }

    private func reveal() {
        fadeWorkItem?.cancel()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 0.92
        }
    }

    private func revealTemporarily() {
        reveal()
        if !pointerIsNear {
            scheduleFade(after: 0.72)
        }
    }

    private func scheduleFade(after delay: TimeInterval) {
        fadeWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.pointerIsNear else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.28
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.animator().alphaValue = 0.12
            }
        }
        fadeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        guard !slotRect.isEmpty else { return }
        let railWidth: CGFloat = 2
        let railRect = NSRect(
            x: slotRect.midX - railWidth / 2,
            y: slotRect.minY + 5,
            width: railWidth,
            height: max(0, slotRect.height - 10)
        )
        NSColor.white.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: railRect, xRadius: 1, yRadius: 1).fill()
    }

    override func drawKnob() {
        let knobRect = rect(for: .knob)
        guard !knobRect.isEmpty else { return }
        let width: CGFloat = 7
        let visibleRect = NSRect(
            x: knobRect.midX - width / 2,
            y: knobRect.minY + 1,
            width: width,
            height: max(12, knobRect.height - 2)
        )
        NSColor.white.withAlphaComponent(0.62).setFill()
        NSBezierPath(
            roundedRect: visibleRect,
            xRadius: width / 2,
            yRadius: width / 2
        ).fill()
    }

    override func mouseDown(with event: NSEvent) {
        reveal()
        let point = convert(event.locationInWindow, from: nil)
        guard testPart(point) == .knobSlot else {
            super.mouseDown(with: event)
            if !pointerIsNear {
                scheduleFade(after: 0.72)
            }
            return
        }

        let slot = rect(for: .knobSlot)
        let knob = rect(for: .knob)
        let vertical = slot.height >= slot.width
        let slotLength = vertical ? slot.height : slot.width
        let knobLength = vertical ? knob.height : knob.width
        let usableLength = max(1, slotLength - knobLength)
        let coordinate = vertical ? point.y : point.x
        let slotStart = vertical ? slot.minY : slot.minX
        var fraction = (coordinate - slotStart - knobLength / 2) / usableLength
        fraction = min(max(fraction, 0), 1)
        if vertical && !isFlipped {
            fraction = 1 - fraction
        }

        doubleValue = Double(fraction)
        if let action {
            sendAction(action, to: target)
        }
        if !pointerIsNear {
            scheduleFade(after: 0.72)
        }
    }
}

func FPConfigurePrimaryScroller(_ scrollView: NSScrollView) {
    let scroller = FPJumpScroller()
    scroller.controlSize = .regular
    scroller.knobStyle = .light
    scrollView.verticalScroller = scroller
    scrollView.scrollerStyle = .overlay
    scrollView.hasVerticalScroller = true
    // The control remains present for the generous hit target, while custom
    // drawing and alpha keep it visually out of the way.
    scrollView.autohidesScrollers = false
}
