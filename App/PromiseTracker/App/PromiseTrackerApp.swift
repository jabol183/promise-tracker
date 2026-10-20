import PromiseCore
import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Creating the environment installs the notification delegate before any
        // notification action from a cold launch is delivered.
        _ = AppEnvironment.shared
        return true
    }
}

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@main
struct PromiseTrackerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel(store: StoreManager())
    @AppStorage("appearance") private var appearance = AppearancePreference.system.rawValue
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(AppearancePreference(rawValue: appearance)?.colorScheme)
                .onOpenURL { model.handle(url: $0) }
                .task { await model.store.loadProducts() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await model.didBecomeActive() } }
                }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if let error = model.env.startupError {
                StartupErrorView(message: error)
            } else if model.showOnboarding {
                OnboardingFlow()
            } else {
                MainTabs()
            }
        }
        .fullScreenCover(item: $model.capture) { request in
            CaptureFlowView(request: request)
                .environment(model)
        }
        .sheet(isPresented: $model.showPaywall) {
            PaywallView().environment(model)
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct MainTabs: View {
    @Environment(AppModel.self) private var model
    @State private var lastTab: AppTab = .home

    var body: some View {
        @Bindable var model = model
        TabView(selection: Binding(get: { model.selectedTab }, set: { tab in
            // "Add" is an action, not a destination: open capture and stay put.
            if tab == .add { model.startCapture(.voice) } else { model.selectedTab = tab }
        })) {
            NavigationStack(path: $model.homePath) {
                HomeView().withRoutes()
            }
            .tabItem { Label("Home", systemImage: "house") }
            .tag(AppTab.home)

            NavigationStack(path: $model.peoplePath) {
                PeopleView().withRoutes()
            }
            .tabItem { Label("People", systemImage: "person.2") }
            .tag(AppTab.people)

            Color.clear
                .tabItem { Label("Add", systemImage: "plus.circle") }
                .tag(AppTab.add)
                .accessibilityLabel("Add a promise")

            NavigationStack(path: $model.calendarPath) {
                PromiseCalendarView().withRoutes()
            }
            .tabItem { Label("Calendar", systemImage: "calendar") }
            .tag(AppTab.calendar)

            NavigationStack(path: $model.settingsPath) {
                SettingsView().withRoutes()
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(AppTab.settings)
        }
        .tint(Theme.ink)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                UndoToast(message: toast.message) {
                    toast.undo?()
                    model.toast = nil
                }
                .padding(.bottom, 64)
            }
        }
    }
}

extension View {
    /// Registers every shared navigation destination on a stack.
    func withRoutes() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case let .commitment(id): CommitmentDetailView(id: id)
            case let .person(id): PersonDetailView(id: id)
            case .history: HistoryView()
            case .impact: ImpactView()
            case let .followUp(id): FollowUpView(commitmentId: id)
            }
        }
    }
}

struct StartupErrorView: View {
    let message: String
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "externaldrive.badge.exclamationmark").font(.system(size: 48)).foregroundStyle(Theme.warm)
            ScreenHeader(title: "Can’t open your promises", subtitle: message, alignment: .center)
            Text("Your data has not been changed. Updating Promise Tracker from the App Store should fix this.")
                .font(.footnote).foregroundStyle(Theme.inkSecondary).multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .canvasBackground()
    }
}
