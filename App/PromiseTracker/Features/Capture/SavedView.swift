import PromiseCore
import SwiftUI

/// "Promise saved" confirmation with the reminder it will get.
struct SavedView: View {
    @Environment(AppModel.self) private var model
    let saved: [Commitment]
    let onAddAnother: () -> Void
    let onView: (UUID) -> Void
    let onDone: () -> Void
    @State private var appeared = false

    private var reminderLine: String {
        guard let first = saved.first else { return "" }
        if saved.count > 1 { return "I’ll remind you before each one is due." }
        if first.status == .waiting {
            let days = first.waitingCheckinDays ?? model.settings.reminders.waitingCheckinDays
            return "I’ll check in with you in \(days) days."
        }
        if first.notificationPolicyId == ReminderPolicyOption.none.rawValue { return "Saved without reminders." }
        guard let local = first.dueLocal else { return "No date yet — you’ll find it under Unscheduled." }
        if first.duePrecision == .approximate { return "I’ll check in near the end of \(first.agreedDueText ?? "that period")." }
        return "I’ll remind you on \(model.formatter.longDay(local, timeZone: first.timeZone))."
    }

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 20)
            ZStack {
                ConfettiView().frame(width: 260, height: 200)
                Image(systemName: "checkmark")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 104, height: 104)
                    .background(Circle().fill(Theme.card).shadow(color: .black.opacity(0.06), radius: 16, y: 6))
                    .scaleEffect(appeared ? 1 : 0.6)
                    .opacity(appeared ? 1 : 0)
            }
            .sensoryFeedback(.success, trigger: appeared)
            VStack(spacing: 10) {
                Text(saved.count > 1 ? "\(saved.count) promises saved" : "Promise saved")
                    .font(Theme.display(.largeTitle)).foregroundStyle(Theme.ink)
                Text(reminderLine).font(.subheadline).foregroundStyle(Theme.inkSecondary).multilineTextAlignment(.center)
            }
            VStack(spacing: 10) {
                ForEach(saved) { c in
                    HStack(spacing: 12) {
                        AvatarView(name: model.personName(for: c), size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                            if let name = model.personName(for: c) { Text(name).font(.footnote).foregroundStyle(Theme.inkSecondary) }
                            Text(c.hasDeadline ? model.formatter.short(c, now: model.now) : "No date")
                                .font(.footnote).foregroundStyle(Theme.urgent)
                        }
                        Spacer()
                    }
                    .card(padding: 14)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, Theme.gutter)
            Spacer()
            VStack(spacing: 12) {
                Button("Add another", action: onAddAnother).buttonStyle(.secondary)
                if saved.count == 1, let first = saved.first {
                    Button("View promise") { onView(first.id) }.buttonStyle(.primary)
                } else {
                    Button("Done", action: onDone).buttonStyle(.primary)
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 20)
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { appeared = true } }
    }
}
