//
//  ProStore.swift
//  CloudTune
//
//  CloudTune Pro: a one-time, non-consumable in-app purchase (StoreKit 2).
//  Pro unlocks the equalizer, speed & pitch, and cloud sources.
//  Free users get speed & pitch on a few songs a day.
//
//  For local testing, the CloudTune scheme uses CloudTune.storekit (no App Store account needed).
//

import Foundation
import StoreKit

@MainActor
final class ProStore: ObservableObject {
    static let productID = "com.robb.CloudTune.pro"
    /// How many different songs a day free users can play with custom speed/pitch.
    static let speedPitchTrialSongs = 3

    @Published private(set) var isPro: Bool
    @Published private(set) var product: Product?
    @Published private(set) var isPurchasing = false
    /// Set when a purchase/restore needs to tell the user something.
    @Published var message: String?
    /// Today's trial: which songs used it (replaying them is free) and the day it's for.
    @Published private(set) var trial: Trial

    struct Trial: Codable, Equatable {
        var day: String          // "yyyy-MM-dd" in the phone's time zone
        var songIDs: [String]
    }

    private let defaults: UserDefaults
    private let keychainService: String
    private let now: () -> Date
    private var updates: Task<Void, Never>?

    private enum Keys {
        static let isPro = "pro.isPro"
        static let trialSongIDs = "pro.speedPitchTrialSongIDs"
    }

    /// - keychainService: where the trial is kept. The Keychain (not UserDefaults) saves immediately
    ///   and survives reinstalling, so quitting or reinstalling can't reset the trial.
    /// - now: the clock (tests pass their own).
    init(defaults: UserDefaults = .standard, keychainService: String = "com.robb.CloudTune.pro",
         now: @escaping () -> Date = Date.init, loadOnInit: Bool = true) {
        self.defaults = defaults
        self.keychainService = keychainService
        self.now = now
        // Last known state, so Pro users don't see locks flash at launch; confirmed by refresh().
        isPro = defaults.bool(forKey: Keys.isPro)
        trial = Self.loadTrial(service: keychainService, defaults: defaults, today: Self.day(now()))

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

    // MARK: - Speed & pitch trial (a few songs a day)

    /// Songs that used the trial today. A new day starts with none (without having to save anything).
    var trialSongIDs: [String] { trial.day == Self.day(now()) ? trial.songIDs : [] }

    var trialSongsLeft: Int { max(0, Self.speedPitchTrialSongs - trialSongIDs.count) }

    func canUseSpeedPitch(on songID: String?) -> Bool {
        if isPro { return true }
        guard let songID else { return trialSongsLeft > 0 }
        return trialSongIDs.contains(songID) || trialSongsLeft > 0
    }

    /// Call when a song plays with custom speed or pitch. Uses up one of today's songs the first time.
    func noteSpeedPitchUse(on songID: String) {
        guard !isPro, !trialSongIDs.contains(songID), trialSongsLeft > 0 else { return }
        saveTrial(Trial(day: Self.day(now()), songIDs: trialSongIDs + [songID]))
    }

    #if DEBUG
    /// Developer builds only: start today's speed/pitch trial over.
    func resetTrial() {
        saveTrial(Trial(day: Self.day(now()), songIDs: []))
        defaults.removeObject(forKey: Keys.trialSongIDs)
    }
    #endif

    private func saveTrial(_ new: Trial) {
        trial = new
        if let data = try? JSONEncoder().encode(new) {
            Keychain.set(data, service: keychainService, account: Keys.trialSongIDs)
        }
    }

    private static func loadTrial(service: String, defaults: UserDefaults, today: String) -> Trial {
        if let data = Keychain.data(service: service, account: Keys.trialSongIDs) {
            if let trial = try? JSONDecoder().decode(Trial.self, from: data) { return trial }
            // Earlier builds kept a plain list (no day); count it as today's.
            if let ids = try? JSONDecoder().decode([String].self, from: data) { return Trial(day: today, songIDs: ids) }
        }
        let ids = defaults.stringArray(forKey: Keys.trialSongIDs) ?? []   // the first Pro build used UserDefaults
        return Trial(day: today, songIDs: ids)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// The calendar day in the phone's current time zone.
    static func day(_ date: Date) -> String {
        dayFormatter.timeZone = .current
        return dayFormatter.string(from: date)
    }
}
