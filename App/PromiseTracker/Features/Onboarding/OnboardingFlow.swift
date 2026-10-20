import PromiseCore
import SwiftUI

/// Launch → value → Siri & privacy. No sign-up, no permission prompts here;
/// permissions are requested only when a feature is first used (PRD §7.1).
struct OnboardingFlow: View {
    @Environment(AppModel.self) private var model
    @State private var page = 0

    var body: some View {
        switch page {
        case 0: LaunchScreen { withAnimation { page = 1 } }
        case 1: ValueScreen(page: $page)
        default: SiriPrivacyScreen(onFinish: finish)
        }
    }

    private func finish(startCapture: Bool) {
        model.completeOnboarding()
        if startCapture { model.startCapture(.voice) }
    }
}

private struct LaunchScreen: View {
    let onStart: () -> Void

    var body: some View {
        ZStack {
            SunsetScene()
            VStack(spacing: 18) {
                Spacer().frame(height: 80)
                Circle()
                    .stroke(Color.white.opacity(0.95), lineWidth: 3)
                    .frame(width: 86, height: 86)
                    .shadow(color: .white.opacity(0.9), radius: 14)
                    .accessibilityHidden(true)
                Text("Promise Tracker")
                    .font(.system(.largeTitle, design: .serif))
                    .foregroundStyle(.white)
                Text("Never forget what you\npromised.")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                Spacer()
                Button(action: onStart) { Label("Get Started", systemImage: "arrow.right").labelStyle(TrailingIconLabelStyle()) }
                    .buttonStyle(.outline)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 40)
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct ValueScreen: View {
    @Binding var page: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Turn your conversations into commitments.")
                .font(Theme.display(.largeTitle))
                .foregroundStyle(Theme.ink)
                .padding(.top, 40)
            // Interactive sample: what you say → what gets saved.
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    AvatarView(name: "Sarah Chen", size: 40)
                    Text("“I promised Sarah I’d send the proposal by Thursday.”")
                        .font(.subheadline).foregroundStyle(Theme.ink)
                }
                .card(padding: 14)
                Image(systemName: "arrow.down").foregroundStyle(Theme.inkTertiary).accessibilityHidden(true)
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.urgent).frame(width: 3, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Send the proposal").font(.subheadline.weight(.semibold))
                        Text("Sarah · Thursday").font(.footnote).foregroundStyle(Theme.inkSecondary)
                        Text("Reminder the day before").font(.footnote).foregroundStyle(Theme.urgent)
                    }
                    Spacer()
                }
                .card(padding: 14)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Example: you say “I promised Sarah I’d send the proposal by Thursday”, and Promise Tracker saves Send the proposal, for Sarah, due Thursday, with a reminder the day before.")

            VStack(alignment: .leading, spacing: 14) {
                Label("Capture promises in seconds", systemImage: "waveform")
                Label("Get reminded at the right time", systemImage: "checkmark")
                Label("Follow through and build trust", systemImage: "checkmark.seal")
            }
            .font(.subheadline)
            .foregroundStyle(Theme.inkSecondary)

            Spacer()
            Button("Continue") { withAnimation { page = 2 } }.buttonStyle(.primary)
            PageDots(current: 0, count: 2).frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 20)
        .canvasBackground()
    }
}

private struct SiriPrivacyScreen: View {
    let onFinish: (_ startCapture: Bool) -> Void

    var body: some View {
        VStack(spacing: 22) {
            Spacer().frame(height: 30)
            SiriOrb(size: 72)
            ScreenHeader(title: "Use Siri to capture promises",
                         subtitle: "Just speak naturally. Promise Tracker will understand who, what and when.",
                         alignment: .center)
            Text("“Siri, add a promise in Promise Tracker”")
                .font(Theme.display(.title3))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 14) {
                Label("Add commitments with your voice", systemImage: "mic")
                Label("Find and update promises", systemImage: "magnifyingglass")
                Label("Get reminders at the right time", systemImage: "bell")
                Label("Private: no account, no cloud AI", systemImage: "lock")
            }
            .font(.subheadline)
            .foregroundStyle(Theme.inkSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("We’ll ask for microphone and notification access only when you first use them.")
                .font(.footnote).foregroundStyle(Theme.inkTertiary).multilineTextAlignment(.center)
            Spacer()
            Button("Try it now") { onFinish(true) }.buttonStyle(.primary)
            Button("Maybe later") { onFinish(false) }
                .font(.subheadline).foregroundStyle(Theme.inkSecondary).underline()
            PageDots(current: 1, count: 2)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 20)
        .canvasBackground()
    }
}

struct PageDots: View {
    let current: Int
    let count: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Circle().fill(i == current ? Theme.ink : Theme.inkTertiary.opacity(0.4)).frame(width: 6, height: 6)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Page \(current + 1) of \(count)")
    }
}

struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) { configuration.title; configuration.icon }
    }
}
