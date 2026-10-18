import SwiftUI
import TranscribeCore

struct DictationHistoryView: View {
    @EnvironmentObject var model: AppModel
    private struct DayGroup: Identifiable {
        let date: Date
        let records: [SessionRecord]
        var id: Date { date }
    }

    private var visibleRecords: [SessionRecord] {
        model.filteredRecords
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
        let recoveryAction: AppModel.ServiceAction? = record.canRecover ? .retryTranscription :
            (record.formattingFailure != nil && !(record.rawTranscript ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .retryFormatting : nil)
        let noticeProvidesRetry = recoveryAction != nil && notice?.action == recoveryAction
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
                } else if !active && !formatting && notice == nil {
                    Text(emptyMessage(for: record))
                        .font(DesignSystem.font(14)).foregroundStyle(DesignSystem.muted)
                    if record.captureIncomplete, let issue = record.issues.first,
                       !issue.contains("saved audio"), !issue.contains("saved recording") {
                        Text(issue).font(DesignSystem.font(13)).foregroundStyle(DesignSystem.muted)
                    }
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
                        if let action = notice.action, action != .retryFormatting || record.status == .complete {
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
                    ConfirmedCopyButton(accessibilityLabel: "Copy dictation from \(time)") { model.copyTranscript(record.id) }.buttonStyle(.plain)
                        .font(DesignSystem.font(14, weight: .semibold)).foregroundStyle(DesignSystem.link)
                }
                if let recoveryAction, !active, !formatting, !noticeProvidesRetry {
                    Button(record.status == .cancelled ? "Recover" : "Retry") {
                        model.performServiceAction(recoveryAction, for: record.id)
                    }.buttonStyle(.plain).font(DesignSystem.font(14, weight: .semibold))
                        .foregroundStyle(DesignSystem.link)
                        .disabled(recoveryAction == .retryFormatting ? !model.canRetryFormatting(record) : !model.canChangeConnectionProvider)
                        .help(recoveryAction == .retryFormatting ? "Retry formatting saved text" : "Retry saved recording")
                }
            }
        }.padding(.vertical, 16).accessibilityElement(children: .contain)
    }

    private func isCaptureActive(_ record: SessionRecord) -> Bool {
        record.id == model.activeSessionID && [.starting, .recording, .stopping, .transcribing].contains(model.phase)
    }
    private func emptyMessage(for record: SessionRecord) -> String {
        if record.status == .complete { return "No speech detected." }
        if record.tracks.contains(where: { !$0.spans.isEmpty }) { return "Recording saved. Transcription could not finish." }
        if record.status == .cancelled { return "Cancelled. No audio was captured." }
        return "No audio was captured. Check your microphone before trying again."
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
}
