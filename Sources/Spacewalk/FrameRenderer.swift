import AppKit
import Metal
import QuartzCore
import SpacewalkCore

/// Renders the current effect offscreen with Core Animation's own renderer, one PNG per sampled
/// moment, so a transition can be inspected frame by frame without a screen or permissions.
enum FrameRenderer {
    @MainActor
    static func render(settings: SpacewalkSettings, to directory: String, fullSize: Bool = false, scrub: Bool = false, frameCount: Int? = nil) -> String {
        // Five moments by default; `frameCount` samples the whole run evenly instead (for a showreel).
        let fractions: [Double] = frameCount.map { count in (0..<count).map { Double($0) / Double(max(1, count - 1)) } }
            ?? [0.05, 0.15, 0.3, 0.5, 0.75]
        let frames = fractions.count
        let size = fullSize ? (NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)) : CGSize(width: 640, height: 360)
        guard let images = MockWorkspace.render(size: size, scale: 1) else { return "mock content failed" }
        guard let device = MTLCreateSystemDefaultDevice() else { return "no Metal device" }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(size.width), height: Int(size.height), mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return "no texture" }

        let stage = TransitionStage(size: size)
        stage.setWallpaper(images.0)
        stage.setOutgoing(images.1)
        stage.setIncoming(images.2)
        let renderer = CARenderer(mtlTexture: texture, options: nil)
        renderer.layer = stage.root
        renderer.bounds = CGRect(origin: .zero, size: size)

        let timing = AnimationTiming(settings: settings)
        let start = CACurrentMediaTime()
        if scrub {
            stage.beginScrub(settings: settings, direction: .forward)
        } else {
            stage.run(settings: settings, direction: .forward, timing: timing) {}
        }
        CATransaction.flush()

        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: Int(size.width * size.height) * 4)
        var renderMs: [Double] = []
        for index in 0..<frames {
            let time = scrub ? CACurrentMediaTime() : start + fractions[index] * timing.totalDuration
            if scrub {
                stage.scrub(fractions[index])
                CATransaction.flush()
            }
            let clock = CACurrentMediaTime()
            renderer.beginFrame(atTime: time, timeStamp: nil)
            renderer.addUpdate(renderer.bounds)
            renderer.render()
            renderer.endFrame()
            // CARenderer gives no completion handle; let the GPU finish before reading the texture back.
            if let queue = device.makeCommandQueue(), let buffer = queue.makeCommandBuffer() {
                buffer.commit()
                buffer.waitUntilCompleted()
            }
            renderMs.append((CACurrentMediaTime() - clock) * 1000)
            usleep(40_000)
            texture.getBytes(&bytes, bytesPerRow: Int(size.width) * 4, from: MTLRegionMake2D(0, 0, Int(size.width), Int(size.height)), mipmapLevel: 0)
            guard let context = CGContext(data: &bytes, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: Int(size.width) * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                  let image = context.makeImage(),
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { continue }
            try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(String(format: "%@%@_%02d.png", settings.effect.rawValue, scrub ? "_scrub" : "", index)))
        }
        let times = renderMs.map { String(format: "%.1f", $0) }.joined(separator: " ")
        return "rendered \(frames) frames of \(settings.effect.rawValue) at \(Int(size.width))x\(Int(size.height)) to \(directory); render+sync ms per frame: \(times)"
    }
}
