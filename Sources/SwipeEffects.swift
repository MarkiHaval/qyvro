import Cocoa
import Quartz
import CoreImage
import CoreVideo
import IOSurface
import Metal
final class SwipeSurfaceWaveView: NSView {
    private static let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let metalDevice: MTLDevice? = {
        // MTLCreateSystemDefaultDevice() selects the Intel UHD on some dual-GPU
        // MacBook Pros. Prefer the discrete GPU for this brief, texture-heavy
        // transition so repeated navigation does not make the window stutter.
        MTLCopyAllDevices().first(where: { !$0.isLowPower && !$0.isRemovable })
            ?? MTLCreateSystemDefaultDevice()
    }()
    private static let commandQueue = metalDevice?.makeCommandQueue()
    /// Доля от размера окна, в которой считается волна.
    ///
    /// Ядро делает девять выборок текстуры на пиксель, а при быстром листании
    /// таких проходов выстраивается несколько подряд. На интегрированной
    /// графике полноразмерный проход не укладывается в кадр: `updateLayer`
    /// начинает массово выходить по проверке «предыдущий кадр ещё на GPU», и
    /// кадры отбрасываются. Эффект намеренно мягкий и размытый, поэтому счёт в
    /// 0.65 размера с растяжением слоя почти не отличим на глаз, но снимает с
    /// GPU больше половины работы.
    ///
    /// Края перехода видны не отсюда: первый и последний кадры оверлея — это
    /// нативные Retina-снимки, они подменяются кроссфейдом.
    private static let renderScale: CGFloat = {
        guard let device = metalDevice else { return 1 }
        return device.isLowPower ? 0.65 : 1
    }()
    private static let context: CIContext = {
        let options: [CIContextOption: Any] = [
            .cacheIntermediates: true,
            .workingColorSpace: outputColorSpace,
            .outputColorSpace: outputColorSpace
        ]
        if let device = metalDevice {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }()
    private static let waveKernel: CIKernel? = {
        let source = """
        kernel vec4 qyvroWave(
            sampler outgoing,
            sampler incoming,
            sampler outgoingBlurred,
            sampler incomingBlurred,
            vec2 center,
            vec4 imageBounds,
            float radius,
            float width,
            float amplitude,
            float tilt,
            vec4 cool,
            vec4 warm,
            float exposure,
            float glowStrength,
            float blurStrength,
            float tintStrength,
            float motion,
            float destinationMix
        ) {
            vec2 position = destCoord();
            vec2 delta = position - center;
            vec2 slanted = vec2(delta.x + delta.y * tilt, delta.y);
            float distanceFromCenter = length(slanted);
            float phase = (distanceFromCenter - radius) / max(width, 1.0);
            float broad = exp(-phase * phase * 0.58);
            float crest = exp(-phase * phase * 2.35);

            vec2 direction = normalize(vec2(slanted.x, delta.y + slanted.x * tilt) + vec2(0.0001));
            vec2 tangent = vec2(-direction.y, direction.x);

            // An asymmetric push-pull lens has a compressed leading shoulder
            // and a longer trailing pull. It stretches the actual pixels like a
            // liquid sheet instead of merely wobbling them along a sine curve.
            float leading = exp(-(phase - 0.40) * (phase - 0.40) * 1.75);
            float trailing = exp(-(phase + 0.52) * (phase + 0.52) * 1.18);
            float verticalPhase = delta.y / max(width, 1.0);
            float displacement = amplitude * (
                leading * 0.72
                - trailing * 0.56
                + sin(phase * 0.88) * broad * 0.13
                + crest * 0.08
            );
            float shear = amplitude * (
                sin(phase * 0.82 + verticalPhase * 0.66) * broad * 0.068
                + verticalPhase * crest * 0.022
            );
            vec2 samplePosition = position + direction * displacement + tangent * shear;
            samplePosition = clamp(samplePosition, imageBounds.xy + vec2(1.0), imageBounds.zw - vec2(1.0));

            // Preserve the old morph, changing only its overlap width. The old
            // 0.155 band exposed two readable grids at once; the narrow band is
            // concealed by the same bright blur and removes that doubling.
            float reveal = 1.0 - smoothstep(-0.040, 0.040, phase);
            float handoff = reveal * destinationMix;
            float blurEnvelope = (0.42 * broad + 0.58 * crest) * motion;

            vec4 o0 = sample(outgoing, samplerTransform(outgoing, samplePosition));
            vec4 i0 = sample(incoming, samplerTransform(incoming, samplePosition));
            vec4 central = mix(o0, i0, handoff);

            // The blurred inputs are produced by Core Image's optimized
            // Gaussian pass and cached for the whole transition. Two lightly
            // shifted samples add the directional AirDrop-like stretch while
            // retaining the smooth, high-quality Gaussian falloff.
            float streakRadius = (1.5 + blurStrength * 8.0) * blurEnvelope;
            vec2 streak = (direction * 0.84 + tangent * 0.36) * streakRadius;
            vec2 bp = clamp(samplePosition + streak, imageBounds.xy + vec2(1.0), imageBounds.zw - vec2(1.0));
            vec2 bm = clamp(samplePosition - streak, imageBounds.xy + vec2(1.0), imageBounds.zw - vec2(1.0));
            vec4 b0 = mix(
                sample(outgoingBlurred, samplerTransform(outgoingBlurred, samplePosition)),
                sample(incomingBlurred, samplerTransform(incomingBlurred, samplePosition)),
                handoff
            );
            vec4 bp0 = mix(
                sample(outgoingBlurred, samplerTransform(outgoingBlurred, bp)),
                sample(incomingBlurred, samplerTransform(incomingBlurred, bp)),
                handoff
            );
            vec4 bm0 = mix(
                sample(outgoingBlurred, samplerTransform(outgoingBlurred, bm)),
                sample(incomingBlurred, samplerTransform(incomingBlurred, bm)),
                handoff
            );
            vec4 softened = b0 * 0.52 + (bp0 + bm0) * 0.24;
            float blurMix = clamp(
                (0.12 + blurStrength * 1.38) * (0.42 * broad + 0.58 * crest) * motion,
                0.0,
                0.94
            );
            vec4 base = mix(central, softened, blurMix);

            float gradientPosition = smoothstep(-1.10, 1.10, phase);
            vec3 waveTint = mix(cool.rgb, warm.rgb, gradientPosition);
            float exposureGain = 1.0 + exposure * (0.20 * broad + 0.42 * crest) * motion;
            float glowAmount = glowStrength * (0.025 * broad + 0.070 * crest) * motion;
            float tintAmount = tintStrength * (0.018 * broad + 0.045 * crest) * motion;

            // Sub-pixel dither prevents visible 8-bit gradient banding without
            // adding texture that resembles JPEG compression.
            float noise = fract(sin(dot(position, vec2(12.9898, 78.233))) * 43758.5453) - 0.5;
            vec3 color = base.rgb * exposureGain
                + waveTint * (glowAmount + tintAmount) * base.a
                + vec3(noise * 0.0022 * broad * motion);
            return vec4(color, base.a);
        }
        """
        return CIKernel(source: source)
    }()
    private static let prewarmedRenderer: Void = {
        guard let waveKernel, let metalDevice, let commandQueue else { return }
        let extent = CGRect(x: 0, y: 0, width: 16, height: 16)
        func bitmap(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGImage? {
            guard let bitmapContext = CGContext(
                data: nil,
                width: 16,
                height: 16,
                bitsPerComponent: 8,
                bytesPerRow: 16 * 4,
                space: outputColorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            bitmapContext.setFillColor(red: red, green: green, blue: blue, alpha: 1)
            bitmapContext.fill(extent)
            return bitmapContext.makeImage()
        }
        guard let sourceBitmap = bitmap(0.10, 0.12, 0.13),
              let destinationBitmap = bitmap(0.13, 0.15, 0.16) else { return }
        let source = CIImage(cgImage: sourceBitmap, options: [.colorSpace: outputColorSpace])
        let destination = CIImage(cgImage: destinationBitmap, options: [.colorSpace: outputColorSpace])
        guard let output = waveKernel.apply(
            extent: extent,
            roiCallback: { _, rect in rect.insetBy(dx: -8, dy: -8) },
            arguments: [
                CISampler(image: source.clampedToExtent()),
                CISampler(image: destination.clampedToExtent()),
                CISampler(image: source.clampedToExtent()),
                CISampler(image: destination.clampedToExtent()),
                CIVector(x: -2, y: 8),
                CIVector(x: 0, y: 0, z: 16, w: 16),
                CGFloat(5), CGFloat(8), CGFloat(2), CGFloat(0),
                CIVector(x: 0.10, y: 0.75, z: 0.86, w: 1),
                CIVector(x: 1.00, y: 0.64, z: 0.26, w: 1),
                CGFloat(0.5), CGFloat(0.5), CGFloat(0.5), CGFloat(0.4), CGFloat(0.5), CGFloat(1)
            ]
        ) else { return }

        let properties: [IOSurfacePropertyKey: Any] = [
            .width: 16,
            .height: 16,
            .bytesPerRow: 16 * 4,
            .bytesPerElement: 4,
            .allocSize: 16 * 16 * 4,
            .pixelFormat: kCVPixelFormatType_32BGRA
        ]
        guard let surface = IOSurface(properties: properties) else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 16,
            height: 16,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let texture = metalDevice.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        let renderOutput = output.transformed(by: CGAffineTransform(
            a: 1,
            b: 0,
            c: 0,
            d: -1,
            tx: 0,
            ty: extent.height
        ))
        context.render(
            renderOutput,
            to: texture,
            commandBuffer: commandBuffer,
            bounds: extent,
            colorSpace: outputColorSpace
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }()

    private var sourceImage: CIImage?
    private var destinationImage: CIImage?
    private var previousDestinationImage: CIImage?
    private var sourceBlurredImage: CIImage?
    private var destinationBlurredImage: CIImage?
    private var previousDestinationBlurredImage: CIImage?
    private var destinationCrossfadeStartedAt: CFTimeInterval?
    private var displayTimer: Timer?
    private var _frameDisplayLink: AnyObject?
    @available(macOS 14.0, *)
    private var frameDisplayLink: CADisplayLink? {
        get { _frameDisplayLink as? CADisplayLink }
        set { _frameDisplayLink = newValue }
    }
    private var hiddenViews: [NSView] = []
    private var hiddenViewAlphas: [CGFloat] = []
    private var direction: CGFloat = 1
    private var displayedProgress: CGFloat = 0
    private var animationStartedAt: CFTimeInterval?
    private var destinationReadyAt: CFTimeInterval?
    private var destinationBlend: CGFloat = 0
    private struct WavePulse {
        let startedAt: CFTimeInterval
        let direction: CGFloat
    }
    private var wavePulses: [WavePulse] = []
    private var wavePulseProgresses: [CGFloat] = []
    private var hasPresentedFirstGPUFrame = false
    private var hasPreparedLiveViewsForHandoff = false
    private var completion: (() -> Void)?
    private var outputSurfaces: [IOSurface] = []
    private var outputSurfaceSize = NSSize.zero
    private var outputSurfaceIndex = 0
    private var captureRect = NSRect.zero
    // «Крайние» кадры перехода в нативном Retina-масштабе и нативном цветовом
    // пространстве окна. Первый и последний видимые кадры оверлея совпадают с
    // живой сеткой попиксельно, поэтому вход в волну и выход из неё не мерцают.
    private var sourceHoldContents: CGImage?
    private var destinationHoldContents: CGImage?
    private var hasSwappedToDestinationHold = false
    private var renderInFlight = false
    private var renderGeneration = 0
    /// Отдельный счётчик для фоновых размытий: `renderGeneration` растёт ещё и
    /// при каждом новом гребне, а посчитанное размытие при этом остаётся
    /// действительным.
    private var blurGeneration = 0
    private var finishRequested = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        DispatchQueue.global(qos: .utility).async { _ = Self.prewarmedRenderer }
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.contentsGravity = .resize
        layer?.contentsScale = 1
        layer?.minificationFilter = .linear
        layer?.magnificationFilter = .linear
        alphaValue = 0
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    @discardableResult
    func prepareTransition(capturing view: NSView, rect: NSRect, hiding views: [NSView], direction: CGFloat) -> Bool {
        restoreHiddenViews()
        stopTimer()
        layer?.removeAllAnimations()
        alphaValue = 0
        isHidden = true
        sourceImage = nil
        destinationImage = nil
        previousDestinationImage = nil
        sourceBlurredImage = nil
        destinationBlurredImage = nil
        previousDestinationBlurredImage = nil
        destinationCrossfadeStartedAt = nil
        completion = nil
        self.direction = direction >= 0 ? 1 : -1
        displayedProgress = 0
        animationStartedAt = nil
        destinationReadyAt = nil
        destinationBlend = 0
        wavePulses.removeAll()
        wavePulseProgresses.removeAll()
        hasPresentedFirstGPUFrame = false
        hasPreparedLiveViewsForHandoff = false
        hasSwappedToDestinationHold = false
        sourceHoldContents = nil
        destinationHoldContents = nil
        renderGeneration += 1
        blurGeneration += 1
        renderInFlight = false
        finishRequested = false
        captureRect = rect
        view.layoutSubtreeIfNeeded()
        sourceHoldContents = holdSnapshot(of: view, rect: rect)
        sourceImage = snapshot(of: view, rect: rect)
        guard let capturedSource = sourceImage else {
            sourceHoldContents = nil
            isHidden = true
            return false
        }
        requestBlur(of: capturedSource) { [weak self] blurred in
            guard let self, self.sourceImage === capturedSource else { return }
            self.sourceBlurredImage = blurred
        }
        if let sourceHoldContents {
            layer?.contentsScale = max(CGFloat(sourceHoldContents.width) / max(bounds.width, 1), 1)
            layer?.contents = sourceHoldContents
        } else {
            layer?.contentsScale = max(capturedSource.extent.width / max(bounds.width, 1), 1)
            layer?.contents = nil
        }
        hiddenViews = views
        hiddenViewAlphas = views.map(\.alphaValue)
        views.forEach { $0.alphaValue = 0 }
        alphaValue = 1
        isHidden = false
        needsDisplay = true
        return true
    }

    @discardableResult
    func captureDestination(from view: NSView) -> Bool {
        guard sourceImage != nil else { return false }
        let wasHidden = isHidden
        let previousAlpha = alphaValue
        isHidden = true
        alphaValue = 0
        for (hiddenView, alpha) in zip(hiddenViews, hiddenViewAlphas) {
            hiddenView.alphaValue = alpha
        }
        view.layoutSubtreeIfNeeded()
        destinationHoldContents = holdSnapshot(of: view, rect: captureRect)
        let capturedDestination = snapshot(of: view, rect: captureRect)
        let now = CACurrentMediaTime()
        if destinationImage == nil {
            destinationImage = capturedDestination
            destinationBlurredImage = nil
            if capturedDestination != nil, !wavePulses.isEmpty {
                destinationReadyAt = now
                destinationBlend = 0
            }
        } else if let capturedDestination {
            previousDestinationImage = destinationImage
            previousDestinationBlurredImage = destinationBlurredImage
            destinationImage = capturedDestination
            destinationBlurredImage = nil
            destinationCrossfadeStartedAt = now
        }
        if let capturedDestination {
            requestBlur(of: capturedDestination) { [weak self] blurred in
                guard let self, self.destinationImage === capturedDestination else { return }
                self.destinationBlurredImage = blurred
            }
        }
        hiddenViews.forEach { $0.alphaValue = 0 }
        alphaValue = previousAlpha
        isHidden = wasHidden
        needsDisplay = true
        return destinationImage != nil
    }

    func play(completion: @escaping () -> Void) {
        guard sourceImage != nil else {
            cancelImmediately()
            completion()
            return
        }
        self.completion = completion
        displayedProgress = 0
        let now = CACurrentMediaTime()
        animationStartedAt = now
        wavePulses = [
            WavePulse(
                startedAt: now,
                direction: direction
            )
        ]
        wavePulseProgresses = [0]
        destinationReadyAt = destinationImage == nil ? nil : animationStartedAt
        destinationBlend = destinationImage == nil ? 0 : 1
        finishRequested = false
        alphaValue = 1
        isHidden = false
        startTimer()
        needsDisplay = true
        displayIfNeeded()
    }

    func appendParallelPulse(direction: CGFloat) {
        guard animationStartedAt != nil else { return }
        let now = CACurrentMediaTime()
        // Four simultaneously visible crests are enough even for an unusually
        // fast hand. Once the visual budget is full, discard only a crest that
        // has already crossed most of the surface; navigation itself is never
        // dropped.
        if wavePulses.count >= 4,
           let disposable = wavePulseProgresses.firstIndex(where: { $0 >= 0.72 }) {
            wavePulses.remove(at: disposable)
            wavePulseProgresses.remove(at: disposable)
        }
        if wavePulses.count < 4 {
            wavePulses.append(
                WavePulse(
                    startedAt: now,
                    direction: direction >= 0 ? 1 : -1
                )
            )
            wavePulseProgresses.append(0)
        }
        // If a very late second gesture arrives during the hand-off, take the
        // live grid back under the opaque overlay and continue rendering. No
        // speed or clock of an existing crest is changed.
        hiddenViews.forEach { $0.alphaValue = 0 }
        hasPreparedLiveViewsForHandoff = false
        if hasSwappedToDestinationHold {
            hasSwappedToDestinationHold = false
            renderGeneration += 1
            renderInFlight = false
        }
        finishRequested = false
        alphaValue = 1
        isHidden = false
        needsDisplay = true
    }

    func cancelImmediately() {
        hideImmediately()
    }

    override func updateLayer() {
        guard let sourceImage, !hasSwappedToDestinationHold else { return }
        guard let waveKernel = Self.waveKernel else { return }
        // Start bending the current folder immediately. When the destination
        // snapshot arrives it replaces this fallback and the same wave performs
        // the hand-off without an empty pause after the trackpad gesture.
        let destinationImage = self.destinationImage ?? sourceImage
        let sourceBlurredImage = self.sourceBlurredImage ?? sourceImage
        let destinationBlurredImage = self.destinationBlurredImage ?? sourceBlurredImage
        guard !renderInFlight else { return }
        let extent = sourceImage.extent
        // Перевод точек в пиксели снимка. Зажимать снизу единицей нельзя:
        // на слабой графике волна считается в долях размера окна, и при
        // зажатом коэффициенте геометрия гребня разъезжалась относительно
        // картинки — ширина, смещение края и амплитуда оставались в точках.
        let scale = extent.width / max(bounds.width, 1)
        let smoothness = CGFloat(FPPreferences.swipeWaveSmoothness)
        let strength = CGFloat(FPPreferences.swipeWaveStrength)
        let widthSetting = CGFloat(FPPreferences.swipeWaveWidth)
        let blurSetting = CGFloat(FPPreferences.swipeWaveBlur)
        let exposure = CGFloat(FPPreferences.swipeWaveExposure)
        let glow = CGFloat(FPPreferences.swipeWaveGlow)
        let tint = CGFloat(FPPreferences.swipeWaveTint)
        let tilt = CGFloat(tan(FPPreferences.swipeWaveTilt * .pi / 180))
        let widthRatio = 0.30 + widthSetting * 0.50
        let waveWidth = max(360, min(1_100, bounds.width * widthRatio)) * scale
        let edgeOffset = max(48, bounds.width * 0.055) * scale
        let imageBounds = CIVector(x: extent.minX, y: extent.minY, z: extent.maxX, w: extent.maxY)
        let cool = colorVector(FPStyle.accent)
        let warm = colorVector(FPStyle.orange)
        let now = CACurrentMediaTime()
        let destinationCrossfade: CGFloat
        if let startedAt = destinationCrossfadeStartedAt {
            destinationCrossfade = smoothStep(CGFloat(min(max((now - startedAt) / 0.12, 0), 1)))
        } else {
            destinationCrossfade = 1
        }
        let effectiveDestination: CIImage
        let effectiveDestinationBlurred: CIImage
        if destinationCrossfade < 1,
           let previousDestinationImage,
           let previousDestinationBlurredImage {
            effectiveDestination = previousDestinationImage.applyingFilter(
                "CIDissolveTransition",
                parameters: [
                    kCIInputTargetImageKey: destinationImage,
                    kCIInputTimeKey: destinationCrossfade
                ]
            ).cropped(to: extent)
            effectiveDestinationBlurred = previousDestinationBlurredImage.applyingFilter(
                "CIDissolveTransition",
                parameters: [
                    kCIInputTargetImageKey: destinationBlurredImage,
                    kCIInputTimeKey: destinationCrossfade
                ]
            ).cropped(to: extent)
        } else {
            effectiveDestination = destinationImage
            effectiveDestinationBlurred = destinationBlurredImage
            previousDestinationImage = nil
            previousDestinationBlurredImage = nil
            destinationCrossfadeStartedAt = nil
        }

        let pulsePairs = Array(zip(wavePulses, wavePulseProgresses))
        guard !pulsePairs.isEmpty else { return }
        let firstActiveIndex = pulsePairs.firstIndex(where: { $0.1 < 0.999 }) ?? pulsePairs.count
        var composed = firstActiveIndex > 0 ? effectiveDestination : sourceImage
        var composedBlurred = firstActiveIndex > 0 ? effectiveDestinationBlurred : sourceBlurredImage
        let activePairs = pulsePairs.dropFirst(firstActiveIndex)
        for (offset, pair) in activePairs.enumerated() {
            let pulse = pair.0
            let clampedProgress = min(max(pair.1, 0), 1)
            let center = CIVector(
                x: pulse.direction > 0 ? extent.minX - edgeOffset : extent.maxX + edgeOffset,
                y: extent.midY
            )
            let eased = smoothStep(clampedProgress)
            let cornerDistances = [
                CGPoint(x: extent.minX, y: extent.minY),
                CGPoint(x: extent.maxX, y: extent.minY),
                CGPoint(x: extent.minX, y: extent.maxY),
                CGPoint(x: extent.maxX, y: extent.maxY)
            ].map { corner -> CGFloat in
                let dx = corner.x - center.x
                let dy = corner.y - center.y
                return hypot(dx + dy * tilt, dy)
            }
            let maxRadius = cornerDistances.max()
                ?? hypot(extent.width + edgeOffset, extent.height * 0.5)
            let entranceReserve = waveWidth * 0.50
            let exitReserve = waveWidth * 1.05
            let radius = -entranceReserve + eased * (maxRadius + entranceReserve + exitReserve)
            let motionBase = max(0, sin(.pi * clampedProgress))
            let motion = pow(motionBase, 2.05 + smoothness * 0.35)
            let amplitude = (7.0 + strength * 37.0) * scale * motion
            let roiPadding = max(waveWidth * 0.22, (amplitude + 20 * scale))
            guard let output = waveKernel.apply(
                extent: extent,
                roiCallback: { _, rect in rect.insetBy(dx: -roiPadding, dy: -roiPadding) },
                arguments: [
                    CISampler(image: composed.clampedToExtent()),
                    CISampler(image: effectiveDestination.clampedToExtent()),
                    CISampler(image: composedBlurred.clampedToExtent()),
                    CISampler(image: effectiveDestinationBlurred.clampedToExtent()),
                    center,
                    imageBounds,
                    radius,
                    waveWidth,
                    amplitude,
                    tilt,
                    cool,
                    warm,
                    exposure,
                    glow,
                    blurSetting,
                    tint,
                    motion,
                    destinationBlend
                ]
            ) else { continue }
            composed = output
            if offset + 1 < activePairs.count {
                let propagatedRadius = (2.5 + blurSetting * 7.5) * scale
                composedBlurred = output
                    .clampedToExtent()
                    .applyingFilter(
                        "CIGaussianBlur",
                        parameters: [kCIInputRadiusKey: propagatedRadius]
                    )
                    .cropped(to: extent)
            }
        }
        present(composed, progress: min(max(displayedProgress, 0), 1))
    }

    /// Цветовое пространство, в котором должны лежать пиксели готового кадра.
    ///
    /// `IOSurface`, назначенный слою через `layer.contents`, CoreAnimation
    /// показывает как есть, без цветокоррекции. Живая сетка и «крайние»
    /// Retina-снимки при этом рисуются AppKit'ом уже с коррекцией под профиль
    /// дисплея. Пока волна рендерилась в sRGB, её кадры выводились на профиль
    /// матрицы без конверсии и выглядели чуть ярче и насыщеннее — на входе и
    /// выходе из перехода это читалось как короткая вспышка. Рендер сразу в
    /// профиль окна убирает расхождение: сравнивать становится нечего.
    private var presentationColorSpace: CGColorSpace {
        window?.colorSpace?.cgColorSpace
            ?? NSScreen.main?.colorSpace?.cgColorSpace
            ?? Self.outputColorSpace
    }

    private func present(_ image: CIImage, progress: CGFloat) {
        let extent = image.extent.integral
        let outputSpace = presentationColorSpace
        // Core Image renders into Metal with a bottom-left origin, while an
        // IOSurface assigned to an AppKit layer is interpreted top-left first.
        // Flip only the rendered pixels; the initial CGImage snapshot remains
        // upright while the first GPU frame is being prepared.
        let renderImage = image.transformed(by: CGAffineTransform(
            a: 1,
            b: 0,
            c: 0,
            d: -1,
            tx: 0,
            ty: extent.minY + extent.maxY
        ))
        guard extent.width > 1, extent.height > 1,
              let surface = nextOutputSurface(width: Int(extent.width), height: Int(extent.height)) else { return }
        guard let device = Self.metalDevice,
              let commandQueue = Self.commandQueue,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            Self.context.render(renderImage, to: surface, bounds: extent, colorSpace: outputSpace)
            layer?.contentsScale = max(extent.width / max(bounds.width, 1), 1)
            layer?.contents = surface
            if finishRequested, progress >= 0.999 { finishAnimation() }
            return
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(extent.width),
            height: Int(extent.height),
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else { return }

        // Encode the Core Image pass into Metal and return to AppKit immediately.
        // If the GPU is still busy, timer samples are coalesced instead of making
        // the whole folder window wait for every intermediate frame.
        renderInFlight = true
        let generation = renderGeneration
        let contentScale = max(extent.width / max(bounds.width, 1), 1)
        Self.context.render(
            renderImage,
            to: texture,
            commandBuffer: commandBuffer,
            bounds: extent,
            colorSpace: outputSpace
        )
        commandBuffer.addCompletedHandler { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.renderGeneration == generation else { return }
                self.renderInFlight = false
                if self.hasSwappedToDestinationHold { return }
                if !self.hasPresentedFirstGPUFrame {
                    let fade = CATransition()
                    fade.type = .fade
                    fade.duration = 0.14
                    fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    self.layer?.add(fade, forKey: "firstGPUFrameFade")
                    self.hasPresentedFirstGPUFrame = true
                }
                self.layer?.contentsScale = contentScale
                self.layer?.contents = surface
                if self.finishRequested, progress >= 0.999 {
                    self.finishAnimation()
                } else if self.displayedProgress > progress + 0.001 || self.finishRequested {
                    self.needsDisplay = true
                    self.displayIfNeeded()
                }
            }
        }
        commandBuffer.commit()
    }

    private func nextOutputSurface(width: Int, height: Int) -> IOSurface? {
        let size = NSSize(width: width, height: height)
        if outputSurfaces.count != 3 || outputSurfaceSize != size {
            let bytesPerRow = ((width * 4 + 63) / 64) * 64
            let properties: [IOSurfacePropertyKey: Any] = [
                .width: width,
                .height: height,
                .bytesPerRow: bytesPerRow,
                .bytesPerElement: 4,
                .allocSize: bytesPerRow * height,
                .pixelFormat: kCVPixelFormatType_32BGRA
            ]
            outputSurfaces = (0..<3).compactMap { _ in IOSurface(properties: properties) }
            outputSurfaceSize = size
            outputSurfaceIndex = 0
        }
        guard !outputSurfaces.isEmpty else { return nil }
        let surface = outputSurfaces[outputSurfaceIndex % outputSurfaces.count]
        outputSurfaceIndex = (outputSurfaceIndex + 1) % outputSurfaces.count
        return surface
    }

    private func snapshot(of view: NSView, rect: NSRect) -> CIImage? {
        guard rect.width > 1, rect.height > 1 else { return nil }
        let windowScale = view.window?.backingScaleFactor ?? 1
        #if arch(arm64)
        // Apple Silicon has enough unified-memory bandwidth for a little extra
        // sampling detail. Intel keeps the short-lived effect at 1x: the wave is
        // intentionally soft, while avoiding 2.25x as many pixels prevents the
        // GPU from skipping frames on Retina displays.
        let preferredScale = min(max(windowScale, 1), 1.25)
        let candidateScales: [CGFloat] = preferredScale > 1.05
            ? [preferredScale, 1]
            : [1]
        #else
        let candidateScales: [CGFloat] = [Self.renderScale]
        #endif
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
                // deviceRGB — это собственное пространство подложки окна, то
                // же, в котором AppKit рисует живую сетку и «крайние» снимки.
                // calibratedRGB добавлял лишний круг «профиль дисплея →
                // generic RGB → рабочее пространство → профиль дисплея»: на
                // краях перехода снимок и живая сетка расходились по яркости
                // и насыщенности, и подмена одного другим читалась вспышкой.
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else { continue }
            representation.size = rect.size
            view.displayIfNeeded()
            view.cacheDisplay(in: rect, to: representation)
            if let image = representation.cgImage {
                // Метка обязана совпадать с тем, в чём пиксели нарисованы на
                // самом деле, иначе Core Image конвертирует их из неверного
                // пространства и все GPU-кадры уезжают по тону относительно
                // живой сетки. deviceRGB подложки — это профиль окна.
                return CIImage(
                    cgImage: image,
                    options: [.colorSpace: presentationColorSpace]
                )
            }
        }
        return nil
    }

    // Нативный снимок для «крайних» кадров перехода: bitmapImageRepForCachingDisplay
    // повторяет масштаб (Retina) и цветовое пространство подложки окна, поэтому
    // подмена живой сетки оверлеем и обратная передача неотличимы на глаз.
    private func holdSnapshot(of view: NSView, rect: NSRect) -> CGImage? {
        guard rect.width > 1, rect.height > 1 else { return nil }
        guard let representation = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        view.displayIfNeeded()
        view.cacheDisplay(in: rect, to: representation)
        return representation.cgImage
    }

    private static func gaussianBlurred(
        _ image: CIImage,
        boundsWidth: CGFloat,
        strength: CGFloat
    ) -> CIImage {
        // Тот же перевод точек в пиксели, что и в updateLayer: радиус размытия
        // должен уменьшаться вместе с разрешением снимка.
        let scale = image.extent.width / max(boundsWidth, 1)
        let radius = (4.5 + strength * 25.0) * scale
        let blurred = image
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: image.extent)
        // Materialise the Gaussian once. Keeping the filter graph as a sampler
        // made Core Image recompute two wide blurs for every animation frame.
        // A cached bitmap gives the custom kernel the same visual result with
        // four cheap texture reads instead.
        guard let bitmap = context.createCGImage(
            blurred,
            from: image.extent,
            format: .RGBA8,
            colorSpace: outputColorSpace
        ) else { return blurred }
        return CIImage(cgImage: bitmap, options: [.colorSpace: outputColorSpace])
    }

    /// Считает размытие вне главного потока и подставляет его, когда готово.
    ///
    /// `createCGImage` материализует Gaussian синхронно: два таких вызова на
    /// каждую навигацию (исходная папка и папка назначения) блокировали главный
    /// поток на десятки миллисекунд ровно в момент начала перехода — отсюда
    /// пропуск кадров тем чаще, чем быстрее листаешь.
    ///
    /// Подмена безопасна визуально: вклад размытия пропорционален
    /// `motion = pow(sin(π·progress), …)`, то есть в первых кадрах он ровно
    /// нулевой. Размытие успевает приехать задолго до того, как станет видимым.
    private func requestBlur(
        of image: CIImage,
        assign: @escaping (CIImage) -> Void
    ) {
        let boundsWidth = bounds.width
        let strength = CGFloat(FPPreferences.swipeWaveBlur)
        let generation = blurGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let blurred = Self.gaussianBlurred(
                image,
                boundsWidth: boundsWidth,
                strength: strength
            )
            DispatchQueue.main.async {
                guard let self, self.blurGeneration == generation else { return }
                assign(blurred)
                if !self.hasSwappedToDestinationHold, self.animationStartedAt != nil {
                    self.needsDisplay = true
                }
            }
        }
    }

    /// Кадры анимации должны выдаваться в такт обновлению экрана.
    ///
    /// Раньше здесь стоял `Timer` на 1/60 с допуском 1/240. Он не привязан к
    /// вертикальной синхронизации: часть кадров попадала в composite-окно
    /// раньше, часть позже, и волна шла рывками даже когда GPU успевал всё
    /// посчитать. На ProMotion-дисплее с плавающей частотой расхождение ещё
    /// заметнее. `CADisplayLink` выдаёт ровно один тик на кадр конкретного
    /// экрана, поэтому шаг анимации становится равномерным.
    private func startTimer() {
        if #available(macOS 14.0, *) {
            guard frameDisplayLink == nil else { return }
            let link = displayLink(target: self, selector: #selector(handleDisplayLinkTick))
            link.add(to: .main, forMode: .common)
            frameDisplayLink = link
            return
        }
        guard displayTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 1.0 / 240.0
        displayTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func handleDisplayLinkTick() {
        tick()
    }

    private func stopTimer() {
        if #available(macOS 14.0, *) {
            frameDisplayLink?.invalidate()
            frameDisplayLink = nil
        }
        displayTimer?.invalidate()
        displayTimer = nil
    }

    private func progress(for pulse: WavePulse, at now: CFTimeInterval, duration: Double) -> CGFloat {
        let elapsed = max(now - pulse.startedAt, 0)
        return min(max(CGFloat(elapsed / duration), 0), 1)
    }

    private func tick() {
        let now = CACurrentMediaTime()
        guard animationStartedAt != nil, !wavePulses.isEmpty else { return }
        let smoothness = FPPreferences.swipeWaveSmoothness
        let duration = min(1.15, FPPreferences.swipeWaveDuration * (0.76 + smoothness * 0.08))
        wavePulseProgresses = wavePulses.map { progress(for: $0, at: now, duration: duration) }
        guard let latestProgress = wavePulseProgresses.last else { return }
        let linear = Double(latestProgress)
        if let destinationReadyAt {
            let elapsed = max(now - destinationReadyAt, 0)
            destinationBlend = smoothStep(CGFloat(min(max(elapsed / 0.14, 0), 1)))
        } else {
            destinationBlend = 0
        }
        displayedProgress = latestProgress
        // Финальная передача кадра — трёхступенчатая и без единого скачка.
        // 1) Пока оверлей полностью непрозрачен, его контент коротким
        //    кроссфейдом подменяется нативным Retina-снимком папки назначения:
        //    остаточное смещение волны здесь < 1–2 px и растворяется в фейде.
        // 2) Под непрозрачным оверлеем восстанавливается живая сетка —
        //    попиксельно совпадающая с показанным снимком.
        // 3) Только затем оверлей плавно исчезает поверх идентичных пикселей.
        // Это убирает прежние скачки резкости и тона («мерцание папок»)
        // в момент завершения анимации.
        if linear >= 0.86, !hasSwappedToDestinationHold, let destinationHoldContents {
            hasSwappedToDestinationHold = true
            // Поздние GPU-кадры больше не должны перекрыть статичный снимок.
            renderGeneration += 1
            renderInFlight = false
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.12
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer?.add(fade, forKey: "holdFrameSwap")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = max(CGFloat(destinationHoldContents.width) / max(bounds.width, 1), 1)
            layer?.contents = destinationHoldContents
            CATransaction.commit()
        }
        // Prepare the real grid once while the GPU surface is still completely
        // opaque. Repeatedly changing an NSScrollView's alpha on every frame
        // makes AppKit rebuild its backing store and produces a one-frame flash
        // after the wave. Once the live grid has settled underneath, only the
        // single overlay layer fades away.
        if linear >= 0.86, !hasPreparedLiveViewsForHandoff {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (view, alpha) in zip(hiddenViews, hiddenViewAlphas) {
                view.alphaValue = alpha
            }
            CATransaction.commit()
            hasPreparedLiveViewsForHandoff = true
        }
        let exitBlend = smoothStep((CGFloat(linear) - 0.90) / 0.10)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        alphaValue = 1 - exitBlend
        CATransaction.commit()
        if !hasSwappedToDestinationHold {
            needsDisplay = true
            // A layer-backed view may coalesce repeated `needsDisplay` requests while
            // the same IOSurface is attached. Present every animation sample in this
            // run-loop turn so the surface actually advances instead of holding the
            // first snapshot until the transition completes.
            displayIfNeeded()
        }
        if linear >= 1 {
            finishRequested = true
            if hasSwappedToDestinationHold {
                // GPU-цепочка уже остановлена — завершаем переход напрямую.
                finishAnimation()
            } else {
                needsDisplay = true
                displayIfNeeded()
            }
        }
    }

    private func finishAnimation() {
        let completion = self.completion
        self.completion = nil
        hideImmediately()
        completion?()
    }

    private func hideImmediately() {
        stopTimer()
        renderGeneration += 1
        blurGeneration += 1
        renderInFlight = false
        finishRequested = false
        layer?.removeAllAnimations()
        alphaValue = 0
        isHidden = true
        restoreHiddenViews()
        sourceImage = nil
        destinationImage = nil
        previousDestinationImage = nil
        sourceBlurredImage = nil
        destinationBlurredImage = nil
        previousDestinationBlurredImage = nil
        layer?.contents = nil
        displayedProgress = 0
        animationStartedAt = nil
        destinationReadyAt = nil
        destinationCrossfadeStartedAt = nil
        destinationBlend = 0
        wavePulses.removeAll()
        wavePulseProgresses.removeAll()
        hasPresentedFirstGPUFrame = false
        hasPreparedLiveViewsForHandoff = false
        hasSwappedToDestinationHold = false
        sourceHoldContents = nil
        destinationHoldContents = nil
        completion = nil
        needsDisplay = true
    }

    private func restoreHiddenViews() {
        for (view, alpha) in zip(hiddenViews, hiddenViewAlphas) {
            view.alphaValue = alpha
        }
        hiddenViews.removeAll()
        hiddenViewAlphas.removeAll()
    }

    private func smoothStep(_ value: CGFloat) -> CGFloat {
        let x = min(max(value, 0), 1)
        return x * x * (3 - 2 * x)
    }

    private func colorVector(_ color: NSColor) -> CIVector {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        return CIVector(x: rgb.redComponent, y: rgb.greenComponent, z: rgb.blueComponent, w: rgb.alphaComponent)
    }
}
