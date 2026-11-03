import AppKit
import EkagrachitCore
import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var coordinator: FocusSessionCoordinator

    var body: some View {
        if coordinator.phase == .active || coordinator.phase == .degraded {
            let minutes = Int((coordinator.remaining / 60).rounded(.up))
            HStack(spacing: 4) {
                Image(nsImage: BrandMark.menuBarImage(active: true))
                Text("\(minutes)m").monospacedDigit()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Ekagrachit, \(minutes) minutes remaining")
        } else {
            Image(nsImage: BrandMark.menuBarImage(active: false))
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
    @State private var selectedWindow: WindowCandidate?
    @State private var choice: DurationChoice = .preset(25)
    @State private var customMinutes = 90
    @FocusState private var urlFocused: Bool
    private let presets = [15, 25, 45, 60]

    private var minutes: Int {
        if case let .preset(m) = choice { return m }
        return customMinutes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
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
                // A sentence, not an alarm: say what happened and what to do.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text(m).fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
            }
            if needsAttention {
                Divider()
                statusRows
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .frame(width: 340)
        .onAppear {
            coordinator.refreshPermissions()
            let d = coordinator.settings.defaultMinutes
            if presets.contains(d) { choice = .preset(d) } else { choice = .custom; customMinutes = d }
            coordinator.refreshWindowChoices()
            // Start from what you were just doing: the page you were reading,
            // or the window you were working in. Exactly one of the two is
            // chosen, so Return always starts what the menu shows.
            selectedWindow = nil
            if let app = coordinator.appBeforeMenu, !WindowCandidates.browserBundleIDs.contains(app.bundleIdentifier ?? ""),
               let w = coordinator.frontWindowChoice(of: app.processIdentifier) {
                selectedWindow = w
                target = ""
                urlFocused = false
            } else {
                target = ""
                urlFocused = true
                coordinator.refreshSuggestion()
            }
        }
        .onChange(of: coordinator.suggestedTarget) { _, url in
            if let url, target.isEmpty, selectedWindow == nil { target = url }
        }
    }

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Focus on")
            TextField("A link: a doc, a pull request, a ticket", text: $target)
                .textFieldStyle(.roundedBorder)
                .focused($urlFocused)
                .onSubmit(start)
                .onChange(of: target) { _, v in if !v.isEmpty { selectedWindow = nil } }
                .accessibilityLabel("Link to focus on")
            if !coordinator.extensionConnected && !target.isEmpty {
                HStack(spacing: 4) {
                    Text("Links need the Chrome extension.").foregroundStyle(.secondary)
                    Button("Set Up…") { NotificationCenter.default.post(name: FocusSessionCoordinator.showSetupNotification, object: nil) }
                        .buttonStyle(.link)
                }
                .font(.caption)
            }
            if !coordinator.windowChoices.isEmpty {
                SectionLabel("Or a window", trailing: HotKey.quickStartDisplay)
                    .help("\(HotKey.quickStartDisplay) focuses the window in front of you, from anywhere")
                VStack(spacing: 2) {
                    ForEach(coordinator.windowChoices.prefix(5), id: \.number) { w in
                        WindowRow(window: w, selected: selectedWindow?.number == w.number) {
                            selectedWindow = w
                            target = ""
                            urlFocused = false
                        }
                    }
                }
            }
            SectionLabel("Minutes")
            Picker("Minutes", selection: $choice) {
                ForEach(presets, id: \.self) { Text("\($0)").monospacedDigit().tag(DurationChoice.preset($0)) }
                Text("Other").tag(DurationChoice.custom)
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
                Text("Start · \(minutes) min").fontWeight(.medium).monospacedDigit().frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(target.trimmingCharacters(in: .whitespaces).isEmpty && selectedWindow == nil)
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
            SectionLabel("Focusing on")
            Text(coordinator.machine.session?.target ?? "")
                .lineLimit(2).truncationMode(.middle)
            Text(HUDPanel.format(coordinator.remaining))
                .font(.system(size: 44, weight: .ultraLight)).monospacedDigit()
                .padding(.vertical, 2)
            if coordinator.phase == .degraded {
                Label(degradedText, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            }
            Button("End early…") { coordinator.requestEnd() }
                .buttonStyle(.glass)
                .help("Or press \(HotKey.emergencyDisplay) anywhere, then hold")
        }
    }

    private var degradedText: String {
        switch coordinator.machine.session?.degradedReason {
        case .extensionDisconnected?: return "Chrome extension disconnected — browser rules still apply."
        case .focusWindowMissing?: return "Focus window missing — reopening it."
        case nil: return "Enforcement degraded."
        }
    }

    /// Status is plumbing: show it only when something needs you.
    private var needsAttention: Bool {
        !coordinator.accessibilityTrusted || coordinator.bridgeError != nil
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

    /// Wordmark left, one gear right: Settings, About and Quit live behind it.
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center) {
                Text("EKAGRACHIT")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(3.2)
                Spacer()
                Menu {
                    Button("Settings…") { NotificationCenter.default.post(name: AppDelegate.showSettingsNotification, object: nil) }
                        .keyboardShortcut(",")
                    Button("About Ekagrachit") { NotificationCenter.default.post(name: AppDelegate.showAboutNotification, object: nil) }
                    Divider()
                    Button("Quit Ekagrachit") { NSApp.terminate(nil) }
                        .keyboardShortcut("q")
                        .disabled(coordinator.isSessionRunning)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Settings")
                .accessibilityLabel("Settings")
            }
            if coordinator.phase == .idle, let summary = coordinator.ledgerSummary {
                Text(summary).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    private func start() {
        let m = minutes
        let error: String?
        if let w = selectedWindow {
            error = coordinator.startAppSession(w.target, minutes: m)
        } else {
            error = coordinator.startSession(target: target, minutes: m)
        }
        if error == nil {
            coordinator.settings.defaultMinutes = m
            target = ""
            selectedWindow = nil
        }
    }
}

/// A small, quiet section label (Bauhaus: hierarchy by size and weight, not colour).
struct SectionLabel: View {
    let text: String
    var trailing: String?

    init(_ text: String, trailing: String? = nil) {
        self.text = text
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(.secondary)
            if let trailing {
                Spacer()
                Text(trailing).font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One row in the window picker: app icon, window title, app name.
struct WindowRow: View {
    let window: WindowCandidate
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(nsImage: NSRunningApplication(processIdentifier: window.pid)?.icon ?? NSImage())
                    .resizable().frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(window.title.isEmpty ? window.appName : window.title).lineLimit(1).truncationMode(.middle)
                    if !window.title.isEmpty {
                        Text(window.appName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(.tint) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(window.title.isEmpty ? window.appName : window.title), \(window.appName)")
        .accessibilityAddTraits(selected ? .isSelected : [])
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
                LabeledContent("Focus the window in front", value: HotKey.quickStartDisplay)
                LabeledContent("Emergency exit", value: HotKey.emergencyDisplay)
            }
            Section("About") {
                LabeledContent("Version", value: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev")
                LabeledContent("Chrome extension", value: coordinator.extensionVersion ?? "not connected")
                HStack {
                    Button("About the name") { NotificationCenter.default.post(name: AppDelegate.showAboutNotification, object: nil) }
                        .buttonStyle(.link)
                    Spacer()
                    Link("Check for updates", destination: URL(string: "https://github.com/thunderboltsid/ekagrachit/releases")!)
                    Spacer()
                    Link("Privacy", destination: URL(string: "https://github.com/thunderboltsid/ekagrachit/blob/main/PRIVACY.md")!)
                    Spacer()
                    Link("Help", destination: URL(string: "https://github.com/thunderboltsid/ekagrachit/blob/main/docs/installation.md#troubleshooting")!)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 600)
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
                Text("One permission, and a browser extension if you'll focus on web pages.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("एकाग्रचित्त — what does the name mean?") {
                    NotificationCenter.default.post(name: AppDelegate.showAboutNotification, object: nil)
                }
                .buttonStyle(.link)
                .font(.callout)
                }
            }
            step(done: coordinator.extensionConnected,
                 title: "Chrome extension · for web pages",
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
                 title: "Accessibility permission · required",
                 detail: coordinator.accessibilityTrusted
                    ? "Lets Ekagrachit bring the focus window back when you switch away."
                    : "Lets Ekagrachit bring the focus window back when you switch away. Nothing else is read or controlled. If Ekagrachit is already listed and switched on (for example after an update), remove it with − and add it again.") {
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
                Text("Ekagrachit lives in the menu bar. Click it to focus on a window or a link — or press \(HotKey.quickStartDisplay) to focus on the window in front of you. \(HotKey.emergencyDisplay) ends a session early.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
            HStack {
                Spacer()
                Button(coordinator.accessibilityTrusted ? "Done" : "Later", action: onDone)
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
