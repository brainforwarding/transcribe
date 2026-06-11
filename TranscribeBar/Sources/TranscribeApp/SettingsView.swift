import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var replacingKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings").font(.title3).bold()

            row("Save to") {
                Text(model.saveFolder.path(percentEncoded: false))
                    .lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                Spacer()
                Button("Change…") { model.chooseFolder() }
            }
            Toggle("Keep audio files", isOn: $model.keepAudio)
            Toggle("Add a summary to each transcript (extra OpenAI cost)", isOn: $model.includeSummary)

            Divider()

            row(Config.proxyBaseURL != nil ? "Team token" : "OpenAI key") {
                KeyStatusLabel()
                Spacer()
                Button(replacingKey ? "Cancel" : "Replace…") {
                    replacingKey.toggle()
                    model.keyStatus = .idle
                }
            }
            if replacingKey { KeyField(onSaved: { replacingKey = false }) }

            if !model.micOnly {
                Divider()
                Text("⚠︎ Recording captures everyone in the call. Inform participants and get their consent — it's legally required in some places.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
            HStack {
                Spacer()
                Button("Quit Transcribe") { NSApp.terminate(nil) }
            }
        }
        .padding(18)
        .frame(width: 380, height: 340)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            Text(label).frame(width: 90, alignment: .leading)
            content()
        }
    }
}
