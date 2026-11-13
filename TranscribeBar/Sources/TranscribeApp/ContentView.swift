import SwiftUI
import TranscribeCore
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var dropping = false
    @State private var dropKind: SessionKind = .meeting
    @State private var windowWidth: CGFloat = 0
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
                    if model.lastDeleted != nil && message == "Dictation deleted" {
                        Button("Undo") { model.undoDelete() }.buttonStyle(.plain)
                            .font(DesignSystem.font(13, weight: .semibold)).foregroundStyle(DesignSystem.link)
                    }
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
        .background(GeometryReader { proxy in
            Color.clear.onAppear { windowWidth = proxy.size.width }.onChange(of: proxy.size.width) { windowWidth = $0 }
        })
        .overlay {
            if dropping {
                HStack(spacing: 12) {
                    dropZone("Meeting", icon: "history-imgIconVideo", active: dropKind == .meeting)
                    dropZone("Dictation", icon: "history-imgIconMicrophone", active: dropKind == .dictation)
                }.padding(12)
                    .background(DesignSystem.surface.opacity(0.94))
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], delegate: FileDrop(enabled: !validationFixture, dropping: $dropping, kind: $dropKind,
                                                   width: windowWidth) { urls, kind in
            model.meetingSetupPresented = false; model.searchText = ""
            model.importAudioFiles(urls, as: kind)
        })
        .onAppear {
#if !TRANSCRIBE_VALIDATION_FIXTURE
            Task { await model.refreshPermissions(); model.refreshMics() }
#endif
        }
        .onChange(of: model.activeSessionID) { id in if id != nil { model.meetingSetupPresented = false } }
        .alert(deleteTitle, isPresented: Binding(get: { model.meetingToDelete != nil }, set: { if !$0 { model.meetingToDelete = nil } })) {
            Button("Cancel", role: .cancel) { model.meetingToDelete = nil }
            Button("Delete", role: .destructive) {
                if let id = model.meetingToDelete { model.delete(id) }
                model.meetingToDelete = nil
            }
        } message: {
            Text("The transcript and the recording move to the Trash. The exported file in your Meeting exports folder is kept.")
        }
    }
    /// Where the file is released is the choice: the left half makes a meeting, the right a dictation.
    private func dropZone(_ title: String, icon: String, active: Bool) -> some View {
        VStack(spacing: 12) {
            DesignIcon(name: icon, size: 34, color: active ? DesignSystem.action : DesignSystem.muted)
            Text(title).font(DesignSystem.font(20, weight: .bold)).foregroundStyle(active ? DesignSystem.primary : DesignSystem.muted)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(active ? DesignSystem.action.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(active ? DesignSystem.action : DesignSystem.border,
                                                                    style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
    }
    private var validationFixture: Bool {
#if TRANSCRIBE_VALIDATION_FIXTURE
        return true
#else
        return false
#endif
    }
    private var freezeContent: Bool { validationFixture || model.updateInProgress }
    private var deleteTitle: String {
        let title = model.records.first { $0.id == model.meetingToDelete }?.title ?? "meeting"
        return "Delete “\(title)”?"
    }
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
                    ForEach(dayGroups, id: \.date) { group in
                        Text(dayTitle(group.date)).font(DesignSystem.font(13, weight: .semibold)).foregroundStyle(DesignSystem.muted).padding(.top, 4)
                        ForEach(group.records) { record in
                            Button { model.selectRecord(record.id) } label: { HistoryRow(record: record, selected: model.selectedRecordID == record.id) }.buttonStyle(.plain)
                                .contextMenu {
                                    Button("Delete meeting…", role: .destructive) { model.meetingToDelete = record.id }.disabled(!model.canDelete(record.id))
                                }
                        }
                    }
                    if model.filteredRecords.isEmpty && !model.searchText.isEmpty { Text("No results").font(DesignSystem.font(13)).foregroundStyle(DesignSystem.muted).padding(.vertical, 24) }
                }
            }
        }.padding(16).frame(width: model.sidebar == .meetings ? 308 : 340).frame(maxHeight: .infinity).background(DesignSystem.page)
    }
    private var dayGroups: [(date: Date, records: [SessionRecord])] {
        let groups = Dictionary(grouping: model.filteredRecords) { Calendar.current.startOfDay(for: $0.startedAt) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!.sorted { $0.startedAt > $1.startedAt }) }
    }
    private func dayTitle(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
    @ViewBuilder private var emptyDetail: some View {
        if model.sidebar == .meetings {
            VStack {
                Button("New meeting") { model.meetingSetupPresented = true }
                    .buttonStyle(CirclesButtonStyle(primary: true, compact: false)).disabled(model.isBusy || validationFixture)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else { dictationEmptyDetail }
    }
    private var dictationEmptyDetail: some View {
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
    @EnvironmentObject var model: AppModel
    let record: SessionRecord
    let selected: Bool
    private var transcribing: Bool {
        record.status == .processing || (model.activeSessionID == record.id && [.stopping, .transcribing].contains(model.phase))
    }
    private var timeLine: String {
        let time = record.startedAt.formatted(date: .omitted, time: .shortened)
        return record.duration > 0 ? time + " · " + minutes(record.duration) : time
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(record.title).font(DesignSystem.font(15, weight: .semibold)).lineLimit(2)
            Text(record.listLine(transcribing: transcribing)).font(DesignSystem.font(13)).foregroundStyle(DesignSystem.muted).lineLimit(2)
            Text(timeLine).font(DesignSystem.font(12)).foregroundStyle(DesignSystem.muted).lineLimit(1)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? DesignSystem.selected : Color.clear, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12)).accessibilityElement(children: .combine)
    }
}

func minutes(_ seconds: Double) -> String {
    seconds < 60 ? "\(max(1, Int(seconds.rounded()))) s" : "\(Int((seconds / 60).rounded())) min"
}

struct EditableRecordTitle: View {
    @EnvironmentObject var model: AppModel
    let record: SessionRecord
    @State private var title = ""
    @State private var shown = ""
    @FocusState private var focused: Bool
    var body: some View {
        TextField("Untitled", text: Binding(get: { title }, set: { value in
            title = value; model.stageTitle(record.id, value)
        })).textFieldStyle(.plain).font(DesignSystem.font(28, weight: .bold, relativeTo: .title))
            .onAppear { title = record.title; shown = record.title }
            .onChange(of: record.title) { new in if title == shown { title = new }; shown = new }
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

func duration(_ seconds: Double) -> String {
    let n = max(0, Int(seconds)); return "\(n / 60):\(String(format: "%02d", n % 60))"
}

private struct FileDrop: DropDelegate {
    let enabled: Bool
    @Binding var dropping: Bool
    @Binding var kind: SessionKind
    let width: CGFloat
    let perform: @MainActor ([URL], SessionKind) -> Void
    private func side(_ info: DropInfo) -> SessionKind { info.location.x < width / 2 ? .meeting : .dictation }
    func validateDrop(info: DropInfo) -> Bool { enabled && info.hasItemsConforming(to: [.fileURL]) }
    func dropEntered(info: DropInfo) { kind = side(info); dropping = true }
    func dropUpdated(info: DropInfo) -> DropProposal? { kind = side(info); return DropProposal(operation: .copy) }
    func dropExited(info: DropInfo) { dropping = false }
    func performDrop(info: DropInfo) -> Bool {
        dropping = false
        let target = side(info)
        let providers = info.itemProviders(for: [.fileURL])
        guard enabled, !providers.isEmpty else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let data = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                   let file = URL(dataRepresentation: data, relativeTo: nil) { urls.append(file) }
            }
            if !urls.isEmpty { perform(urls, target) }
        }
        return true
    }
}
