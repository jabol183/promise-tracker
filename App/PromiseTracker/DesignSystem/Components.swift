import SwiftUI
import PromiseCore

/// Initials avatar with a warm colour derived from the name (no photos are stored).
struct AvatarView: View {
    let name: String?
    var size: CGFloat = 40

    private static let palette: [Color] = [
        Color(light: 0xE8C9A9, dark: 0x6B5240), Color(light: 0xD9B8B0, dark: 0x6A4A45),
        Color(light: 0xC9C6A6, dark: 0x5A5843), Color(light: 0xB9C7C4, dark: 0x45595A),
        Color(light: 0xCDBAD3, dark: 0x5B4A63), Color(light: 0xE3C08F, dark: 0x6E5634),
    ]

    var initials: String {
        guard let name, !name.isEmpty else { return "" }
        let parts = name.split(whereSeparator: { $0.isWhitespace }).prefix(2)
        return parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    var color: Color {
        guard let name else { return Theme.soft }
        let hash = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFFFFFF }
        return Self.palette[hash % Self.palette.count]
    }

    var body: some View {
        ZStack {
            Circle().fill(color)
            if initials.isEmpty {
                Image(systemName: "person.fill").font(.system(size: size * 0.4)).foregroundStyle(Theme.inkSecondary)
            } else {
                Text(initials)
                    .font(.system(size: size * 0.38, weight: .semibold, design: .serif))
                    .foregroundStyle(Theme.ink.opacity(0.8))
                    .minimumScaleFactor(0.5)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The glowing listening ring from the voice-capture screen. Respects Reduce Motion.
struct GlowOrb: View {
    var level: CGFloat = 0
    var size: CGFloat = 220
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color.white.opacity(0.55), Theme.canvas.opacity(0)], center: .center, startRadius: 0, endRadius: size * 0.55))
            Circle()
                .stroke(AngularGradient(colors: [Color(light: 0xF6A06A, dark: 0xF6A06A), Color(light: 0xF2617A, dark: 0xF2617A),
                                                 Color(light: 0xFFE3C4, dark: 0xFFE3C4), Color(light: 0xF6A06A, dark: 0xF6A06A)],
                                        center: .center),
                        lineWidth: 10)
                .blur(radius: 6)
                .rotationEffect(.degrees(rotation))
            Circle()
                .stroke(Color.white.opacity(0.85), lineWidth: 2)
                .padding(4)
        }
        .frame(width: size, height: size)
        .scaleEffect(1 + min(level, 1) * 0.06)
        .animation(.easeOut(duration: 0.12), value: level)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) { rotation = 360 }
        }
        .accessibilityHidden(true)
    }
}

/// Siri-style orb used on the Siri onboarding/settings screens.
struct SiriOrb: View {
    var size: CGFloat = 64
    var body: some View {
        ZStack {
            Circle().fill(Color.black)
            Circle().fill(AngularGradient(colors: [.blue, .purple, .pink, .orange, .cyan, .blue], center: .center))
                .blur(radius: size * 0.12)
                .padding(size * 0.12)
            Circle().fill(RadialGradient(colors: [.white.opacity(0.9), .clear], center: .center, startRadius: 0, endRadius: size * 0.22))
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

/// Live audio waveform: bar heights follow the recent input levels.
struct WaveformView: View {
    var levels: [CGFloat]
    var color: Color = Theme.warm

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                let edgeFade = 1 - abs(CGFloat(index) - CGFloat(levels.count) / 2) / CGFloat(max(levels.count, 1))
                Capsule()
                    .fill(color.opacity(0.35 + 0.65 * edgeFade))
                    .frame(width: 3, height: max(4, 56 * level * edgeFade))
            }
        }
        .frame(height: 60)
        .animation(.easeOut(duration: 0.1), value: levels)
        .accessibilityHidden(true)
    }
}

/// Celebration confetti behind the "Promise saved" check. Static when Reduce Motion is on.
struct ConfettiView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false
    private let pieces: [(x: CGFloat, y: CGFloat, r: Double, c: Color)] = (0..<18).map { i in
        let colors: [Color] = [Theme.urgent, Theme.gold, Theme.waiting, Theme.calm, Theme.warm]
        return (CGFloat((i * 37) % 100) / 100, CGFloat((i * 53) % 100) / 100, Double((i * 47) % 180), colors[i % colors.count])
    }

    var body: some View {
        GeometryReader { geo in
            ForEach(pieces.indices, id: \.self) { i in
                let p = pieces[i]
                RoundedRectangle(cornerRadius: 1)
                    .fill(p.c.opacity(0.8))
                    .frame(width: 5, height: 9)
                    .rotationEffect(.degrees(p.r + (animate ? 40 : 0)))
                    .position(x: p.x * geo.size.width, y: p.y * geo.size.height + (animate ? 8 : 0))
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.4).repeatForever()) { animate = true }
        }
        .accessibilityHidden(true)
    }
}

/// Sunset over mountains, drawn in code for the launch screen.
struct SunsetScene: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.55), Color(red: 0.93, green: 0.70, blue: 0.52),
                                        Color(red: 0.97, green: 0.80, blue: 0.62), Color(red: 0.55, green: 0.40, blue: 0.40)],
                               startPoint: .top, endPoint: .bottom)
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h * 0.72))
                    p.addLine(to: CGPoint(x: w * 0.22, y: h * 0.60))
                    p.addLine(to: CGPoint(x: w * 0.38, y: h * 0.67))
                    p.addLine(to: CGPoint(x: w * 0.58, y: h * 0.55))
                    p.addLine(to: CGPoint(x: w * 0.78, y: h * 0.66))
                    p.addLine(to: CGPoint(x: w, y: h * 0.61))
                    p.addLine(to: CGPoint(x: w, y: h))
                    p.addLine(to: CGPoint(x: 0, y: h))
                    p.closeSubpath()
                }
                .fill(Color(red: 0.42, green: 0.32, blue: 0.36).opacity(0.85))
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h * 0.82))
                    p.addLine(to: CGPoint(x: w * 0.30, y: h * 0.74))
                    p.addLine(to: CGPoint(x: w * 0.52, y: h * 0.80))
                    p.addLine(to: CGPoint(x: w * 0.74, y: h * 0.72))
                    p.addLine(to: CGPoint(x: w, y: h * 0.79))
                    p.addLine(to: CGPoint(x: w, y: h))
                    p.addLine(to: CGPoint(x: 0, y: h))
                    p.closeSubpath()
                }
                .fill(Color(red: 0.25, green: 0.19, blue: 0.23))
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// Status pill that never relies on colour alone (icon + text).
struct StatusPill: View {
    let status: CommitmentStatus
    var isOverdue = false

    private var style: (text: String, icon: String, color: Color) {
        if isOverdue { return ("Overdue", "exclamationmark.circle.fill", Theme.urgent) }
        switch status {
        case .open: return ("Open", "circle", Theme.inkSecondary)
        case .waiting: return ("Waiting", "hourglass", Theme.waiting)
        case .completed: return ("Done", "checkmark.circle.fill", Theme.calm)
        case .cancelled: return ("Cancelled", "xmark.circle", Theme.inkTertiary)
        case .archived: return ("Archived", "archivebox", Theme.inkTertiary)
        case .draft: return ("Draft", "pencil", Theme.inkTertiary)
        }
    }

    var body: some View {
        Label(style.text, systemImage: style.icon)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(style.color)
            .background(Capsule().fill(style.color.opacity(0.12)))
    }
}

/// Undo toast shown after quick actions such as "Done".
struct UndoToast: View {
    let message: String
    let undo: () -> Void

    var body: some View {
        HStack {
            Text(message).font(.subheadline).foregroundStyle(Theme.onAction)
            Spacer()
            Button("Undo", action: undo).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.gold)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Capsule().fill(Theme.action))
        .padding(.horizontal, Theme.gutter)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
