import AppKit
import ScreenCaptureKit
import ServiceManagement
import SpacewalkCore

@MainActor
@Observable
final class AppModel {
    var settings: SpacewalkSettings {
        didSet { settingsChanged(from: oldValue) }
    }
    var lastReport: SwitchReport?
    var reports: [SwitchReport] = []
    var displayStatus: [DisplayStatus] = []
    var captureAccess = CaptureAccess.granted
    var accessibilityAccess = SpaceEngine.accessibilityGranted
    var systemArrowsEnabled = SpaceEngine.systemArrowShortcutsEnabled
    var autoRearrange = SpaceEngine.autoRearrangeEnabled
    var spaces: [DisplaySpaces] = []
    var launchAtLoginError: String?
    var transferNote: String?
    var configWarnings: [String] = []
    var showOnboarding = false
    private var loadingFromFile = false
    private var watcher: ConfigWatcher?
    let switcher: Switcher
    let updater = UpdaterService()
    private let settingsWindow = SettingsWindowController()
    private let interceptor = SwipeInterceptor()
    private let mouse = MouseTriggers()

    init() {
        let loaded = SettingsStore.load()
        settings = loaded
        switcher = Switcher(settings: loaded)
        switcher.slowMotion = loaded.slowMotion
        configWarnings = ConfigFile.load().warnings
        switcher.onReport = { [weak self] report in
            guard let self else { return }
            lastReport = report
            reports = switcher.reports.reversed()
            writeStatus()
        }
    }

    func start() async {
        SpacewalkIPC.writePIDFile()
        let watcher = ConfigWatcher { [weak self] in self?.reloadFromFile() }
        watcher.noteWritten(ConfigFile.render(settings))
        watcher.start()
        self.watcher = watcher
        captureAccess = CaptureAccess.request()
        accessibilityAccess = SpaceEngine.requestAccessibility()
        registerHotkeys()
        listenForCommands()
        interceptor.onSwipe = { [weak self] direction in self?.perform(direction == .right ? .next : .previous) }
        interceptor.onGesture = { [weak self] event in self?.switcher.gesture(event) }
        mouse.onSwitch = { [weak self] direction in self?.perform(direction == .right ? .next : .previous) }
        applyInterceptor()
        applyMouse()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshSpaces() }
        }
        refreshSpaces()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { await self?.refreshDisplays() }
        }
        await refreshDisplays()
        if settings.launchAtLogin { applyLaunchAtLogin() }
        updater.start()
        if !captureAccess || !accessibilityAccess {
            showOnboarding = true
            openSettingsWindow()
        }
    }

    func stop() {
        SpacewalkIPC.removePIDFile()
    }

    func refreshDisplays() async {
        captureAccess = CaptureAccess.granted
        accessibilityAccess = SpaceEngine.accessibilityGranted
        await switcher.attachDisplays()
        displayStatus = switcher.displayStatus
        applyInterceptor()
        refreshSpaces()
    }

    func refreshSpaces() {
        spaces = switcher.engine.snapshot().displays
        systemArrowsEnabled = SpaceEngine.systemArrowShortcutsEnabled
        autoRearrange = SpaceEngine.autoRearrangeEnabled
        writeStatus()
        switcher.refreshBars()
        Task {
            await switcher.refreshWallpapers()
            await switcher.refreshPictures()
        }
    }

    // MARK: App bindings and settings files

    func addAppBinding() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.message = "Choose the app whose Space the hotkey should jump to"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        if !settings.hotkeys.contains(where: { $0.target == .app(id) }) {
            settings.hotkeys.append(HotkeyBinding(target: .app(id)))
        }
    }

    func removeBinding(_ id: UUID) {
        settings.hotkeys.removeAll { $0.id == id }
    }

    func exportSettings() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "spacewalk.toml"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try SettingsStore.export(settings, to: url); transferNote = "Exported" } catch { transferNote = error.localizedDescription }
    }

    func importSettings() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var imported = try SettingsStore.importSettings(from: url)
            imported.spaceNames = settings.spaceNames.merging(imported.spaceNames) { _, new in new }
            settings = imported
            transferNote = "Imported"
        } catch { transferNote = error.localizedDescription }
    }

    /// Snapshot for `spacewalk status`.
    /// Saves a PNG of the settings window alone, nothing else on screen.
    func snapshotSettingsWindow(to path: String) async -> Bool {
        guard let number = settingsWindow.windowNumber,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let target = content.windows.first(where: { $0.windowID == CGWindowID(number) }) else { return false }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let config = SCStreamConfiguration()
        config.width = Int(target.frame.width * scale)
        config.height = Int(target.frame.height * scale)
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: config),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    func writeStatus() {
        var status: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "enabled": settings.enabled,
            "captureAccess": captureAccess,
            "effect": settings.effect.rawValue,
            "durationMs": Int(settings.duration * 1000),
            "slowMotion": settings.slowMotion,
            "config": ConfigFile.url.path,
            "previewEffect": UserDefaults.standard.string(forKey: "debug.previewEffect") ?? "",
            "configWarnings": configWarnings,
            "eagerStart": settings.eagerStart,
            "predictiveStart": settings.predictiveStart,
            "interactiveSwipes": settings.interactiveSwipes,
            "haptic": settings.hapticFeedback,
            "hapticStrength": settings.hapticStrength.rawValue,
            "pill": settings.showWorkspacePill,
            "sound": settings.playSound,
            "wallpaperMode": settings.wallpaperMode.rawValue,
            "accessibility": accessibilityAccess,
            "systemArrowShortcuts": systemArrowsEnabled,
            "trackpadIntercept": interceptor.isActive,
            "hotkeys": settings.hotkeys.compactMap { binding -> String? in
                guard let combo = binding.combo else { return nil }
                return "\(combo.displayString) → \(binding.target)"
            },
            "autoRearrange": autoRearrange,
            "bar": settings.spacesBar,
            "gestureOverview": settings.gestureOverview,
            "spaces": spaces.map { display in ["display": display.displayUUID, "current": display.currentIndex ?? -1, "count": display.count,
                                                "labels": (0..<display.count).map { display.label(at: $0, names: settings.spaceNames) }] },
            "displays": displayStatus.map { ["name": $0.name, "running": $0.running, "error": $0.error ?? ""] },
            "screens": NSScreen.screens.map { ["name": $0.localizedName, "points": "\(Int($0.frame.width))x\(Int($0.frame.height))", "scale": $0.backingScaleFactor, "fps": $0.maximumFramesPerSecond] },
            "recent": reports.prefix(10).map(\.summary),
        ]
        if let report = lastReport { status["lastSwitch"] = report.summary }
        if let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: SpacewalkIPC.statusFile, options: .atomic)
        }
    }

    var statusLine: String {
        if !captureAccess { return "Screen Recording permission missing" }
        if !accessibilityAccess { return "Accessibility permission missing" }
        let running = displayStatus.filter(\.running).count
        if running == 0 { return "No capture stream" }
        return "Ready on \(running) display\(running == 1 ? "" : "s")"
    }

    /// "2 ⁄ 3": current position on the display under the pointer, for the menu bar.
    var menuBarLabel: String {
        let uuid = SpaceEngine.cursorDisplayUUID()
        guard let display = spaces.first(where: { $0.displayUUID == uuid }) ?? spaces.first, let index = display.currentIndex else { return "Spacewalk" }
        return "\(index + 1) ⁄ \(display.count)"
    }

    func label(_ display: DisplaySpaces, at index: Int) -> String {
        display.label(at: index, names: settings.spaceNames)
    }

    func setName(_ name: String, forSpace uuid: String) {
        guard !uuid.isEmpty else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { settings.spaceNames[uuid] = nil } else { settings.spaceNames[uuid] = trimmed }
    }

    func disableAutoRearrange() {
        SpaceEngine.disableAutoRearrange()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refreshSpaces() }
    }

    // MARK: Actions

    func perform(_ target: SpaceTarget) {
        Task { await switcher.perform(target) }
    }

    func preview() {
        Task { await switcher.preview() }
    }

    func openSettingsWindow() {
        settingsWindow.show(model: self)
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Hands ⌃← and ⌃→ to Spacewalk by switching the system's own shortcuts off, or gives them back.
    func setSystemArrows(enabled: Bool) {
        SpaceEngine.setSystemArrowShortcuts(enabled: enabled)
        systemArrowsEnabled = enabled
        for index in settings.hotkeys.indices {
            switch settings.hotkeys[index].target {
            case .next: settings.hotkeys[index].combo = enabled ? nil : KeyCombo(keyCode: 124, modifiers: 4096)
            case .previous: settings.hotkeys[index].combo = enabled ? nil : KeyCombo(keyCode: 123, modifiers: 4096)
            default: break
            }
        }
    }

    func useControlDigits() {
        // Virtual key codes for the digit row 1...9 on ANSI layouts.
        let digitCodes: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        for index in settings.hotkeys.indices {
            if case .index(let digit) = settings.hotkeys[index].target, (1...9).contains(digit) {
                settings.hotkeys[index].combo = KeyCombo(keyCode: digitCodes[digit - 1], modifiers: 4096)
            }
        }
    }

    func clearDigits() {
        for index in settings.hotkeys.indices {
            if case .index = settings.hotkeys[index].target { settings.hotkeys[index].combo = nil }
        }
    }

    func clearHotkeys() {
        for index in settings.hotkeys.indices { settings.hotkeys[index].combo = nil }
    }

    // MARK: Plumbing

    /// The file changed outside the app: adopt it without writing it back.
    func reloadFromFile() {
        let (loaded, warnings) = ConfigFile.load()
        var next = loaded
        next.enabled = settings.enabled
        configWarnings = warnings
        loadingFromFile = true
        settings = next
        loadingFromFile = false
        writeStatus()
    }

    var configPath: String { ConfigFile.url.path }

    func revealConfig() { NSWorkspace.shared.activateFileViewerSelecting([ConfigFile.url]) }

    func appName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return (Bundle(url: url)?.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (Bundle(url: url)?.infoDictionary?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
    }

    private func settingsChanged(from old: SpacewalkSettings) {
        if !loadingFromFile {
            SettingsStore.save(settings)
            watcher?.noteWritten(ConfigFile.render(settings))
        }
        switcher.settings = settings
        switcher.slowMotion = settings.slowMotion
        if old.hotkeys != settings.hotkeys { registerHotkeys() }
        if old.launchAtLogin != settings.launchAtLogin { applyLaunchAtLogin() }
        if old.interceptTrackpadSwipes != settings.interceptTrackpadSwipes || old.interactiveSwipes != settings.interactiveSwipes || old.gestureOverview != settings.gestureOverview { applyInterceptor() }
        if old.spacesBar != settings.spacesBar || old.spacesBarAtTop != settings.spacesBarAtTop || old.spaceNames != settings.spaceNames { switcher.refreshBars() }
        if old.mouseButtonsSwitch != settings.mouseButtonsSwitch || old.menuBarScrollSwitch != settings.menuBarScrollSwitch { applyMouse() }
        writeStatus()
    }

    private func applyMouse() {
        mouse.buttonsEnabled = settings.mouseButtonsSwitch
        mouse.edgeScrollEnabled = settings.menuBarScrollSwitch
        if (settings.mouseButtonsSwitch || settings.menuBarScrollSwitch), accessibilityAccess {
            mouse.start()
        } else {
            mouse.stop()
        }
    }

    private func applyInterceptor() {
        interceptor.interactive = settings.interactiveSwipes
        interceptor.overviewGestures = settings.gestureOverview
        if settings.interceptTrackpadSwipes, accessibilityAccess {
            interceptor.start()
        } else {
            interceptor.stop()
        }
    }

    private func registerHotkeys() {
        HotKeyCenter.shared.unregisterAll()
        for binding in settings.hotkeys {
            guard let combo = binding.combo else { continue }
            let target = binding.target
            HotKeyCenter.shared.register(combo) { [weak self] in self?.perform(target) }
        }
    }

    private func listenForCommands() {
        DistributedNotificationCenter.default().addObserver(forName: SpacewalkIPC.commandNotification, object: nil, queue: .main) { [weak self] note in
            if let text = note.userInfo?[SpacewalkIPC.targetKey] as? String, let target = SpacewalkIPC.decode(text) {
                Task { @MainActor in self?.perform(target) }
            } else if let command = note.userInfo?[SpacewalkIPC.commandKey] as? String {
                Task { @MainActor in
                    switch command {
                    case "preview": self?.preview()
                    case "open-settings": self?.openSettingsWindow()
                    case "overview": self?.switcher.showOverview()
                    case "fix-rearrange": self?.disableAutoRearrange()
                    case "bind-arrows": self?.setSystemArrows(enabled: false)
                    case "unbind-arrows": self?.setSystemArrows(enabled: true)
                    case "bind-digits": self?.useControlDigits()
                    case "unbind-digits": self?.clearDigits()
                    case "bind-swipes": self?.settings.interceptTrackpadSwipes = true
                    case "unbind-swipes": self?.settings.interceptTrackpadSwipes = false
                    default:
                        let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
                        guard parts.count == 2, let self else { return }
                        switch parts[0] {
                        case "effect": if let effect = Effect(rawValue: parts[1]) { self.settings.effect = effect }
                        case "slowmo": self.settings.slowMotion = max(1, Double(parts[1]) ?? 1)
                        case "duration": if let ms = Double(parts[1]) { self.settings.duration = max(0.05, min(5, ms / 1000)) }
                        case "set":
                            let pair = parts[1].split(separator: "=", maxSplits: 1).map(String.init)
                            guard pair.count == 2 else { return }
                            let on = ["on", "true", "1", "yes"].contains(pair[1].lowercased())
                            switch pair[0] {
                            case "pill": self.settings.showWorkspacePill = on
                            case "sound": self.settings.playSound = on
                            case "haptic":
                                if let strength = HapticStrength(rawValue: pair[1].lowercased()) {
                                    self.settings.hapticStrength = strength
                                    self.settings.hapticFeedback = true
                                    HapticTick.perform(strength)
                                } else {
                                    self.settings.hapticFeedback = on
                                }
                            case "interactive": self.settings.interactiveSwipes = on
                            case "predictive": self.settings.predictiveStart = on
                            case "eager": self.settings.eagerStart = on
                            case "animations": self.settings.enabled = on
                            case "indicator": self.settings.menuBarIndicator = on
                            case "buttons": self.settings.mouseButtonsSwitch = on
                            case "edgescroll": self.settings.menuBarScrollSwitch = on
                            case "wrap": self.settings.wrapAround = on
                            case "alldisplays": self.settings.switchAllDisplays = on
                            case "bar": self.settings.spacesBar = on
                            case "bartop": self.settings.spacesBarAtTop = on
                            case "gestureoverview": self.settings.gestureOverview = on
                            default: break
                            }
                        case "snapshot":
                            // `path|settings` captures only the settings window, for checking the preview.
                            let target = parts[1].split(separator: "|", maxSplits: 1).map(String.init)
                            if target.count == 2, target[1] == "settings" {
                                Task { _ = await self.snapshotSettingsWindow(to: target[0]) }
                            } else {
                                Task { _ = await self.switcher.snapshot(to: parts[1]) }
                            }
                        case "name":
                            let pair = parts[1].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                            guard pair.count == 2, let number = Int(pair[0]),
                                  let display = self.spaces.first(where: { $0.displayUUID == SpaceEngine.cursorDisplayUUID() }) ?? self.spaces.first,
                                  display.spaces.indices.contains(number - 1) else { return }
                            self.setName(pair[1], forSpace: display.spaces[number - 1].uuid)
                        case "columns": if let n = Int(parts[1]) { self.settings.overviewColumns = max(0, min(8, n)) }
                        case "export":
                            do { try SettingsStore.export(self.settings, to: URL(fileURLWithPath: parts[1])) } catch {}
                        case "import":
                            if var imported = try? SettingsStore.importSettings(from: URL(fileURLWithPath: parts[1])) {
                                imported.spaceNames = self.settings.spaceNames.merging(imported.spaceNames) { _, new in new }
                                self.settings = imported
                            }
                        case "wallpapers":
                            Task {
                                let result = await self.switcher.dumpWallpapers(to: parts[1])
                                try? result.write(toFile: parts[1] + "/result.txt", atomically: true, encoding: .utf8)
                            }
                        case "render":
                            // dir, dir|full, dir|scrub, or dir|scrub|<frames> for an evenly sampled run.
                            let fields = parts[1].split(separator: "|").map(String.init)
                            let directory = fields[0]
                            let full = fields.dropFirst().contains("full")
                            let scrub = fields.dropFirst().contains("scrub")
                            let frames = fields.dropFirst().compactMap { Int($0) }.first
                            let result = FrameRenderer.render(settings: self.settings, to: directory, fullSize: full, scrub: scrub, frameCount: frames)
                            try? result.write(toFile: directory + "/result.txt", atomically: true, encoding: .utf8)
                        default: break
                        }
                    }
                }
            }
        }
    }

    private func applyLaunchAtLogin() {
        do {
            if settings.launchAtLogin {
                try SMAppService.mainApp.register()
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
    }
}
