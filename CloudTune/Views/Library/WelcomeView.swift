//
//  WelcomeView.swift
//  CloudTune
//
//  Shown in the Library tab while the library is empty: what CloudTune does and how to start.
//

import SwiftUI

struct WelcomeView: View {
    let onAddFolder: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                VStack(spacing: 14) {
                    Image(systemName: "music.note")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 88, height: 88)
                        .background(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(LinearGradient(colors: [Color("appAccent"), Color("appAccent").opacity(0.7)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                        )

                    Text("Welcome to CloudTune")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)

                    Text("Play the music you own (MP3, FLAC, M4A and more) straight from your Files.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: 22) {
                    step("folder.badge.plus", "Add a music folder",
                         "Pick any folder in Files: on this iPhone, in iCloud Drive, or on a connected drive.")
                    step("wand.and.stars", "It tidies itself up",
                         "Titles, albums, years and cover art are filled in automatically.")
                    step("dial.medium", "Make it yours",
                         "Playlists, an equalizer, and speed & pitch: slowed, sped up, or anything in between.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 12) {
                    Button(action: onAddFolder) {
                        Label("Add a Music Folder", systemImage: "folder.badge.plus")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 14))

                    Text("Tip: one folder per album works best, or one folder holding them all.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .tint(Color("appAccent"))
    }

    private func step(_ symbol: String, _ title: String, _ detail: String) -> some View {
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
}
