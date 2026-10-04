import AppKit
import AVFoundation

/// A click on the Force Touch trackpad.
public enum HapticTick {
    @MainActor
    public static func perform(_ strength: HapticStrength) {
        let performer = NSHapticFeedbackManager.defaultPerformer
        switch strength {
        case .light: performer.perform(.levelChange, performanceTime: .now)
        case .medium: performer.perform(.alignment, performanceTime: .now)
        case .strong: performer.perform(.generic, performanceTime: .now)
        case .double:
            performer.perform(.generic, performanceTime: .now)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) { performer.perform(.generic, performanceTime: .now) }
        }
    }
}

/// A short synthesized whoosh: filtered noise with a sweeping low-pass and a smooth envelope.
/// Nothing is loaded from disk.
public final class Whoosh {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffer: AVAudioPCMBuffer?

    public init?() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let seconds = 0.26
        let frames = AVAudioFrameCount(format.sampleRate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        var noise = SystemRandomNumberGenerator()
        var low: Float = 0
        let samples = buffer.floatChannelData![0]
        for index in 0..<Int(frames) {
            let t = Double(index) / Double(frames)
            let envelope = Float(pow(sin(Double.pi * t), 1.6))
            let cutoff = 7000.0 * pow(0.08, t) + 300        // Hz, sweeping down
            let alpha = Float(1 - exp(-2 * Double.pi * cutoff / format.sampleRate))
            let white = Float.random(in: -1...1, using: &noise)
            low += alpha * (white - low)
            samples[index] = low * envelope * 0.22
        }
        self.buffer = buffer
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    public func play() {
        guard let buffer else { return }
        if !engine.isRunning { try? engine.start() }
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
    }

    public func stop() {
        player.stop()
        engine.stop()
    }
}

/// A small capsule naming the destination, above the overlay, that fades out on its own.
@MainActor
public final class PillWindow {
    private let panel: NSPanel
    private let background = CALayer()
    private let text = CATextLayer()
    private var hideWork: DispatchWorkItem?

    public init(screen: NSScreen) {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: 3)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.addSublayer(background)
        background.addSublayer(text)
        background.backgroundColor = CGColor(gray: 0.08, alpha: 0.72)
        background.cornerRadius = 15
        background.borderColor = CGColor(gray: 1, alpha: 0.12)
        background.borderWidth = 1
        background.opacity = 0
        text.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        text.fontSize = 13
        text.foregroundColor = CGColor(gray: 1, alpha: 0.95)
        text.alignmentMode = .center
        text.contentsScale = screen.backingScaleFactor
        panel.contentView = view
        update(screen: screen)
    }

    public func update(screen: NSScreen) {
        let size = NSSize(width: 220, height: 30)
        let origin = NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.minY + 56)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        background.frame = CGRect(origin: .zero, size: size)
        text.frame = CGRect(x: 0, y: 7, width: size.width, height: 18)
        text.contentsScale = screen.backingScaleFactor
    }

    public func show(_ label: String, for duration: Double) {
        hideWork?.cancel()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        text.string = label
        CATransaction.commit()
        panel.orderFrontRegardless()
        animate(opacity: 1, duration: 0.12)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            animate(opacity: 0, duration: 0.25)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.background.opacity == 0 else { return }
                self.panel.orderOut(nil)
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func animate(opacity: Float, duration: Double) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = background.presentation()?.opacity ?? background.opacity
        fade.toValue = opacity
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        background.opacity = opacity
        background.add(fade, forKey: "opacity")
        CATransaction.commit()
    }
}
