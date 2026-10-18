import SwiftUI
import TranscribeCore

struct ChipView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            switch model.chipState {
            case .starting:
                ActivitySpinner().frame(width: 16, height: 16).accessibilityHidden(true)
                Text("Starting…")
                Spacer(minLength: 0)
                iconButton("chip-imgIconStop", "Stop starting") { model.finishRecording() }
            case .recording, .warning:
                DesignIcon(name: model.chipState == .warning ? "chip-imgRecording1" : "chip-imgRecording",
                           size: 6, color: model.chipState == .warning ? DesignSystem.warning : DesignSystem.error)
                InputMeter(level: model.activeKind == .meeting ? max(model.micLevel, model.systemLevel) : model.micLevel, compact: true)
                Text(model.chipState == .warning ? "\(max(0, 300 - model.elapsed))s left" : time)
                    .foregroundStyle(model.chipState == .warning ? DesignSystem.warning : DesignSystem.muted)
                    .frame(width: model.chipState == .warning ? 54 : model.activeKind == .meeting ? 62 : 32, alignment: .leading)
                if model.activeKind == .meeting { Spacer(minLength: 0) }
                iconButton("chip-imgIconStop", model.activeKind == .meeting ? "Finish meeting" : "Finish · Option") {
                    model.finishRecording()
                }
            case .transcribing:
                ActivitySpinner().frame(width: 16, height: 16).accessibilityHidden(true)
                Text("Transcribing")
                Spacer(minLength: 0)
                iconButton("chip-imgIconClose", model.activeKind == .meeting ? "Hide indicator" : "Cancel insertion · Escape") {
                    if model.activeKind == .meeting { model.chipVisible = false }
                    else { model.cancelDictation() }
                }
            case .inserted:
                DesignIcon(name: "chip-imgIconTickCircle", size: 14, color: DesignSystem.success)
                Text("Inserted")
                Spacer(minLength: 0)
                ConfirmedCopyButton(accessibilityLabel: "Copy last", icon: "chip-imgIconCopy", action: copyLast).buttonStyle(.plain)
            case .ready:
                DesignIcon(name: "chip-imgIconCopy1", size: 14, color: DesignSystem.action)
                Text("Ready")
                Spacer(minLength: 0)
                ConfirmedCopyButton(accessibilityLabel: "Copy last", action: copyLast).buttonStyle(.plain)
                    .foregroundStyle(DesignSystem.link).padding(4)
            case .cancelled:
                DesignIcon(name: "chip-imgIconClose1", size: 14, color: DesignSystem.muted)
                Text("Cancelled")
                Spacer(minLength: 0)
                if model.activeRecord?.canRecover == true { linkButton("Recover") { recover() } }
            case .failed:
                DesignIcon(name: "chip-imgIconDanger", size: 14, color: DesignSystem.error)
                Text(model.failedChipLabel)
                Spacer(minLength: 0)
                if model.activeRecord?.canRecover == true { linkButton("Retry") { recover() } }
                else if model.failedChipShowsSettings { linkButton("Settings") { model.showSettings?() } }
                else { linkButton("History") { model.selectedRecordID = model.activeSessionID; model.showLibrary?() } }
            case .silent:
                DesignIcon(name: "chip-imgIconMicrophone", size: 14, color: DesignSystem.muted)
                Text("No speech")
                Spacer(minLength: 0)
                linkButton("Retry") { model.startDictation() }
            case .hidden:
                EmptyView()
            }
        }
        .preferredColorScheme(model.colorScheme)
        .font(DesignSystem.font(13, weight: .semibold))
        .foregroundStyle(DesignSystem.primary)
        .padding(.horizontal, 8)
        .frame(width: model.chipWidth, height: 34)
        .background(DesignSystem.raised, in: Capsule())
        .overlay(Capsule().strokeBorder(DesignSystem.border, lineWidth: 1))
        .shadow(color: DesignSystem.shadow, radius: 6, y: 4)
        .shadow(color: DesignSystem.shadow, radius: 1.5, y: 1)
        .fixedSize()
    }

    private var time: String { "\(model.elapsed / 60):\(String(format: "%02d", model.elapsed % 60))" }
    private func iconButton(_ name: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            DesignIcon(name: name, size: 12, color: DesignSystem.muted)
                .frame(width: 24, height: 24).background(DesignSystem.subtle, in: Circle())
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
    private func linkButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action).buttonStyle(.plain).foregroundStyle(DesignSystem.link)
            .padding(4).help(label).accessibilityLabel(label)
    }
    private func copyLast() -> Bool {
        guard let record = model.lastRecordWithText else { return false }
        return model.copyTranscript(record.id)
    }
    private func recover() {
        if let id = model.activeSessionID ?? model.records.first?.id {
            model.retry(id)
        }
    }
}
