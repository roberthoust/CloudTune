import Foundation
import StoreKitTest
import Testing
@testable import CloudTune

@MainActor
struct ProStoreTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "ProStoreTests-\(UUID().uuidString)")!
    }

    private func freshKeychain() -> String { "ProStoreTests-\(UUID().uuidString)" }

    private func makeStore(_ defaults: UserDefaults, _ keychain: String) -> ProStore {
        ProStore(defaults: defaults, keychainService: keychain, loadOnInit: false)
    }

    @Test func speedPitchTrialAllowsThreeSongs() {
        let store = makeStore(freshDefaults(), freshKeychain())
        #expect(store.trialSongsLeft == 3)

        for id in ["a", "b", "c"] {
            #expect(store.canUseSpeedPitch(on: id))
            store.noteSpeedPitchUse(on: id)
        }
        store.noteSpeedPitchUse(on: "a")            // replaying a trial song is free
        #expect(store.trialSongsLeft == 0)
        #expect(store.canUseSpeedPitch(on: "b"))    // still allowed on trial songs
        #expect(!store.canUseSpeedPitch(on: "d"))   // but not on new ones
    }

    @Test func trialSurvivesRelaunchAndReinstall() {
        let keychain = freshKeychain()
        makeStore(freshDefaults(), keychain).noteSpeedPitchUse(on: "a")
        // Reinstalling wipes UserDefaults but not the Keychain.
        #expect(makeStore(freshDefaults(), keychain).trialSongsLeft == 2)
        Keychain.set(nil, service: keychain, account: "pro.speedPitchTrialSongIDs")
    }

    @Test func trialStartsOverEachDay() {
        var clock = ISO8601DateFormatter().date(from: "2026-10-27T22:00:00Z")!
        let store = ProStore(defaults: freshDefaults(), keychainService: freshKeychain(),
                             now: { clock }, loadOnInit: false)
        for id in ["a", "b", "c"] { store.noteSpeedPitchUse(on: id) }
        #expect(!store.canUseSpeedPitch(on: "d"))

        clock = clock.addingTimeInterval(24 * 3600)   // next day
        #expect(store.trialSongsLeft == 3)
        #expect(store.canUseSpeedPitch(on: "d"))
        store.noteSpeedPitchUse(on: "d")
        #expect(store.trialSongIDs == ["d"])
    }

    @Test func resetTrialStartsOver() {
        let keychain = freshKeychain()
        let store = makeStore(freshDefaults(), keychain)
        for id in ["a", "b", "c"] { store.noteSpeedPitchUse(on: id) }
        store.resetTrial()
        #expect(store.trialSongsLeft == 3)
        #expect(makeStore(freshDefaults(), keychain).trialSongsLeft == 3)   // reset is saved too
    }

    @Test func trialFromFirstProBuildCarriesOver() {
        let defaults = freshDefaults()
        defaults.set(["a", "b"], forKey: "pro.speedPitchTrialSongIDs")
        #expect(makeStore(defaults, freshKeychain()).trialSongsLeft == 1)
    }

    /// Runs a real purchase against the local StoreKit configuration (no App Store account).
    @Test func purchaseUnlocksProAndRefundRemovesIt() async throws {
        let config = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CloudTune.storekit")
        let session = try SKTestSession(contentsOf: config)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()

        let defaults = freshDefaults()
        let store = makeStore(defaults, freshKeychain())
        await store.loadProduct()
        #expect(store.product?.displayName == "CloudTune Pro")
        #expect(store.priceText == "$9.99")
        #expect(!store.isPro)

        await store.purchase()
        #expect(store.isPro)
        #expect(store.canUseSpeedPitch(on: "anything"))
        #expect(defaults.bool(forKey: "pro.isPro"))

        // A fresh install (empty defaults) finds the purchase through the App Store.
        let reinstalled = makeStore(freshDefaults(), freshKeychain())
        await reinstalled.refresh()
        #expect(reinstalled.isPro)

        // Refunded / removed: Pro goes away.
        session.clearTransactions()
        await reinstalled.refresh()
        #expect(!reinstalled.isPro)
    }
}
