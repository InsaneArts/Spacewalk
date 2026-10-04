import AppKit
import Metal
import QuartzCore
import SpacewalkCore

/// Renders the current effect offscreen with Core Animation's own renderer, one PNG per sampled
/// moment, so a transition can be inspected frame by frame without a screen or permissions.
enum FrameRenderer {
    @MainActor
    static func render(settings: SpacewalkSettings, to directory: String, fullSize: Bool = false, scrub: Bool = false,
                       frameCount: Int? = nil, size requested: CGSize? = nil, backward: Bool = false) -> String {
        // Five moments by default; `frameCount` samples the whole run evenly instead (for a showreel).
        let fractions: [Double] = frameCount.map { count in (0..<count).map { Double($0) / Double(max(1, count - 1)) } }
            ?? [0.05, 0.15, 0.3, 0.5, 0.75]
        let frames = fractions.count
        let size = requested ?? (fullSize ? (NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)) : CGSize(width: 640, height: 360))
        guard let scene = MockWorkspace.render(size: size, scale: 1) else { return "mock content failed" }
        // Forward goes from Space 1 to Space 2; backward returns, so a showreel can alternate without a cut.
        let images = backward ? (scene.wallpaperSecond, scene.wallpaperFirst, scene.second, scene.first)
                              : (scene.wallpaperFirst, scene.wallpaperSecond, scene.first, scene.second)
        let direction: Direction = backward ? Direction.forward.flipped : .forward
        guard let device = MTLCreateSystemDefaultDevice() else { return "no Metal device" }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(size.width), height: Int(size.height), mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return "no texture" }

        let stage = TransitionStage(size: size)
        stage.setWallpapers(outgoing: images.0, incoming: images.1)
        stage.setOutgoing(images.2)
        stage.setIncoming(images.3)
        let renderer = CARenderer(mtlTexture: texture, options: nil)
        renderer.layer = stage.root
        renderer.bounds = CGRect(origin: .zero, size: size)

        // CARenderer evaluates animations against the wall clock, whatever time beginFrame is
        // given and whatever the root layer's speed says. So the run is slowed until every sampled
        // moment is at least 120 ms apart, and each frame is captured when its moment arrives.
        // `scrub` plays the effect linearly, for frames a caller re-times itself.
        let spacing = 0.12
        let timing: AnimationTiming
        if scrub {
            timing = AnimationTiming(duration: Double(frames) * spacing, easing: .linear, bounce: 0)
        } else {
            let slow = max(1, Double(frames) * spacing / max(0.01, settings.duration))
            timing = AnimationTiming(settings: settings, slowMotion: slow)
        }
        var played = settings
        if scrub { played.easing = .linear }
        stage.run(settings: played, direction: direction, timing: timing) {}
        CATransaction.flush()
        let start = CACurrentMediaTime()

        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: Int(size.width * size.height) * 4)
        var renderMs: [Double] = []
        var lateMs = 0.0
        for index in 0..<frames {
            let due = start + fractions[index] * timing.totalDuration
            while CACurrentMediaTime() < due { usleep(500) }
            let clock = CACurrentMediaTime()
            lateMs = max(lateMs, (clock - due) * 1000)
            renderer.beginFrame(atTime: clock, timeStamp: nil)
            renderer.addUpdate(renderer.bounds)
            renderer.render()
            renderer.endFrame()
            // CARenderer gives no completion handle; let the GPU finish before reading the texture back.
            if let queue = device.makeCommandQueue(), let buffer = queue.makeCommandBuffer() {
                buffer.commit()
                buffer.waitUntilCompleted()
            }
            usleep(8_000)
            renderMs.append((CACurrentMediaTime() - clock) * 1000)
            texture.getBytes(&bytes, bytesPerRow: Int(size.width) * 4, from: MTLRegionMake2D(0, 0, Int(size.width), Int(size.height)), mipmapLevel: 0)
            guard let context = CGContext(data: &bytes, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: Int(size.width) * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                  let image = context.makeImage(),
                  let data = NSBitmapImageRep(cgImage: Self.flipped(image) ?? image).representation(using: .png, properties: [:]) else { continue }
            try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(String(format: "%@%@_%02d.png", settings.effect.rawValue, scrub ? "_scrub" : "", index)))
        }
        stage.showResting()
        let times = renderMs.map { String(format: "%.1f", $0) }.joined(separator: " ")
        return "rendered \(frames) frames of \(settings.effect.rawValue) at \(Int(size.width))x\(Int(size.height)) to \(directory) over \(String(format: "%.1f", timing.totalDuration)) s (worst capture lag \(String(format: "%.0f", lateMs)) ms); render+sync ms per frame: \(times)"
    }

    /// Metal textures start at the top-left and Core Animation draws from the bottom-left, so the
    /// readback is upside down. Flip it once so the PNGs look like the screen.
    private static func flipped(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}
