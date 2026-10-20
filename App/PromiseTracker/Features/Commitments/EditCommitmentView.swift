import PromiseCore
import SwiftUI

struct EditCommitmentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let commitment: Commitment

    @State private var title = ""
    @State private var notes = ""
    @State private var nextAction = ""
    @State private var personId: UUID?
    @State private var priority: Priority = .normal
    @State private var isSensitive = false
    @State private var reminderPolicy: ReminderPolicyOption = .default
    @State private var checkinDays = 3
    @State private var customReminders: [Date] = []
    @State private var newReminder = Date().addingTimeInterval(86400)

    var body: some View {
        NavigationStack {
            Form {
                Section("What") {
                    TextField("Title", text: $title, axis: .vertical)
                    TextField("Next action", text: $nextAction)
                }
                Section("Who") {
                    Picker("Person", selection: $personId) {
                        Text("No one in particular").tag(UUID?.none)
                        ForEach(model.activePeople.sorted { $0.displayName < $1.displayName }) { p in
                            Text(p.displayName).tag(UUID?.some(p.id))
                        }
                    }
                }
                Section("Details") {
                    Picker("Priority", selection: $priority) {
                        Text("Low").tag(Priority.low)
                        Text("Normal").tag(Priority.normal)
                        Text("High").tag(Priority.high)
                    }
                    TextField("Notes", text: $notes, axis: .vertical).lineLimit(3...8)
                    Toggle("Private on lock screen", isOn: $isSensitive)
                }
                Section {
                    Picker("Remind me", selection: $reminderPolicy) {
                        ForEach(ReminderPolicyOption.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    if commitment.status == .waiting {
                        Stepper("Check in every \(checkinDays) days", value: $checkinDays, in: 1...30)
                    }
                } header: {
                    Text("Reminders")
                }
                Section {
                    ForEach(customReminders, id: \.self) { date in
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                    }
                    .onDelete { customReminders.remove(atOffsets: $0) }
                    if model.isPro {
                        DatePicker("Add", selection: $newReminder, in: Date()...)
                        Button("Add reminder") { customReminders.append(newReminder); customReminders.sort() }
                    } else {
                        Button("Extra reminders are part of Pro") { model.showPaywall = true }
                    }
                } header: {
                    Text("Extra reminders")
                }
            }
            .scrollContentBackground(.hidden)
            .canvasBackground()
            .navigationTitle("Edit promise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        title = commitment.title
        notes = commitment.notes ?? ""
        nextAction = commitment.nextAction ?? ""
        personId = commitment.personId
        priority = commitment.priority
        isSensitive = commitment.isSensitive
        reminderPolicy = ReminderPolicyOption(rawValue: commitment.notificationPolicyId) ?? .default
        checkinDays = commitment.waitingCheckinDays ?? model.settings.reminders.waitingCheckinDays
        customReminders = commitment.customReminders
    }

    private func save() {
        let edit = PromiseService.Edit(
            reminderPolicy: reminderPolicy,
            title: title,
            notes: .some(notes.isEmpty ? nil : notes),
            personId: .some(personId),
            priority: priority,
            nextAction: .some(nextAction.isEmpty ? nil : nextAction),
            isSensitive: isSensitive,
            customReminders: customReminders,
            waitingCheckinDays: commitment.status == .waiting ? .some(checkinDays) : nil
        )
        model.perform { try model.service.edit(commitment.id, edit) }
        dismiss()
    }
}
