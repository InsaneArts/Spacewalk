import Testing
import QuartzCore
@testable import SpacewalkCore

@Suite struct DirectionTests {
    let order = ["1", "2", "3", "4"]

    @Test func higherWorkspaceIsForward() {
        #expect(Direction.resolve(from: "2", to: "4", order: order, mode: .byOrder, inverted: false) == .forward)
        #expect(Direction.resolve(from: "4", to: "1", order: order, mode: .byOrder, inverted: false) == .backward)
    }

    @Test func unknownNamesFallBackToForward() {
        #expect(Direction.resolve(from: nil, to: "3", order: order, mode: .byOrder, inverted: false) == .forward)
        #expect(Direction.resolve(from: "1", to: "zzz", order: order, mode: .byOrder, inverted: false) == .forward)
    }

    @Test func fixedModesAndInversion() {
        #expect(Direction.resolve(from: "4", to: "1", order: order, mode: .alwaysForward, inverted: false) == .forward)
        #expect(Direction.resolve(from: "1", to: "4", order: order, mode: .alwaysBackward, inverted: false) == .backward)
        #expect(Direction.resolve(from: "1", to: "4", order: order, mode: .byOrder, inverted: true) == .backward)
    }
}

@Suite struct SettingsTests {
    @Test func roundTripsThroughJSON() throws {
        var settings = SpacewalkSettings()
        settings.effect = .cube
        settings.duration = 0.5
        settings.hotkeys = [HotkeyBinding(combo: KeyCombo(keyCode: 18, modifiers: 4096), target: .index(1))]
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(SpacewalkSettings.self, from: data)
        // Bindings for targets missing from a file are merged in from the defaults.
        #expect(decoded.hotkeys.first == settings.hotkeys.first)
        #expect(decoded.hotkeys.count == SpacewalkSettings.defaultHotkeys.count)
        var expected = settings
        expected.hotkeys = decoded.hotkeys
        #expect(decoded == expected)
    }

    @Test func missingKeysKeepDefaults() throws {
        let decoded = try JSONDecoder().decode(SpacewalkSettings.self, from: Data(#"{"effect":"cube","duration":0.5}"#.utf8))
        #expect(decoded.effect == .cube)
        #expect(decoded.duration == 0.5)
        #expect(decoded.eagerStart == SpacewalkSettings().eagerStart)
        #expect(decoded.hotkeys == SpacewalkSettings.defaultHotkeys)
    }

    @Test func defaultHotkeysCoverNineWorkspaces() {
        let indices = SpacewalkSettings.defaultHotkeys.compactMap { binding -> Int? in
            if case .index(let index) = binding.target { return index }
            return nil
        }
        #expect(indices == Array(1...9))
    }
}

@Suite struct IPCTests {
    @Test func parsesCommandWords() {
        #expect(SpacewalkIPC.parseTarget(["switch", "3"]) == .index(3))
        #expect(SpacewalkIPC.parseTarget(["switch", "0"]) == nil)
        #expect(SpacewalkIPC.parseTarget(["switch", "dev"]) == nil)
        #expect(SpacewalkIPC.parseTarget(["next"]) == .next)
        #expect(SpacewalkIPC.parseTarget(["prev"]) == .previous)
        #expect(SpacewalkIPC.parseTarget(["back-and-forth"]) == .backAndForth)
        #expect(SpacewalkIPC.parseTarget(["switch"]) == nil)
        #expect(SpacewalkIPC.parseTarget(["dance"]) == nil)
    }

    @Test func encodesAndDecodesTargets() {
        for target in [SpaceTarget.index(4), .next, .previous, .backAndForth] {
            #expect(SpacewalkIPC.encode(target).flatMap(SpacewalkIPC.decode) == target)
        }
    }
}

@Suite struct TimingTests {
    @Test func springsSettleAndCurvesKeepDuration() {
        let spring = AnimationTiming(duration: 0.3, easing: .spring, bounce: 0.2).animation(keyPath: "opacity", from: 0, to: 1)
        #expect(spring is CASpringAnimation)
        #expect(spring.duration > 0)
        let curve = AnimationTiming(duration: 0.3, easing: .snappy, bounce: 0).animation(keyPath: "opacity", from: 0, to: 1)
        #expect(curve.duration == 0.3)
        #expect(curve.timingFunction != nil)
    }

    @Test func easedProgressStartsAtZeroAndEndsAtOne() {
        for preset in EasingPreset.allCases {
            let timing = AnimationTiming(duration: 0.3, easing: preset, bounce: 0.2)
            #expect(abs(timing.progress(0)) < 1e-6)
            #expect(abs(timing.progress(1) - 1) < 1e-6)
            #expect(timing.progress(0.5) > 0 && timing.progress(0.5) < 1)
        }
        #expect(abs(AnimationTiming.cubicBezier(0, 0, 1, 1, at: 0.3) - 0.3) < 1e-4)
        let keyframes = AnimationTiming(duration: 0.3, easing: .smooth, bounce: 0).keyframes(keyPath: "transform", frames: 10) { $0 }
        #expect(keyframes.values?.count == 10)
    }

    @Test func everyCurvePresetHasControlPointsExceptSpring() {
        for preset in EasingPreset.allCases {
            #expect((preset.controlPoints == nil) == (preset == .spring))
        }
    }
}

@Suite @MainActor struct StageTests {
    @Test func runsEveryEffectWithoutThrowing() {
        let stage = TransitionStage(size: CGSize(width: 320, height: 180))
        var settings = SpacewalkSettings()
        for effect in Effect.allCases {
            settings.effect = effect
            for direction in [Direction.forward, .backward] {
                stage.run(settings: settings, direction: direction, timing: AnimationTiming(settings: settings)) {}
            }
        }
        #expect(stage.root.sublayers?.count == 3)
    }
}

@Suite struct SettleTests {
    let size = CGSize(width: 1920, height: 1080)

    @Test func changedFractionUsesTheRightUnit() {
        let half = [CGRect(x: 0, y: 0, width: 960, height: 1080)]
        #expect(abs(DisplayCapture.changedFraction(half, pixelWidth: 3840, pixelHeight: 2160, pointSize: size) - 0.5) < 0.001)
        let halfPixels = [CGRect(x: 0, y: 0, width: 1920, height: 2160)]
        #expect(abs(DisplayCapture.changedFraction(halfPixels, pixelWidth: 3840, pixelHeight: 2160, pointSize: size) - 0.5) < 0.001)
        #expect(DisplayCapture.dirtyRects([CGRect(x: 1, y: 2, width: 3, height: 4).dictionaryRepresentation])?.first == CGRect(x: 1, y: 2, width: 3, height: 4))
    }
}


@Suite struct SpaceModelTests {
    let raw: [[String: Any]] = [[
        "Display Identifier": "UUID-A",
        "Current Space": ["id64": NSNumber(value: 615)],
        "Spaces": [["id64": NSNumber(value: 1), "type": NSNumber(value: 0), "uuid": "s1"],
                   ["id64": NSNumber(value: 615), "type": NSNumber(value: 0), "uuid": "s2"],
                   ["id64": NSNumber(value: 900), "type": NSNumber(value: 4), "uuid": "fs"]],
    ], ["Display Identifier": "UUID-B", "Spaces": [["id64": NSNumber(value: 77), "type": NSNumber(value: 0), "uuid": "b1"]]]]

    @Test func parsesDisplaysAndCurrentSpace() {
        let snapshot = SpaceSnapshot.parse(raw, activeSpace: 77)
        #expect(snapshot.displays.count == 2)
        let a = snapshot.display(uuid: "UUID-A")!
        #expect(a.currentIndex == 1)
        #expect(a.spaces.map(\.id) == [1, 615, 900])
        #expect(a.spaces[2].isFullscreen)
        #expect(a.label(at: 0) == "Desktop 1")
        #expect(a.label(at: 2) == "Full screen 3")
        // Display B has no "Current Space" entry, so the active space fills in.
        #expect(snapshot.display(uuid: "UUID-B")?.currentIndex == 0)
    }
}

@Suite struct DockSwipeTests {
    @Test func fixedPointKeepsTheSign() {
        #expect(DockSwipe.fixed1616(1.0) == 65536)
        #expect(DockSwipe.fixed1616(-0.5) == -32768)
        #expect(DockSwipe.fixed1616(1e-9) == 1)
        #expect(DockSwipe.fixed1616(-1e-9) == -1)
        #expect(DockSwipe.fixed1616(0) == 0)
    }

    @Test func payloadSizesMatchTheRecordLayout() {
        let began = DockSwipe.iohidPayload(phase: 1, motion: 1, progress: -1e-4, positionX: 0.1, positionY: 0, velocityX: 0, velocityY: 0, mask: 0, timestamp: 1)
        #expect(began.count == 68)
        let ended = DockSwipe.iohidPayload(phase: 4, motion: 1, progress: -1e-4, positionX: 0.1, positionY: 0, velocityX: -9999, velocityY: 0, mask: 0, timestamp: 1)
        #expect(ended.count == 96)
        // event_count sits at offset 24, little endian.
        #expect(began[24] == 1 && ended[24] == 2)
        // gesture record: size 40 at offset 28, type 23 at offset 32, phase in the top byte of options at offset 39.
        #expect(began[28] == 40 && began[32] == 23 && ended[39] == 4)
        // flavor 3 at offset 62, velocity record type 9 at offset 72.
        #expect(began[62] == 3 && ended[72] == 9)
    }

    @Test func plainEventCarriesTheDockSwipeFields() throws {
        let event = try #require(DockSwipe.plainEvent(.changed, right: true))
        #expect(event.getIntegerValueField(DockSwipe.field(55)) == 30)
        #expect(event.getIntegerValueField(DockSwipe.field(110)) == 23)
        #expect(event.getIntegerValueField(DockSwipe.field(132)) == 2)
        #expect(event.getIntegerValueField(DockSwipe.field(123)) == 1)
        #expect(event.getDoubleValueField(DockSwipe.field(124)) > 0)
        #expect(event.getIntegerValueField(.eventSourceUserData) == DockSwipe.eventTag)
    }
}

@Suite struct ConfigTests {
    @Test func parsesTablesStringsNumbersAndArrays() throws {
        let text = """
        # comment
        [transition]
        effect = "cube"   # trailing comment
        duration-ms = 240
        bounce = 0.25
        pill = false
        tags = ["a", "b # not a comment", 'c']
        [shortcuts.apps]
        "com.example.app" = "ctrl-alt-s"
        inline = { x = 1, y = "two" }
        """
        let table = try TOML.parse(text)
        #expect(TOML.lookup(table, path: ["transition", "effect"])?.string == "cube")
        #expect(TOML.lookup(table, path: ["transition", "duration-ms"])?.int == 240)
        #expect(TOML.lookup(table, path: ["transition", "bounce"])?.double == 0.25)
        #expect(TOML.lookup(table, path: ["transition", "pill"])?.bool == false)
        #expect(TOML.lookup(table, path: ["transition", "tags"]) == .array([.string("a"), .string("b # not a comment"), .string("c")]))
        #expect(TOML.lookup(table, path: ["shortcuts", "apps", "com.example.app"])?.string == "ctrl-alt-s")
        #expect(TOML.lookup(table, path: ["shortcuts", "apps", "inline", "y"])?.string == "two")
    }

    @Test func reportsSyntaxErrorsWithLines() {
        #expect(throws: TOMLError.self) { try TOML.parse("[transition\neffect = 1") }
        #expect(throws: TOMLError.self) { try TOML.parse("effect = ") }
    }

    @Test func keyNamesRoundTrip() {
        let combo = KeyNames.combo(from: "ctrl-alt-1")
        #expect(combo == .some(KeyCombo(keyCode: 18, modifiers: 4096 | 2048)))
        #expect(KeyNames.text(for: KeyCombo(keyCode: 124, modifiers: 4096)) == "ctrl-right")
        #expect(KeyNames.combo(from: "") == .some(nil))
        #expect(KeyNames.combo(from: "ctrl-nonsense") == nil)
        #expect(KeyNames.text(for: KeyNames.combo(from: "cmd-shift-f3")!) == "cmd-shift-f3")
    }

    @Test func configRendersAndReadsBack() throws {
        var settings = SpacewalkSettings()
        settings.effect = .flip
        settings.duration = 0.3
        settings.easing = .spring
        settings.wallpaperMode = .still
        settings.setBinding(KeyCombo(keyCode: 18, modifiers: 4096), for: .index(1))
        settings.setBinding(KeyCombo(keyCode: 1, modifiers: 4096 | 2048), for: .app("com.example.app"))
        settings.spaceNames["uuid-1"] = "Reading"
        settings.interceptTrackpadSwipes = true
        settings.interactiveSwipes = false
        settings.hapticStrength = .double
        settings.spacesBarAtTop = true
        settings.slowMotion = 4
        let text = ConfigFile.render(settings)
        let table = try TOML.parse(text)
        let (loaded, warnings) = ConfigFile.apply(table, to: SpacewalkSettings())
        #expect(warnings.isEmpty)
        #expect(loaded.effect == .flip)
        #expect(abs(loaded.duration - 0.3) < 0.001)
        #expect(loaded.easing == .spring)
        #expect(loaded.wallpaperMode == .still)
        #expect(loaded.hotkeys.first { $0.target == .index(1) }?.combo == KeyCombo(keyCode: 18, modifiers: 4096))
        #expect(loaded.hotkeys.first { $0.target == .app("com.example.app") }?.combo == KeyCombo(keyCode: 1, modifiers: 4096 | 2048))
        #expect(loaded.spaceNames["uuid-1"] == "Reading")
        #expect(loaded.interceptTrackpadSwipes && !loaded.interactiveSwipes)
        #expect(loaded.hapticStrength == .double)
        #expect(loaded.spacesBarAtTop)
        #expect(loaded.slowMotion == 4)
    }

    @Test func unknownValuesWarnAndKeepDefaults() throws {
        let table = try TOML.parse("[transition]\neffect = \"warp\"\n[shortcuts]\nnext = \"ctrl-zzz\"")
        let (loaded, warnings) = ConfigFile.apply(table, to: SpacewalkSettings())
        #expect(loaded.effect == SpacewalkSettings().effect)
        #expect(warnings.count == 2)
    }
}
