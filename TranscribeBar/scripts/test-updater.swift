import Foundation
import Sparkle
import TranscribeCore

private struct Failure: Error, CustomStringConvertible { let description: String }
@MainActor private func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw Failure(description: message) }
}
private final class StateDecoder: NSCoder {
    let stage: SPUUserUpdateStage
    let initiated: Bool
    init(_ stage: SPUUserUpdateStage, initiated: Bool) { self.stage = stage; self.initiated = initiated }
    override var allowsKeyedCoding: Bool { true }
    override func decodeInteger(forKey key: String) -> Int { stage.rawValue }
    override func decodeBool(forKey key: String) -> Bool { initiated }
}

@MainActor private final class Fixture {
    let root: URL
    let store: SessionStore
    let preferences: UserDefaults
    let domain = "Transcribe.UpdaterFixture." + UUID().uuidString
    let record: SessionRecord
    var saveFails = false
    var editingAllowed = true
    var checkReady = true
    var checks = 0
    var model: AppModel!
    var controller: UpdateController!
    let driver = TranscribeUpdateDriver()
    var resume: UpdateResumeStore { UpdateResumeStore(url: root.appendingPathComponent("resume.json")) }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("transcribe-updater-tests-" + UUID().uuidString)
        store = try SessionStore(root: root.appendingPathComponent("Sessions"))
        preferences = UserDefaults(suiteName: domain)!
        record = SessionRecord(kind: .dictation, meetingMode: .inPerson, title: "Synthetic fixture")
        try store.save(record)
        let access = CredentialAccess(get: { _ in nil }, unlock: { _ in nil }, set: { _, _ in },
            status: { _ in nil }, fingerprint: { _ in nil }, legacyConfigured: { false })
        let operations = AppModel.Operations(makeCapture: { _, _, _, _, _, _ in fatalError("No capture in updater tests") },
            transcribe: { _, _, _ in fatalError("No transcription in updater tests") }, uptime: { 0 },
            credentials: { _ in fatalError("No credentials in updater tests") }, save: { [weak self] store, record in
                if self?.saveFails == true { throw CocoaError(.fileWriteOutOfSpace) }
                try store.save(record)
            }, cleanAudio: { _, _ in }, deliverAtCurrentCaret: { _, _ in fatalError("No paste in updater tests") },
            copy: { _ in false }, automaticTimer: false)
        model = AppModel(store: store, operations: operations, preferences: preferences,
            initializeSystemState: false, credentialAccess: access)
        controller = UpdateController(model: model, resumeStore: resume,
            endEditing: { [weak self] in self?.editingAllowed == true }, windowVisible: { true },
            checkOperations: .init(canCheckForUpdates: { [weak self] in self?.checkReady == true },
                                   checkForUpdates: { [weak self] in self?.checks += 1 }))
        driver.controller = controller
    }
    func clean() { preferences.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: root) }
}

@main private struct UpdaterSelftest {
    @MainActor static func main() throws {
        let f = try Fixture(); defer { f.clean() }
        let item = SUAppcastItem(dictionary: ["enclosure": ["url": "https://example.invalid/Transcribe_12.dmg", "sparkle:version": "12", "length": "100"]])!
        let background = SPUUserUpdateState(coder: StateDecoder(.notDownloaded, initiated: false))!
        let interactive = SPUUserUpdateState(coder: StateDecoder(.notDownloaded, initiated: true))!
        try expect(UpdateController.canOffer(item), "Ordinary HTTPS app item accepted")
        let unsafe = SUAppcastItem(dictionary: ["enclosure": ["url": "http://example.invalid/Transcribe_12.dmg", "sparkle:version": "12"]])!
        try expect(!UpdateController.canOffer(unsafe), "Remote HTTP asset rejected")
        var choices: [SPUUserUpdateChoice] = []
        f.driver.showUpdateFound(with: item, state: background) { choices.append($0) }
        try expect(choices == [.dismiss] && !f.model.updateInProgress && f.model.updatePresentation == .available,
                   "Background discovery replies immediately without an app lock")
        f.checkReady = false; f.controller.requestUpdate()
        try expect(f.checks == 0 && !f.model.updateInProgress, "Sparkle readiness blocks fresh check")
        f.checkReady = true; f.model.keyStatus = .checking; f.controller.requestUpdate()
        try expect(f.checks == 0 && !f.model.updateInProgress, "Credential verification blocks fresh check")
        f.model.keyStatus = .idle
        f.saveFails = true
        f.model.updateNotes(f.record.id, "Unsaved synthetic notes")
        f.model.updateSummary(f.record.id, "Unsaved synthetic summary")
        try expect(f.model.editableNotes(for: f.record.id) == "Unsaved synthetic notes" &&
                   f.model.editableSummary(for: f.record.id) == "Unsaved synthetic summary",
                   "Failed notes/summary writes retain editable drafts")
        f.model.stageTitle(f.record.id, "Saved before update")
        f.controller.requestUpdate()
        try expect(f.checks == 0 && !f.model.updateInProgress && f.model.updatePresentation == .retry,
                   "Failed title save refuses update and offers retry")
        f.saveFails = false; f.controller.requestUpdate(); f.controller.requestUpdate()
        try expect(f.checks == 1 && f.model.updateInProgress && f.model.records.first?.title == "Saved before update",
                   "Durable title save precedes exactly one fresh check and lock")
        let committed = try f.store.load().first
        try expect(committed?.notes == "Unsaved synthetic notes" && committed?.summary == "Unsaved synthetic summary",
                   "Pending notes and summary are durably flushed before checking")
        f.driver.showUpdateFound(with: item, state: interactive) { choices.append($0) }
        try expect(choices == [.dismiss, .install], "Accepted user cycle replies Install once")
        f.driver.showDownloadInitiated(cancellation: {})
        f.driver.showDownloadDidReceiveExpectedContentLength(100)
        f.driver.showDownloadDidReceiveData(ofLength: 30)
        try expect(f.model.updateProgress == 0.3, "Progress uses actual downloaded bytes")
        f.driver.showDownloadDidReceiveData(ofLength: UInt64.max)
        try expect(f.model.updateProgress == 1, "Invalid/overflow transfer length remains bounded")
        f.driver.showDownloadDidStartExtractingUpdate()
        f.editingAllowed = false
        f.driver.showReady(toInstallAndRelaunch: { choices.append($0) })
        try expect(choices.last == .skip && !f.model.updateInProgress && f.model.updatePresentation == .retry,
                   "Final failed edit gate skips staged installation and releases latch")
        try expect(!FileManager.default.fileExists(atPath: f.resume.url.path), "Rejected installation has no resume marker")
        f.driver.dismissUpdateInstallation()
        try expect(f.model.updatePresentation == .retry, "Dismiss preserves useful retry state")
        f.editingAllowed = true; f.controller.requestUpdate()
        f.driver.showUpdateFound(with: item, state: interactive) { choices.append($0) }
        f.model.sidebar = .meetings; f.model.selectedRecordID = f.record.id
        f.driver.showReady(toInstallAndRelaunch: { choices.append($0) })
        try expect(choices.last == .install && f.controller.installationAuthorized && f.model.updateInProgress,
                   "Saved idle gate authorizes install and retains lock")
        f.driver.dismissUpdateInstallation()
        try expect(f.model.updateInProgress, "Installer handoff cannot release work lock")
        let marker = f.resume.consume(currentBuild: "12")
        try expect(marker?.sidebar == "meetings" && marker?.selectedRecordID == f.record.id && marker?.windowVisible == true,
                   "Resume marker preserves navigation only")
        try expect(f.resume.consume(currentBuild: "12") == nil, "Resume consumed once")
        try f.resume.write(UpdateResumeMarker(sidebar: "settings", selectedRecordID: nil, windowVisible: false,
                                            targetBuild: "12", createdAt: Date().addingTimeInterval(-601)))
        try expect(f.resume.consume(currentBuild: "12") == nil, "Expired marker rejected and cleared")
        try f.resume.write(UpdateResumeMarker(sidebar: "settings", selectedRecordID: nil, windowVisible: false,
                                            targetBuild: "12", createdAt: Date()))
        try expect(f.resume.consume(currentBuild: "11") == nil, "Wrong target build rejected")
        f.editingAllowed = false
        try expect(!f.controller.permitsTermination() && f.model.updateInProgress && f.model.updatePresentation == .retry,
                   "Denied final termination preserves latch and exposes retry")
        var quitRetries = 0
        f.driver.showInstallingUpdate(withApplicationTerminated: false) { quitRetries += 1 }
        let priorChecks = f.checks
        f.checkReady = false
        f.controller.requestUpdate()
        try expect(quitRetries == 0 && f.model.updateInProgress, "Failed retry gate does not terminate or release staged lock")
        f.editingAllowed = true
        f.controller.requestUpdate(); f.controller.requestUpdate()
        try expect(quitRetries == 1 && f.checks == priorChecks && f.model.updatePresentation == .installing,
                   "Explicit retry uses one termination callback without a second check")
        f.controller.cycleFinished(error: nil)
        try expect(!f.model.updateInProgress && f.model.updatePresentation == .retry,
                   "Nil-error aborted authorized cycle releases lock")
        var acknowledgements = 0
        f.checkReady = true; f.controller.requestUpdate()
        f.driver.showUpdaterError(URLError(.badServerResponse)) { acknowledgements += 1 }
        try expect(acknowledgements == 1 && f.model.updatePresentation == .retry && !f.model.updateInProgress,
                   "Error acknowledgement runs once and releases work")
        f.driver.showUpdateNotFoundWithError(URLError(.fileDoesNotExist)) { acknowledgements += 1 }
        try expect(acknowledgements == 2 && f.model.updatePresentation == .hidden, "No offer clears obsolete availability")
        let stagedBackground = SPUUserUpdateState(coder: StateDecoder(.installing, initiated: false))!
        f.driver.showUpdateFound(with: item, state: stagedBackground) { choices.append($0) }
        try expect(choices.last == .skip && !f.model.updateInProgress,
                   "Unaccepted staged installer is cancelled instead of installing on ordinary quit")
        let malformed = try JSONSerialization.data(withJSONObject: ["sidebar": "meetings", "selectedRecordID": "invalid-uuid",
            "windowVisible": true, "targetBuild": "12", "createdAt": Date().timeIntervalSinceReferenceDate])
        try malformed.write(to: f.resume.url)
        try expect(f.resume.consume(currentBuild: "12") == nil, "Malformed UUID marker rejected and cleared")
        let detached = TranscribeUpdateDriver()
        detached.showUserInitiatedUpdateCheck { acknowledgements += 1 }
        detached.showDownloadInitiated { acknowledgements += 1 }
        detached.showReady(toInstallAndRelaunch: { choices.append($0) })
        try expect(acknowledgements == 4 && choices.last == .skip, "Detached driver cancels checks/downloads and rejects installation")
        print("PASS updater: 30 offline state, callback, save-gate, progress and resume checks")
    }
}
