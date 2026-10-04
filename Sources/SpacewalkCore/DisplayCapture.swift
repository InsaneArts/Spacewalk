import AppKit
import ScreenCaptureKit
import CoreMedia
import IOSurface
import os

public struct CapturedFrame: @unchecked Sendable {
    public let surface: IOSurface
    let pixelBuffer: CVPixelBuffer
    /// Arrival time in the CACurrentMediaTime() domain. Always later than the screen state it shows,
    /// so a frame that arrived after a switch command returned reflects that switch.
    public let time: Double
    /// Share of the screen that changed since the previous frame, 0...1. 1 when unknown.
    public let changedFraction: Double
}

public enum CaptureAccess {
    public static var granted: Bool { CGPreflightScreenCaptureAccess() }
    /// Shows the system prompt once; later calls only return the current state.
    @discardableResult
    public static func request() -> Bool { CGRequestScreenCaptureAccess() }
}

/// Keeps a ScreenCaptureKit stream open for one display so the latest frame is always at hand.
/// The stream sees app windows only: the menu bar, Dock, panels, wallpaper and this process are excluded.
public final class DisplayCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public let displayID: CGDirectDisplayID
    public private(set) var pointSize: CGSize
    public private(set) var scale: CGFloat
    public private(set) var frameInterval: Double
    /// Wallpaper of the space that was current at the last refresh, as an IOSurface for zero-copy display.
    public private(set) var wallpaper: IOSurface?
    private var wallpapers: [UInt64: (surface: IOSurface, time: Double)] = [:]
    /// The windows-only picture of a Space as it looked when we last left it, newest first.
    private var lastSeen: [(space: UInt64, surface: IOSurface, time: Double)] = []
    private static let lastSeenLimit = 3
    public private(set) var isRunning = false
    public private(set) var lastError: String?

    private var stream: SCStream?
    private var display: SCDisplay?
    private let lock = NSLock()
    private var latest: CapturedFrame?
    private var waiters: [(after: Double, resume: (CapturedFrame?) -> Void)] = []
    private let outputQueue = DispatchQueue(label: "dev.tgomareli.spacewalk.capture", qos: .userInteractive)
    private var refreshTask: Task<Void, Never>?
    private let log = Logger(subsystem: "dev.tgomareli.spacewalk", category: "capture")

    public init(screen: NSScreen) {
        displayID = screen.displayID
        pointSize = screen.frame.size
        scale = screen.backingScaleFactor
        frameInterval = 1.0 / Double(max(screen.maximumFramesPerSecond, 30))
        super.init()
    }

    public func update(screen: NSScreen) {
        pointSize = screen.frame.size
        scale = screen.backingScaleFactor
        frameInterval = 1.0 / Double(max(screen.maximumFramesPerSecond, 30))
    }

    // MARK: Lifecycle

    public func start() async {
        guard !isRunning else { return }
        do {
            let (display, filter, _) = try await currentFilter()
            self.display = display
            let stream = SCStream(filter: filter, configuration: configuration(), delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
            try await stream.startCapture()
            self.stream = stream
            isRunning = true
            lastError = nil
            log.info("capture started for display \(self.displayID) \(Int(self.pointSize.width))x\(Int(self.pointSize.height))@\(self.scale)x")
            await captureWallpaper()
            refreshTask = Task.detached { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    await self?.refreshFilter()
                }
            }
        } catch {
            lastError = error.localizedDescription
            isRunning = false
            log.error("capture failed for display \(self.displayID): \(error.localizedDescription, privacy: .public)")
        }
    }

    public func stop() async {
        refreshTask?.cancel()
        refreshTask = nil
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        isRunning = false
        let pending = lock.withLock { () -> [(after: Double, resume: (CapturedFrame?) -> Void)] in
            latest = nil
            let all = waiters
            waiters.removeAll()
            return all
        }
        pending.forEach { $0.resume(nil) }
    }

    private func configuration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = Int(pointSize.width * scale)
        config.height = Int(pointSize.height * scale)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.backgroundColor = .clear
        config.queueDepth = 6
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(1.0 / frameInterval))
        return config
    }

    /// Windows that are not ordinary app windows: wallpaper, desktop icons, menu bar, Dock, panels, and our own overlay.
    private func currentFilter() async throws -> (SCDisplay, SCContentFilter, [SCWindow]) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NSError(domain: "Spacewalk", code: 1, userInfo: [NSLocalizedDescriptionKey: "Display \(displayID) is not capturable"])
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let excluded = content.windows.filter { $0.windowLayer != 0 || $0.owningApplication?.processID == ownPID }
        let desktop = content.windows.filter { $0.windowLayer < 0 }
        return (display, SCContentFilter(display: display, excludingWindows: excluded), desktop)
    }

    /// Picks up new panels or menu bar items. Cheap (about 15 ms, off the main thread).
    public func refreshFilter() async {
        guard let stream else { return }
        if let (_, filter, _) = try? await currentFilter() {
            try? await stream.updateContentFilter(filter)
        }
    }

    public func wallpaper(for space: UInt64) -> IOSurface? { wallpapers[space]?.surface }

    public func lastSeen(for space: UInt64) -> IOSurface? { lastSeen.first { $0.space == space }?.surface }

    public var spacesWithPictures: Set<UInt64> { Set(lastSeen.map(\.space)) }

    /// Builds a windows-only picture of a Space we have never left through Spacewalk, from captures of
    /// each of its windows, so even a first visit can start moving before the Dock answers. Slow
    /// (tens of ms per window), so it runs in the background and is replaced by a real last picture.
    public func composePicture(for space: UInt64, windows: [SpaceWindow]) async {
        guard !windows.isEmpty, lastSeen(for: space) == nil,
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else { return }
        let bounds = CGDisplayBounds(displayID)
        let width = Int(pointSize.width * scale), height = Int(pointSize.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return }
        context.scaleBy(x: scale, y: scale)
        var drew = false
        // Back to front: the window list comes front to back.
        for window in windows.reversed() {
            guard let target = content.windows.first(where: { $0.windowID == window.id }) else { continue }
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width * scale)
            config.height = Int(window.frame.height * scale)
            config.showsCursor = false
            config.backgroundColor = .clear
            config.ignoreShadowsSingleWindow = true
            config.pixelFormat = kCVPixelFormatType_32BGRA
            guard config.width > 0, config.height > 0,
                  let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: config) else { continue }
            // Window bounds are top-left based in global coordinates; the context is bottom-left based.
            let local = CGRect(x: window.frame.minX - bounds.minX, y: bounds.maxY - window.frame.maxY, width: window.frame.width, height: window.frame.height)
            context.draw(image, in: local)
            drew = true
        }
        guard drew, lastSeen(for: space) == nil, let image = context.makeImage(), let surface = Self.surface(from: image) else { return }
        lastSeen.append((space, surface, CACurrentMediaTime()))
        if lastSeen.count > Self.lastSeenLimit { lastSeen.removeLast(lastSeen.count - Self.lastSeenLimit) }
    }

    /// Copies a stream frame into our own surface (the stream's pool must get its buffer back) and
    /// files it as the last picture of `space`. Keeps the three most recent Spaces.
    public func remember(_ frame: CapturedFrame, for space: UInt64) async {
        let copy = await Task.detached(priority: .utility) { Self.copy(frame.surface) }.value
        guard let copy else { return }
        lastSeen.removeAll { $0.space == space }
        lastSeen.insert((space, copy, CACurrentMediaTime()), at: 0)
        if lastSeen.count > Self.lastSeenLimit { lastSeen.removeLast(lastSeen.count - Self.lastSeenLimit) }
    }

    static func copy(_ source: IOSurface) -> IOSurface? {
        guard let target = IOSurface(properties: [.width: source.width, .height: source.height, .bytesPerElement: 4,
                                                  .pixelFormat: source.pixelFormat]) else { return nil }
        source.lock(options: [.readOnly], seed: nil)
        target.lock(options: [], seed: nil)
        let stride = min(source.bytesPerRow, target.bytesPerRow)
        for row in 0..<source.height {
            memcpy(target.baseAddress + row * target.bytesPerRow, source.baseAddress + row * source.bytesPerRow, stride)
        }
        target.unlock(options: [], seed: nil)
        source.unlock(options: [.readOnly], seed: nil)
        return target
    }

    public var cachedWallpaperSpaces: [UInt64] { Array(wallpapers.keys) }

    /// The Dock keeps one wallpaper window per space, so every space's wallpaper can be captured
    /// without visiting it. Desktop icons live in one Finder window shared by all spaces and are
    /// drawn on top. Spaces refreshed within `maxAge` seconds are skipped.
    public func refreshWallpapers(spaces: [UInt64], currentSpace: UInt64, maxAge: Double) async {
        let now = CACurrentMediaTime()
        let stale = spaces.filter { (wallpapers[$0]?.time ?? -1e9) < now - maxAge }
        guard !stale.isEmpty, let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return }
        let bounds = CGDisplayBounds(displayID)
        let onThisDisplay = content.windows.filter { $0.frame.intersects(bounds) && $0.windowLayer < -2_000_000_000 }
        let wallpaperWindows = onThisDisplay.filter { $0.owningApplication?.bundleIdentifier == "com.apple.dock" && ($0.title ?? "").hasPrefix("Wallpaper") }
        let iconsWindow = onThisDisplay.first { $0.owningApplication?.bundleIdentifier == "com.apple.finder" && $0.frame.size == bounds.size }
        var icons: CGImage?
        if let iconsWindow { icons = await captureWindow(iconsWindow, transparent: true) }
        for space in stale {
            guard let window = wallpaperWindows.first(where: { SkyLight.spaces(forWindows: [$0.windowID]).contains(space) }),
                  let image = await captureWindow(window, transparent: false) else { continue }
            let composed = Self.compose(image, over: icons) ?? image
            guard let surface = Self.surface(from: composed) else { continue }
            wallpapers[space] = (surface, CACurrentMediaTime())
            if space == currentSpace { wallpaper = surface }
        }
        if wallpaper == nil { await captureWallpaper() }
    }

    /// Copies a CGImage into a BGRA IOSurface once, so Core Animation can show it without uploading.
    static func surface(from image: CGImage) -> IOSurface? {
        let width = image.width, height = image.height
        guard let surface = IOSurface(properties: [.width: width, .height: height, .bytesPerElement: 4,
                                                   .pixelFormat: kCVPixelFormatType_32BGRA]) else { return nil }
        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        guard let context = CGContext(data: surface.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: surface.bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return surface
    }

    /// The reverse, for diagnostics.
    public static func image(from surface: IOSurface) -> CGImage? {
        surface.lock(options: [.readOnly], seed: nil)
        defer { surface.unlock(options: [.readOnly], seed: nil) }
        guard let context = CGContext(data: surface.baseAddress, width: surface.width, height: surface.height, bitsPerComponent: 8, bytesPerRow: surface.bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        return context.makeImage()
    }

    private func captureWindow(_ window: SCWindow, transparent: Bool) async -> CGImage? {
        let config = SCStreamConfiguration()
        config.width = Int(pointSize.width * scale)
        config.height = Int(pointSize.height * scale)
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        if transparent { config.backgroundColor = .clear }
        return try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
    }

    private static func compose(_ wallpaper: CGImage, over icons: CGImage?) -> CGImage? {
        guard let icons, let context = CGContext(data: nil, width: wallpaper.width, height: wallpaper.height, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: wallpaper.width, height: wallpaper.height)
        context.draw(wallpaper, in: rect)
        context.draw(icons, in: rect)
        return context.makeImage()
    }

    /// One screenshot of the desktop plane: wallpaper plus desktop icons and widgets.
    public func captureWallpaper() async {
        guard let (display, _, desktop) = try? await currentFilter() else { return }
        let config = SCStreamConfiguration()
        config.width = Int(pointSize.width * scale)
        config.height = Int(pointSize.height * scale)
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        let filter = SCContentFilter(display: display, including: desktop)
        if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
            wallpaper = Self.surface(from: image)
        }
    }

    /// Everything on this display, overlay included. For diagnostics (`spacewalk snapshot`).
    public func screenshot() async -> CGImage? {
        guard let (display, _, _) = try? await currentFilter() else { return nil }
        let config = SCStreamConfiguration()
        config.width = Int(pointSize.width * scale)
        config.height = Int(pointSize.height * scale)
        config.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: config)
    }

    // MARK: Frames

    public func latestFrame() -> CapturedFrame? {
        lock.withLock { latest }
    }

    /// The first frame that arrives after `time`, or nil when none arrives within `timeout` seconds.
    public func frame(after time: Double, timeout: Double) async -> CapturedFrame? {
        if let candidate = lock.withLock({ latest }), candidate.time > time {
            return candidate
        }
        return await withCheckedContinuation { continuation in
            let state = WaiterState()
            let resume: (CapturedFrame?) -> Void = { frame in
                if state.claim() { continuation.resume(returning: frame) }
            }
            lock.withLock { waiters.append((after: time, resume: resume)) }
            outputQueue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                let fallback = self.lock.withLock { () -> CapturedFrame? in
                    self.waiters.removeAll { $0.after == time }
                    return self.latest.flatMap { $0.time > time ? $0 : nil }
                }
                resume(fallback)
            }
        }
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
        let time = CACurrentMediaTime()
        let dirty = Self.dirtyRects(attachments.first?[.dirtyRects])
        let fraction = Self.changedFraction(dirty, pixelWidth: CVPixelBufferGetWidth(pixelBuffer), pixelHeight: CVPixelBufferGetHeight(pixelBuffer), pointSize: pointSize)
        let frame = CapturedFrame(surface: surface, pixelBuffer: pixelBuffer, time: time, changedFraction: fraction)
        let ready = lock.withLock { () -> [(after: Double, resume: (CapturedFrame?) -> Void)] in
            latest = frame
            let due = waiters.filter { $0.after < time }
            waiters.removeAll { $0.after < time }
            return due
        }
        ready.forEach { $0.resume(frame) }
    }

    static func dirtyRects(_ value: Any?) -> [CGRect]? {
        (value as? [Any])?.compactMap { ($0 as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } }
    }

    /// Dirty rects may come in points or pixels; pick the unit by what fits.
    private static func unitSize(_ rects: [CGRect], pixelWidth: Int, pixelHeight: Int, pointSize: CGSize) -> CGSize {
        let inPixels = rects.contains { $0.maxX > pointSize.width + 1 || $0.maxY > pointSize.height + 1 }
        return inPixels ? CGSize(width: pixelWidth, height: pixelHeight) : pointSize
    }

    static func changedFraction(_ rects: [CGRect]?, pixelWidth: Int, pixelHeight: Int, pointSize: CGSize) -> Double {
        guard let rects, !rects.isEmpty else { return 1 }
        let unit = unitSize(rects, pixelWidth: pixelWidth, pixelHeight: pixelHeight, pointSize: pointSize)
        let area = rects.reduce(0.0) { $0 + Double($1.width * $1.height) }
        return min(1, area / Double(unit.width * unit.height))
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.error("stream stopped: \(error.localizedDescription, privacy: .public)")
        lastError = error.localizedDescription
        isRunning = false
        self.stream = nil
    }
}

/// One-shot guard shared by a waiter and its timeout.
private final class WaiterState: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}

/// An ordinary app window and where it sits, for composing pictures of unseen Spaces.
public struct SpaceWindow: Sendable {
    public let id: CGWindowID
    public let frame: CGRect
    public init(id: CGWindowID, frame: CGRect) {
        self.id = id
        self.frame = frame
    }
}

public extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) } ?? 0
    }
}
