import PromiseCore
import StoreKit
import SwiftUI

struct PaywallView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var embedded = false
    @State private var selectedId = StoreManager.yearlyId
    @State private var purchasing = false
    @State private var message: String?

    private let features: [(String, String)] = [
        ("infinity", "Unlimited open promises and people"),
        ("bell.and.waves.left.and.right", "Advanced reminders: an hour before, overdue nudge, extra reminders"),
        ("sun.max", "Daily briefing"),
        ("text.bubble", "Unlimited AI follow-up rewrites"),
    ]

    var body: some View {
        let content = ScrollView {
            VStack(spacing: 22) {
                if !embedded {
                    HStack { Spacer(); Button("Not now") { dismiss() }.foregroundStyle(Theme.inkSecondary) }
                }
                Image(systemName: "star.circle").font(.system(size: 52, weight: .light)).foregroundStyle(Theme.gold)
                ScreenHeader(title: "Promise Tracker Pro", subtitle: "Keep every promise, without limits.", alignment: .center)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(features, id: \.1) { feature in
                        Label(feature.1, systemImage: feature.0).font(.subheadline).foregroundStyle(Theme.ink)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()

                if model.store.products.isEmpty {
                    if model.store.isLoading { ProgressView() }
                    else {
                        Text(model.store.lastError ?? "Plans aren’t available right now.").font(.footnote).foregroundStyle(Theme.inkSecondary)
                        Button("Try again") { Task { await model.store.loadProducts() } }
                    }
                } else {
                    VStack(spacing: 10) {
                        ForEach(model.store.products, id: \.id) { product in
                            planRow(product)
                        }
                    }
                }

                Button {
                    Task { await buy() }
                } label: {
                    if purchasing { ProgressView().tint(Theme.onAction) } else { Text("Continue") }
                }
                .buttonStyle(.primary)
                .disabled(model.store.product(selectedId) == nil || purchasing)

                if let message { Text(message).font(.footnote).foregroundStyle(Theme.urgent).multilineTextAlignment(.center) }

                Button("Restore purchases") { Task { await model.store.restore(); message = model.isPro ? nil : model.store.lastError } }
                    .font(.subheadline).foregroundStyle(Theme.inkSecondary)

                Text("Subscriptions renew automatically until cancelled. Cancel anytime in Settings › Apple Account › Subscriptions at least 24 hours before renewal. Your promises, people and exports always stay available on the free plan.")
                    .font(.caption).foregroundStyle(Theme.inkTertiary).multilineTextAlignment(.center)
                HStack(spacing: 16) {
                    if let terms = AppConfig.termsURL { Link("Terms of Use", destination: terms) }
                    if let privacy = AppConfig.privacyPolicyURL { Link("Privacy Policy", destination: privacy) }
                }
                .font(.caption)
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 20)
        }
        .canvasBackground()
        .task { await model.store.loadProducts() }

        if embedded { content.navigationTitle("Pro").navigationBarTitleDisplayMode(.inline) } else { content }
    }

    private func planRow(_ product: Product) -> some View {
        let selected = product.id == selectedId
        let period = product.subscription?.subscriptionPeriod
        let cadence: String = {
            guard let period else { return "" }
            switch period.unit {
            case .year: return period.value == 1 ? "per year" : "every \(period.value) years"
            case .month: return period.value == 1 ? "per month" : "every \(period.value) months"
            case .week: return "per week"
            case .day: return "per day"
            @unknown default: return ""
            }
        }()
        return Button { selectedId = product.id } label: {
            HStack {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Theme.ink : Theme.inkTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(product.displayName).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                    Text("\(product.displayPrice) \(cadence)").font(.footnote).foregroundStyle(Theme.inkSecondary)
                }
                Spacer()
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? Theme.ink : Theme.cardBorder, lineWidth: selected ? 1.5 : 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func buy() async {
        guard let product = model.store.product(selectedId) else { return }
        purchasing = true
        defer { purchasing = false }
        switch await model.store.purchase(product) {
        case .success:
            if !embedded { dismiss() }
        case .pending:
            message = "Your purchase is waiting for approval."
        case .cancelled:
            break
        case .failed:
            message = model.store.lastError ?? "The purchase didn’t go through."
        }
    }
}
