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
                HStack(spacing: 12) {
                    Picker("Meeting mode", selection: $model.meetingMode) { Text("Online meeting").tag(MeetingMode.online); Text("In person").tag(MeetingMode.inPerson) }.labelsHidden().pickerStyle(.segmented).fixedSize()
                    if !model.meetingLanguageOptions.isEmpty {
                        Picker("Language", selection: Binding(get: { model.languageIDs.contains(model.meetingLanguage) ? model.meetingLanguage : "" },
                                                              set: { model.meetingLanguage = $0 })) {
                            ForEach(model.meetingLanguageOptions) { Text($0.name).tag($0.id) }
                        }.labelsHidden().fixedSize()
                    }
                }
                // Configuration lives in Settings; only the first thing blocking this meeting shows here.
                if let blocker {
                    HStack(spacing: 12) {
                        Text(blocker.message).font(DesignSystem.font(15)).foregroundStyle(DesignSystem.body)
                        Button(blocker.action, action: blocker.perform).buttonStyle(CirclesButtonStyle()).disabled(model.updateInProgress)
                    }
                }
                HStack(spacing: 12) {
                    Button("Start meeting") { model.startMeeting() }.buttonStyle(CirclesButtonStyle(primary: true, compact: false)).disabled(!model.ready || model.isBusy || (model.meetingMode == .online && !model.screenGranted))
                    Button("Cancel", action: onCancel).buttonStyle(CirclesButtonStyle(compact: false))
                }
            }.padding(32).frame(maxWidth: 844, alignment: .leading)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await model.refreshPermissions() } }
    }
    private var blocker: (message: String, action: String, perform: () -> Void)? {
        let settings = { model.meetingSetupPresented = false; model.sidebar = .settings }
        if !model.micGranted { return ("Microphone isn’t allowed", "Allow", model.grantMic) }
        if !model.hasKey { return ("Add your \(model.connectionProvider.credentialLabel)", "Settings", settings) }
        if model.keyStatus == .rejected { return ("\(model.connectionProvider.credentialLabel) not accepted", "Settings", settings) }
        if !model.consentAccepted { return ("Agree to tell participants before recording", "Settings", settings) }
        if model.meetingMode == .online && !model.screenGranted {
            return model.screenRequested ? ("Reopen Transcribe to use Mac audio", "Reopen", model.reopenForPermissions)
                                         : ("Mac audio isn’t allowed", "Allow", model.grantScreen)
        }
        return nil
    }
}

struct MeetingWorkspaceView: View {
    @EnvironmentObject var model: AppModel
    let record: SessionRecord
    private var capturing: Bool { model.activeSessionID == record.id && (model.phase == .starting || model.phase == .recording) }
    var body: some View {
        Group {
            if capturing { capture } else { MeetingPage(record: record) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(DesignSystem.surface)
    }
    private var capture: some View {
        VStack(alignment: .leading, spacing: 20) {
            EditableRecordTitle(record: record).id(record.id)
            sourceControls
            if record.liveMeetingVersion != nil, let notice = model.serviceNotice(for: record) {
                Text(notice.message).font(DesignSystem.font(13)).foregroundStyle(DesignSystem.warning)
            }
            LiveMeetingTranscriptView(record: record, order: model.liveOrder, drafts: model.meetingDrafts)
                .id(record.id).frame(maxWidth: 760, alignment: .leading)
        }.padding(24)
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
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let word = health.flatMap({ problemWord($0.state) }) { Text(word).font(DesignSystem.font(11)).foregroundStyle(DesignSystem.warning) }
            }.font(DesignSystem.font(13)).foregroundStyle(DesignSystem.muted)
            InputMeter(level: level)
        }
    }
    /// A word appears only when something is wrong. Mac audio is quiet whenever the others are.
    private func problemWord(_ state: CaptureHealthState) -> String? {
        switch state { case .interrupted: return "Interrupted"; case .unavailable: return "Unavailable"; default: return nil }
    }
}

/// The finished meeting: title, Copy transcript and ⋯, one summary paragraph, a hairline, the transcript.
private struct MeetingPage: View {
    @EnvironmentObject var model: AppModel
    let record: SessionRecord
    private var notice: AppModel.ServiceNotice? { model.serviceNotice(for: record) }
    private var noticeRetries: Bool { notice?.action == .retryTranscription }
    private var transcribing: Bool { record.status == .processing || (model.activeSessionID == record.id && model.isBusy) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .center, spacing: 12) {
                    EditableRecordTitle(record: record).id(record.id)
                    Spacer(minLength: 0)
                    if record.hasText {
                        ConfirmedCopyButton(accessibilityLabel: "Copy transcript", title: "Copy transcript") { model.copyTranscript(record.id) }
                            .buttonStyle(CirclesButtonStyle(primary: true))
                    }
                    Menu {
                        Button("Export…") { model.exportAs(record.id) }.disabled(!record.hasText && record.notes.isEmpty && record.summary.isEmpty)
                        if record.exportURL.map({ FileManager.default.fileExists(atPath: $0.path) }) == true {
                            Button("Show in Finder") { model.reveal(record.id) }
                        }
                        Divider()
                        Button("Delete meeting…", role: .destructive) { model.meetingToDelete = record.id }.disabled(!model.canDelete(record.id))
                    } label: { Text("···").font(DesignSystem.font(15, weight: .semibold)) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .padding(.horizontal, 14).frame(height: 36)
                        .overlay(Capsule().strokeBorder(DesignSystem.fieldBorder, lineWidth: 1))
                        .accessibilityLabel("More")
                }
                if !transcribing { problems }
                if !record.overview.isEmpty {
                    Text(record.overview).font(DesignSystem.font(15)).foregroundStyle(DesignSystem.body)
                        .lineSpacing(4).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Rectangle().fill(DesignSystem.border).frame(height: 1)
                }
                transcript
            }.padding(32).frame(maxWidth: 824, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    @ViewBuilder private var problems: some View {
        if let notice {
            HStack(spacing: 12) {
                Text(notice.message).font(DesignSystem.font(13)).foregroundStyle(DesignSystem.warning)
                Spacer(minLength: 0)
                if let action = notice.action {
                    Button(notice.buttonTitle) { model.performServiceAction(action, for: record.id) }
                        .buttonStyle(CirclesButtonStyle()).disabled(model.isBusy)
                }
            }
        }
        if record.captureIncomplete {
            Text("Part of the meeting wasn’t recorded").font(DesignSystem.font(13)).foregroundStyle(DesignSystem.muted)
        }
        if !record.usesLiveTranscription, record.canRecover, !noticeRetries {
            gapRow("Part of the audio couldn’t be transcribed")
        }
    }
    private func gapRow(_ message: String) -> some View {
        HStack(spacing: 12) {
            Text(message).font(DesignSystem.font(13)).foregroundStyle(DesignSystem.body)
            Spacer(minLength: 0)
            if !noticeRetries { Button("Retry") { model.retry(record.id) }.buttonStyle(CirclesButtonStyle()).disabled(model.isBusy) }
        }.padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 10)
            .background(DesignSystem.page, in: RoundedRectangle(cornerRadius: 12))
    }
    /// Captured audio with no transcript, at the time it happened. Close ranges read as one.
    private var gaps: [(start: Double, end: Double)] {
        guard record.usesLiveTranscription, !transcribing else { return [] }
        var merged: [(start: Double, end: Double)] = []
        for interval in uncoveredMeetingAudio(tracks: record.tracks, turns: record.meetingTurns, includePending: false)
            .sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, interval.start <= last.end + 2 { merged[merged.count - 1].end = max(last.end, interval.end) }
            else { merged.append((interval.start, interval.end)) }
        }
        return merged
    }
    private enum Row: Identifiable {
        case paragraph(TranscriptParagraph), gap(Double, Double)
        var id: String { switch self { case .paragraph(let p): return p.id; case .gap(let s, _): return "gap-\(s)" } }
        var start: Double { switch self { case .paragraph(let p): return p.start; case .gap(let s, _): return s } }
    }
    @ViewBuilder private var transcript: some View {
        let paragraphs = record.transcriptParagraphs
        let rows = (paragraphs.map(Row.paragraph) + gaps.map { Row.gap($0.start, $0.end) }).sorted { $0.start < $1.start }
        if paragraphs.isEmpty && transcribing {
            Text("Transcribing…").font(DesignSystem.font(15)).foregroundStyle(DesignSystem.muted)
        } else if paragraphs.isEmpty && record.status == .complete {
            Text("No speech").font(DesignSystem.font(15)).foregroundStyle(DesignSystem.muted)
        }
        LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(rows) { row in
                switch row {
                case .paragraph(let paragraph):
                    paragraphText(paragraph).font(DesignSystem.font(15)).foregroundStyle(DesignSystem.body)
                        .lineSpacing(4).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(record.segments.isEmpty ? "" : clock(paragraph.start))
                case .gap(let start, let end):
                    gapRow(clock(start) + "–" + clock(end) + " couldn’t be transcribed")
                }
            }
        }
    }
    private func paragraphText(_ paragraph: TranscriptParagraph) -> Text {
        guard let speaker = paragraph.speaker else { return Text(paragraph.text) }
        return Text(speaker).font(DesignSystem.font(15, weight: .semibold)).foregroundColor(DesignSystem.primary) + Text("   " + paragraph.text)
    }
}

func clock(_ seconds: Double) -> String {
    let n = max(0, Int(seconds)); return n >= 3600 ? String(format: "%d:%02d:%02d", n / 3600, n / 60 % 60, n % 60) : String(format: "%02d:%02d", n / 60, n % 60)
}

/// Each passage keeps the slot where it first appeared: grey while it is being
/// transcribed, final in the same place. Following exists only in the capture pane.
private struct LiveMeetingTranscriptView: View {
    let record: SessionRecord
    let order: [AppModel.LiveSlot]
    let drafts: [String: LiveMeetingDraft]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var follower = LiveTranscriptFollower()
    private let bottomID = "live-transcript-bottom"
    private struct Line: Identifiable { let id: Int; let source: Source; let text: String; let final: Bool }
    private var lines: [Line] {
        let confirmed = Dictionary(record.segments.map { ($0.idx, $0) }, uniquingKeysWith: { a, _ in a })
        return order.enumerated().compactMap { index, slot in
            if let turn = slot.turnIdx, let segment = confirmed[turn] { return Line(id: index, source: segment.source, text: segment.text, final: true) }
            if let key = slot.draftKey, let draft = drafts[key], !draft.text.isEmpty { return Line(id: index, source: draft.source, text: draft.text, final: false) }
            return nil
        }
    }
    var body: some View {
        let lines = self.lines
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if record.liveMeetingVersion == nil {
                        Text(record.preview).foregroundStyle(DesignSystem.muted).textSelection(.enabled)
                    } else {
                        ForEach(lines) { line in
                            text(line).foregroundStyle(line.final ? DesignSystem.body : DesignSystem.muted)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
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
    private func text(_ line: Line) -> Text {
        guard record.meetingMode == .online else { return Text(line.text) }
        return Text(line.source == .mic ? "You" : "Others").font(DesignSystem.font(15, weight: .semibold))
            .foregroundColor(line.final ? DesignSystem.primary : DesignSystem.muted) + Text("   " + line.text)
    }
}
