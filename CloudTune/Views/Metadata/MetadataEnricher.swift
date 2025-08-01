//
//  MetadataEnricher.swift
//  CloudTune
//
//  Updated by Rob F. on 7/31/25.
//

import Foundation

private func extractArtistAndTitle(from rawTitle: String, fallbackArtist: String?) -> (artist: String?, title: String) {
    // Split by dash separator
    let parts = rawTitle.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }

    // Handle common format: "01 - 21 Savage - song name"
    if parts.count >= 3, let _ = Int(parts[0]) {
        let artist = parts[1]
        let title = parts[2...].joined(separator: " - ")
        return (artist: artist, title: title)
    }

    // Handle format: "21 Savage - song name"
    if parts.count >= 2 {
        let artist = parts[0]
        let title = parts[1...].joined(separator: " - ")
        return (artist: artist, title: title)
    }

    // Fallback: no dashes or unknown format
    return (artist: fallbackArtist?.isEmpty == false ? fallbackArtist : nil, title: rawTitle.trimmingCharacters(in: .whitespaces))
}

/// Represents detailed information returned by the MusicBrainz release API
struct MusicBrainzReleaseDetail: Codable {
    let date: String?
    let media: [Medium]
    
    struct Medium: Codable {
        let position: Int
        let tracks: [Track]
    }

    struct Track: Codable {
        let number: String
        let title: String
    }
}

class MetadataEnricher {
    /// Enriches a song's metadata using MusicBrainz and Deezer fallback, filling in as many details as available.
    static func enrich(_ song: Song) async throws -> Song {
        let rawTitle = song.title
        let fallbackArtistName = song.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = extractArtistAndTitle(from: rawTitle, fallbackArtist: fallbackArtistName)
        let cleanedArtist = cleaned.artist
        let cleanedTitle = cleaned.title

        print("🎯 Cleaned Metadata — Title: \(cleanedTitle), Artist: \(cleanedArtist ?? "None")")

        guard let artist = cleanedArtist, !artist.isEmpty else {
            var enriched = song
            // Special fallback: if we have album in filename but no artist, try to pull artist from folder name or infer from album
            if (cleanedArtist == nil || cleanedArtist!.isEmpty), !song.album.isEmpty, song.album != "No Album" {
                print("🔍 Inferring artist from album/folder...")
                let folderName = song.url.deletingLastPathComponent().lastPathComponent
                let inferredArtist = folderName.replacingOccurrences(of: song.album, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !inferredArtist.isEmpty {
                    print("✅ Inferred artist: \(inferredArtist)")
                    enriched.artist = inferredArtist
                }
            }
            return enriched
        }
        
        let artistQuery = artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let titleQuery = cleanedTitle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "https://musicbrainz.org/ws/2/recording/?query=recording:\"\(titleQuery)\"^3 AND artist:\"\(artistQuery)\"^2&fmt=json&limit=1&inc=releases"
        
        print("🔎 Querying MusicBrainz for '\(cleanedTitle)' by \(artist)")
        print("🔗 URL: \(urlString)")

        guard let url = URL(string: urlString) else { return song }

        var enriched = song

        let (data, _) = try await URLSession.shared.data(from: url)

        if let result = try? JSONDecoder().decode(MusicBrainzSearchResponse.self, from: data),
           let first = result.recordings.first {

            print("🎯 Enriched result: Title=\(first.title), Artist=\(first.artistCredit.first?.name ?? "N/A"), Album=\(first.releases?.first?.title ?? "N/A")")

            if !first.title.isEmpty {
                enriched.title = first.title
            }

            if let artistName = first.artistCredit.first?.name, !artistName.isEmpty {
                enriched.artist = artistName
            }

            if let albumTitle = first.releases?.first?.title, !albumTitle.isEmpty {
                enriched.album = albumTitle
            }

            if let releases = first.releases {
                print("📀 Found \(releases.count) releases:")
                for r in releases {
                    print("  - \(r.title) [\(r.id)]")
                }
            }

            if let releaseID = first.releases?.first?.id {
                enriched.musicBrainzReleaseID = releaseID

                let releaseURLString = "https://musicbrainz.org/ws/2/release/\(releaseID)?fmt=json&inc=recordings+artist-credits+labels"
                print("📦 Fetching detailed release info: \(releaseURLString)")

                if let releaseURL = URL(string: releaseURLString) {
                    do {
                        let (releaseData, _) = try await URLSession.shared.data(from: releaseURL)
                        if let releaseResult = try? JSONDecoder().decode(MusicBrainzReleaseDetail.self, from: releaseData) {
                            if let date = releaseResult.date, !date.isEmpty {
                                enriched.year = String(date.prefix(4))
                                print("📅 Release year: \(enriched.year ?? "N/A")")
                            }
                            if let medium = releaseResult.media.first {
                                for track in medium.tracks {
                                    print("🔢 MusicBrainz Track in Medium: \(track.number) - \(track.title)")
                                }
                                if let track = medium.tracks.first(where: {
                                    let normalizedTrackTitle = $0.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                                    let normalizedCleanedTitle = cleanedTitle.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                                    return normalizedTrackTitle == normalizedCleanedTitle ||
                                           normalizedTrackTitle.contains(normalizedCleanedTitle) ||
                                           normalizedCleanedTitle.contains(normalizedTrackTitle)
                                }) {
                                    if let trackNumber = Int(track.number) {
                                        enriched.trackNumber = trackNumber
                                        print("🎵 Matched Track Number: \(trackNumber)")
                                    } else {
                                        print("⚠️ Could not parse track number: \(track.number)")
                                    }
                                    enriched.discNumber = medium.position
                                    print("💿 Disc Number: \(medium.position)")
                                } else {
                                    print("⚠️ Track '\(cleanedTitle)' not found in release media")
                                }
                                // Fallback: If still not found, try partial match for track number
                                if enriched.trackNumber == 0 {
                                    if let fallbackIndex = medium.tracks.firstIndex(where: {
                                        cleanedTitle.lowercased().contains($0.title.lowercased())
                                    }) {
                                        enriched.trackNumber = fallbackIndex + 1
                                        print("🧠 Fallback matched track number: \(enriched.trackNumber)")
                                    }
                                }
                            }
                        }
                    } catch {
                        print("⚠️ Failed to fetch detailed release info: \(error.localizedDescription)")
                    }
                }
                if let artworkData = try? await fetchArtwork(for: enriched) {
                    enriched.artwork = artworkData
                    print("🖼️ Cover art fetched and assigned.")

                    // Save artwork to disk immediately
                    let artworkURL = song.url.deletingPathExtension().appendingPathExtension("jpg")
                    do {
                        try artworkData.write(to: artworkURL, options: [.atomic])
                        print("🖼️ Artwork saved to \(artworkURL.path)")
                    } catch {
                        print("❌ Failed to save artwork: \(error.localizedDescription)")
                    }
                }
            }

            // Re-query with enriched artist/title if they differ from original
            if enriched.title != song.title || enriched.artist != song.artist {
                let secondaryArtistQuery = enriched.artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                let secondaryTitleQuery = enriched.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                let secondaryURLString = "https://musicbrainz.org/ws/2/recording/?query=recording:\"\(secondaryTitleQuery)\"^3 AND artist:\"\(secondaryArtistQuery)\"^2&fmt=json&limit=1&inc=releases"
                print("🔁 Re-querying MusicBrainz with enriched values: '\(enriched.title)' by '\(enriched.artist)'")
                print("🔗 Secondary URL: \(secondaryURLString)")

                if let secondaryURL = URL(string: secondaryURLString) {
                    do {
                        let (secondaryData, _) = try await URLSession.shared.data(from: secondaryURL)
                        if let secondaryResult = try? JSONDecoder().decode(MusicBrainzSearchResponse.self, from: secondaryData),
                           let secondaryFirst = secondaryResult.recordings.first {
                            if let albumTitle = secondaryFirst.releases?.first?.title, !albumTitle.isEmpty {
                                enriched.album = albumTitle
                            }
                            if let releaseID = secondaryFirst.releases?.first?.id {
                                enriched.musicBrainzReleaseID = releaseID
                            }
                        }
                    } catch {
                        print("⚠️ Failed to re-query with enriched values: \(error.localizedDescription)")
                    }
                }
            }

        } else {
            print("❌ No valid enrichment found for '\(cleanedTitle)'")
        }

        if enriched.album == "No Album" || enriched.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let deezerEnriched = await enrichWithDeezer(song, fallbackArtist: cleanedArtist ?? "", fallbackTitle: cleanedTitle) {
                print("✅ Deezer fallback enrichment succeeded.")
                return deezerEnriched
            } else {
                print("⚠️ Deezer fallback enrichment failed.")
            }
        }

        var finalSong = song
        finalSong.title = !enriched.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? enriched.title : song.title
        finalSong.artist = !enriched.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? enriched.artist : song.artist
        finalSong.album = !enriched.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? enriched.album : song.album
        finalSong.year = !enriched.year.isEmpty ? enriched.year : song.year
        finalSong.trackNumber = enriched.trackNumber != 0 ? enriched.trackNumber : song.trackNumber
        finalSong.discNumber = enriched.discNumber != 0 ? enriched.discNumber : song.discNumber
        finalSong.duration = enriched.duration != 0 ? enriched.duration : song.duration
        finalSong.musicBrainzReleaseID = enriched.musicBrainzReleaseID ?? song.musicBrainzReleaseID
        finalSong.externalURL = enriched.externalURL ?? song.externalURL
        finalSong.artwork = enriched.artwork ?? song.artwork

        saveEnrichedMetadata(for: finalSong)
        return finalSong
    }

    static func enrichWithDeezer(_ song: Song, fallbackArtist: String, fallbackTitle: String) async -> Song? {
        let artistQuery = fallbackArtist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let titleQuery = fallbackTitle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "https://api.deezer.com/search?q=track:\"\(titleQuery)\" artist:\"\(artistQuery)\""

        guard let url = URL(string: urlString) else { return nil }

        print("🔍 Querying Deezer for '\(fallbackTitle)' by \(fallbackArtist)")
        print("🔗 URL: \(urlString)")

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataArray = json["data"] as? [[String: Any]],
               let first = dataArray.first {
                
                var enriched = song
                if let title = first["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    enriched.title = title
                }
                if let artistDict = first["artist"] as? [String: Any],
                   let artistName = artistDict["name"] as? String,
                   !artistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    enriched.artist = artistName
                    print("🎤 Deezer Artist: \(artistName)")
                } else {
                    print("⚠️ Deezer could not determine artist.")
                }
                if let albumDict = first["album"] as? [String: Any],
                   let albumTitle = albumDict["title"] as? String,
                   !albumTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    enriched.album = albumTitle
                }
                // The genre fetching block from Deezer has been removed.
                if let duration = first["duration"] as? Int {
                    enriched.duration = Double(duration)
                    print("⏱️ Duration (Deezer): \(duration) seconds")
                }
                if let link = first["link"] as? String {
                    enriched.externalURL = link
                    print("🌐 Deezer Link: \(link)")
                }

                return enriched
            }
        } catch {
            print("❌ Deezer enrichment failed: \(error.localizedDescription)")
        }
        return nil
    }
}

import UIKit

extension MetadataEnricher {
    static func fetchArtwork(for song: Song) async throws -> Data? {
        guard let releaseID = song.musicBrainzReleaseID else { return nil }

        let url = URL(string: "https://coverartarchive.org/release/\(releaseID)/front")!
        var request = URLRequest(url: url)
        request.setValue("image/jpeg", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                print("⚠️ Cover art not found for release ID: \(releaseID)")
                return nil
            }
            return data
        } catch {
            print("❌ Failed to fetch artwork: \(error.localizedDescription)")
            return nil
        }
    }

    static func saveEnrichedMetadata(for song: Song) {
        if let artworkData = song.artwork {
            let artworkURL = song.url.deletingPathExtension().appendingPathExtension("jpg")
            try? artworkData.write(to: artworkURL, options: [.atomic])
            print("🖼️ Artwork saved to \(artworkURL.path)")
        }
        let metadata: [String: Any] = [
            "source": "musicbrainz + deezer",
            "title": song.title,
            "artist": song.artist,
            "album": song.album,
            // "genre": song.genre, // genre field removed as requested
            "year": song.year,
            "trackNumber": song.trackNumber,
            "discNumber": song.discNumber,
            "duration": song.duration,
            "musicBrainzReleaseID": song.musicBrainzReleaseID ?? "",
            "externalURL": song.externalURL ?? "",
            ]

        // Store JSON inside a `.metadata` subdirectory of the song’s folder
        let parentFolder = song.url.deletingLastPathComponent()
        let metadataFolder = parentFolder.appendingPathComponent(".metadata")
        try? FileManager.default.createDirectory(at: metadataFolder, withIntermediateDirectories: true, attributes: nil)
        let metadataURL = metadataFolder.appendingPathComponent(song.url.deletingPathExtension().lastPathComponent + ".json")
        do {
            let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: metadataURL, options: [.atomic])
            print("💾 Metadata saved to \(metadataURL.path)")
            print("📚 Metadata enrichment source: musicbrainz + deezer")
        } catch {
            print("❌ Failed to save metadata for \(song.title): \(error.localizedDescription)")
        }
    }
}
