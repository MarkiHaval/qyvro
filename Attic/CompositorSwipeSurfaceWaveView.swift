// Не подключён к сборке. Запасной вариант эффекта свайпа на слоях
// композитора: дешевле по ресурсам, но не искривляет сами пиксели,
// поэтому не стал основным. Оставлен на случай возврата.

import Cocoa
import Quartz

// Kept as a source-level fallback. This compositor-only version is cheaper, but
// it cannot bend the actual pixels and therefore must not be the default effect.
final class CompositorSwipeSurfaceWaveView: NSView {
    private let sourceLayer = CALayer()
    private let sourceMask = CAGradientLayer()
    private let destinationLayer = CALayer()
    private let destinationMask = CAGradientLayer()

    private let blurGroup = CALayer()
    private let blurSourceLayer = CALayer()
    private let blurSourceMask = CAGradientLayer()
    private let blurDestinationLayer = CALayer()
    private let blurDestinationMask = CAGradientLayer()
    private let blurCrestMask = CAGradientLayer()

    private let tintGlowLayer = CAGradientLayer()
    private let tintLayer = CAGradientLayer()

    private var sourceContents: CGImage?
    private var destinationContents: CGImage?
    private var hiddenViews: [NSView] = []
    private var hiddenViewAlphas: [CGFloat] = []
    private var direction: CGFloat = 1
    private var captureRect = NSRect.zero
    private var completion: (() -> Void)?
    private var animationGeneration = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        alphaValue = 0
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    @discardableResult
    func prepareTransition(capturing view: NSView, rect: NSRect, hiding views: [NSView], direction: CGFloat) -> Bool {
        cancelPendingAnimation()
        restoreHiddenViews()
        removeCompositorLayers()
        sourceContents = nil
        destinationContents = nil
        completion = nil
        captureRect = rect
        self.direction = direction >= 0 ? 1 : -1

        view.layoutSubtreeIfNeeded()
        guard let source = snapshot(of: view, rect: rect) else { return false }
        sourceContents = source

        hiddenViews = views
        hiddenViewAlphas = views.map(\.alphaValue)
        views.forEach { $0.alphaValue = 0 }

        layer?.contents = source
        layer?.contentsGravity = .resize
        layer?.contentsScale = max(CGFloat(source.width) / max(bounds.width, 1), 1)
        alphaValue = 1
        isHidden = false
        return true
    }

    @discardableResult
    func captureDestination(from view: NSView) -> Bool {
        guard sourceContents != nil else { return false }
        let wasHidden = isHidden
        let previousAlpha = alphaValue
        isHidden = true
        alphaValue = 0
        for (hiddenView, alpha) in zip(hiddenViews, hiddenViewAlphas) {
            hiddenView.alphaValue = alpha
        }
        view.layoutSubtreeIfNeeded()
        destinationContents = snapshot(of: view, rect: captureRect)
        hiddenViews.forEach { $0.alphaValue = 0 }
        alphaValue = previousAlpha
        isHidden = wasHidden
        layer?.contents = sourceContents
        return destinationContents != nil
    }

    func play(completion: @escaping () -> Void) {
        guard let sourceContents, let destinationContents else {
            cancelImmediately()
            completion()
            return
        }

        self.completion = completion
        animationGeneration += 1
        let generation = animationGeneration
        configureCompositorLayers(source: sourceContents, destination: destinationContents)

        let smoothness = CGFloat(FPPreferences.swipeWaveSmoothness)
        let widthSetting = CGFloat(FPPreferences.swipeWaveWidth)
        let duration = min(1.12, FPPreferences.swipeWaveDuration * (0.74 + Double(smoothness) * 0.08))
        let bandWidth = 0.15 + widthSetting * 0.22
        let revealFeather = 0.018 + smoothness * 0.021
        let start = -bandWidth * 0.78
        let end = 1 + bandWidth * 0.78
        let timing = CAMediaTimingFunction(controlPoints: 0.20, 0.66, 0.28, 1.0)

        let revealStart = revealLocations(center: start, feather: revealFeather)
        let revealEnd = revealLocations(center: end, feather: revealFeather)
        animateLocations(
            on: sourceMask,
            from: revealStart,
            to: revealEnd,
            duration: duration,
            timing: timing
        )
        animateLocations(
            on: destinationMask,
            from: revealStart,
            to: revealEnd,
            duration: duration,
            timing: timing
        )
        animateLocations(
            on: blurSourceMask,
            from: revealStart,
            to: revealEnd,
            duration: duration,
            timing: timing
        )
        animateLocations(
            on: blurDestinationMask,
            from: revealStart,
            to: revealEnd,
            duration: duration,
            timing: timing
        )

        let crestStart = crestLocations(center: start, width: bandWidth, feather: revealFeather)
        let crestEnd = crestLocations(center: end, width: bandWidth, feather: revealFeather)
        animateLocations(
            on: blurCrestMask,
            from: crestStart,
            to: crestEnd,
            duration: duration,
            timing: timing
        )

        let tintStart = tintLocations(center: start, width: bandWidth)
        let tintEnd = tintLocations(center: end, width: bandWidth)
        animateLocations(on: tintGlowLayer, from: tintStart, to: tintEnd, duration: duration, timing: timing)
        animateLocations(on: tintLayer, from: tintStart, to: tintEnd, duration: duration, timing: timing)

        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.025) { [weak self] in
            guard let self, self.animationGeneration == generation else { return }
            self.finishAnimation()
        }
    }

    func cancelImmediately() {
        let completion = self.completion
        self.completion = nil
        hideImmediately()
        completion?()
    }

    private func configureCompositorLayers(source: CGImage, destination: CGImage) {
        guard let rootLayer = layer else { return }
        removeCompositorLayers()
        rootLayer.contents = nil
        rootLayer.masksToBounds = true

        let frame = bounds
        let contentScale = max(CGFloat(source.width) / max(frame.width, 1), 1)
        let imageLayers = [sourceLayer, destinationLayer, blurSourceLayer, blurDestinationLayer]
        for imageLayer in imageLayers {
            imageLayer.frame = frame
            imageLayer.contentsGravity = .resize
            imageLayer.contentsScale = contentScale
            imageLayer.masksToBounds = true
        }
        sourceLayer.contents = source
        destinationLayer.contents = destination
        blurSourceLayer.contents = source
        blurDestinationLayer.contents = destination

        configureGradientGeometry(sourceMask)
        configureGradientGeometry(destinationMask)
        configureGradientGeometry(blurSourceMask)
        configureGradientGeometry(blurDestinationMask)
        configureGradientGeometry(blurCrestMask)
        configureGradientGeometry(tintGlowLayer)
        configureGradientGeometry(tintLayer)

        sourceMask.frame = frame
        sourceMask.colors = inverseRevealColors()
        sourceLayer.mask = sourceMask

        destinationMask.frame = frame
        destinationMask.colors = revealColors()
        destinationLayer.mask = destinationMask

        blurSourceMask.frame = frame
        blurSourceMask.colors = inverseRevealColors()
        blurSourceLayer.mask = blurSourceMask

        blurDestinationMask.frame = frame
        blurDestinationMask.colors = revealColors()
        blurDestinationLayer.mask = blurDestinationMask

        blurGroup.frame = frame
        blurGroup.masksToBounds = true
        blurGroup.addSublayer(blurSourceLayer)
        blurGroup.addSublayer(blurDestinationLayer)
        blurCrestMask.frame = frame
        blurCrestMask.colors = crestColors()
        blurGroup.mask = blurCrestMask
        blurGroup.opacity = 0.98

        let blurSetting = CGFloat(FPPreferences.swipeWaveBlur)
        let strength = CGFloat(FPPreferences.swipeWaveStrength)
        let exposure = CGFloat(FPPreferences.swipeWaveExposure)
        let tiltRadians = CGFloat(FPPreferences.swipeWaveTilt * .pi / 180)
        var filters: [CIFilter] = []
        if let exposureFilter = CIFilter(name: "CIExposureAdjust") {
            exposureFilter.setValue(0.10 + exposure * 0.62, forKey: kCIInputEVKey)
            filters.append(exposureFilter)
        }
        if let motionFilter = CIFilter(name: "CIMotionBlur") {
            motionFilter.setValue(1.2 + blurSetting * 5.8 + strength * 2.2, forKey: kCIInputRadiusKey)
            motionFilter.setValue(tiltRadians, forKey: kCIInputAngleKey)
            filters.append(motionFilter)
        }
        if let softFilter = CIFilter(name: "CIGaussianBlur") {
            softFilter.setValue(0.8 + blurSetting * 3.6, forKey: kCIInputRadiusKey)
            filters.append(softFilter)
        }
        blurGroup.filters = filters

        // A tiny offset inside the masked crest reads as refraction, while the
        // broad motion/gaussian blur keeps it from producing a second sharp icon.
        let refraction = (1.5 + strength * 4.8) * direction
        blurGroup.setAffineTransform(
            CGAffineTransform(a: 1.003, b: 0, c: tan(tiltRadians) * 0.012, d: 1.002, tx: refraction, ty: 0)
        )

        let cool = (FPStyle.accent.usingColorSpace(.sRGB) ?? FPStyle.accent)
        let warm = (FPStyle.orange.usingColorSpace(.sRGB) ?? FPStyle.orange)
        let tintStrength = CGFloat(FPPreferences.swipeWaveTint)
        let glowStrength = CGFloat(FPPreferences.swipeWaveGlow)
        let brightAlpha = min(0.26, 0.075 + glowStrength * 0.17 + exposure * 0.04)
        let colorAlpha = min(0.34, 0.055 + tintStrength * 0.21 + glowStrength * 0.075)
        let clear = NSColor.clear.cgColor
        let tintColors: [CGColor] = [
            clear,
            cool.withAlphaComponent(colorAlpha * 0.55).cgColor,
            cool.withAlphaComponent(colorAlpha).cgColor,
            NSColor.white.withAlphaComponent(brightAlpha).cgColor,
            warm.withAlphaComponent(colorAlpha).cgColor,
            warm.withAlphaComponent(colorAlpha * 0.52).cgColor,
            clear
        ]

        tintGlowLayer.frame = frame
        tintGlowLayer.colors = tintColors
        tintGlowLayer.opacity = Float(0.30 + glowStrength * 0.34)
        tintGlowLayer.compositingFilter = "screenBlendMode"
        if let glowBlur = CIFilter(name: "CIGaussianBlur") {
            glowBlur.setValue(12 + glowStrength * 18, forKey: kCIInputRadiusKey)
            tintGlowLayer.filters = [glowBlur]
        }

        tintLayer.frame = frame
        tintLayer.colors = tintColors
        tintLayer.opacity = Float(0.42 + tintStrength * 0.30)
        tintLayer.compositingFilter = "screenBlendMode"

        rootLayer.addSublayer(sourceLayer)
        rootLayer.addSublayer(destinationLayer)
        rootLayer.addSublayer(blurGroup)
        rootLayer.addSublayer(tintGlowLayer)
        rootLayer.addSublayer(tintLayer)
        alphaValue = 1
        isHidden = false
    }

    private func configureGradientGeometry(_ gradient: CAGradientLayer) {
        gradient.type = .axial
        let tilt = CGFloat(tan(FPPreferences.swipeWaveTilt * .pi / 180)) * 0.28
        if direction > 0 {
            gradient.startPoint = CGPoint(x: 0, y: 0.5 - tilt)
            gradient.endPoint = CGPoint(x: 1, y: 0.5 + tilt)
        } else {
            gradient.startPoint = CGPoint(x: 1, y: 0.5 + tilt)
            gradient.endPoint = CGPoint(x: 0, y: 0.5 - tilt)
        }
        gradient.drawsAsynchronously = true
    }

    private func revealColors() -> [CGColor] {
        [NSColor.white.cgColor, NSColor.white.cgColor, NSColor.clear.cgColor, NSColor.clear.cgColor]
    }

    private func inverseRevealColors() -> [CGColor] {
        [NSColor.clear.cgColor, NSColor.clear.cgColor, NSColor.white.cgColor, NSColor.white.cgColor]
    }

    private func crestColors() -> [CGColor] {
        [
            NSColor.clear.cgColor,
            NSColor.clear.cgColor,
            NSColor.white.cgColor,
            NSColor.white.cgColor,
            NSColor.clear.cgColor,
            NSColor.clear.cgColor
        ]
    }

    private func revealLocations(center: CGFloat, feather: CGFloat) -> [NSNumber] {
        [center - feather * 1.35, center - feather * 0.50, center + feather * 0.50, center + feather * 1.35]
            .map { NSNumber(value: Double($0)) }
    }

    private func crestLocations(center: CGFloat, width: CGFloat, feather: CGFloat) -> [NSNumber] {
        [
            center - width * 0.64,
            center - width * 0.42,
            center - feather * 0.80,
            center + feather * 0.80,
            center + width * 0.42,
            center + width * 0.64
        ].map { NSNumber(value: Double($0)) }
    }

    private func tintLocations(center: CGFloat, width: CGFloat) -> [NSNumber] {
        [
            center - width,
            center - width * 0.62,
            center - width * 0.27,
            center,
            center + width * 0.27,
            center + width * 0.62,
            center + width
        ].map { NSNumber(value: Double($0)) }
    }

    private func animateLocations(
        on gradient: CAGradientLayer,
        from: [NSNumber],
        to: [NSNumber],
        duration: CFTimeInterval,
        timing: CAMediaTimingFunction
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.locations = to
        CATransaction.commit()

        let animation = CABasicAnimation(keyPath: "locations")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = timing
        animation.isRemovedOnCompletion = true
        gradient.add(animation, forKey: "qyvro.wave.locations")
    }

    private func snapshot(of view: NSView, rect: NSRect) -> CGImage? {
        guard rect.width > 1, rect.height > 1 else { return nil }
        let windowScale = view.window?.backingScaleFactor ?? 1
        let preferredScale = min(max(windowScale, 1), 2)
        var candidateScales: [CGFloat] = [preferredScale]
        if preferredScale > 1.55 { candidateScales.append(1.5) }
        if preferredScale > 1.05 { candidateScales.append(1) }

        for backingScale in candidateScales {
            let pixelWidth = max(Int((rect.width * backingScale).rounded(.up)), 2)
            let pixelHeight = max(Int((rect.height * backingScale).rounded(.up)), 2)
            guard let representation = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelWidth,
                pixelsHigh: pixelHeight,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else { continue }
            representation.size = rect.size
            view.displayIfNeeded()
            view.cacheDisplay(in: rect, to: representation)
            if let image = representation.cgImage { return image }
        }
        return nil
    }

    private func finishAnimation() {
        let completion = self.completion
        self.completion = nil
        hideImmediately()
        completion?()
    }

    private func cancelPendingAnimation() {
        animationGeneration += 1
    }

    private func hideImmediately() {
        cancelPendingAnimation()
        alphaValue = 0
        isHidden = true
        restoreHiddenViews()
        removeCompositorLayers()
        sourceContents = nil
        destinationContents = nil
        layer?.contents = nil
        completion = nil
    }

    private func removeCompositorLayers() {
        let layers = [
            sourceLayer,
            destinationLayer,
            blurGroup,
            blurSourceLayer,
            blurDestinationLayer,
            tintGlowLayer,
            tintLayer
        ]
        for currentLayer in layers {
            currentLayer.removeAllAnimations()
            currentLayer.removeFromSuperlayer()
            currentLayer.mask = nil
            currentLayer.filters = nil
            currentLayer.setAffineTransform(.identity)
        }
        for mask in [sourceMask, destinationMask, blurSourceMask, blurDestinationMask, blurCrestMask] {
            mask.removeAllAnimations()
            mask.removeFromSuperlayer()
        }
        destinationLayer.contents = nil
        blurDestinationLayer.contents = nil
        sourceLayer.contents = nil
        blurSourceLayer.contents = nil
    }

    private func restoreHiddenViews() {
        for (view, alpha) in zip(hiddenViews, hiddenViewAlphas) {
            view.alphaValue = alpha
        }
        hiddenViews.removeAll()
        hiddenViewAlphas.removeAll()
    }
}
