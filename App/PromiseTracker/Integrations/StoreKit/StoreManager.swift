import Foundation
import Observation
import StoreKit

/// StoreKit 2 subscriptions. Entitlement comes from verified transactions only — never
/// a homemade flag (PRD §13). StoreKit caches entitlements for offline use.
@MainActor
@Observable
final class StoreManager {
    static let monthlyId = "com.jabol183.PromiseTracker.pro.monthly"
    static let yearlyId = "com.jabol183.PromiseTracker.pro.yearly"
    static let productIds = [monthlyId, yearlyId]

    private(set) var products: [Product] = []
    private(set) var isPro = false
    private(set) var activeProductId: String?
    private(set) var renewalDate: Date?
    private(set) var willRenew = true
    private(set) var isLoading = false
    var lastError: String?

    var onEntitlementChange: ((Bool) -> Void)?
    private var updatesTask: Task<Void, Never>?

    init() {
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                if case let .verified(transaction) = update { await transaction.finish() }
                await self?.refreshEntitlements()
            }
        }
    }

    func loadProducts() async {
        guard products.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            products = try await Product.products(for: Self.productIds).sorted { $0.price < $1.price }
        } catch {
            lastError = "Couldn’t load plans. Check your connection and try again."
        }
    }

    enum PurchaseOutcome { case success, cancelled, pending, failed }

    func purchase(_ product: Product) async -> PurchaseOutcome {
        do {
            let result = try await product.purchase()
            switch result {
            case let .success(verification):
                guard case let .verified(transaction) = verification else {
                    lastError = "The purchase couldn’t be verified."
                    return .failed
                }
                await transaction.finish()
                await refreshEntitlements()
                return .success
            case .userCancelled:
                return .cancelled
            case .pending:
                return .pending
            @unknown default:
                return .failed
            }
        } catch {
            lastError = error.localizedDescription
            return .failed
        }
    }

    func restore() async {
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            if !isPro { lastError = "No active subscription was found for this Apple Account." }
        } catch {
            lastError = "Restore failed: \(error.localizedDescription)"
        }
    }

    func refreshEntitlements() async {
        var pro = false
        var productId: String?
        var expiry: Date?
        for await entitlement in Transaction.currentEntitlements {
            guard case let .verified(t) = entitlement, Self.productIds.contains(t.productID), t.revocationDate == nil else { continue }
            if let exp = t.expirationDate, exp < Date() { continue }
            pro = true
            productId = t.productID
            expiry = t.expirationDate
        }
        var renews = true
        var activeProduct = products.first { $0.id == productId }
        if activeProduct == nil, let productId {
            activeProduct = (try? await Product.products(for: [productId]))?.first
        }
        if let product = activeProduct, let statuses = try? await product.subscription?.status {
            for status in statuses {
                if case let .verified(info) = status.renewalInfo { renews = info.willAutoRenew }
            }
        }
        let changed = pro != isPro
        isPro = pro
        activeProductId = productId
        renewalDate = expiry
        willRenew = renews
        if changed { onEntitlementChange?(pro) }
    }

    func product(_ id: String) -> Product? { products.first { $0.id == id } }
}
