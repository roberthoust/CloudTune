//
//  PaywallView.swift
//  CloudTune
//
//  The CloudTune Pro screen: what Pro includes, the price, Buy and Restore.
//

import SwiftUI

/// Why the paywall opened; shown as a short line at the top.
enum PaywallReason: String, Identifiable {
    case equalizer, speedPitch, cloud, settings
    var id: String { rawValue }

    var message: String? {
        switch self {
        case .equalizer: return "The equalizer is part of CloudTune Pro."
        case .speedPitch: return "You've used your \(ProStore.speedPitchTrialSongs) free speed & pitch songs."
        case .cloud: return "Cloud music is part of CloudTune Pro."
        case .settings: return nil
        }
    }
}

struct PaywallView: View {
    var reason: PaywallReason = .settings

    @EnvironmentObject private var pro: ProStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    header
                    features
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .safeAreaInset(edge: .bottom) { purchaseArea }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Close")
                }
            }
            .alert("CloudTune Pro", isPresented: Binding(get: { pro.message != nil },
                                                         set: { if !$0 { pro.message = nil } })) {
                Button("OK") { if pro.isPro { dismiss() } }
            } message: {
                Text(pro.message ?? "")
            }
            .onChange(of: pro.isPro) { _, isPro in
                // Bought: close (a restore shows its alert first, which closes this).
                if isPro && pro.message == nil { dismiss() }
            }
            .task { if pro.product == nil { await pro.loadProduct() } }
        }
        .tint(Color("appAccent"))
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Color("appAccent"))
                .padding(20)
                .background(Circle().fill(Color("appAccent").opacity(0.12)))

            Text("CloudTune Pro")
                .font(.largeTitle.bold())

            if let message = reason.message {
                Text(message)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Color("appAccent"))
                    .multilineTextAlignment(.center)
            }

            Text("One purchase. Yours to keep, no subscription.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 20) {
            feature("slider.vertical.3", "Equalizer",
                    "Shape your sound with presets or your own curve.")
            feature("dial.medium", "Speed & pitch",
                    "Slowed, sped up or pitched: any song you own, in real time.")
            feature("icloud.and.arrow.down", "Cloud music",
                    "Play your music from Dropbox. Coming soon, included with Pro.")
            feature("heart", "Support an indie developer",
                    "Pro keeps CloudTune ad-free and improving.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Color("appAccent"))
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var purchaseArea: some View {
        VStack(spacing: 10) {
            if pro.isPro {
                Label("You have CloudTune Pro", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(Color("appAccent"))
                    .frame(maxWidth: .infinity, minHeight: 50)
            } else {
                Button {
                    Task { await pro.purchase() }
                } label: {
                    ZStack {
                        Text("Unlock Pro for \(pro.priceText)")
                            .font(.headline)
                            .opacity(pro.isPurchasing ? 0 : 1)
                        if pro.isPurchasing { ProgressView().tint(.white) }
                    }
                    .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 14))
                .disabled(pro.isPurchasing)
            }

            Button("Restore Purchases") {
                Task { await pro.restore() }
            }
            .font(.subheadline)
            .disabled(pro.isPurchasing)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)
    }
}
