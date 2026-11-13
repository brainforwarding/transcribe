import SwiftUI
import AppKit
import TranscribeCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var replacingKey = false
    @State private var consent = false
    @State private var checkingDictation = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Settings").font(DesignSystem.font(28, weight: .bold, relativeTo: .title))
                group("Dictation") {
                    row("Start / finish", first: true) { StatusPill(title: "⌥ ⌥ / ⌥") }
                    row("Additional shortcut") {
                        Picker("Additional shortcut", selection: $model.additionalShortcut) {
                            ForEach(AdditionalShortcut.allCases, id: \.rawValue) { Text($0.title).tag($0) }
                        }.labelsHidden().fixedSize()
                    }
                    row("Paste last") {
                        StatusPill(title: "⌥ ⇧ V")
                        Toggle("Paste last shortcut", isOn: $model.pasteLastShortcutEnabled).toggleStyle(.switch).labelsHidden()
                    }
                    row("Check dictation") { Button("Check…") { checkingDictation = true }.buttonStyle(.bordered) }
                }
                group("Transcription") {
                    row("Languages", first: true) {
                        Menu(model.languageSummary) {
                            ForEach(model.languages) { language in
                                Toggle(language.name, isOn: Binding(get: { model.languageIDs.contains(language.id) },
                                                                    set: { _ in model.toggleLanguage(language.id) }))
                            }
                        }.fixedSize()
                    }
                    row("Microphone") { MicrophonePicker().fixedSize().frame(maxWidth: 300, alignment: .trailing) }
                    row("Keep audio") {
                        Picker("Keep audio", selection: $model.audioRetentionDays) {
                            Text("7 days").tag(7); Text("30 days").tag(30); Text("Forever").tag(-1)
                        }.labelsHidden().fixedSize()
                    }
                    row("Meeting exports") {
                        Text(model.saveFolder.path).font(DesignSystem.font(13)).foregroundStyle(DesignSystem.muted).lineLimit(1).truncationMode(.head)
                        Button("Change") { model.chooseFolder() }.buttonStyle(.bordered)
                    }
                }
                group("Connection") {
                    row("Service", first: true) { ConnectionProviderPicker().fixedSize() }
                    row(model.connectionProvider.credentialLabel) {
                        KeyStatusLabel()
                        if model.tokenAccessRequired {
                            Button("Unlock") { model.unlockToken() }.buttonStyle(.bordered).disabled(!model.canChangeConnectionProvider)
                        }
                        Button(replacingKey ? "Cancel" : model.hasKey ? "Replace" : "Add") { replacingKey.toggle() }.buttonStyle(.bordered).disabled(!model.canChangeConnectionProvider)
                    }
                    if replacingKey { KeyField(onSaved: { replacingKey = false }, inSettings: true).padding(.horizontal, 16).padding(.bottom, 12) }
                }
                group("Permissions") {
                    permission("Microphone", allowed: model.micGranted, first: true, action: model.grantMic)
                    permission("Mac audio", allowed: model.screenGranted, reopen: model.screenRequested, action: model.grantScreen)
                    permission("Cursor insertion", allowed: model.accessibilityGranted, action: model.grantAccessibility)
                    permission("Shortcuts", allowed: model.shortcutAvailable, action: model.grantShortcuts)
                }
                if !model.consentAccepted {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("I’ll let participants know before recording a meeting.", isOn: $consent).toggleStyle(.checkbox)
                        Button("Continue") { model.acceptConsent() }.buttonStyle(.borderedProminent).disabled(!consent)
                    }
                }
                group("App") {
                    row("Show in Dock", first: true) { Toggle("Show in Dock", isOn: $model.showInDock).toggleStyle(.switch).labelsHidden() }
                    row("Appearance") {
                        Picker("Appearance", selection: $model.appearance) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }.labelsHidden().fixedSize()
                    }
                }
            }.padding(32).frame(maxWidth: 764, alignment: .leading)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .font(DesignSystem.font()).foregroundStyle(DesignSystem.primary).background(DesignSystem.surface)
            .preferredColorScheme(model.colorScheme)
            .onAppear { Task { await model.refreshPermissions() }; model.refreshMics() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await model.refreshPermissions() } }
            .onChange(of: model.connectionProvider) { _ in replacingKey = false }
            .sheet(isPresented: $checkingDictation) {
                VStack(alignment: .leading, spacing: 24) {
                    DictationCheckView(inSheet: true)
                    HStack { Spacer(); Button("Done") { checkingDictation = false }.keyboardShortcut(.defaultAction) }
                }.padding(24).frame(width: 560).environmentObject(model)
            }
    }
    /// A titled group in the style of System Settings: label left, controls right.
    private func group<C: View>(_ title: String, @ViewBuilder rows: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(DesignSystem.font(13, weight: .semibold)).foregroundStyle(DesignSystem.muted)
            VStack(spacing: 0) { rows() }
                .background(DesignSystem.page, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DesignSystem.border, lineWidth: 1))
        }
    }
    private func row<C: View>(_ title: String, first: Bool = false, @ViewBuilder content: () -> C) -> some View {
        VStack(spacing: 0) {
            if !first { Divider().overlay(DesignSystem.border).padding(.leading, 16) }
            HStack(spacing: 8) {
                Text(title).font(DesignSystem.font(15, weight: .medium))
                Spacer(minLength: 16)
                content()
            }.padding(.horizontal, 16).frame(minHeight: 48)
        }
    }
    private func permission(_ title: String, allowed: Bool, first: Bool = false, reopen: Bool = false, action: @escaping () -> Void) -> some View {
        row(title, first: first) {
            if allowed {
                Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(DesignSystem.success).accessibilityLabel("Allowed")
            } else if reopen {
                Button("Reopen") { model.reopenForPermissions() }.buttonStyle(.bordered).disabled(model.isBusy)
            } else {
                Button("Allow", action: action).buttonStyle(.bordered)
            }
        }
    }
}

struct KeyStatusLabel: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Text(label).font(DesignSystem.font(13)).foregroundStyle(model.keyStatus == .rejected ? DesignSystem.error : DesignSystem.muted)
    }
    private var label: String {
        switch model.keyStatus {
        case .checking: return "Checking…"
        case .verified: return "Connected"
        case .rejected: return model.connectionProvider == .openAI ? "API key not accepted" : "Team token not accepted"
        case .savedUnverified: return "Saved · check connection"
        case .idle: return model.tokenAccessRequired ? "Unlock Keychain" : model.hasKey ? "Saved in Keychain" : model.connectionProvider == .team ? "Team token missing" : "OpenAI API key missing"
        }
    }
}

struct KeyField: View {
    @EnvironmentObject var model: AppModel
    var onSaved: () -> Void = {}
    /// In a Settings group: native controls, and the row above already shows status and Unlock.
    var inSettings = false
    @State private var value = ""
    @State private var saving = false
    var body: some View {
        if inSettings {
            HStack(spacing: 8) {
                SecureField(model.connectionProvider.credentialPlaceholder, text: $value).textFieldStyle(.roundedBorder).onSubmit { save() }
                Button(saving ? "Checking…" : "Connect") { save() }.buttonStyle(.borderedProminent)
                    .disabled(saving || !model.canChangeConnectionProvider || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.onChange(of: model.connectionProvider) { _ in value = "" }
        } else {
        VStack(alignment: .leading, spacing: 12) {
            SecureField(model.connectionProvider.credentialPlaceholder, text: $value).textFieldStyle(.plain).padding(.horizontal, 16).frame(height: 44)
                .background(DesignSystem.surface, in: Capsule()).overlay(Capsule().strokeBorder(DesignSystem.inputBorder, lineWidth: 1))
                .onSubmit { save() }
            HStack {
                Text("Stored securely in your Mac’s Keychain.").font(DesignSystem.font(13)).foregroundStyle(DesignSystem.muted)
                Spacer()
                if model.tokenAccessRequired {
                    Button("Unlock") { model.unlockToken() }.buttonStyle(CirclesButtonStyle()).disabled(saving || !model.canChangeConnectionProvider)
                }
                Button(saving ? "Checking…" : "Connect") { save() }.buttonStyle(CirclesButtonStyle(primary: true)).disabled(saving || !model.canChangeConnectionProvider || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if model.keyStatus == .rejected || model.keyStatus == .savedUnverified { KeyStatusLabel() }
        }
        .onChange(of: model.connectionProvider) { _ in value = "" }
        }
    }
    private func save() {
        guard !saving, model.canChangeConnectionProvider, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let submittedValue = value
        let submittedProvider = model.connectionProvider
        saving = true
        Task {
            guard model.connectionProvider == submittedProvider else { saving = false; return }
            let result = await model.saveAndVerifyKey(submittedValue)
            saving = false
            if result { value = ""; onSaved() }
        }
    }
}

struct ConnectionProviderPicker: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Picker("Connection", selection: Binding(get: { model.connectionProvider }, set: { model.setConnectionProvider($0) })) {
            ForEach(ConnectionProvider.allCases) { provider in Text(provider.title).tag(provider) }
        }.labelsHidden().disabled(!model.canChangeConnectionProvider)
    }
}

struct MicrophonePicker: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Picker("Microphone", selection: $model.selectedMicID) {
            Text("Default microphone").tag(String?.none)
            ForEach(model.mics, id: \.uniqueID) { mic in Text(mic.name).tag(Optional(mic.uniqueID)) }
        }.labelsHidden()
    }
}

extension AppModel {
    var colorScheme: ColorScheme? { appearance == "dark" ? .dark : appearance == "light" ? .light : nil }
}
