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

            row("OpenAI key") {
                Text(model.hasKey ? "•••• stored" : "not set").foregroundStyle(.secondary)
                Spacer()
                Button(replacingKey ? "Cancel" : "Replace…") { replacingKey.toggle() }
            }
            if replacingKey { KeyField() }

            Divider()

            if model.micOnly {
                Text("Mic only is on — recordings capture just your microphone (voice notes, thinking out loud). Turn it off in the menu to record meetings again.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Tip: use a headset — speakers cause echo on both tracks.")
                    .font(.caption).foregroundStyle(.secondary)
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
