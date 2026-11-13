import Foundation
import SwiftUI
import AppKit
import Security
import UniformTypeIdentifiers
import TranscribeCore

struct LanguageOption: Identifiable, Hashable {
    let id: String
    let name: String
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
            CaptureSession(start: { throw ProviderError.unavailable }, stop: { .init(tracks: [], issues: []) })
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
    enum ChipState: Equatable { case hidden, starting, recording, warning, transcribing, inserted, ready, cancelled, failed, silent }
    enum KeyStatus: Equatable { case idle, checking, verified, rejected, savedUnverified }
    enum ServiceAction: Equatable { case settings, billing, retryTranscription }
    struct ServiceNotice { let message: String; let buttonTitle: String; let action: ServiceAction? }

    /// The coordinator owns state; these operations isolate hardware, network and side effects.
    /// Tests supply controlled completions while exercising the same production commands.
    struct CaptureSession {
        struct Output { let tracks: [SessionAudioTrack]; let issues: [TranscriptionIssue] }
        let start: () async throws -> Void
        let stop: () async -> Output
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
        var makeLiveMeeting: ((SessionRecord, URL, OpenAIConfig,
            @escaping LiveMeetingController.Persist,
            @escaping @Sendable (LiveMeetingDraft) -> Void,
            @escaping @Sendable (TranscriptionIssue) -> Void) -> MeetingSession)? = nil
        var recoverMeeting: ((SessionRecord, URL, OpenAIConfig,
            @escaping LiveMeetingController.Persist) async throws -> [MeetingTurn])? = nil
        /// Title and one-paragraph summary for a finished meeting transcript.
        var describeMeeting: ((String, OpenAIConfig) async throws -> MeetingOverview)? = nil
        /// Moves a folder to the macOS Trash and returns where it went. Only `live()` uses
        /// the real Trash; fixtures and tests must supply their own.
        var trash: (URL) throws -> URL = { _ in throw CocoaError(.featureUnsupported) }

        @MainActor static func live() -> Operations {
            let paste = PasteService()
            return Operations(makeCapture: { directory, microphone, micOnly, level, health, preview in
                let capture = CaptureController(outDir: directory, micUniqueID: microphone, micOnly: micOnly)
                capture.onLevel = level; capture.onHealth = health; capture.onPreviewWindow = preview
                return CaptureSession(start: { try await capture.start() }, stop: {
                    let output = await capture.stop()
                    return CaptureSession.Output(tracks: output.tracks, issues: output.issues)
                }, setAudioFrameHandler: { capture.onAudioFrame = $0 })
            }, transcribe: { record, directory, credentials in
                if let audio = record.importedAudio {
                    return try await transcribeImportedAudio(audio, chunkDir: directory,
                        kind: record.kind == .dictation ? .dictation : .inPersonMeeting,
                        languages: record.languages, keywords: record.keywords, config: credentials)
                }
                if record.kind == .dictation, record.importedFrom != nil {
                    return try await transcribeFinal(tracks: record.tracks, kind: .dictation, chunkDir: directory,
                        languages: record.languages, keywords: record.keywords, config: credentials)
                }
                if record.kind == .dictation {
                    return try await transcribeContinuousDictation(tracks: record.tracks,
                        languages: record.languages, keywords: record.keywords, config: credentials)
                }
                let kind: TranscriptionKind = record.meetingMode == .online ? .onlineMeeting : .inPersonMeeting
                return try await transcribeFinal(tracks: record.tracks, kind: kind, chunkDir: directory,
                    languages: record.languages, keywords: record.keywords, config: credentials)
            }, uptime: { ProcessInfo.processInfo.systemUptime }, credentials: { provider in
                guard let token = Keychain.get(for: provider), !token.isEmpty else {
                    throw Keychain.cachedReadStatus(for: provider).map { $0 != errSecItemNotFound && $0 != errSecSuccess } == true
                        ? AppFailure.lockedToken : AppFailure.missingToken
                }
                return OpenAIConfig(baseURL: provider.baseURL, authValue: "Bearer \(token)")
            }, save: { try $0.save($1) }, cleanAudio: { try $0.cleanAudio(for: $1) },
            deliverAtCurrentCaret: { text, canDeliver in
                await paste.deliverAtCurrentCaret(text, canDeliver: canDeliver)
            }, copy: { paste.copy($0) }, makeLiveMeeting: { record, url, credentials, persist, draft, issue in
                let live = LiveMeetingController(realtimeURL: url, config: credentials,
                    sources: record.kind == .dictation || record.meetingMode == .inPerson ? [.mic] : [.mic, .system],
                    languages: record.languages, keywords: record.keywords,
                    onPersist: persist, onDraft: draft, onIssue: issue,
                    finishTimeout: 10,
                    continuousDictation: record.usesContinuousDictation)
                return MeetingSession(start: { await live.start() }, offer: { live.offer($0) },
                    finish: { await live.finish() }, cancel: { await live.cancel() })
            }, recoverMeeting: { record, directory, credentials, persist in
                try await recoverMeetingTurns(tracks: record.tracks, turns: record.meetingTurns, directory: directory,
                    languages: record.languages, keywords: record.keywords,
                    config: credentials, onPersist: persist)
            }, describeMeeting: { transcript, credentials in
                try await generateMeetingOverview(transcript: transcript, config: credentials)
            }, trash: { url in
                var result: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &result)
                guard let moved = result as URL? else { throw CocoaError(.fileNoSuchFile) }
                return moved
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
    private var audioImportTask: Task<Void, Never>?
    /// Admitted audio files waiting their turn, oldest first.
    private var importQueue: [UUID] = []
    private var summaryTasks: [UUID: Task<Void, Never>] = [:]
    struct DeletedRecord: Equatable { let id: UUID; let trashed: URL; let kind: SessionKind }
    /// The last dictation sent to the Trash, while its Undo notice is up.
    @Published private(set) var lastDeleted: DeletedRecord?
    /// A meeting waiting for the delete confirmation.
    @Published var meetingToDelete: UUID?
    private var undoExpiry: Task<Void, Never>?

    @Published var phase: Phase = .idle { didSet { if phase == .done || phase == .error { Task { @MainActor [weak self] in self?.pumpImports() } } } }
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
    @Published var statusDetail = "" { didSet { if statusDetail != Self.deletedNotice, lastDeleted != nil { lastDeleted = nil } } }
    static let deletedNotice = "Dictation deleted"
    @Published var deliveryDetail = ""
    @Published var pasteFeedback: PasteService.Feedback = .saved
    @Published var chipRecordID: UUID?
    enum ShortcutCheck: Equatable { case idle, listening, detected, timedOut }
    @Published private(set) var shortcutCheck: ShortcutCheck = .idle
    @Published var dictationChecked: Bool { didSet { preferences.set(dictationChecked, forKey: "dictationChecked") } }
    @Published var showInDock: Bool { didSet { preferences.set(showInDock, forKey: "showInDock") } }
    @Published var additionalShortcut: AdditionalShortcut {
        didSet {
            preferences.set(additionalShortcut.rawValue, forKey: "additionalShortcut")
            if oldValue != additionalShortcut { cancelShortcutCheck(); dictationChecked = false; shortcutsChanged?() }
        }
    }
    var shortcutsChanged: (() -> Void)?
    var shortcutTestChanged: ((Bool) -> Void)?
    private var shortcutCheckTask: Task<Void, Never>?
    @Published var chipState: ChipState = .hidden
    @Published var chipVisible = false
    @Published private(set) var meetingDrafts: [String: LiveMeetingDraft] = [:]
    /// Live meeting display order. A slot is created when its passage first appears and is
    /// never moved or removed during capture, so nothing jumps above lines already shown.
    struct LiveSlot: Equatable { var draftKey: String?; var turnIdx: Int? }
    @Published private(set) var liveOrder: [LiveSlot] = []
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
    @Published var audioRetentionDays: Int {
        didSet { preferences.set(audioRetentionDays, forKey: "audioRetentionDays"); keepAudio = audioRetentionDays != 0 }
    }

    /// Transcription hints. Without them the live model guesses per passage and short or
    /// noisy ones come back in unrelated languages and scripts.
    @Published var languageIDs: [String] { didSet { preferences.set(languageIDs, forKey: "languageIDs") } }
    /// Empty means all of `languageIDs`; otherwise one of them, kept for the next meeting.
    @Published var meetingLanguage: String { didSet { preferences.set(meetingLanguage, forKey: "meetingLanguage") } }
    @Published var appearance: String { didSet { preferences.set(appearance, forKey: "appearance") } }
    @Published var dictionaryWords: [String] { didSet { preferences.set(dictionaryWords, forKey: "dictionaryWords") } }
    @Published var pasteLastShortcutEnabled: Bool {
        didSet { preferences.set(pasteLastShortcutEnabled, forKey: "pasteLastShortcutEnabled") }
    }
    static let supportedLanguages = [LanguageOption(id: "en", name: "English"), LanguageOption(id: "es", name: "Spanish"),
                                     LanguageOption(id: "pt", name: "Portuguese"), LanguageOption(id: "fr", name: "French"),
                                     LanguageOption(id: "de", name: "German"), LanguageOption(id: "it", name: "Italian")]
    var languages: [LanguageOption] { Self.supportedLanguages }
    /// All Settings languages together, then each alone. Empty with fewer than two.
    var meetingLanguageOptions: [LanguageOption] {
        let chosen = languages.filter { languageIDs.contains($0.id) }
        guard chosen.count > 1 else { return [] }
        let names = chosen.map(\.name)
        let together = names.count == 2 ? names.joined(separator: " & ")
            : names.dropLast().joined(separator: ", ") + " & " + names.last!
        return [LanguageOption(id: "", name: together)] + chosen
    }
    var meetingLanguages: [String] {
        languageIDs.contains(meetingLanguage) ? [meetingLanguage] : languageIDs
    }
    var languageSummary: String {
        let names = languages.filter { languageIDs.contains($0.id) }.map(\.name)
        return names.isEmpty ? "Any" : names.joined(separator: ", ")
    }
    /// A saved list wins; an old single choice carries over; "Automatic" and new installs
    /// start from the Mac's preferred languages.
    static func initialLanguages(_ p: UserDefaults, supported: [String],
                                 preferred: [String] = Locale.preferredLanguages) -> [String] {
        if let saved = p.stringArray(forKey: "languageIDs") { return saved.filter(supported.contains) }
        if let old = p.string(forKey: "languageID"), supported.contains(old) { return [old] }
        let mac = Set(preferred.map { String($0.prefix { $0 != "-" && $0 != "_" }).lowercased() })
        return supported.filter(mac.contains)
    }
    func toggleLanguage(_ id: String) {
        languageIDs = languageIDs.contains(id) ? languageIDs.filter { $0 != id } : languages.map(\.id).filter { $0 == id || languageIDs.contains($0) }
    }
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
    private var audioRetentionTimer: Timer?
    private var startedUptime = 0.0
    private var dictationStopUptime: Double?
    private var timeSinceDictationStop: Double? { dictationStopUptime.map { max(0, operations.uptime() - $0) } }
    private var startupTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var liveController: MeetingSession?
    private var liveStartupTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var liveGeneration = UUID()
    private var liveCredentials: OpenAIConfig?
    private var stoppingForQuit = false
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
    func dictationDisplayText(for record: SessionRecord) -> String {
        guard record.id == activeSessionID, record.usesContinuousDictation,
              [.starting, .recording, .stopping, .transcribing].contains(phase) else {
            return record.hasText ? record.transcript : record.preview
        }
        let draft = meetingDrafts.values.filter { $0.source == .mic }
            .sorted { $0.itemID < $1.itemID }.map(\.text).joined(separator: " ")
        return [record.transcript, draft].filter { !$0.isEmpty }.joined(separator: " ")
    }
    var lastRecordWithText: SessionRecord? { records.first { $0.kind == .dictation && $0.hasText } }
    var isBusy: Bool { updateInProgress || liveController != nil || liveTask != nil || liveStartupTask != nil || [.starting, .recording, .stopping, .transcribing].contains(phase) }
    /// All work that must finish naturally before an update can acquire the main-actor latch.
    var updateBlockingWork: Bool {
        [.starting, .recording, .stopping, .transcribing].contains(phase) ||
            importInProgress || summaryTaskCount > 0 || manualPasteTask != nil ||
            keyStatus == .checking || pendingDialogCount > 0 || liveController != nil || liveTask != nil || liveStartupTask != nil
    }
    var canBeginUpdate: Bool { !updateInProgress && !updateBlockingWork }
    func acquireUpdateLock() -> Bool {
        guard canBeginUpdate, commitPendingEdits() else { return false }
        cancelShortcutCheck()
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
            if let title { $0.title = title; $0.titleIsAutomatic = false }
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
    var failedChipShowsSettings: Bool {
        guard let record = activeRecord else { return true }
        return !record.hasText && !record.tracks.contains { !$0.spans.isEmpty }
    }
    var failedChipLabel: String {
        if activeRecord?.canRecover == true { return "Retry needed" }
        if activeRecord?.hasText == true { return "Text saved" }
        return failedChipShowsSettings ? "No audio captured" : "Recording saved"
    }
    /// Changes whenever the chip's content can change size, so its panel is refitted.
    var chipLayout: String {
        "\(chipState)|\(activeKind)|\(pasteFeedback)|\(readyChipLabel)|\(failedChipLabel)|\(failedChipShowsSettings)|\(activeRecord?.canRecover == true)"
    }
    var filteredRecords: [SessionRecord] {
        let kind: SessionKind = sidebar == .meetings ? .meeting : .dictation
        return records.filter { r in r.kind == kind && (searchText.isEmpty || [r.title, r.overview, r.transcript].contains { $0.localizedCaseInsensitiveContains(searchText) }) }
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
        showInDock = p.object(forKey: "showInDock") as? Bool ?? true
        dictationChecked = p.bool(forKey: "dictationChecked")
        additionalShortcut = p.string(forKey: "additionalShortcut").flatMap(AdditionalShortcut.init(rawValue:)) ?? .controlOptionSpace
        pasteLastShortcutEnabled = p.object(forKey: "pasteLastShortcutEnabled") as? Bool ?? true
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        saveFolder = URL(fileURLWithPath: p.string(forKey: "saveFolderPath") ?? docs.appendingPathComponent("Transcribe").path)
        let retention = p.object(forKey: "audioRetentionDays") as? Int ?? (p.bool(forKey: "keepAudio") ? -1 : 7)
        audioRetentionDays = retention; keepAudio = retention != 0
        languageIDs = Self.initialLanguages(p, supported: Self.supportedLanguages.map(\.id))
        meetingLanguage = p.string(forKey: "meetingLanguage") ?? ""
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
            // Cleanup uses completion-relative expiry and never removes failed/cancelled audio.
            if initializeSystemState, audioRetentionDays > 0 { try s.purgeExpiredAudio(records: records, days: audioRetentionDays); forgetDeletedImports() }
        } catch { statusDetail = "History storage unavailable" }
        if initializeSystemState {
            refreshMics(); Task { await refreshPermissions() }
            audioRetentionTimer = Timer.scheduledTimer(withTimeInterval: 3_600, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.isBusy, self.audioRetentionDays > 0 else { return }
                    try? self.store?.purgeExpiredAudio(records: self.records, days: self.audioRetentionDays); self.forgetDeletedImports()
                }
            }
        }
    }
    func selectRecord(_ id: UUID) { selectedRecordID = id }
    func acceptConsent() { guard !updateInProgress else { return }; consentAccepted = true; preferences.set(true, forKey: "consentAccepted") }
    func refreshMics() { mics = MicCapture.available(); if let id = selectedMicID, !mics.contains(where: { $0.uniqueID == id }) { selectedMicID = nil } }
    func refreshPermissions() async {
        micGranted = Permissions.micAuthorized(); accessibilityGranted = Permissions.accessibilityAuthorized()
        if !accessibilityGranted { cancelShortcutCheck() }
        retryShortcuts?()
        screenGranted = CGPreflightScreenCaptureAccess(); hasKey = credentialAccess.get(connectionProvider) != nil
        tokenAccessRequired = credentialAccess.needsAccess(connectionProvider)
    }
    func grantMic() {
        guard !updateInProgress else { return }
        pendingDialogCount += 1
        Task {
            defer { pendingDialogCount -= 1 }
            if !(await Permissions.requestMic()) { Permissions.openMicSettings() }
            await refreshPermissions(); refreshMics()
        }
    }
    /// Set once Allow was pressed: macOS applies Screen & System Audio Recording only
    /// after the app reopens, so the next step is Reopen.
    @Published private(set) var screenRequested = false
    func reopenForPermissions() { guard !isBusy, !updateInProgress else { return }; Permissions.relaunch() }
    func grantScreen() {
        guard !updateInProgress else { return }
        screenRequested = true
        pendingDialogCount += 1
        Permissions.requestScreen()
        Task { defer { pendingDialogCount -= 1 }; await refreshPermissions() }
    }
    func grantAccessibility() { guard !updateInProgress else { return }; Permissions.requestAccessibility(); Task { await refreshPermissions() } }
    func grantShortcuts() {
        guard !updateInProgress else { return }
        if !Permissions.accessibilityAuthorized() { grantAccessibility(); Permissions.openAccessibilitySettings() }
        retryShortcuts?()
    }

    func beginShortcutCheck() {
        guard !isBusy, !updateInProgress else { return }
        cancelShortcutCheck()
        guard accessibilityGranted, shortcutAvailable else { grantShortcuts(); return }
        shortcutCheck = .listening
        shortcutTestChanged?(true)
        shortcutCheckTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            self?.finishShortcutCheck(detected: false)
        }
    }

    func finishShortcutCheck(detected: Bool) {
        guard shortcutCheck == .listening else { return }
        shortcutCheckTask?.cancel(); shortcutCheckTask = nil
        shortcutCheck = detected ? .detected : .timedOut
        shortcutTestChanged?(false)
    }

    func cancelShortcutCheck() {
        shortcutCheckTask?.cancel(); shortcutCheckTask = nil
        if shortcutCheck == .listening { shortcutCheck = .idle }
        shortcutTestChanged?(false)
    }

    var readyChipLabel: String {
        switch pasteFeedback {
        case .permission: return "Enable Accessibility"
        case .field: return "Select a text field"
        case .unconfirmed: return "Check paste"
        case .saved: return "Ready"
        }
    }

    var chipTranscriptRecord: SessionRecord? {
        guard let id = chipRecordID else { return lastRecordWithText }
        return records.first { $0.id == id && $0.hasText }
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
                    .union(self.deletedExports)
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
        cancelShortcutCheck()
        let title = kind == .dictation ? "Dictation" : meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        var newRecord = SessionRecord(kind: kind, meetingMode: meetingMode, title: title.isEmpty ? "Meeting" : title, languages: kind == .meeting ? meetingLanguages : languageIDs, keywords: dictionaryWords)
        newRecord.titleIsAutomatic = kind == .meeting && title.isEmpty
        if kind == .meeting, operations.makeLiveMeeting != nil { newRecord.liveMeetingVersion = 1; newRecord.serviceProviderID = connectionProvider.rawValue }
        if kind == .dictation {
            if operations.makeLiveMeeting != nil { newRecord.liveDictationVersion = 4 }
            newRecord.dictationPerformance = .init(mode: .live)
            newRecord.serviceProviderID = connectionProvider.rawValue
        }
        let r = newRecord
        do { try operations.save(store, r) } catch { statusDetail = "Recording could not be saved"; phase = .error; return }
        records.insert(r, at: 0); activeSessionID = r.id; activeKind = kind; phase = .starting
        chipRecordID = r.id; pasteFeedback = .saved
        automaticDeliveryID = kind == .dictation ? r.id : nil
        elapsed = 0; startedUptime = operations.uptime(); dictationStopUptime = nil; micLevel = 0; systemLevel = 0
        sourceIssue = ""; statusDetail = ""; deliveryDetail = ""; micHealth = nil; systemHealth = nil; previewDisabled = false; captureStatusSaveFailed = false; setChip(.starting)
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
        if r.usesLiveTranscription {
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
                self.setChip(.recording)
                guard self.mutate(r.id, { $0.status = .recording }) else {
                    self.captureStatusSaveFailed = true; self.automaticDeliveryID = nil
                    self.finishRecording(); return
                }
                self.startTimer(id: r.id)
            } catch {
                guard let self, self.activeSessionID == r.id else { return }
                let message = (error as? MicrophoneCaptureError)?.message
                    ?? (self.sourceIssue.isEmpty ? "Recording could not start. Check your microphone." : self.sourceIssue)
                self.sourceIssue = message
                _ = self.mutate(r.id) { $0.captureIncomplete = true; if !$0.issues.contains(message) { $0.issues.append(message) } }
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
            if h.source == .mic && (phase == .starting || phase == .recording) { finishRecording() }
        }
    }
    func finishRecording() {
        guard phase == .starting || phase == .recording, let id = activeSessionID, let ctl = controller else { return }
        if activeKind == .dictation { dictationStopUptime = operations.uptime() }
        phase = .stopping; timer?.invalidate(); timer = nil; setChip(activeRecord?.delivery == .cancelled ? .cancelled : .transcribing)
        let startup = startupTask
        stopTask = Task { [weak self] in
            await startup?.value; let result = await ctl.stop(); guard let self, self.activeSessionID == id else { return }
            self.previewTask?.cancel(); await self.previewTask?.value; self.previewTask = nil
            if let w = self.pendingPreview { try? FileManager.default.removeItem(at: w.url) }; self.pendingPreview = nil
            let hasAudio = result.tracks.contains { $0.spans.contains { $0.duration > 0 } }
            let saved = self.mutate(id) {
                $0.duration = max(0, self.operations.uptime() - self.startedUptime); $0.tracks = result.tracks
                if !result.issues.isEmpty { $0.captureIncomplete = true; for i in result.issues where !$0.issues.contains(i.userMessage) { $0.issues.append(i.userMessage) } }
                $0.status = self.cancelledIDs.contains(id) || $0.delivery == .cancelled ? .cancelled
                    : self.captureStatusSaveFailed || !hasAudio ? .failed : .processing
                if !hasAudio {
                    $0.captureIncomplete = true
                    $0.issues.append("No audio was captured. Check your microphone before trying again.")
                    if $0.delivery == .eligible { $0.delivery = .ready }
                }
                if self.captureStatusSaveFailed {
                    $0.issues.append("Recording status could not be saved")
                    if $0.delivery == .eligible { $0.delivery = .ready }
                }
            }
            self.controller = nil; self.startupTask = nil
            guard saved else { await self.closeLiveWithoutRecovery(); self.phase = .error; self.setChip(.failed); return }
            guard !self.captureStatusSaveFailed else { await self.closeLiveWithoutRecovery(); self.phase = .error; self.setChip(.failed); return }
            guard hasAudio else {
                await self.closeLiveWithoutRecovery(); self.automaticDeliveryID = nil
                let cancelled = self.activeRecord?.delivery == .cancelled
                self.phase = cancelled ? .done : .error
                self.setChip(cancelled ? .cancelled : .failed)
                return
            }
            if self.activeRecord?.liveDictationVersion != nil { self.processLiveDictation(id: id, drain: true); return }
            if self.activeRecord?.liveMeetingVersion != nil { self.processLiveMeeting(id: id, drain: true); return }
            if self.cancelledIDs.contains(id) || self.activeRecord?.delivery == .cancelled { self.phase = .done; self.setChip(.cancelled, dismissAfter: 12) } else { self.process(id: id) }
        }
    }
    func cancelDictation() {
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
                model.placeConfirmedPassages(next)
            }
        }
    }
    private func configureLiveMeeting(_ record: SessionRecord, capture: CaptureSession) -> Bool {
        guard let make = operations.makeLiveMeeting, !updateInProgress else { return false }
        do {
            let credentials = try config(), generation = UUID()
            liveGeneration = generation; liveCredentials = credentials; stoppingForQuit = false; meetingDrafts = [:]; liveOrder = []
            let session = make(record, connectionProvider.realtimeURL, credentials,
                livePersistence(id: record.id, generation: generation), { [weak self] draft in Task { @MainActor in
                    guard let self, self.liveController != nil, self.liveGeneration == generation, self.activeSessionID == record.id else { return }
                    self.placeDraft(draft)
                    if draft.text.isEmpty { self.meetingDrafts.removeValue(forKey: draft.id) }
                    else { self.meetingDrafts[draft.id] = draft }
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
    private func placeDraft(_ draft: LiveMeetingDraft) {
        if let i = liveOrder.firstIndex(where: { $0.draftKey == draft.id }) {
            if let turn = draft.turnIdx { liveOrder[i].turnIdx = turn }
        } else if let turn = draft.turnIdx, let i = liveOrder.firstIndex(where: { $0.turnIdx == turn }) {
            liveOrder[i].draftKey = draft.id
        } else if !draft.text.isEmpty {
            liveOrder.append(LiveSlot(draftKey: draft.id, turnIdx: draft.turnIdx))
        }
    }
    fileprivate func placeConfirmedPassages(_ record: SessionRecord) {
        guard record.kind == .meeting else { return }
        let placed = Set(liveOrder.compactMap(\.turnIdx))
        for segment in record.segments where !placed.contains(segment.idx) {
            liveOrder.append(LiveSlot(draftKey: nil, turnIdx: segment.idx))
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
                self.describeMeeting(id, credentials: credentials)
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
    /// Complete the live transcript. Recovery replays saved audio through the same model.
    private func processLiveDictation(id: UUID, drain: Bool) {
        guard !updateInProgress, liveTask == nil, let store,
              records.first(where: { $0.id == id })?.liveDictationVersion != nil else { return }
        let generation = liveGeneration, session = liveController
        phase = .transcribing
        if activeRecord?.delivery != .cancelled { setChip(.transcribing) }
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
                    if self.stoppingForQuit || self.cancelledIDs.contains(id) { _ = await session.cancel() }
                    else { _ = await session.finish() }
                }
                guard self.liveGeneration == generation, self.activeSessionID == id else { return }
                self.liveController = nil; self.meetingDrafts = [:]
                if self.stoppingForQuit || self.cancelledIDs.contains(id) || Task.isCancelled { throw CancellationError() }
                let credentials = drain ? try self.liveCredentials ?? self.config() : try self.config()
                if !drain {
                    guard self.mutate(id, { $0.status = .processing; $0.serviceProviderID = self.connectionProvider.rawValue }) else { throw ProviderError.cacheWrite }
                }
                guard let record = self.records.first(where: { $0.id == id }) else { return }
                if !record.hasSealedMeetingAudio {
                    guard self.mutate(id, { $0.dictationPerformance?.usedRecovery = true }) else { throw ProviderError.cacheWrite }
                    let result = try await self.operations.transcribe(record,
                        store.directory(for: id).appendingPathComponent("chunks/dictation-fallback"), credentials)
                    try Task.checkCancellation()
                    guard self.liveGeneration == generation, self.activeSessionID == id,
                          !self.cancelledIDs.contains(id), self.activeRecord?.delivery != .cancelled else { throw CancellationError() }
                    guard self.mutate(id, {
                        // Preserve original turns for diagnosis; recovery is one full live replay.
                        $0.liveDictationVersion = nil
                        $0.transcript = result.text; $0.rawTranscript = result.text; $0.segments = result.segments
                        $0.status = result.complete && !$0.captureIncomplete ? .complete : .partial
                        $0.transcriptionIssues = result.issues
                        $0.issues = ($0.captureIncomplete ? $0.issues : []) + result.issues.map(\.userMessage)
                    }) else { throw ProviderError.cacheWrite }
                }
                try Task.checkCancellation()
                guard self.liveGeneration == generation, self.activeSessionID == id,
                      !self.cancelledIDs.contains(id), self.activeRecord?.delivery != .cancelled else { throw CancellationError() }
                guard self.mutate(id, {
                    if $0.liveDictationVersion != nil {
                        $0.status = $0.hasSealedMeetingAudio && !$0.captureIncomplete ? .complete : .partial
                        $0.transcriptionIssues = $0.liveMeetingIssues
                    }
                    $0.rawTranscript = $0.transcript
                    $0.formattingFailure = nil
                    if $0.delivery == .eligible { $0.delivery = .ready }
                    if let elapsed = self.timeSinceDictationStop { $0.dictationPerformance?.stopToTranscript = elapsed }
                }) else { throw ProviderError.cacheWrite }
                guard try await self.finishDictation(id: id) else { return }
                self.automaticDeliveryID = nil
                if !self.keepAudio, !self.cancelledIDs.contains(id), let final = self.records.first(where: { $0.id == id }) {
                    do { try self.operations.cleanAudio(store, final) }
                    catch { self.statusDetail = "Transcript saved; audio retained" }
                }
                self.phase = .done
            } catch {
                guard self.liveGeneration == generation, self.activeSessionID == id else { return }
                let cancelled = self.cancelledIDs.contains(id) || self.activeRecord?.delivery == .cancelled || self.stoppingForQuit
                self.automaticDeliveryID = nil
                _ = self.mutate(id) {
                    $0.status = cancelled ? .cancelled : .partial
                    if cancelled { $0.delivery = .cancelled }
                    else if $0.delivery == .eligible { $0.delivery = .ready }
                    $0.transcriptionIssues = $0.liveMeetingIssues
                    if !cancelled && $0.transcriptionIssues.isEmpty {
                        $0.transcriptionIssues = [.init(userMessage: "Dictation could not finish. Audio is saved.", failureKind: self.failureKind(for: error))]
                    }
                }
                self.phase = cancelled ? .done : .error
                self.setChip(cancelled ? .cancelled : .failed, dismissAfter: 12)
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
                    if $0.importedAudio != nil, $0.kind == .meeting { $0.duration = result.segments.map(\.end).max() ?? $0.duration }
                    if $0.kind == .dictation { $0.rawTranscript = result.text }
                    if let elapsed = self.timeSinceDictationStop { $0.dictationPerformance?.stopToTranscript = elapsed }
                    $0.formattingFailure = nil
                    $0.transcriptionIssues = result.issues
                    $0.issues = ($0.captureIncomplete ? $0.issues : []) + result.issues.map(\.userMessage)
                    $0.status = result.complete && !$0.captureIncomplete ? .complete : .partial
                    if self.cancelledIDs.contains(id) || $0.delivery == .cancelled { $0.status = .cancelled; $0.delivery = .cancelled }
                    else if $0.delivery == .eligible { $0.delivery = .ready }
                }) else { self.phase = .error; self.setChip(.failed); return }
                let current = self.records.first { $0.id == id }!
                if current.kind == .dictation, current.importedFrom == nil {
                    guard try await self.finishDictation(id: id) else { return }
                } else if current.kind == .dictation {
                    self.chipVisible = false
                } else {
                    self.export(id); self.chipVisible = false
                    self.describeMeeting(id, credentials: credentials)
                }
                self.automaticDeliveryID = nil
                if !self.keepAudio, !self.cancelledIDs.contains(id), let final = self.records.first(where: { $0.id == id }) { do { try self.operations.cleanAudio(store, final); self.forgetDeletedImports() } catch { self.statusDetail = "Transcript saved; audio retained" } }
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
    /// Deliver only the durable completed transcript. No post-processing request.
    private func finishDictation(id: UUID) async throws -> Bool {
        guard let current = records.first(where: { $0.id == id }) else { return false }
        if cancelledIDs.contains(id) || current.delivery == .cancelled { setChip(.cancelled, dismissAfter: 12) }
        else if !current.hasText { setChip(current.status == .complete ? .silent : .failed, dismissAfter: 8) }
        else {
            if let stopToReady = timeSinceDictationStop {
                guard mutate(id, { $0.dictationPerformance?.stopToReady = stopToReady }) else {
                    phase = .error; setChip(.failed); return false
                }
            }
            if canAutomaticallyDeliver(id: id, text: current.transcript) {
                let outcome = await operations.deliverAtCurrentCaret(current.transcript, { [weak self] in
                    self?.canAutomaticallyDeliver(id: id, text: current.transcript) == true
                })
                guard activeSessionID == id else { return false }
                if cancelledIDs.contains(id) || activeRecord?.delivery == .cancelled { setChip(.cancelled, dismissAfter: 12) }
                else {
                    switch outcome {
                    case .inserted: pasteFeedback = .saved; deliveryDetail = ""; _ = mutate(id) { $0.delivery = .inserted }; setChip(.inserted, dismissAfter: 2)
                    case .ready(let reason, let feedback):
                        pasteFeedback = feedback
                        noteDeliveryIssue(reason, for: id); setChip(.ready, dismissAfter: 12)
                    case .unconfirmed(let reason):
                        pasteFeedback = .unconfirmed
                        noteDeliveryIssue(reason, for: id); setChip(.ready, dismissAfter: 12)
                    }
                }
            } else { setChip(.ready, dismissAfter: 12) }
        }
        return true
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
                    let text = try await transcribePreview(window: next, languages: r?.languages ?? [], keywords: r?.keywords ?? [], config: self.config())
                    guard !Task.isCancelled else { break }; _ = self.mutate(id) { $0.preview += ($0.preview.isEmpty ? "" : "\n") + text }
                } catch { self.previewDisabled = true }
            }
            self.previewTask = nil
        }
    }
    func retry(_ id: UUID) {
        guard !isBusy, manualPasteTask == nil, let r = records.first(where: { $0.id == id }) else { return }
        let needsService = r.canRecover && !(r.hasText && r.status == .cancelled && r.issues.isEmpty && !r.usesLiveTranscription)
        if needsService, !ensureCredentials(for: id) { return }
        cancelledIDs.remove(id)
        cancelShortcutCheck()
        automaticDeliveryID = nil; activeSessionID = id; activeKind = r.kind
        chipRecordID = id; pasteFeedback = .saved; deliveryDetail = ""
        dictationStopUptime = nil
        if r.liveDictationVersion != nil {
            guard r.canRecover, mutate(id, { $0.delivery = .ready }) else { return }
            liveGeneration = UUID(); stoppingForQuit = false
            processLiveDictation(id: id, drain: false); return
        }
        if r.liveMeetingVersion != nil {
            guard r.canRecover else { return }
            liveGeneration = UUID(); stoppingForQuit = false
            processLiveMeeting(id: id, drain: false); return
        }
        if r.hasText && r.status == .cancelled && r.issues.isEmpty { _ = mutate(id) { $0.status = .complete; $0.delivery = .ready }; phase = .done; setChip(.ready, dismissAfter: 12); return }
        guard r.canRecover, mutate(id, { $0.delivery = $0.kind == .dictation && $0.importedFrom == nil ? .ready : .never }) else { return }; process(id: id)
    }
    func recover(_ id: UUID) { retry(id) }
    /// Each file becomes an in-person meeting or a dictation at once; transcription waits its turn.
    func importAudioFiles(_ urls: [URL], as kind: SessionKind = .meeting) {
        guard !updateInProgress, let store else { return }
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        let previous = audioImportTask
        importInProgress = true
        audioImportTask = Task { [weak self] in
            await previous?.value
            var selected = false
            for url in files {
                guard let self, !Task.isCancelled, !self.updateInProgress else { break }
                do {
                    let record = try await store.importAudioFile(url, kind: kind,
                        languages: kind == .meeting ? self.meetingLanguages : self.languageIDs,
                        keywords: kind == .dictation ? self.dictionaryWords : [])
                    self.records.insert(record, at: 0); self.importQueue.append(record.id)
                    if !selected {
                        self.sidebar = kind == .meeting ? .meetings : .dictation
                        if kind == .meeting { self.selectedRecordID = record.id }
                        selected = true
                    }
                    self.pumpImports()
                } catch {
                    self.statusDetail = "Can’t import “\(url.lastPathComponent)”."
                }
            }
            self?.importInProgress = false
        }
    }
    /// Cleanup deletes a dropped Ogg copy and clears the field on disk; memory must agree,
    /// or a later save would write the dead URL back.
    private func forgetDeletedImports() {
        for i in records.indices {
            if let url = records[i].importedAudio, !FileManager.default.fileExists(atPath: url.path) { records[i].importedAudio = nil }
        }
    }
    private func pumpImports() {
        guard !isBusy, manualPasteTask == nil, !importQueue.isEmpty else { return }
        let id = importQueue.removeFirst()
        guard records.first(where: { $0.id == id })?.status == .processing else { return pumpImports() }
        guard ensureCredentials(for: id) else {
            _ = mutate(id) { $0.status = .failed }
            return pumpImports()
        }
        cancelledIDs.remove(id); cancelShortcutCheck()
        automaticDeliveryID = nil; activeSessionID = id; activeKind = .meeting // a file is never inserted; the chip only offers Hide
        chipRecordID = id; pasteFeedback = .saved; deliveryDetail = ""; dictationStopUptime = nil
        process(id: id)
    }
    func recoverCancelled() { if let id = activeSessionID { retry(id) } }
    func serviceNotice(for record: SessionRecord) -> ServiceNotice? {
        let failures = record.transcriptionIssues.compactMap(\.failureKind)
        let asrFailure = failures.first { $0.allowsRecoveryAfterRemedy || $0 == .invalidHints } ?? failures.first
        guard let failure = asrFailure else { return nil }
        let provider = record.serviceProviderID.flatMap(ConnectionProvider.init(rawValue:))
        let retryAction: ServiceAction = .retryTranscription
        let retryTitle = "Retry"
        switch failure {
        case .credentialMissing:
            return ServiceNotice(message: "Add your " + (provider == .openAI ? "OpenAI API key" : provider == .team ? "team token" : "credential") + " in Settings.", buttonTitle: "Settings", action: .settings)
        case .credentialLocked:
            return ServiceNotice(message: "Unlock your " + (provider == .openAI ? "OpenAI API key" : provider == .team ? "team token" : "credential") + " in Settings.", buttonTitle: "Unlock", action: .settings)
        case .configuration:
            return ServiceNotice(message: "The transcription service could not accept this request.", buttonTitle: "Settings", action: .settings)
        case .invalidCredential:
            return ServiceNotice(message: (provider == .team ? "Your team token was rejected." : provider == .openAI ? "Your API key was rejected." : "Your credential was rejected."), buttonTitle: "Check Settings", action: .settings)
        case .accessDenied:
            return ServiceNotice(message: "Your account cannot access this service.", buttonTitle: "Check access", action: .settings)
        case .insufficientCredits, .billingLimit:
            if provider == .openAI {
                return ServiceNotice(message: (failure == .insufficientCredits ? "Your API credits are exhausted." : "An account or project limit was reached."), buttonTitle: failure == .insufficientCredits ? "Add credits" : "Check billing", action: .billing)
            }
            return ServiceNotice(message: (provider == .team ? "Your team service needs billing attention. Contact your administrator." : "The service account needs billing attention."), buttonTitle: "Settings", action: .settings)
        case .rateLimited:
            return ServiceNotice(message: "Too many requests. Try again shortly.", buttonTitle: "Retry", action: retryAction)
        case .invalidHints:
            return ServiceNotice(message: record.usesLiveTranscription
                ? "The transcription service could not accept this request."
                : "Review your language and dictionary settings.", buttonTitle: "Settings", action: .settings)
        case .tooLarge:
            return ServiceNotice(message: "This recording could not be uploaded. Your audio is saved.", buttonTitle: "", action: nil)
        case .unavailable, .invalidResponse, .storage, .timedOut, .truncated:
            return ServiceNotice(message: "Transcription could not finish. Your recording is saved.", buttonTitle: retryTitle, action: retryAction)
        }
    }
    func performServiceAction(_ action: ServiceAction, for id: UUID) {
        guard !isBusy, manualPasteTask == nil, keyStatus != .checking, let record = records.first(where: { $0.id == id }) else { return }
        switch action {
        case .retryTranscription: retry(id)
        case .settings:
            if let provider = record.serviceProviderID.flatMap(ConnectionProvider.init(rawValue:)) { setConnectionProvider(provider) }
            showSettings?()
        case .billing:
            guard record.serviceProviderID == ConnectionProvider.openAI.rawValue else { showSettings?(); return }
            NSWorkspace.shared.open(URL(string: "https://platform.openai.com/settings/organization/billing/overview")!)
        }
    }
    /// Runs on its own after the transcript is saved, so dictation and the next file
    /// never wait for it. A failure leaves the record as it was, with nothing shown.
    private func describeMeeting(_ id: UUID, credentials: OpenAIConfig) {
        guard let describe = operations.describeMeeting, !updateInProgress, summaryTasks[id] == nil,
              let r = records.first(where: { $0.id == id }), r.kind == .meeting, r.hasText else { return }
        let text = r.copyableTranscript
        summaryTaskCount += 1
        summaryTasks[id] = Task { [weak self] in
            let result = try? await describe(text, credentials)
            guard let self else { return }
            defer { self.summaryTasks[id] = nil; self.summaryTaskCount -= 1 }
            guard let result, !Task.isCancelled, !self.updateInProgress,
                  let current = self.records.first(where: { $0.id == id }), current.copyableTranscript == text else { return }
            let applyTitle = current.titleIsAutomatic && self.pendingTitles[id] == nil && !result.title.isEmpty
            guard self.mutate(id, {
                $0.overview = wordCount(text) < 100 ? "" : result.summary
                if applyTitle { $0.title = result.title }
            }) else { return }
            self.export(id)
        }
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
        return operations.copy(record.kind == .meeting ? record.copyableTranscript : record.transcript)
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
            self.chipRecordID = r.id
            switch outcome {
            case .inserted: self.pasteFeedback = .saved; self.deliveryDetail = ""; self.setChip(.inserted, dismissAfter: 2)
            case .ready(let reason, let feedback):
                self.pasteFeedback = feedback
                self.noteDeliveryIssue(reason, for: r.id)
                self.setChip(.ready, dismissAfter: 8)
            case .unconfirmed(let reason):
                self.pasteFeedback = .unconfirmed
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
    private func exportText(_ r: SessionRecord) -> String {
        var text = "# \(r.title)\n\n"; if !r.overview.isEmpty { text += "\(r.overview)\n\n" }; if r.isPartial { text += "Partial recording\n\n" }
        if !r.notes.isEmpty { text += "## My notes\n\n\(r.notes)\n\n" }; if !r.summary.isEmpty { text += "## Notes\n\n\(r.summary)\n\n" }
        return text + "## Transcript\n\n\(r.transcript)\n"
    }
    func export(_ id: UUID) {
        guard !updateInProgress else { return }
        guard let r = records.first(where: { $0.id == id }), r.hasText || !r.notes.isEmpty || !r.summary.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
            let url = !r.imported ? r.exportURL ?? saveFolder.appendingPathComponent("\(r.startedAt.formatted(.iso8601).replacingOccurrences(of: ":", with: "-"))-\(id.uuidString.prefix(8)).md") : saveFolder.appendingPathComponent("\(id.uuidString.prefix(8)).md")
            try exportText(r).write(to: url, atomically: true, encoding: .utf8)
            _ = mutate(id) { $0.exportURL = url }; lastTranscript = url
        } catch { statusDetail = "Export unavailable" }
    }
    /// A copy wherever the user chooses; the automatic export stays where it is.
    func exportAs(_ id: UUID) {
        guard !updateInProgress, let r = records.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = r.title.replacingOccurrences(of: "/", with: "-") + ".md"
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        pendingDialogCount += 1; defer { pendingDialogCount -= 1 }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try exportText(r).write(to: url, atomically: true, encoding: .utf8) } catch { statusDetail = "Export unavailable" }
    }
    func reveal(_ id: UUID) { if records.first(where: { $0.id == id })?.exportURL == nil { export(id) }; if let url = records.first(where: { $0.id == id })?.exportURL { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    func openLastTranscript() { if let url = lastTranscript { NSWorkspace.shared.open(url) } else { showLibrary?() } }
    /// Not while it is being recorded, transcribed or waiting to be, nor during an update.
    func canDelete(_ id: UUID) -> Bool {
        guard !updateInProgress, let r = records.first(where: { $0.id == id }) else { return false }
        if id == activeSessionID && [.starting, .recording, .stopping, .transcribing].contains(phase) { return false }
        return !importQueue.contains(id) && r.status != .processing && r.status != .recording && r.status != .starting
    }
    /// Moves the record's folder to the Trash. Dictations get an Undo notice; meetings
    /// were confirmed in a dialog. Exports in the Meeting exports folder stay.
    func delete(_ id: UUID) {
        guard canDelete(id), let store, let record = records.first(where: { $0.id == id }) else { return }
        let visible = filteredRecords.map(\.id)
        let trashed: URL
        do { trashed = try store.moveToTrash(id, using: operations.trash) }
        catch { statusDetail = "Couldn’t move to the Trash."; return }
        summaryTasks[id]?.cancel()
        pendingTitles[id] = nil; pendingNotes[id] = nil; pendingSummary[id] = nil
        records.removeAll { $0.id == id }
        if activeSessionID == id { activeSessionID = nil }
        if chipRecordID == id { chipRecordID = nil; chipVisible = false }
        if automaticDeliveryID == id { automaticDeliveryID = nil }
        if record.exportURL != nil, lastTranscript == record.exportURL { lastTranscript = nil }
        if record.kind == .meeting, let path = record.exportURL?.standardizedFileURL.path {
            preferences.set(deletedExports + [path], forKey: "deletedExports")
        }
        if selectedRecordID == id {
            if record.kind == .meeting, let index = visible.firstIndex(of: id) {
                let rest = visible.filter { $0 != id }
                selectedRecordID = rest.isEmpty ? nil : rest[min(index, rest.count - 1)]
            } else { selectedRecordID = nil }
        }
        undoExpiry?.cancel()
        if record.kind == .dictation {
            lastDeleted = DeletedRecord(id: id, trashed: trashed, kind: record.kind)
            statusDetail = Self.deletedNotice
            undoExpiry = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled, let self, self.lastDeleted?.id == id else { return }
                self.lastDeleted = nil
                if self.statusDetail == Self.deletedNotice { self.statusDetail = "" }
            }
        } else { lastDeleted = nil }
    }
    /// Exports of deleted meetings stay on disk; Import Recordings skips them.
    var deletedExports: [String] { preferences.stringArray(forKey: "deletedExports") ?? [] }
    func undoDelete() {
        guard let deleted = lastDeleted, let store else { return }
        undoExpiry?.cancel(); lastDeleted = nil
        do {
            let record = try store.restore(from: deleted.trashed, id: deleted.id)
            let index = records.firstIndex { $0.startedAt < record.startedAt } ?? records.endIndex
            records.insert(record, at: index)
            if record.kind == .meeting, let path = record.exportURL?.standardizedFileURL.path {
                preferences.set(deletedExports.filter { $0 != path }, forKey: "deletedExports")
            }
            statusDetail = ""
        } catch { statusDetail = "Couldn’t restore from the Trash." }
    }
    @discardableResult private func mutate(_ id: UUID, _ change: (inout SessionRecord) -> Void) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == id }), let store else { return false }
        var next = records[index]; change(&next)
        if next.status == .complete, next.hasText, next.audioCompletedAt == nil { next.audioCompletedAt = Date() }
        do { try operations.save(store, next); records[index] = next; return true } catch { statusDetail = "Changes could not be saved"; return false }
    }
    private func setChip(_ state: ChipState, dismissAfter seconds: Double? = nil) {
        dismissTask?.cancel(); chipState = state; chipVisible = state != .hidden
        if let seconds { dismissTask = Task { [weak self] in try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); guard !Task.isCancelled else { return }; self?.chipVisible = false } }
    }
    func hideChip() { chipVisible = false }
    func prepareToQuit() async {
        stoppingForQuit = true
        audioRetentionTimer?.invalidate(); audioRetentionTimer = nil
        importTask?.cancel(); await importTask?.value
        audioImportTask?.cancel(); await audioImportTask?.value; importQueue = []
        let summaries = Array(summaryTasks.values)
        for task in summaries { task.cancel() }
        for task in summaries { await task.value }
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
