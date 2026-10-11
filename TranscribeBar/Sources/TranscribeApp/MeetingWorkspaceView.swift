import SwiftUI
import TranscribeCore

struct MeetingSetupView: View {
    @EnvironmentObject var model: AppModel
    var onCancel: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("New meeting").font(DesignSystem.font(28, weight: .bold, relativeTo: .title))
                TextField("Meeting title", text: $model.meetingTitle).textFieldStyle(.plain).padding(.horizontal, 16).frame(height: 44)
                    .background(DesignSystem.surface, in: Capsule()).overlay(Capsule().strokeBorder(DesignSystem.inputBorder, lineWidth: 1))
                Picker("Meeting mode", selection: $model.meetingMode) { Text("Online meeting").tag(MeetingMode.online); Text("In person").tag(MeetingMode.inPerson) }.labelsHidden().pickerStyle(.segmented).frame(maxWidth: 340, alignment: .leading)
                HStack { DesignIcon(name: "meetingSetup-imgIconMicrophone1", size: 20); Text("Microphone").font(DesignSystem.font(15, weight: .semibold)); Spacer(); MicrophonePicker().frame(width: 250) }.padding(16).background(DesignSystem.page, in: RoundedRectangle(cornerRadius: 12))
                if model.meetingMode == .online {
                    HStack {
                        DesignIcon(name: "meetingSetup-imgIconMonitor", size: 20)
                        VStack(alignment: .leading, spacing: 4) { Text("Mac audio").font(DesignSystem.font(15, weight: .semibold)); Text("Records all audio playing on this Mac.").font(DesignSystem.font(13)).foregroundStyle(DesignSystem.muted) }
                        Spacer()
                        if model.screenGranted { StatusPill(title: "Allowed", color: DesignSystem.success, background: DesignSystem.successBackground) }
                        else { Button("Allow") { model.grantScreen() }.buttonStyle(CirclesButtonStyle()) }
                    }.padding(16).background(DesignSystem.page, in: RoundedRectangle(cornerRadius: 12))
                }
                Text("Let everyone know before you record.").font(DesignSystem.font(13)).foregroundStyle(DesignSystem.muted)
                HStack(spacing: 12) {
                    Button("Start meeting") { model.startMeeting() }.buttonStyle(CirclesButtonStyle(primary: true, compact: false)).disabled(!model.ready || model.isBusy || (model.meetingMode == .online && !model.screenGranted))
                    Button("Cancel", action: onCancel).buttonStyle(CirclesButtonStyle(compact: false))
                }
            }.padding(32).frame(maxWidth: 844, alignment: .leading)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct MeetingWorkspaceView: View {
    @EnvironmentObject var model: AppModel
    let record: SessionRecord
    @State private var tab: ReviewTab = .summary
    @State private var focusedTurnID: String?
    @State private var showNotesSnapshot = false
    enum ReviewTab: String, CaseIterable { case summary = "Summary", notes = "My notes", transcript = "Transcript" }
    private var capturing: Bool { model.activeSessionID == record.id && (model.phase == .starting || model.phase == .recording) }
    private var notes: Binding<String> { Binding(get: { model.editableNotes(for: record.id) }, set: { model.updateNotes(record.id, $0) }) }
    private var summary: Binding<String> { Binding(get: { model.editableSummary(for: record.id) }, set: { model.updateSummary(record.id, $0) }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 12) {
                EditableRecordTitle(record: record).id(record.id)
                Spacer(minLength: 0)
                StatusPill(title: record.statusLabel, color: capturing ? DesignSystem.error : record.isPartial ? DesignSystem.warning : DesignSystem.muted, background: capturing ? DesignSystem.errorBackground : record.isPartial ? DesignSystem.warningBackground : DesignSystem.subtle)
            }
            if capturing {
                sourceControls
                if !model.sourceIssue.isEmpty {
                    HStack { Text(model.sourceIssue).font(DesignSystem.font(13)); Spacer(); if record.meetingMode == .online { Button("Retry Mac audio") { model.retrySystemAudio() }.buttonStyle(.plain).foregroundStyle(DesignSystem.link) } }
                        .foregroundStyle(DesignSystem.warning).padding(12).background(DesignSystem.warningBackground, in: RoundedRectangle(cornerRadius: 12))
                }
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("My notes").font(DesignSystem.font(20, weight: .bold))
                        EditableTextArea(text: notes, placeholder: "Write what matters…").frame(maxHeight: .infinity).accessibilityLabel("My meeting notes")
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { Text("Transcript").font(DesignSystem.font(20, weight: .bold)); StatusPill(title: record.liveMeetingVersion == nil ? "Preview" : "Live") }
                        if record.liveMeetingVersion != nil {
                            if let notice = model.serviceNotice(for: record) { Text(notice.message).font(DesignSystem.font(13)).foregroundStyle(DesignSystem.warning) }
                            LiveMeetingTranscriptView(record: record, drafts: sortedDrafts).id(record.id)
                        } else {
                            LiveMeetingTranscriptView(record: record, drafts: []).id(record.id)
                        }
                    }.frame(width: 360, alignment: .topLeading)
                }.frame(maxHeight: .infinity)
            } else {
                reviewHeader
                if record.liveMeetingVersion != nil, let notice = model.serviceNotice(for: record) {
                    HStack(spacing: 12) {
                        Text(notice.message).font(DesignSystem.font(13)).foregroundStyle(DesignSystem.warning)
                        Spacer(minLength: 0)
                        if let action = notice.action {
                            Button(notice.buttonTitle) { model.performServiceAction(action, for: record.id) }
                                .buttonStyle(CirclesButtonStyle()).disabled(model.isBusy)
                        }
                    }
                }
                if record.liveMeetingVersion == nil, !record.issues.isEmpty { RecordIssuesView(record: record) }
                Picker("Meeting content", selection: $tab) { ForEach(ReviewTab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().pickerStyle(.segmented).frame(maxWidth: 372)
                switch tab {
                case .notes: EditableTextArea(text: notes, placeholder: "Your personal notes…").accessibilityLabel("My meeting notes")
                case .transcript: transcript
                case .summary: summaryPanel
                }
            }
        }.padding(capturing ? 24 : 32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(DesignSystem.surface)
            .onChange(of: record.id) { _ in tab = .summary; focusedTurnID = nil }
            .sheet(isPresented: $showNotesSnapshot) {
                VStack(alignment: .leading, spacing: 20) {
                    HStack { Text("Notes used for this summary").font(DesignSystem.font(20, weight: .bold)); Spacer(); Button("Done") { showNotesSnapshot = false }.buttonStyle(CirclesButtonStyle()) }
                    ScrollView { Text(record.summaryNotesSnapshot).foregroundStyle(DesignSystem.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                }.padding(24).frame(width: 600, height: 420).font(DesignSystem.font()).background(DesignSystem.surface).preferredColorScheme(model.colorScheme)
            }
    }
    private var sortedDrafts: [LiveMeetingDraft] {
        model.meetingDrafts.values.sorted { $0.source != $1.source ? $0.source < $1.source : $0.itemID < $1.itemID }
    }
    private var sourceControls: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) { DesignIcon(name: "liveMeeting-imgIconClock", size: 16); Text(duration(Double(model.elapsed))).font(DesignSystem.font(16, weight: .semibold)).frame(minWidth: 50, alignment: .leading) }
            Spacer(minLength: 0)
            source("Mic", icon: "liveMeeting-imgIconMicrophone", level: model.micLevel, health: model.micHealth)
            if record.meetingMode == .online { source("Mac audio", icon: "liveMeeting-imgIconMonitor", level: model.systemLevel, health: model.systemHealth) }
            Button(model.phase == .starting ? "Starting…" : "Finish meeting") { model.finishRecording() }.buttonStyle(CirclesButtonStyle(primary: true)).disabled(model.phase == .starting)
        }.padding(16).background(DesignSystem.page, in: RoundedRectangle(cornerRadius: 16))
    }
    private func source(_ title: String, icon: String, level: Double, health: CaptureHealth?) -> some View {
        HStack(spacing: 8) {
            DesignIcon(name: icon, size: 16)
            VStack(alignment: .leading, spacing: 2) { Text(title); if let health { Text(healthLabel(health.state)).font(DesignSystem.font(11)) } }.font(DesignSystem.font(13)).foregroundStyle(DesignSystem.muted)
            InputMeter(level: level)
        }
    }
    private func healthLabel(_ state: CaptureHealthState) -> String {
        switch state { case .starting: return "Starting"; case .active: return "Active"; case .silent: return "Quiet"; case .interrupted: return "Interrupted"; case .unavailable: return "Unavailable" }
    }
    private var reviewHeader: some View {
        HStack(spacing: 12) {
            Text(record.startedAt.formatted(date: .abbreviated, time: .shortened) + " · " + duration(record.duration)).font(DesignSystem.font(13)).foregroundStyle(DesignSystem.muted)
            Spacer(minLength: 0)
            if record.hasText { ConfirmedCopyButton(accessibilityLabel: "Copy meeting transcript") { model.copyTranscript(record.id) }.buttonStyle(CirclesButtonStyle()); Button("Export") { model.export(record.id) }.buttonStyle(CirclesButtonStyle()) }
            if record.canRecover && !(record.liveMeetingVersion != nil && model.serviceNotice(for: record)?.action == .retryTranscription) { Button("Retry") { model.retry(record.id) }.buttonStyle(CirclesButtonStyle(primary: true)).disabled(model.isBusy) }
        }
    }
    private var summaryPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(record.summaryStatus == .processing ? "Generating notes…" : record.summary.isEmpty ? record.summaryStatus == .failed ? "Notes couldn’t be generated." : "No summary yet" : "Generated notes").font(DesignSystem.font(13)).foregroundStyle(DesignSystem.muted)
                Spacer()
                if record.hasText { Button(record.summary.isEmpty ? "Generate notes" : "Regenerate") { model.regenerateNotes(record.id) }.buttonStyle(CirclesButtonStyle()).disabled(record.summaryStatus == .processing || model.isBusy) }
            }
            if record.summaryIsStale { Text("New transcript passages are available. Regenerate to include them.").font(DesignSystem.font(13)).foregroundStyle(DesignSystem.warning) }
            if !record.summary.isEmpty { EditableTextArea(text: summary).frame(minHeight: 120).accessibilityLabel("Generated meeting notes") }
            if !record.summaryEvidence.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Sources").font(DesignSystem.font(15, weight: .semibold))
                        ForEach(record.summaryEvidence, id: \.id) { evidence in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(evidence.text).font(DesignSystem.font(13)).foregroundStyle(DesignSystem.body)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: 8) { ForEach(evidence.turnIDs, id: \.self) { id in
                                    if id == "notes-0" { Button("My notes") { if record.summaryNotesSnapshot != record.notes { showNotesSnapshot = true } else { tab = .notes } }.buttonStyle(.plain).foregroundStyle(DesignSystem.link) }
                                    else if let segment = record.segments.first(where: { $0.turnID == id }) { Button(duration(segment.start) + " · " + segment.label) { focusedTurnID = id; tab = .transcript }.buttonStyle(.plain).foregroundStyle(DesignSystem.link) }
                                } }.font(DesignSystem.font(12))
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 190)
            }
            if record.summary.isEmpty { Spacer() }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if record.segments.isEmpty {
                        Text(record.transcript.isEmpty ? record.status == .processing ? "Transcribing…" : "No transcript yet" : record.transcript).foregroundStyle(DesignSystem.body).textSelection(.enabled)
                    } else {
                        ForEach(record.segments, id: \.turnID) { segment in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(duration(segment.start) + " · " + segment.label).font(DesignSystem.font(13, weight: .semibold)).foregroundStyle(DesignSystem.muted).help(segment.timing == .audioInterval ? "Approximate passage time" : "Passage time")
                                Text(segment.text).foregroundStyle(DesignSystem.body).textSelection(.enabled)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(focusedTurnID == segment.turnID ? DesignSystem.selected : Color.clear, in: RoundedRectangle(cornerRadius: 12)).id(segment.turnID)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.onAppear { if let id = focusedTurnID { proxy.scrollTo(id, anchor: .top) } }
                .onChange(of: focusedTurnID) { id in if let id { proxy.scrollTo(id, anchor: .top) } }
        }
    }
}

/// Following exists only in the capture pane. Notes and finished review keep
/// their own ordinary scroll position, including summary-source navigation.
private struct LiveMeetingTranscriptView: View {
    let record: SessionRecord
    let drafts: [LiveMeetingDraft]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var follower = LiveTranscriptFollower()
    private let bottomID = "live-transcript-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if record.liveMeetingVersion == nil {
                        Text(record.preview.isEmpty ? "Your transcript will appear here." : record.preview)
                            .foregroundStyle(DesignSystem.muted).textSelection(.enabled)
                    } else {
                        ForEach(record.segments, id: \.turnID) { segment in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(duration(segment.start) + " · " + segment.label)
                                    .font(DesignSystem.font(12, weight: .semibold)).foregroundStyle(DesignSystem.muted)
                                    .help(segment.timing == .audioInterval ? "Approximate passage time" : "Passage time")
                                Text(segment.text).textSelection(.enabled)
                            }
                        }
                        ForEach(drafts, id: \.id) { draft in
                            VStack(alignment: .leading, spacing: 4) {
                                Text((draft.source == .system ? "System audio" : record.meetingMode == .inPerson ? "Microphone" : "You") + " · Draft")
                                    .font(DesignSystem.font(12, weight: .semibold))
                                Text(draft.text)
                            }.foregroundStyle(DesignSystem.muted)
                        }
                        if record.segments.isEmpty && drafts.isEmpty {
                            Text("Your transcript will appear here.").foregroundStyle(DesignSystem.muted)
                        }
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }.font(DesignSystem.font(15)).frame(maxWidth: .infinity, alignment: .leading)
                    .background(LiveTranscriptScrollProbe(follower: follower))
            }
            .onAppear { follower.contentChanged() }
            .onChange(of: record.transcriptRevision) { _ in follower.contentChanged() }
            .onChange(of: drafts) { _ in follower.contentChanged() }
            .onChange(of: record.preview) { _ in follower.contentChanged() }
            .onChange(of: follower.scrollPulse) { _ in
                if reduceMotion { proxy.scrollTo(bottomID, anchor: .bottom) }
                else { withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(bottomID, anchor: .bottom) } }
            }
            .onDisappear { follower.stop() }
        }
    }
}
