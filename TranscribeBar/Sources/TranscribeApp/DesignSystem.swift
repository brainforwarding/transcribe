import SwiftUI
import AppKit
import CoreText

/// Circles 2026 v2.8.7 semantic tokens. Native adaptations are limited to
/// window chrome, compact controls and the approved 34-point dictation chip.
enum DesignSystem {
    static var resources: Bundle {
        if let url = Bundle.main.url(forResource: "TranscribeBar_TranscribeApp", withExtension: "bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }
    private static var fontsRegistered = false
    static func registerFonts() {
        guard !fontsRegistered else { return }
        fontsRegistered = true
        for (name, ext) in [("Urbanist-Regular", "ttf"), ("Urbanist-Medium", "ttf"),
                            ("Urbanist-SemiBold", "ttf"), ("Urbanist-Bold", "otf"),
                            ("Urbanist-ExtraBold", "ttf")] {
            guard let url = resources.url(forResource: name, withExtension: ext) else {
                assertionFailure("Missing bundled font: \(name)"); continue
            }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static func font(_ size: CGFloat = 15, weight: Font.Weight = .medium,
                     relativeTo: Font.TextStyle = .body) -> Font {
        let face: String
        switch weight {
        case .regular: face = "Regular"
        case .semibold: face = "SemiBold"
        case .bold: face = "Bold"
        case .heavy, .black: face = "ExtraBold"
        default: face = "Medium"
        }
        return .custom("Urbanist-\(face)", size: size, relativeTo: relativeTo)
    }

    static let page = color("F9FAFB", "0B1B30")
    static let surface = color("FFFFFF", "13263F")
    static let raised = color("FFFFFF", "1A2F4B")
    static let subtle = color("F3F4F6", "1A2F4B")
    static let selected = color("CDE4FF", "1E4579")
    static let primary = color("002654", "FDFAF6")
    static let body = color("374151", "C8D2E0")
    static let muted = color("5C6470", "A5B4C9")
    static let border = color("E5E7EB", "2A3F5F")
    static let fieldBorder = color("D1D5DB", "34496A")
    static let inputBorder = color("818998", "7085A3")
    static let action = color("0A72EF", "0A72EF")
    static let actionPressed = color("1D4ED8", "1D4ED8")
    static let disabled = color("EEF0F3", "223756")
    static let disabledText = color("9CA3AF", "627795")
    static let link = color("2563EB", "9CC6FF")
    static let success = color("0E4A3B", "A9DCCB")
    static let successBackground = color("E3F4EF", "134A3F")
    static let warning = color("A8421A", "F08A60")
    static let warningBackground = color("FEF3C7", "1A2F4B")
    static let error = color("B42318", "F98A7E")
    static let errorBackground = color("FEF3F2", "1A2F4B")
    static let shadow = color("00265414", "0000003D")

    private static func color(_ light: String, _ dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            let n = UInt64(hex, radix: 16) ?? 0
            let alpha = hex.count == 8 ? CGFloat(n & 255) / 255 : 1
            let rgb = hex.count == 8 ? n >> 8 : n
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                           green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: alpha)
        })
    }
}

/// Exact Figma SVGs are retained alongside vector PDF renderings for AppKit.
/// PDF derivatives preserve the SVG viewport; template rendering makes semantic
/// colors mode-aware without substituting or redrawing the exported glyph.
struct DesignIcon: View {
    let name: String
    var size: CGFloat = 18
    var color: Color = DesignSystem.body
    var body: some View {
        Group {
            if let url = DesignSystem.resources.url(forResource: name, withExtension: "pdf"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size).foregroundStyle(color)
        .accessibilityHidden(true)
    }
}

struct CirclesButtonStyle: ButtonStyle {
    var primary = false
    var compact = true
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DesignSystem.font(compact ? 14 : 15, weight: .semibold))
            .foregroundStyle(!enabled ? DesignSystem.disabledText : primary ? Color.white : DesignSystem.primary)
            .padding(.horizontal, compact ? 16 : 20)
            .frame(height: compact ? 36 : 44)
            .background(!enabled ? DesignSystem.disabled : primary ? (configuration.isPressed ? DesignSystem.actionPressed : DesignSystem.action) : (configuration.isPressed ? DesignSystem.subtle : DesignSystem.surface), in: Capsule())
            .overlay(Capsule().strokeBorder(primary ? Color.clear : DesignSystem.fieldBorder, lineWidth: 1.5))
            .contentShape(Capsule())
    }
}

struct StatusPill: View {
    let title: String
    var color: Color = DesignSystem.muted
    var background: Color = DesignSystem.subtle
    var body: some View {
        Text(title).font(DesignSystem.font(13, weight: .semibold))
            .foregroundStyle(color).padding(.horizontal, 8).padding(.vertical, 4)
            .background(background, in: Capsule())
    }
}

/// Draw track and arc separately so template tinting cannot hide the motion.
/// A clock-driven task also works while the floating panel is not the key window.
struct ActivitySpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var phase = 0.0

    var body: some View {
        ZStack {
            Circle().stroke(DesignSystem.action.opacity(0.16), lineWidth: 1.8)
            Circle().trim(from: 0, to: 0.68)
                .stroke(DesignSystem.action, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .rotationEffect(.degrees(phase - 90))
        }
        .padding(1)
        .task(id: reducedMotion) {
            guard !reducedMotion else { phase = 0; return }
            while !Task.isCancelled {
                phase = ProcessInfo.processInfo.systemUptime.truncatingRemainder(dividingBy: 0.8) * 450
                do { try await Task.sleep(nanoseconds: 33_333_333) } catch { return }
            }
        }
    }
}

struct InputMeter: View {
    let level: Double
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var targetLevel = 0.0
    @State private var smoothedLevel = 0.0
    @State private var history = Array(repeating: 0.0, count: 23)
    private var width: CGFloat { compact ? 44 : 92 }
    private var height: CGFloat { compact ? 16 : 32 }
    private var normalizedLevel: Double { level.isFinite ? min(1, max(0, level)) : 0 }

    var body: some View {
        Group {
            if reducedMotion {
                Capsule().fill(DesignSystem.action.opacity(0.15))
                    .frame(height: 3)
                    .overlay(alignment: .leading) {
                        Capsule().fill(DesignSystem.action)
                            .frame(width: width * normalizedLevel, height: 3)
                    }
            } else {
                HStack(spacing: 1) {
                    ForEach(Array(history.suffix(compact ? 15 : 23).enumerated()), id: \.offset) { index, sample in
                        Capsule().fill(DesignSystem.action.opacity(0.35 + 0.65 * Double(index + 1) / Double(compact ? 15 : 23)))
                            .frame(width: compact ? 2 : 3,
                                   height: 2 + (height - 2) * pow(sample, 0.65))
                    }
                }
                .animation(.linear(duration: 0.05), value: history)
            }
        }
        .frame(width: width, height: height, alignment: .leading)
        .onAppear { targetLevel = normalizedLevel }
        .onChange(of: level) { _ in targetLevel = normalizedLevel }
        .task(id: reducedMotion) {
            guard !reducedMotion else { return }
            history = Array(repeating: 0, count: 23); smoothedLevel = 0
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
                // Fast attack follows speech; slower release avoids a twitchy display.
                // Every bar is a recent measured level, including quiet intervals.
                let response = targetLevel > smoothedLevel ? 0.8 : 0.35
                smoothedLevel += (targetLevel - smoothedLevel) * response
                history.removeFirst(); history.append(smoothedLevel)
            }
        }
        .accessibilityLabel("Audio input")
        .accessibilityValue(normalizedLevel > 0.01 ? "Sound detected" : "No input")
    }
}

struct EditableTextArea: View {
    @Binding var text: String
    var placeholder: String = ""
    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder).font(DesignSystem.font()).foregroundStyle(DesignSystem.muted)
                    .padding(.horizontal, 12).padding(.vertical, 12).allowsHitTesting(false)
            }
            TextEditor(text: $text).font(DesignSystem.font()).foregroundStyle(DesignSystem.body)
                .scrollContentBackground(.hidden).padding(8)
        }
        .background(DesignSystem.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(DesignSystem.inputBorder, lineWidth: 1))
    }
}
