import QuartzCore

/// Builds Core Animation animations that all share one duration and one timing.
public struct AnimationTiming: Sendable {
    public var duration: Double
    public var easing: EasingPreset
    public var bounce: Double

    public init(duration: Double, easing: EasingPreset, bounce: Double) {
        self.duration = duration
        self.easing = easing
        self.bounce = bounce
    }

    public init(settings: SpacewalkSettings, slowMotion: Double = 1) {
        self.init(duration: settings.duration * slowMotion, easing: settings.easing, bounce: settings.bounce)
    }

    /// The wall-clock time the animation takes, including a spring's settling tail.
    public var totalDuration: Double {
        easing == .spring ? duration * (1 + bounce) : duration
    }

    public func animation(keyPath: String, from: Any?, to: Any?) -> CAPropertyAnimation {
        let animation: CAPropertyAnimation
        if easing == .spring {
            let spring = CASpringAnimation(perceptualDuration: duration, bounce: bounce)
            spring.keyPath = keyPath
            spring.duration = spring.settlingDuration
            animation = spring
        } else {
            let basic = CABasicAnimation(keyPath: keyPath)
            basic.duration = duration
            if let (x1, y1, x2, y2) = easing.controlPoints {
                basic.timingFunction = CAMediaTimingFunction(controlPoints: x1, y1, x2, y2)
            }
            animation = basic
        }
        if let basic = animation as? CABasicAnimation {
            basic.fromValue = from
            basic.toValue = to
        }
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        return animation
    }

    /// Keyframes sampled along the eased progress curve, for properties Core Animation cannot
    /// interpolate well on its own (3D transforms). `value` receives eased progress in 0...1.
    public func keyframes(keyPath: String, frames: Int, value: (CGFloat) -> Any) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        let count = max(2, frames)
        animation.values = (0..<count).map { value(CGFloat(progress(Double($0) / Double(count - 1)))) }
        animation.keyTimes = (0..<count).map { NSNumber(value: Double($0) / Double(count - 1)) }
        animation.calculationMode = .linear
        animation.duration = duration
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        return animation
    }

    /// Eased progress for a time fraction, matching the preset curve. Springs settle without overshoot here.
    public func progress(_ time: Double) -> Double {
        let t = min(1, max(0, time))
        guard let (x1, y1, x2, y2) = easing.controlPoints else {
            return 1 - pow(1 - t, 3)
        }
        return AnimationTiming.cubicBezier(Double(x1), Double(y1), Double(x2), Double(y2), at: t)
    }

    /// y for a given x on a CSS-style cubic bezier, by bisection.
    static func cubicBezier(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, at x: Double) -> Double {
        func point(_ s: Double, _ a: Double, _ b: Double) -> Double {
            3 * (1 - s) * (1 - s) * s * a + 3 * (1 - s) * s * s * b + s * s * s
        }
        var low = 0.0, high = 1.0, s = x
        for _ in 0..<40 {
            let px = point(s, x1, x2)
            if abs(px - x) < 1e-6 { break }
            if px < x { low = s } else { high = s }
            s = (low + high) / 2
        }
        return point(s, y1, y2)
    }

    /// A plain keyframe over the shared duration, for opacity ramps that must not bounce.
    public func keyframes(keyPath: String, values: [Any], times: [NSNumber]) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = times
        animation.duration = totalDuration
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return animation
    }
}
