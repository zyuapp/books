import AppKit
import Foundation
import Observation

/// Fetches newer releases in the background and installs them without asking: when Books quits, or by a quiet
/// relaunch (back onto the same book and page) after the app has sat unused in the background.
/// Inactive in ad-hoc builds, which have no signing team to verify updates against.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    enum State: Equatable {
        case idle
        case checking
        /// Downloaded and verified; installs when the app quits.
        case ready(String)
    }

    private(set) var state: State = .idle
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var idleTimer: Timer?
    @ObservationIgnored private var inactiveSince: Date?

    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    let app = Bundle.main.executableURL.flatMap(ReleaseUpdate.installedApp(containing:))

    var ready: String? {
        if case .ready(let v) = state { return v }
        return nil
    }

    func start() {
        guard let app, timer == nil else { return }
        if let staged = ReleaseUpdate.staged(for: app) { state = .ready(staged.version) }
        Task { await check() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.restartIfIdle() }
        }
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.inactiveSince = Date() }
        }
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.inactiveSince = nil }
        }
    }

    /// Relaunches onto the new version once Books has been in the background for 10 minutes.
    private func restartIfIdle() {
        guard ready != nil, let since = inactiveSince, Date().timeIntervalSince(since) > 600,
              NSApp.windows.allSatisfy({ $0.attachedSheet == nil }) else { return }
        LibraryStore.shared.flushAll()
        installOnQuit(relaunch: .background)
        state = .idle
        NSApp.terminate(nil)
    }

    /// Fetches a newer release if there is one. When `interactive`, reports the outcome in an alert.
    func check(interactive: Bool = false) async {
        guard let app else {
            if interactive {
                alert("Updates are off in this build.", detail: "Install a release with the install script to get automatic updates.")
            }
            return
        }
        if case .checking = state { return }
        let before = state
        state = .checking
        do {
            if let v = try await ReleaseUpdate.fetch(for: app) {
                state = .ready(v)
                if interactive { promptRestart(v) }
            } else {
                state = .idle
                if interactive { alert("Books \(current) is the latest version.") }
            }
        } catch {
            state = before
            if interactive { alert("Could not check for updates.", detail: error.localizedDescription) }
        }
    }

    /// Hands a downloaded update to a helper that swaps it in once this process exits.
    func installOnQuit(relaunch: ReleaseUpdate.Relaunch = .none) {
        guard let app, ready != nil else { return }
        try? ReleaseUpdate.installAfterExit(of: ProcessInfo.processInfo.processIdentifier, into: app, relaunch: relaunch)
    }

    private func promptRestart(_ version: String) {
        let a = NSAlert()
        a.messageText = "Books \(version) is ready"
        a.informativeText = "It installs the next time Books quits. Restart now to use it? You’ll be back on the same page."
        a.addButton(withTitle: "Restart Now")
        a.addButton(withTitle: "Later")
        if a.runModal() == .alertFirstButtonReturn {
            LibraryStore.shared.flushAll()
            installOnQuit(relaunch: .foreground)
            state = .idle
            NSApp.terminate(nil)
        }
    }

    private func alert(_ message: String, detail: String = "") {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = detail
        a.runModal()
    }
}
