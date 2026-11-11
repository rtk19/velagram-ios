import SwiftUI
import MediaAccessibility
import CoreText
import VLCKit

struct SystemCaptionStyle: Equatable {
    let font: UIFont
    let foreground: UIColor
    let background: UIColor
    let window: UIColor
    let relativeSize: CGFloat
    let edge: MACaptionAppearanceTextEdgeStyle
    static func current() -> Self {
        let domain = MACaptionAppearanceDomain.user
        let descriptor = MACaptionAppearanceCopyFontDescriptorForStyle(domain, nil, .default).takeRetainedValue()
        let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String ?? UIFont.systemFont(ofSize: 22).fontName
        let scale = max(0.5, min(3, MACaptionAppearanceGetRelativeCharacterSize(domain, nil)))
        return Self(font: UIFont(name: name, size: 22 * scale) ?? .systemFont(ofSize: 22 * scale),
                    foreground: UIColor(cgColor: MACaptionAppearanceCopyForegroundColor(domain, nil).takeRetainedValue()).withAlphaComponent(MACaptionAppearanceGetForegroundOpacity(domain, nil)),
                    background: UIColor(cgColor: MACaptionAppearanceCopyBackgroundColor(domain, nil).takeRetainedValue()).withAlphaComponent(MACaptionAppearanceGetBackgroundOpacity(domain, nil)),
                    window: UIColor(cgColor: MACaptionAppearanceCopyWindowColor(domain, nil).takeRetainedValue()).withAlphaComponent(MACaptionAppearanceGetWindowOpacity(domain, nil)),
                    relativeSize: scale, edge: MACaptionAppearanceGetTextEdgeStyle(domain, nil))
    }
    func sized(for video: CGSize) -> Self {
        let pointSize = max(12, min(20, video.height * 0.05)) * relativeSize
        return Self(font: font.withSize(pointSize), foreground: foreground, background: background, window: window, relativeSize: relativeSize, edge: edge)
    }
    private func rgb(_ color: UIColor) -> Int {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Int(r * 255) << 16) | (Int(g * 255) << 8) | Int(b * 255)
    }
    var vlcOptions: [String] {
        ["--text-renderer=freetype", "--subsdec-align=0", "--sub-margin=0", "--no-subsdec-formatted",
         "--freetype-font=\(font.fontName)", "--freetype-color=\(rgb(foreground))",
         "--freetype-opacity=\(Int(foreground.cgColor.alpha * 255))",
         "--freetype-background-color=\(rgb(background))", "--freetype-background-opacity=\(Int(background.cgColor.alpha * 255))",
         "--freetype-outline-thickness=\(edge == .none ? 0 : 2)", "--freetype-shadow-opacity=\(edge == .dropShadow ? 180 : 0)"]
    }
    func configure(_ media: VLCMedia) {
        // VLC renders embedded text tracks on its own clock. Map the user's
        // accessibility style to its text renderer; bitmap subtitles keep artwork.
        media.addOption(":text-renderer=freetype")
        media.addOption(":subsdec-align=0")
        media.addOption(":sub-margin=0")
        media.addOption(":subsdec-formatted=false")
        media.addOption(":freetype-font=\(font.fontName)")
        media.addOption(":freetype-color=\(rgb(foreground))")
        media.addOption(":freetype-opacity=\(Int(foreground.cgColor.alpha * 255))")
        media.addOption(":freetype-background-color=\(rgb(background))")
        media.addOption(":freetype-background-opacity=\(Int(background.cgColor.alpha * 255))")
        media.addOption(":freetype-outline-thickness=\(edge == .none ? 0 : 2)")
        media.addOption(":freetype-shadow-opacity=\(edge == .dropShadow ? 180 : 0)")
    }
}

struct DeviceCaptionOverlay: UIViewRepresentable {
    let text: String
    let style: SystemCaptionStyle
    func makeUIView(context: Context) -> UILabel {
        let label = UILabel(); label.numberOfLines = 0; label.textAlignment = .center
        label.adjustsFontForContentSizeCategory = false; label.isUserInteractionEnabled = false
        label.accessibilityLabel = "Subtitles"; label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }
    func updateUIView(_ label: UILabel, context: Context) {
        label.text = text; label.font = style.font; label.textColor = style.foreground
        label.backgroundColor = style.background; label.layer.cornerRadius = 5; label.clipsToBounds = true
        label.shadowColor = style.edge == .none ? nil : .black
        label.shadowOffset = style.edge == .none ? .zero : CGSize(width: 1, height: 1)
        label.semanticContentAttribute = .unspecified
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
        uiView.sizeThatFits(CGSize(width: proposal.width ?? 600, height: .greatestFiniteMagnitude))
    }
}

struct PlayerGlass: ViewModifier {
    var circle = false
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            if circle { content.glassEffect(.regular.interactive(), in: Circle()) }
            else { content.glassEffect(.regular, in: Capsule()) }
        } else {
            if circle { content.background(.ultraThinMaterial, in: Circle()) }
            else { content.background(.ultraThinMaterial, in: Capsule()) }
        }
    }
}
