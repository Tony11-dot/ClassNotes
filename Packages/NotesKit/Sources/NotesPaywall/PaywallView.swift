import ClassMateTheme
import NotesDesignSystem
import NotesServices
import StoreKit
import SwiftUI

/// The glass upsell sheet. Shown only when the user taps a visibly locked
/// feature — never as an interrupting popup.
public struct PaywallView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(EntitlementService.self) private var entitlements

    /// The feature whose tap opened the sheet, listed first.
    let highlighted: PremiumFeature?

    @State private var purchaseInFlight = false
    @State private var purchaseError: String?

    public init(highlighting highlighted: PremiumFeature? = nil) {
        self.highlighted = highlighted
    }

    private var orderedFeatures: [PremiumFeature] {
        guard let highlighted else { return PremiumFeature.allCases }
        return [highlighted] + PremiumFeature.allCases.filter { $0 != highlighted }
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    featureList
                    productButtons
                    restoreButton
                }
                .padding(20)
            }
            .background(theme.surface.color)
            .navigationTitle("Premium")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.large, .medium])
        .presentationBackground(theme.surface.color)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.dsSystem(size: 36, weight: .light))
                .foregroundStyle(theme.accent.color)
            Text("ClassNotes Premium")
                .font(.dsTitle2.weight(.bold))
                .foregroundStyle(theme.ink.color)
            Text("Everything in the free app stays free. Premium adds the studio.")
                .font(.dsSubheadline)
                .foregroundStyle(theme.inkSecondary.color)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 8)
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(orderedFeatures) { feature in
                HStack(spacing: 12) {
                    Image(systemName: feature.symbolName)
                        .font(.dsSystem(size: 17))
                        .foregroundStyle(theme.accent.color)
                        .frame(width: 28)
                    Text(feature.displayName)
                        .font(feature == highlighted ? .body.weight(.semibold) : .body)
                        .foregroundStyle(theme.ink.color)
                    Spacer()
                    if feature.tier == .subscription {
                        Text("Subscription")
                            .font(.dsCaption2)
                            .foregroundStyle(theme.inkSecondary.color)
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                if feature != orderedFeatures.last {
                    Divider().overlay(theme.separator.color)
                }
            }
        }
        .background(
            theme.surfaceRaised.color,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    @ViewBuilder
    private var productButtons: some View {
        if entitlements.isPremium {
            Label("Premium is active", systemImage: "checkmark.seal.fill")
                .font(.dsHeadline)
                .foregroundStyle(theme.accent.color)
                .padding(.vertical, 8)
        } else if entitlements.products.isEmpty {
            Text("Purchases are unavailable right now. You can restore an existing purchase below.")
                .font(.dsFootnote)
                .foregroundStyle(theme.inkSecondary.color)
                .multilineTextAlignment(.center)
        } else {
            VStack(spacing: 10) {
                ForEach(entitlements.products, id: \.id) { product in
                    Button {
                        purchase(product)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(product.displayName)
                                    .font(.dsBody.weight(.semibold))
                                if product.id == EntitlementService.lifetimeProductID {
                                    Text("One-time purchase · all local features")
                                        .font(.dsCaption)
                                } else {
                                    Text("Includes sync & AI features")
                                        .font(.dsCaption)
                                }
                            }
                            Spacer()
                            Text(product.displayPrice)
                                .font(.dsBody.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(purchaseInFlight)
                }
                if let purchaseError {
                    Text(purchaseError)
                        .font(.dsFootnote)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var restoreButton: some View {
        VStack(spacing: 6) {
            Button("Restore Purchases") {
                Task {
                    await entitlements.restorePurchases()
                }
            }
            .buttonStyle(.glass)
            if let restoreError = entitlements.lastRestoreError {
                Text(restoreError)
                    .font(.dsFootnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private func purchase(_ product: Product) {
        purchaseInFlight = true
        purchaseError = nil
        Task {
            defer { purchaseInFlight = false }
            do {
                _ = try await entitlements.purchase(product)
            } catch {
                purchaseError = "Purchase didn't go through. Nothing was charged."
            }
        }
    }
}
