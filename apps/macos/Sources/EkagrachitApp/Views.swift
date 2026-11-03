import AppKit
import EkagrachitCore
import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var coordinator: FocusSessionCoordinator

    var body: some View {
        if coordinator.phase == .active || coordinator.phase == .degraded {
            let minutes = Int((coordinator.remaining / 60).rounded(.up))
            HStack(spacing: 3) {
                Image(systemName: coordinator.phase == .degraded ? "exclamationmark.circle" : "circle.circle.fill")
                Text("\(minutes)m").monospacedDigit()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Ekagrachit, \(minutes) minutes remaining")
        } else {
            Image(systemName: "circle.circle")
                .accessibilityLabel("Ekagrachit")
        }
    }
}

enum DurationChoice: Hashable {
    case preset(Int)
    case custom
}

struct MenuContentView: View {
    @ObservedObject var coordinator: FocusSessionCoordinator
    @State private var target = ""
    @State private var choice: DurationChoice = .preset(25)
    @State private var customMinutes = 90
    @FocusState private var urlFocused: Bool
    private let presets = [15, 25, 45, 60]

    private var minutes: Int {
        if case let .preset(m) = choice { return m }
        return customMinutes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("EKAGRACHIT")
                .font(.system(size: 12, weight: .semibold))
                .tracking(3)
                .frame(maxWidth: .infinity, alignment: .center)
            switch coordinator.phase {
            case .idle where coordinator.waitingForChrome:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Opening Chrome…")
                }
            case .idle: idleView
            case .preparing: preparingView
            case .active, .degraded, .ending: activeView
            }
            if let m = coordinator.message {
                Text(m).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            statusRows
            footer
        }
        .padding(16)
        .frame(width: 340)
        .onAppear {
            coordinator.refreshPermissions()
            let d = coordinator.settings.defaultMinutes
            if presets.contains(d) { choice = .preset(d) } else { choice = .custom; customMinutes = d }
            urlFocused = true
            coordinator.refreshSuggestion()
        }
        .onChange(of: coordinator.suggestedTarget) { _, url in
            if let url, target.isEmpty { target = url }
        }
    }

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What are you focusing on?").font(.callout).foregroundStyle(.secondary)
            TextField("https://docs.google.com/document/d/…", text: $target)
                .textFieldStyle(.roundedBorder)
                .focused($urlFocused)
                .onSubmit(start)
                .accessibilityLabel("Focus target URL")
            Text("Duration").font(.callout).foregroundStyle(.secondary)
            Picker("Duration", selection: $choice) {
                ForEach(presets, id: \.self) { Text("\($0)m").tag(DurationChoice.preset($0)) }
                Text("Custom").tag(DurationChoice.custom)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if choice == .custom {
                HStack(spacing: 6) {
                    TextField("Minutes", value: $customMinutes, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                        .accessibilityLabel("Custom duration in minutes")
                    Stepper("Minutes", value: $customMinutes, in: 1...480, step: 5).labelsHidden()
                    Text("minutes").foregroundStyle(.secondary)
                }
            }
            Button(action: start) {
                Text("Start Focus · \(minutes) min").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(target.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var preparingView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Opening the focus window…")
            }
            Button("Cancel") { coordinator.requestEnd() }
        }
    }

    private var activeView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(coordinator.machine.session?.target ?? "")
                .font(.callout).lineLimit(2).truncationMode(.middle).foregroundStyle(.secondary)
            Text(HUDPanel.format(coordinator.remaining))
                .font(.system(size: 34, weight: .light)).monospacedDigit()
            if coordinator.phase == .degraded {
                Label(degradedText, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            }
            Button("End Session…") { coordinator.requestEnd() }
                .buttonStyle(.glass)
            Text("Emergency exit: \(HotKey.emergencyDisplay), then hold to confirm.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var degradedText: String {
        switch coordinator.machine.session?.degradedReason {
        case .extensionDisconnected?: return "Chrome extension disconnected — browser rules still apply."
        case .focusWindowMissing?: return "Focus window missing — reopening it."
        case nil: return "Enforcement degraded."
        }
    }

    private var statusRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                statusRow(ok: coordinator.extensionConnected,
                          okText: "Chrome extension connected" + (coordinator.extensionVersion.map { " (v\($0))" } ?? ""),
                          badText: coordinator.bridgeError ?? "Chrome extension not connected")
                if !coordinator.extensionConnected {
                    Spacer()
                    Button("Set Up…") { NotificationCenter.default.post(name: FocusSessionCoordinator.showSetupNotification, object: nil) }
                        .controlSize(.small)
                }
            }
            HStack {
                statusRow(ok: coordinator.accessibilityTrusted, okText: "Accessibility granted", badText: "Accessibility not granted")
                if !coordinator.accessibilityTrusted {
                    Spacer()
                    Button("Grant…") {
                        Permissions.requestAccessibility()
                        Permissions.openAccessibilitySettings()
                    }
                    .controlSize(.small)
                }
            }
        }
        .font(.caption)
    }

    private func statusRow(ok: Bool, okText: String, badText: String) -> some View {
        Label(ok ? okText : badText, systemImage: ok ? "checkmark.circle" : "exclamationmark.circle")
            .foregroundStyle(ok ? Color.secondary : Color.orange)
    }

    private var footer: some View {
        HStack {
            SettingsLink { Text("Settings…") }
                .simultaneousGesture(TapGesture().onEnded { NSApp.activate() })
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .disabled(coordinator.isSessionRunning)
                .help(coordinator.isSessionRunning ? "End the session first" : "Quit Ekagrachit")
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }

    private func start() {
        let m = minutes
        if coordinator.startSession(target: target, minutes: m) == nil {
            coordinator.settings.defaultMinutes = m
            target = ""
        }
    }
}

struct SettingsView: View {
    @ObservedObject var coordinator: FocusSessionCoordinator
    @ObservedObject var settings: AppSettings
    @State private var launchAtLogin = false

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Background", selection: $settings.overlayStyle) {
                    ForEach(OverlayStyle.allCases) { Text($0.label).tag($0) }
                }
            }
            Section {
                TextField("Run at start", text: $settings.startShortcut, prompt: Text("e.g. Ekagrachit Focus On"))
                TextField("Run at end", text: $settings.endShortcut, prompt: Text("e.g. Ekagrachit Focus Off"))
            } header: {
                Text("Do Not Disturb (via Shortcuts)")
            } footer: {
                Text("macOS does not let apps switch Focus modes directly. Create two Shortcuts using the “Set Focus” action (Do Not Disturb on / off) and enter their names here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("General") {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in settings.launchAtLogin = on }
                Toggle("Play a sound when a session ends", isOn: $settings.playEndSound)
                LabeledContent("Emergency exit", value: HotKey.emergencyDisplay)
            }
            Section("About") {
                LabeledContent("Version", value: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev")
                LabeledContent("Chrome extension", value: coordinator.extensionVersion ?? "not connected")
                HStack {
                    Link("Check for updates", destination: URL(string: "https://github.com/thunderboltsid/ekagrachit/releases")!)
                    Spacer()
                    Link("Privacy", destination: URL(string: "https://github.com/thunderboltsid/ekagrachit/blob/main/PRIVACY.md")!)
                    Spacer()
                    Link("Help", destination: URL(string: "https://github.com/thunderboltsid/ekagrachit/blob/main/docs/installation.md#troubleshooting")!)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(.vertical, 8)
        .onAppear { launchAtLogin = settings.launchAtLogin }
    }
}

/// Setup checklist with live status. Shown at launch when something is missing
/// (and once on first launch), so a menu-bar-only app never starts silently broken.
struct SetupView: View {
    @ObservedObject var coordinator: FocusSessionCoordinator
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                Text("Set up Ekagrachit").font(.title2.weight(.semibold))
                Text("Two things are needed before your first focus session.")
                    .foregroundStyle(.secondary)
                }
            }
            step(done: coordinator.extensionConnected,
                 title: "Chrome extension connected",
                 detail: coordinator.extensionConnected
                    ? "Version \(coordinator.extensionVersion ?? "?")"
                    : "In Chrome's Extensions page, turn on Developer mode (top right), then drag the “Chrome Extension” folder onto the page.") {
                if !coordinator.extensionConnected {
                    HStack {
                        Button("Open Chrome Extensions") { coordinator.openChromeExtensionsPage() }
                        Button("Show Extension Folder") { coordinator.revealExtensionFolder() }
                            .disabled(coordinator.extensionFolder == nil)
                    }
                    .buttonStyle(.glass)
                }
            }
            step(done: coordinator.accessibilityTrusted,
                 title: "Accessibility permission",
                 detail: coordinator.accessibilityTrusted
                    ? "Lets Ekagrachit bring the focus window back when you switch away."
                    : "Lets Ekagrachit bring the focus window back when you switch away. Nothing else is read or controlled.") {
                if !coordinator.accessibilityTrusted {
                    Button("Open System Settings") {
                        Permissions.requestAccessibility()
                        Permissions.openAccessibilitySettings()
                    }
                    .buttonStyle(.glass)
                }
            }
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "circle.circle")
                Text("Ekagrachit lives in the menu bar. Click it to start a session; \(HotKey.emergencyDisplay) ends one early.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
            HStack {
                Spacer()
                Button(coordinator.extensionConnected && coordinator.accessibilityTrusted ? "Done" : "Later", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear { coordinator.refreshPermissions() }
    }

    private func step<Accessory: View>(done: Bool, title: String, detail: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title2)
                .foregroundStyle(done ? Color.green : Color.secondary)
                .accessibilityLabel(done ? "Done" : "Not done")
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                accessory()
            }
        }
    }
}
