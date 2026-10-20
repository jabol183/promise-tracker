import PromiseCore
import SwiftUI

/// Month grid with dots on days that have promises, and the selected day's list (#9).
struct PromiseCalendarView: View {
    @Environment(AppModel.self) private var model
    @State private var month = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
    @State private var selected = Calendar.current.startOfDay(for: Date())

    private var cal: Calendar { Calendar.autoupdatingCurrent }

    /// Promises keyed by local start-of-day (approximate periods show on their last day).
    private var byDay: [Date: [Commitment]] {
        var map: [Date: [Commitment]] = [:]
        for c in model.commitments where c.status != .draft && c.status != .archived {
            guard let local = c.duePrecision == .approximate ? (c.dueWindowEnd ?? c.dueLocal) : c.dueLocal,
                  c.duePrecision != .none, let day = local.startOfDay(in: cal) else { continue }
            map[day, default: []].append(c)
        }
        return map
    }

    private var days: [Date?] {
        guard let range = cal.range(of: .day, in: .month, for: month) else { return [] }
        let firstWeekday = cal.component(.weekday, from: month)
        let leading = (firstWeekday - cal.firstWeekday + 7) % 7
        var result: [Date?] = Array(repeating: nil, count: leading)
        for d in range { result.append(cal.date(byAdding: .day, value: d - 1, to: month)) }
        return result
    }

    private var weekdaySymbols: [String] {
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        let start = cal.firstWeekday - 1
        return Array(symbols[start...] + symbols[..<start])
    }

    var body: some View {
        let map = byDay
        ScrollView {
            VStack(spacing: 18) {
                HStack {
                    Button { shift(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Previous month")
                    Spacer()
                    Text(month.formatted(.dateTime.month(.wide).year()))
                        .font(Theme.display(.title2)).foregroundStyle(Theme.ink)
                    Spacer()
                    Button { shift(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("Next month")
                }
                .foregroundStyle(Theme.ink)
                .font(.body.weight(.medium))

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 10) {
                    ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, s in
                        Text(s).font(.caption).foregroundStyle(Theme.inkSecondary).accessibilityHidden(true)
                    }
                    ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                        if let day { dayCell(day, items: map[day] ?? []) } else { Color.clear.frame(height: 40) }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: selected.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                    let items = model.classifier.sorted(map[selected] ?? [], now: model.now)
                    if items.isEmpty {
                        Text("Nothing due this day.").font(.subheadline).foregroundStyle(Theme.inkSecondary)
                    }
                    ForEach(items) { CommitmentRow(commitment: $0) }
                }

                Button("Today") {
                    month = cal.dateInterval(of: .month, for: Date())?.start ?? Date()
                    selected = cal.startOfDay(for: Date())
                }
                .buttonStyle(.primary)
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 30)
        }
        .canvasBackground()
        .toolbar(.hidden, for: .navigationBar)
    }

    private func dayCell(_ day: Date, items: [Commitment]) -> some View {
        let isSelected = cal.isDate(day, inSameDayAs: selected)
        let isToday = cal.isDateInToday(day)
        let dots = Array(items.prefix(3))
        return Button { selected = day } label: {
            VStack(spacing: 3) {
                Text("\(cal.component(.day, from: day))")
                    .font(.subheadline.weight(isToday ? .bold : .regular))
                    .foregroundStyle(isSelected ? Theme.onAction : (isToday ? Theme.urgent : Theme.ink))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(isSelected ? Theme.action : Color.clear))
                HStack(spacing: 2) {
                    ForEach(dots) { c in Circle().fill(dotColor(c)).frame(width: 5, height: 5) }
                }
                .frame(height: 5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(day.formatted(date: .complete, time: .omitted)), \(items.count) \(items.count == 1 ? "promise" : "promises")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func dotColor(_ c: Commitment) -> Color {
        if c.status == .completed { return Theme.calm }
        if model.isOverdue(c) { return Theme.urgent }
        if c.status == .waiting { return Theme.waiting }
        return Theme.gold
    }

    private func shift(_ months: Int) {
        if let m = cal.date(byAdding: .month, value: months, to: month) { month = m }
    }
}
