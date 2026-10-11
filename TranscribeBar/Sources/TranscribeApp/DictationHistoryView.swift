import SwiftUI
import TranscribeCore

struct DictationHistoryView: View {
    @EnvironmentObject var model: AppModel
    @State private var renameRecordID: UUID?
    @State private var renameDraft = ""
    @State private var renamePresented = false

    private struct DayGroup: Identifiable {
        let date: Date
        let records: [SessionRecord]
        var id: Date { date }
    }

    private var visibleRecords: [SessionRecord] {
        model.filteredRecords.filter { record in
            record.hasText || !record.preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || record.canRecover || model.serviceNotice(for: record) != nil
                || isCaptureActive(record) || model.formattingRecordID == record.id
        }
    }
    private var dayGroups: [DayGroup] {
        let groups = Dictionary(grouping: visibleRecords) { Calendar.current.startOfDay(for: $0.startedAt) }
        return groups.keys.sorted(by: >).map { DayGroup(date: $0, records: groups[$0] ?? []) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(dayGroups) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(dayTitle(group.date)).font(DesignSystem.font(14, weight: .semibold)).foregroundStyle(DesignSystem.muted)
                                ForEach(group.records) { record in
                                    entry(record).id(record.id)
                                    Divider().overlay(DesignSystem.border)
                                }
                            }
                        }
                        if visibleRecords.isEmpty {
                            Text(model.searchText.isEmpty ? "No dictations yet" : "No results")
                                .font(DesignSystem.font(15)).foregroundStyle(DesignSystem.muted).padding(.vertical, 24)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.selectedRecordID) { id in
                    if let id, visibleRecords.contains(where: { $0.id == id }) { proxy.scrollTo(id, anchor: .top) }
                }
            }
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(DesignSystem.surface)
            .alert("Rename", isPresented: $renamePresented) {
                TextField("Title", text: $renameDraft)
                Button("Cancel", role: .cancel) { renameRecordID = nil }
                Button("Save") { saveTitle() }.disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Text("History").font(DesignSystem.font(24, weight: .bold))
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                DesignIcon(name: "history-imgIcon", size: 16)
                TextField("Search dictations", text: $model.searchText).textFieldStyle(.plain)
                if !model.searchText.isEmpty {
                    Button("Clear") { model.searchText = "" }.buttonStyle(.plain).font(DesignSystem.font(12))
                }
            }.padding(.horizontal, 16).frame(maxWidth: 320).frame(height: 36)
                .background(DesignSystem.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(DesignSystem.inputBorder, lineWidth: 1))
            Button("New") { model.startDictation() }.buttonStyle(.plain)
                .font(DesignSystem.font(14, weight: .semibold)).foregroundStyle(DesignSystem.link)
                .disabled(model.isBusy).help("Start dictation").accessibilityLabel("Start dictation")
        }
    }

    private func entry(_ record: SessionRecord) -> some View {
        let active = isCaptureActive(record)
        let formatting = model.formattingRecordID == record.id
        let notice = model.serviceNotice(for: record)
        let text = record.hasText ? record.transcript : record.preview
        let time = record.startedAt.formatted(date: .omitted, time: .shortened)
        return HStack(alignment: .top, spacing: 16) {
            Text(time).font(DesignSystem.font(13)).foregroundStyle(DesignSystem.muted)
                .frame(width: 72, alignment: .leading).accessibilityLabel(record.startedAt.formatted(date: .abbreviated, time: .shortened))
            VStack(alignment: .leading, spacing: 8) {
                if !record.title.isEmpty && record.title != "Dictation" {
                    Text(record.title).font(DesignSystem.font(15, weight: .semibold)).textSelection(.enabled)
                }
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(text).font(DesignSystem.font(16)).foregroundStyle(DesignSystem.body)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                } else if !active && !formatting && notice == nil && record.canRecover {
                    Text("Recording available").font(DesignSystem.font(14)).foregroundStyle(DesignSystem.muted)
                }
                if formatting {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small).accessibilityLabel("Retrying formatting")
                        Text("Retrying…").font(DesignSystem.font(13)).foregroundStyle(DesignSystem.muted)
                        Button("Cancel") { model.cancelFormattingRetry() }.buttonStyle(.plain)
                            .font(DesignSystem.font(13, weight: .semibold)).foregroundStyle(DesignSystem.link)
                            .help("Cancel formatting retry")
                    }
                } else if active {
                    Text(activeLabel).font(DesignSystem.font(13)).foregroundStyle(DesignSystem.muted)
                } else if let notice {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(notice.message).font(DesignSystem.font(13)).foregroundStyle(DesignSystem.muted)
                        if let action = notice.action {
                            Button(notice.buttonTitle) { model.performServiceAction(action, for: record.id) }
                                .buttonStyle(.plain).font(DesignSystem.font(13, weight: .semibold))
                                .foregroundStyle(DesignSystem.link).fixedSize()
                                .disabled(!model.canChangeConnectionProvider)
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                if record.hasText {
                    Button("Copy") { model.copyTranscript(record.id) }.buttonStyle(.plain)
                        .font(DesignSystem.font(14, weight: .semibold)).foregroundStyle(DesignSystem.link)
                        .help("Copy dictation").accessibilityLabel("Copy dictation from \(time)")
                } else if record.canRecover && notice == nil && !active && !formatting {
                    recoveryButton(record)
                }
                Menu {
                    if record.hasText { Button("Export") { model.export(record.id) } }
                    Button("Rename…") { rename(record) }
                    if record.canRecover {
                        Button(record.status == .cancelled ? "Recover" : "Retry transcription") {
                            model.performServiceAction(.retryTranscription, for: record.id)
                        }.disabled(!model.canChangeConnectionProvider)
                    }
                    if record.formattingFailure != nil {
                        Button("Retry formatting") { model.performServiceAction(.retryFormatting, for: record.id) }
                            .disabled(!model.canRetryFormatting(record))
                    }
                } label: {
                    Text("…").font(DesignSystem.font(18, weight: .semibold)).frame(width: 24, height: 24)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Actions").accessibilityLabel("Actions for dictation from \(time)")
            }
        }.padding(.vertical, 16).accessibilityElement(children: .contain)
    }

    private func recoveryButton(_ record: SessionRecord) -> some View {
        Button(record.status == .cancelled ? "Recover" : "Retry") { model.performServiceAction(.retryTranscription, for: record.id) }
            .buttonStyle(.plain).font(DesignSystem.font(14, weight: .semibold))
            .foregroundStyle(DesignSystem.link).disabled(!model.canChangeConnectionProvider)
    }
    private func isCaptureActive(_ record: SessionRecord) -> Bool {
        record.id == model.activeSessionID && [.starting, .recording, .stopping, .transcribing].contains(model.phase)
    }
    private var activeLabel: String {
        switch model.phase {
        case .starting: return "Starting…"
        case .recording: return "Recording…"
        default: return "Transcribing…"
        }
    }
    private func dayTitle(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
    private func rename(_ record: SessionRecord) {
        renameRecordID = record.id
        renameDraft = record.title == "Dictation" ? "" : record.title
        renamePresented = true
    }
    private func saveTitle() {
        let title = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = renameRecordID, !title.isEmpty, model.records.contains(where: { $0.id == id && $0.kind == .dictation }) else { return }
        model.updateTitle(id, title)
        renameRecordID = nil
    }
}
