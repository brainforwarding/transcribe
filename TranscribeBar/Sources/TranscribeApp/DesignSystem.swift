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

struct InputMeter: View {
    let level: Double
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    private let weights: [Double] = [0.25, 0.62, 0.38, 1, 0.56, 0.75, 0.31]
    var body: some View {
        HStack(spacing: compact ? 4 : 4) {
            ForEach(Array((compact ? weights : [0.2,0.43,0.3,0.77,0.56,1,0.67,0.4,0.87,0.6,0.27,0.5,0.8,0.33]).enumerated()), id: \.offset) { _, weight in
                Capsule().fill(DesignSystem.action)
                    .frame(width: compact ? 2 : 3,
                           height: max(2, (compact ? 16 : 32) * min(1, max(0, level)) * (reducedMotion ? 1 : weight)))
            }
        }
        .frame(width: compact ? 44 : 92, height: compact ? 16 : 32, alignment: .leading)
        .accessibilityLabel("Audio input")
        .accessibilityValue(level > 0.01 ? "Sound detected" : "No input")
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
