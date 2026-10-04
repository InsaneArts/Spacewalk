import Foundation

/// Which visual transition plays between two workspaces.
public enum Effect: String, CaseIterable, Codable, Identifiable, Sendable {
    case instant, slide, depth, tilt, carousel, fade, zoom, cube, flip, swap, reveal, stack
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .instant: return "Instant (no animation)"
        case .slide: return "Slide"
        case .depth: return "Slide with depth"
        case .tilt: return "Tilt slide"
        case .carousel: return "Carousel"
        case .fade: return "Fade through"
        case .zoom: return "Zoom"
        case .cube: return "Cube"
        case .flip: return "Flip"
        case .swap: return "Swap"
        case .reveal: return "Reveal"
        case .stack: return "Stack"
        }
    }
    /// Effects that stack the two pictures need each side to be a full opaque picture.
    public var needsOpaqueCards: Bool { self != .slide }

    /// Effects that round the cards and need the corner radius control.
    public var usesCards: Bool { [.depth, .tilt, .carousel, .zoom, .swap, .reveal, .stack].contains(self) }

    public var summary: String {
        switch self {
        case .instant: return "The Dock switches with no animation at all. Spacewalk stays out of the way."
        case .slide: return "Both workspaces move as one strip. The macOS look."
        case .depth: return "The old workspace sinks and dims while the new one slides over it."
        case .tilt: return "Cards lean into the motion as they slide past, the Safari tab look."
        case .carousel: return "Both workspaces shrink, slide past, and grow back. The app switcher look."
        case .fade: return "The new workspace fades in over the old one with a slight scale."
        case .zoom: return "The old workspace grows and fades, the new one settles in from smaller."
        case .cube: return "Workspaces are faces of a rotating cube."
        case .flip: return "The workspace flips over like a card to show the new one on its back."
        case .swap: return "The two workspaces trade places, the new one passing in front."
        case .reveal: return "The old workspace slides away and uncovers the new one underneath."
        case .stack: return "The new workspace rises as a card; the old one recedes."
        }
    }
}

public enum EasingPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case smooth, snappy, easeOut, easeInOut, easeIn, linear, spring
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .smooth: return "Smooth"
        case .snappy: return "Snappy"
        case .easeOut: return "Ease out"
        case .easeInOut: return "Ease in-out"
        case .easeIn: return "Ease in"
        case .linear: return "Linear"
        case .spring: return "Spring"
        }
    }
    /// Cubic bezier control points, nil for spring.
    public var controlPoints: (Float, Float, Float, Float)? {
        switch self {
        case .smooth: return (0.4, 0.0, 0.2, 1.0)
        case .snappy: return (0.2, 0.9, 0.2, 1.0)
        case .easeOut: return (0.0, 0.0, 0.58, 1.0)
        case .easeInOut: return (0.42, 0.0, 0.58, 1.0)
        case .easeIn: return (0.42, 0.0, 1.0, 1.0)
        case .linear: return (0.0, 0.0, 1.0, 1.0)
        case .spring: return nil
        }
    }
}

public enum Orientation: String, CaseIterable, Codable, Sendable {
    case horizontal, vertical
}

/// What the wallpaper does during a plain slide.
public enum WallpaperMode: String, CaseIterable, Codable, Sendable {
    /// Each workspace carries its wallpaper, the macOS look.
    case moves
    /// The wallpaper stays put and only windows slide, the compositor look.
    case still
    /// The wallpaper drifts a little behind the windows and crossfades, which reads as depth.
    case parallax
}

/// How hard the trackpad clicks when a swipe reaches the switching point.
public enum HapticStrength: String, CaseIterable, Codable, Identifiable, Sendable {
    case light, medium, strong, double
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .light: return "Light"
        case .medium: return "Medium"
        case .strong: return "Strong"
        case .double: return "Double"
        }
    }
}

public enum DirectionMode: String, CaseIterable, Codable, Sendable {
    /// Higher space = forward, in Mission Control order.
    case byOrder
    case alwaysForward
    case alwaysBackward
}

/// A global hotkey: virtual key code plus Carbon modifier flags.
public struct KeyCombo: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// Everything a hotkey can ask for. `index` is 1-based, in Mission Control order.
public enum SpaceTarget: Codable, Equatable, Hashable, Sendable {
    case index(Int)
    case next
    case previous
    case backAndForth
    /// One row up or down in the virtual grid (`overviewColumns` wide).
    case up
    case down
    /// Open the overview of all Spaces.
    case overview
    /// Go to the Space holding this app's frontmost window (bundle identifier).
    case app(String)
}

public struct HotkeyBinding: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var combo: KeyCombo?
    public var target: SpaceTarget
    public init(id: UUID = UUID(), combo: KeyCombo? = nil, target: SpaceTarget) {
        self.id = id
        self.combo = combo
        self.target = target
    }
}

public struct SpacewalkSettings: Codable, Equatable, Sendable {
    public var enabled = true
    public var effect: Effect = .depth
    /// Seconds. For springs this is the perceptual duration.
    public var duration: Double = 0.24
    public var easing: EasingPreset = .smooth
    /// 0 = no bounce, 1 = very bouncy. Spring only.
    public var bounce: Double = 0.15
    public var orientation: Orientation = .horizontal
    public var directionMode: DirectionMode = .byOrder
    public var invertDirection = false
    /// What the wallpaper does during a plain slide. Other effects always carry it in their cards.
    public var wallpaperMode: WallpaperMode = .parallax
    /// Kept for settings files written before `wallpaperMode` existed.
    public var wallpaperMoves: Bool {
        get { wallpaperMode == .moves }
        set { wallpaperMode = newValue ? .moves : .still }
    }
    /// How far the receding workspace travels, as a fraction of the incoming one. Depth only.
    public var parallax: Double = 0.3
    /// Scale the receding workspace shrinks to. Depth, zoom, stack.
    public var depthScale: Double = 0.94
    /// Darkening applied to the receding workspace at the end of the transition.
    public var dimAmount: Double = 0.25
    /// Corner radius in points for card-like effects (stack, zoom, depth).
    public var cornerRadius: Double = 12
    public var hotkeys: [HotkeyBinding] = SpacewalkSettings.defaultHotkeys
    /// How many quiet frames mean the new picture has settled.
    public var settleFrames = 1
    /// Start the animation on the first changed frame and keep refreshing the incoming picture while it settles.
    public var eagerStart = true
    /// Start moving before the Dock answers, from the last picture Spacewalk saw of the destination.
    public var predictiveStart = true
    /// Replace real three-finger swipes with Spacewalk switches.
    public var interceptTrackpadSwipes = false
    /// Let the transition follow the fingers and finish with the fling, instead of playing on the first event.
    public var interactiveSwipes = true
    /// A trackpad tick when a swipe crosses the point where it will switch.
    public var hapticFeedback = true
    public var hapticStrength: HapticStrength = .strong
    /// A small capsule naming the destination while switching.
    public var showWorkspacePill = false
    /// A short synthesized whoosh on every switch.
    public var playSound = false
    /// Names per Space UUID, shown in the pill, the overview and the menu bar.
    public var spaceNames: [String: String] = [:]
    /// Width of the virtual grid for up/down navigation and the overview layout. 0 = one row.
    public var overviewColumns = 0
    /// Show the current Space in the menu bar instead of the plain icon.
    public var menuBarIndicator = true
    /// Mouse side buttons (4 and 5) switch to the previous and next Space.
    public var mouseButtonsSwitch = false
    /// Scrolling with the pointer against the top edge of the screen switches Spaces.
    public var menuBarScrollSwitch = false
    /// Gestures and mouse triggers wrap from the last Space to the first.
    public var wrapAround = true
    /// With "Displays have separate Spaces", switch every display to the same position.
    public var switchAllDisplays = false
    /// Replace the Mission Control swipe with Spacewalk's overview, zooming with the fingers.
    public var gestureOverview = false
    /// A thin bar listing Spaces with their app icons; click to switch.
    public var spacesBar = false
    public var spacesBarAtTop = false
    /// Multiplies every transition's duration; for inspection only.
    public var slowMotion: Double = 1
    public var launchAtLogin = false

    public init() {}

    // Tolerant decoding: keys missing from an older settings file keep their defaults.
    private enum CodingKeys: String, CodingKey {
        case enabled, effect, duration, easing, bounce, orientation, directionMode, invertDirection, wallpaperMode
        case parallax, depthScale, dimAmount, cornerRadius, hotkeys, settleFrames, eagerStart, predictiveStart, interceptTrackpadSwipes
        case interactiveSwipes, hapticFeedback, hapticStrength, showWorkspacePill, playSound, launchAtLogin
        case spaceNames, overviewColumns, menuBarIndicator, mouseButtonsSwitch, menuBarScrollSwitch, wrapAround, switchAllDisplays
        case gestureOverview, spacesBar, spacesBarAtTop, slowMotion
    }

    private enum LegacyKeys: String, CodingKey { case wallpaperMoves }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let base = SpacewalkSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? base.enabled
        effect = (try? c.decodeIfPresent(Effect.self, forKey: .effect)) ?? base.effect
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? base.duration
        easing = try c.decodeIfPresent(EasingPreset.self, forKey: .easing) ?? base.easing
        bounce = try c.decodeIfPresent(Double.self, forKey: .bounce) ?? base.bounce
        orientation = try c.decodeIfPresent(Orientation.self, forKey: .orientation) ?? base.orientation
        directionMode = try c.decodeIfPresent(DirectionMode.self, forKey: .directionMode) ?? base.directionMode
        invertDirection = try c.decodeIfPresent(Bool.self, forKey: .invertDirection) ?? base.invertDirection
        if let mode = try? c.decodeIfPresent(WallpaperMode.self, forKey: .wallpaperMode) {
            wallpaperMode = mode
        } else if let moves = try legacy.decodeIfPresent(Bool.self, forKey: .wallpaperMoves) {
            wallpaperMode = moves ? .moves : .still
        } else {
            wallpaperMode = base.wallpaperMode
        }
        parallax = try c.decodeIfPresent(Double.self, forKey: .parallax) ?? base.parallax
        depthScale = try c.decodeIfPresent(Double.self, forKey: .depthScale) ?? base.depthScale
        dimAmount = try c.decodeIfPresent(Double.self, forKey: .dimAmount) ?? base.dimAmount
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? base.cornerRadius
        var decodedHotkeys = try c.decodeIfPresent([HotkeyBinding].self, forKey: .hotkeys) ?? base.hotkeys
        for binding in base.hotkeys where !decodedHotkeys.contains(where: { $0.target == binding.target }) {
            decodedHotkeys.append(binding)
        }
        hotkeys = decodedHotkeys
        settleFrames = try c.decodeIfPresent(Int.self, forKey: .settleFrames) ?? base.settleFrames
        eagerStart = try c.decodeIfPresent(Bool.self, forKey: .eagerStart) ?? base.eagerStart
        predictiveStart = try c.decodeIfPresent(Bool.self, forKey: .predictiveStart) ?? base.predictiveStart
        interceptTrackpadSwipes = try c.decodeIfPresent(Bool.self, forKey: .interceptTrackpadSwipes) ?? base.interceptTrackpadSwipes
        interactiveSwipes = try c.decodeIfPresent(Bool.self, forKey: .interactiveSwipes) ?? base.interactiveSwipes
        hapticFeedback = try c.decodeIfPresent(Bool.self, forKey: .hapticFeedback) ?? base.hapticFeedback
        hapticStrength = (try? c.decodeIfPresent(HapticStrength.self, forKey: .hapticStrength)) ?? base.hapticStrength
        showWorkspacePill = try c.decodeIfPresent(Bool.self, forKey: .showWorkspacePill) ?? base.showWorkspacePill
        playSound = try c.decodeIfPresent(Bool.self, forKey: .playSound) ?? base.playSound
        spaceNames = try c.decodeIfPresent([String: String].self, forKey: .spaceNames) ?? base.spaceNames
        overviewColumns = try c.decodeIfPresent(Int.self, forKey: .overviewColumns) ?? base.overviewColumns
        menuBarIndicator = try c.decodeIfPresent(Bool.self, forKey: .menuBarIndicator) ?? base.menuBarIndicator
        mouseButtonsSwitch = try c.decodeIfPresent(Bool.self, forKey: .mouseButtonsSwitch) ?? base.mouseButtonsSwitch
        menuBarScrollSwitch = try c.decodeIfPresent(Bool.self, forKey: .menuBarScrollSwitch) ?? base.menuBarScrollSwitch
        wrapAround = try c.decodeIfPresent(Bool.self, forKey: .wrapAround) ?? base.wrapAround
        switchAllDisplays = try c.decodeIfPresent(Bool.self, forKey: .switchAllDisplays) ?? base.switchAllDisplays
        gestureOverview = try c.decodeIfPresent(Bool.self, forKey: .gestureOverview) ?? base.gestureOverview
        spacesBar = try c.decodeIfPresent(Bool.self, forKey: .spacesBar) ?? base.spacesBar
        spacesBarAtTop = try c.decodeIfPresent(Bool.self, forKey: .spacesBarAtTop) ?? base.spacesBarAtTop
        slowMotion = try c.decodeIfPresent(Double.self, forKey: .slowMotion) ?? base.slowMotion
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? base.launchAtLogin
    }

    /// Sets or clears the key of a target, adding the binding if the list lacks it.
    public mutating func setBinding(_ combo: KeyCombo?, for target: SpaceTarget) {
        if let index = hotkeys.firstIndex(where: { $0.target == target }) {
            hotkeys[index].combo = combo
        } else {
            hotkeys.append(HotkeyBinding(combo: combo, target: target))
        }
    }

    public static let defaultHotkeys: [HotkeyBinding] = (1...9).map {
        HotkeyBinding(target: .index($0))
    } + [
        HotkeyBinding(target: .next),
        HotkeyBinding(target: .previous),
        HotkeyBinding(target: .up),
        HotkeyBinding(target: .down),
        HotkeyBinding(target: .backAndForth),
        HotkeyBinding(target: .overview),
    ]
}

public enum SettingsStore {
    static let legacyKey = "settings"

    public static var defaults: UserDefaults { .standard }

    /// The config file, or the old UserDefaults blob migrated into one, or the defaults.
    public static func load() -> SpacewalkSettings {
        if ConfigFile.exists { return ConfigFile.load().settings }
        var settings = SpacewalkSettings()
        // The settings blob from before the config file existed, under either of the app's old and new ids.
        let stores = [defaults, UserDefaults(suiteName: "dev.tgomareli.glide")].compactMap { $0 }
        if let data = stores.lazy.compactMap({ $0.data(forKey: legacyKey) }).first,
           let legacy = try? JSONDecoder().decode(SpacewalkSettings.self, from: data) {
            settings = legacy
        }
        try? ConfigFile.write(settings)
        return settings
    }

    public static func save(_ settings: SpacewalkSettings) {
        try? ConfigFile.write(settings)
    }

    public static func export(_ settings: SpacewalkSettings, to url: URL) throws {
        try ConfigFile.render(settings).write(to: url, atomically: true, encoding: .utf8)
    }

    public static func importSettings(from url: URL) throws -> SpacewalkSettings {
        let table = try TOML.parse(try String(contentsOf: url, encoding: .utf8))
        return ConfigFile.apply(table, to: SpacewalkSettings()).0
    }
}
