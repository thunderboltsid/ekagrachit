import AppKit
import EkagrachitCore
import SwiftUI

@main
struct EkagrachitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(coordinator: delegate.coordinator)
        } label: {
            MenuBarLabel(coordinator: delegate.coordinator)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = FocusSessionCoordinator()

    private var setupWindow: NSWindow?
    private var settingsWindow: NSWindow?
    static let showSettingsNotification = Notification.Name("EkagrachitShowSettings")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar app: no Dock icon even when run outside a bundle (swift run).
        NSApp.setActivationPolicy(.accessory)
        coordinator.start()
        NotificationCenter.default.addObserver(forName: FocusSessionCoordinator.showSetupNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showSetup() }
        }
        NotificationCenter.default.addObserver(forName: Self.showSettingsNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showSettings() }
        }
        let env = ProcessInfo.processInfo.environment
        if env["EKAGRACHIT_APPEARANCE"] == "dark" { NSApp.appearance = NSAppearance(named: .darkAqua) } // screenshot hook
        if env["EKAGRACHIT_OPEN_SETTINGS"] == "1" { // screenshot hook
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                MainActor.assumeIsolated { self?.showSettings() }
            }
        }
        // Give Chrome's extension a moment to connect, then show setup if
        // anything is missing (or on first launch, to point at the menu bar).
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            MainActor.assumeIsolated { self?.showSetupIfNeeded() }
        }
    }

    private func showSetupIfNeeded() {
        let firstLaunch = !UserDefaults.standard.bool(forKey: "setupShown")
        let ready = coordinator.extensionConnected && Permissions.accessibilityTrusted
        guard firstLaunch || !ready, !coordinator.isSessionRunning,
              ProcessInfo.processInfo.environment["EKAGRACHIT_NO_SETUP_WINDOW"] != "1" else { return }
        UserDefaults.standard.set(true, forKey: "setupShown")
        showSetup()
    }

    func showSetup() {
        if setupWindow == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Ekagrachit"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SetupView(coordinator: coordinator) { [weak w] in w?.close() })
            w.center()
            setupWindow = w
        }
        NSApp.activate()
        setupWindow?.makeKeyAndOrderFront(nil)
    }

    /// Settings live in our own window: SwiftUI's Settings scene opens behind
    /// other apps when the app is menu-bar-only.
    func showSettings() {
        if settingsWindow == nil {
            // A grouped Form scrolls and has no intrinsic height: size the window explicitly.
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Ekagrachit Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(coordinator: coordinator, settings: coordinator.settings))
            w.center()
            settingsWindow = w
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Never block logout/shutdown/updates. The Quit button is disabled
        // during a session; anything else that quits us leaves the session
        // persisted so a relaunch resumes it until its deadline.
        .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.prepareForTermination()
    }
}
