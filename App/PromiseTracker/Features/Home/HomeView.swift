import PromiseCore
import SwiftUI
import UIKit

struct BucketSection: Identifiable {
    let bucket: CommitmentBucket
    let items: [Commitment]
    var id: Int { bucket.rawValue }
}

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: HomeFilter = .all
    @State private var search = ""

    enum HomeFilter: String, CaseIterable, Identifiable {
        case all = "All", upcoming = "Upcoming", overdue = "Overdue", waiting = "Waiting", completed = "Completed"
        var id: String { rawValue }
        var smart: SmartFilter {
            switch self {
            case .all: return .all
            case .upcoming: return .upcoming
            case .overdue: return .overdue
            case .waiting: return .waiting
            case .completed: return .completed
            }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: model.now)
        let part = hour < 12 ? "Good morning" : (hour < 18 ? "Good afternoon" : "Good evening")
        if let name = model.userName?.split(separator: " ").first { return "\(part),\n\(name)" }
        return part
    }

    private var subtitle: String {
        let d = model.digest
        if d.overdue > 0 || d.dueToday > 0 { return d.sentence }
        if d.dueThisWeek > 0 { return "You have \(d.dueThisWeek) \(d.dueThisWeek == 1 ? "promise" : "promises") due this week." }
        let open = model.commitments.filter { $0.status.isActive }.count
        return open == 0 ? "Nothing owed right now." : "Nothing due this week. \(open) open in total."
    }

    private var searchResults: [Commitment] {
        let results = SearchService().search(SearchQuery(text: search), commitments: model.commitments, people: model.people)
        return model.classifier.sorted(results, now: model.now)
    }

    private var sections: [BucketSection] {
        let list = model.commitments.filter { model.classifier.matches($0, filter: filter.smart, now: model.now) }
        if filter == .completed {
            let sorted = list.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            return sorted.isEmpty ? [] : [BucketSection(bucket: .closed, items: sorted)]
        }
        let grouped = Dictionary(grouping: model.classifier.sorted(list, now: model.now)) { model.classifier.bucket($0, now: model.now) }
        return grouped.keys.sorted().map { BucketSection(bucket: $0, items: grouped[$0] ?? []) }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    searchField
                    if search.isEmpty {
                        chips
                        banners
                        if sections.isEmpty { emptyState } else { lists }
                    } else {
                        searchList
                    }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.top, 8)
                .padding(.bottom, 110)
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await model.didBecomeActive() }

            Button {
                model.startCapture(.voice)
            } label: {
                Image(systemName: "plus")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(Theme.onAction)
                    .frame(width: 60, height: 60)
                    .background(Circle().fill(Theme.action))
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
            }
            .padding(.trailing, Theme.gutter)
            .padding(.bottom, 16)
            .accessibilityLabel("Add a promise")
            .accessibilityHint("Opens voice capture. You can also type.")
        }
        .canvasBackground()
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(greeting)
                    .font(Theme.display(.largeTitle))
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle).font(.subheadline).foregroundStyle(Theme.inkSecondary)
            }
            Spacer()
            Button { model.homePath.append(Route.impact) } label: {
                Image(systemName: "chart.pie")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Theme.soft))
            }
            .accessibilityLabel("Your impact")
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.inkTertiary).accessibilityHidden(true)
            TextField("Search promises…", text: $search)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.inkTertiary) }
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background(Capsule().fill(Theme.soft))
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(HomeFilter.allCases) { f in
                    Chip(title: f.rawValue, isSelected: filter == f) { filter = f }
                }
            }
        }
    }

    @ViewBuilder private var banners: some View {
        if model.notificationPermission == .denied {
            NoticeBanner(icon: "bell.slash", text: "Reminders are off, so Promise Tracker can’t nudge you. Your promises are still saved.",
                         actionTitle: "Turn on in Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        }
        if let notice = model.env.recoveryNotice {
            NoticeBanner(icon: "exclamationmark.triangle", text: notice)
        }
    }

    private var lists: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: filter == .completed ? "Completed" : section.bucket.sectionTitle)
                    ForEach(section.items) { c in
                        CommitmentRow(commitment: c)
                    }
                }
            }
        }
    }

    private var searchList: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: searchResults.isEmpty ? "No matches" : "Results")
            ForEach(searchResults) { CommitmentRow(commitment: $0) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: filter == .completed ? "checkmark.seal" : "sparkles")
                .font(.system(size: 36)).foregroundStyle(Theme.gold)
            Text(emptyTitle).font(Theme.display(.title3)).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
            Text(emptyBody).font(.subheadline).foregroundStyle(Theme.inkSecondary).multilineTextAlignment(.center)
            if filter == .all {
                Button("Add your first promise") { model.startCapture(.voice) }
                    .buttonStyle(.primary)
                    .padding(.top, 6)
                Button("Type instead") { model.startCapture(.text) }
                    .font(.subheadline).foregroundStyle(Theme.inkSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var emptyTitle: String {
        switch filter {
        case .all: return "Nothing owed right now"
        case .upcoming: return "Nothing coming up"
        case .overdue: return "Nothing overdue"
        case .waiting: return "Not waiting on anyone"
        case .completed: return "No completed promises yet"
        }
    }

    private var emptyBody: String {
        switch filter {
        case .all: return "Tap + and say what you promised, like “I told Sam I’d send the photos on Friday.”"
        case .overdue: return "You’re on top of things."
        case .waiting: return "When a promise depends on someone else, mark it as waiting."
        default: return ""
        }
    }
}

/// List row: accent bar, avatar, action, person, due badge, quick Done.
struct CommitmentRow: View {
    @Environment(AppModel.self) private var model
    let commitment: Commitment

    private var bucket: CommitmentBucket { model.classifier.bucket(commitment, now: model.now) }

    private var accent: Color {
        switch bucket {
        case .overdue, .dueToday: return Theme.urgent
        case .tomorrow: return Theme.warm
        case .waiting: return Theme.waiting
        case .closed: return Theme.calm
        default: return Theme.cardBorder
        }
    }

    private var dueText: String {
        if commitment.status == .completed, let done = commitment.completedAt {
            return "Completed \(done.formatted(date: .abbreviated, time: .omitted))"
        }
        if commitment.status == .waiting {
            return "Waiting" + (commitment.waitingOnText.map { " on \($0)" } ?? "")
        }
        return model.formatter.short(commitment, now: model.now)
    }

    var body: some View {
        let personName = model.personName(for: commitment)
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 3).padding(.vertical, 6)
            AvatarView(name: personName, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(commitment.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                if let personName {
                    Text(personName).font(.footnote).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                }
                HStack(spacing: 4) {
                    if bucket == .overdue { Image(systemName: "exclamationmark.circle.fill").accessibilityHidden(true) }
                    Text(bucket == .overdue ? "Overdue · \(dueText)" : dueText)
                }
                .font(.footnote)
                .foregroundStyle(bucket == .overdue || bucket == .dueToday ? Theme.urgent : Theme.inkSecondary)
                if let next = commitment.nextAction, commitment.status.isActive {
                    Text("Next: \(next)").font(.caption).foregroundStyle(Theme.inkTertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if commitment.status.isActive {
                Button { model.complete(commitment) } label: {
                    Image(systemName: "circle")
                        .font(.title3)
                        .foregroundStyle(bucket == .overdue ? Theme.urgent : Theme.inkTertiary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Mark done: \(commitment.title)")
                .sensoryFeedback(.success, trigger: commitment.status)
            } else if commitment.status == .completed {
                Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(Theme.calm).frame(width: 44, height: 44)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 8)
        .padding(.trailing, 4)
        .padding(.leading, 8)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.cardBorder, lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture { model.open(.commitment(commitment.id)) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open") { model.open(.commitment(commitment.id)) }
        .accessibilityAction(named: commitment.status.isActive ? "Mark done" : "Reopen") {
            commitment.status.isActive ? model.complete(commitment) : model.reopen(commitment)
        }
        .contextMenu {
            if commitment.status.isActive {
                Button { model.complete(commitment) } label: { Label("Mark done", systemImage: "checkmark") }
                Button { model.snooze(commitment, until: Date().addingTimeInterval(3600)) } label: { Label("Snooze 1 hour", systemImage: "clock") }
            } else {
                Button { model.reopen(commitment) } label: { Label("Reopen", systemImage: "arrow.uturn.backward") }
            }
        }
    }
}
