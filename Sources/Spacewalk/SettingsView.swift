import SwiftUI
import SpacewalkCore

/// Four toolbar tabs, the way Finder and Safari lay out their settings: General, Transition,
/// Shortcuts, Advanced. Plain words, few controls per screen, fine tuning folded away.
struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var tab: Tab = .general

    enum Tab: String, CaseIterable, Identifiable {
        case general, transition, shortcuts, advanced
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .transition: return "sparkles.rectangle.stack"
            case .shortcuts: return "keyboard"
            case .advanced: return "slider.horizontal.3"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ToolbarTabs(selection: $tab)
            Divider()
            Group {
                switch tab {
                case .general: GeneralTab(model: model)
                case .transition: TransitionTab(model: model)
                case .shortcuts: ShortcutsTab(model: model)
                case .advanced: AdvancedTab(model: model)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 640, height: 640)
        .sheet(isPresented: $model.showOnboarding) { OnboardingView(model: model) }
    }
}

/// Icon-over-label tabs across the top, like a classic settings toolbar.
struct ToolbarTabs: View {
    @Binding var selection: SettingsView.Tab

    var body: some View {
        HStack(spacing: 6) {
            ForEach(SettingsView.Tab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol).font(.system(size: 20, weight: .regular)).frame(height: 24)
                        Text(tab.title).font(.caption)
                    }
                    .frame(width: 76, height: 50)
                    .background(selection == tab ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    .foregroundStyle(selection == tab ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}

// MARK: - General

struct GeneralTab: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            if !model.captureAccess || !model.accessibilityAccess {
                Section {
                    PermissionRow(granted: model.captureAccess, title: "Screen Recording", why: "to see your Spaces", open: model.openScreenRecordingSettings)
                    PermissionRow(granted: model.accessibilityAccess, title: "Accessibility", why: "to switch Spaces", open: model.openAccessibilitySettings)
                    HStack { Spacer(); Button("Check Again") { Task { await model.refreshDisplays() } } }
                } header: {
                    Label("Spacewalk needs two permissions", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            Section("Menu Bar") {
                Toggle("Show current Space in menu bar", isOn: $model.settings.menuBarIndicator)
            }
            Section("Spaces Bar") {
                Toggle("Show a bar of Spaces with their apps", isOn: $model.settings.spacesBar)
                if model.settings.spacesBar {
                    Picker("Position", selection: $model.settings.spacesBarAtTop) {
                        Text("Bottom of screen").tag(false)
                        Text("Top of screen").tag(true)
                    }
                }
            }
            Section {
                if model.autoRearrange {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("macOS reorders Spaces by recent use, so numbered shortcuts drift.")
                        Spacer()
                        Button("Turn Off") { model.disableAutoRearrange() }
                    }
                }
                ForEach(model.spaces, id: \.displayUUID) { display in
                    ForEach(Array(display.spaces.enumerated()), id: \.element.nameKey) { index, space in
                        HStack {
                            Text("\(index + 1)")
                                .monospacedDigit()
                                .frame(width: 22, alignment: .trailing)
                                .foregroundStyle(index == display.currentIndex ? Color.accentColor : .secondary)
                            TextField(space.isFullscreen ? "Full Screen \(index + 1)" : "Desktop \(index + 1)",
                                      text: Binding(get: { model.settings.spaceNames[space.nameKey] ?? "" },
                                                    set: { model.setName($0, forSpace: space.nameKey) }))
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
            } header: {
                Text("Space Names")
            } footer: {
                Text("Names appear in the menu bar, the Overview and the Spaces bar.")
            }
            Section("Startup") {
                Toggle("Open Spacewalk at login", isOn: $model.settings.launchAtLogin)
                if let error = model.launchAtLoginError { Text(error).foregroundStyle(.orange) }
            }
            Section {
                LabeledContent("Spacewalk \(UpdaterService.version)") {
                    Button("Check Now") { model.updater.checkForUpdates() }
                        .disabled(!model.updater.canCheckForUpdates)
                }
                Toggle("Check for updates automatically", isOn: Binding(get: { model.updater.automaticallyChecksForUpdates },
                                                                        set: { model.updater.automaticallyChecksForUpdates = $0 }))
                Toggle("Download updates automatically", isOn: Binding(get: { model.updater.automaticallyDownloadsUpdates },
                                                                      set: { model.updater.automaticallyDownloadsUpdates = $0 }))
                    .disabled(!model.updater.automaticallyChecksForUpdates)
            } header: {
                Text("Updates")
            } footer: {
                Text(model.updater.availableVersion.map { "Version \($0) is available." }
                     ?? "Updates come from GitHub and are verified with an EdDSA signature before they install.")
            }
        }
    }
}

struct PermissionRow: View {
    let granted: Bool
    let title: String
    let why: String
    let open: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle").foregroundStyle(granted ? Color.green : .secondary)
            Text(granted ? "\(title) is allowed" : "\(title), \(why)")
            Spacer()
            if !granted { Button("Open System Settings", action: open) }
        }
    }
}

// MARK: - Transition

struct TransitionTab: View {
    @Bindable var model: AppModel

    private enum Speed: String, CaseIterable, Identifiable {
        case slow, normal, fast, custom
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var duration: Double? {
            switch self {
            case .slow: return 0.36
            case .normal: return 0.24
            case .fast: return 0.15
            case .custom: return nil
            }
        }
    }

    private var speed: Binding<Speed> {
        Binding(get: {
            Speed.allCases.first { preset in preset.duration.map { abs($0 - model.settings.duration) < 0.006 } ?? false } ?? .custom
        }, set: { newValue in
            if let duration = newValue.duration { model.settings.duration = duration }
        })
    }

    var body: some View {
        // The preview and the gallery stay put above the scrolling options, like the Wallpaper pane.
        // Inside the form they would be list rows, and the list crossfades a stale snapshot of the
        // row whenever the sections below change, which flashes an old frame over the live preview.
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                PreviewView(settings: model.settings)
                    .frame(height: 210)
                    .opacity(model.settings.effect == .instant ? 0.3 : 1)
                    .overlay(alignment: .bottomTrailing) {
                        Button("Preview on Screen") { model.preview() }
                            .controlSize(.small)
                            .padding(10)
                    }
                EffectGallery(selection: $model.settings.effect)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 6)
            Form {
                if model.settings.effect != .instant {
                    Section("Timing") {
                        Picker("Speed", selection: speed) {
                            ForEach(Speed.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        if speed.wrappedValue == .custom {
                            LabeledSlider("Duration", value: $model.settings.duration, range: 0.08...0.6) { "\(Int(($0 * 1000).rounded())) ms" }
                        }
                        Picker("Easing", selection: $model.settings.easing) {
                            ForEach(EasingPreset.allCases) { Text($0.title).tag($0) }
                        }
                        if model.settings.easing == .spring {
                            LabeledSlider("Bounce", value: $model.settings.bounce, range: 0...0.6) { "\(Int(($0 * 100).rounded()))%" }
                        }
                    }
                    Section("Direction") {
                        Picker("The new Space arrives from", selection: $model.settings.directionMode) {
                            Text("Its side in the list").tag(DirectionMode.byOrder)
                            Text("Always the right").tag(DirectionMode.alwaysForward)
                            Text("Always the left").tag(DirectionMode.alwaysBackward)
                        }
                        Toggle("Move vertically", isOn: Binding(get: { model.settings.orientation == .vertical },
                                                                 set: { model.settings.orientation = $0 ? .vertical : .horizontal }))
                        if model.settings.effect == .slide {
                            Picker("Wallpaper", selection: $model.settings.wallpaperMode) {
                                Text("Drifts behind the windows").tag(WallpaperMode.parallax)
                                Text("Stays still").tag(WallpaperMode.still)
                                Text("Moves with the windows").tag(WallpaperMode.moves)
                            }
                        }
                    }
                    if model.settings.effect.usesCards || model.settings.effect == .cube || model.settings.effect == .flip {
                        Section("Fine Tuning") {
                            fineTuning
                        }
                    }
                    Section("Extras") {
                        Toggle("Show the name of the new Space", isOn: $model.settings.showWorkspacePill)
                        Toggle("Play a sound", isOn: $model.settings.playSound)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var fineTuning: some View {
        switch model.settings.effect {
        case .depth:
            LabeledSlider("Parallax", value: $model.settings.parallax, range: 0...1, format: percent)
            LabeledSlider("Shrink to", value: $model.settings.depthScale, range: 0.8...1, format: percent)
            LabeledSlider("Dim", value: $model.settings.dimAmount, range: 0...0.6, format: percent)
            LabeledSlider("Corner radius", value: $model.settings.cornerRadius, range: 0...40, format: points)
        case .zoom, .stack, .swap, .reveal:
            LabeledSlider("Shrink to", value: $model.settings.depthScale, range: 0.8...1, format: percent)
            LabeledSlider("Dim", value: $model.settings.dimAmount, range: 0...0.6, format: percent)
            LabeledSlider("Corner radius", value: $model.settings.cornerRadius, range: 0...40, format: points)
        case .carousel:
            LabeledSlider("Shrink to", value: $model.settings.depthScale, range: 0.8...1, format: percent)
            LabeledSlider("Corner radius", value: $model.settings.cornerRadius, range: 0...40, format: points)
        case .tilt:
            LabeledSlider("Corner radius", value: $model.settings.cornerRadius, range: 0...40, format: points)
        case .cube, .flip:
            LabeledSlider("Dim", value: $model.settings.dimAmount, range: 0...0.6, format: percent)
        case .instant, .slide, .fade:
            EmptyView()
        }
    }

    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
    private func points(_ value: Double) -> String { "\(Int(value.rounded())) pt" }
}

/// Every transition as a selectable card with a symbol, like a wallpaper or screen saver picker.
struct EffectGallery: View {
    @Binding var selection: Effect
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Effect.allCases) { effect in
                Button {
                    selection = effect
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: symbol(for: effect)).font(.system(size: 22)).frame(height: 28)
                        Text(shortTitle(for: effect)).font(.caption).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(selection == effect ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(selection == effect ? Color.accentColor : .clear, lineWidth: 2))
                    .foregroundStyle(selection == effect ? Color.accentColor : .primary)
                }
                .buttonStyle(.plain)
                .help(effect.summary)
            }
        }
    }

    private func shortTitle(for effect: Effect) -> String {
        switch effect {
        case .instant: return "Instant"
        case .depth: return "Depth"
        case .tilt: return "Tilt"
        case .fade: return "Fade"
        default: return effect.title
        }
    }

    private func symbol(for effect: Effect) -> String {
        switch effect {
        case .instant: return "bolt.fill"
        case .slide: return "arrow.left.and.right"
        case .depth: return "square.stack.3d.down.right"
        case .tilt: return "rotate.3d"
        case .carousel: return "rectangle.3.group"
        case .fade: return "circle.lefthalf.filled"
        case .zoom: return "arrow.up.left.and.arrow.down.right"
        case .cube: return "cube"
        case .flip: return "arrow.trianglehead.2.clockwise.rotate.90"
        case .swap: return "arrow.left.arrow.right"
        case .reveal: return "rectangle.portrait.on.rectangle.portrait"
        case .stack: return "square.stack"
        }
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String

    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: @escaping (Double) -> String) {
        self.title = title
        _value = value
        self.range = range
        self.format = format
    }

    var body: some View {
        HStack {
            Text(title)
            Slider(value: $value, in: range)
            Text(format(value)).monospacedDigit().foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
        }
    }
}

// MARK: - Shortcuts

struct ShortcutsTab: View {
    @Bindable var model: AppModel

    private enum SwipeMode: String, CaseIterable, Identifiable {
        case off, instant, follow
        var id: String { rawValue }
    }

    private var swipeMode: Binding<SwipeMode> {
        Binding(get: {
            model.settings.interceptTrackpadSwipes ? (model.settings.interactiveSwipes ? .follow : .instant) : .off
        }, set: { mode in
            model.settings.interceptTrackpadSwipes = mode != .off
            if mode != .off { model.settings.interactiveSwipes = mode == .follow }
        })
    }

    var body: some View {
        Form {
            Section {
                ForEach($model.settings.hotkeys) { $binding in
                    if shows(binding.target) {
                        HStack {
                            Text(label(for: binding.target))
                            Spacer()
                            HotkeyRecorderView(combo: $binding.combo)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Keyboard")
                    Spacer()
                    Menu("Presets") {
                        Button("Use ⌃1 to ⌃9 for Spaces 1 to 9") { model.useControlDigits() }
                        Button(model.systemArrowsEnabled ? "Use ⌃← and ⌃→ (takes them over from macOS)" : "Give ⌃← and ⌃→ back to macOS") {
                            model.setSystemArrows(enabled: !model.systemArrowsEnabled)
                        }
                        Divider()
                        Button("Clear All") { model.clearHotkeys() }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            } footer: {
                Text("Click a field, press the keys. Spaces are numbered the way Mission Control shows them.")
            }
            Section {
                ForEach($model.settings.hotkeys) { $binding in
                    if case .app(let bundleID) = binding.target {
                        HStack {
                            Text(model.appName(for: bundleID))
                            Spacer()
                            HotkeyRecorderView(combo: $binding.combo)
                            Button { model.removeBinding(binding.id) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                Button("Add App…") { model.addAppBinding() }
            } header: {
                Text("Go to an App")
            } footer: {
                Text("Switches to the Space where that app's window is.")
            }
            Section("Trackpad") {
                Picker("Three-finger swipe", selection: swipeMode) {
                    Text("Leave to macOS").tag(SwipeMode.off)
                    Text("Switch instantly").tag(SwipeMode.instant)
                    Text("Follow my fingers").tag(SwipeMode.follow)
                }
                .disabled(!model.accessibilityAccess)
                if swipeMode.wrappedValue == .follow {
                    Toggle("Click when the swipe will switch", isOn: $model.settings.hapticFeedback)
                    if model.settings.hapticFeedback {
                        HStack {
                            Picker("Click strength", selection: $model.settings.hapticStrength) {
                                ForEach(HapticStrength.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            Button("Try") { HapticTick.perform(model.settings.hapticStrength) }
                        }
                    }
                }
                if swipeMode.wrappedValue != .off {
                    Toggle("Mission Control swipe opens the Overview", isOn: $model.settings.gestureOverview)
                }
            }
            Section("Mouse") {
                Toggle("Side buttons switch Spaces", isOn: $model.settings.mouseButtonsSwitch).disabled(!model.accessibilityAccess)
                Toggle("Scrolling at the top edge switches Spaces", isOn: $model.settings.menuBarScrollSwitch).disabled(!model.accessibilityAccess)
            }
        }
    }

    private func shows(_ target: SpaceTarget) -> Bool {
        switch target {
        case .app: return false
        case .up, .down: return model.settings.overviewColumns > 0
        default: return true
        }
    }

    private func label(for target: SpaceTarget) -> String {
        switch target {
        case .index(let number): return "Space \(number)"
        case .next: return "Next Space"
        case .previous: return "Previous Space"
        case .backAndForth: return "Last Space"
        case .up: return "Row Up"
        case .down: return "Row Down"
        case .overview: return "Overview"
        case .app(let bundleID): return model.appName(for: bundleID)
        }
    }
}

// MARK: - Advanced

struct AdvancedTab: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(model.configPath).font(.system(.callout, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Spacer()
                }
                HStack {
                    Button("Show in Finder") { model.revealConfig() }
                    Button("Reload") { model.reloadFromFile() }
                    Spacer()
                    Button("Export…") { model.exportSettings() }
                    Button("Import…") { model.importSettings() }
                }
                ForEach(model.configWarnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if let note = model.transferNote { Text(note).foregroundStyle(.secondary) }
            } header: {
                Text("Configuration File")
            } footer: {
                Text("Every setting lives in this file. Edit it with any editor; Spacewalk applies changes when you save.")
            }
            Section("Switching") {
                Toggle("Start moving before macOS has switched", isOn: $model.settings.predictiveStart)
                Toggle("Keep updating the new Space's picture while it settles", isOn: $model.settings.eagerStart)
                Stepper("Wait for \(model.settings.settleFrames) quiet frame\(model.settings.settleFrames == 1 ? "" : "s") after switching", value: $model.settings.settleFrames, in: 1...4)
                Toggle("Wrap around from the last Space to the first", isOn: $model.settings.wrapAround)
                Stepper("Overview grid: \(model.settings.overviewColumns == 0 ? "one row" : model.settings.overviewColumns == 1 ? "one column" : "\(model.settings.overviewColumns) columns")", value: $model.settings.overviewColumns, in: 0...8)
                if model.spaces.count > 1 {
                    Toggle("Switch all displays together", isOn: $model.settings.switchAllDisplays)
                }
                Stepper("Slow motion: \(Int(model.settings.slowMotion))×", value: $model.settings.slowMotion, in: 1...20)
            }
            Section("Diagnostics") {
                ForEach(model.displayStatus) { status in
                    HStack {
                        Text(status.name)
                        Spacer()
                        Text(status.running ? "Capturing" : (status.error ?? "Stopped")).foregroundStyle(status.running ? Color.secondary : Color.orange)
                    }
                }
                if model.reports.isEmpty {
                    Text("No switches yet").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.reports.prefix(6).enumerated()), id: \.offset) { _, report in
                        Text(report.summary).font(.system(.caption, design: .monospaced)).foregroundStyle(report.animated ? .primary : .secondary)
                    }
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.reports.map(\.summary).joined(separator: "\n"), forType: .string)
                    }
                }
            }
        }
    }
}
