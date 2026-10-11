import SwiftUI
import TranscribeCore

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Group {
            if let active = model.activeRecord, active.kind == .meeting, model.phase == .starting || model.phase == .recording {
                MeetingWorkspaceView(record: active)
            } else {
            HStack(spacing: 0) {
            sidebar
            if model.sidebar == .settings { SettingsView().disabled(freezeContent) }
            else if model.sidebar == .dictionary { DictionaryView().disabled(freezeContent) }
            else if model.records.isEmpty && !model.ready { SetupView().disabled(freezeContent) }
            else if model.sidebar == .meetings && model.meetingSetupPresented && !model.isBusy { MeetingSetupView(onCancel: { model.meetingSetupPresented = false }) }
            else if model.sidebar == .dictation { DictationHistoryView().disabled(validationFixture) }
            else {
                history
                if let record = model.selectedRecord, record.kind == .meeting {
                    MeetingWorkspaceView(record: record).disabled(freezeContent)
                } else { emptyDetail }
            }
        }
            }
        }
        .preferredColorScheme(model.colorScheme)
        .font(DesignSystem.font()).foregroundStyle(DesignSystem.primary).background(DesignSystem.surface)
        .frame(minWidth: 880, idealWidth: 1120, maxWidth: .infinity, minHeight: 560, idealHeight: 680, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) {
            if let message = generalNotice {
                HStack(alignment: .top, spacing: 12) {
                    Text(message).font(DesignSystem.font(13)).foregroundStyle(DesignSystem.body)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { model.statusDetail = "" } label: {
                        DesignIcon(name: "chip-imgIconClose", size: 12, color: DesignSystem.muted)
                            .frame(width: 24, height: 24).background(DesignSystem.subtle, in: Circle())
                    }.buttonStyle(.plain).help("Dismiss").accessibilityLabel("Dismiss notice")
                }
                .padding(12).frame(maxWidth: 360, alignment: .leading)
                .background(DesignSystem.raised, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DesignSystem.border, lineWidth: 1))
                .shadow(color: DesignSystem.shadow, radius: 6, y: 4).padding(16)
            }
        }
        .onAppear {
#if !TRANSCRIBE_VALIDATION_FIXTURE
            Task { await model.refreshPermissions(); model.refreshMics() }
#endif
        }
        .onChange(of: model.activeSessionID) { id in if id != nil { model.meetingSetupPresented = false } }
    }
    private var validationFixture: Bool {
#if TRANSCRIBE_VALIDATION_FIXTURE
        return true
#else
        return false
#endif
    }
    private var freezeContent: Bool { validationFixture || model.updateInProgress }
    private var generalNotice: String? {
        let message = model.statusDetail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !model.records.contains(where: { record in
            record.issues.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == message }
        }) else { return nil }
        return message
    }
    private func switchSidebar(_ sidebar: AppModel.Sidebar) {
        model.sidebar = sidebar; model.selectedRecordID = nil; model.searchText = ""; model.meetingSetupPresented = false
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transcribe").font(DesignSystem.font(18, weight: .bold)).padding(.bottom, 8)
            nav("Dictation", "history-imgIconMicrophone", selected: model.sidebar == .dictation) { switchSidebar(.dictation) }
            nav("Meetings", "history-imgIconVideo", selected: model.sidebar == .meetings) { switchSidebar(.meetings) }
            nav("Dictionary", "history-imgIconBook", selected: model.sidebar == .dictionary) { switchSidebar(.dictionary) }
            nav("Settings", "history-imgIconSetting2", selected: model.sidebar == .settings) { switchSidebar(.settings) }
            Spacer()
            if model.updatePresentation != .hidden { SidebarUpdateButton() }
            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !version.isEmpty {
                Text(version).font(DesignSystem.font(12)).foregroundStyle(DesignSystem.muted)
                    .accessibilityLabel("Version \(version)")
            }
        }.padding(16).frame(width: 180).frame(maxHeight: .infinity).background(DesignSystem.subtle)
    }
    private func nav(_ title: String, _ icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                DesignIcon(name: icon)
                Text(title).font(DesignSystem.font(14, weight: .semibold))
                Spacer(minLength: 0)
            }.padding(8).frame(height: 38)
                .background(selected ? DesignSystem.selected : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var history: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.sidebar == .meetings ? "Meetings" : "Dictation").font(DesignSystem.font(20, weight: .bold))
                Spacer()
                Button { if model.sidebar == .meetings { model.meetingSetupPresented = true } else { model.startDictation() } } label: {
                    Text("New").font(DesignSystem.font(14, weight: .semibold)).foregroundStyle(DesignSystem.link).frame(height: 28)
                }.buttonStyle(.plain).disabled(model.isBusy || validationFixture)
                    .help(model.sidebar == .meetings ? "New meeting" : "Start dictation")
                    .accessibilityLabel(model.sidebar == .meetings ? "New meeting" : "Start dictation")
            }
            HStack(spacing: 8) {
                DesignIcon(name: "history-imgIcon", size: 18)
                TextField(model.sidebar == .meetings ? "Search meetings" : "Search dictations", text: $model.searchText).textFieldStyle(.plain).font(DesignSystem.font(15))
                if !model.searchText.isEmpty { Button("Clear") { model.searchText = "" }.buttonStyle(.plain).font(DesignSystem.font(12)) }
            }.padding(.horizontal, 16).frame(height: 44).background(DesignSystem.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(DesignSystem.inputBorder, lineWidth: 1))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.filteredRecords) { record in
                        Button { model.selectRecord(record.id) } label: { HistoryRow(record: record, selected: model.selectedRecordID == record.id) }.buttonStyle(.plain)
                    }
                    if model.filteredRecords.isEmpty { Text(model.searchText.isEmpty ? "No recordings yet" : "No results").font(DesignSystem.font(13)).foregroundStyle(DesignSystem.muted).padding(.vertical, 24) }
                }
            }
        }.padding(16).frame(width: model.sidebar == .meetings ? 308 : 340).frame(maxHeight: .infinity).background(DesignSystem.page)
    }
    private var emptyDetail: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(model.sidebar == .meetings ? "Meeting notes" : "Speak where you work").font(DesignSystem.font(28, weight: .bold, relativeTo: .title))
            Text(model.sidebar == .meetings ? "Keep your notes, transcript and summary together." : "Double-tap Option to start. Tap Option once to finish.").foregroundStyle(DesignSystem.muted)
            Button(model.sidebar == .meetings ? "New meeting" : "Try a dictation") { if model.sidebar == .meetings { model.meetingSetupPresented = true } else { model.startDictation() } }
                .buttonStyle(CirclesButtonStyle(primary: true, compact: false)).disabled(model.isBusy || validationFixture)
            Spacer()
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct HistoryRow: View {
    let record: SessionRecord
    let selected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(record.title).font(DesignSystem.font(15, weight: .semibold)).lineLimit(2)
            Text(record.hasText ? record.transcript : record.canRecover ? "Recording available for transcription." : record.preview).font(DesignSystem.font(13)).foregroundStyle(DesignSystem.muted).lineLimit(2)
            Text("\(record.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(duration(record.duration)) · \(record.statusLabel)").font(DesignSystem.font(12)).foregroundStyle(DesignSystem.muted).lineLimit(2)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? DesignSystem.selected : Color.clear, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12)).accessibilityElement(children: .combine)
    }
}

struct EditableRecordTitle: View {
    @EnvironmentObject var model: AppModel
    let record: SessionRecord
    @State private var title = ""
    @FocusState private var focused: Bool
    var body: some View {
        TextField("Untitled", text: Binding(get: { title }, set: { value in
            title = value; model.stageTitle(record.id, value)
        })).textFieldStyle(.plain).font(DesignSystem.font(28, weight: .bold, relativeTo: .title))
            .onAppear { title = record.title }.onChange(of: record.id) { _ in title = record.title }
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { active in if !active { commit() } }
            .onDisappear(perform: commit)
            .accessibilityLabel("Recording title")
            .disabled(model.updateInProgress)
    }
    private func commit() {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { title = record.title }
        else if value != record.title { model.updateTitle(record.id, value) }
    }

}

struct RecordIssuesView: View {
    let record: SessionRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if record.isPartial { Text("Partial transcript").font(DesignSystem.font(15, weight: .semibold)) }
            ForEach(Array(record.issues.enumerated()), id: \.offset) { _, issue in Text(issue).font(DesignSystem.font(13)) }
        }.foregroundStyle(DesignSystem.warning).padding(16).frame(maxWidth: .infinity, alignment: .leading).background(DesignSystem.warningBackground, in: RoundedRectangle(cornerRadius: 12))
    }
}

extension SessionRecord {
    var statusLabel: String {
        switch status {
        case .starting: return "Starting"
        case .recording: return "Recording"
        case .processing: return "Transcribing"
        case .partial: return "Partial"
        case .cancelled: return "Recoverable"
        case .failed: return "Retry needed"
        case .complete:
            if kind == .meeting { return "Complete" }
            switch delivery { case .inserted: return "Inserted"; case .cancelled: return "Saved"; default: return "Ready to copy" }
        }
    }
}
func duration(_ seconds: Double) -> String {
    let n = max(0, Int(seconds)); return "\(n / 60):\(String(format: "%02d", n % 60))"
}
