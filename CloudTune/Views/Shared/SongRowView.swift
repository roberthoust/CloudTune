//
//  SongRowView.swift
//  CloudTune
//
//  Created by Robert Houst on 7/31/25.
//
import Foundation
import SwiftUI

struct SongRowView: View {
    let song: Song
    let isPlaying: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                if let data = song.artwork, let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 70, height: 70)
                        .cornerRadius(10)
                        .clipped()
                } else {
                    Image("DefaultCover")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 70, height: 70)
                        .cornerRadius(10)
                        .clipped()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(song.title)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                    Text(song.artist)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if isPlaying {
                    Image(systemName: "waveform.circle.fill")
                        .foregroundColor(.appAccent)
                        .imageScale(.large)
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
            )
            .padding(.horizontal)
        }
    }
}
