import SwiftUI

/// Brief confirmation belongs to the control that successfully wrote the clipboard.
struct ConfirmedCopyButton: View {
    let accessibilityLabel: String
    var icon: String? = nil
    let action: () -> Bool
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button(action: copy) {
            if let icon {
                ZStack {
                    DesignIcon(name: copied ? "chip-imgIconTickCircle" : icon,
                               size: 12, color: copied ? DesignSystem.success : DesignSystem.muted)
                        .id(copied).transition(.opacity)
                }.frame(width: 24, height: 24).background(DesignSystem.subtle, in: Circle())
            } else {
                ZStack {
                    Text("Copied").hidden().accessibilityHidden(true)
                    Text(copied ? "Copied" : "Copy").id(copied).transition(.opacity)
                }
            }
        }
        .animation(reducedMotion ? nil : .easeInOut(duration: 0.15), value: copied)
        .help(copied ? "Copied" : accessibilityLabel)
        .accessibilityLabel(copied ? "Copied" : accessibilityLabel)
        .onDisappear { resetTask?.cancel(); resetTask = nil; copied = false }
    }

    private func copy() {
        resetTask?.cancel()
        copied = action()
        guard copied else { resetTask = nil; return }
        resetTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 1_400_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            copied = false
            resetTask = nil
        }
    }
}
