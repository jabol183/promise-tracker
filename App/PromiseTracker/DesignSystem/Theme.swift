import SwiftUI
import UIKit

/// Warm, calm palette from the design: cream canvas, white cards, ink-black actions.
/// Every token has a dark-mode counterpart.
enum Theme {
    static let canvas = Color(light: 0xF6F0E7, dark: 0x1A1714)
    static let canvasDeep = Color(light: 0xEFE6D9, dark: 0x13110F)
    static let card = Color(light: 0xFFFDF9, dark: 0x26221E)
    static let cardBorder = Color(light: 0xEDE4D7, dark: 0x3A342E)
    static let ink = Color(light: 0x1C1A17, dark: 0xF6EEE2)
    static let inkSecondary = Color(light: 0x7D746A, dark: 0xB5AA9C)
    static let inkTertiary = Color(light: 0xA89E92, dark: 0x8A8074)
    /// Primary action fill (black pill in light mode, cream pill in dark mode).
    static let action = Color(light: 0x141210, dark: 0xF6EEE2)
    static let onAction = Color(light: 0xFFFFFF, dark: 0x141210)
    static let soft = Color(light: 0xEDE6DC, dark: 0x332E29)
    static let urgent = Color(light: 0xD5483B, dark: 0xF0705F)
    static let warm = Color(light: 0xE9813F, dark: 0xF29A5C)
    static let calm = Color(light: 0x4F7C6B, dark: 0x7FB09C)
    static let waiting = Color(light: 0x6C6FB5, dark: 0x9EA1E0)
    static let gold = Color(light: 0xC89B4A, dark: 0xE0B868)

    static let radius: CGFloat = 18
    static let gutter: CGFloat = 20

    /// Serif display type used for headings ("Good morning, Alex").
    static func display(_ style: Font.TextStyle = .largeTitle) -> Font {
        .system(style, design: .serif).weight(.regular)
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self = Color(UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 54)
            .padding(.horizontal, 20)
            .foregroundStyle(Theme.onAction)
            .background(Capsule().fill(Theme.action.opacity(isEnabled ? 1 : 0.35)))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 20)
            .foregroundStyle(Theme.ink)
            .background(Capsule().fill(Theme.soft))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

/// Outlined pill on photographic/gradient backgrounds (launch "Get Started").
struct OutlineButtonStyle: ButtonStyle {
    var color: Color = .white
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundStyle(color)
            .background(Capsule().stroke(color.opacity(0.85), lineWidth: 1.2))
            .background(Capsule().fill(.black.opacity(configuration.isPressed ? 0.25 : 0.12)))
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle { static var primary: PrimaryButtonStyle { .init() } }
extension ButtonStyle where Self == SecondaryButtonStyle { static var secondary: SecondaryButtonStyle { .init() } }
extension ButtonStyle where Self == OutlineButtonStyle { static var outline: OutlineButtonStyle { .init() } }

// MARK: - Surfaces

struct CardModifier: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Theme.cardBorder, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.04), radius: 10, y: 4)
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View { modifier(CardModifier(padding: padding)) }

    /// Cream canvas behind a whole screen.
    func canvasBackground() -> some View {
        background(Theme.canvas.ignoresSafeArea())
    }
}

/// Serif screen heading with optional subtitle, as on Review / Settings / Impact.
struct ScreenHeader: View {
    let title: String
    var subtitle: String?
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 8) {
            Text(title)
                .font(Theme.display(.largeTitle))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(alignment == .center ? .center : .leading)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(alignment == .center ? .center : .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Filter chip ("All", "Upcoming", "Overdue"…).
struct Chip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .foregroundStyle(isSelected ? Theme.onAction : Theme.ink)
                .background(Capsule().fill(isSelected ? Theme.action : Theme.soft))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// Labelled field row used on the Review screen: round icon, caption, value, accessory.
struct FieldCard<Content: View, Accessory: View>: View {
    let icon: String
    let label: String
    var tint: Color = Theme.inkSecondary
    var highlight: Bool = false
    @ViewBuilder var content: Content
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle().fill(tint.opacity(0.14))
                Image(systemName: icon).font(.body.weight(.medium)).foregroundStyle(tint)
            }
            .frame(width: 40, height: 40)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(label).font(.caption).foregroundStyle(Theme.inkSecondary)
                    if highlight {
                        Label("Check", systemImage: "exclamationmark.circle.fill")
                            .labelStyle(.iconOnly)
                            .font(.caption)
                            .foregroundStyle(Theme.warm)
                            .accessibilityLabel("Needs your check")
                    }
                }
                content
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(highlight ? Theme.warm.opacity(0.7) : Theme.cardBorder, lineWidth: highlight ? 1.2 : 0.5))
                    .overlay(alignment: .trailing) { accessory.padding(.trailing, 10) }
            }
        }
    }
}

extension FieldCard where Accessory == EmptyView {
    init(icon: String, label: String, tint: Color = Theme.inkSecondary, highlight: Bool = false, @ViewBuilder content: () -> Content) {
        self.icon = icon
        self.label = label
        self.tint = tint
        self.highlight = highlight
        self.content = content()
        self.accessory = EmptyView()
    }
}

/// Small inline notice ("Basic recognition was used", "Reminders are off").
struct NoticeBanner: View {
    let icon: String
    let text: String
    var tint: Color = Theme.warm
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(text).font(.footnote).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                if let actionTitle, let action {
                    Button(actionTitle, action: action).font(.footnote.weight(.semibold)).foregroundStyle(tint)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tint.opacity(0.10)))
        .accessibilityElement(children: .combine)
    }
}
