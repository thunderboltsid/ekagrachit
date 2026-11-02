import AppKit
import EkagrachitCore
import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var coordinator: FocusSessionCoordinator

    var body: some View {
        if coordinator.phase == .active || coordinator.phase == .degraded {
            let minutes = Int((coordinator.remaining / 60).rounded(.up))
            Text("◉ \(minutes)m")
                .monospacedDigit()
                .accessibilityLabel("Ekagrachit, \(minutes) minutes remaining")
        } else {
            Image(systemName: "circle.circle")
                .accessibilityLabel("Ekagrachit")
        }
    }
}

struct MenuContentView: View {
    @ObservedObject var coordinator: FocusSessionCoordinator
    @State private var target = ""
    @State private var minutes = 25
    @State private var customText = ""
    @FocusState private var urlFocused: Bool
    private let presets = [15, 25, 45, 60]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("EKAGRACHIT")
                .font(.system(size: 12, weight: .semibold))
                .tracking(3)
                .frame(maxWidth: .infinity, alignment: .center)
            switch coordinator.phase {
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
            minutes = coordinator.settings.defaultMinutes
            urlFocused = true
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
            HStack(spacing: 6) {
                ForEach(presets, id: \.self) { m in
                    Button("\(m)m") {
                        minutes = m
                        customText = ""
                    }
                    .buttonStyle(.bordered)
                    .tint(minutes == m && customText.isEmpty ? .accentColor : nil)
                    .accessibilityAddTraits(minutes == m && customText.isEmpty ? .isSelected : [])
                }
                TextField("Custom", text: $customText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                    .onChange(of: customText) { v in
                        if let m = Int(v.filter(\.isNumber)), m > 0 { minutes = m }
                    }
                    .accessibilityLabel("Custom duration in minutes")
            }
            Button(action: start) {
                Text("Start Focus").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
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
            statusRow(ok: coordinator.extensionConnected,
                      okText: "Chrome extension connected" + (coordinator.extensionVersion.map { " (v\($0))" } ?? ""),
                      badText: coordinator.bridgeError ?? "Chrome extension not connected")
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
            Button("Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                if #available(macOS 14, *) {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                } else {
                    NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                }
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .disabled(coordinator.isSessionRunning)
                .help(coordinator.isSessionRunning ? "End the session first" : "Quit Ekagrachit")
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }

    private func start() {
        let m = Int(customText.filter(\.isNumber)) ?? minutes
        if coordinator.startSession(target: target, minutes: m) == nil {
            coordinator.settings.defaultMinutes = m
            target = ""
            customText = ""
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
                    .onChange(of: launchAtLogin) { settings.launchAtLogin = $0 }
                LabeledContent("Emergency exit", value: HotKey.emergencyDisplay)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(.vertical, 8)
        .onAppear { launchAtLogin = settings.launchAtLogin }
    }
}
