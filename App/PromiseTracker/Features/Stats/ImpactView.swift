import PromiseCore
import SwiftUI

/// Counts only — informative, with no invented productivity score (PRD §7.6).
struct ImpactView: View {
    @Environment(AppModel.self) private var model
    @State private var period: ImpactStats.Period = .month

    var body: some View {
        let stats = ImpactStats.compute(model.commitments, period: period, now: model.now, calendar: .autoupdatingCurrent)
        ScrollView {
            VStack(spacing: 24) {
                Text("Your impact").font(Theme.display(.largeTitle)).foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)
                Picker("Period", selection: $period) {
                    Text("Week").tag(ImpactStats.Period.week)
                    Text("Month").tag(ImpactStats.Period.month)
                    Text("Year").tag(ImpactStats.Period.year)
                }
                .pickerStyle(.segmented)

                ring(stats)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    tile("square.stack", "\(stats.total)", "Total promises", Theme.calm)
                    tile("checkmark", "\(stats.completed)", "Completed", Theme.calm)
                    tile("exclamationmark.circle", "\(stats.overdue)", "Overdue", Theme.urgent)
                    tile("bell", "\(stats.upcoming)", "Upcoming", Theme.waiting)
                }
                if stats.completed > 0 {
                    Text("\(stats.completedOnTime) of \(stats.completed) completed by the agreed date.")
                        .font(.footnote).foregroundStyle(Theme.inkSecondary)
                }

                VStack(spacing: 6) {
                    Text("“People remember what you do.”").font(Theme.display(.title3)).foregroundStyle(Theme.ink)
                    Text("— Build trust, one promise at a time.").font(.footnote).foregroundStyle(Theme.inkSecondary)
                }
                .multilineTextAlignment(.center)
                .padding(.top, 8)

                Button { model.homePath.append(Route.history) } label: { Label("See history", systemImage: "clock.arrow.circlepath") }
                    .buttonStyle(.secondary)
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 30)
        }
        .canvasBackground()
    }

    private func ring(_ stats: ImpactStats) -> some View {
        let rate = stats.keptRate ?? 0
        return ZStack {
            Circle().stroke(Theme.soft, lineWidth: 12)
            Circle().trim(from: 0, to: rate).stroke(Theme.action, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.5), value: rate)
            VStack(spacing: 4) {
                Text(stats.keptRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                    .font(Theme.display(.largeTitle)).foregroundStyle(Theme.ink)
                Text("Promises kept").font(.subheadline).foregroundStyle(Theme.ink)
                Text("\(stats.completed) of \(stats.total - stats.cancelled)").font(.caption).foregroundStyle(Theme.inkSecondary)
            }
        }
        .frame(width: 190, height: 190)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stats.keptRate == nil ? "No promises in this period yet"
                            : "\(stats.completed) of \(stats.total - stats.cancelled) promises kept")
    }

    private func tile(_ icon: String, _ value: String, _ label: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint).accessibilityHidden(true)
            Text(value).font(.title2.weight(.semibold)).foregroundStyle(Theme.ink)
            Text(label).font(.caption).foregroundStyle(Theme.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14)
        .accessibilityElement(children: .combine)
    }
}

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var personFilter: UUID?
    @State private var showCancelled = true

    struct MonthGroup: Identifiable {
        let month: String
        let items: [Commitment]
        var id: String { month }
    }

    private var groups: [MonthGroup] {
        let closed = model.commitments.filter { c in
            (c.status == .completed || (showCancelled && c.status == .cancelled) || c.status == .archived)
                && (personFilter == nil || c.personId == personFilter)
        }
        .sorted { ($0.completedAt ?? $0.cancelledAt ?? $0.updatedAt) > ($1.completedAt ?? $1.cancelledAt ?? $1.updatedAt) }
        var order: [String] = []
        var map: [String: [Commitment]] = [:]
        for c in closed {
            let key = (c.completedAt ?? c.cancelledAt ?? c.updatedAt).formatted(.dateTime.month(.wide).year())
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(c)
        }
        return order.map { MonthGroup(month: $0, items: map[$0] ?? []) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "History", subtitle: "Completed and cancelled promises.")
                HStack {
                    Menu {
                        Button("Everyone") { personFilter = nil }
                        ForEach(model.activePeople.sorted { $0.displayName < $1.displayName }) { p in
                            Button(p.displayName) { personFilter = p.id }
                        }
                    } label: {
                        Label(model.person(personFilter)?.displayName ?? "Everyone", systemImage: "person")
                            .font(.subheadline).padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Capsule().fill(Theme.soft)).foregroundStyle(Theme.ink)
                    }
                    Chip(title: "Include cancelled", isSelected: showCancelled) { showCancelled.toggle() }
                }
                if groups.isEmpty {
                    Text("Finished promises will appear here.").font(.subheadline).foregroundStyle(Theme.inkSecondary)
                }
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(text: "\(group.month) · \(group.items.filter { $0.status == .completed }.count) done")
                        ForEach(group.items) { CommitmentRow(commitment: $0) }
                    }
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 30)
        }
        .canvasBackground()
    }
}
