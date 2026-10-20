import PromiseCore
import SwiftUI

/// "Review your promise" — editable draft cards. Nothing is active until Save.
struct ReviewView: View {
    @Environment(AppModel.self) private var model
    @Binding var drafts: [DraftCommitment]
    let skipped: [SkippedStatement]
    let fallbackReason: ExtractionUnavailableReason?
    @Binding var edited: Bool
    let onSaved: ([Commitment]) -> Void
    let onBack: () -> Void

    @State private var index = 0
    @State private var saveErrors: [UUID: String] = [:]
    @State private var savedCount = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button(action: onBack) { Image(systemName: "chevron.left").font(.title3.weight(.medium)) }
                    .foregroundStyle(Theme.ink)
                    .accessibilityLabel("Back to text")
                ScreenHeader(title: drafts.count > 1 ? "Review your promises" : "Review your promise",
                             subtitle: drafts.count > 1
                                ? "I found \(drafts.count) separate promises. Save the ones you want."
                                : "I’ve found the key details. You can edit anything before saving.")
                if let fallbackReason, fallbackReason != .disabledByUser {
                    NoticeBanner(icon: "wand.and.stars.inverse", text: fallbackReason.userMessage, tint: Theme.inkSecondary)
                }
                ForEach(Array(skipped.enumerated()), id: \.offset) { _, s in
                    NoticeBanner(icon: "info.circle", text: "“\(s.text)” — \(s.explanation)", tint: Theme.waiting)
                }
                if savedCount > 0 {
                    NoticeBanner(icon: "checkmark.circle", text: "\(savedCount) saved. \(drafts.count) still to review.", tint: Theme.calm)
                }
                if drafts.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(drafts.indices, id: \.self) { i in
                                Chip(title: "\(i + 1). \(drafts[i].title.prefix(18))", isSelected: i == index) { index = i }
                            }
                        }
                    }
                }
                if drafts.indices.contains(index) {
                    DraftEditor(draft: $drafts[index], edited: $edited)
                        .id(drafts[index].id)
                    if let error = saveErrors[drafts[index].id] {
                        NoticeBanner(icon: "exclamationmark.triangle", text: error, tint: Theme.urgent)
                    }
                    actions
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 30)
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var actions: some View {
        let current = drafts[index]
        return VStack(spacing: 10) {
            if !current.blockingIssues.isEmpty {
                Text(current.blockingIssues.joined(separator: " "))
                    .font(.footnote).foregroundStyle(Theme.warm)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button { save([current]) } label: {
                Label(drafts.count > 1 ? "Save this promise" : "Save Promise", systemImage: "sparkles")
            }
            .buttonStyle(.primary)
            .disabled(!current.canSave)
            if drafts.count > 1 {
                Button("Save all \(drafts.count)") { save(drafts) }
                    .buttonStyle(.secondary)
                    .disabled(!drafts.allSatisfy(\.canSave))
                Button("Skip this one", role: .destructive) { remove(current.id) }
                    .font(.subheadline)
            }
        }
        .padding(.top, 6)
    }

    private func save(_ list: [DraftCommitment]) {
        let results = model.service.saveAll(list)
        var savedNow: [Commitment] = []
        for (id, result) in results {
            switch result {
            case let .success(c):
                savedNow.append(c)
                saveErrors[id] = nil
                drafts.removeAll { $0.id == id }
            case let .failure(error):
                saveErrors[id] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                if case DatabaseError.limitReached = error { model.showPaywall = true }
            }
        }
        savedCount += savedNow.count
        index = min(index, max(0, drafts.count - 1))
        model.reload()
        if savedNow.contains(where: { $0.hasDeadline || $0.status == .waiting }) {
            Task { await model.ensureNotificationPermission() }
        }
        if !savedNow.isEmpty { onSaved(savedNow) }
    }

    private func remove(_ id: UUID) {
        drafts.removeAll { $0.id == id }
        index = min(index, max(0, drafts.count - 1))
        if drafts.isEmpty { onBack() }
    }
}

/// One editable draft card: Person, What, When, Waiting, Remind me, Notes.
struct DraftEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: DraftCommitment
    @Binding var edited: Bool
    @State private var showDueEditor = false
    @State private var showNewPerson = false
    @State private var newPersonName = ""

    private var selectedPerson: Person? { model.person(draft.personMatch.resolvedPersonId) }

    private var personLabel: String {
        switch draft.personMatch {
        case .none: return "No one in particular"
        case let .new(name): return "\(name) (new)"
        case .ambiguous: return "Which \(draft.recipientName ?? "person")?"
        case .matched, .suggested: return selectedPerson?.displayName ?? "Unknown"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            personField
            FieldCard(icon: "text.alignleft", label: "What", tint: Theme.ink, highlight: draft.uncertainFields.contains(.title)) {
                TextField("What did you promise?", text: Binding(get: { draft.title }, set: { draft.title = $0; edited = true }), axis: .vertical)
                    .font(.subheadline)
            }
            whenField
            if let waiting = draft.waitingOn {
                FieldCard(icon: "hourglass", label: "Depends on", tint: Theme.waiting, highlight: draft.uncertainFields.contains(.waitingOn)) {
                    Toggle(isOn: Binding(get: { draft.startAsWaiting }, set: { draft.startAsWaiting = $0; edited = true })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(waiting).font(.subheadline)
                            Text(draft.startAsWaiting ? "Saved as waiting" : "Saved as open").font(.caption).foregroundStyle(Theme.inkSecondary)
                        }
                    }
                    .tint(Theme.waiting)
                }
            }
            remindField
            FieldCard(icon: "note.text", label: "Notes (optional)") {
                TextField("Add details", text: Binding(get: { draft.notes ?? "" }, set: { draft.notes = $0.isEmpty ? nil : $0; edited = true }), axis: .vertical)
                    .font(.subheadline)
            }
            if !draft.possibleDuplicates.isEmpty {
                NoticeBanner(icon: "square.on.square", text: "This looks like a promise you already have. You can still save it.", tint: Theme.inkSecondary)
            }
            if let span = draft.sourceSpan ?? (draft.rawText.isEmpty ? nil : draft.rawText), span != draft.title {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your words").font(.caption).foregroundStyle(Theme.inkSecondary)
                    Text("“\(span)”").font(.footnote.italic()).foregroundStyle(Theme.inkSecondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .sheet(isPresented: $showDueEditor) {
            DueEditorSheet(initial: draft.selectedDue, phrase: draft.dateResolution.phrase) { due in
                draft.setDue(due)
                edited = true
            }
        }
        .alert("New person", isPresented: $showNewPerson) {
            TextField("Name", text: $newPersonName)
            Button("Add") { draft.createPerson(named: newPersonName); edited = true }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Fields

    private var personField: some View {
        FieldCard(icon: "person", label: "Person", tint: Theme.warm, highlight: draft.personMatch.needsReview) {
            Menu {
                if case let .ambiguous(ids) = draft.personMatch {
                    Section("Did you mean") {
                        ForEach(ids, id: \.self) { id in
                            Button(model.person(id)?.displayName ?? "Unknown") { draft.choosePerson(id); edited = true }
                        }
                    }
                }
                Section {
                    ForEach(model.activePeople.sorted { $0.displayName < $1.displayName }) { p in
                        Button(p.displayName) { draft.choosePerson(p.id); edited = true }
                    }
                }
                Button { newPersonName = draft.recipientName ?? ""; showNewPerson = true } label: { Label("New person…", systemImage: "plus") }
                Button("No one in particular") { draft.choosePerson(nil); edited = true }
            } label: {
                HStack(spacing: 10) {
                    AvatarView(name: selectedPerson?.displayName ?? draft.recipientName, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(personLabel).font(.subheadline).foregroundStyle(Theme.ink)
                        if case .suggested = draft.personMatch, let spoken = draft.recipientName {
                            Text("You said “\(spoken)”").font(.caption).foregroundStyle(Theme.inkSecondary)
                        } else if let suggestion = draft.suggestedRecipient {
                            Text("Suggested: \(suggestion) — not in your words").font(.caption).foregroundStyle(Theme.inkSecondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.down").font(.caption).foregroundStyle(Theme.inkTertiary)
                }
            }
            .accessibilityLabel("Person: \(personLabel)")
        }
    }

    private var dueText: String {
        guard let due = draft.selectedDue else { return draft.dateResolution.phrase.map { "No date (you said “\($0)”)" } ?? "No date" }
        let tz = TimeZone(identifier: due.timezoneId) ?? .current
        switch due.precision {
        case .day, .datetime:
            guard let local = due.local else { return "No date" }
            return model.formatter.absolute(local, timeZone: tz)
        default:
            return model.formatter.short(due: due, now: model.now)
        }
    }

    private var whenField: some View {
        let resolution = draft.dateResolution
        let needsChoice = resolution.needsConfirmation && !draft.dateConfirmed
        return FieldCard(icon: "calendar", label: "When", tint: Theme.urgent, highlight: needsChoice) {
            VStack(alignment: .leading, spacing: 10) {
                Button { showDueEditor = true } label: {
                    Text(dueText).font(.subheadline).foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 28)
                }
                .accessibilityLabel("When: \(dueText). Double tap to change.")
                ForEach(resolution.ambiguities, id: \.self) { note in
                    Label(note.message, systemImage: note.kind.requiresConfirmation ? "questionmark.circle" : "info.circle")
                        .font(.caption)
                        .foregroundStyle(note.kind.requiresConfirmation ? Theme.warm : Theme.inkSecondary)
                }
                if resolution.candidates.count > 1 || needsChoice {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(resolution.candidates, id: \.self) { c in
                                Chip(title: candidateLabel(c), isSelected: draft.dateConfirmed && draft.selectedDue == c.due) {
                                    draft.choose(candidate: c)
                                    edited = true
                                }
                            }
                            Chip(title: "Other…", isSelected: false) { showDueEditor = true }
                        }
                    }
                }
            }
        } accessory: {
            if draft.selectedDue != nil && !needsChoice {
                Button { draft.setDue(nil); edited = true } label: {
                    Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(Theme.inkTertiary)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Remove date")
            }
        }
    }

    private func candidateLabel(_ c: DueCandidate) -> String {
        model.formatter.short(due: c.due, now: model.now)
    }

    private var remindField: some View {
        FieldCard(icon: "bell", label: "Remind me", tint: Theme.ink) {
            Menu {
                Picker("Remind me", selection: Binding(get: { draft.reminderPolicy }, set: { draft.reminderPolicy = $0; edited = true })) {
                    ForEach(ReminderPolicyOption.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            } label: {
                HStack {
                    Text(reminderSummary).font(.subheadline).foregroundStyle(Theme.ink)
                    Spacer()
                    Image(systemName: "chevron.down").font(.caption).foregroundStyle(Theme.inkTertiary)
                }
            }
        }
    }

    private var reminderSummary: String {
        let r = model.settings.reminders
        let time = Calendar.current.date(bySettingHour: r.dateOnlyReminderTime.hour, minute: r.dateOnlyReminderTime.minute, second: 0, of: Date())?
            .formatted(date: .omitted, time: .shortened) ?? ""
        guard let due = draft.selectedDue, due.local != nil else {
            return draft.startAsWaiting ? "Check in every \(r.waitingCheckinDays) days" : "No date, so no reminder"
        }
        if due.precision == .approximate { return draft.reminderPolicy == .none ? "No reminders" : "A check-in near the end" }
        switch draft.reminderPolicy {
        case .none: return "No reminders"
        case .dayBefore: return "The day before at \(due.precision == .datetime ? "the same time" : time)"
        case .onTheDay: return due.precision == .datetime ? "At the time it’s due" : "On the day at \(time)"
        case .dayBeforeAndOnTheDay: return "The day before and on the day"
        case .default:
            var parts: [String] = []
            if r.dayBefore { parts.append("the day before") }
            if r.atDue { parts.append(due.precision == .datetime ? "when it’s due" : "on the day at \(time)") }
            guard !parts.isEmpty else { return "No reminders" }
            let sentence: String = parts.joined(separator: " and ")
            return sentence.prefix(1).uppercased() + String(sentence.dropFirst())
        }
    }
}

/// Choose or change a deadline. Used by Review and by Reschedule on the detail screen.
struct DueEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let initial: Commitment.Due?
    var phrase: String?
    let onSave: (Commitment.Due?) -> Void

    enum Kind: String, CaseIterable, Identifiable {
        case date = "Date", dateTime = "Date & time", period = "Period", none = "No date"
        var id: String { rawValue }
    }

    @State private var kind: Kind = .date
    @State private var date = Date()
    @State private var endDate = Date().addingTimeInterval(6 * 86400)
    @State private var periodLabel = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                switch kind {
                case .date:
                    DatePicker("Due on", selection: $date, displayedComponents: .date).datePickerStyle(.graphical)
                case .dateTime:
                    DatePicker("Due at", selection: $date).datePickerStyle(.graphical)
                case .period:
                    DatePicker("From", selection: $date, displayedComponents: .date)
                    DatePicker("Until", selection: $endDate, in: date..., displayedComponents: .date)
                    TextField("Label (e.g. next week)", text: $periodLabel)
                    Text("A period gives you a check-in near the end, never an overdue alert.")
                        .font(.footnote).foregroundStyle(.secondary)
                case .none:
                    Text("It will stay in Unscheduled until you add a date.").foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .canvasBackground()
            .navigationTitle("When")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { onSave(makeDue()); dismiss() } }
            }
            .onAppear(perform: load)
        }
        .presentationDetents([.large])
    }

    private func load() {
        periodLabel = phrase ?? ""
        guard let initial, let local = initial.local else { kind = initial == nil ? .date : .none; return }
        var cal = Calendar.current
        cal.timeZone = TimeZone(identifier: initial.timezoneId) ?? .current
        date = WallClock.resolve(local, calendar: cal)?.date ?? Date()
        switch initial.precision {
        case .datetime: kind = .dateTime
        case .approximate:
            kind = .period
            if let end = initial.windowEnd, let e = end.startOfDay(in: cal) { endDate = e }
        default: kind = .date
        }
    }

    private func makeDue() -> Commitment.Due? {
        let cal = Calendar.current
        let tz = TimeZone.current.identifier
        switch kind {
        case .none: return nil
        case .date:
            return Commitment.Due(precision: .day, local: LocalDateTime(date, calendar: cal, includeTime: false), timezoneId: tz, phrase: nil)
        case .dateTime:
            return Commitment.Due(precision: .datetime, local: LocalDateTime(date, calendar: cal), timezoneId: tz, phrase: nil)
        case .period:
            return Commitment.Due(precision: .approximate, local: LocalDateTime(date, calendar: cal, includeTime: false),
                                  windowEnd: LocalDateTime(endDate, calendar: cal, includeTime: false), timezoneId: tz,
                                  phrase: periodLabel.isEmpty ? nil : periodLabel)
        }
    }
}
