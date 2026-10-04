import QuartzCore
import Foundation

/// Core Animation adds a 250 ms fade to every property change by default. Nothing in the stage
/// may animate unless we add the animation ourselves, so every layer gets this delegate.
final class NoImplicitAnimations: NSObject, CALayerDelegate {
    static let shared = NoImplicitAnimations()
    func action(for layer: CALayer, forKey event: String) -> CAAction? { NSNull() }
}

/// One workspace image plus the layers needed to move, clip, dim, blur and shadow it.
final class ContentGroup {
    /// Receives transforms, opacity, shadow. Never clips.
    let outer = CALayer()
    /// Clips to rounded corners and hosts the filters.
    let inner = CALayer()
    let wallpaper = CALayer()
    let content = CALayer()
    /// Live frames fade in here over a predicted `content`, so a stale prediction never pops.
    let live = CALayer()
    let dim = CALayer()

    init() {
        for layer in [outer, inner, wallpaper, content, live, dim] { layer.delegate = NoImplicitAnimations.shared }
        outer.addSublayer(inner)
        inner.addSublayer(wallpaper)
        inner.addSublayer(content)
        inner.addSublayer(live)
        inner.addSublayer(dim)
        // Clipping forces an offscreen pass over the whole card every frame; only rounded cards pay it.
        inner.masksToBounds = false
        for layer in [wallpaper, content, live] {
            layer.contentsGravity = .resize
            // Linear, not trilinear: trilinear rebuilds mipmaps of a 50 MB surface on every content swap.
            layer.minificationFilter = .linear
            layer.magnificationFilter = .linear
        }
        wallpaper.isOpaque = true
        outer.allowsEdgeAntialiasing = true
        inner.allowsEdgeAntialiasing = true
        dim.backgroundColor = CGColor(gray: 0, alpha: 1)
        dim.opacity = 0
        outer.shadowColor = CGColor(gray: 0, alpha: 1)
        outer.shadowRadius = 30
        outer.shadowOffset = .zero
        outer.shadowOpacity = 0
        reset()
    }

    func layout(_ bounds: CGRect) {
        for layer in [outer, inner, wallpaper, content, live, dim] {
            layer.frame = bounds
        }
        outer.shadowPath = CGPath(rect: bounds, transform: nil)
    }

    func reset() {
        for layer in [outer, inner, wallpaper, content, live, dim] {
            layer.removeAllAnimations()
        }
        live.contents = nil
        live.opacity = 0
        outer.transform = CATransform3DIdentity
        outer.opacity = 1
        outer.zPosition = 0
        outer.anchorPointZ = 0
        outer.shadowOpacity = 0
        outer.isHidden = false
        inner.cornerRadius = 0
        dim.opacity = 0
        if let path = outer.shadowPath {
            outer.shadowPath = CGPath(rect: path.boundingBox, transform: nil)
        }
    }

    func round(_ radius: CGFloat) {
        inner.cornerRadius = radius
        inner.masksToBounds = radius > 0
        outer.shadowPath = CGPath(roundedRect: inner.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
}

/// The layer tree that renders a transition. The overlay window and the settings preview both host one.
public final class TransitionStage {
    public let root = CALayer()
    private let base = CALayer()
    /// The destination's wallpaper, crossfaded over `base` by the parallax and still modes of slide.
    private let baseIncoming = CALayer()
    /// Holds the two pictures. Perspective lives here, so the wallpaper underneath is never sorted
    /// or projected with them: Core Animation orders 3D-transformed siblings by depth, and a face
    /// whose centre sits behind the screen would otherwise vanish under the wallpaper.
    private let scene = CALayer()
    private let outgoing = ContentGroup()
    private let incoming = ContentGroup()
    private var generation = 0

    public var size: CGSize {
        didSet { layout() }
    }

    public init(size: CGSize) {
        self.size = size
        root.delegate = NoImplicitAnimations.shared
        base.delegate = NoImplicitAnimations.shared
        baseIncoming.delegate = NoImplicitAnimations.shared
        scene.delegate = NoImplicitAnimations.shared
        root.masksToBounds = true
        for layer in [base, baseIncoming] {
            layer.isOpaque = true
            layer.contentsGravity = .resize
            layer.minificationFilter = .linear
        }
        baseIncoming.opacity = 0
        root.addSublayer(base)
        root.addSublayer(baseIncoming)
        root.addSublayer(scene)
        scene.addSublayer(outgoing.outer)
        scene.addSublayer(incoming.outer)
        layout()
        incoming.outer.isHidden = true
    }

    private func layout() {
        let bounds = CGRect(origin: .zero, size: size)
        root.frame = bounds
        base.frame = bounds
        baseIncoming.frame = bounds
        scene.frame = bounds
        outgoing.layout(bounds)
        incoming.layout(bounds)
    }

    private var wallpapersDiffer = false

    /// One wallpaper per side (CGImage or IOSurface); the incoming one also fills the gaps behind the pictures.
    public func setWallpapers(outgoing outgoingImage: AnyObject?, incoming incomingImage: AnyObject?) {
        base.contents = outgoingImage ?? incomingImage
        baseIncoming.contents = incomingImage ?? outgoingImage
        outgoing.wallpaper.contents = outgoingImage
        incoming.wallpaper.contents = incomingImage ?? outgoingImage
        wallpapersDiffer = outgoingImage != nil && incomingImage != nil && outgoingImage !== incomingImage
    }

    public func setWallpaper(_ image: AnyObject?) { setWallpapers(outgoing: image, incoming: image) }

    public func setOutgoing(_ contents: Any?) { outgoing.content.contents = contents }
    public func setIncoming(_ contents: Any?) { incoming.content.contents = contents }

    /// Same as `setIncomingLive`, for the picture shown at rest (arriving from the overview).
    public func setOutgoingLive(_ contents: Any?, fadeIn: Double) {
        fadeLive(outgoing, contents: contents, fadeIn: fadeIn)
    }

    /// The first live frame fades in over whatever the incoming card showed so far; later ones replace it.
    public func setIncomingLive(_ contents: Any?, fadeIn: Double) {
        fadeLive(incoming, contents: contents, fadeIn: fadeIn)
    }

    private func fadeLive(_ group: ContentGroup, contents: Any?, fadeIn: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        group.live.contents = contents
        if group.live.opacity < 1 {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = max(0.001, fadeIn)
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.live.opacity = 1
            group.live.add(fade, forKey: "opacity")
        }
        CATransaction.commit()
    }

    /// Show the outgoing frame at rest, nothing else. Called before the workspace actually changes.
    public func showResting() {
        generation += 1
        root.removeAllAnimations()
        root.speed = 1
        root.timeOffset = 0
        scene.sublayerTransform = CATransform3DIdentity
        for layer in [base, baseIncoming] {
            layer.removeAllAnimations()
            layer.transform = CATransform3DIdentity
        }
        baseIncoming.opacity = 0
        outgoing.reset()
        incoming.reset()
        incoming.outer.isHidden = true
        outgoing.wallpaper.isHidden = true
        incoming.wallpaper.isHidden = true
        base.isHidden = false
    }

    public func clear() {
        showResting()
        setOutgoing(nil)
        setIncoming(nil)
    }

    // MARK: Scrubbing (finger-driven transitions)

    private let scrubDuration: Double = 1

    /// Freezes the stage's clock and lays the transition out as a one-second linear animation, so
    /// `scrub(_:)` can place it at any progress. Call `showResting()` to leave this mode.
    public func beginScrub(settings: SpacewalkSettings, direction: Direction) {
        showResting()
        root.speed = 0
        root.timeOffset = 0
        var linear = settings
        linear.easing = .linear
        run(settings: linear, direction: direction, timing: AnimationTiming(duration: scrubDuration, easing: .linear, bounce: 0)) {}
    }

    /// Progress 0...1 along the frozen transition.
    public func scrub(_ progress: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.timeOffset = min(1, max(0, progress)) * scrubDuration
        CATransaction.commit()
    }

    /// Plays the transition. `completion` runs on the main thread when the last animation ends,
    /// unless a newer transition replaced this one first.
    public func run(settings: SpacewalkSettings, direction: Direction, timing: AnimationTiming, completion: @escaping () -> Void) {
        showResting()
        generation += 1
        let myGeneration = generation

        let horizontal = settings.orientation == .horizontal
        let axis = horizontal ? "transform.translation.x" : "transform.translation.y"
        let length = horizontal ? size.width : size.height
        // Forward: the new workspace enters from the right, or from below.
        let travel = (horizontal ? length : -length) * direction.sign
        let radius = CGFloat(settings.cornerRadius)
        // Plain slide can leave the wallpaper still because the two pictures never overlap. Every
        // other effect stacks them, so each side must be a full opaque picture: windows over wallpaper.
        let opaqueCards = settings.effect.needsOpaqueCards || settings.wallpaperMode == .moves
        outgoing.wallpaper.isHidden = !opaqueCards
        incoming.wallpaper.isHidden = !opaqueCards
        incoming.outer.isHidden = false

        var animations: [(CALayer, CAAnimation, String)] = []
        func add(_ layer: CALayer, _ keyPath: String, _ from: Double, _ to: Double) {
            animations.append((layer, timing.animation(keyPath: keyPath, from: from, to: to), keyPath))
        }

        /// Row-vector order: scale about the centre, then move along the axis.
        func card(offset: CGFloat, scale: CGFloat) -> CATransform3D {
            let move = horizontal ? CATransform3DMakeTranslation(offset, 0, 0) : CATransform3DMakeTranslation(0, offset, 0)
            return CATransform3DConcat(CATransform3DMakeScale(scale, scale, 1), move)
        }
        func keyframes(_ layer: CALayer, _ keyPath: String, _ value: @escaping (CGFloat) -> Any) {
            animations.append((layer, timing.keyframes(keyPath: keyPath, frames: 60, value: value), keyPath))
        }

        switch settings.effect {
        case .instant:
            break

        case .tilt:
            // Cards slide like a strip but lean into the motion, with perspective: the leaving card
            // turns away as it goes, the arriving one straightens as it lands.
            var perspective = CATransform3DIdentity
            perspective.m34 = -1 / (length * 2.2)
            scene.sublayerTransform = perspective
            outgoing.round(radius)
            incoming.round(radius)
            outgoing.outer.shadowOpacity = 0.35
            incoming.outer.shadowOpacity = 0.35
            let lean = CGFloat.pi / 180 * 22 * CGFloat(direction.sign) * (horizontal ? -1 : 1)
            let axisX: CGFloat = horizontal ? 0 : 1
            let axisY: CGFloat = horizontal ? 1 : 0
            func leaning(offset: CGFloat, angle: CGFloat) -> CATransform3D {
                CATransform3DConcat(CATransform3DMakeRotation(angle, axisX, axisY, 0), card(offset: offset, scale: 1))
            }
            keyframes(outgoing.outer, "transform") { p in NSValue(caTransform3D: leaning(offset: -travel * p, angle: lean * p)) }
            keyframes(incoming.outer, "transform") { p in NSValue(caTransform3D: leaning(offset: travel * (1 - p), angle: -lean * (1 - p))) }
            add(incoming.inner, "cornerRadius", radius, 0)
            add(outgoing.inner, "cornerRadius", 0, radius)

        case .carousel:
            // Both cards shrink to 85%, slide past each other and grow back, like an app switcher.
            outgoing.round(radius)
            incoming.round(radius)
            incoming.outer.zPosition = 1
            let dip = 1 - CGFloat(settings.depthScale)
            keyframes(outgoing.outer, "transform") { p in NSValue(caTransform3D: card(offset: -travel * p, scale: 1 - dip * sin(.pi * p))) }
            keyframes(incoming.outer, "transform") { p in NSValue(caTransform3D: card(offset: travel * (1 - p), scale: 1 - dip * sin(.pi * p))) }
            add(incoming.inner, "cornerRadius", radius, 0)
            add(outgoing.inner, "cornerRadius", 0, radius)

        case .flip:
            // The old picture turns edge-on about the screen centre in the first half, the new one
            // turns in from edge-on in the second half: a card flipping over.
            var perspective = CATransform3DIdentity
            perspective.m34 = -1 / (length * 1.5)
            scene.sublayerTransform = perspective
            let axisX: CGFloat = horizontal ? 0 : 1
            let axisY: CGFloat = horizontal ? 1 : 0
            let quarter = CGFloat.pi / 2 * CGFloat(direction.sign) * (horizontal ? 1 : -1)
            keyframes(outgoing.outer, "transform") { p in NSValue(caTransform3D: CATransform3DMakeRotation(-quarter * min(1, 2 * p), axisX, axisY, 0)) }
            keyframes(incoming.outer, "transform") { p in NSValue(caTransform3D: CATransform3DMakeRotation(quarter * (1 - max(0, 2 * p - 1)), axisX, axisY, 0)) }
            keyframes(outgoing.outer, "opacity") { p in NSNumber(value: p < 0.5 ? 1.0 : 0.0) }
            keyframes(incoming.outer, "opacity") { p in NSNumber(value: p < 0.5 ? 0.0 : 1.0) }
            keyframes(outgoing.dim, "opacity") { p in NSNumber(value: Double(min(1, 2 * p)) * settings.dimAmount) }
            keyframes(incoming.dim, "opacity") { p in NSNumber(value: Double(1 - max(0, 2 * p - 1)) * settings.dimAmount) }

        case .swap:
            // The two cards trade places: the old one shrinks into the background on one side while
            // the new one grows in on the other, passing in front.
            outgoing.round(radius)
            incoming.round(radius)
            incoming.outer.zPosition = 1
            incoming.outer.shadowOpacity = 0.45
            let small = CGFloat(settings.depthScale) - 0.1
            keyframes(outgoing.outer, "transform") { p in NSValue(caTransform3D: card(offset: -travel * 0.5 * p, scale: 1 - (1 - small) * p)) }
            keyframes(incoming.outer, "transform") { p in NSValue(caTransform3D: card(offset: travel * 0.5 * (1 - p), scale: small + (1 - small) * p)) }
            add(outgoing.dim, "opacity", 0, settings.dimAmount)
            add(incoming.inner, "cornerRadius", radius, 0)
            add(outgoing.inner, "cornerRadius", 0, radius)

        case .reveal:
            // The old picture slides off and uncovers the new one, which was waiting underneath.
            outgoing.round(radius)
            incoming.round(radius)
            outgoing.outer.zPosition = 1
            outgoing.outer.shadowOpacity = 0.5
            add(outgoing.outer, axis, 0, -travel)
            add(incoming.outer, "transform.scale", settings.depthScale, 1)
            add(incoming.dim, "opacity", settings.dimAmount, 0)
            add(incoming.inner, "cornerRadius", radius, 0)

        case .slide:
            add(outgoing.outer, axis, 0, -travel)
            add(incoming.outer, axis, travel, 0)
            if !opaqueCards {
                // The wallpaper stays behind the windows. Parallax lets it drift a little, scaled up
                // so no edge is ever uncovered; a crossfade brings in the destination's wallpaper.
                let drift: CGFloat = settings.wallpaperMode == .parallax ? 0.075 : 0
                let grow = 1 + 2 * drift
                for layer in [base, baseIncoming] { layer.transform = CATransform3DMakeScale(grow, grow, 1) }
                if drift > 0 {
                    keyframes(base, "transform") { p in NSValue(caTransform3D: card(offset: -travel * drift * p, scale: grow)) }
                    keyframes(baseIncoming, "transform") { p in NSValue(caTransform3D: card(offset: travel * drift * (1 - p), scale: grow)) }
                }
                if wallpapersDiffer || drift > 0 {
                    add(baseIncoming, "opacity", 0, 1)
                }
            }

        case .depth:
            incoming.outer.zPosition = 1
            outgoing.round(radius)
            incoming.round(radius)
            incoming.outer.shadowOpacity = 0.45
            add(outgoing.outer, axis, 0, -travel * settings.parallax)
            add(outgoing.outer, "transform.scale", 1, settings.depthScale)
            add(outgoing.dim, "opacity", 0, settings.dimAmount)
            add(incoming.outer, axis, travel, 0)
            add(incoming.inner, "cornerRadius", radius, 0)

        case .fade:
            // The incoming picture fades in on top of an outgoing one that stays opaque, so the
            // wallpaper never shows through mid-way.
            incoming.outer.zPosition = 1
            let forward = direction == .forward
            add(incoming.outer, "opacity", 0, 1)
            add(outgoing.outer, "transform.scale", 1, forward ? 1.03 : 0.97)
            add(incoming.outer, "transform.scale", forward ? 0.96 : 1.04, 1)

        case .zoom:
            incoming.outer.zPosition = 1
            let forward = direction == .forward
            outgoing.round(radius)
            incoming.round(radius)
            add(outgoing.outer, "transform.scale", 1, forward ? 1.12 : settings.depthScale)
            add(outgoing.dim, "opacity", 0, settings.dimAmount)
            add(incoming.outer, "transform.scale", forward ? settings.depthScale : 1.12, 1)
            add(incoming.outer, "opacity", 0, 1)
            add(incoming.inner, "cornerRadius", radius, 0)

        case .cube:
            // Each picture is a face of a cube whose axis runs half an edge behind the screen. The
            // rotation is written out as explicit keyframes with the easing baked in, which keeps the
            // maths under our control instead of Core Animation's transform interpolation.
            var perspective = CATransform3DIdentity
            perspective.m34 = -1 / (length * 1.8)
            scene.sublayerTransform = perspective
            let half = length / 2
            let sign = CGFloat(direction.sign)
            let axisX: CGFloat = horizontal ? 0 : 1
            let axisY: CGFloat = horizontal ? 1 : 0
            let flip: CGFloat = horizontal ? 1 : -1
            func face(_ angle: CGFloat) -> CATransform3D {
                // Move the pivot half an edge back, rotate, move back: the front face stays on screen.
                let back = CATransform3DMakeTranslation(0, 0, half)
                let rotation = CATransform3DMakeRotation(angle, axisX, axisY, 0)
                return CATransform3DConcat(CATransform3DConcat(back, rotation), CATransform3DMakeTranslation(0, 0, -half))
            }
            let quarter = CGFloat.pi / 2 * sign * flip
            animations.append((outgoing.outer, timing.keyframes(keyPath: "transform", frames: 60) { NSValue(caTransform3D: face(-quarter * $0)) }, "transform"))
            animations.append((incoming.outer, timing.keyframes(keyPath: "transform", frames: 60) { NSValue(caTransform3D: face(quarter * (1 - $0))) }, "transform"))
            add(outgoing.dim, "opacity", 0, settings.dimAmount)
            add(incoming.dim, "opacity", settings.dimAmount, 0)

        case .stack:
            outgoing.round(radius)
            incoming.round(radius)
            if direction == .forward {
                incoming.outer.zPosition = 1
                incoming.outer.shadowOpacity = 0.5
                add(incoming.outer, axis, travel, 0)
                add(incoming.inner, "cornerRadius", radius, 0)
                add(outgoing.outer, "transform.scale", 1, settings.depthScale)
                add(outgoing.dim, "opacity", 0, settings.dimAmount)
            } else {
                outgoing.outer.zPosition = 1
                outgoing.outer.shadowOpacity = 0.5
                add(outgoing.outer, axis, 0, -travel)
                add(incoming.outer, "transform.scale", settings.depthScale, 1)
                add(incoming.dim, "opacity", settings.dimAmount, 0)
                add(incoming.inner, "cornerRadius", radius, 0)
            }
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.generation == myGeneration else { return }
            completion()
        }
        for (layer, animation, key) in animations {
            layer.add(animation, forKey: key)
        }
        CATransaction.commit()
    }
}
