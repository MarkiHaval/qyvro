import AppKit
import QuartzCore

/// A small, restrained window transition that feels native on macOS.
/// The caller owns the transition token so interrupted show/hide animations
/// cannot order a newly reopened window back out.
enum FPWindowPresentationAnimator {
    static func show(
        _ window: NSWindow,
        orderFront: () -> Void,
        completion: (() -> Void)? = nil
    ) {
        let finalFrame = window.frame
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard !reduceMotion else {
            window.alphaValue = 1
            orderFront()
            completion?()
            return
        }

        let startFrame = scaledFrame(finalFrame, insetX: 9, insetY: 6, offsetY: -5)
        window.alphaValue = 0
        window.setFrame(startFrame, display: false)
        orderFront()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.20
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.20, 0.82, 0.24, 1.0)
            window.animator().alphaValue = 1
            window.animator().setFrame(finalFrame, display: true)
        } completionHandler: {
            window.alphaValue = 1
            window.setFrame(finalFrame, display: false)
            completion?()
        }
    }

    static func hide(
        _ window: NSWindow,
        completion: @escaping () -> Void
    ) {
        let finalFrame = window.frame
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard !reduceMotion else {
            completion()
            window.alphaValue = 1
            window.setFrame(finalFrame, display: false)
            return
        }

        let endFrame = scaledFrame(finalFrame, insetX: 7, insetY: 5, offsetY: -4)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.55, 0.0, 0.90, 0.55)
            window.animator().alphaValue = 0
            window.animator().setFrame(endFrame, display: true)
        } completionHandler: {
            completion()
            window.alphaValue = 1
            window.setFrame(finalFrame, display: false)
        }
    }

    private static func scaledFrame(
        _ frame: NSRect,
        insetX: CGFloat,
        insetY: CGFloat,
        offsetY: CGFloat
    ) -> NSRect {
        frame.insetBy(dx: insetX, dy: insetY).offsetBy(dx: 0, dy: offsetY)
    }
}
