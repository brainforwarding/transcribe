import SwiftUI
import AppKit
import TranscribeCore

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if !model.consentAccepted { consent }
            else if !model.hasKey { keyEntry }
            else if model.needsSetup { setup }
            else { main }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { Task { await model.refreshPermissions(); model.refreshMics() } }
    }

    // MARK: onboarding

    private var consent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Before you record").font(.headline)
            Text("This captures your mic **and everyone else's** audio and uploads it to OpenAI to transcribe. Tell participants and get their consent. Transcripts are saved on your Mac.")
                .font(.callout).foregroundStyle(.secondary)
            Button("I understand — continue") { model.acceptConsent() }
                .buttonStyle(.borderedProminent).frame(maxWidth: .infinity).controlSize(.large)
        }
    }

    private var keyEntry: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Config.proxyBaseURL != nil ? "Add your team token" : "Add your OpenAI key").font(.headline)
            Text("Stored securely in your Keychain.").font(.caption).foregroundStyle(.secondary)
            KeyField()
            if model.keyStatus == .rejected {
                Text("✗ token not recognized — check it and try again").font(.caption).foregroundStyle(.red)
            }
            if Config.proxyBaseURL == nil {
                Link("Get a key →", destination: URL(string: "https://platform.openai.com/api-keys")!).font(.caption)
            } else {
                Text("Ask your team admin for your token.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: setup (only shown while a grant is missing)

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Finish setup").font(.headline)
            if !model.micOnly {
                permissionRow("Screen & System Audio", model.screenGranted) { model.grantScreen() }
            }
            permissionRow("Microphone", model.micGranted) { model.grantMic() }
            if !model.screenGranted && !model.micOnly {
                Text("After granting Screen Recording, reopen the app to finish.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Quit & Reopen") { Permissions.relaunch() }.controlSize(.small)
                Toggle("Record just me (skip this permission)", isOn: $model.micOnly)
                Text("Only recording yourself — voice notes, self-interviews? \"Just me\" needs no Screen & System Audio permission.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
    }

    // MARK: main (idle / recording / transcribing)

    @ViewBuilder private var main: some View {
        switch model.phase {
        case .recording: recording
        case .transcribing: transcribing
        default: idle
        }
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 12) {
            pickerRow("Mic", selection: Binding(
                get: { model.selectedMicID ?? "" },
                set: { model.selectedMicID = $0.isEmpty ? nil : $0 })) {
                Text("System default").tag("")
                ForEach(model.mics) { Text($0.name).tag($0.uniqueID) }
            }
            pickerRow("Language", selection: $model.languageID) {
                ForEach(model.languages) { Text($0.name).tag($0.id) }
            }
            HStack {
                Text("Mode").frame(width: 64, alignment: .leading).foregroundStyle(.secondary)
                Picker("", selection: $model.micOnly) {
                    Text("Meeting").tag(false)
                    Text("Just me").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: .infinity)
                .help("Meeting: you + everyone on the call (You/Them transcript), needs Screen & System Audio permission. Just me: your voice only — notes, self-interviews.")
            }
            recordButton(title: "Record", system: "record.circle", tint: .accentColor)
            if !model.statusDetail.isEmpty {
                Text(model.statusDetail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
    }

    private var recording: some View {
        VStack(spacing: 16) {
            HStack(spacing: 9) {
                Circle().fill(.red).frame(width: 10, height: 10)
                Text(model.elapsedString)
                    .font(.system(size: 34, weight: .light, design: .monospaced))
                    .monospacedDigit()
            }.padding(.top, 6)
            if model.micOnly {
                Text("Just me").font(.caption).foregroundStyle(.secondary)
            }
            recordButton(title: "Stop", system: "stop.fill", tint: .red)
        }
    }

    private var transcribing: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.large)
            Text("Transcribing…").foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 10)
    }

    // MARK: reusable bits

    private var footer: some View {
        HStack(spacing: 10) {
            if model.phase == .done {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.caption)
            }
            Spacer()
            Button("Recordings") { model.openFolder() }.font(.caption).buttonStyle(.link)
            Button { model.showSettings?() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).help("Settings")
        }
    }

    private func recordButton(title: String, system: String, tint: Color) -> some View {
        Button { model.toggleRecord() } label: {
            Label(title, systemImage: system).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent).tint(tint).controlSize(.large)
        .disabled(model.phase == .transcribing)
    }

    private func pickerRow<T: Hashable, Content: View>(
        _ label: String, selection: Binding<T>, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label).frame(width: 64, alignment: .leading).foregroundStyle(.secondary)
            Picker("", selection: selection) { content() }.labelsHidden()
        }
    }

    private func permissionRow(_ label: String, _ granted: Bool, grant: @escaping () -> Void) -> some View {
        HStack {
            Circle().fill(granted ? .green : .red).frame(width: 8, height: 8)
            Text(label).font(.callout)
            Spacer()
            if !granted { Button("Grant", action: grant).controlSize(.small) }
        }
    }
}

/// Secure key entry (used in onboarding and Settings).
struct KeyField: View {
    @EnvironmentObject var model: AppModel
    @State private var text = ""
    var onSaved: (() -> Void)? = nil
    private var usesProxy: Bool { Config.proxyBaseURL != nil }
    private var checking: Bool { model.keyStatus == .checking }
    var body: some View {
        HStack {
            SecureField(usesProxy ? "team token" : "sk-…", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            Button(checking ? "Saving…" : "Save", action: save)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || checking)
        }
    }
    private func save() {
        let value = text
        Task {
            if await model.saveAndVerifyKey(value) {
                text = ""
                onSaved?()
            }
        }
    }
}

/// One-line status for the stored key/token (fingerprint + verification state).
struct KeyStatusLabel: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        switch model.keyStatus {
        case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("verifying…").foregroundStyle(.secondary) }
        case .rejected:
            Text("✗ token not recognized").foregroundStyle(.red)
        case .verified:
            Text("✓ verified").foregroundStyle(.green)
        case .savedUnverified:
            Text("saved — couldn't verify (offline?)").foregroundStyle(.secondary)
        case .idle:
            if let fp = model.keyFingerprint {
                Text("•••• \(fp) stored").foregroundStyle(.secondary)
            } else {
                Text("not set").foregroundStyle(.secondary)
            }
        }
    }
}
