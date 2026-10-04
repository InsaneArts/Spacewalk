import AppKit
import os

public struct SwitchReport: Sendable {
    public var target: SpaceTarget
    public var from: String?
    public var to: String?
    public var animated = false
    /// The animation started from the last picture seen of the destination, before the Dock answered.
    public var predicted = false
    public var note: String?
    public var direction: Direction?
    /// Milliseconds from the hotkey to the overlay being on screen.
    public var overlayMs: Double = 0
    /// Milliseconds the Dock took to report the new space.
    public var switchMs: Double = 0
    /// Milliseconds from the switch completing to the new frame being in hand.
    public var afterFrameMs: Double = 0
    /// Milliseconds from the hotkey to the first animated frame.
    public var motionMs: Double = 0
    /// Frames that still changed after the switch.
    public var settleFrames = 0
    public var settleAreas: [Double] = []
    public var date = Date()

    public var summary: String {
        let route = [from, to].compactMap { $0 }.joined(separator: " → ")
        if animated {
            let areas = settleAreas.map { String(format: "%.0f%%", $0 * 100) }.joined(separator: " ")
            return String(format: "%@  motion after %.0f ms%@ (overlay %.0f, switch %.0f, frame %.0f, settle %d: %@)", route, motionMs, predicted ? " predicted" : "", overlayMs, switchMs, afterFrameMs, settleFrames, areas)
        }
        return "\(route.isEmpty ? "switch" : route)  not animated: \(note ?? "unknown")"
    }
}

public struct DisplayStatus: Identifiable, Sendable {
    public var name: String
    public var running: Bool
    public var error: String?
    public var id: String { name }
}

/// Runs one space switch: overlay up, the Dock switches underneath, new frame in, animate, overlay down.
@MainActor
public final class Switcher {
    public var settings: SpacewalkSettings
    /// Multiplies the duration. Debug aid, read from the `debugSlowMotion` default.
    public var slowMotion: Double = 1
    public private(set) var reports: [SwitchReport] = []
    public var onReport: ((SwitchReport) -> Void)?
    public let engine = SpaceEngine()

    /// A frame must change at least this share of the screen to count as layout still moving.
    public static let layoutChangeFraction = 0.02

    private struct Display {
        let screen: NSScreen
        let capture: DisplayCapture
        let overlay: OverlayWindow
        let pill: PillWindow
        let overview: OverviewWindow
        let bar: SpacesBarWindow
    }

    /// Drives the finish or cancel of a finger-driven transition at display rate.
    private final class LinkDriver: NSObject {
        var tick: () -> Void = {}
        @objc func step(_ link: CADisplayLink) { tick() }
    }

    private struct Gesture {
        let plan: SpaceEngine.Plan
        let displayID: CGDirectDisplayID
        let before: CapturedFrame
        let direction: Direction
        let towardsNext: Bool
        var progress: Double = 0
        var ticked = false
        var committed = false
        var landed = false
        var animationDone = false
        var finished = false
        var link: CADisplayLink?
        var report: SwitchReport
    }
    private var gesture: Gesture?
    private var gestureIgnored = false
    private var overviewScrub: (displayID: CGDirectDisplayID, progress: Double)?
    private var barTimer: Timer?
    private let linkDriver = LinkDriver()
    private lazy var whoosh = Whoosh()
    private var composing: Set<UInt64> = []
    private var lastPictureRefresh: Double = 0
    /// Finger progress is multiplied by this; a comfortable swipe reports about 0.6 to 0.8.
    private static let gestureGain = 1.3
    /// Past this progress a lifted finger commits the switch.
    private static let commitProgress = 0.33

    private var displays: [CGDirectDisplayID: Display] = [:]
    private var held: [CGDirectDisplayID: [CapturedFrame]] = [:]
    private var generation = 0
    private var switching = false
    private let log = Logger(subsystem: "dev.tgomareli.spacewalk", category: "switch")

    public init(settings: SpacewalkSettings) {
        self.settings = settings
    }

    // MARK: Displays

    public var displayStatus: [DisplayStatus] {
        displays.values.map { DisplayStatus(name: $0.screen.localizedName, running: $0.capture.isRunning, error: $0.capture.lastError) }
    }

    public var hasRunningCapture: Bool { displays.values.contains { $0.capture.isRunning } }

    /// Match the capture and overlay set to the connected screens.
    public func attachDisplays() async {
        let screens = NSScreen.screens
        let ids = Set(screens.map(\.displayID))
        for (id, display) in displays where !ids.contains(id) {
            await display.capture.stop()
            display.overlay.hide()
            displays[id] = nil
        }
        for screen in screens {
            if let existing = displays[screen.displayID] {
                existing.capture.update(screen: screen)
                existing.overlay.update(screen: screen)
                existing.pill.update(screen: screen)
                existing.overview.update(screen: screen)
                existing.bar.update(screen: screen)
                if !existing.capture.isRunning { await existing.capture.start() }
            } else {
                let display = Display(screen: screen, capture: DisplayCapture(screen: screen), overlay: OverlayWindow(screen: screen),
                                      pill: PillWindow(screen: screen), overview: OverviewWindow(screen: screen), bar: SpacesBarWindow(screen: screen))
                let displayID = screen.displayID
                display.overview.onSelect = { [weak self] index in self?.arrive(at: index, from: displayID) }
                display.overview.onCancel = { [weak self] in self?.overviewScrub = nil }
                display.bar.onSelect = { [weak self] index in self?.perform(.index(index + 1)) }
                displays[screen.displayID] = display
                await display.capture.start()
            }
        }
        await refreshWallpapers()
        await refreshPictures(force: true)
    }

    /// Pictures of Spaces we have never left through Spacewalk, composed from their windows. Throttled.
    public func refreshPictures(force: Bool = false) async {
        let now = CACurrentMediaTime()
        guard force || now - lastPictureRefresh > 10 else { return }
        lastPictureRefresh = now
        let snapshot = engine.snapshot()
        for display in displays.values {
            guard display.capture.isRunning, let uuid = SpaceEngine.nameKey(for: display.screen.displayID),
                  let spaces = snapshot.display(uuid: uuid) else { continue }
            for space in spaces.spaces where space.id != spaces.currentID && !space.isFullscreen
                && display.capture.lastSeen(for: space.id) == nil && !composing.contains(space.id) {
                composing.insert(space.id)
                let windows = SpaceEngine.windows(on: space.id)
                await display.capture.composePicture(for: space.id, windows: windows)
                composing.remove(space.id)
            }
        }
    }

    private func announce(_ plan: SpaceEngine.Plan, on display: Display, for seconds: Double) {
        if settings.showWorkspacePill { display.pill.show(plan.display.label(at: plan.toIndex, names: settings.spaceNames), for: seconds + 0.35) }
        if settings.playSound { whoosh?.play() }
    }

    public func detachAll() async {
        for display in displays.values {
            await display.capture.stop()
            display.overlay.hide()
        }
        displays.removeAll()
    }

    // MARK: Switching

    /// Fire-and-forget form for hotkeys and the overview.
    public func perform(_ target: SpaceTarget) {
        Task { await self.perform(target) }
    }

    public func perform(_ target: SpaceTarget) async {
        if target == .overview {
            showOverview()
            return
        }
        // One switch at a time: the Dock must finish before the next plan is computed.
        while switching { try? await Task.sleep(nanoseconds: 4_000_000) }
        switching = true
        defer { switching = false }

        generation += 1
        let myGeneration = generation
        let t0 = CACurrentMediaTime()
        var report = SwitchReport(target: target)
        func ms(_ since: Double) -> Double { (CACurrentMediaTime() - since) * 1000 }

        let plan: SpaceEngine.Plan
        switch engine.plan(target, wrapAround: settings.wrapAround, columns: settings.overviewColumns) {
        case .success(let value): plan = value
        case .failure(let error):
            report.note = error.localizedDescription
            return finish(report)
        }
        report.from = plan.display.label(at: plan.fromIndex, names: settings.spaceNames)
        report.to = plan.display.label(at: plan.toIndex, names: settings.spaceNames)
        guard SpaceEngine.accessibilityGranted else {
            report.note = "Accessibility permission missing, cannot post the switch"
            return finish(report)
        }

        func plain(_ note: String) async {
            hideAll()
            let switched = await engine.execute(plan)
            report.note = switched ? note : "\(note); the Dock did not switch"
            finish(report)
        }

        guard settings.enabled, settings.effect != .instant else { return await plain(settings.enabled ? "instant mode" : "animations disabled") }
        guard let displayID = plan.displayID, let display = displays[displayID] else { return await plain("no overlay for that display") }
        let capture = display.capture
        let stage = display.overlay.stage
        guard capture.isRunning, let before = capture.latestFrame() else { return await plain("no capture stream (check Screen Recording permission)") }

        // 1. Freeze the current picture, on the wallpapers of both spaces. If we have seen the
        //    destination before, its last picture becomes the incoming card right away.
        let fromSpace = plan.display.currentID
        let fromWallpaper = capture.wallpaper(for: fromSpace) ?? capture.wallpaper
        stage.setWallpapers(outgoing: fromWallpaper, incoming: capture.wallpaper(for: plan.target.id) ?? fromWallpaper)
        stage.setOutgoing(before.surface)
        let predicted = settings.predictiveStart ? capture.lastSeen(for: plan.target.id) : nil
        report.predicted = predicted != nil
        stage.showResting()
        if let predicted { stage.setIncoming(predicted) }
        display.overlay.show()
        held[displayID] = [before]
        // The committed overlay reaches the glass at the next refresh; the Dock needs 30 ms or more
        // to act on the swipe, so the swipe can go out right away.
        CATransaction.flush()
        report.overlayMs = ms(t0)

        let forward = plan.toIndex > plan.fromIndex
        var direction: Direction
        switch settings.directionMode {
        case .byOrder: direction = forward ? .forward : .backward
        case .alwaysForward: direction = .forward
        case .alwaysBackward: direction = .backward
        }
        if settings.invertDirection { direction = direction.flipped }
        let timing = AnimationTiming(settings: settings, slowMotion: slowMotion)
        report.direction = direction
        announce(plan, on: display, for: timing.totalDuration)

        var landed = false
        var animationDone = false
        var hidden = false
        func hideWhenReady() {
            guard landed, animationDone, !hidden, myGeneration == generation else { return }
            hidden = true
            display.overlay.hide()
            self.held[displayID] = nil
            Task {
                await capture.remember(before, for: fromSpace)
                await capture.refreshFilter()
                self.refreshBars()
                await self.refreshWallpapers(forcing: plan.target.id)
                await self.refreshPictures()
            }
        }

        // 2. With a prediction, start moving now; the Dock switches underneath.
        if predicted != nil {
            report.motionMs = ms(t0)
            report.animated = true
            stage.run(settings: settings, direction: direction, timing: timing) {
                animationDone = true
                hideWhenReady()
            }
        }
        let tSwitch = CACurrentMediaTime()
        let switched = await engine.execute(plan)
        report.switchMs = ms(tSwitch)
        guard myGeneration == generation else { return }
        guard switched else {
            hideAll()
            report.animated = false
            report.note = "the Dock did not switch within the timeout"
            return finish(report)
        }
        landed = true
        if settings.switchAllDisplays { Task { await self.followOnOtherDisplays(plan) } }

        // 3. The first frame that shows the new space. The picture may have changed before the Dock
        //    reported the switch, so a frame from after the swipe was posted also counts.
        let tDone = CACurrentMediaTime()
        let idleWindow = capture.frameInterval * Double(max(1, settings.settleFrames)) + 0.006
        var after = await capture.frame(after: tDone, timeout: capture.frameInterval * 2 + 0.004)
        if after == nil, let recent = capture.latestFrame(), recent.time > tSwitch { after = recent }
        if after == nil { after = await capture.frame(after: tSwitch, timeout: 0.25) }
        var settled = 0
        var areas: [Double] = []

        func settle(from first: CapturedFrame, onFrame: (CapturedFrame) -> Void) async {
            var current = first
            var deadline = CACurrentMediaTime() + idleWindow
            while settled < 12, myGeneration == generation {
                let remaining = deadline - CACurrentMediaTime()
                guard remaining > 0, let next = await capture.frame(after: current.time, timeout: remaining) else { break }
                current = next
                settled += 1
                areas.append(next.changedFraction)
                if next.changedFraction >= Switcher.layoutChangeFraction { deadline = CACurrentMediaTime() + idleWindow }
                onFrame(next)
            }
        }
        if predicted == nil, !settings.eagerStart, let first = after {
            await settle(from: first) { after = $0 }
        }
        report.afterFrameMs = ms(tDone)
        guard myGeneration == generation else { return }
        guard let firstFrame = after else {
            if predicted != nil {
                hideWhenReady()
                animationDone = true
                hideWhenReady()
            } else {
                hideAll()
            }
            report.note = "no frame arrived after the switch"
            return finish(report)
        }
        held[displayID, default: []].append(firstFrame)

        // 4. Without a prediction the animation starts here, on the first real frame.
        if predicted == nil {
            stage.setIncoming(firstFrame.surface)
            report.motionMs = ms(t0)
            report.animated = true
            stage.run(settings: settings, direction: direction, timing: timing) {
                animationDone = true
                hideWhenReady()
            }
        } else {
            stage.setIncomingLive(firstFrame.surface, fadeIn: 0.12)
        }
        hideWhenReady()

        // 5. Keep the incoming picture live until the overlay hides.
        if settings.eagerStart || predicted != nil {
            var current = firstFrame
            let stop = CACurrentMediaTime() + timing.totalDuration + 0.1
            while display.overlay.isVisible, myGeneration == generation, CACurrentMediaTime() < stop {
                guard let next = await capture.frame(after: current.time, timeout: 0.05) else { continue }
                guard display.overlay.isVisible, myGeneration == generation else { break }
                current = next
                settled += 1
                if next.changedFraction >= Switcher.layoutChangeFraction { areas.append(next.changedFraction) }
                // Keep the outgoing frame, the frame on screen and the one before it. Holding every
                // frame would exhaust the capture stream's buffer pool and stall it mid-animation.
                var kept = held[displayID] ?? []
                if kept.count > 2 { kept.removeSubrange(1..<(kept.count - 1)) }
                kept.append(next)
                held[displayID] = kept
                if predicted != nil {
                    stage.setIncomingLive(next.surface, fadeIn: 0)
                } else {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    stage.setIncoming(next.surface)
                    CATransaction.commit()
                }
            }
        }
        report.settleFrames = settled
        report.settleAreas = areas
        finish(report)
    }

    /// Captures every space's wallpaper on every display. `forcing` is refreshed even when fresh.
    public func refreshWallpapers(forcing: UInt64? = nil, maxAge: Double = 120) async {
        let snapshot = engine.snapshot()
        for display in displays.values {
            guard let uuid = SpaceEngine.nameKey(for: display.screen.displayID), let spaces = snapshot.display(uuid: uuid) else { continue }
            if let forcing, spaces.spaces.contains(where: { $0.id == forcing }) {
                await display.capture.refreshWallpapers(spaces: [forcing], currentSpace: spaces.currentID, maxAge: 0)
            }
            await display.capture.refreshWallpapers(spaces: spaces.spaces.map(\.id), currentSpace: spaces.currentID, maxAge: maxAge)
        }
    }

    /// Writes every cached wallpaper as PNG, for diagnostics (`spacewalk wallpapers`).
    public func dumpWallpapers(to directory: String) async -> String {
        await refreshWallpapers(maxAge: 0)
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        var written: [String] = []
        for display in displays.values {
            for space in display.capture.cachedWallpaperSpaces {
                guard let surface = display.capture.wallpaper(for: space), let image = DisplayCapture.image(from: surface),
                      let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { continue }
                let name = "space_\(space).png"
                try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
                written.append(name)
            }
        }
        return written.isEmpty ? "no wallpapers captured" : written.joined(separator: " ")
    }

    // MARK: Overview

    private func overviewEntries(for display: Display, spaces: DisplaySpaces) -> [OverviewEntry] {
        let capture = display.capture
        return spaces.spaces.indices.map { index -> OverviewEntry in
            let space = spaces.spaces[index]
            let windows = space.id == spaces.currentID ? capture.latestFrame()?.surface : capture.lastSeen(for: space.id)
            return OverviewEntry(label: spaces.label(at: index, names: settings.spaceNames),
                                 wallpaper: capture.wallpaper(for: space.id) ?? capture.wallpaper,
                                 windows: windows, isCurrent: space.id == spaces.currentID,
                                 apps: SpaceEngine.apps(on: space.id))
        }
    }

    private func cursorDisplay() -> (Display, DisplaySpaces)? {
        guard let uuid = SpaceEngine.cursorDisplayUUID(), let spaces = engine.snapshot().display(uuid: uuid),
              let displayID = engine.displayID(forUUID: uuid), let display = displays[displayID] else { return nil }
        return (display, spaces)
    }

    /// Every Space of the display under the pointer as a picture, with names and app icons.
    public func showOverview() {
        guard let (display, spaces) = cursorDisplay() else { return }
        if display.overview.isVisible { display.overview.endScrub(open: false); return }
        display.overview.show(entries: overviewEntries(for: display, spaces: spaces), current: spaces.currentIndex ?? 0, columns: settings.overviewColumns)
    }

    /// The chosen card already fills the screen with the destination's picture. Take it over on the
    /// overlay, switch underneath, fade the live picture in, hide.
    private func arrive(at index: Int, from displayID: CGDirectDisplayID) {
        guard let display = displays[displayID] else { return }
        let target: SpaceTarget = .index(index + 1)
        guard !switching, settings.enabled, case .success(let plan) = engine.plan(target) else {
            display.overview.hide()
            perform(target)
            return
        }
        let capture = display.capture
        let stage = display.overlay.stage
        let wallpaper = capture.wallpaper(for: plan.target.id) ?? capture.wallpaper
        stage.setWallpapers(outgoing: wallpaper, incoming: wallpaper)
        stage.setOutgoing(capture.lastSeen(for: plan.target.id))
        stage.showResting()
        display.overlay.show()
        CATransaction.flush()
        display.overview.hide()
        switching = true
        generation += 1
        let myGeneration = generation
        var report = SwitchReport(target: target)
        report.from = plan.display.label(at: plan.fromIndex, names: settings.spaceNames)
        report.to = plan.display.label(at: plan.toIndex, names: settings.spaceNames)
        report.note = "from the overview"
        announce(plan, on: display, for: 0.3)
        Task { @MainActor in
            defer { self.switching = false }
            let tSwitch = CACurrentMediaTime()
            let switched = await self.engine.execute(plan)
            report.switchMs = (CACurrentMediaTime() - tSwitch) * 1000
            guard myGeneration == self.generation else { return }
            guard switched else {
                display.overlay.hide()
                report.note = "from the overview; the Dock did not switch"
                self.finish(report)
                return
            }
            let tDone = CACurrentMediaTime()
            var first = await capture.frame(after: tDone, timeout: capture.frameInterval * 2 + 0.004)
            if first == nil, let recent = capture.latestFrame(), recent.time > tSwitch { first = recent }
            if first == nil { first = await capture.frame(after: tSwitch, timeout: 0.25) }
            report.afterFrameMs = (CACurrentMediaTime() - tDone) * 1000
            guard myGeneration == self.generation else { return }
            guard let firstFrame = first else { display.overlay.hide(); report.note = "from the overview; no frame"; self.finish(report); return }
            self.held[displayID] = [firstFrame]
            stage.setOutgoingLive(firstFrame.surface, fadeIn: 0.14)
            var frame = firstFrame
            let stop = CACurrentMediaTime() + 0.3
            while CACurrentMediaTime() < stop, myGeneration == self.generation {
                guard let next = await capture.frame(after: frame.time, timeout: 0.05) else { continue }
                frame = next
                self.held[displayID] = [firstFrame, next]
                stage.setOutgoingLive(next.surface, fadeIn: 0)
            }
            guard myGeneration == self.generation else { return }
            display.overlay.hide()
            self.held[displayID] = nil
            report.animated = true
            self.finish(report)
            await self.refreshWallpapers(forcing: plan.target.id)
            await self.refreshPictures()
            self.refreshBars()
        }
    }

    // MARK: Spaces bar

    /// Shows or hides the bar on every display and keeps it current.
    public func refreshBars() {
        barTimer?.invalidate()
        barTimer = nil
        let snapshot = engine.snapshot()
        for display in displays.values {
            guard settings.spacesBar, let uuid = SpaceEngine.nameKey(for: display.screen.displayID), let spaces = snapshot.display(uuid: uuid) else {
                display.bar.hide()
                continue
            }
            let entries = spaces.spaces.indices.map { index in
                BarEntry(label: spaces.label(at: index, names: settings.spaceNames), apps: SpaceEngine.apps(on: spaces.spaces[index].id),
                         isCurrent: index == spaces.currentIndex)
            }
            display.bar.show(entries: entries, atTop: settings.spacesBarAtTop)
        }
        if settings.spacesBar {
            barTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.refreshBars() }
            }
        }
    }

    public func hideOverview() {
        for display in displays.values where display.overview.isVisible { display.overview.hide() }
    }

    // MARK: Other displays

    /// With "Displays have separate Spaces", bring every other display to the same position. The Dock
    /// routes a swipe to the display under the pointer, so the pointer is parked there for a moment.
    /// These switches are instant, not animated.
    private func followOnOtherDisplays(_ primary: SpaceEngine.Plan) async {
        let snapshot = engine.snapshot()
        for other in snapshot.displays where other.displayUUID != primary.display.displayUUID {
            guard let current = other.currentIndex, other.spaces.indices.contains(primary.toIndex), current != primary.toIndex,
                  let displayID = engine.displayID(forUUID: other.displayUUID) else { continue }
            let restore = SpaceEngine.warpCursor(toCenterOf: displayID)
            try? await Task.sleep(nanoseconds: 20_000_000)
            DockSwipe.post(primary.toIndex > current ? .right : .left, steps: abs(primary.toIndex - current))
            let deadline = CACurrentMediaTime() + 0.6
            while CACurrentMediaTime() < deadline {
                try? await Task.sleep(nanoseconds: 5_000_000)
                if engine.snapshot().display(uuid: other.displayUUID)?.currentIndex == primary.toIndex { break }
            }
            SpaceEngine.warpCursor(to: restore)
        }
    }

    // MARK: Finger-driven switching

    /// Feed the whole trackpad gesture here. The transition follows the fingers; lifting them past a
    /// third of the way, or with a fling, commits the switch and finishes with matching speed.
    public func gesture(_ event: GestureEvent) {
        switch event {
        case .began:
            gestureIgnored = gesture != nil
        case .changed(let raw):
            guard !gestureIgnored else { return }
            if gesture == nil {
                guard abs(raw) > 0.015 else { return }
                beginGesture(towardsNext: raw > 0)
            }
            guard var current = gesture, !current.committed else { return }
            let signed = current.towardsNext ? raw : -raw
            current.progress = min(1, max(0, signed * Switcher.gestureGain))
            if settings.hapticFeedback {
                if !current.ticked, current.progress >= Switcher.commitProgress {
                    HapticTick.perform(settings.hapticStrength)
                    current.ticked = true
                } else if current.ticked, current.progress < Switcher.commitProgress - 0.12 {
                    current.ticked = false
                }
            }
            gesture = current
            displays[current.displayID]?.overlay.stage.scrub(current.progress)
        case .ended(let raw, let velocity):
            defer { gestureIgnored = false }
            guard let current = gesture, !current.committed else { return }
            let fling = current.towardsNext ? velocity : -velocity
            if current.progress >= Switcher.commitProgress || (fling > 1.2 && current.progress > 0.05) {
                commitGesture(velocity: max(0, fling))
            } else {
                cancelGesture()
            }
        case .cancelled:
            gestureIgnored = false
            if let current = gesture, !current.committed { cancelGesture() }
        case .overviewBegan:
            break
        case .overviewChanged(let raw):
            let progress = min(1, abs(raw) * 1.6)
            if overviewScrub == nil {
                guard let (display, spaces) = cursorDisplay(), !display.overview.isVisible else { return }
                display.overview.beginScrub(entries: overviewEntries(for: display, spaces: spaces), current: spaces.currentIndex ?? 0, columns: settings.overviewColumns)
                overviewScrub = (display.screen.displayID, progress)
            }
            guard var scrub = overviewScrub, let display = displays[scrub.displayID] else { return }
            scrub.progress = progress
            overviewScrub = scrub
            display.overview.scrub(progress)
        case .overviewEnded(let raw, let velocity):
            guard let scrub = overviewScrub, let display = displays[scrub.displayID] else { return }
            overviewScrub = nil
            let open = scrub.progress >= 0.3 || abs(velocity) > 1.5
            if settings.hapticFeedback, open { HapticTick.perform(settings.hapticStrength) }
            display.overview.endScrub(open: open)
        }
    }

    private func beginGesture(towardsNext: Bool) {
        let target: SpaceTarget = towardsNext ? .next : .previous
        guard !switching, settings.enabled, settings.effect != .instant else {
            gestureIgnored = true
            if !switching { perform(target) }
            return
        }
        guard case .success(let plan) = engine.plan(target, wrapAround: settings.wrapAround),
              let displayID = plan.displayID, let display = displays[displayID],
              display.capture.isRunning, let before = display.capture.latestFrame() else {
            gestureIgnored = true
            return
        }
        switching = true
        generation += 1
        let capture = display.capture
        let stage = display.overlay.stage
        let fromWallpaper = capture.wallpaper(for: plan.display.currentID) ?? capture.wallpaper
        stage.setWallpapers(outgoing: fromWallpaper, incoming: capture.wallpaper(for: plan.target.id) ?? fromWallpaper)
        stage.setOutgoing(before.surface)
        let predicted = settings.predictiveStart ? capture.lastSeen(for: plan.target.id) : nil
        var direction: Direction = towardsNext ? .forward : .backward
        if settings.directionMode == .alwaysForward { direction = .forward }
        if settings.directionMode == .alwaysBackward { direction = .backward }
        if settings.invertDirection { direction = direction.flipped }
        stage.beginScrub(settings: settings, direction: direction)
        stage.setIncoming(predicted)
        display.overlay.show()
        held[displayID] = [before]
        var report = SwitchReport(target: target)
        report.from = plan.display.label(at: plan.fromIndex, names: settings.spaceNames)
        report.to = plan.display.label(at: plan.toIndex, names: settings.spaceNames)
        report.predicted = predicted != nil
        report.direction = direction
        report.note = "finger-driven"
        gesture = Gesture(plan: plan, displayID: displayID, before: before, direction: direction, towardsNext: towardsNext, report: report)
    }

    private func commitGesture(velocity: Double) {
        guard var current = gesture, let display = displays[current.displayID] else { return }
        current.committed = true
        if settings.hapticFeedback, !current.ticked { HapticTick.perform(settings.hapticStrength) }
        gesture = current
        let remaining = 1 - current.progress
        // Faster flings finish sooner; never slower than 0.3 s nor faster than one or two frames.
        let duration = min(0.3, max(0.07, 0.3 * remaining / max(1, velocity / 3))) * slowMotion
        announce(current.plan, on: display, for: duration)
        current.report.animated = true
        current.report.motionMs = 0
        gesture = current
        runLink(on: display.screen, from: current.progress, to: 1, duration: duration) { [weak self] in
            guard let self, var g = self.gesture else { return }
            g.animationDone = true
            self.gesture = g
            self.finishGestureIfReady()
        }
        let plan = current.plan
        let capture = display.capture
        let stage = display.overlay.stage
        Task { @MainActor in
            let tSwitch = CACurrentMediaTime()
            let switched = await self.engine.execute(plan)
            guard var g = self.gesture else { return }
            g.report.switchMs = (CACurrentMediaTime() - tSwitch) * 1000
            guard switched else {
                g.link?.invalidate()
                self.hideAll()
                g.report.animated = false
                g.report.note = "finger-driven; the Dock did not switch"
                self.finish(g.report)
                self.gesture = nil
                self.switching = false
                return
            }
            g.landed = true
            self.gesture = g
            let tDone = CACurrentMediaTime()
            var first = await capture.frame(after: tDone, timeout: capture.frameInterval * 2 + 0.004)
            if first == nil, let recent = capture.latestFrame(), recent.time > tSwitch { first = recent }
            if first == nil { first = await capture.frame(after: tSwitch, timeout: 0.25) }
            guard let firstFrame = first, var live = self.gesture else { self.finishGestureIfReady(); return }
            live.report.afterFrameMs = (CACurrentMediaTime() - tDone) * 1000
            self.gesture = live
            self.held[current.displayID, default: []].append(firstFrame)
            stage.setIncomingLive(firstFrame.surface, fadeIn: 0.12)
            self.finishGestureIfReady()
            var frame = firstFrame
            let stop = CACurrentMediaTime() + duration + 0.3
            while self.gesture != nil, display.overlay.isVisible, CACurrentMediaTime() < stop {
                guard let next = await capture.frame(after: frame.time, timeout: 0.05) else { continue }
                guard self.gesture != nil, display.overlay.isVisible else { break }
                frame = next
                var kept = self.held[current.displayID] ?? []
                if kept.count > 2 { kept.removeSubrange(1..<(kept.count - 1)) }
                kept.append(next)
                self.held[current.displayID] = kept
                stage.setIncomingLive(next.surface, fadeIn: 0)
            }
        }
    }

    private func finishGestureIfReady() {
        guard var current = gesture, current.committed, current.landed, current.animationDone, !current.finished,
              let display = displays[current.displayID] else { return }
        current.finished = true
        gesture = nil
        current.link?.invalidate()
        display.overlay.hide()
        held[current.displayID] = nil
        switching = false
        finish(current.report)
        let before = current.before
        let fromSpace = current.plan.display.currentID
        let target = current.plan.target.id
        Task {
            await display.capture.remember(before, for: fromSpace)
            await display.capture.refreshFilter()
            await self.refreshWallpapers(forcing: target)
            await self.refreshPictures()
        }
    }

    private func cancelGesture() {
        guard let current = gesture, let display = displays[current.displayID] else { return }
        gesture = nil
        runLink(on: display.screen, from: current.progress, to: 0, duration: 0.18 * slowMotion) { [weak self] in
            guard let self else { return }
            display.overlay.hide()
            self.held[current.displayID] = nil
            self.switching = false
        }
        var report = current.report
        report.note = "finger-driven; swipe released early, no switch"
        finish(report)
    }

    /// Eases the scrub position from one progress to another at display rate.
    private func runLink(on screen: NSScreen, from: Double, to: Double, duration: Double, completion: @escaping () -> Void) {
        gesture?.link?.invalidate()
        let start = CACurrentMediaTime()
        let stage = displays[screen.displayID]?.overlay.stage
        var link: CADisplayLink?
        linkDriver.tick = { [weak self] in
            let t = min(1, (CACurrentMediaTime() - start) / max(0.001, duration))
            let eased = 1 - pow(1 - t, 3)
            stage?.scrub(from + (to - from) * eased)
            if t >= 1 {
                link?.invalidate()
                if var g = self?.gesture, g.link === link { g.link = nil; self?.gesture = g }
                completion()
            }
        }
        link = screen.displayLink(target: linkDriver, selector: #selector(LinkDriver.step(_:)))
        link?.add(to: .main, forMode: .common)
        if var g = gesture { g.link = link; gesture = g }
    }

    /// Plays the current effect on the focused screen using the live picture for both sides.
    public func preview() async {
        generation += 1
        let myGeneration = generation
        guard let display = displays.values.first(where: { $0.screen == NSScreen.main }) ?? displays.values.first,
              display.capture.isRunning, let frame = display.capture.latestFrame() else { return }
        let stage = display.overlay.stage
        stage.setWallpaper(display.capture.wallpaper)
        stage.setOutgoing(frame.surface)
        stage.setIncoming(frame.surface)
        stage.showResting()
        display.overlay.show()
        held[display.screen.displayID] = [frame]
        let id = display.screen.displayID
        stage.run(settings: settings, direction: .forward, timing: AnimationTiming(settings: settings, slowMotion: slowMotion)) { [weak self] in
            guard let self, myGeneration == self.generation else { return }
            display.overlay.hide()
            self.held[id] = nil
        }
    }

    /// Saves a PNG of the main display, overlay included.
    public func snapshot(to path: String) async -> Bool {
        guard let display = displays.values.first(where: { $0.screen == NSScreen.main }) ?? displays.values.first,
              let image = await display.capture.screenshot(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    private func hideAll() {
        for display in displays.values { display.overlay.hide() }
        held.removeAll()
    }

    private func finish(_ report: SwitchReport) {
        reports.append(report)
        if reports.count > 50 { reports.removeFirst(reports.count - 50) }
        log.info("\(report.summary, privacy: .public)")
        onReport?(report)
    }
}
