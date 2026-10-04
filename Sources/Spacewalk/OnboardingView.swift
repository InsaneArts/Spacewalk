import SwiftUI
import SpacewalkCore

/// First run: the two permissions, then one choice of how to switch. Nothing else.
struct OnboardingView: View {
    @Bindable var model: AppModel
    @State private var step = 0
    @State private var choice = Choice.keys
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    enum Choice { case keys, arrows, trackpad }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "rectangle.on.rectangle.angled").font(.system(size: 40)).foregroundStyle(Color.accentColor)
            Text(step == 0 ? "Welcome to Spacewalk" : "How do you want to switch?").font(.title2.weight(.semibold))
            if step == 0 {
                Text("Spacewalk replaces the slow Spaces animation with an instant, animated one. It needs two permissions from macOS.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                VStack(spacing: 10) {
                    PermissionRow(granted: model.captureAccess, title: "Screen Recording", why: "to see your Spaces", open: model.openScreenRecordingSettings)
                    PermissionRow(granted: model.accessibilityAccess, title: "Accessibility", why: "to switch Spaces", open: model.openAccessibilitySettings)
                }
                .padding(14)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                HStack {
                    Button("Later") { model.showOnboarding = false }
                    Spacer()
                    Button("Continue") { step = 1 }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!(model.captureAccess && model.accessibilityAccess))
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    choiceRow(.keys, title: "Keys", detail: "⌃1 to ⌃9 go straight to a Space.")
                    choiceRow(.arrows, title: "Arrows", detail: "⌃← and ⌃→, taken over from macOS so they are instant.")
                    choiceRow(.trackpad, title: "Trackpad", detail: "Three-finger swipes, following your fingers.")
                }
                Text("You can combine these later in Settings > Shortcuts.").font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Back") { step = 0 }
                    Spacer()
                    Button("Done") { apply(); model.showOnboarding = false }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(28)
        .frame(width: 460)
        .onReceive(timer) { _ in if step == 0 { Task { await model.refreshDisplays() } } }
    }

    private func choiceRow(_ value: Choice, title: String, detail: String) -> some View {
        Button {
            choice = value
        } label: {
            HStack(spacing: 12) {
                Image(systemName: choice == value ? "checkmark.circle.fill" : "circle").foregroundStyle(choice == value ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.medium)
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(choice == value ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }

    private func apply() {
        switch choice {
        case .keys: model.useControlDigits()
        case .arrows: model.setSystemArrows(enabled: false)
        case .trackpad:
            model.settings.interceptTrackpadSwipes = true
            model.settings.interactiveSwipes = true
        }
    }
}
