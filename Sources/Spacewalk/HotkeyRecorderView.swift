import SwiftUI
import SpacewalkCore

/// Click, press a key combination, done. Escape cancels, Delete clears.
struct HotkeyRecorderView: View {
    @Binding var combo: KeyCombo?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "Press keys…" : (combo?.displayString ?? "Record"))
                .frame(minWidth: 96)
                .foregroundStyle(recording ? Color.accentColor : (combo == nil ? .secondary : .primary))
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }
            if event.keyCode == 51 || event.keyCode == 117 { combo = nil; stop(); return nil }
            let candidate = KeyCombo(event: event)
            let isFunctionKey = event.modifierFlags.contains(.function) && !event.modifierFlags.contains(.numericPad)
            guard candidate.hasModifiers || isFunctionKey else { NSSound.beep(); return nil }
            combo = candidate
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
