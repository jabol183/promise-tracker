import PromiseCore
import SwiftUI

struct CommitmentDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let id: UUID

    @State private var showEdit = false
    @State private var showReschedule = false
    @State private var showWaiting = false
    @State private var waitingText = ""
    @State private var showCancel = false
    @State private var cancelReason = ""
    @State private var confirmDelete = false
    @State private var showCustomSnooze = false
    @State private var customSnooze = Date().addingTimeInterval(3600)

    private var commitment: Commitment? { model.commitment(id) }

    var body: some View {
        Group {
            if let c = commitment {
                content(c)
            } else {
                ContentUnavailableView("Promise not found", systemImage: "questionmark.circle",
                                       description: Text("It may have been deleted."))
            }
        }
        .canvasBackground()
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func content(_ c: Commitment) -> some View {
        let person = model.person(c.personId)
        let overdue = model.isOverdue(c)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Title & who
                VStack(alignment: .leading, spacing: 12) {
                    StatusPill(status: c.status, isOverdue: overdue)
                    Text(c.title)
                        .font(Theme.display(.largeTitle))
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    if let person {
                        Button { model.open(.person(person.id)) } label: {
                            HStack(spacing: 10) {
                                AvatarView(name: person.displayName, size: 32)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Promised to").font(.caption).foregroundStyle(Theme.inkSecondary)
                                    Text(person.displayName).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                                }
                            }
                        }
                        .accessibilityLabel("Promised to \(person.displayName)")
                    } else if let context = c.context {
                        Text(context).font(.subheadline).foregroundStyle(Theme.inkSecondary)
                    }
                }

                // Due & reminder
                VStack(alignment: .leading, spacing: 10) {
                    detailRow("calendar", "Due", dueDescription(c), tint: overdue ? Theme.urgent : Theme.ink)
                    if let reason = model.classifier.overdueReason(c, now: model.now) {
                        Text(reason).font(.footnote).foregroundStyle(Theme.urgent)
                    }
                    if c.duePrecision == .approximate {
                        Text("This is a period, not a hard deadline, so it never shows as overdue.")
                            .font(.footnote).foregroundStyle(Theme.inkSecondary)
                    }
                    detailRow("bell", "Next reminder", nextReminder(c, personName: person?.displayName))
                    if c.timezoneId != TimeZone.current.identifier, c.hasDeadline {
                        Button("Keep the same clock time here (\(TimeZone.current.identifier))") {
                            model.perform { try model.service.moveDeadline(c.id, toTimeZone: TimeZone.current.identifier) }
                        }
                        .font(.footnote)
                    }
                }
                .card()

                if c.status == .waiting || c.nextAction != nil || c.waitingOnText != nil {
                    VStack(alignment: .leading, spacing: 10) {
                        if let waiting = c.waitingOnText { detailRow("hourglass", "Waiting on", waiting, tint: Theme.waiting) }
                        if let next = c.nextAction { detailRow("arrow.turn.down.right", "Next action", next) }
                    }
                    .card()
                }

                if let notes = c.notes, !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Notes").font(.caption).foregroundStyle(Theme.inkSecondary)
                        Text(notes).font(.body).foregroundStyle(Theme.ink)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
                }

                if !c.originalInput.isEmpty, c.originalInput != c.title {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Your words", systemImage: c.sourceType == .voice ? "waveform" : "text.quote")
                            .font(.caption).foregroundStyle(Theme.inkSecondary)
                        Text("“\(c.originalInput)”").font(.body.italic()).foregroundStyle(Theme.ink)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
                }

                actions(c)

                TimelineSection(events: model.events(for: c.id))
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 40)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { moreMenu(c) }
        }
        .sheet(isPresented: $showEdit) { EditCommitmentView(commitment: c).environment(model) }
        .sheet(isPresented: $showReschedule) {
            DueEditorSheet(initial: c.hasDeadline || c.duePrecision == .approximate ? c.due : nil, phrase: c.agreedDueText) { due in
                model.perform { try model.service.reschedule(c.id, to: due) }
            }
        }
        .sheet(isPresented: $showCustomSnooze) {
            NavigationStack {
                Form { DatePicker("Remind me at", selection: $customSnooze, in: Date()...) }
                    .navigationTitle("Snooze")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showCustomSnooze = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Snooze") { model.snooze(c, until: customSnooze); showCustomSnooze = false }
                        }
                    }
            }
            .presentationDetents([.medium])
        }
        .alert("Waiting on…", isPresented: $showWaiting) {
            TextField("e.g. Legal approval", text: $waitingText)
            Button("Mark waiting") { model.perform { try model.service.markWaiting(c.id, on: waitingText.isEmpty ? nil : waitingText) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Waiting promises get check-ins instead of overdue alerts.")
        }
        .alert("Cancel this promise?", isPresented: $showCancel) {
            TextField("Reason (optional)", text: $cancelReason)
            Button("Cancel promise", role: .destructive) {
                model.perform { try model.service.setStatus(c.id, .cancelled, reason: cancelReason.isEmpty ? nil : cancelReason) }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("It moves to History and its reminders stop. You can reopen it later.")
        }
        .confirmationDialog("Delete this promise?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                model.delete(c)
                dismiss()
            }
        } message: {
            Text("This removes it and its history from this iPhone. This can’t be undone.")
        }
    }

    private func actions(_ c: Commitment) -> some View {
        VStack(spacing: 12) {
            if c.status.isActive {
                Button { model.complete(c) } label: { Label("Mark as done", systemImage: "checkmark") }
                    .buttonStyle(.primary)
                HStack(spacing: 10) {
                    Button { showEdit = true } label: { Label("Edit", systemImage: "pencil") }.buttonStyle(.secondary)
                    Menu {
                        Button("In 1 hour") { model.snooze(c, until: Date().addingTimeInterval(3600)) }
                        Button("This evening") { model.snooze(c, until: at(hour: 19, daysFromNow: 0)) }
                        Button("Tomorrow morning") { model.snooze(c, until: at(hour: 9, daysFromNow: 1)) }
                        Button("Next week") { model.snooze(c, until: at(hour: 9, daysFromNow: 7)) }
                        Button("Choose…") { customSnooze = Date().addingTimeInterval(3600); showCustomSnooze = true }
                    } label: {
                        Label("Snooze", systemImage: "clock")
                            .font(.body.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .foregroundStyle(Theme.ink)
                            .background(Capsule().fill(Theme.soft))
                    }
                    Button { showReschedule = true } label: { Label("Reschedule", systemImage: "calendar") }.buttonStyle(.secondary)
                }
                .labelStyle(CompactLabelStyle())
                Button { model.open(.followUp(c.id)) } label: {
                    Label("Draft a follow-up message", systemImage: "text.bubble")
                }
                .font(.subheadline).foregroundStyle(Theme.inkSecondary)
            } else {
                Button { model.reopen(c) } label: { Label("Reopen", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(.primary)
                if c.status == .completed {
                    Button { model.open(.followUp(c.id)) } label: { Label("Let them know it’s done", systemImage: "text.bubble") }
                        .buttonStyle(.secondary)
                }
            }
        }
    }

    private func moreMenu(_ c: Commitment) -> some View {
        Menu {
            if c.status == .open {
                Button { waitingText = c.waitingOnText ?? ""; showWaiting = true } label: { Label("Mark as waiting", systemImage: "hourglass") }
            } else if c.status == .waiting {
                Button { model.perform { try model.service.setStatus(c.id, .open) } } label: { Label("No longer waiting", systemImage: "play") }
            }
            Button { model.perform { try model.service.edit(c.id, .init(isPinned: !c.isPinned)) } } label: {
                Label(c.isPinned ? "Unpin" : "Pin", systemImage: c.isPinned ? "pin.slash" : "pin")
            }
            Button { model.perform { try model.service.duplicate(c.id) } } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            if c.status.isActive {
                Button(role: .destructive) { cancelReason = ""; showCancel = true } label: { Label("Cancel promise", systemImage: "xmark.circle") }
            }
            if c.status.isClosed {
                Button { model.perform { try model.service.setStatus(c.id, .archived) } } label: { Label("Archive", systemImage: "archivebox") }
            }
            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis.circle").foregroundStyle(Theme.ink)
        }
        .accessibilityLabel("More actions")
    }

    private func detailRow(_ icon: String, _ label: String, _ value: String, tint: Color = Theme.ink) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.inkSecondary).frame(width: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(Theme.inkSecondary)
                Text(value).font(.subheadline).foregroundStyle(tint)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func dueDescription(_ c: Commitment) -> String {
        switch c.duePrecision {
        case .day, .datetime:
            guard let local = c.dueLocal else { return "No date" }
            var text = model.formatter.absolute(local, timeZone: c.timeZone)
            if let phrase = c.agreedDueText { text += " · you said “\(phrase)”" }
            return text
        case .approximate:
            return model.formatter.short(c, now: model.now)
        case .eventLinked:
            return c.agreedDueText ?? "Linked to an event"
        case .none, .relative:
            return c.agreedDueText.map { "No date (you said “\($0)”)" } ?? "No date"
        }
    }

    private func nextReminder(_ c: Commitment, personName: String?) -> String {
        guard c.status.isActive else { return "None — this promise is closed" }
        if model.notificationPermission == .denied { return "Notifications are off in iOS Settings" }
        let planner = ReminderPlanner(settings: model.settings.reminders, calendar: model.calendar, isPro: model.isPro)
        guard let next = planner.plan(for: c, personName: personName, now: Date()).first else { return "None scheduled" }
        return next.scheduledAt.formatted(date: .abbreviated, time: .shortened) + " · " + next.title
    }

    private func at(hour: Int, daysFromNow: Int) -> Date {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: daysFromNow, to: cal.startOfDay(for: Date())) ?? Date()
        let target = cal.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? Date()
        return target > Date() ? target : target.addingTimeInterval(86400)
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 2) {
            configuration.icon
            configuration.title.font(.caption)
        }
    }
}

/// Activity timeline: why reminders fired, when dates changed.
struct TimelineSection: View {
    let events: [ActivityEvent]
    @State private var expanded = false

    var body: some View {
        if !events.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(text: "Activity")
                let shown: [ActivityEvent] = expanded ? Array(events.reversed()) : Array(events.reversed().prefix(4))
                ForEach(shown) { e in
                    HStack(alignment: .top, spacing: 12) {
                        Circle().fill(Theme.inkTertiary).frame(width: 7, height: 7).padding(.top, 6).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.describe(e)).font(.subheadline).foregroundStyle(Theme.ink)
                            Text(e.occurredAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(Theme.inkSecondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                if events.count > 4 {
                    Button(expanded ? "Show less" : "Show all \(events.count)") { expanded.toggle() }
                        .font(.footnote.weight(.semibold)).foregroundStyle(Theme.inkSecondary)
                }
            }
        }
    }

    static func describe(_ e: ActivityEvent) -> String {
        let via = e.source == .siri ? " with Siri" : ""
        switch e.eventType {
        case .created: return e.payload["duplicatedFrom"] != nil ? "Duplicated" : "Saved\(via)"
        case .edited: return "Edited"
        case .rescheduled: return "Date changed"
        case .reminded: return "Reminder delivered"
        case .snoozed: return "Snoozed"
        case .statusChanged:
            if e.payload["to"] == "waiting" { return "Marked as waiting" + ((e.payload["on"]).flatMap { $0.isEmpty ? nil : " on \($0)" } ?? "") }
            if e.payload["to"] == "cancelled" { return "Cancelled" + (e.payload["reason"].map { ": \($0)" } ?? "") }
            if e.payload["to"] == "archived" { return "Archived" }
            return "Status changed to \(e.payload["to"] ?? "")"
        case .completed: return "Marked done\(via)"
        case .reopened: return "Reopened"
        case .personLinked: return "Linked to \(e.payload["person"] ?? "a person")"
        case .followupDrafted: return "Follow-up drafted"
        case .exported: return "Exported"
        case .deleted: return "Deleted"
        }
    }
}
