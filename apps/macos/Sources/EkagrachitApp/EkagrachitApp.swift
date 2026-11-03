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

        Settings {
            SettingsView(coordinator: delegate.coordinator, settings: delegate.coordinator.settings)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = FocusSessionCoordinator()

    private var setupWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar app: no Dock icon even when run outside a bundle (swift run).
        NSApp.setActivationPolicy(.accessory)
        coordinator.start()
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
