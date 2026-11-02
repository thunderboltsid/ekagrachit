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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar app: no Dock icon even when run outside a bundle (swift run).
        NSApp.setActivationPolicy(.accessory)
        coordinator.start()
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
