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
    enum ServiceAction: Equatable { case settings, billing, retryTranscription, retryFormatting }
    struct ServiceNotice { let message: String; let buttonTitle: String; let action: ServiceAction? }

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
        var credentials: (ConnectionProvider) throws -> OpenAIConfig
        var save: (SessionStore, SessionRecord) throws -> Void
        var cleanAudio: (SessionStore, SessionRecord) throws -> Void
        var deliverAtCurrentCaret: (String, @escaping @MainActor () -> Bool) async -> PasteService.Outcome
        var copy: (String) -> Bool
        var automaticTimer = true
        var format: ((String, OpenAIConfig) async throws -> DictationFormatResult)? = nil

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
            }, uptime: { ProcessInfo.processInfo.systemUptime }, credentials: { provider in
                guard let token = Keychain.get(for: provider), !token.isEmpty else { throw AppFailure.missingToken }
                return OpenAIConfig(baseURL: provider.baseURL, authValue: "Bearer \(token)")
            }, save: { try $0.save($1) }, cleanAudio: { try $0.cleanAudio(for: $1) },
            deliverAtCurrentCaret: { text, canDeliver in
                await paste.deliverAtCurrentCaret(text, canDeliver: canDeliver)
            }, copy: { paste.copy($0) }, format: { raw, credentials in
                try await formatDictation(raw, config: credentials)
            })
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
    @Published var deliveryDetail = ""
    @Published var chipState: ChipState = .hidden
    @Published var chipVisible = false
    @Published private(set) var formattingRecordID: UUID?
    @Published var shortcutAvailable = false
    @Published var lastTranscript: URL?
    @Published var mics: [MicDevice] = []
    @Published var selectedMicID: String? { didSet { preferences.set(selectedMicID, forKey: "selectedMicID") } }
    @Published var micGranted = false
    @Published var screenGranted = false
    @Published var accessibilityGranted = false
    @Published var hasKey = false
    @Published var tokenAccessRequired = false
    @Published var keyStatus: KeyStatus = .idle
    @Published private(set) var connectionProvider: ConnectionProvider
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
    private let credentialAccess: CredentialAccess
    private let verificationSession: URLSession
    private var providerStatuses: [ConnectionProvider: KeyStatus] = [:]
    private var verificationGeneration = UUID()
    private var store: SessionStore?
    private var controller: CaptureSession?
    private var timer: Timer?
    private var startedUptime = 0.0
    private var startupTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var formattingTask: Task<Void, Never>?
    private var formattingGeneration = UUID()
    private var previewTask: Task<Void, Never>?
    private var pendingPreview: PreviewWindow?
    private var previewDisabled = false
    private var captureStatusSaveFailed = false
    private var automaticDeliveryID: UUID?
    private var manualPasteTask: Task<Void, Never>?
    private var cancelledIDs: Set<UUID> = []
    private var dismissTask: Task<Void, Never>?
    var selectedRecord: SessionRecord? { records.first { $0.id == selectedRecordID } }
    var activeRecord: SessionRecord? { records.first { $0.id == activeSessionID } }
    var lastRecordWithText: SessionRecord? { records.first { $0.kind == .dictation && $0.hasText } }
    var isBusy: Bool { formattingRecordID != nil || [.starting, .recording, .stopping, .transcribing].contains(phase) }
    var ready: Bool { micGranted && hasKey && consentAccepted && keyStatus != .checking && keyStatus != .rejected }
    var needsSetup: Bool { !ready }
    var micOnly: Bool { get { meetingMode == .inPerson } set { meetingMode = newValue ? .inPerson : .online } }
    var keyFingerprint: String? { credentialAccess.fingerprint(connectionProvider) }
    var canChangeConnectionProvider: Bool { !isBusy && manualPasteTask == nil && keyStatus != .checking }
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
         preferences: UserDefaults = .standard, initializeSystemState: Bool = true,
         credentialAccess suppliedCredentialAccess: CredentialAccess? = nil, verificationSession: URLSession = .shared) {
        self.preferences = preferences
        operations = suppliedOperations ?? .live()
        let access = suppliedCredentialAccess ?? CredentialAccess.live
        credentialAccess = access
        self.verificationSession = verificationSession
        let p = preferences
        let inspectCredentials = initializeSystemState || suppliedCredentialAccess != nil
        if let selected = p.string(forKey: "connectionProvider").flatMap(ConnectionProvider.init(rawValue:)) {
            connectionProvider = selected
        } else {
            let legacyUser = p.bool(forKey: "consentAccepted") || (inspectCredentials && access.legacyConfigured())
            let resolved: ConnectionProvider = legacyUser ? .team : .openAI
            connectionProvider = resolved
            p.set(resolved.rawValue, forKey: "connectionProvider")
        }
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
        if inspectCredentials {
            hasKey = credentialAccess.get(connectionProvider) != nil
            tokenAccessRequired = credentialAccess.needsAccess(connectionProvider)
        }
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
        screenGranted = CGPreflightScreenCaptureAccess(); hasKey = credentialAccess.get(connectionProvider) != nil
        tokenAccessRequired = credentialAccess.needsAccess(connectionProvider)
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
    func setConnectionProvider(_ provider: ConnectionProvider) {
        guard canChangeConnectionProvider, provider != connectionProvider else { return }
        providerStatuses[connectionProvider] = keyStatus
        verificationGeneration = UUID()
        connectionProvider = provider
        preferences.set(provider.rawValue, forKey: "connectionProvider")
        hasKey = credentialAccess.get(provider) != nil
        tokenAccessRequired = credentialAccess.needsAccess(provider)
        keyStatus = providerStatuses[provider] ?? .idle
        statusDetail = ""
    }
    func saveKey(_ key: String) { Task { _ = await saveAndVerifyKey(key) } }
    func unlockToken() {
        guard canChangeConnectionProvider else { return }
        hasKey = credentialAccess.unlock(connectionProvider) != nil
        tokenAccessRequired = credentialAccess.needsAccess(connectionProvider)
        if hasKey {
            if keyStatus == .idle || keyStatus == .savedUnverified { keyStatus = .savedUnverified }
            statusDetail = ""
        } else {
            if keyStatus == .idle || keyStatus == .savedUnverified { keyStatus = .idle }
            statusDetail = tokenAccessRequired ? "Credential access required" : "Add your " + connectionProvider.credentialLabel.lowercased()
        }
    }
    func saveAndVerifyKey(_ key: String) async -> Bool {
        guard canChangeConnectionProvider else { return false }
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        let provider = connectionProvider, generation = UUID()
        verificationGeneration = generation
        do { try credentialAccess.set(value, provider); hasKey = true; tokenAccessRequired = false }
        catch { statusDetail = "Credential could not be saved"; return false }
        keyStatus = .checking; statusDetail = ""
        let request = provider.verificationRequest(credential: value)
        let status: KeyStatus
        do {
            let (_, response) = try await verificationSession.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode
            if provider == .openAI {
                status = code == 200 ? .verified : code == 401 ? .rejected : .savedUnverified
            } else {
                status = code == 401 ? .rejected : code == 403 || code.map({ (200..<300).contains($0) }) == true ? .verified : .savedUnverified
            }
        } catch { status = .savedUnverified }
        guard connectionProvider == provider, verificationGeneration == generation else { return false }
        keyStatus = status; providerStatuses[provider] = status
        return status != .rejected
    }
    func openMeetings() { sidebar = .meetings; selectedRecordID = nil; searchText = ""; meetingSetupPresented = true; showLibrary?() }
    func toggleRecord() { toggleDictation() }
    func toggleDictation() { if activeKind == .dictation && (phase == .starting || phase == .recording) { finishRecording() } else if !isBusy { startDictation() } }
    func startDictation() { start(kind: .dictation) }
    func startMeeting() { start(kind: .meeting) }
    private func start(kind: SessionKind) {
        guard !isBusy, manualPasteTask == nil else { return }
        guard ready, let store else { statusDetail = "Finish setup"; showSettings?(); return }
        guard kind != .meeting || meetingMode != .online || screenGranted else { statusDetail = "Allow Mac audio"; showSettings?(); return }
        let title = kind == .dictation ? "Dictation" : meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = SessionRecord(kind: kind, meetingMode: meetingMode, title: title.isEmpty ? "Meeting" : title, language: languages.first { $0.id == languageID }?.code, keywords: dictionaryWords)
        do { try operations.save(store, r) } catch { statusDetail = "Recording could not be saved"; phase = .error; return }
        records.insert(r, at: 0); activeSessionID = r.id; activeKind = kind; phase = .starting
        automaticDeliveryID = kind == .dictation ? r.id : nil
        elapsed = 0; startedUptime = operations.uptime(); micLevel = 0; systemLevel = 0
        sourceIssue = ""; statusDetail = ""; deliveryDetail = ""; micHealth = nil; systemHealth = nil; previewDisabled = false; captureStatusSaveFailed = false; setChip(.recording)
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
                    self.captureStatusSaveFailed = true; self.automaticDeliveryID = nil
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
        if formattingRecordID != nil { cancelFormattingRetry(); return }
        guard activeKind == .dictation, let id = activeSessionID, isBusy else { if activeKind == .meeting { chipVisible = false }; return }
        cancelledIDs.insert(id)
        _ = mutate(id) { $0.delivery = .cancelled; $0.status = .cancelled }; automaticDeliveryID = nil; setChip(.cancelled)
        if phase == .starting || phase == .recording { finishRecording() }
    }
    private enum AppFailure: Error { case missingToken }
    private func config() throws -> OpenAIConfig { try operations.credentials(connectionProvider) }
    private func process(id: UUID) {
        guard let r = records.first(where: { $0.id == id }), let store else { return }
        let provider = connectionProvider
        guard mutate(id, { $0.status = .processing; $0.serviceProviderID = provider.rawValue }) else { phase = .error; setChip(.failed); return }
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
                    if $0.kind == .dictation { $0.rawTranscript = result.text }
                    $0.formattingFailure = nil
                    $0.transcriptionIssues = result.issues
                    $0.issues = ($0.captureIncomplete ? $0.issues : []) + result.issues.map(\.userMessage)
                    $0.status = result.complete && !$0.captureIncomplete ? .complete : .partial
                    if self.cancelledIDs.contains(id) || $0.delivery == .cancelled { $0.status = .cancelled; $0.delivery = .cancelled }
                    else if $0.delivery == .eligible { $0.delivery = .ready }
                }) else { self.phase = .error; self.setChip(.failed); return }
                if let raw = self.records.first(where: { $0.id == id }), raw.kind == .dictation,
                   raw.status == .complete, raw.hasText, raw.delivery != .cancelled,
                   !self.cancelledIDs.contains(id), !Task.isCancelled, let format = self.operations.format {
                    let formatted = try await format(raw.transcript, credentials)
                    guard self.activeSessionID == id else { return }
                    if !Task.isCancelled, !self.cancelledIDs.contains(id), self.activeRecord?.delivery != .cancelled,
                       formatted.text != raw.transcript || formatted.failure != raw.formattingFailure {
                        guard self.mutate(id, { $0.transcript = formatted.text; $0.formattingFailure = formatted.failure }) else {
                            self.phase = .error; self.setChip(.failed); return
                        }
                    }
                }
                let current = self.records.first { $0.id == id }!
                if current.kind == .dictation {
                    if self.cancelledIDs.contains(id) || current.delivery == .cancelled { self.setChip(.cancelled, dismissAfter: 12) }
                    else if !current.hasText { self.setChip(result.complete ? .silent : .failed, dismissAfter: 8) }
                    else if self.canAutomaticallyDeliver(id: id, text: current.transcript) {
                        // Native delivery resolves focus now, after final text is durable.
                        // Its final guard runs immediately before clipboard/event writes.
                        let outcome = await self.operations.deliverAtCurrentCaret(current.transcript, { [weak self] in
                            self?.canAutomaticallyDeliver(id: id, text: current.transcript) == true
                        })
                        guard self.activeSessionID == id else { return }
                        if self.cancelledIDs.contains(id) || self.activeRecord?.delivery == .cancelled {
                            self.setChip(.cancelled, dismissAfter: 12)
                        } else {
                            switch outcome {
                            case .inserted: _ = self.mutate(id) { $0.delivery = .inserted }; self.setChip(.inserted, dismissAfter: 2)
                            case .ready(let reason), .unconfirmed(let reason):
                                self.noteDeliveryIssue(reason, for: id)
                                self.setChip(.ready, dismissAfter: 12)
                            }
                        }
                    } else { self.setChip(.ready, dismissAfter: 12) }
                } else {
                    self.export(id); self.chipVisible = false
                    if self.includeSummary && current.hasText { await self.generateNotes(for: id, credentials: credentials) }
                }
                self.automaticDeliveryID = nil
                if !self.keepAudio, !self.cancelledIDs.contains(id), let final = self.records.first(where: { $0.id == id }) { do { try self.operations.cleanAudio(store, final) } catch { self.statusDetail = "Transcript saved; audio retained" } }
                self.phase = .done
            } catch {
                if self.cancelledIDs.contains(id) || self.activeRecord?.delivery == .cancelled {
                    self.automaticDeliveryID = nil; self.phase = .done
                    self.setChip(.cancelled, dismissAfter: 12); return
                }
                let failure = (error as? ProviderError)?.failureKind ?? (error is AppFailure ? .invalidCredential : .unavailable)
                _ = self.mutate(id) {
                    $0.status = $0.delivery == .cancelled ? .cancelled : .failed
                    $0.transcriptionIssues = [TranscriptionIssue(userMessage: "Transcription could not finish.", failureKind: failure)]
                    $0.issues.append("Transcription could not finish.")
                    if $0.delivery == .eligible { $0.delivery = .ready }
                }
                self.phase = .error
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
        guard !isBusy, manualPasteTask == nil, let r = records.first(where: { $0.id == id }) else { return }
        cancelledIDs.remove(id)
        automaticDeliveryID = nil; activeSessionID = id; activeKind = r.kind
        if r.hasText && r.status == .cancelled && r.issues.isEmpty { _ = mutate(id) { $0.status = .complete; $0.delivery = .ready }; phase = .done; setChip(.ready, dismissAfter: 12); return }
        guard r.canRecover, mutate(id, { $0.delivery = $0.kind == .dictation ? .ready : .never }) else { return }; process(id: id)
    }
    func recover(_ id: UUID) { retry(id) }
    func recoverCancelled() { if let id = activeSessionID { retry(id) } }
    func canRetryFormatting(_ record: SessionRecord) -> Bool {
        !isBusy && manualPasteTask == nil && keyStatus != .checking && record.kind == .dictation &&
            record.status == .complete && record.formattingFailure != nil &&
            !(record.rawTranscript ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && operations.format != nil
    }
    /// A historical text-only retry. It never touches capture, ASR, insertion or audio cleanup.
    func retryFormatting(_ id: UUID) {
        guard let record = records.first(where: { $0.id == id }), canRetryFormatting(record),
              let raw = record.rawTranscript, let format = operations.format else { return }
        let provider = connectionProvider
        let generation = UUID(); formattingGeneration = generation; formattingRecordID = id
        formattingTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.formattingGeneration == generation { self.formattingRecordID = nil; self.formattingTask = nil }
            }
            do {
                let credentials = try self.operations.credentials(provider)
                let result = try await format(raw, credentials)
                guard !Task.isCancelled, self.formattingGeneration == generation, self.formattingRecordID == id,
                      let current = self.records.first(where: { $0.id == id }),
                      current.rawTranscript == record.rawTranscript, current.transcript == record.transcript,
                      current.status == record.status else { return }
                _ = self.mutate(id) {
                    $0.transcript = result.text; $0.formattingFailure = result.failure; $0.serviceProviderID = provider.rawValue
                }
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), self.formattingGeneration == generation,
                      self.formattingRecordID == id, let current = self.records.first(where: { $0.id == id }),
                      current.rawTranscript == record.rawTranscript, current.transcript == record.transcript else { return }
                _ = self.mutate(id) {
                    $0.formattingFailure = (error as? ProviderError)?.failureKind ?? (error is AppFailure ? .invalidCredential : .unavailable)
                    $0.serviceProviderID = provider.rawValue
                }
            }
        }
    }
    func cancelFormattingRetry() { formattingTask?.cancel() }
    func serviceNotice(for record: SessionRecord) -> ServiceNotice? {
        let failures = record.transcriptionIssues.compactMap(\.failureKind)
        let asrFailure = failures.first { $0.allowsRecoveryAfterRemedy || $0 == .invalidHints } ?? failures.first
        guard let failure = asrFailure ?? record.formattingFailure else { return nil }
        let formatting = asrFailure == nil
        let prefix = formatting ? "Text saved. " : ""
        let provider = record.serviceProviderID.flatMap(ConnectionProvider.init(rawValue:))
        let retryAction: ServiceAction = formatting ? .retryFormatting : .retryTranscription
        let retryTitle = "Retry"
        switch failure {
        case .invalidCredential:
            return ServiceNotice(message: prefix + (provider == .team ? "Your team token was rejected." : provider == .openAI ? "Your API key was rejected." : "Your credential was rejected."), buttonTitle: "Check Settings", action: .settings)
        case .accessDenied:
            return ServiceNotice(message: prefix + "Your account cannot access this service.", buttonTitle: "Check access", action: .settings)
        case .insufficientCredits, .billingLimit:
            if provider == .openAI {
                return ServiceNotice(message: prefix + (failure == .insufficientCredits ? "Your API credits are exhausted." : "An account or project limit was reached."), buttonTitle: failure == .insufficientCredits ? "Add credits" : "Check billing", action: .billing)
            }
            return ServiceNotice(message: prefix + (provider == .team ? "Your team service needs billing attention. Contact your administrator." : "The service account needs billing attention."), buttonTitle: "Settings", action: .settings)
        case .rateLimited:
            return ServiceNotice(message: prefix + "Too many requests. Try again shortly.", buttonTitle: "Retry", action: retryAction)
        case .invalidHints:
            return ServiceNotice(message: "Review your language and dictionary settings.", buttonTitle: "Settings", action: .settings)
        case .tooLarge:
            return ServiceNotice(message: "This recording could not be uploaded. Your audio is saved.", buttonTitle: "", action: nil)
        case .unavailable, .invalidResponse, .storage:
            return ServiceNotice(message: formatting ? "Text saved. Formatting could not finish." : "Transcription could not finish. Your recording is saved.", buttonTitle: retryTitle, action: retryAction)
        }
    }
    func performServiceAction(_ action: ServiceAction, for id: UUID) {
        guard !isBusy, manualPasteTask == nil, keyStatus != .checking, let record = records.first(where: { $0.id == id }) else { return }
        switch action {
        case .retryTranscription: retry(id)
        case .retryFormatting: retryFormatting(id)
        case .settings:
            if let provider = record.serviceProviderID.flatMap(ConnectionProvider.init(rawValue:)) { setConnectionProvider(provider) }
            showSettings?()
        case .billing:
            guard record.serviceProviderID == ConnectionProvider.openAI.rawValue else { showSettings?(); return }
            NSWorkspace.shared.open(URL(string: "https://platform.openai.com/settings/organization/billing/overview")!)
        }
    }
    func regenerateNotes(_ id: UUID) { guard let r = records.first(where: { $0.id == id }), r.kind == .meeting, r.hasText else { return }; Task { do { await generateNotes(for: id, credentials: try config()) } catch { statusDetail = "Add your " + self.connectionProvider.credentialLabel.lowercased() } } }
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
    @discardableResult func copyTranscript(_ id: UUID) -> Bool {
        guard let record = records.first(where: { $0.id == id }), record.hasText else { return false }
        return operations.copy(record.transcript)
    }
    private func canAutomaticallyDeliver(id: UUID, text: String) -> Bool {
        guard !Task.isCancelled, phase == .transcribing, activeSessionID == id,
              activeKind == .dictation, automaticDeliveryID == id,
              !cancelledIDs.contains(id), let record = records.first(where: { $0.id == id }) else { return false }
        return record.status == .complete && record.delivery == .ready && record.transcript == text && record.hasText
    }
    func pasteLast() {
        guard !isBusy, manualPasteTask == nil, let r = lastRecordWithText else { return }
        manualPasteTask = Task { [weak self] in
            guard let self else { return }
            defer { self.manualPasteTask = nil }
            let outcome = await self.operations.deliverAtCurrentCaret(r.transcript, { [weak self] in
                guard let self, !Task.isCancelled, !self.isBusy else { return false }
                return self.lastRecordWithText?.id == r.id && self.lastRecordWithText?.transcript == r.transcript
            })
            // A new recording owns the chip; a late manual result must not replace it.
            guard !Task.isCancelled, !self.isBusy, self.lastRecordWithText?.id == r.id else { return }
            switch outcome {
            case .inserted: self.deliveryDetail = ""; self.setChip(.inserted, dismissAfter: 2)
            case .ready(let reason):
                self.noteDeliveryIssue(reason, for: r.id)
                self.setChip(.ready, dismissAfter: 8)
            case .unconfirmed(let reason):
                // A dispatched paste may still complete. Never copy or retry it automatically.
                self.noteDeliveryIssue(reason, for: r.id)
                self.setChip(.ready, dismissAfter: 12)
            }
        }
    }
    private func noteDeliveryIssue(_ reason: String, for id: UUID) {
        let detail = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detail.isEmpty else { return }
        deliveryDetail = detail
        guard let record = records.first(where: { $0.id == id }),
              record.status != .cancelled, record.delivery != .cancelled,
              !record.issues.contains(detail) else { return }
        // Keep delivery diagnostics separate from transcription retry eligibility.
        _ = mutate(id) { $0.issues.append(detail) }
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
        formattingTask?.cancel(); await formattingTask?.value
        if activeKind == .dictation, isBusy { cancelDictation() }
        if phase == .starting || phase == .recording { finishRecording() }
        await stopTask?.value; previewTask?.cancel(); processingTask?.cancel()
        manualPasteTask?.cancel(); await manualPasteTask?.value
    }
}
