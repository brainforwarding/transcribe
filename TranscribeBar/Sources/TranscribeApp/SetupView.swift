import SwiftUI

struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @State private var consent = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Set up Transcribe").font(DesignSystem.font(28, weight: .bold, relativeTo: .title))
                Text("Dictation and meeting notes, ready on your Mac.").foregroundStyle(DesignSystem.muted)
                if !model.hasKey || model.keyStatus == .checking || model.keyStatus == .rejected || model.keyStatus == .savedUnverified {
                    Text(Config.proxyBaseURL == nil ? "Connect OpenAI" : "Connect your team").font(DesignSystem.font(18, weight: .bold))
                    KeyField()
                }
                setupRow("Microphone", icon: "onboarding-imgIconMicrophone", detail: "Capture your voice.", allowed: model.micGranted, action: model.grantMic)
                setupRow("Paste & shortcuts", icon: "onboarding-imgIconMonitor", detail: "Use double Option and insert at your cursor.", allowed: model.accessibilityGranted && model.shortcutAvailable, action: model.grantShortcuts)
                if model.sidebar == .meetings { setupRow("Mac audio", icon: "onboarding-imgIconMonitor", detail: "Capture the other side of online meetings.", allowed: model.screenGranted, action: model.grantScreen) }
                if !model.consentAccepted {
                    Toggle("I’ll let participants know before recording a meeting.", isOn: $consent).toggleStyle(.checkbox)
                    Text("Audio is sent to OpenAI for transcription. Your history stays on this Mac.").font(DesignSystem.font(13)).foregroundStyle(DesignSystem.muted)
                    Button("Continue") { model.acceptConsent() }.buttonStyle(CirclesButtonStyle(primary: true, compact: false)).disabled(!consent || !model.hasKey || !model.micGranted || model.keyStatus == .checking || model.keyStatus == .rejected)
                } else if !model.accessibilityGranted && model.sidebar == .dictation {
                    Text("You can record and copy manually while you enable pasting.").font(DesignSystem.font(13)).foregroundStyle(DesignSystem.muted)
                    Button("Try a dictation") { model.startDictation() }.buttonStyle(CirclesButtonStyle(primary: true)).disabled(!model.ready || model.isBusy)
                }
                if !model.statusDetail.isEmpty { Text(model.statusDetail).font(DesignSystem.font(13)).foregroundStyle(DesignSystem.warning) }
            }.padding(32).frame(maxWidth: 740, alignment: .leading)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func setupRow(_ title: String, icon: String, detail: String, allowed: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 16) {
            DesignIcon(name: icon, size: 20)
            VStack(alignment: .leading, spacing: 4) { Text(title).font(DesignSystem.font(15, weight: .semibold)); Text(detail).font(DesignSystem.font(13)).foregroundStyle(DesignSystem.muted) }
            Spacer(minLength: 12)
            if allowed { StatusPill(title: "Allowed", color: DesignSystem.success, background: DesignSystem.successBackground) }
            else { Button("Allow", action: action).buttonStyle(CirclesButtonStyle()) }
        }.padding(16).background(DesignSystem.page, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct DictionaryView: View {
    @EnvironmentObject var model: AppModel
    @State private var word = ""
    @State private var validation = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Dictionary").font(DesignSystem.font(28, weight: .bold, relativeTo: .title))
            Text("Names and terms for dictation.").foregroundStyle(DesignSystem.muted)
            HStack(spacing: 12) {
                TextField("Add a name or term", text: $word).textFieldStyle(.plain).padding(.horizontal, 16).frame(height: 44).background(DesignSystem.surface, in: Capsule()).overlay(Capsule().strokeBorder(DesignSystem.inputBorder, lineWidth: 1)).onSubmit(add)
                Button("Add", action: add).buttonStyle(CirclesButtonStyle(primary: true, compact: false)).disabled(word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !validation.isEmpty { Text(validation).font(DesignSystem.font(13)).foregroundStyle(DesignSystem.error) }
            ScrollView { LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.dictionaryWords, id: \.self) { item in
                    HStack { Text(item); Spacer(); Button("Remove") { model.removeDictionaryWord(item) }.buttonStyle(.plain).foregroundStyle(DesignSystem.link).accessibilityLabel("Remove \(item)") }.padding(.vertical, 12)
                    Divider()
                }
            } }
            if model.dictionaryWords.isEmpty { Text("No terms added yet").font(DesignSystem.font(13)).foregroundStyle(DesignSystem.muted) }
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func add() {
        let term = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        guard model.dictionaryWords.count < 100 else { validation = "100 terms maximum"; return }
        guard term.count <= 100, !term.contains(where: { $0.isNewline || $0 == "<" || $0 == ">" }) else { validation = "Use a term up to 100 characters without line breaks or angle brackets."; return }
        guard !model.dictionaryWords.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) else { validation = "This term is already in your dictionary."; return }
        model.addDictionaryWord(term); word = ""; validation = ""
    }
}
