import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var replacingKey = false
    @State private var consent = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Settings").font(DesignSystem.font(28, weight: .bold, relativeTo: .title))
                preference("Start / finish") { StatusPill(title: "⌥ ⌥ / ⌥"); Text("Double to start · Single to finish").foregroundStyle(DesignSystem.muted) }
                preference("Paste last") { StatusPill(title: "⌥ ⇧ V"); Toggle("Enable shortcut", isOn: $model.pasteLastShortcutEnabled).toggleStyle(.switch) }
                preference("Language") {
                    Picker("Language", selection: $model.languageID) { ForEach(model.languages) { Text($0.id == "auto" ? "Automatic" : $0.name).tag($0.id) } }.labelsHidden().fixedSize(horizontal: true, vertical: false).frame(width: 190, alignment: .leading)
                }
                preference("Appearance") {
                    Picker("Appearance", selection: $model.appearance) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }.labelsHidden().fixedSize(horizontal: true, vertical: false).frame(width: 190, alignment: .leading)
                }
                Divider().overlay(DesignSystem.border)
                preference("Connection") { ConnectionProviderPicker().fixedSize(horizontal: true, vertical: false).frame(width: 190, alignment: .leading) }
                preference(model.connectionProvider.credentialLabel) {
                    KeyStatusLabel(); Spacer(minLength: 8)
                    if model.tokenAccessRequired {
                        Button("Unlock") { model.unlockToken() }.buttonStyle(CirclesButtonStyle()).disabled(!model.canChangeConnectionProvider)
                    }
                    Button(replacingKey ? "Cancel" : model.hasKey ? "Replace" : "Add") { replacingKey.toggle() }.buttonStyle(CirclesButtonStyle()).disabled(!model.canChangeConnectionProvider)
                }
                if replacingKey { KeyField(onSaved: { replacingKey = false }) }
                preference("Microphone") {
                    HStack(spacing: 0) {
                        MicrophonePicker().lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                    }.frame(width: 270, alignment: .leading)
                }
                preference("Permissions") {
                    VStack(alignment: .leading, spacing: 8) {
                        permission("Microphone", allowed: model.micGranted, action: model.grantMic)
                        permission("Mac audio", allowed: model.screenGranted, action: model.grantScreen)
                        permission("Cursor insertion", allowed: model.accessibilityGranted, action: model.grantAccessibility)
                        permission("Shortcuts", allowed: model.shortcutAvailable, action: model.grantShortcuts)
                    }
                }
                if !model.consentAccepted {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("I’ll let participants know before recording a meeting.", isOn: $consent).toggleStyle(.checkbox)
                        Text("Audio is sent to OpenAI for transcription. Your history stays on this Mac.").font(DesignSystem.font(13)).foregroundStyle(DesignSystem.muted)
                        Button("Continue") { model.acceptConsent() }.buttonStyle(CirclesButtonStyle(primary: true)).disabled(!consent)
                    }
                }
                preference("Save to") {
                    Text(model.saveFolder.path).font(DesignSystem.font(13)).foregroundStyle(DesignSystem.muted).lineLimit(1).truncationMode(.head)
                    Button("Change") { model.chooseFolder() }.buttonStyle(CirclesButtonStyle())
                }
                Toggle("Keep audio", isOn: $model.keepAudio).toggleStyle(.switch)
                Toggle("Generate meeting summaries", isOn: $model.includeSummary).toggleStyle(.switch)
                Button("Import recordings…") { model.importLegacyRecordings() }.buttonStyle(CirclesButtonStyle())
                Divider().overlay(DesignSystem.border)
                Button("Quit Transcribe") { NSApp.terminate(nil) }.buttonStyle(CirclesButtonStyle())
            }.padding(32).frame(maxWidth: 920, alignment: .leading)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .font(DesignSystem.font()).foregroundStyle(DesignSystem.primary).background(DesignSystem.surface)
            .preferredColorScheme(model.colorScheme)
            .onAppear { Task { await model.refreshPermissions() }; model.refreshMics() }
            .onChange(of: model.connectionProvider) { _ in replacingKey = false }
    }
    private func preference<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 24) {
            Text(title).font(DesignSystem.font(15, weight: .semibold)).frame(width: 208, alignment: .leading)
            HStack(alignment: .top, spacing: 8) { content() }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minHeight: 36)
    }
    private func permission(_ title: String, allowed: Bool, action: @escaping () -> Void) -> some View {
        HStack { Text(title).frame(width: 148, alignment: .leading); if allowed { Text("Allowed").foregroundStyle(DesignSystem.success) } else { Button("Allow", action: action).buttonStyle(.plain).foregroundStyle(DesignSystem.link) } }.font(DesignSystem.font(13))
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
    @State private var value = ""
    @State private var saving = false
    var body: some View {
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
