import Foundation
import SwiftUI
import AppKit
import TranscribeCore

struct LanguageOption: Identifiable, Hashable {
    let id: String
    let name: String
    var code: String? { id == "auto" ? nil : id }
}

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable { case idle, starting, recording, stopping, transcribing, done, error }
    enum Sidebar: String, CaseIterable { case dictation, meetings, dictionary, settings }
    enum ChipState: Equatable { case hidden, recording, warning, transcribing, inserted, ready, cancelled, failed, silent }
    enum KeyStatus: Equatable { case idle, checking, verified, rejected, savedUnverified }

    /// The coordinator owns state; these operations isolate hardware, network and side effects.
    /// Tests supply controlled completions while exercising the same production commands.
    struct CaptureSession {
        struct Output { let tracks: [SessionAudioTrack]; let issues: [TranscriptionIssue] }
        let start: () async throws -> Void
        let stop: () async -> Output
        let retrySystemAudio: () async throws -> Void
    }
    struct Operations {
        var makeCapture: (URL, String?, Bool,
            @escaping @Sendable (Source, Double) -> Void,
            @escaping @Sendable (CaptureHealth) -> Void,
            (@Sendable (PreviewWindow) -> Void)?) -> CaptureSession
        var transcribe: (SessionRecord, URL, OpenAIConfig) async throws -> FinalTranscription
        var uptime: () -> Double
        var credentials: () throws -> OpenAIConfig
        var save: (SessionStore, SessionRecord) throws -> Void
        var cleanAudio: (SessionStore, SessionRecord) throws -> Void
        var captureInsertion: () -> ((String) -> PasteService.Outcome)?
        var pasteAtCurrentCaret: (String) -> PasteService.Outcome
        var copy: (String) -> Void
        var automaticTimer = true

        @MainActor static func live() -> Operations {
            let paste = PasteService()
            return Operations(makeCapture: { directory, microphone, micOnly, level, health, preview in
                let capture = CaptureController(outDir: directory, micUniqueID: microphone, micOnly: micOnly)
                capture.onLevel = level; capture.onHealth = health; capture.onPreviewWindow = preview
                return CaptureSession(start: { try await capture.start() }, stop: {
                    let output = await capture.stop()
                    return CaptureSession.Output(tracks: output.tracks, issues: output.issues)
                }, retrySystemAudio: { try await capture.retrySystemAudio() })
            }, transcribe: { record, directory, credentials in
                let kind: TranscriptionKind = record.kind == .dictation ? .dictation
                    : record.meetingMode == .online ? .onlineMeeting : .inPersonMeeting
                return try await transcribeFinal(tracks: record.tracks, kind: kind, chunkDir: directory,
                    languages: record.language.map { [$0] } ?? [], keywords: record.keywords, config: credentials)
            }, uptime: { ProcessInfo.processInfo.systemUptime }, credentials: {
                guard let token = Keychain.get(), !token.isEmpty else { throw AppFailure.missingToken }
                return OpenAIConfig(baseURL: Config.apiBaseURL, authValue: "Bearer \(token)")
            }, save: { try $0.save($1) }, cleanAudio: { try $0.cleanAudio(for: $1) },
            captureInsertion: {
                guard let destination = paste.captureDestination() else { return nil }
                return { paste.insert($0, at: destination) }
            }, pasteAtCurrentCaret: { paste.pasteAtCurrentCaret($0) }, copy: { paste.copy($0) })
        }
    }
    @Published var phase: Phase = .idle
    @Published var records: [SessionRecord] = []
    @Published var selectedRecordID: UUID?
    @Published var sidebar: Sidebar = .dictation
    @Published var searchText = ""
    @Published var activeSessionID: UUID?
    @Published var activeKind: SessionKind?
    @Published var elapsed = 0
    @Published var micLevel = 0.0
    @Published var systemLevel = 0.0
    @Published var micHealth: CaptureHealth?
    @Published var systemHealth: CaptureHealth?
    @Published var sourceIssue = ""
    @Published var statusDetail = ""
    @Published var chipState: ChipState = .hidden
    @Published var chipVisible = false
    @Published var shortcutAvailable = false
    @Published var lastTranscript: URL?
    @Published var mics: [MicDevice] = []
    @Published var selectedMicID: String? { didSet { preferences.set(selectedMicID, forKey: "selectedMicID") } }
    @Published var micGranted = false
    @Published var screenGranted = false
    @Published var accessibilityGranted = false
    @Published var hasKey = false
    @Published var keyStatus: KeyStatus = .idle
    @Published var consentAccepted: Bool
    @Published var meetingMode: MeetingMode = .online
    @Published var meetingTitle = ""
    @Published var meetingSetupPresented = false
    @Published var saveFolder: URL { didSet { preferences.set(saveFolder.path, forKey: "saveFolderPath") } }
    @Published var keepAudio: Bool { didSet { preferences.set(keepAudio, forKey: "keepAudio") } }
    @Published var includeSummary: Bool { didSet { preferences.set(includeSummary, forKey: "includeSummary") } }
    @Published var languageID: String { didSet { preferences.set(languageID, forKey: "languageID") } }
    @Published var appearance: String { didSet { preferences.set(appearance, forKey: "appearance") } }
    @Published var dictionaryWords: [String] { didSet { preferences.set(dictionaryWords, forKey: "dictionaryWords") } }
    @Published var pasteLastShortcutEnabled: Bool {
        didSet { preferences.set(pasteLastShortcutEnabled, forKey: "pasteLastShortcutEnabled") }
    }
    let languages = [LanguageOption(id: "auto", name: "Auto"), LanguageOption(id: "en", name: "English"), LanguageOption(id: "es", name: "Spanish"), LanguageOption(id: "pt", name: "Portuguese")]
    var showLibrary: (() -> Void)?
    var showSettings: (() -> Void)?
    var retryShortcuts: (() -> Void)?
    private let preferences: UserDefaults
    private let operations: Operations
    private var store: SessionStore?
    private var controller: CaptureSession?
    private var timer: Timer?
    private var startedUptime = 0.0
    private var startupTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var pendingPreview: PreviewWindow?
    private var previewDisabled = false
    private var captureStatusSaveFailed = false
    private var automaticInsertion: ((String) -> PasteService.Outcome)?
    private var cancelledIDs: Set<UUID> = []
    private var dismissTask: Task<Void, Never>?
    var selectedRecord: SessionRecord? { records.first { $0.id == selectedRecordID } }
    var activeRecord: SessionRecord? { records.first { $0.id == activeSessionID } }
    var lastRecordWithText: SessionRecord? { records.first { $0.kind == .dictation && $0.hasText } }
    var isBusy: Bool { [.starting, .recording, .stopping, .transcribing].contains(phase) }
    var ready: Bool { micGranted && hasKey && consentAccepted && keyStatus != .checking && keyStatus != .rejected }
    var needsSetup: Bool { !ready }
    var micOnly: Bool { get { meetingMode == .inPerson } set { meetingMode = newValue ? .inPerson : .online } }
    var keyFingerprint: String? { Keychain.get().map { String($0.suffix(4)) } }
    var chipWidth: CGFloat {
        switch chipState {
        case .recording: return activeKind == .meeting ? 192 : 164
        case .warning, .failed: return 192
        case .transcribing, .silent: return 172
        case .inserted: return 144
        case .ready: return 152
        case .cancelled: return 190
        case .hidden: return 164
        }
    }
    var filteredRecords: [SessionRecord] {
        let kind: SessionKind = sidebar == .meetings ? .meeting : .dictation
        return records.filter { r in r.kind == kind && (searchText.isEmpty || [r.title,r.transcript,r.notes,r.summary].contains { $0.localizedCaseInsensitiveContains(searchText) }) }
    }
    init(store suppliedStore: SessionStore? = nil, operations suppliedOperations: Operations? = nil,
         preferences: UserDefaults = .standard, initializeSystemState: Bool = true) {
        self.preferences = preferences
        operations = suppliedOperations ?? .live()
        let p = preferences
        consentAccepted = p.bool(forKey: "consentAccepted")
        pasteLastShortcutEnabled = p.object(forKey: "pasteLastShortcutEnabled") as? Bool ?? true
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        saveFolder = URL(fileURLWithPath: p.string(forKey: "saveFolderPath") ?? docs.appendingPathComponent("Transcribe").path)
        keepAudio = p.bool(forKey: "keepAudio")
        includeSummary = p.object(forKey: "includeSummary") == nil ? true : p.bool(forKey: "includeSummary")
        languageID = p.string(forKey: "languageID") ?? "auto"
        appearance = p.string(forKey: "appearance") ?? "system"
        dictionaryWords = p.stringArray(forKey: "dictionaryWords") ?? []
        selectedMicID = p.string(forKey: "selectedMicID")
        if initializeSystemState { hasKey = Keychain.get() != nil }
        do {
            let s = try suppliedStore ?? SessionStore(); store = s; records = try s.load()
            records.sort { $0.startedAt > $1.startedAt }
            statusDetail = s.loadIssues.first ?? ""
        } catch { statusDetail = "History storage unavailable" }
        if initializeSystemState { refreshMics(); Task { await refreshPermissions() } }
    }
    func selectRecord(_ id: UUID) { selectedRecordID = id }
    func acceptConsent() { consentAccepted = true; preferences.set(true, forKey: "consentAccepted") }
    func refreshMics() { mics = MicCapture.available(); if let id = selectedMicID, !mics.contains(where: { $0.uniqueID == id }) { selectedMicID = nil } }
    func refreshPermissions() async {
        micGranted = Permissions.micAuthorized(); accessibilityGranted = Permissions.accessibilityAuthorized()
        screenGranted = CGPreflightScreenCaptureAccess(); hasKey = Keychain.get() != nil
    }
    func grantMic() { Task { _ = await Permissions.requestMic(); await refreshPermissions(); refreshMics() } }
    func grantScreen() { Permissions.requestScreen(); Task { await refreshPermissions() } }
    func grantAccessibility() { Permissions.requestAccessibility(); Task { await refreshPermissions() } }
    func grantShortcuts() {
        if !Permissions.accessibilityAuthorized() { grantAccessibility() }
        else { Permissions.requestInputMonitoring() }
        retryShortcuts?()
    }
    func chooseFolder() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false; p.directoryURL = saveFolder
        if p.runModal() == .OK, let url = p.url { saveFolder = url }
    }
    func importLegacyRecordings() {
        guard let store else { statusDetail = "History storage unavailable"; return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.directoryURL = saveFolder
        panel.prompt = "Import recordings"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let snapshot = records
        statusDetail = "Importing recordings…"
        Task { [weak self] in
            do {
                // Discovery never touches the coordinator's store/JSONEncoder on a background thread.
                let discovered = try await Task.detached(priority: .utility) {
                    try SessionStore.discoverMarkdown(from: folder, existing: snapshot)
                }.value
                guard let self else { return }
                // Captures/exports can complete during discovery. Deduplicate against committed state.
                var known = Set(self.records.flatMap { [$0.importURL, $0.exportURL].compactMap { $0?.standardizedFileURL.path } })
                var saved: [SessionRecord] = []
                var failed = false
                for record in discovered {
                    guard let path = record.exportURL?.standardizedFileURL.path, !known.contains(path) else { continue }
                    do {
                        try self.operations.save(store, record)
                        saved.append(record); known.insert(path)
                    } catch { failed = true; break }
                }
                self.records += saved
                self.records.sort { $0.startedAt > $1.startedAt }
                self.statusDetail = failed ? "Some recordings could not be imported"
                    : saved.isEmpty ? "No new recordings" : "Imported \(saved.count) recordings"
                if !saved.isEmpty { self.showLibrary?() }
            } catch { self?.statusDetail = "Import unavailable" }
        }
    }
    func saveKey(_ key: String) { Task { _ = await saveAndVerifyKey(key) } }
    func saveAndVerifyKey(_ key: String) async -> Bool {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines); guard !value.isEmpty else { return false }
        do { try Keychain.set(value); hasKey = true } catch { statusDetail = "Token could not be saved"; return false }
        guard let base = Config.proxyBaseURL else { keyStatus = .verified; return true }
        keyStatus = .checking
        var req = URLRequest(url: base.appendingPathComponent("chat/completions")); req.httpMethod = "POST"; req.timeoutInterval = 10
        req.setValue("Bearer \(value)", forHTTPHeaderField: "Authorization"); req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = #"{"model":"__verify__"}"#.data(using: .utf8)
        do {
            let (_, res) = try await URLSession.shared.data(for: req); let code = (res as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 { keyStatus = .rejected; return false }
            keyStatus = code == 403 || (200..<300).contains(code) ? .verified : .savedUnverified
        } catch { keyStatus = .savedUnverified }
        return true
    }
    func openMeetings() { sidebar = .meetings; selectedRecordID = nil; searchText = ""; meetingSetupPresented = true; showLibrary?() }
    func toggleRecord() { toggleDictation() }
    func toggleDictation() { if activeKind == .dictation && (phase == .starting || phase == .recording) { finishRecording() } else if !isBusy { startDictation() } }
    func startDictation() { start(kind: .dictation) }
    func startMeeting() { start(kind: .meeting) }
    private func start(kind: SessionKind) {
        guard !isBusy else { return }
        guard ready, let store else { statusDetail = "Finish setup"; showSettings?(); return }
        guard kind != .meeting || meetingMode != .online || screenGranted else { statusDetail = "Allow Mac audio"; showSettings?(); return }
        let title = kind == .dictation ? "Dictation" : meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = SessionRecord(kind: kind, meetingMode: meetingMode, title: title.isEmpty ? "Meeting" : title, language: languages.first { $0.id == languageID }?.code, keywords: dictionaryWords)
        do { try operations.save(store, r) } catch { statusDetail = "Recording could not be saved"; phase = .error; return }
        records.insert(r, at: 0); activeSessionID = r.id; activeKind = kind; phase = .starting
        automaticInsertion = kind == .dictation ? operations.captureInsertion() : nil
        elapsed = 0; startedUptime = operations.uptime(); micLevel = 0; systemLevel = 0
        sourceIssue = ""; statusDetail = ""; micHealth = nil; systemHealth = nil; previewDisabled = false; captureStatusSaveFailed = false; setChip(.recording)
        if kind == .meeting { sidebar = .meetings; selectedRecordID = r.id; meetingSetupPresented = false; showLibrary?() }
        let level: @Sendable (Source, Double) -> Void = { [weak self] source, level in Task { @MainActor in
            guard let self, self.activeSessionID == r.id else { return }
            if source == .mic { self.micLevel = level } else { self.systemLevel = level }
        } }
        let health: @Sendable (CaptureHealth) -> Void = { [weak self] health in Task { @MainActor in
            guard let self, self.activeSessionID == r.id else { return }; self.handleHealth(health, id: r.id)
        } }
        let preview: @Sendable (PreviewWindow) -> Void = { [weak self] window in Task { @MainActor in
            guard let self, self.activeSessionID == r.id else { return }; self.enqueuePreview(window, id: r.id)
        } }
        let ctl = operations.makeCapture(store.directory(for: r.id), selectedMicID,
            kind == .dictation || meetingMode == .inPerson, level, health, kind == .meeting ? preview : nil)
        controller = ctl
        startupTask = Task { [weak self] in
            do {
                try await ctl.start(); guard let self, self.activeSessionID == r.id, self.phase == .starting else { return }
                self.phase = .recording
                guard self.mutate(r.id, { $0.status = .recording }) else {
                    self.captureStatusSaveFailed = true; self.automaticInsertion = nil
                    self.finishRecording(); return
                }
                self.startTimer(id: r.id)
            } catch {
                guard let self, self.activeSessionID == r.id else { return }; self.statusDetail = "Recording could not start"
                _ = self.mutate(r.id) { $0.captureIncomplete = true; $0.issues.append("Recording could not start") }
                if self.phase == .starting { self.finishRecording() }
            }
        }
    }
    private func startTimer(id: UUID) {
        timer?.invalidate()
        guard operations.automaticTimer else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in Task { @MainActor in
            guard let self, self.activeSessionID == id else { return }; self.updateRecordingTime()
        } }
    }
    /// Timer wakeups are advisory; elapsed time and both deadlines use the monotonic clock.
    func updateRecordingTime() {
        guard let id = activeSessionID, phase == .recording else { return }
        let duration = max(0, operations.uptime() - startedUptime)
        let old = elapsed; elapsed = Int(duration)
        if elapsed != old && elapsed % 15 == 0 { _ = mutate(id) { $0.duration = duration } }
        if activeKind == .dictation {
            if duration >= 300 { finishRecording() }
            else if duration >= 270 && chipState == .recording { setChip(.warning) }
        }
    }
    private func handleHealth(_ h: CaptureHealth, id: UUID) {
        if h.source == .mic { micHealth = h } else { systemHealth = h }
        if h.state == .interrupted || h.state == .unavailable {
            let message = h.message ?? (h.source == .mic ? "Microphone unavailable" : "Mac audio unavailable"); sourceIssue = message
            _ = mutate(id) { $0.captureIncomplete = true; if !$0.issues.contains(message) { $0.issues.append(message) } }
            if h.source == .mic && phase == .recording { finishRecording() }
        }
    }
    func retrySystemAudio() { guard let controller, phase == .recording else { return }; Task { do { try await controller.retrySystemAudio(); sourceIssue = "" } catch { sourceIssue = "Mac audio unavailable" } } }
    func finishRecording() {
        guard phase == .starting || phase == .recording, let id = activeSessionID, let ctl = controller else { return }
        phase = .stopping; timer?.invalidate(); timer = nil; setChip(activeRecord?.delivery == .cancelled ? .cancelled : .transcribing)
        let startup = startupTask
        stopTask = Task { [weak self] in
            await startup?.value; let result = await ctl.stop(); guard let self, self.activeSessionID == id else { return }
            self.previewTask?.cancel(); await self.previewTask?.value; self.previewTask = nil
            if let w = self.pendingPreview { try? FileManager.default.removeItem(at: w.url) }; self.pendingPreview = nil
            let saved = self.mutate(id) {
                $0.duration = max(0, self.operations.uptime() - self.startedUptime); $0.tracks = result.tracks
                if !result.issues.isEmpty { $0.captureIncomplete = true; for i in result.issues where !$0.issues.contains(i.userMessage) { $0.issues.append(i.userMessage) } }
                $0.status = self.cancelledIDs.contains(id) || $0.delivery == .cancelled ? .cancelled
                    : self.captureStatusSaveFailed ? .failed : .processing
                if self.captureStatusSaveFailed {
                    $0.issues.append("Recording status could not be saved")
                    if $0.delivery == .eligible { $0.delivery = .ready }
                }
            }
            self.controller = nil; self.startupTask = nil
            guard saved else { self.phase = .error; self.setChip(.failed); return }
            guard !self.captureStatusSaveFailed else { self.phase = .error; self.setChip(.failed); return }
            if self.cancelledIDs.contains(id) || self.activeRecord?.delivery == .cancelled { self.phase = .done; self.setChip(.cancelled, dismissAfter: 12) } else { self.process(id: id) }
        }
    }
    func cancelDictation() {
        guard activeKind == .dictation, let id = activeSessionID, isBusy else { if activeKind == .meeting { chipVisible = false }; return }
        cancelledIDs.insert(id)
        _ = mutate(id) { $0.delivery = .cancelled; $0.status = .cancelled }; automaticInsertion = nil; setChip(.cancelled)
        if phase == .starting || phase == .recording { finishRecording() }
    }
    private enum AppFailure: Error { case missingToken }
    private func config() throws -> OpenAIConfig { try operations.credentials() }
    private func process(id: UUID) {
        guard let r = records.first(where: { $0.id == id }), let store else { return }
        guard mutate(id, { $0.status = .processing }) else { phase = .error; setChip(.failed); return }
        phase = .transcribing; if r.delivery != .cancelled { setChip(.transcribing) }
        processingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let credentials = try self.config()
                let result = try await self.operations.transcribe(r,
                    store.directory(for: id).appendingPathComponent("chunks"), credentials)
                guard self.activeSessionID == id else { return }
                guard self.mutate(id, {
                    $0.transcript = result.text; $0.segments = result.segments
                    $0.transcriptionIssues = result.issues
                    $0.issues = ($0.captureIncomplete ? $0.issues : []) + result.issues.map(\.userMessage)
                    $0.status = result.complete && !$0.captureIncomplete ? .complete : .partial
                    if self.cancelledIDs.contains(id) || $0.delivery == .cancelled { $0.status = .cancelled; $0.delivery = .cancelled }
                    else if $0.delivery == .eligible { $0.delivery = .ready }
                }) else { self.phase = .error; self.setChip(.failed); return }
                let current = self.records.first { $0.id == id }!
                if current.kind == .dictation {
                    if current.delivery == .cancelled { self.setChip(.cancelled, dismissAfter: 12) }
                    else if !current.hasText { self.setChip(result.complete ? .silent : .failed, dismissAfter: 8) }
                    else if current.status == .complete, r.delivery == .eligible, let insertion = self.automaticInsertion {
                        switch insertion(current.transcript) {
                        case .inserted: _ = self.mutate(id) { $0.delivery = .inserted }; self.setChip(.inserted, dismissAfter: 2)
                        case .ready: self.setChip(.ready, dismissAfter: 12)
                        }
                    } else { self.setChip(.ready, dismissAfter: 12) }
                } else {
                    self.export(id); self.chipVisible = false
                    if self.includeSummary && current.hasText { await self.generateNotes(for: id, credentials: credentials) }
                }
                self.automaticInsertion = nil
                if !self.keepAudio, !self.cancelledIDs.contains(id), let final = self.records.first(where: { $0.id == id }) { do { try self.operations.cleanAudio(store, final) } catch { self.statusDetail = "Transcript saved; audio retained" } }
                self.phase = .done
            } catch {
                _ = self.mutate(id) { $0.status = $0.delivery == .cancelled ? .cancelled : .failed; $0.issues.append("Transcription unavailable"); if $0.delivery == .eligible { $0.delivery = .ready } }
                self.phase = .error; self.statusDetail = self.hasKey ? "Transcription unavailable" : "Add your team token"
                self.setChip(self.activeRecord?.delivery == .cancelled ? .cancelled : .failed, dismissAfter: 12)
            }
        }
    }
    private func enqueuePreview(_ w: PreviewWindow, id: UUID) {
        guard !previewDisabled, phase == .recording || phase == .starting else { try? FileManager.default.removeItem(at: w.url); return }
        if let old = pendingPreview { try? FileManager.default.removeItem(at: old.url) }; pendingPreview = w
        guard previewTask == nil else { return }
        previewTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.activeSessionID == id, !self.previewDisabled, let next = self.pendingPreview {
                self.pendingPreview = nil; defer { try? FileManager.default.removeItem(at: next.url) }
                do {
                    let r = self.records.first { $0.id == id }
                    let text = try await transcribePreview(window: next, languages: r?.language.map { [$0] } ?? [], keywords: r?.keywords ?? [], config: self.config())
                    guard !Task.isCancelled else { break }; _ = self.mutate(id) { $0.preview += ($0.preview.isEmpty ? "" : "\n") + text }
                } catch { self.previewDisabled = true }
            }
            self.previewTask = nil
        }
    }
    func retry(_ id: UUID) {
        guard !isBusy, let r = records.first(where: { $0.id == id }) else { return }
        cancelledIDs.remove(id)
        automaticInsertion = nil; activeSessionID = id; activeKind = r.kind
        if r.hasText && r.status == .cancelled && r.issues.isEmpty { _ = mutate(id) { $0.status = .complete; $0.delivery = .ready }; phase = .done; setChip(.ready, dismissAfter: 12); return }
        guard r.canRecover, mutate(id, { $0.delivery = $0.kind == .dictation ? .ready : .never }) else { return }; process(id: id)
    }
    func recover(_ id: UUID) { retry(id) }
    func recoverCancelled() { if let id = activeSessionID { retry(id) } }
    func regenerateNotes(_ id: UUID) { guard let r = records.first(where: { $0.id == id }), r.kind == .meeting, r.hasText else { return }; Task { do { await generateNotes(for: id, credentials: try config()) } catch { statusDetail = "Add your team token" } } }
    private func generateNotes(for id: UUID, credentials: OpenAIConfig) async {
        guard let r = records.first(where: { $0.id == id }), r.summaryStatus != .processing, mutate(id, { $0.summaryStatus = .processing }) else { return }
        do {
            let transcript = FinalTranscription(text: r.transcript, segments: r.segments, complete: !r.isPartial, issues: [])
            let generated = try await TranscribeCore.generateNotes(transcription: transcript, originalNotes: r.notes, config: credentials)
            _ = mutate(id) {
                if $0.summary == r.summary {
                    $0.summary = generated.text; $0.summaryEvidenceIDs = generated.evidence.flatMap(\.turnIDs)
                    $0.summaryEvidence = generated.evidence
                    $0.summaryNotesSnapshot = r.notes
                }
                $0.summaryStatus = .complete
            }; export(id)
        } catch { _ = mutate(id) { $0.summaryStatus = .failed }; statusDetail = "Notes unavailable" }
    }
    func updateTitle(_ id: UUID, _ title: String) { _ = mutate(id) { $0.title = title } }
    func updateNotes(_ id: UUID, _ notes: String) { _ = mutate(id) { $0.notes = notes } }
    func updateSummary(_ id: UUID, _ text: String) {
        _ = mutate(id) { $0.summary = text; $0.summaryEvidenceIDs = []; $0.summaryEvidence = [] }
    }
    func addDictionaryWord(_ word: String) {
        let v = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard dictionaryWords.count < 100, !v.isEmpty, v.count <= 100, !v.contains(where: { $0.isNewline || $0 == "<" || $0 == ">" }), !dictionaryWords.contains(v) else { return }; dictionaryWords.append(v)
    }
    func removeDictionaryWord(_ word: String) { dictionaryWords.removeAll { $0 == word } }
    func copyTranscript(_ id: UUID) { if let r = records.first(where: { $0.id == id }), r.hasText { operations.copy(r.transcript) } }
    func pasteLast() {
        guard !isBusy, let r = lastRecordWithText else { return }
        switch operations.pasteAtCurrentCaret(r.transcript) { case .inserted: setChip(.inserted, dismissAfter: 2); case .ready: operations.copy(r.transcript); setChip(.ready, dismissAfter: 8) }
    }
    func copyLast() { if let r = lastRecordWithText { copyTranscript(r.id) } }
    func export(_ id: UUID) {
        guard let r = records.first(where: { $0.id == id }), r.hasText else { return }
        do {
            try FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
            let url = !r.imported ? r.exportURL ?? saveFolder.appendingPathComponent("\(r.startedAt.formatted(.iso8601).replacingOccurrences(of: ":", with: "-"))-\(id.uuidString.prefix(8)).md") : saveFolder.appendingPathComponent("\(id.uuidString.prefix(8)).md")
            var text = "# \(r.title)\n\n"; if r.isPartial { text += "Partial recording\n\n" }
            if !r.notes.isEmpty { text += "## My notes\n\n\(r.notes)\n\n" }; if !r.summary.isEmpty { text += "## Notes\n\n\(r.summary)\n\n" }
            text += "## Transcript\n\n\(r.transcript)\n"; try text.write(to: url, atomically: true, encoding: .utf8)
            _ = mutate(id) { $0.exportURL = url }; lastTranscript = url
        } catch { statusDetail = "Export unavailable" }
    }
    func reveal(_ id: UUID) { if records.first(where: { $0.id == id })?.exportURL == nil { export(id) }; if let url = records.first(where: { $0.id == id })?.exportURL { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    func openLastTranscript() { if let url = lastTranscript { NSWorkspace.shared.open(url) } else { showLibrary?() } }
    @discardableResult private func mutate(_ id: UUID, _ change: (inout SessionRecord) -> Void) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == id }), let store else { return false }
        var next = records[index]; change(&next)
        do { try operations.save(store, next); records[index] = next; return true } catch { statusDetail = "Changes could not be saved"; return false }
    }
    private func setChip(_ state: ChipState, dismissAfter seconds: Double? = nil) {
        dismissTask?.cancel(); chipState = state; chipVisible = state != .hidden
        if let seconds { dismissTask = Task { [weak self] in try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); guard !Task.isCancelled else { return }; self?.chipVisible = false } }
    }
    func hideChip() { chipVisible = false }
    func prepareToQuit() async {
        if activeKind == .dictation, isBusy { cancelDictation() }
        if phase == .starting || phase == .recording { finishRecording() }
        await stopTask?.value; previewTask?.cancel(); processingTask?.cancel()
    }
}
