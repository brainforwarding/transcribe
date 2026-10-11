import AppKit
import SwiftUI
import Sparkle

/// Small, nonsecret, one-shot navigation state. Written only after the final save gate.
struct UpdateResumeMarker: Codable, Equatable {
    let sidebar: String
    let selectedRecordID: UUID?
    let windowVisible: Bool
    let targetBuild: String
    let createdAt: Date

    func isValid(currentBuild: String, now: Date) -> Bool {
        AppModel.Sidebar(rawValue: sidebar) != nil && !targetBuild.isEmpty && targetBuild == currentBuild &&
            now.timeIntervalSince(createdAt) >= -60 && now.timeIntervalSince(createdAt) <= 600
    }
}

struct UpdateResumeStore {
    let url: URL
    init(url: URL? = nil, bundle: Bundle = .main) {
        if let url { self.url = url; return }
#if TRANSCRIBE_VALIDATION_FIXTURE
        guard bundle.bundleIdentifier?.hasPrefix("com.sebastianmarambio.transcribe.updatefixture.") == true,
              bundle.object(forInfoDictionaryKey: "TranscribeValidationFixture") as? Bool == true,
              let root = bundle.object(forInfoDictionaryKey: "TranscribeValidationRoot") as? String,
              (root as NSString).isAbsolutePath, root != "/" else {
            preconditionFailure("Missing isolated updater fixture configuration")
        }
        self.url = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("UpdateResume.json")
#else
        self.url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(bundle.bundleIdentifier ?? "Transcribe", isDirectory: true)
            .appendingPathComponent("UpdateResume.json")
#endif
    }
    func write(_ marker: UpdateResumeMarker) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(marker).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func clear() { try? FileManager.default.removeItem(at: url) }
    func consume(currentBuild: String, now: Date = Date()) -> UpdateResumeMarker? {
        defer { clear() }
        guard let data = try? Data(contentsOf: url), data.count <= 2048,
              let marker = try? JSONDecoder().decode(UpdateResumeMarker.self, from: data),
              marker.isValid(currentBuild: currentBuild, now: now) else { return nil }
        return marker
    }
}

/// Sparkle's native scheduler discovers updates. Only an accepted fresh interactive
/// check owns installation permission; background replies are never retained.
@MainActor
final class UpdateController: NSObject, SPUUpdaterDelegate {
    struct CheckOperations {
        let canCheckForUpdates: () -> Bool
        let checkForUpdates: () -> Void
    }
    private let model: AppModel
    private let checkOperations: CheckOperations?
    private let resumeStore: UpdateResumeStore
    private let endEditing: () -> Bool
    private let windowVisible: () -> Bool
    private let hostBundle: Bundle
    private let driver = TranscribeUpdateDriver()
    private var updater: SPUUpdater!
    private var readiness: NSKeyValueObservation?
    private(set) var acceptedUserCycle = false
    private(set) var installationAuthorized = false
    private var targetBuild: String?
    private var expectedLength: UInt64 = 0
    private var receivedLength: UInt64 = 0
    private var checkCancellation: (() -> Void)?
    private var downloadCancellation: (() -> Void)?
    private var retryTermination: (() -> Void)?

    init(model: AppModel, hostBundle: Bundle = .main, resumeStore: UpdateResumeStore? = nil,
         endEditing: @escaping () -> Bool, windowVisible: @escaping () -> Bool, checkOperations: CheckOperations? = nil) {
        self.model = model; self.hostBundle = hostBundle; self.checkOperations = checkOperations
        self.resumeStore = resumeStore ?? UpdateResumeStore(bundle: hostBundle)
        self.endEditing = endEditing; self.windowVisible = windowVisible
        super.init()
        driver.controller = self
        if checkOperations == nil {
            updater = SPUUpdater(hostBundle: hostBundle, applicationBundle: hostBundle, userDriver: driver, delegate: self)
        }
        model.requestUpdate = { [weak self] in self?.requestUpdate() }
    }

    func start() {
        guard let updater else { model.updaterReady = checkOperations?.canCheckForUpdates() == true; return }
        // Configure privacy/interaction explicitly, also for migrated Sparkle defaults.
        updater.sendsSystemProfile = false
        updater.automaticallyDownloadsUpdates = false
        updater.automaticallyChecksForUpdates = true
        readiness = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let ready = updater.canCheckForUpdates
            Task { @MainActor in self?.model.updaterReady = ready }
        }
        do { try updater.start() }
        catch { model.updaterReady = false } // Misconfiguration/background failures do not interrupt app work.
    }

    func consumeResume() -> UpdateResumeMarker? {
        let build = hostBundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return resumeStore.consume(currentBuild: build)
    }

    func requestUpdate() {
        // A denied quit leaves Sparkle's staged installer alive. Retry that one
        // termination handler only after another save gate, never a second check.
        if acceptedUserCycle, installationAuthorized, model.updatePresentation == .retry,
           let retryTermination {
            guard endEditing(), model.updateSafePoint(), writeResume() else { return }
            setPresentation(.installing)
            retryTermination()
            return
        }
        guard (checkOperations?.canCheckForUpdates() ?? updater.canCheckForUpdates), !acceptedUserCycle, model.canBeginUpdate else { return }
        guard endEditing(), model.acquireUpdateLock() else { setPresentation(.retry); return }
        acceptedUserCycle = true; installationAuthorized = false
        resumeStore.clear(); expectedLength = 0; receivedLength = 0
        setPresentation(.checking)
        if let checkOperations { checkOperations.checkForUpdates() } else { updater.checkForUpdates() }
    }

    static func canOffer(_ item: SUAppcastItem) -> Bool {
        !item.isInformationOnlyUpdate && !item.isMajorUpgrade && !item.isDeltaUpdate &&
            item.installationType == "application" && item.minimumOperatingSystemVersionIsOK &&
            item.maximumOperatingSystemVersionIsOK && item.minimumUpdateVersionIsOK &&
            item.arm64HardwareRequirementIsOK && item.isMacOsUpdate &&
            allowedAssetURL(item.fileURL) && !item.versionString.isEmpty
    }

    private static func allowedAssetURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        if url.scheme?.lowercased() == "https" { return true }
#if TRANSCRIBE_VALIDATION_FIXTURE
        return url.scheme?.lowercased() == "http" && ["127.0.0.1", "localhost"].contains(url.host?.lowercased() ?? "")
#else
        return false
#endif
    }

    fileprivate func found(_ item: SUAppcastItem, state: SPUUserUpdateState) -> SPUUserUpdateChoice {
        guard Self.canOffer(item) else {
            if acceptedUserCycle { finish(.hidden) }
            return state.stage == .installing ? .skip : .dismiss
        }
        targetBuild = item.versionString
        guard acceptedUserCycle, state.userInitiated, model.updateInProgress else {
            if !acceptedUserCycle { setPresentation(.available) }
            // An unexpected previously staged installer must be cancelled, because
            // Dismiss would still allow it to install on a subsequent ordinary quit.
            return state.stage == .installing ? .skip : .dismiss
        }
        guard endEditing(), model.updateSafePoint() else {
            fail(); return state.stage == .installing ? .skip : .dismiss
        }
        checkCancellation = nil
        // A resumed installing update can terminate immediately from this callback.
        if state.stage == .installing {
            guard authorizeInstallation() else { fail(); return .skip }
            setPresentation(.installing)
        } else { setPresentation(.downloading) }
        return .install
    }

    fileprivate func readyToInstall() -> SPUUserUpdateChoice {
        checkCancellation = nil; downloadCancellation = nil
        guard authorizeInstallation() else { fail(); return .skip }
        setPresentation(.installing)
        return .install
    }

    private func authorizeInstallation() -> Bool {
        guard acceptedUserCycle, model.updateInProgress, endEditing(), model.updateSafePoint(),
              writeResume() else { return false }
        installationAuthorized = true
        return true
    }
    private func writeResume() -> Bool {
        guard let targetBuild else { return false }
        let marker = UpdateResumeMarker(sidebar: model.sidebar.rawValue, selectedRecordID: model.selectedRecordID,
            windowVisible: windowVisible(), targetBuild: targetBuild, createdAt: Date())
        do { try resumeStore.write(marker); return true }
        catch { return false }
    }
    /// The application termination delegate rechecks the saved gate before Sparkle's quit event.
    func permitsTermination() -> Bool {
        guard model.updateInProgress else { return true }
        let permitted = installationAuthorized && endEditing() && model.updateSafePoint() && writeResume()
        if !permitted, acceptedUserCycle, installationAuthorized { setPresentation(.retry) }
        return permitted
    }
    func applicationWillTerminate() {
        // Successful updater termination must leave the marker for the new process.
        if !installationAuthorized { resumeStore.clear() }
        checkCancellation = nil; downloadCancellation = nil; retryTermination = nil
    }

    fileprivate func checking(_ cancellation: @escaping () -> Void) {
        guard acceptedUserCycle else { cancellation(); return }
        checkCancellation = cancellation
    }
    fileprivate func downloading(_ cancellation: @escaping () -> Void) {
        guard acceptedUserCycle, model.updateInProgress else { cancellation(); return }
        checkCancellation = nil; downloadCancellation = cancellation
        expectedLength = 0; receivedLength = 0; setPresentation(.downloading)
    }
    fileprivate func expected(_ length: UInt64) { expectedLength = length; updateProgress() }
    fileprivate func received(_ length: UInt64) {
        let sum = receivedLength.addingReportingOverflow(length)
        receivedLength = sum.overflow ? UInt64.max : sum.partialValue
        updateProgress()
    }
    private func updateProgress() {
        guard acceptedUserCycle, model.updatePresentation == .downloading else { return }
        model.updateProgress = expectedLength > 0 ? min(1, max(0, Double(receivedLength) / Double(expectedLength))) : nil
    }
    fileprivate func extracting() {
        guard acceptedUserCycle else { return }
        downloadCancellation = nil; setPresentation(.installing)
    }
    fileprivate func installing(applicationTerminated: Bool, retry: @escaping () -> Void) {
        guard acceptedUserCycle, installationAuthorized else { return }
        retryTermination = applicationTerminated ? nil : retry
        if model.updatePresentation != .retry { setPresentation(.installing) }
    }
    func cycleFinished(error: Error?) {
        // Sparkle calls this only after completion/abort, including a nil-error
        // relaunch veto. Installed success already ends the accepted cycle.
        if acceptedUserCycle { fail() }
    }
    fileprivate func installed() { finish(.hidden, clearResume: false) }
    fileprivate func notFound() {
        targetBuild = nil
        if acceptedUserCycle { finish(.hidden) } else { setPresentation(.hidden) }
    }
    fileprivate func fail() { if acceptedUserCycle { finish(.retry) } }
    fileprivate func dismiss() {
        checkCancellation = nil; downloadCancellation = nil
        // Sparkle may dismiss presentation during installer handoff; keep the lock.
        if acceptedUserCycle && !installationAuthorized { fail() }
    }
    private func finish(_ state: UpdatePresentation, clearResume: Bool = true) {
        acceptedUserCycle = false; installationAuthorized = false
        checkCancellation = nil; downloadCancellation = nil; retryTermination = nil
        if clearResume { resumeStore.clear() }
        model.releaseUpdateLock(); setPresentation(state)
    }
    private func setPresentation(_ state: UpdatePresentation) {
        let changed = model.updatePresentation != state
        model.updatePresentation = state; model.updateProgress = nil
        if changed, state.running || state == .retry, let app = NSApp {
            NSAccessibility.post(element: app, notification: .announcementRequested,
                userInfo: [.announcement: state.title, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
    }

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }
    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool { false }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) { notFound() }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        guard Self.canOffer(item) else { return }
        targetBuild = item.versionString
        if !acceptedUserCycle { setPresentation(.available) }
    }
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem,
                 updateCheck: SPUUpdateCheck, error: AutoreleasingUnsafeMutablePointer<NSError?>) -> Bool {
        Self.canOffer(updateItem)
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { fail() }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        cycleFinished(error: error)
    }
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool { permitsTermination() }
}

/// Replies are consumed synchronously, once per callback. There are no pending
/// background prompts or deferred reply closures to survive a finished cycle.
@MainActor
final class TranscribeUpdateDriver: NSObject, SPUUserDriver {
    weak var controller: UpdateController?
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, automaticUpdateDownloading: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { if let controller { controller.checking(cancellation) } else { cancellation() } }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        reply(controller?.found(appcastItem, state: state) ?? (state.stage == .installing ? .skip : .dismiss))
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        controller?.notFound(); acknowledgement()
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        controller?.fail(); acknowledgement()
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { if let controller { controller.downloading(cancellation) } else { cancellation() } }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { controller?.expected(expectedContentLength) }
    func showDownloadDidReceiveData(ofLength length: UInt64) { controller?.received(length) }
    func showDownloadDidStartExtractingUpdate() { controller?.extracting() }
    func showExtractionReceivedProgress(_ progress: Double) {} // Installer remains an indeterminate stage.
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { reply(controller?.readyToInstall() ?? .skip) }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        controller?.installing(applicationTerminated: applicationTerminated, retry: retryTerminatingApplication)
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        controller?.installed(); acknowledgement()
    }
    func dismissUpdateInstallation() { controller?.dismiss() }
}

struct SidebarUpdateButton: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    var body: some View {
        Button { model.requestUpdate?() } label: {
            HStack(spacing: 8) {
                ZStack {
                    if model.updatePresentation.running {
                        if let progress = model.updateProgress, model.updatePresentation == .downloading {
                            Circle().stroke(Color.white.opacity(0.25), lineWidth: 1.5)
                            Circle().trim(from: 0, to: progress).stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        } else if reducedMotion { Image(systemName: "arrow.down").font(.system(size: 12, weight: .semibold)) }
                        else { ProgressView().controlSize(.mini).tint(.white) }
                    } else { Image(systemName: "arrow.down").font(.system(size: 12, weight: .semibold)) }
                }.frame(width: 14, height: 14).accessibilityHidden(true)
                Text(model.updatePresentation.title).font(DesignSystem.font(13, weight: .semibold)).lineLimit(1)
            }.frame(width: 148, height: 32)
        }
        .buttonStyle(SidebarUpdateButtonStyle(running: model.updatePresentation.running))
        .disabled(model.updatePresentation.running ||
            (!(model.updateInProgress && model.updatePresentation == .retry) && (!model.canBeginUpdate || !model.updaterReady)))
        .accessibilityLabel(model.updatePresentation.title)
        .accessibilityHint(model.updatePresentation == .available || model.updatePresentation == .retry
            ? "Descarga, instala y reinicia Transcribe" : "")
    }
}

private struct SidebarUpdateButtonStyle: ButtonStyle {
    let running: Bool
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(enabled || running ? Color.white : DesignSystem.disabledText)
            .background(enabled || running ? (configuration.isPressed ? DesignSystem.actionPressed : DesignSystem.action) : DesignSystem.disabled, in: Capsule())
            .contentShape(Capsule())
    }
}
