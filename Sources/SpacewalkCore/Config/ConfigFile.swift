import Foundation

/// The configuration lives in `~/.config/spacewalk/config.toml`, like AeroSpace's. The app writes
/// it with comments whenever a setting changes in the UI, and reloads it when it is edited by hand.
public enum ConfigFile {
    public static let appID = "dev.tgomareli.spacewalk"

    public static var directory: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("spacewalk", isDirectory: true)
    }

    public static var url: URL { directory.appendingPathComponent("config.toml") }

    public static var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Reads the file. Missing keys keep their defaults; problems come back as warnings.
    public static func load(base: SpacewalkSettings = SpacewalkSettings()) -> (settings: SpacewalkSettings, warnings: [String]) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return (base, []) }
        do {
            let table = try TOML.parse(text)
            return apply(table, to: base)
        } catch {
            return (base, [error.localizedDescription])
        }
    }

    public static func write(_ settings: SpacewalkSettings) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try render(settings).write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Reading

    static func apply(_ table: [String: TOMLValue], to base: SpacewalkSettings) -> (SpacewalkSettings, [String]) {
        var settings = base
        var warnings: [String] = []
        func string(_ path: String...) -> String? { TOML.lookup(table, path: path)?.string }
        func bool(_ path: String...) -> Bool? { TOML.lookup(table, path: path)?.bool }
        func double(_ path: String...) -> Double? { TOML.lookup(table, path: path)?.double }
        func int(_ path: String...) -> Int? { TOML.lookup(table, path: path)?.int }
        func choice<T: RawRepresentable>(_ value: String?, _ type: T.Type, key: String) -> T? where T.RawValue == String {
            guard let value else { return nil }
            if let parsed = T(rawValue: value.replacingOccurrences(of: "-", with: "")) ?? T(rawValue: value) { return parsed }
            warnings.append("\(key): unknown value \(TOML.quote(value))")
            return nil
        }

        if let v = choice(string("transition", "effect"), Effect.self, key: "transition.effect") { settings.effect = v }
        if let v = double("transition", "duration-ms") { settings.duration = max(0.05, min(5, v / 1000)) }
        if let v = choice(string("transition", "easing"), EasingPreset.self, key: "transition.easing") { settings.easing = v }
        if let v = double("transition", "bounce") { settings.bounce = max(0, min(1, v)) }
        if let v = choice(string("transition", "axis"), Orientation.self, key: "transition.axis") { settings.orientation = v }
        if let v = choice(string("transition", "direction"), DirectionMode.self, key: "transition.direction") { settings.directionMode = v }
        if let v = bool("transition", "invert-direction") { settings.invertDirection = v }
        if let v = choice(string("transition", "wallpaper"), WallpaperMode.self, key: "transition.wallpaper") { settings.wallpaperMode = v }
        if let v = double("transition", "parallax") { settings.parallax = max(0, min(1, v)) }
        if let v = double("transition", "shrink") { settings.depthScale = max(0.5, min(1, v)) }
        if let v = double("transition", "dim") { settings.dimAmount = max(0, min(1, v)) }
        if let v = double("transition", "corner-radius") { settings.cornerRadius = max(0, min(80, v)) }
        if let v = bool("transition", "pill") { settings.showWorkspacePill = v }
        if let v = bool("transition", "sound") { settings.playSound = v }

        if let shortcuts = TOML.lookup(table, path: ["shortcuts"])?.table {
            for (key, value) in shortcuts {
                guard let text = value.string else { continue }
                guard let target = target(forConfigKey: key) else { continue }
                guard let combo = KeyNames.combo(from: text) else { warnings.append("shortcuts.\(key): unknown key \(TOML.quote(text))"); continue }
                settings.setBinding(combo, for: target)
            }
            if let apps = shortcuts["apps"]?.table {
                for (bundleID, value) in apps {
                    guard let text = value.string else { continue }
                    guard let combo = KeyNames.combo(from: text) else { warnings.append("shortcuts.apps.\(bundleID): unknown key \(TOML.quote(text))"); continue }
                    settings.setBinding(combo, for: .app(bundleID))
                }
            }
        }
        if let v = bool("shortcuts", "wrap-around") { settings.wrapAround = v }
        if let v = int("shortcuts", "grid-columns") { settings.overviewColumns = max(0, min(8, v)) }

        if let v = string("trackpad", "swipe") {
            switch v {
            case "off": settings.interceptTrackpadSwipes = false
            case "instant": settings.interceptTrackpadSwipes = true; settings.interactiveSwipes = false
            case "follow": settings.interceptTrackpadSwipes = true; settings.interactiveSwipes = true
            default: warnings.append("trackpad.swipe: unknown value \(TOML.quote(v))")
            }
        }
        if let v = string("trackpad", "haptic") {
            if v == "off" { settings.hapticFeedback = false } else if let strength = HapticStrength(rawValue: v) { settings.hapticFeedback = true; settings.hapticStrength = strength } else { warnings.append("trackpad.haptic: unknown value \(TOML.quote(v))") }
        }
        if let v = bool("trackpad", "mission-control-swipe-opens-overview") { settings.gestureOverview = v }
        if let v = bool("mouse", "side-buttons") { settings.mouseButtonsSwitch = v }
        if let v = bool("mouse", "top-edge-scroll") { settings.menuBarScrollSwitch = v }

        if let v = bool("spaces", "menu-bar-indicator") { settings.menuBarIndicator = v }
        if let v = bool("spaces", "bar") { settings.spacesBar = v }
        if let v = string("spaces", "bar-position") { settings.spacesBarAtTop = v == "top" }
        if let v = bool("spaces", "switch-all-displays") { settings.switchAllDisplays = v }
        if let names = TOML.lookup(table, path: ["spaces", "names"])?.table {
            settings.spaceNames = names.compactMapValues { $0.string }.filter { !$0.value.isEmpty }
        }

        if let v = bool("advanced", "start-early") { settings.predictiveStart = v }
        if let v = bool("advanced", "keep-refreshing") { settings.eagerStart = v }
        if let v = int("advanced", "settle-frames") { settings.settleFrames = max(1, min(4, v)) }
        if let v = double("advanced", "slow-motion") { settings.slowMotion = max(1, min(60, v)) }
        if let v = bool("advanced", "launch-at-login") { settings.launchAtLogin = v }
        return (settings, warnings)
    }

    static func target(forConfigKey key: String) -> SpaceTarget? {
        if key.hasPrefix("space-"), let n = Int(key.dropFirst(6)), n >= 1, n <= 9 { return .index(n) }
        switch key {
        case "next": return .next
        case "previous": return .previous
        case "back-and-forth": return .backAndForth
        case "row-up": return .up
        case "row-down": return .down
        case "overview": return .overview
        default: return nil
        }
    }

    static func configKey(for target: SpaceTarget) -> String? {
        switch target {
        case .index(let n): return "space-\(n)"
        case .next: return "next"
        case .previous: return "previous"
        case .backAndForth: return "back-and-forth"
        case .up: return "row-up"
        case .down: return "row-down"
        case .overview: return "overview"
        case .app: return nil
        }
    }

    // MARK: Writing

    public static func render(_ s: SpacewalkSettings) -> String {
        func q(_ text: String) -> String { TOML.quote(text) }
        func num(_ value: Double) -> String { value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value) }
        var out = """
        # Spacewalk configuration. Saved by the app when you change a setting; edit by hand and
        # save, and the app applies it at once. Keys: ctrl-alt-1, cmd-shift-right, f3, keypad1…

        [transition]
        effect = \(q(s.effect.rawValue))          # instant, slide, depth, tilt, carousel, fade, zoom, cube, flip, swap, reveal, stack
        duration-ms = \(Int((s.duration * 1000).rounded()))
        easing = \(q(s.easing.rawValue))            # smooth, snappy, easeOut, easeInOut, easeIn, linear, spring
        bounce = \(num(s.bounce))                  # spring only, 0 to 1
        axis = \(q(s.orientation.rawValue))
        direction = \(q(s.directionMode.rawValue))    # byOrder, alwaysForward, alwaysBackward
        invert-direction = \(s.invertDirection)
        wallpaper = \(q(s.wallpaperMode.rawValue))      # slide only: parallax, still, moves
        parallax = \(num(s.parallax))
        shrink = \(num(s.depthScale))
        dim = \(num(s.dimAmount))
        corner-radius = \(num(s.cornerRadius))
        pill = \(s.showWorkspacePill)
        sound = \(s.playSound)

        [shortcuts]

        """
        let ordered: [SpaceTarget] = (1...9).map { .index($0) } + [.next, .previous, .backAndForth, .overview, .up, .down]
        for target in ordered {
            guard let key = configKey(for: target) else { continue }
            let combo = s.hotkeys.first { $0.target == target }?.combo
            out += "\(key) = \(q(KeyNames.text(for: combo)))\n"
        }
        out += "wrap-around = \(s.wrapAround)\ngrid-columns = \(s.overviewColumns)\n"
        let apps = s.hotkeys.compactMap { binding -> (String, KeyCombo?)? in
            if case .app(let id) = binding.target { return (id, binding.combo) }
            return nil
        }
        out += "\n[shortcuts.apps]                 # bundle id = key: go to the Space holding that app\n"
        for (id, combo) in apps.sorted(by: { $0.0 < $1.0 }) { out += "\(q(id)) = \(q(KeyNames.text(for: combo)))\n" }
        let swipe = s.interceptTrackpadSwipes ? (s.interactiveSwipes ? "follow" : "instant") : "off"
        out += """

        [trackpad]
        swipe = \(q(swipe))                   # off, instant, follow
        haptic = \(q(s.hapticFeedback ? s.hapticStrength.rawValue : "off"))     # off, light, medium, strong, double
        mission-control-swipe-opens-overview = \(s.gestureOverview)

        [mouse]
        side-buttons = \(s.mouseButtonsSwitch)
        top-edge-scroll = \(s.menuBarScrollSwitch)

        [spaces]
        menu-bar-indicator = \(s.menuBarIndicator)
        bar = \(s.spacesBar)
        bar-position = \(q(s.spacesBarAtTop ? "top" : "bottom"))
        switch-all-displays = \(s.switchAllDisplays)

        [spaces.names]                   # Space id = name

        """
        for (uuid, name) in s.spaceNames.sorted(by: { $0.key < $1.key }) { out += "\(q(uuid)) = \(q(name))\n" }
        out += """

        [advanced]
        start-early = \(s.predictiveStart)             # start moving before the Dock answers, from the last picture of the destination
        keep-refreshing = \(s.eagerStart)           # keep replacing the incoming picture while the switch settles
        settle-frames = \(s.settleFrames)
        slow-motion = \(num(s.slowMotion))               # 1 = normal; higher slows every transition for inspection
        launch-at-login = \(s.launchAtLogin)

        """
        return out
    }
}

/// Watches the config directory and reports edits that did not come from the app itself.
public final class ConfigWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1
    private let onChange: () -> Void
    private var lastSeen: String?

    public init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    /// Remember what the app wrote, so its own save does not count as an edit.
    public func noteWritten(_ text: String) { lastSeen = text }

    public func start() {
        stop()
        try? FileManager.default.createDirectory(at: ConfigFile.directory, withIntermediateDirectories: true)
        descriptor = open(ConfigFile.directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        lastSeen = try? String(contentsOf: ConfigFile.url, encoding: .utf8)
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .extend, .attrib], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // Editors write in a few steps; wait for them to finish.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                let text = try? String(contentsOf: ConfigFile.url, encoding: .utf8)
                guard text != self.lastSeen else { return }
                self.lastSeen = text
                self.onChange()
            }
        }
        source.setCancelHandler { [descriptor] in close(descriptor) }
        source.resume()
        self.source = source
    }

    public func stop() {
        source?.cancel()
        source = nil
    }
}
