import SwiftUI
import SpacewalkCore

@main
struct SpacewalkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: delegate.model)
        } label: {
            if delegate.model.settings.menuBarIndicator {
                Text(delegate.model.menuBarLabel).monospacedDigit()
            } else {
                Image(systemName: "rectangle.on.rectangle.angled")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await model.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }
}

struct MenuContent: View {
    @Bindable var model: AppModel

    var body: some View {
        if !model.captureAccess || !model.accessibilityAccess {
            Button("Finish Setup…") { model.showOnboarding = true; model.openSettingsWindow() }
            Divider()
        }
        if let display = model.spaces.first {
            ForEach(0..<display.count, id: \.self) { index in
                Button {
                    model.perform(.index(index + 1))
                } label: {
                    Text(index == display.currentIndex ? "✓ \(model.label(display, at: index))" : "    \(model.label(display, at: index))")
                }
            }
            Divider()
        }
        Button("Overview") { model.switcher.showOverview() }
        Toggle("Pause Transitions", isOn: Binding(get: { !model.settings.enabled }, set: { model.settings.enabled = !$0 }))
        Divider()
        Button("Settings…") { model.openSettingsWindow() }.keyboardShortcut(",")
        Button("Check for Updates…") { model.updater.checkForUpdates() }.disabled(!model.updater.canCheckForUpdates)
        Button("Quit Spacewalk") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
