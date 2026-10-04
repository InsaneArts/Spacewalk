import AppKit
import ApplicationServices

public enum SwipeDirection: Sendable {
    case left, right
}

/// Decides which space a request means and drives the switch through the Dock.
@MainActor
public final class SpaceEngine {
    public struct Plan: Sendable {
        public let display: DisplaySpaces
        public let displayID: CGDirectDisplayID?
        public let fromIndex: Int
        public let toIndex: Int
        public var steps: Int { abs(toIndex - fromIndex) }
        public var swipe: SwipeDirection { toIndex > fromIndex ? .right : .left }
        public var target: Space { display.spaces[toIndex] }
    }

    public enum PlanError: Error, LocalizedError, Equatable {
        case unavailable, noDisplay, alreadyThere, outOfRange(Int), noHistory
        public var errorDescription: String? {
            switch self {
            case .unavailable: return "space information is unavailable (SkyLight symbols missing)"
            case .noDisplay: return "no display found under the cursor"
            case .alreadyThere: return "already on that space"
            case .outOfRange(let count): return "no such space (this display has \(count))"
            case .noHistory: return "no previous space yet"
            }
        }
    }

    /// Previous space index per display UUID, for back-and-forth.
    private var history: [String: Int] = [:]
    private var lastKnown: [String: Int] = [:]

    public init() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.noteSpaceChange()
                self?.guardEmptyLanding()
            }
        }
        noteSpaceChange()
    }

    /// Landing on a space with no windows makes macOS activate some other app. If that app's window
    /// lives on another space, the Dock follows it and yanks the user away about 400 ms later.
    /// Claiming activation ourselves (a windowless accessory app) leaves nothing to follow.
    private func guardEmptyLanding() {
        let active = SkyLight.activeSpace()
        guard active != 0, !Self.spaceHasWindows(active) else { return }
        // Only a windowless app is safe to activate: a visible window of ours on another space
        // would make the Dock follow it. Overlays sit on every space, so they do not count.
        guard NSApp.windows.allSatisfy({ !$0.isVisible || $0.collectionBehavior.contains(.canJoinAllSpaces) }) else { return }
        NSApp.activate(ignoringOtherApps: true)
    }

    public struct AppBadge: Sendable {
        public let bundleID: String
        public let name: String
        public let icon: CGImage?
    }

    /// Apps with ordinary windows on `spaceID`, front to back, each once.
    public static func apps(on spaceID: UInt64) -> [AppBadge] {
        let list = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var seen: Set<pid_t> = []
        var badges: [AppBadge] = []
        for window in list {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let id = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, !seen.contains(pid),
                  let alpha = window[kCGWindowAlpha as String] as? Double, alpha > 0.01,
                  let dict = window[kCGWindowBounds as String] as? NSDictionary, let frame = CGRect(dictionaryRepresentation: dict),
                  frame.width > 40, frame.height > 40,
                  SkyLight.spaces(forWindows: [id]).contains(spaceID),
                  let app = NSRunningApplication(processIdentifier: pid), !app.isHidden, app.activationPolicy == .regular else { continue }
            seen.insert(pid)
            var rect = CGRect(x: 0, y: 0, width: 64, height: 64)
            badges.append(AppBadge(bundleID: app.bundleIdentifier ?? "pid-\(pid)", name: app.localizedName ?? "App",
                                   icon: app.icon?.cgImage(forProposedRect: &rect, context: nil, hints: nil)))
        }
        return badges
    }

    /// The Space on `display` holding the frontmost window of the app, if any.
    public static func spaceIndex(ofApp bundleID: String, in display: DisplaySpaces) -> Int? {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier))
        guard !pids.isEmpty else { return nil }
        let list = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in list {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pids.contains(pid),
                  let id = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            let spaces = SkyLight.spaces(forWindows: [id])
            if let index = display.spaces.firstIndex(where: { spaces.contains($0.id) }) { return index }
        }
        return nil
    }

    /// Ordinary windows on `spaceID`, front to back, without windows of hidden apps.
    public static func windows(on spaceID: UInt64) -> [SpaceWindow] {
        let list = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let hiddenPIDs = Set(NSWorkspace.shared.runningApplications.filter(\.isHidden).map(\.processIdentifier))
        return list.compactMap { window -> SpaceWindow? in
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let id = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, !hiddenPIDs.contains(pid),
                  let alpha = window[kCGWindowAlpha as String] as? Double, alpha > 0.01,
                  let dict = window[kCGWindowBounds as String] as? NSDictionary, let frame = CGRect(dictionaryRepresentation: dict),
                  frame.width > 40, frame.height > 40,
                  SkyLight.spaces(forWindows: [id]).contains(spaceID) else { return nil }
            return SpaceWindow(id: id, frame: frame)
        }
    }

    static func spaceHasWindows(_ spaceID: UInt64) -> Bool {
        let list = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let ids = list.compactMap { window -> UInt32? in
            guard (window[kCGWindowLayer as String] as? Int) == 0 else { return nil }
            return (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
        return SkyLight.spaces(forWindows: ids).contains(spaceID)
    }

    // MARK: State

    public var isAvailable: Bool { SkyLight.isAvailable }

    public func snapshot() -> SpaceSnapshot {
        SpaceSnapshot.parse(SkyLight.managedDisplaySpaces(), activeSpace: SkyLight.activeSpace())
    }

    /// Records index changes so back-and-forth also works after switches Spacewalk did not make.
    public func noteSpaceChange() {
        for display in snapshot().displays {
            guard let index = display.currentIndex else { continue }
            if let previous = lastKnown[display.displayUUID], previous != index {
                history[display.displayUUID] = previous
            }
            lastKnown[display.displayUUID] = index
        }
    }

    public static func uuid(for displayID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    public func displayID(forUUID uuid: String) -> CGDirectDisplayID? {
        NSScreen.screens.map(\.displayID).first { Self.uuid(for: $0) == uuid }
    }

    /// The Dock lands a swipe on the display under the mouse, not the one with keyboard focus.
    public static func cursorDisplayUUID() -> String? {
        let location = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) } ?? NSScreen.main
        return screen.flatMap { uuid(for: $0.displayID) }
    }

    // MARK: Planning

    public func plan(_ target: SpaceTarget, wrapAround: Bool = true, columns: Int = 0) -> Result<Plan, PlanError> {
        guard isAvailable else { return .failure(.unavailable) }
        let snapshot = snapshot()
        let cursorUUID = Self.cursorDisplayUUID()
        guard let display = cursorUUID.flatMap({ snapshot.display(uuid: $0) }) ?? snapshot.displays.first,
              let from = display.currentIndex else { return .failure(.noDisplay) }
        let to: Int
        switch target {
        case .index(let number):
            to = number - 1
            guard display.spaces.indices.contains(to) else { return .failure(.outOfRange(display.count)) }
        case .next:
            guard from + 1 < display.count || wrapAround else { return .failure(.outOfRange(display.count)) }
            to = from + 1 < display.count ? from + 1 : 0
        case .previous:
            guard from > 0 || wrapAround else { return .failure(.outOfRange(display.count)) }
            to = from > 0 ? from - 1 : display.count - 1
        case .backAndForth:
            guard let previous = history[display.displayUUID], display.spaces.indices.contains(previous) else { return .failure(.noHistory) }
            to = previous
        case .up, .down:
            let step = max(1, columns)
            let candidate = target == .up ? from - step : from + step
            guard display.spaces.indices.contains(candidate) else { return .failure(.outOfRange(display.count)) }
            to = candidate
        case .overview:
            return .failure(.alreadyThere)
        case .app(let bundleID):
            guard let found = Self.spaceIndex(ofApp: bundleID, in: display) else { return .failure(.noHistory) }
            to = found
        }
        guard to != from else { return .failure(.alreadyThere) }
        return .success(Plan(display: display, displayID: displayID(forUUID: display.displayUUID), fromIndex: from, toIndex: to))
    }

    // MARK: Switching

    /// Posts the synthetic swipes and waits until the Dock reports the target space, or times out.
    public func execute(_ plan: Plan, timeout: Double = 0.6) async -> Bool {
        history[plan.display.displayUUID] = plan.fromIndex
        lastKnown[plan.display.displayUUID] = plan.toIndex
        var remaining = plan.steps
        var attempts = 0
        while remaining > 0, attempts < 2 {
            attempts += 1
            DockSwipe.post(plan.swipe, steps: remaining)
            let deadline = CACurrentMediaTime() + timeout
            while CACurrentMediaTime() < deadline {
                try? await Task.sleep(nanoseconds: 3_000_000)
                if let current = snapshot().display(uuid: plan.display.displayUUID)?.currentIndex {
                    if current == plan.toIndex { return true }
                    remaining = abs(plan.toIndex - current)
                }
            }
        }
        return snapshot().display(uuid: plan.display.displayUUID)?.currentIndex == plan.toIndex
    }

    // MARK: Permissions and system shortcuts

    public static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    @discardableResult
    public static func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// The system's own ⌃← and ⌃→ (symbolic hotkeys 79 and 81) consume the keys before any app.
    /// Turn them off live and persist the choice for future logins, with properly typed values.
    public static func setSystemArrowShortcuts(enabled: Bool) {
        let domain = "com.apple.symbolichotkeys" as CFString
        var hotkeys = (CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, domain) as? [String: Any]) ?? [:]
        for (id, keyCode) in [(79, 123), (81, 124)] {
            SkyLight.setSymbolicHotKey(Int32(id), enabled: enabled)
            var entry = hotkeys[String(id)] as? [String: Any] ?? [:]
            entry["enabled"] = enabled
            if entry["value"] == nil {
                entry["value"] = ["parameters": [65535, keyCode, 8650752], "type": "standard"]
            }
            hotkeys[String(id)] = entry
        }
        CFPreferencesSetAppValue("AppleSymbolicHotKeys" as CFString, hotkeys as CFDictionary, domain)
        CFPreferencesAppSynchronize(domain)
    }

    /// macOS reorders Spaces by recent use unless this Dock preference is off. It breaks numbered switching.
    public static var autoRearrangeEnabled: Bool {
        let domain = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(domain)
        guard let value = CFPreferencesCopyAppValue("mru-spaces" as CFString, domain) else { return true }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String { return text != "0" && text.lowercased() != "false" }
        return true
    }

    /// Turns the reordering off and restarts the Dock, which is what System Settings does too.
    public static func disableAutoRearrange() {
        let domain = "com.apple.dock" as CFString
        CFPreferencesSetAppValue("mru-spaces" as CFString, kCFBooleanFalse, domain)
        CFPreferencesAppSynchronize(domain)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        try? process.run()
    }

    /// Moves the pointer to a display so the Dock routes the next swipe there. Returns the old position.
    public static func warpCursor(toCenterOf displayID: CGDirectDisplayID) -> CGPoint {
        let before = CGEvent(source: nil)?.location ?? .zero
        let bounds = CGDisplayBounds(displayID)
        CGWarpMouseCursorPosition(CGPoint(x: bounds.midX, y: bounds.midY))
        return before
    }

    public static func warpCursor(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
    }

    public static var systemArrowShortcutsEnabled: Bool {
        let domain = "com.apple.symbolichotkeys" as CFString
        CFPreferencesAppSynchronize(domain)
        guard let hotkeys = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, domain) as? [String: Any],
              let entry = hotkeys["79"] as? [String: Any] else { return true }
        if let number = entry["enabled"] as? NSNumber { return number.boolValue }
        if let text = entry["enabled"] as? String { return text != "0" }
        return true
    }
}
