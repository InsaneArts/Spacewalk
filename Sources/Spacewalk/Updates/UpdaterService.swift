import AppKit
import Observation
import Sparkle

/// Sparkle, wrapped so the rest of the app never imports it. Updates are signed with EdDSA and
/// checked against appcast.xml in the repository; there is no Spacewalk server.
@MainActor
@Observable
final class UpdaterService {
    /// False until Sparkle finishes starting, and while a check is in flight.
    private(set) var canCheckForUpdates = false
    /// The newest version Sparkle has seen, or nil when the app is current.
    private(set) var availableVersion: String?
    private(set) var lastCheckedAt: Date?

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private let updaterDelegate = UpdaterDelegate()
    @ObservationIgnored private let userDriverDelegate = UserDriverDelegate()
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? true }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    static var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    /// Starts Sparkle. Called once at launch, after the app's own setup, so a scheduled check
    /// can never race it. Does nothing when the bundle carries no feed (a bare `swift run`).
    func start() {
        guard controller == nil, Bundle.main.infoDictionary?["SUFeedURL"] != nil else { return }
        updaterDelegate.service = self
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: updaterDelegate, userDriverDelegate: userDriverDelegate)
        guard let updater = controller?.updater else { return }
        lastCheckedAt = updater.lastUpdateCheckDate
        canCheckForUpdates = updater.canCheckForUpdates
        canCheckObservation = updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
            Task { @MainActor [weak self] in self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
    }

    /// A check the user asked for. Sparkle shows its own window, including "you're up to date".
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
        lastCheckedAt = .now
    }

    fileprivate func foundUpdate(version: String?) { availableVersion = version }
    fileprivate func finishedCheck() { lastCheckedAt = controller?.updater.lastUpdateCheckDate ?? .now }
}

private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    weak var service: UpdaterService?

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Task { @MainActor [weak service] in service?.foundUpdate(version: item.displayVersionString) }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor [weak service] in
            service?.foundUpdate(version: nil)
            service?.finishedCheck()
        }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        Task { @MainActor [weak service] in service?.finishedCheck() }
    }
}

/// Spacewalk is `LSUIElement`: no Dock icon, accessory activation policy. Sparkle places and
/// focuses its windows like a regular app, so under `.accessory` the update window can open
/// unfocused or off-screen. The policy becomes `.regular` while the update UI is up and reverts
/// when the session ends, so the app stays out of the Dock.
private final class UserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// A scheduled update may be shown, but never pulled into focus: a window stealing focus
    /// mid-gesture would land the cursor's keystrokes somewhere else.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        !immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard state.userInitiated else { return }
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { _ = NSApp.setActivationPolicy(.accessory) }
    }
}
