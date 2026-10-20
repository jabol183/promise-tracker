import AppIntents
import PromiseCore
import StoreKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("appearance") private var appearance = AppearancePreference.system.rawValue
    @State private var editingName = false
    @State private var nameDraft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Settings").font(Theme.display(.largeTitle)).foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)

                Button { nameDraft = model.userName ?? ""; editingName = true } label: {
                    HStack(spacing: 14) {
                        AvatarView(name: model.userName, size: 52)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.userName ?? "Add your name").font(.headline).foregroundStyle(Theme.ink)
                            Text("Stored on this iPhone only").font(.footnote).foregroundStyle(Theme.inkSecondary)
                            Text(model.isPro ? "Pro plan · Active" : "Free plan").font(.footnote.weight(.medium))
                                .foregroundStyle(model.isPro ? Theme.calm : Theme.inkSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.inkTertiary)
                    }
                    .card(padding: 14)
                }
                .buttonStyle(.plain)

                group {
                    link("Siri & Shortcuts", "mic.fill", .purple) { SiriSettingsView() }
                    link("Notifications", "bell.badge.fill", .red) { NotificationSettingsView() }
                    link("Preferences", "slider.horizontal.3", .orange) { PreferencesView() }
                    HStack {
                        icon("circle.lefthalf.filled", .indigo)
                        Picker("Appearance", selection: $appearance) {
                            ForEach(AppearancePreference.allCases) { Text($0.label).tag($0.rawValue) }
                        }
                        .tint(Theme.inkSecondary)
                    }
                    .padding(.vertical, 6)
                    link("Sync", "icloud.fill", .teal, detail: "This iPhone only") { SyncInfoView() }
                }

                group {
                    link(model.isPro ? "Subscription" : "Upgrade to Pro", "star.fill", .yellow) { SubscriptionView() }
                    link("Your data", "externaldrive.fill", .gray) { DataSettingsView() }
                    link("Privacy & diagnostics", "hand.raised.fill", .blue) { PrivacyView() }
                }

                group {
                    if let url = AppConfig.supportURL {
                        Link(destination: url) { row("Help & Support", "questionmark.circle", .gray) }
                    }
                    if let url = AppConfig.appStoreURL {
                        ShareLink(item: url) { row("Share Promise Tracker", "square.and.arrow.up", .gray) }
                    }
                    link("History", "clock.arrow.circlepath", .gray) { HistoryView() }
                }

                Text("Promise Tracker \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .font(.caption).foregroundStyle(Theme.inkTertiary).frame(maxWidth: .infinity)
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 30)
        }
        .canvasBackground()
        .toolbar(.hidden, for: .navigationBar)
        .alert("Your name", isPresented: $editingName) {
            TextField("Name", text: $nameDraft).textContentType(.givenName)
            Button("Save") { model.setUserName(nameDraft) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Used for greetings and to sign follow-up drafts.")
        }
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) { content() }.card(padding: 12)
    }

    private func icon(_ name: String, _ color: Color) -> some View {
        Image(systemName: name).font(.footnote.weight(.semibold)).foregroundStyle(.white)
            .frame(width: 28, height: 28).background(RoundedRectangle(cornerRadius: 7).fill(color.gradient))
            .accessibilityHidden(true)
    }

    private func row(_ title: String, _ systemImage: String, _ color: Color, detail: String? = nil) -> some View {
        HStack(spacing: 12) {
            icon(systemImage, color)
            Text(title).font(.subheadline).foregroundStyle(Theme.ink)
            Spacer()
            if let detail { Text(detail).font(.footnote).foregroundStyle(Theme.inkSecondary) }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.inkTertiary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func link<D: View>(_ title: String, _ systemImage: String, _ color: Color, detail: String? = nil,
                               @ViewBuilder destination: @escaping () -> D) -> some View {
        NavigationLink { destination().environment(model) } label: { row(title, systemImage, color, detail: detail) }
            .buttonStyle(.plain)
    }
}

/// Release configuration. Fill these in before App Store submission.
enum AppConfig {
    static let supportURL: URL? = nil       // e.g. URL(string: "https://example.com/support")
    static let privacyPolicyURL: URL? = nil
    static let termsURL: URL? = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")
    static let appStoreURL: URL? = nil
}

// MARK: - Notifications

struct NotificationSettingsView: View {
    @Environment(AppModel.self) private var model

    private func binding<T>(_ keyPath: WritableKeyPath<ReminderSettings, T>) -> Binding<T> {
        Binding(get: { model.settings.reminders[keyPath: keyPath] },
                set: { value in model.updateSettings { $0.reminders[keyPath: keyPath] = value } })
    }

    private func timeBinding(_ keyPath: WritableKeyPath<ReminderSettings, TimeOfDay>) -> Binding<Date> {
        Binding(get: {
            let t = model.settings.reminders[keyPath: keyPath]
            return Calendar.current.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            model.updateSettings { $0.reminders[keyPath: keyPath] = TimeOfDay(hour: c.hour ?? 9, minute: c.minute ?? 0) }
        })
    }

    var body: some View {
        Form {
            Section {
                switch model.notificationPermission {
                case .authorized:
                    Label("Notifications are on", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.calm)
                case .denied:
                    Label("Notifications are off for Promise Tracker", systemImage: "bell.slash").foregroundStyle(Theme.urgent)
                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                case .notDetermined:
                    Button("Allow reminders") { Task { await model.ensureNotificationPermission() } }
                }
            } footer: {
                Text("iOS decides exactly when notifications appear. Focus modes may delay them.")
            }

            Section("Default reminders") {
                Toggle("The day before", isOn: binding(\.dayBefore))
                Toggle("When it’s due", isOn: binding(\.atDue))
                proToggle("An hour before", binding(\.hourBefore))
                proToggle("One nudge if overdue", binding(\.overdueNudge))
                DatePicker("Time for date-only promises", selection: timeBinding(\.dateOnlyReminderTime), displayedComponents: .hourAndMinute)
            }
            Section {
                Stepper("Check in every \(model.settings.reminders.waitingCheckinDays) days", value: binding(\.waitingCheckinDays), in: 1...30)
                Toggle("Check in on “next week”-style promises", isOn: binding(\.approximateCheckins))
            } header: { Text("Waiting & periods") } footer: {
                Text("Waiting promises are never marked overdue.")
            }
            Section {
                if model.isPro {
                    Toggle("Daily briefing", isOn: binding(\.dailyDigestEnabled))
                    if model.settings.reminders.dailyDigestEnabled {
                        DatePicker("Briefing time", selection: timeBinding(\.dailyDigestTime), displayedComponents: .hourAndMinute)
                    }
                } else {
                    Button("Daily briefing is part of Pro") { model.showPaywall = true }
                }
            } header: { Text("Briefing") } footer: {
                Text("A morning summary like “2 due today, 1 overdue”. Counts come straight from your list.")
            }
        }
        .scrollContentBackground(.hidden)
        .canvasBackground()
        .navigationTitle("Notifications")
        .task { await model.refreshPermissions() }
    }

    @ViewBuilder
    private func proToggle(_ title: String, _ binding: Binding<Bool>) -> some View {
        if model.isPro {
            Toggle(title, isOn: binding)
        } else {
            Button { model.showPaywall = true } label: {
                HStack { Text(title).foregroundStyle(Theme.ink); Spacer(); Text("Pro").font(.caption.weight(.semibold)).foregroundStyle(Theme.gold) }
            }
        }
    }
}

// MARK: - Preferences

struct PreferencesView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("useOnDeviceAI") private var useOnDeviceAI = true

    private func binding<T>(_ keyPath: WritableKeyPath<DateInterpretationPreferences, T>) -> Binding<T> {
        Binding(get: { model.settings.dates[keyPath: keyPath] },
                set: { value in model.updateSettings { $0.dates[keyPath: keyPath] = value } })
    }

    private var endOfDay: Binding<Date?> {
        Binding(get: {
            model.settings.dates.endOfDayTime.flatMap { Calendar.current.date(bySettingHour: $0.hour, minute: $0.minute, second: 0, of: Date()) }
        }, set: { date in
            model.updateSettings {
                $0.dates.endOfDayTime = date.map {
                    let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                    return TimeOfDay(hour: c.hour ?? 17, minute: c.minute ?? 0)
                }
            }
        })
    }

    var body: some View {
        Form {
            Section {
                Picker("“Friday”, said on a Friday", selection: binding(\.sameWeekdayPolicy)) {
                    Text("Means today").tag(SameWeekdayPolicy.today)
                    Text("Means next week").tag(SameWeekdayPolicy.nextWeek)
                }
                Picker("“Next Thursday”", selection: binding(\.nextWeekdayPolicy)) {
                    Text("Ask me each time").tag(NextWeekdayPolicy.ask)
                    Text("The nearest Thursday").tag(NextWeekdayPolicy.nearest)
                    Text("Thursday of next week").tag(NextWeekdayPolicy.followingWeek)
                }
                Toggle("Set an end-of-day time", isOn: Binding(get: { endOfDay.wrappedValue != nil },
                                                               set: { endOfDay.wrappedValue = $0 ? Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: Date()) : nil }))
                if let value = endOfDay.wrappedValue {
                    DatePicker("“End of day” means", selection: Binding(get: { value }, set: { endOfDay.wrappedValue = $0 }), displayedComponents: .hourAndMinute)
                }
            } header: { Text("Reading dates") } footer: {
                Text("Dates are always worked out on your iPhone in your time zone, and shown to you before saving.")
            }
            Section {
                Toggle("Use on-device AI", isOn: $useOnDeviceAI)
                    .onChange(of: useOnDeviceAI) { _, _ in Task { await model.refreshPermissions() } }
                Toggle("Let Siri save clear promises without review", isOn: Binding(get: { model.settings.siriQuickSave },
                                                                                   set: { v in model.updateSettings { $0.siriQuickSave = v } }))
            } header: { Text("Capture") } footer: {
                Text("When Siri hears a promise with no open questions, it can save it directly. Anything unclear always opens for review.")
            }
        }
        .scrollContentBackground(.hidden)
        .canvasBackground()
        .navigationTitle("Preferences")
    }
}

// MARK: - Siri

struct SiriSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                SiriOrb(size: 72)
                ScreenHeader(title: "Use Siri to capture promises", subtitle: "Say one of these phrases. Siri needs the app’s name in the phrase.", alignment: .center)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(["“Add a promise in Promise Tracker”", "“What do I owe Anna in Promise Tracker?”",
                             "“Show my promises in Promise Tracker”", "“Capture a promise with Promise Tracker”"], id: \.self) { phrase in
                        Label(phrase, systemImage: "quote.opening").font(.subheadline).foregroundStyle(Theme.ink)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
                SiriTipView(intent: AddPromiseIntent())
                ShortcutsLink()
                    .shortcutsLinkStyle(.automaticOutline)
                Text("You can also assign “Open Capture” to the Action button in iOS Settings › Action Button › Shortcut.")
                    .font(.footnote).foregroundStyle(Theme.inkSecondary).multilineTextAlignment(.center)
                Text("Say the phrase on its own, wait for “What did you promise?”, then say the promise. Avoid the word “reminder” in the phrase, or Siri may hand it to Apple’s Reminders app.")
                    .font(.footnote).foregroundStyle(Theme.inkSecondary).multilineTextAlignment(.center)
                Text("Siri’s language support and follow-up questions are controlled by iOS and may vary.")
                    .font(.caption).foregroundStyle(Theme.inkTertiary).multilineTextAlignment(.center)
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 30)
        }
        .canvasBackground()
        .navigationTitle("Siri & Shortcuts")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SyncInfoView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenHeader(title: "On this iPhone only", subtitle: "Your promises are stored on this device, encrypted by iOS.")
                Text("iCloud sync across your devices is planned. Until then, your data is included in your regular iPhone backups, and you can export everything from Settings › Your data.")
                    .font(.subheadline).foregroundStyle(Theme.inkSecondary)
            }
            .padding(Theme.gutter)
        }
        .canvasBackground()
        .navigationTitle("Sync")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Privacy

struct PrivacyView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Text("Promises, people and your words are stored only on this iPhone. Promise Tracker has no account and no server, and sends nothing to its developer.")
                Text("Promise text is never written to logs or analytics.")
            } header: { Text("Your data") }
            Section {
                diag("On-device AI", model.aiUnavailableReason == nil ? "Available" : (model.aiUnavailableReason?.userMessage ?? ""))
                diag("Speech on this iPhone", SpeechTranscriber.supportsOnDevice ? "Transcribed on device" : "Uses Apple’s speech service")
                diag("Microphone", SpeechTranscriber.microphoneGranted ? "Allowed" : (SpeechTranscriber.microphoneDenied ? "Off" : "Not asked yet"))
                diag("Notifications", { () -> String in
                    switch model.notificationPermission {
                    case .authorized: return "Allowed"
                    case .denied: return "Off"
                    case .notDetermined: return "Not asked yet"
                    }
                }())
                Button("Open iOS Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            } header: { Text("Diagnostics") } footer: {
                Text("Apple Intelligence runs Apple’s model on your iPhone. If it’s unavailable, basic on-device rules are used instead — nothing is sent to a cloud AI.")
            }
            if let url = AppConfig.privacyPolicyURL {
                Section { Link("Privacy policy", destination: url) }
            }
        }
        .scrollContentBackground(.hidden)
        .canvasBackground()
        .navigationTitle("Privacy")
        .task { await model.refreshPermissions() }
    }

    private func diag(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(value).font(.footnote).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Data

struct DataSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var exportURL: URL?
    @State private var csvURL: URL?
    @State private var importing = false
    @State private var confirmImport: URL?
    @State private var confirmDelete = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                if let exportURL { ShareLink("Export all data (JSON)", item: exportURL) }
                if let csvURL { ShareLink("Export promises (CSV)", item: csvURL) }
                Button("Import from a JSON export") { importing = true }
            } header: { Text("Export & import") } footer: {
                Text("Exports are always free. Importing replaces what’s on this iPhone.")
            }
            Section {
                Button("Delete all data", role: .destructive) { confirmDelete = true }
            } footer: {
                Text("Removes every promise, person and setting from this iPhone.")
            }
            if let message { Section { Text(message).font(.footnote) } }
        }
        .scrollContentBackground(.hidden)
        .canvasBackground()
        .navigationTitle("Your data")
        .task { prepareExports() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            if case let .success(url) = result { confirmImport = url }
        }
        .confirmationDialog("Replace everything with this file?", isPresented: Binding(get: { confirmImport != nil }, set: { if !$0 { confirmImport = nil } }),
                            titleVisibility: .visible) {
            Button("Replace", role: .destructive) { if let url = confirmImport { importFile(url) } }
        } message: { Text("Your current promises will be replaced. Export them first if you want a copy.") }
        .confirmationDialog("Delete all data?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete everything", role: .destructive) {
                model.perform { try model.service.eraseAllData() }
                model.env.notifications.removeAll()
                message = "All data deleted."
            }
        } message: { Text("This can’t be undone.") }
    }

    private func prepareExports() {
        let dir = FileManager.default.temporaryDirectory
        let stamp = Date().formatted(.iso8601.year().month().day())
        do {
            let json = dir.appendingPathComponent("PromiseTracker-\(stamp).json")
            try model.service.database.exportJSON().write(to: json, options: [.atomic, .completeFileProtection])
            exportURL = json
            let csv = dir.appendingPathComponent("PromiseTracker-\(stamp).csv")
            try CSVExporter().export(commitments: model.commitments, people: model.people)
                .write(to: csv, atomically: true, encoding: .utf8)
            csvURL = csv
        } catch {
            message = "Couldn’t prepare the export: \(error.localizedDescription)"
        }
    }

    private func importFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            try model.service.database.importJSON(data)
            model.reload()
            model.env.notifications.scheduleReconcile()
            message = "Imported \(model.commitments.count) promises."
        } catch {
            message = "That file couldn’t be imported: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }
}

// MARK: - Subscription

struct SubscriptionView: View {
    @Environment(AppModel.self) private var model
    @State private var manage = false

    var body: some View {
        if model.isPro {
            Form {
                Section {
                    Label("Pro is active", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.calm)
                    if let date = model.store.renewalDate {
                        Text(model.store.willRenew ? "Renews \(date.formatted(date: .abbreviated, time: .omitted))"
                                                   : "Ends \(date.formatted(date: .abbreviated, time: .omitted)). Your promises stay yours.")
                    }
                    Button("Manage subscription") { manage = true }
                    Button("Restore purchases") { Task { await model.store.restore() } }
                }
            }
            .scrollContentBackground(.hidden)
            .canvasBackground()
            .navigationTitle("Subscription")
            .manageSubscriptionsSheet(isPresented: $manage)
        } else {
            PaywallView(embedded: true)
        }
    }
}
