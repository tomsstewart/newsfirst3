import SwiftUI

/// The one gate in the app: a 4th custom topic. Everything else stays free —
/// the pitch is "your keywords, your alerts", not a metered news reader.
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var ent = Entitlements.shared
    @State private var buying = false
    @State private var unavailable = false

    /// Guideline 3.1.2 wants these reachable at the point of purchase, not just in
    /// the App Store description. Terms are Apple's standard EULA — the licence we
    /// ship under — rather than the marketing-site terms page.
    private enum Legal {
        static let eula = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
        static let privacy = URL(string: "https://www.getnewsfirst.app/privacy-policy")!
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.footnote.bold()).foregroundStyle(.primary)
                        .padding(9).background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.panelBorder, lineWidth: 1))
                }
                .buttonStyle(PressableStyle())
            }

            // The disclosure below is long by law, so the pitch scrolls and the
            // purchase block stays pinned — on an SE the two together overflow.
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Theme.tierMedium)
                    Text("NewsFirst Premium")
                        .font(Theme.Text.hero)
                    Text("The free plan includes \(Entitlements.freeCustomTopics) custom topics — yours forever, no card. Premium removes the ceiling.")
                        .font(Theme.Text.excerpt).foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 12) {
                        benefit("infinity", "Unlimited custom topics",
                                "Any keyword — a team, a stock, a person — becomes a column.")
                        benefit("bell.badge.fill", "Alerts on every keyword",
                                "Breaking-news pushes for all your topics, not just the first three.")
                        benefit("heart.fill", "Back an independent news app",
                                "No ads, no tracking-driven feed. You are not the product.")
                    }
                    .padding(14)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.panelBorder, lineWidth: 1))
                }
                .padding(.top, 18)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)

            purchaseBlock
        }
        .padding(20)
        .background(Theme.canvas)
        .onAppear { Analytics.capture("paywall_open") }
    }

    private var purchaseBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                guard !buying else { return }
                buying = true
                Analytics.capture("paywall_purchase_tap")
                Task {
                    let ok = await ent.purchase()
                    buying = false
                    if ok { dismiss() } else { withAnimation(Theme.Motion.snappy) { unavailable = true } }
                }
            } label: {
                Group {
                    if buying {
                        ProgressView().tint(.white)
                    } else {
                        Text(hasTrial ? "Start 7-day free trial" : "Go Premium — \(price) / month")
                    }
                }
                .font(Theme.Text.cardTitle)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Theme.selectionGradient, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(PressableStyle())

            Text(disclosure)
                .font(Theme.Text.meta).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)

            HStack(spacing: 8) {
                Spacer()
                Link("Terms of Use (EULA)", destination: Legal.eula)
                Text("·").foregroundStyle(.secondary)
                Link("Privacy Policy", destination: Legal.privacy)
                Spacer()
            }
            .font(Theme.Text.meta)
            .tint(Theme.link)

            if unavailable {
                Text("Purchases aren't live yet — Premium arrives with the App Store release. Your topics are safe; the first three keep working.")
                    .font(Theme.Text.meta).foregroundStyle(.secondary)
            }

            HStack {
                Button("Restore purchase") { Task { await ent.restore(); if ent.isPremium { dismiss() } } }
                Spacer()
                Button("Stay on Free") { dismiss() }
            }
            .font(Theme.Text.meta)
            .foregroundStyle(.secondary)
            .padding(.bottom, 8)
        }
    }

    private var price: String { ent.product?.displayPrice ?? "£3.99" }
    /// True when StoreKit reports the intro offer (set in ASC for all territories) —
    /// and as the fallback while the product hasn't loaded, since the offer exists
    /// for every new subscriber.
    private var hasTrial: Bool {
        guard let sub = ent.product?.subscription else { return true }
        return sub.introductoryOffer?.paymentMode == .freeTrial
    }

    /// Length, price and the auto-renew terms — what 3.1.2 requires next to the button.
    private var disclosure: String {
        let renewal = "Payment is charged to your Apple Account at confirmation of purchase. The subscription renews automatically at \(price) / month unless cancelled at least 24 hours before the end of the current period. Manage or cancel in Apple Account settings."
        return hasTrial
            ? "7 days free, then \(price) / month. Cancel any time during the trial and pay nothing. " + renewal
            : "\(price) / month. " + renewal
    }

    private func benefit(_ icon: String, _ title: String, _ sub: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline.bold())
                .foregroundStyle(Theme.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Text.rowTitle)
                Text(sub).font(Theme.Text.meta).foregroundStyle(.secondary)
            }
        }
    }
}
