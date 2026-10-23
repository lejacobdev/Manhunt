import Foundation
import StoreKit

/// The server's view of this player's cosmetics: every item, what they own, how close they are to
/// the ones unlocked by playing, the packs on sale, and what's equipped.
struct CosmeticsSnapshot: Decodable, Equatable {
    struct Item: Decodable, Identifiable, Equatable {
        let id: String
        let category: String
        let name: String
        let description: String
        /// free, play, pack or supporter.
        let unlock: String
        let productId: String?
        let requirement: String?
        let progress: Int?
        let goal: Int?
        let owned: Bool
    }

    struct Product: Decodable, Identifiable, Equatable {
        let productId: String
        let name: String
        let description: String
        let items: [String]
        let owned: Bool
        var id: String { productId }
    }

    let items: [Item]
    let products: [Product]
    let equipped: [String: String]
}

/// Cosmetics and App Store purchases. Every purchase is sent to the server as Apple's signed
/// transaction and verified there before anything is unlocked; the server's snapshot is the
/// source of truth for what this player owns.
@MainActor
final class CosmeticsStore: ObservableObject {
    static let shared = CosmeticsStore()

    @Published private(set) var snapshot: CosmeticsSnapshot?
    @Published private(set) var products: [String: Product] = [:]
    @Published var isWorking = false
    @Published var message: String?

    private var updatesTask: Task<Void, Never>?

    var equipped: [String: String] { snapshot?.equipped ?? [:] }

    /// Starts listening for transactions that finish outside the purchase sheet (Ask to Buy, a
    /// purchase on another device, a refund) and loads the catalog. Call once signed in.
    func start() {
        if updatesTask == nil {
            updatesTask = Task.detached { [weak self] in
                for await update in Transaction.updates {
                    guard case .verified(let transaction) = update else { continue }
                    await self?.send([update.jwsRepresentation])
                    await transaction.finish()
                }
            }
        }
        Task { await refresh() }
    }

    #if DEBUG
    /// Simulator screenshot scenarios only.
    func loadPreview(_ preview: CosmeticsSnapshot) { snapshot = preview }
    #endif

    func refresh() async {
        do {
            snapshot = try await APIClient.shared.cosmetics()
            let ids = snapshot?.products.map(\.productId) ?? []
            if !ids.isEmpty, products.isEmpty {
                let loaded = try await Product.products(for: ids)
                products = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func equip(_ item: CosmeticsSnapshot.Item) async {
        do {
            snapshot = try await APIClient.shared.equipCosmetic(category: item.category, itemId: item.id)
            HapticsEngine.shared.lightTap()
        } catch {
            message = error.localizedDescription
        }
    }

    func buy(_ productId: String) async {
        guard let product = products[productId] else {
            message = "That pack isn't available right now. Try again in a moment."
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let result = try await product.purchase(options: [.appAccountToken(AuthSession.shared.accountUUID)])
            switch result {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    message = "The App Store couldn't confirm that purchase."
                    return
                }
                await send([verification.jwsRepresentation])
                await transaction.finish()
                message = "\(product.displayName) unlocked. Thank you!"
            case .pending:
                message = "Waiting for approval — it'll unlock as soon as it's approved."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            message = error.localizedDescription
        }
    }

    /// Restore Purchases: re-sends every purchase this Apple ID owns to the server.
    func restore() async {
        isWorking = true
        defer { isWorking = false }
        try? await AppStore.sync()
        var signed: [String] = []
        for await entitlement in Transaction.currentEntitlements {
            signed.append(entitlement.jwsRepresentation)
        }
        if signed.isEmpty {
            message = "No purchases to restore on this Apple ID."
            return
        }
        await send(signed)
        message = "Purchases restored."
    }

    private func send(_ transactions: [String]) async {
        do {
            snapshot = try await APIClient.shared.submitPurchases(transactions)
        } catch {
            message = error.localizedDescription
        }
    }
}
