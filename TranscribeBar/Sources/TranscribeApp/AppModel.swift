import Foundation
import SwiftUI
import AppKit
import TranscribeCore

struct LanguageOption: Identifiable, Hashable {
    let id: String        // "auto", "en", "es", "pt"
    let name: String
    var code: String? { id == "auto" ? nil : id }
}

@MainActor
final class AppModel: ObservableObject {

    enum Phase: Equatable { case idle, recording, transcribing, done, error }

    @Published var phase: Phase = .idle
    @Published var elapsed: Int = 0
    @Published var statusDetail: String = ""
    @Published var lastTranscript: URL?

    @Published var mics: [MicDevice] = []
    @Published var selectedMicID: String?
    let languages = [LanguageOption(id: "auto", name: "Auto"),
                     LanguageOption(id: "en", name: "English"),
                     LanguageOption(id: "es", name: "Spanish"),
                     LanguageOption(id: "pt", name: "Portuguese")]
    @Published var languageID: String = "auto"

    @Published var screenGranted = false
    @Published var micGranted = false
    @Published var hasKey = false
    @Published var consentAccepted = UserDefaults.standard.bool(forKey: "consentAccepted")

    // Settings (persisted)
    @Published var saveFolder: URL { didSet { UserDefaults.standard.set(saveFolder.path, forKey: "saveFolderPath") } }
    @Published var keepAudio: Bool { didSet { UserDefaults.standard.set(keepAudio, forKey: "keepAudio") } }
    @Published var includeSummary: Bool { didSet { UserDefaults.standard.set(includeSummary, forKey: "includeSummary") } }
    /// Mic-only mode: record just your own voice (notes, thinking out loud, self-interviews).
    /// Skips system audio entirely — no ScreenCaptureKit, no Screen Recording permission,
    /// no You/Them labels in the transcript.
    @Published var micOnly: Bool { didSet { UserDefaults.standard.set(micOnly, forKey: "micOnly") } }

    private var controller: CaptureController?
    private var timer: Timer?
    private var currentStamp: String?
    private var currentWorkDir: URL?
    private var currentMicOnly = false

    /// Set by the AppDelegate — opens the separate Settings window.
    var showSettings: (@MainActor () -> Void)?

    /// Screen Recording is only required for the default (meeting) mode.
    var ready: Bool { (screenGranted || micOnly) && micGranted && hasKey && consentAccepted }
    var needsSetup: Bool { !ready }

    init() {
        let defaultFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Transcribe", isDirectory: true)
        if let p = UserDefaults.standard.string(forKey: "saveFolderPath") {
            saveFolder = URL(fileURLWithPath: p, isDirectory: true)
        } else {
            saveFolder = defaultFolder
        }
        keepAudio = UserDefaults.standard.bool(forKey: "keepAudio")
        includeSummary = UserDefaults.standard.bool(forKey: "includeSummary")
        micOnly = UserDefaults.standard.bool(forKey: "micOnly")
        hasKey = Keychain.get() != nil
        refreshMics()
        Task { await refreshPermissions() }
    }

    // MARK: setup

    func saveKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Keychain.set(trimmed)
        hasKey = true
    }

    // Last 4 chars of the stored secret — a fingerprint so the user can tell which
    // token/key is stored without revealing it.
    var keyFingerprint: String? {
        guard let k = Keychain.get(), k.count >= 4 else { return nil }
        return String(k.suffix(4))
    }

    enum KeyStatus: Equatable { case idle, checking, verified, rejected, savedUnverified }
    @Published var keyStatus: KeyStatus = .idle

    /// Save the key, then (in proxy mode) verify it against the Worker.
    /// Returns true if the field should collapse (saved & accepted, or saved but offline);
    /// false if the token was rejected and the user should fix it.
    @MainActor
    func saveAndVerifyKey(_ key: String) async -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        Keychain.set(trimmed)
        hasKey = true
        guard Config.proxyBaseURL != nil else { keyStatus = .verified; return true }
        keyStatus = .checking
        switch await verifyToken(trimmed) {
        case .accepted: keyStatus = .verified; settleKeyStatus(); return true
        case .rejected: keyStatus = .rejected; return false
        case .unreachable: keyStatus = .savedUnverified; settleKeyStatus(); return true
        }
    }

    // After a brief confirmation, settle back to showing the fingerprint.
    private func settleKeyStatus() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if keyStatus == .verified || keyStatus == .savedUnverified { keyStatus = .idle }
        }
    }

    private enum VerifyResult { case accepted, rejected, unreachable }

    // Probe the proxy: a recognized token passes auth (→ 403 "model not allowed" on a
    // bogus model); an unrecognized one gets 401. Network failure → unreachable.
    private func verifyToken(_ token: String) async -> VerifyResult {
        guard let base = Config.proxyBaseURL else { return .accepted }
        var req = URLRequest(url: base.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = #"{"model":"__verify__"}"#.data(using: .utf8)
        req.timeoutInterval = 10
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return code == 401 ? .rejected : .accepted
        } catch {
            return .unreachable
        }
    }

    func acceptConsent() {
        consentAccepted = true
        UserDefaults.standard.set(true, forKey: "consentAccepted")
    }

    func refreshMics() {
        mics = MicCapture.available()
        if let sel = selectedMicID, !mics.contains(where: { $0.uniqueID == sel }) { selectedMicID = nil }
    }

    func refreshPermissions() async {
        micGranted = Permissions.micAuthorized()
        // Don't probe ScreenCaptureKit in mic-only mode — the probe itself can trip the
        // Screen Recording consent flow, which mic-only recordings never need.
        if !micOnly { screenGranted = await Permissions.screenAuthorized() }
    }

    func grantMic() {
        Task { _ = await Permissions.requestMic(); await refreshPermissions(); refreshMics() }
    }

    func grantScreen() {
        Permissions.requestScreen()
        statusDetail = "Granted? Quit & Reopen to finish enabling Screen Recording."
        Task { await refreshPermissions() }
    }

    func chooseFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = saveFolder
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { saveFolder = url }
    }

    // MARK: recording

    func toggleRecord() {
        switch phase {
        case .idle, .done, .error: startRecording()
        case .recording: Task { await stopRecording() }
        case .transcribing: break
        }
    }

    private func isoStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.string(from: Date())
    }

    private func humanTitle(_ stamp: String) -> String {
        let parts = stamp.split(separator: "_")
        guard parts.count == 2 else { return stamp }
        let time = parts[1].replacingOccurrences(of: "-", with: ":").prefix(5)  // HH:mm
        return "\(parts[0]) · \(time)"
    }

    func startRecording() {
        guard ready else { statusDetail = "Finish setup first."; return }
        let stamp = isoStamp()
        let work = saveFolder.appendingPathComponent(".work", isDirectory: true)
            .appendingPathComponent(stamp, isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        currentStamp = stamp
        currentWorkDir = work
        currentMicOnly = micOnly
        let ctl = CaptureController(outDir: work, micUniqueID: selectedMicID, micOnly: micOnly)
        ctl.onLog = { msg in Task { @MainActor in self.statusDetail = msg } }
        controller = ctl
        elapsed = 0
        statusDetail = ""
        Task {
            do { try await ctl.start(); phase = .recording; startTimer() }
            catch { phase = .error; statusDetail = "Couldn't start recording: \(error)" }
        }
    }

    func stopRecording() async {
        stopTimer()
        guard let ctl = controller, let stamp = currentStamp, let work = currentWorkDir else { return }
        let wasMicOnly = currentMicOnly
        phase = .transcribing
        statusDetail = "Finishing capture…"
        let result = await ctl.stop()
        controller = nil

        guard let key = Keychain.get() else { phase = .error; statusDetail = "No API key set."; return }
        let config = OpenAIConfig(baseURL: Config.apiBaseURL, authValue: "Bearer \(key)")
        let lang = languages.first { $0.id == languageID }?.code
        statusDetail = "Transcribing…"

        // Transcription starts immediately, off the main thread…
        let micURL = result.micURL, systemURL = result.systemURL, micOffset = result.micOffset
        let wantSummary = includeSummary
        let pipeline = Task.detached(priority: .userInitiated) {
            try await transcribeSessionBody(
                micWAV: micURL, systemWAV: systemURL,
                chunkDir: work, language: lang, micOffset: micOffset,
                labelSpeakers: !wasMicOnly, includeSummary: wantSummary, config: config)
        }
        // …while the optional title prompt runs on the main thread. Enter confirms,
        // empty or Escape skips; the title/filename is applied at the final write.
        let userTitle = promptForTitle()

        do {
            let r = try await pipeline.value
            let stem = transcriptStem(stamp: stamp, title: userTitle)
            let transcriptURL = availableTranscriptURL(in: saveFolder, stem: stem)
            let md = "# \(userTitle ?? humanTitle(stamp))\n\n" + r.body
            try FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
            try md.write(to: transcriptURL, atomically: true, encoding: .utf8)
            lastTranscript = transcriptURL
            finishWorkDir(work, stamp: stamp, success: true)
            phase = .done
            statusDetail = r.hadSpeech ? "" : "No speech detected (silent recording?)."
            // Fade the "Saved ✓" back to idle after a few seconds.
            Task { try? await Task.sleep(nanoseconds: 4_500_000_000); if self.phase == .done { self.phase = .idle } }
        } catch {
            finishWorkDir(work, stamp: stamp, success: false)
            phase = .error
            statusDetail = "Transcription failed — audio kept in _unfinished/ to retry. (\(error))"
        }
    }

    /// Small modal asking for an optional recording title. Returns nil when skipped
    /// (empty field, Skip, or Escape) — the caller falls back to the timestamp name.
    private func promptForTitle() -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Name this recording"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Skip")
        alert.buttons[1].keyEquivalent = "\u{1b}"   // Escape skips
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Optional name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    /// On success: drop the working dir (optionally stash the two raw tracks in audio/).
    /// On failure: move the working dir to _unfinished/<stamp> so nothing is lost.
    private func finishWorkDir(_ work: URL, stamp: String, success: Bool) {
        let fm = FileManager.default
        guard success else {
            let dest = saveFolder.appendingPathComponent("_unfinished", isDirectory: true)
                .appendingPathComponent(stamp, isDirectory: true)
            try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: dest)
            try? fm.moveItem(at: work, to: dest)
            return
        }
        if keepAudio {
            let dest = saveFolder.appendingPathComponent("audio", isDirectory: true)
                .appendingPathComponent(stamp, isDirectory: true)
            try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
            for name in ["system.wav", "mic.caf"] {
                let src = work.appendingPathComponent(name)
                guard fm.fileExists(atPath: src.path) else { continue }
                try? fm.removeItem(at: dest.appendingPathComponent(name))
                try? fm.moveItem(at: src, to: dest.appendingPathComponent(name))
            }
        }
        try? fm.removeItem(at: work)
        let workParent = saveFolder.appendingPathComponent(".work", isDirectory: true)
        if let c = try? fm.contentsOfDirectory(atPath: workParent.path), c.isEmpty {
            try? fm.removeItem(at: workParent)
        }
    }

    func revealTranscript() {
        if let t = lastTranscript, FileManager.default.fileExists(atPath: t.path) {
            NSWorkspace.shared.activateFileViewerSelecting([t])
        } else { openFolder() }
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(saveFolder)
    }

    // MARK: timer

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.elapsed += 1 }
        }
    }
    private func stopTimer() { timer?.invalidate(); timer = nil }

    var elapsedString: String { String(format: "%02d:%02d", elapsed / 60, elapsed % 60) }
}
