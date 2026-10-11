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
    private var notes: Binding<String> { Binding(get: { model.records.first { $0.id == record.id }?.notes ?? record.notes }, set: { model.updateNotes(record.id, $0) }) }
    private var summary: Binding<String> { Binding(get: { model.records.first { $0.id == record.id }?.summary ?? record.summary }, set: { model.updateSummary(record.id, $0) }) }
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
                        HStack { Text("Transcript").font(DesignSystem.font(20, weight: .bold)); StatusPill(title: "Preview") }
                        ScrollView { Text(record.preview.isEmpty ? "Your transcript will appear here." : record.preview).font(DesignSystem.font(15)).foregroundStyle(DesignSystem.muted).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    }.frame(width: 360, alignment: .topLeading)
                }.frame(maxHeight: .infinity)
            } else {
                reviewHeader
                if !record.issues.isEmpty { RecordIssuesView(record: record) }
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
            if record.hasText { Button("Copy") { model.copyTranscript(record.id) }.buttonStyle(CirclesButtonStyle()); Button("Export") { model.export(record.id) }.buttonStyle(CirclesButtonStyle()) }
            if record.canRecover { Button("Retry") { model.retry(record.id) }.buttonStyle(CirclesButtonStyle(primary: true)).disabled(model.isBusy) }
        }
    }
    private var summaryPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(record.summaryStatus == .processing ? "Generating notes…" : record.summary.isEmpty ? record.summaryStatus == .failed ? "Notes couldn’t be generated." : "No summary yet" : "Generated notes").font(DesignSystem.font(13)).foregroundStyle(DesignSystem.muted)
                Spacer()
                if record.hasText { Button(record.summary.isEmpty ? "Generate notes" : "Regenerate") { model.regenerateNotes(record.id) }.buttonStyle(CirclesButtonStyle()).disabled(record.summaryStatus == .processing || model.isBusy) }
            }
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
                                Text(duration(segment.start) + " · " + segment.label).font(DesignSystem.font(13, weight: .semibold)).foregroundStyle(DesignSystem.muted)
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
