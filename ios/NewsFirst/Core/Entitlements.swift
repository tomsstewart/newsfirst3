import Foundation
import Observation
import StoreKit

/// Premium: unlimited custom topics (3 free). One monthly subscription
/// (£3.99/mo — Tom's call 2026-07-05, supersedes the strategy doc's £29.99/yr).
/// Entitled = StoreKit purchase OR a comped account.
@Observable @MainActor
final class Entitlements {
    static let shared = Entitlements()
    static let productID = "newsfirst.premium.monthly"
    static let freeCustomTopics = 3
    /// Comped accounts (founder) — matched against the signed-in email.
    private static let comped: Set<String> = ["tshawstewart@gmail.com"]

    private(set) var purchased = UserDefaults.standard.bool(forKey: "premiumPurchased") {
        didSet { UserDefaults.standard.set(purchased, forKey: "premiumPurchased") }
    }
    private(set) var product: Product?

    var isPremium: Bool {
        purchased || Self.comped.contains((AuthClient.shared.email ?? "").lowercased())
    }

    private init() {
        Task { await refresh() }
    }

    func refresh() async {
        // Product is nil until the subscription exists in App Store Connect —
        // the paywall stays honest about that instead of failing silently.
        product = try? await Product.products(for: [Self.productID]).first
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, t.productID == Self.productID, t.revocationDate == nil {
                purchased = true
            }
        }
    }

    /// True on success. A missing product (not yet configured in ASC) returns false.
    func purchase() async -> Bool {
        if product == nil { product = try? await Product.products(for: [Self.productID]).first }
        guard let product else { return false }
        guard let result = try? await product.purchase() else { return false }
        if case .success(let verification) = result, case .verified(let t) = verification {
            await t.finish()
            purchased = true
            return true
        }
        return false
    }

    func restore() async {
        try? await AppStore.sync()
        await refresh()
    }
}
