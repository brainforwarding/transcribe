import SwiftUI
import TranscribeCore

struct ChipView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            switch model.chipState {
            case .starting:
                spinner("Starting")
                iconButton("chip-imgIconStop", "Stop starting") { model.finishRecording() }
            case .recording, .warning:
                DesignIcon(name: model.chipState == .warning ? "chip-imgRecording1" : "chip-imgRecording",
                           size: 6, color: model.chipState == .warning ? DesignSystem.warning : DesignSystem.error)
                InputMeter(level: model.activeKind == .meeting ? max(model.micLevel, model.systemLevel) : model.micLevel, compact: true)
                Text(model.chipState == .warning ? "\(max(0, 300 - model.elapsed))s left" : time)
                    .foregroundStyle(model.chipState == .warning ? DesignSystem.warning : DesignSystem.muted)
                    .frame(width: model.chipState == .warning ? 50 : model.activeKind == .meeting ? 58 : 30, alignment: .leading)
                iconButton("chip-imgIconStop", model.activeKind == .meeting ? "Finish meeting" : "Finish · Option") {
                    model.finishRecording()
                }
            case .transcribing:
                spinner("Transcribing")
                iconButton("chip-imgIconClose", model.activeKind == .meeting ? "Hide indicator" : "Cancel insertion · Escape") {
                    if model.activeKind == .meeting { model.chipVisible = false }
                    else { model.cancelDictation() }
                }
            case .inserted:
                DesignIcon(name: "chip-imgIconTickCircle", size: 12, color: DesignSystem.success)
                    .help("Inserted").accessibilityLabel("Inserted")
                ConfirmedCopyButton(accessibilityLabel: "Copy last", icon: "chip-imgIconCopy", iconFrame: 20, action: copyLast).buttonStyle(.plain)
            case .ready:
                DesignIcon(name: "chip-imgIconCopy1", size: 12, color: DesignSystem.action)
                if model.pasteFeedback == .permission {
                    Button(model.readyChipLabel) { model.grantAccessibility(); Permissions.openAccessibilitySettings() }
                        .buttonStyle(.plain).foregroundStyle(DesignSystem.link)
                        .help(model.deliveryDetail)
                } else {
                    Text(model.readyChipLabel).help(model.deliveryDetail)
                        .accessibilityLabel(model.readyChipLabel + ". " + model.deliveryDetail)
                }
                ConfirmedCopyButton(accessibilityLabel: "Copy last", action: copyLast).buttonStyle(.plain)
                    .foregroundStyle(DesignSystem.link).padding(.horizontal, 4).padding(.vertical, 2)
            case .cancelled:
                DesignIcon(name: "chip-imgIconClose1", size: 12, color: DesignSystem.muted)
                Text("Cancelled")
                if model.activeRecord?.canRecover == true { linkButton("Recover") { recover() } }
            case .failed:
                DesignIcon(name: "chip-imgIconDanger", size: 12, color: DesignSystem.error)
                Text(model.failedChipLabel)
                if model.activeRecord?.canRecover == true { linkButton("Retry") { recover() } }
                else if model.failedChipShowsSettings { linkButton("Settings") { model.showSettings?() } }
                else { linkButton("History") { model.selectedRecordID = model.activeSessionID; model.showLibrary?() } }
            case .silent:
                DesignIcon(name: "chip-imgIconMicrophone", size: 12, color: DesignSystem.muted)
                Text("No speech")
                linkButton("Retry") { model.startDictation() }
            case .hidden:
                EmptyView()
            }
        }
        .preferredColorScheme(model.colorScheme)
        .font(DesignSystem.font(12, weight: .semibold))
        .foregroundStyle(DesignSystem.primary)
        .padding(.leading, 8)
        .padding(.trailing, endsWithText ? 10 : 4)
        .frame(height: 26)
        .background(DesignSystem.raised, in: Capsule())
        .overlay(Capsule().strokeBorder(DesignSystem.border, lineWidth: 1))
        .shadow(color: DesignSystem.shadow, radius: 6, y: 4)
        .shadow(color: DesignSystem.shadow, radius: 1.5, y: 1)
        .fixedSize()
    }

    /// Cancelled without Recover is the only state whose last item is plain text.
    private var endsWithText: Bool { model.chipState == .cancelled && model.activeRecord?.canRecover != true }
    private func spinner(_ label: String) -> some View {
        ActivitySpinner().frame(width: 12, height: 12).help(label).accessibilityLabel(label)
    }
    private var time: String { "\(model.elapsed / 60):\(String(format: "%02d", model.elapsed % 60))" }
    private func iconButton(_ name: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            DesignIcon(name: name, size: 10, color: DesignSystem.muted)
                .frame(width: 20, height: 20).background(DesignSystem.subtle, in: Circle())
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
    private func linkButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action).buttonStyle(.plain).foregroundStyle(DesignSystem.link)
            .padding(.horizontal, 4).padding(.vertical, 2).help(label).accessibilityLabel(label)
    }
    private func copyLast() -> Bool {
        guard let record = model.chipTranscriptRecord else { return false }
        return model.copyTranscript(record.id)
    }
    private func recover() {
        if let id = model.activeSessionID ?? model.records.first?.id {
            model.retry(id)
        }
    }
}
