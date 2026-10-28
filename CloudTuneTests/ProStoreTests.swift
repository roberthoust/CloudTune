import Foundation
import StoreKitTest
import Testing
@testable import CloudTune

@MainActor
struct ProStoreTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "ProStoreTests-\(UUID().uuidString)")!
    }

    @Test func speedPitchTrialAllowsThreeSongs() {
        let store = ProStore(defaults: freshDefaults(), loadOnInit: false)
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

    @Test func trialIsRememberedAcrossLaunches() {
        let defaults = freshDefaults()
        ProStore(defaults: defaults, loadOnInit: false).noteSpeedPitchUse(on: "a")
        #expect(ProStore(defaults: defaults, loadOnInit: false).trialSongsLeft == 2)
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
        let store = ProStore(defaults: defaults, loadOnInit: false)
        await store.loadProduct()
        #expect(store.product?.displayName == "CloudTune Pro")
        #expect(store.priceText == "$9.99")
        #expect(!store.isPro)

        await store.purchase()
        #expect(store.isPro)
        #expect(store.canUseSpeedPitch(on: "anything"))
        #expect(defaults.bool(forKey: "pro.isPro"))

        // A fresh install (empty defaults) finds the purchase through the App Store.
        let reinstalled = ProStore(defaults: freshDefaults(), loadOnInit: false)
        await reinstalled.refresh()
        #expect(reinstalled.isPro)

        // Refunded / removed: Pro goes away.
        session.clearTransactions()
        await reinstalled.refresh()
        #expect(!reinstalled.isPro)
    }
}
