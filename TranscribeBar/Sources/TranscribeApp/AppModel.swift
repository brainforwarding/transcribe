import Foundation
import SwiftUI
import AppKit
import Security
import TranscribeCore

struct LanguageOption: Identifiable, Hashable {
    let id: String
    let name: String
    var code: String? { id == "auto" ? nil : id }
}

enum UpdatePresentation: Equatable {
    case hidden, available, checking, downloading, installing, retry
    var title: String {
        switch self {
        case .hidden, .available: return "Actualizar"
        case .checking, .downloading: return "Descargando"
        case .installing: return "Instalando"
        case .retry: return "Reintentar"
        }
    }
    var running: Bool { self == .checking || self == .downloading || self == .installing }
}

@MainActor
final class AppModel: ObservableObject {
#if TRANSCRIBE_VALIDATION_FIXTURE
    static func makeUpdateValidationModel() throws -> AppModel {
        guard let identifier = Bundle.main.bundleIdentifier,
              identifier.hasPrefix("com.sebastianmarambio.transcribe.updatefixture."),
              let path = Bundle.main.infoDictionary?["TranscribeValidationRoot"] as? String,
              path.hasPrefix("/"), let preferences = UserDefaults(suiteName: identifier + ".validation")
        else { throw ProviderError.invalidResponse }
        let root = URL(fileURLWithPath: path).standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        guard root.resolvingSymlinksInPath().path.hasPrefix(temporary),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0 == 0o700,
              attributes[.ownerAccountName] as? String == NSUserName()
        else { throw ProviderError.invalidResponse }
        let store = try SessionStore(root: root.appendingPathComponent("Sessions", isDirectory: true))
        if try store.load().isEmpty {
            var record = SessionRecord(kind: .meeting, title: "Update validation")
            record.status = .complete; record.transcript = "Local validation fixture."
            try store.save(record)
        }
        preferences.set(root.appendingPathComponent("Exports", isDirectory: true).path, forKey: "saveFolderPath")
        let access = CredentialAccess(get: { _ in nil }, unlock: { _ in nil }, set: { _, _ in throw ProviderError.unavailable },
            status: { _ in nil }, fingerprint: { _ in nil }, legacyConfigured: { false })
        let operations = Operations(makeCapture: { _, _, _, _, _, _ in
            CaptureSession(start: { throw ProviderError.unavailable }, stop: { .init(tracks: [], issues: []) },
                           retrySystemAudio: { throw ProviderError.unavailable })
        }, transcribe: { _, _, _ in throw ProviderError.unavailable }, uptime: { ProcessInfo.processInfo.systemUptime },
            credentials: { _ in throw ProviderError.authentication }, save: { try $0.save($1) },
            cleanAudio: { _, _ in throw ProviderError.unavailable },
            deliverAtCurrentCaret: { _, _ in .ready(reason: "Disabled in validation fixture") }, copy: { _ in false },
            automaticTimer: false)
        let model = AppModel(store: store, operations: operations, preferences: preferences,
                             initializeSystemState: false, credentialAccess: access)
        model.sidebar = .meetings; model.selectedRecordID = model.records.first?.id
        return model
    }
#endif
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
        var setAudioFrameHandler: ((@Sendable (CapturedAudioFrame) -> Void)?) -> Void = { _ in }
    }
    struct MeetingSession: Sendable {
        let start: @Sendable () async -> Void
        let offer: @Sendable (CapturedAudioFrame) -> Void
        let finish: @Sendable () async -> [MeetingTurn]
        let cancel: @Sendable () async -> [MeetingTurn]
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
        var makeLiveMeeting: ((SessionRecord, URL, OpenAIConfig,
            @escaping LiveMeetingController.Persist,
            @escaping @Sendable (LiveMeetingDraft) -> Void,
            @escaping @Sendable (TranscriptionIssue) -> Void) -> MeetingSession)? = nil
        var recoverMeeting: ((SessionRecord, URL, OpenAIConfig,
            @escaping LiveMeetingController.Persist) async throws -> [MeetingTurn])? = nil

        @MainActor static func live() -> Operations {
            let paste = PasteService()
            return Operations(makeCapture: { directory, microphone, micOnly, level, health, preview in
                let capture = CaptureController(outDir: directory, micUniqueID: microphone, micOnly: micOnly)
                capture.onLevel = level; capture.onHealth = health; capture.onPreviewWindow = preview
                return CaptureSession(start: { try await capture.start() }, stop: {
                    let output = await capture.stop()
                    return CaptureSession.Output(tracks: output.tracks, issues: output.issues)
                }, retrySystemAudio: { try await capture.retrySystemAudio() }, setAudioFrameHandler: { capture.onAudioFrame = $0 })
            }, transcribe: { record, directory, credentials in
                let kind: TranscriptionKind = record.kind == .dictation ? .dictation
                    : record.meetingMode == .online ? .onlineMeeting : .inPersonMeeting
                return try await transcribeFinal(tracks: record.tracks, kind: kind, chunkDir: directory,
                    languages: record.language.map { [$0] } ?? [], keywords: record.keywords, config: credentials)
            }, uptime: { ProcessInfo.processInfo.systemUptime }, credentials: { provider in
                guard let token = Keychain.get(for: provider), !token.isEmpty else {
                    throw Keychain.cachedReadStatus(for: provider).map { $0 != errSecItemNotFound && $0 != errSecSuccess } == true
                        ? AppFailure.lockedToken : AppFailure.missingToken
                }
                return OpenAIConfig(baseURL: provider.baseURL, authValue: "Bearer \(token)")
            }, save: { try $0.save($1) }, cleanAudio: { try $0.cleanAudio(for: $1) },
            deliverAtCurrentCaret: { text, canDeliver in
                await paste.deliverAtCurrentCaret(text, canDeliver: canDeliver)
            }, copy: { paste.copy($0) }, format: { raw, credentials in
                try await formatDictation(raw, config: credentials)
            }, makeLiveMeeting: { record, url, credentials, persist, draft, issue in
                let live = LiveMeetingController(realtimeURL: url, config: credentials,
                    sources: record.meetingMode == .online ? [.mic, .system] : [.mic],
                    languages: record.language.map { [$0] } ?? [], keywords: record.keywords,
                    onPersist: persist, onDraft: draft, onIssue: issue)
                return MeetingSession(start: { await live.start() }, offer: { live.offer($0) },
                    finish: { await live.finish() }, cancel: { await live.cancel() })
            }, recoverMeeting: { record, directory, credentials, persist in
                try await recoverMeetingTurns(tracks: record.tracks, turns: record.meetingTurns, directory: directory,
                    languages: record.language.map { [$0] } ?? [], keywords: record.keywords,
                    config: credentials, onPersist: persist)
            })
        }
    }
    @Published private(set) var updateInProgress = false
    @Published var updatePresentation: UpdatePresentation = .hidden
    @Published var updateProgress: Double?
    @Published var updaterReady = false
    @Published private(set) var importInProgress = false
    @Published private(set) var summaryTaskCount = 0
    @Published private(set) var pendingDialogCount = 0
    var requestUpdate: (() -> Void)?
    private var pendingTitles: [UUID: String] = [:]
    private var pendingNotes: [UUID: String] = [:]
    private var pendingSummary: [UUID: String] = [:]
    private var importTask: Task<Void, Never>?
    private var summaryTasks: [UUID: Task<Void, Never>] = [:]

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
    @Published private(set) var meetingDrafts: [String: LiveMeetingDraft] = [:]
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
    private var liveController: MeetingSession?
    private var liveStartupTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var liveGeneration = UUID()
    private var liveCredentials: OpenAIConfig?
    private var stoppingForQuit = false
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
    var isBusy: Bool { updateInProgress || formattingRecordID != nil || liveController != nil || liveTask != nil || liveStartupTask != nil || [.starting, .recording, .stopping, .transcribing].contains(phase) }
    /// All work that must finish naturally before an update can acquire the main-actor latch.
    var updateBlockingWork: Bool {
        formattingRecordID != nil || [.starting, .recording, .stopping, .transcribing].contains(phase) ||
            importInProgress || summaryTaskCount > 0 || manualPasteTask != nil ||
            keyStatus == .checking || pendingDialogCount > 0 || liveController != nil || liveTask != nil || liveStartupTask != nil
    }
    var canBeginUpdate: Bool { !updateInProgress && !updateBlockingWork }
    func acquireUpdateLock() -> Bool {
        guard canBeginUpdate, commitPendingEdits() else { return false }
        updateInProgress = true
        return true
    }
    func updateSafePoint() -> Bool {
        updateInProgress && !updateBlockingWork && commitPendingEdits()
    }
    func releaseUpdateLock() { updateInProgress = false }
    func stageTitle(_ id: UUID, _ title: String) {
        guard !updateInProgress, let record = records.first(where: { $0.id == id }) else { return }
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value == record.title { pendingTitles[id] = nil }
        else { pendingTitles[id] = value }
    }
    @discardableResult func commitPendingEdits() -> Bool {
        for id in Set(pendingTitles.keys).union(pendingNotes.keys).union(pendingSummary.keys) {
            guard commitEdits(for: id) else { return false }
        }
        return true
    }
    private func commitEdits(for id: UUID) -> Bool {
        let title = pendingTitles[id], notes = pendingNotes[id], summary = pendingSummary[id]
        guard mutate(id, {
            if let title { $0.title = title }
            if let notes { $0.notes = notes }
            if let summary {
                $0.summary = summary; $0.summaryEvidenceIDs = []; $0.summaryEvidence = []
                $0.summaryTranscriptRevision = $0.transcriptRevision
            }
        }) else { return false }
        if pendingTitles[id] == title { pendingTitles[id] = nil }
        if pendingNotes[id] == notes { pendingNotes[id] = nil }
        if pendingSummary[id] == summary { pendingSummary[id] = nil }
        return true
    }
    func editableNotes(for id: UUID) -> String { pendingNotes[id] ?? records.first(where: { $0.id == id })?.notes ?? "" }
    func editableSummary(for id: UUID) -> String { pendingSummary[id] ?? records.first(where: { $0.id == id })?.summary ?? "" }
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
    func acceptConsent() { guard !updateInProgress else { return }; consentAccepted = true; preferences.set(true, forKey: "consentAccepted") }
    func refreshMics() { mics = MicCapture.available(); if let id = selectedMicID, !mics.contains(where: { $0.uniqueID == id }) { selectedMicID = nil } }
    func refreshPermissions() async {
        micGranted = Permissions.micAuthorized(); accessibilityGranted = Permissions.accessibilityAuthorized()
        screenGranted = CGPreflightScreenCaptureAccess(); hasKey = credentialAccess.get(connectionProvider) != nil
        tokenAccessRequired = credentialAccess.needsAccess(connectionProvider)
    }
    func grantMic() {
        guard !updateInProgress else { return }
        pendingDialogCount += 1
        Task { defer { pendingDialogCount -= 1 }; _ = await Permissions.requestMic(); await refreshPermissions(); refreshMics() }
    }
    func grantScreen() {
        guard !updateInProgress else { return }
        pendingDialogCount += 1
        Permissions.requestScreen()
        Task { defer { pendingDialogCount -= 1 }; await refreshPermissions() }
    }
    func grantAccessibility() { guard !updateInProgress else { return }; Permissions.requestAccessibility(); Task { await refreshPermissions() } }
    func grantShortcuts() {
        guard !updateInProgress else { return }
        if !Permissions.accessibilityAuthorized() { grantAccessibility() }
        else { Permissions.requestInputMonitoring() }
        retryShortcuts?()
    }
    func chooseFolder() {
        guard !updateInProgress else { return }
        pendingDialogCount += 1
        defer { pendingDialogCount -= 1 }
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false; p.directoryURL = saveFolder
        if p.runModal() == .OK, let url = p.url { saveFolder = url }
    }
    func importLegacyRecordings() {
        guard !updateInProgress, !importInProgress else { return }
        guard let store else { statusDetail = "History storage unavailable"; return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.directoryURL = saveFolder
        panel.prompt = "Import recordings"
        pendingDialogCount += 1
        let response = panel.runModal()
        pendingDialogCount -= 1
        guard !updateInProgress, response == .OK, let folder = panel.url else { return }
        let snapshot = records
        statusDetail = "Importing recordings…"
        importInProgress = true
        importTask = Task { [weak self] in
            guard let self else { return }
            defer { self.importInProgress = false; self.importTask = nil }
            guard !self.updateInProgress else { return }
            do {
                // Discovery never touches the coordinator's store/JSONEncoder on a background thread.
                let discovered = try await Task.detached(priority: .utility) {
                    try SessionStore.discoverMarkdown(from: folder, existing: snapshot)
                }.value
                guard !Task.isCancelled, !self.updateInProgress else { return }
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
            } catch { if !Task.isCancelled { self.statusDetail = "Import unavailable" } }
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
            statusDetail = tokenAccessRequired ? "Unlock your " + connectionProvider.credentialLabel.lowercased() + " in Settings." : "Add your " + connectionProvider.credentialLabel.lowercased() + " in Settings."
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
        guard ensureCredentials() else { return }
        guard ready, let store else { statusDetail = "Finish setup"; showSettings?(); return }
        guard kind != .meeting || meetingMode != .online || screenGranted else { statusDetail = "Allow Mac audio"; showSettings?(); return }
        let title = kind == .dictation ? "Dictation" : meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        var newRecord = SessionRecord(kind: kind, meetingMode: meetingMode, title: title.isEmpty ? "Meeting" : title, language: languages.first { $0.id == languageID }?.code, keywords: dictionaryWords)
        if kind == .meeting, operations.makeLiveMeeting != nil { newRecord.liveMeetingVersion = 1; newRecord.serviceProviderID = connectionProvider.rawValue }
        let r = newRecord
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
            kind == .dictation || meetingMode == .inPerson, level, health, kind == .meeting && r.liveMeetingVersion == nil ? preview : nil)
        controller = ctl
        if r.liveMeetingVersion != nil {
            guard configureLiveMeeting(r, capture: ctl) else {
                controller = nil; phase = .error; setChip(.failed)
                // Capture has not started. No microphone or network side effect occurred.
                return
            }
        }
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
    func retrySystemAudio() { guard !updateInProgress, let controller, phase == .recording else { return }; Task { do { try await controller.retrySystemAudio(); sourceIssue = "" } catch { sourceIssue = "Mac audio unavailable" } } }
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
            guard saved else { await self.closeLiveWithoutRecovery(); self.phase = .error; self.setChip(.failed); return }
            guard !self.captureStatusSaveFailed else { await self.closeLiveWithoutRecovery(); self.phase = .error; self.setChip(.failed); return }
            if self.activeRecord?.liveMeetingVersion != nil { self.processLiveMeeting(id: id, drain: true); return }
            if self.cancelledIDs.contains(id) || self.activeRecord?.delivery == .cancelled { self.phase = .done; self.setChip(.cancelled, dismissAfter: 12) } else { self.process(id: id) }
        }
    }
    func cancelDictation() {
        if formattingRecordID != nil { cancelFormattingRetry(); return }
        guard activeKind == .dictation, let id = activeSessionID,
              [.starting, .recording, .stopping, .transcribing].contains(phase)
        else { if activeKind == .meeting { chipVisible = false }; return }
        cancelledIDs.insert(id)
        _ = mutate(id) { $0.delivery = .cancelled; $0.status = .cancelled }; automaticDeliveryID = nil; setChip(.cancelled)
        if phase == .starting || phase == .recording { finishRecording() }
    }
    private enum AppFailure: Error {
        case missingToken, lockedToken, rejectedToken
        var kind: ServiceFailureKind {
            switch self { case .missingToken: return .credentialMissing; case .lockedToken: return .credentialLocked; case .rejectedToken: return .invalidCredential }
        }
    }
    private func credentialFailure(for provider: ConnectionProvider) -> AppFailure? {
        let credential = credentialAccess.get(provider)
        let available = credential?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let locked = credentialAccess.needsAccess(provider)
        if provider == connectionProvider { hasKey = available; tokenAccessRequired = locked }
        if (provider == connectionProvider ? keyStatus : providerStatuses[provider]) == .rejected { return .rejectedToken }
        if !available { return locked ? .lockedToken : .missingToken }
        return nil
    }
    @discardableResult private func ensureCredentials(for recordID: UUID? = nil) -> Bool {
        guard keyStatus != .checking else { statusDetail = "Checking your " + connectionProvider.credentialLabel.lowercased() + "…"; return false }
        guard let failure = credentialFailure(for: connectionProvider) else { return true }
        var noticeRecord = SessionRecord(kind: .dictation, title: "")
        noticeRecord.serviceProviderID = connectionProvider.rawValue
        noticeRecord.transcriptionIssues = [.init(userMessage: "Credential required.", failureKind: failure.kind)]
        if let recordID {
            _ = mutate(recordID) { record in
                record.serviceProviderID = connectionProvider.rawValue
                record.transcriptionIssues.removeAll { $0.spanID == nil && $0.failureKind?.allowsRecoveryAfterRemedy == true }
                record.transcriptionIssues.append(contentsOf: noticeRecord.transcriptionIssues)
            }
            statusDetail = ""
        } else { statusDetail = serviceNotice(for: noticeRecord)?.message ?? "Check Settings" }
        showSettings?()
        return false
    }
    private func config(for provider: ConnectionProvider? = nil) throws -> OpenAIConfig {
        let selected = provider ?? connectionProvider
        if let failure = credentialFailure(for: selected) { throw failure }
        let config = try operations.credentials(selected)
        guard config.hasKey else { throw AppFailure.missingToken }
        return config
    }
    private func failureKind(for error: Error) -> ServiceFailureKind {
        (error as? AppFailure)?.kind ?? (error as? ProviderError)?.failureKind ?? .unavailable
    }
    private func livePersistence(id: UUID, generation: UUID) -> LiveMeetingController.Persist {
        { [weak self] turns in
            guard let model = self else { throw CancellationError() }
            try await MainActor.run {
                guard !Task.isCancelled, !model.updateInProgress, model.liveGeneration == generation,
                      model.activeSessionID == id, let index = model.records.firstIndex(where: { $0.id == id }),
                      let store = model.store else { throw CancellationError() }
                var next = model.records[index]
                try next.applyMeetingTurns(turns)
                let sourceIssues = next.transcriptionIssues.filter { $0.spanID == nil && $0.failureKind != nil }
                next.transcriptionIssues = sourceIssues + next.liveMeetingIssues
                // The view sees a completed passage only after its entire snapshot
                // and stable evidence identity have been atomically saved.
                try model.operations.save(store, next)
                model.records[index] = next
            }
        }
    }
    private func configureLiveMeeting(_ record: SessionRecord, capture: CaptureSession) -> Bool {
        guard let make = operations.makeLiveMeeting, !updateInProgress else { return false }
        do {
            let credentials = try config(), generation = UUID()
            liveGeneration = generation; liveCredentials = credentials; stoppingForQuit = false; meetingDrafts = [:]
            let session = make(record, connectionProvider.realtimeURL, credentials,
                livePersistence(id: record.id, generation: generation), { [weak self] draft in Task { @MainActor in
                    guard let self, self.liveController != nil, self.liveGeneration == generation, self.activeSessionID == record.id else { return }
                    let key = "\(draft.source.rawValue)-\(draft.itemID)"
                    if draft.text.isEmpty { self.meetingDrafts.removeValue(forKey: key) }
                    else { self.meetingDrafts[key] = draft }
                } }, { [weak self] issue in Task { @MainActor in
                    guard let self, self.liveController != nil, self.liveGeneration == generation, self.activeSessionID == record.id else { return }
                    _ = self.mutate(record.id) { if !$0.transcriptionIssues.contains(issue) { $0.transcriptionIssues.append(issue) } }
                } })
            liveController = session
            capture.setAudioFrameHandler { session.offer($0) }
            liveStartupTask = Task { [weak self] in
                await session.start()
                if self?.liveGeneration == generation { self?.liveStartupTask = nil }
            }
            return true
        } catch {
            _ = mutate(record.id) {
                $0.status = .failed
                $0.transcriptionIssues = [.init(userMessage: "Live transcript could not start.",
                    failureKind: failureKind(for: error))]
            }
            return false
        }
    }
    private func closeLiveWithoutRecovery() async {
        await liveStartupTask?.value
        if let liveController { _ = await liveController.cancel() }
        self.liveController = nil; liveStartupTask = nil; liveCredentials = nil
        liveGeneration = UUID(); meetingDrafts = [:]
    }
    /// Dedicated live finalization. It never enters the legacy full-ASR replacement,
    /// dictation formatter, or automatic-insertion paths.
    private func processLiveMeeting(id: UUID, drain: Bool) {
        guard !updateInProgress, liveTask == nil, let store, let initial = records.first(where: { $0.id == id }),
              initial.liveMeetingVersion != nil else { return }
        let generation = liveGeneration, session = liveController, provider = connectionProvider
        phase = .transcribing; setChip(.transcribing)
        liveTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.liveGeneration == generation {
                    self.liveTask = nil; self.liveController = nil; self.liveStartupTask = nil
                    self.liveCredentials = nil; self.meetingDrafts = [:]; self.liveGeneration = UUID()
                }
            }
            do {
                await self.liveStartupTask?.value
                if drain, let session {
                    if self.stoppingForQuit { _ = await session.cancel() } else { _ = await session.finish() }
                }
                guard self.liveGeneration == generation, self.activeSessionID == id else { return }
                self.liveController = nil; self.meetingDrafts = [:]
                if self.stoppingForQuit || Task.isCancelled { throw CancellationError() }
                let credentials: OpenAIConfig
                if drain, let snapshot = self.liveCredentials { credentials = snapshot } else { credentials = try self.config() }
                if !drain {
                    guard self.mutate(id, { $0.status = .processing; $0.serviceProviderID = provider.rawValue }) else { throw ProviderError.cacheWrite }
                }
                guard let record = self.records.first(where: { $0.id == id }), let recover = self.operations.recoverMeeting else { throw ProviderError.invalidResponse }
                _ = try await recover(record, store.directory(for: id).appendingPathComponent("chunks/live-recovery"),
                                      credentials, self.livePersistence(id: id, generation: generation))
                try Task.checkCancellation()
                guard self.liveGeneration == generation, self.activeSessionID == id else { return }
                guard self.mutate(id, {
                    $0.status = $0.hasSealedMeetingAudio && !$0.captureIncomplete ? .complete : .partial
                    $0.transcriptionIssues = $0.liveMeetingIssues
                }) else { throw ProviderError.cacheWrite }
                self.export(id)
                if self.includeSummary, self.records.first(where: { $0.id == id })?.hasText == true {
                    await self.generateNotes(for: id, credentials: credentials)
                }
                if !self.keepAudio, let final = self.records.first(where: { $0.id == id }), final.hasSealedMeetingAudio {
                    do { try self.operations.cleanAudio(store, final) }
                    catch {
                        // Cleanup is optional. The durable sealed transcript remains
                        // complete; any undeleted audio stays in its owned folder.
                    }
                }
                self.phase = .done; self.chipVisible = false
            } catch is CancellationError {
                guard self.liveGeneration == generation else { return }
                _ = self.mutate(id) {
                    $0.status = .partial
                    $0.transcriptionIssues = $0.transcriptionIssues.filter { $0.spanID == nil && $0.failureKind != nil } + $0.liveMeetingIssues
                }
                self.phase = .done; self.chipVisible = false
            } catch {
                guard self.liveGeneration == generation else { return }
                _ = self.mutate(id) {
                    $0.status = .partial
                    $0.transcriptionIssues = $0.transcriptionIssues.filter { $0.spanID == nil && $0.failureKind != nil } + $0.liveMeetingIssues
                    if $0.transcriptionIssues.isEmpty {
                        $0.transcriptionIssues = [.init(userMessage: "Meeting transcript could not finish. Audio is saved.",
                            failureKind: self.failureKind(for: error))]
                    }
                }
                self.phase = .error; self.setChip(.failed)
            }
        }
    }
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
                let failure = self.failureKind(for: error)
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
        let needsService = r.canRecover && !(r.hasText && r.status == .cancelled && r.issues.isEmpty && r.liveMeetingVersion == nil)
        if needsService, !ensureCredentials(for: id) { return }
        cancelledIDs.remove(id)
        automaticDeliveryID = nil; activeSessionID = id; activeKind = r.kind
        if r.liveMeetingVersion != nil {
            guard r.canRecover else { return }
            liveGeneration = UUID(); stoppingForQuit = false
            processLiveMeeting(id: id, drain: false); return
        }
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
                let credentials = try self.config(for: provider)
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
                    $0.formattingFailure = self.failureKind(for: error)
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
        case .credentialMissing:
            return ServiceNotice(message: prefix + "Add your " + (provider == .openAI ? "OpenAI API key" : provider == .team ? "team token" : "credential") + " in Settings.", buttonTitle: "Settings", action: .settings)
        case .credentialLocked:
            return ServiceNotice(message: prefix + "Unlock your " + (provider == .openAI ? "OpenAI API key" : provider == .team ? "team token" : "credential") + " in Settings.", buttonTitle: "Unlock", action: .settings)
        case .configuration:
            return ServiceNotice(message: prefix + "The transcription service could not accept this request.", buttonTitle: "Settings", action: .settings)
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
            return ServiceNotice(message: record.liveMeetingVersion != nil
                ? "The transcription service could not accept this request."
                : "Review your language and dictionary settings.", buttonTitle: "Settings", action: .settings)
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
    func regenerateNotes(_ id: UUID) {
        guard !updateInProgress, summaryTasks[id] == nil,
              let r = records.first(where: { $0.id == id }), r.kind == .meeting, r.hasText else { return }
        summaryTaskCount += 1
        summaryTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.summaryTasks[id] = nil; self.summaryTaskCount -= 1 }
            guard !self.updateInProgress, !Task.isCancelled else { return }
            do { await self.generateNotes(for: id, credentials: try self.config()) }
            catch { self.statusDetail = "Add your " + self.connectionProvider.credentialLabel.lowercased() }
        }
    }
    private func generateNotes(for id: UUID, credentials: OpenAIConfig) async {
        guard !updateInProgress, commitPendingEdits(), let r = records.first(where: { $0.id == id }), r.summaryStatus != .processing, mutate(id, { $0.summaryStatus = .processing }) else { return }
        do {
            let transcript = FinalTranscription(text: r.transcript, segments: r.segments, complete: !r.isPartial, issues: [])
            let generated = try await TranscribeCore.generateNotes(transcription: transcript, originalNotes: r.notes, config: credentials)
            _ = mutate(id) {
                if $0.summary == r.summary && self.pendingSummary[id] == nil {
                    $0.summary = generated.text; $0.summaryEvidenceIDs = generated.evidence.flatMap(\.turnIDs)
                    $0.summaryEvidence = generated.evidence
                    $0.summaryNotesSnapshot = r.notes
                    $0.summaryTranscriptRevision = r.transcriptRevision
                }
                $0.summaryStatus = .complete
            }; export(id)
        } catch { _ = mutate(id) { $0.summaryStatus = .failed }; statusDetail = "Notes unavailable" }
    }
    @discardableResult func updateTitle(_ id: UUID, _ title: String) -> Bool {
        guard !updateInProgress else { return false }
        stageTitle(id, title)
        guard pendingTitles[id] != nil else { return records.contains { $0.id == id } }
        return commitEdits(for: id)
    }
    func updateNotes(_ id: UUID, _ notes: String) {
        guard !updateInProgress, records.contains(where: { $0.id == id }) else { return }
        objectWillChange.send(); pendingNotes[id] = notes
        _ = commitEdits(for: id)
    }
    func updateSummary(_ id: UUID, _ text: String) {
        guard !updateInProgress, records.contains(where: { $0.id == id }) else { return }
        objectWillChange.send(); pendingSummary[id] = text
        _ = commitEdits(for: id)
    }
    func addDictionaryWord(_ word: String) {
        guard !updateInProgress else { return }
        let v = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard dictionaryWords.count < 100, !v.isEmpty, v.count <= 100, !v.contains(where: { $0.isNewline || $0 == "<" || $0 == ">" }), !dictionaryWords.contains(v) else { return }; dictionaryWords.append(v)
    }
    func removeDictionaryWord(_ word: String) { guard !updateInProgress else { return }; dictionaryWords.removeAll { $0 == word } }
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
        objectWillChange.send()
        manualPasteTask = Task { [weak self] in
            guard let self else { return }
            defer { self.objectWillChange.send(); self.manualPasteTask = nil }
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
        guard !updateInProgress else { return }
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
        stoppingForQuit = true
        importTask?.cancel(); await importTask?.value
        let summaries = Array(summaryTasks.values)
        for task in summaries { task.cancel() }
        for task in summaries { await task.value }
        formattingTask?.cancel(); await formattingTask?.value
        if activeKind == .dictation, [.starting, .recording, .stopping, .transcribing].contains(phase) { cancelDictation() }
        if phase == .starting || phase == .recording { finishRecording() }
        await stopTask?.value; previewTask?.cancel(); processingTask?.cancel()
        liveTask?.cancel()
        if let liveController { _ = await liveController.cancel() }
        await liveStartupTask?.value; await liveTask?.value
        self.liveController = nil; liveStartupTask = nil; meetingDrafts = [:]; liveGeneration = UUID()
        manualPasteTask?.cancel(); await manualPasteTask?.value
    }
}
