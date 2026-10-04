import AppKit
import SwiftUI
import SpacewalkCore

/// Reports the AX subrole "dialog" so tiling window managers leave the window floating.
final class SettingsPanel: NSPanel {
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .dialog }
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    var windowNumber: Int? { window?.windowNumber }

    func show(model: AppModel) {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: model))
            let panel = SettingsPanel(contentViewController: hosting)
            panel.title = "Spacewalk Settings"
            panel.styleMask = [.titled, .closable]
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = false
            panel.isFloatingPanel = false
            panel.setContentSize(NSSize(width: 640, height: 640))
            panel.center()
            self.window = panel
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
