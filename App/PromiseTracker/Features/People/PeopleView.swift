import PromiseCore
import SwiftUI

struct PeopleView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var sortByOutstanding = true
    @State private var showAdd = false
    @State private var newName = ""
    @State private var mergeCandidate: (Person, Person)?
    @State private var showMerge = false

    private func openCount(_ p: Person) -> Int { model.commitments.filter { $0.personId == p.id && $0.status.isActive }.count }
    private func waitingCount(_ p: Person) -> Int { model.commitments.filter { $0.personId == p.id && $0.status == .waiting }.count }

    private var people: [Person] {
        let q = TextNormalizer.normalize(search)
        let list = model.activePeople.filter { q.isEmpty || $0.searchableNames.contains { $0.contains(q) } }
        return list.sorted { a, b in
            if sortByOutstanding {
                let (ca, cb) = (openCount(a), openCount(b))
                if ca != cb { return ca > cb }
            }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
    }

    private var mergeSuggestions: [(Person, Person)] { PersonMatcher().mergeSuggestions(in: model.people) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("People").font(Theme.display(.largeTitle)).foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button { newName = ""; showAdd = true } label: {
                        Image(systemName: "plus").font(.body.weight(.medium)).foregroundStyle(Theme.ink)
                            .frame(width: 40, height: 40).background(Circle().fill(Theme.soft))
                    }
                    .accessibilityLabel("Add person")
                }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.inkTertiary).accessibilityHidden(true)
                    TextField("Search people…", text: $search)
                }
                .padding(.horizontal, 14).frame(minHeight: 44).background(Capsule().fill(Theme.soft))
                HStack(spacing: 8) {
                    Chip(title: "Most owed", isSelected: sortByOutstanding) { sortByOutstanding = true }
                    Chip(title: "A–Z", isSelected: !sortByOutstanding) { sortByOutstanding = false }
                }

                ForEach(Array(mergeSuggestions.prefix(2).enumerated()), id: \.offset) { _, pair in
                    NoticeBanner(icon: "person.2.circle", text: "“\(pair.0.displayName)” and “\(pair.1.displayName)” might be the same person.",
                                 tint: Theme.waiting, actionTitle: "Review") {
                        mergeCandidate = pair
                        showMerge = true
                    }
                }

                if people.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "person.2").font(.system(size: 34)).foregroundStyle(Theme.gold)
                        Text(search.isEmpty ? "People you promise things to appear here." : "No one matches “\(search)”.")
                            .font(.subheadline).foregroundStyle(Theme.inkSecondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
                }

                ForEach(people) { p in
                    Button { model.peoplePath.append(Route.person(p.id)) } label: {
                        HStack(spacing: 12) {
                            AvatarView(name: p.displayName, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.displayName).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                                Text(summary(p)).font(.footnote).foregroundStyle(Theme.inkSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.inkTertiary)
                        }
                        .card(padding: 12)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 30)
        }
        .canvasBackground()
        .toolbar(.hidden, for: .navigationBar)
        .alert("Add person", isPresented: $showAdd) {
            TextField("Name", text: $newName)
            Button("Add") {
                guard model.entitlements.canCreatePerson(count: model.activePeople.count) else {
                    model.errorMessage = model.entitlements.peopleLimitMessage
                    model.showPaywall = true
                    return
                }
                model.perform { try model.service.createPerson(named: newName) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("No Contacts access needed.")
        }
        .confirmationDialog("Merge these people?", isPresented: $showMerge, titleVisibility: .visible, presenting: mergeCandidate) { pair in
            Button("Keep “\(pair.1.displayName)”, merge “\(pair.0.displayName)” into it") {
                model.perform { try model.service.mergePeople(source: pair.0.id, into: pair.1.id) }
            }
            Button("Keep “\(pair.0.displayName)”, merge “\(pair.1.displayName)” into it") {
                model.perform { try model.service.mergePeople(source: pair.1.id, into: pair.0.id) }
            }
            Button("They’re different people", role: .cancel) {}
        } message: { _ in
            Text("All promises move to the person you keep. The other name becomes an alias.")
        }
    }

    private func summary(_ p: Person) -> String {
        let open = openCount(p), waiting = waitingCount(p)
        if open == 0 { return p.relationship ?? "Nothing owed" }
        var s = "\(open) open"
        if waiting > 0 { s += " · \(waiting) waiting" }
        return s
    }
}

struct PersonDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let id: UUID
    @State private var tab = 0
    @State private var showEdit = false
    @State private var confirmDelete = false

    private var person: Person? { model.person(id) }
    private var items: [Commitment] { model.commitments.filter { $0.personId == id || $0.waitingOnPersonId == id } }

    var body: some View {
        Group {
            if let person { content(person) }
            else { ContentUnavailableView("Person not found", systemImage: "person.crop.circle.badge.questionmark") }
        }
        .canvasBackground()
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(_ p: Person) -> some View {
        let upcoming = model.classifier.sorted(items.filter { $0.status == .open }, now: model.now)
        let waiting = items.filter { $0.status == .waiting }
        let done = items.filter { $0.status.isClosed }.sorted { ($0.completedAt ?? $0.updatedAt) > ($1.completedAt ?? $1.updatedAt) }
        return ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 8) {
                    AvatarView(name: p.displayName, size: 88)
                    Text(p.displayName).font(Theme.display(.title)).foregroundStyle(Theme.ink)
                    if let rel = p.relationship { Text(rel).font(.subheadline).foregroundStyle(Theme.inkSecondary) }
                }
                HStack(spacing: 28) {
                    contactButton("message", "Message", p.phone.flatMap { URL(string: "sms:\(digits($0))") })
                    contactButton("phone", "Call", p.phone.flatMap { URL(string: "tel:\(digits($0))") })
                    contactButton("envelope", "Email", p.email.flatMap { URL(string: "mailto:\($0)") })
                    Button { showEdit = true } label: { contactLabel("info.circle", "Details") }
                        .buttonStyle(.plain)
                }
                Picker("View", selection: $tab) {
                    Text("Promises").tag(0)
                    Text("Activity").tag(1)
                }
                .pickerStyle(.segmented)

                if tab == 0 {
                    group("Upcoming", upcoming)
                    group("Waiting", waiting)
                    group("Completed", Array(done.prefix(20)))
                    if items.isEmpty {
                        Text("No promises to \(p.displayName) yet.").font(.subheadline).foregroundStyle(Theme.inkSecondary).padding(.vertical, 20)
                    }
                } else {
                    activity
                }

                Button { model.startCapture(.voice, personId: p.id) } label: { Label("New promise", systemImage: "plus") }
                    .buttonStyle(.primary)
                    .padding(.top, 6)
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 30)
        }
        .sheet(isPresented: $showEdit) { EditPersonView(person: p).environment(model) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showEdit = true } label: { Label("Edit details", systemImage: "pencil") }
                    Button { model.perform { try model.service.updatePerson(p.id, isArchived: true) }; dismiss() } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete person", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle").foregroundStyle(Theme.ink) }
                .accessibilityLabel("More")
            }
        }
        .confirmationDialog("Delete \(p.displayName)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete person", role: .destructive) {
                model.perform { try model.service.deletePerson(p.id) }
                dismiss()
            }
        } message: {
            Text("Their promises stay, marked “For \(p.displayName)”.")
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ list: [Commitment]) -> some View {
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: title)
                ForEach(list) { CommitmentRow(commitment: $0) }
            }
        }
    }

    private var activity: some View {
        let events = items.flatMap { c in model.events(for: c.id).map { PersonEvent(title: c.title, event: $0) } }
            .sorted { $0.event.occurredAt > $1.event.occurredAt }.prefix(40)
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(events)) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(TimelineSection.describe(item.event)) · \(item.title)").font(.subheadline).foregroundStyle(Theme.ink)
                    Text(item.event.occurredAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(Theme.inkSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
            if events.isEmpty { Text("No activity yet.").font(.subheadline).foregroundStyle(Theme.inkSecondary) }
        }
    }

    private func digits(_ phone: String) -> String { phone.filter { $0.isNumber || $0 == "+" } }

    private func contactButton(_ icon: String, _ label: String, _ url: URL?) -> some View {
        Button {
            // Opens the system app only on an explicit tap; nothing is sent automatically.
            if let url { openURL(url) } else { showEdit = true }
        } label: {
            contactLabel(icon, label).opacity(url == nil ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityHint(url == nil ? "Add contact details first" : "Opens the \(label) app")
    }

    private func contactLabel(_ icon: String, _ label: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.body).foregroundStyle(Theme.ink)
                .frame(width: 44, height: 44).background(Circle().fill(Theme.card))
                .overlay(Circle().stroke(Theme.cardBorder, lineWidth: 0.5))
            Text(label).font(.caption).foregroundStyle(Theme.inkSecondary)
        }
    }
}

struct EditPersonView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let person: Person
    @State private var name = ""
    @State private var relationship = ""
    @State private var aliases = ""
    @State private var phone = ""
    @State private var email = ""
    @State private var notes = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $name)
                    TextField("Relationship (e.g. Client · Chen Creative)", text: $relationship)
                    TextField("Also known as (comma separated)", text: $aliases)
                }
                Section {
                    TextField("Phone", text: $phone).keyboardType(.phonePad).textContentType(.telephoneNumber)
                    TextField("Email", text: $email).keyboardType(.emailAddress).textContentType(.emailAddress).textInputAutocapitalization(.never)
                } header: { Text("Contact (optional)") } footer: {
                    Text("Stored only on this iPhone. Used when you tap Message, Call or Email.")
                }
                Section("Notes") { TextField("Notes", text: $notes, axis: .vertical).lineLimit(3...8) }
            }
            .scrollContentBackground(.hidden)
            .canvasBackground()
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.perform {
                            try model.service.updatePerson(person.id, displayName: name,
                                                           aliases: aliases.split(separator: ",").map(String.init),
                                                           notes: .some(notes.isEmpty ? nil : notes), phone: .some(phone),
                                                           email: .some(email), relationship: .some(relationship))
                        }
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                name = person.displayName
                relationship = person.relationship ?? ""
                aliases = person.aliases.joined(separator: ", ")
                phone = person.phone ?? ""
                email = person.email ?? ""
                notes = person.notes ?? ""
            }
        }
    }
}

struct PersonEvent: Identifiable {
    let title: String
    let event: ActivityEvent
    var id: UUID { event.id }
}
