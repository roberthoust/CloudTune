//
//  ProStore.swift
//  CloudTune
//
//  CloudTune Pro: a one-time, non-consumable in-app purchase (StoreKit 2).
//  Pro unlocks the equalizer, speed & pitch, and cloud sources.
//  Free users get speed & pitch on a few songs to try it.
//
//  For local testing, the CloudTune scheme uses CloudTune.storekit (no App Store account needed).
//

import Foundation
import StoreKit

@MainActor
final class ProStore: ObservableObject {
    static let productID = "com.robb.CloudTune.pro"
    /// How many different songs free users can play with custom speed/pitch.
    static let speedPitchTrialSongs = 3

    @Published private(set) var isPro: Bool
    @Published private(set) var product: Product?
    @Published private(set) var isPurchasing = false
    /// Set when a purchase/restore needs to tell the user something.
    @Published var message: String?
    /// Songs that have used the speed/pitch trial (replaying them is free).
    @Published private(set) var trialSongIDs: [String]

    private let defaults: UserDefaults
    private var updates: Task<Void, Never>?

    private enum Keys {
        static let isPro = "pro.isPro"
        static let trialSongIDs = "pro.speedPitchTrialSongIDs"
    }

    init(defaults: UserDefaults = .standard, loadOnInit: Bool = true) {
        self.defaults = defaults
        // Last known state, so Pro users don't see locks flash at launch; confirmed by refresh().
        isPro = defaults.bool(forKey: Keys.isPro)
        trialSongIDs = defaults.stringArray(forKey: Keys.trialSongIDs) ?? []

        // Purchases made elsewhere (other devices, Ask to Buy approvals, refunds) arrive here.
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let transaction) = result { await transaction.finish() }
                await self?.refresh()
            }
        }
        if loadOnInit {
            Task {
                await refresh()
                await loadProduct()
            }
        }
    }

    deinit { updates?.cancel() }

    // MARK: - Store

    var priceText: String { product?.displayPrice ?? "$9.99" }

    func loadProduct() async {
        do {
            product = try await Product.products(for: [Self.productID]).first
        } catch {
            print("💳 Couldn't load Pro product: \(error)")
        }
    }

    /// Checks the App Store for a current (not refunded) Pro purchase.
    func refresh() async {
        var owned = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, t.productID == Self.productID, t.revocationDate == nil {
                owned = true
            }
        }
        setPro(owned)
    }

    func purchase() async {
        if product == nil { await loadProduct() }
        guard let product else {
            message = "The App Store isn't reachable right now. Please try again in a moment."
            return
        }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            switch try await product.purchase() {
            case .success(.verified(let transaction)):
                await transaction.finish()
                setPro(true)
            case .success(.unverified):
                message = "The purchase couldn't be verified. If you were charged, tap Restore Purchases."
            case .pending:
                message = "Your purchase is waiting for approval. Pro unlocks as soon as it's approved."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            message = "The purchase didn't go through: \(error.localizedDescription)"
        }
    }

    /// "Restore Purchases": asks the App Store to re-sync this Apple ID's purchases.
    func restore() async {
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            try await AppStore.sync()
        } catch StoreKitError.userCancelled {
            return
        } catch {
            message = "Couldn't reach the App Store: \(error.localizedDescription)"
            return
        }
        await refresh()
        message = isPro ? "CloudTune Pro is restored." : "No CloudTune Pro purchase was found for this Apple ID."
    }

    private func setPro(_ value: Bool) {
        guard value != isPro else { return }
        isPro = value
        defaults.set(value, forKey: Keys.isPro)
    }

    // MARK: - Speed & pitch trial

    var trialSongsLeft: Int { max(0, Self.speedPitchTrialSongs - trialSongIDs.count) }

    func canUseSpeedPitch(on songID: String?) -> Bool {
        if isPro { return true }
        guard let songID else { return trialSongsLeft > 0 }
        return trialSongIDs.contains(songID) || trialSongsLeft > 0
    }

    /// Call when a song plays with custom speed or pitch. Uses up a trial song the first time.
    func noteSpeedPitchUse(on songID: String) {
        guard !isPro, !trialSongIDs.contains(songID), trialSongsLeft > 0 else { return }
        trialSongIDs.append(songID)
        defaults.set(trialSongIDs, forKey: Keys.trialSongIDs)
    }
}
