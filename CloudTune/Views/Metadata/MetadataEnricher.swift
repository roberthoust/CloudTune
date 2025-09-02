//
//  MetadataEnricher.swift
//  CloudTune
//
//  One-pass, defensive enrichment for MP3/MP4/FLAC
//  EXACT PIPELINE (what we do, in order):
//  ┌────────────────────────────────────────────────────────────────────────────┐
//  │ 1) Read LOCAL TAGS (ID3 / iTunes atoms / Vorbis)                          │
//  │    - title, artist, album, year, track, disc, duration                    │
//  │    - albumArtist (TPE2/Band for ID3, ©alb "Album Artist" for iTunes)      │
//  │    - If artist is missing/placeholder or equals album, use albumArtist.   │
//  │                                                                            │
//  │ 2) FOLDER HINTS + FILENAME PARSING                                        │
//  │    - folderHints: infer (Artist, Album) from ".../Artist/Album/track.ext" │
//  │    - splitArtistTitle: parse filename patterns like                        │
//  │      "01 - Artist - Title", "Artist – Title", "Artist - Title".           │
//  │    - Fill only EMPTY/placeholder fields. Avoid overwriting good tags.     │
//  │                                                                            │
//  │ 3) MUSICBRAINZ RECORDING SEARCH (rate-limited, cached)                    │
//  │    - Build a Lucene query:                                                 │
//  │        recording:"<title>"^3 AND artist:"<artist>"^2                      │
//  │        AND dur:[<ms-5000> TO <ms+5000>] (if duration available)           │
//  │    - GET: /ws/2/recording/?query=...&fmt=json&limit=5&inc=releases        │
//  │    - Score candidates using title/artist similarity, folder hints,         │
//  │      and duration window. Accept only if score ≥ confidenceThreshold (0.70).│
//  │    - If accepted:                                                         │
//  │       * Overwrite title if better                                          │
//  │       * Overwrite artist if shouldReplaceArtist(...) allows it             │
//  │       * Set album (from first release), store release + release-group IDs  │
//  │       * Optionally fetch release detail to refine year/track/disc          │
//  │                                                                            │
//  │ 3b) FALLBACK MB QUERY USING FILENAME-PARSED ARTIST/TITLE                   │
//  │    - If the first MB query is below threshold, retry with parsed artist/title│
//  │      (useful when local tags are wrong).                                   │
//  │                                                                            │
//  │ 4) COVER ART ARCHIVE (if we have release or release-group):                │
//  │    - Try /release/<id>/front-250, then /release-group/<id>/front-250      │
//  │    - Cache in-memory, write JPEG sidecar next to audio file.               │
//  │                                                                            │
//  │ 5) DEEZER FALLBACK (fills only album/duration/link):                       │
//  │    - GET: /search?q=track:"<title>" artist:"<artist>"                     │
//  │    - Use only to fill missing album / duration / external link.            │
//  │    - Replace artist ONLY if placeholder or equals album (weak signal).     │
//  │                                                                            │
//  │ 6) WRITE SIDECAR JSON                                                      │
//  │    - .metadata/<filename>.json with: source, confidence, title, artist,    │
//  │      album, year, track, disc, duration, MBID, externalURL.               │
//  └────────────────────────────────────────────────────────────────────────────┘
//
//  Notes
//  - We never overwrite good data with placeholders ("Unknown", "No Album", etc.).
//  - We fix the common bad-tag case where Artist == Album.
//  - Artist replacement is guarded by shouldReplaceArtist(...), using confidence + heuristics.
//  - All network calls have timeouts, retries, simple in-memory caching, and polite MB headers.

import Foundation
import AVFoundation
import AudioToolbox
import OSLog

// MARK: - EXPECTED Song MODEL (for reference only)
// struct Song {
//     var title: String
//     var artist: String
//     var album: String
//     var year: String
//     var trackNumber: Int
//     var discNumber: Int
//     var duration: Double
//     var musicBrainzReleaseID: String?
//     var externalURL: String?
//     var artwork: Data?
//     let url: URL
// }

// MARK: - Config

private enum EnricherConfig {
    static let musicBrainzUserAgent = "CloudTune/1.0 (contact: support@cloudtune.app)"
    static let musicBrainzBase = "https://musicbrainz.org/ws/2"
    static let coverArtBase = "https://coverartarchive.org"
    static let deezerBase = "https://api.deezer.com"

    static let requestTimeout: TimeInterval = 12
    static let musicBrainzRateLimit: TimeInterval = 1.1  // ≥1 req/sec app-wide
    static let maxRetries = 2
    static let confidenceThreshold = 0.70                 // accept MB only if ≥ 0.70
}

private let log = Logger(subsystem: "app.cloudtune", category: "enrichment")

// MARK: - Simple in-memory cache (session only)

private actor MemoryCache<Value> {
    private var store: [String: Value] = [:]
    func get(_ key: String) -> Value? { store[key] }
    func set(_ key: String, _ value: Value) { store[key] = value }
}

private let responseCache = MemoryCache<Data>()

// MARK: - Global rate limiter for MusicBrainz politeness

private actor RateLimiter {
    private var last: Date?
    private let minInterval: TimeInterval
    init(minInterval: TimeInterval) { self.minInterval = minInterval }
    func acquire() async {
        let now = Date()
        if let last = last {
            let delta = now.timeIntervalSince(last)
            if delta < minInterval {
                let wait = minInterval - delta
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
        last = Date()
    }
}

private let mbLimiter = RateLimiter(minInterval: EnricherConfig.musicBrainzRateLimit)

// MARK: - HTTP helpers (timeouts, retries, polite headers)

private struct HTTP {
    static func getData(url: URL,
                        headers: [String:String] = [:],
                        cacheKey: String? = nil,
                        politeMB: Bool = false) async throws -> Data {
        if let cacheKey, let cached = await responseCache.get(cacheKey) { return cached }

        var req = URLRequest(url: url, timeoutInterval: EnricherConfig.requestTimeout)
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }

        if politeMB {
            await mbLimiter.acquire()
            req.setValue(EnricherConfig.musicBrainzUserAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
        }

        var lastError: Error?
        for attempt in 0...EnricherConfig.maxRetries {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                if (200..<300).contains(http.statusCode) {
                    if let cacheKey { await responseCache.set(cacheKey, data) }
                    return data
                }
                // Retry on 5xx
                if (500..<600).contains(http.statusCode) && attempt < EnricherConfig.maxRetries {
                    let backoff = Double(attempt + 1) * 0.75
                    try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                    continue
                }
                throw URLError(.badServerResponse)
            } catch {
                lastError = error
                if attempt < EnricherConfig.maxRetries {
                    let backoff = Double(attempt + 1) * 0.5
                    try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                    continue
                }
            }
        }
        throw lastError ?? URLError(.cannotLoadFromNetwork)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        return try dec.decode(T.self, from: data)
    }
}

// MARK: - String cleaning & parsing

private func isPlaceholder(_ s: String) -> Bool {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return t.isEmpty || t == "no album" || t == "unknown album" || t == "unknown artist" || t == "unknown"
}

/// Normalizes a raw title/filename:
/// - Converts `_` and `.` to spaces
/// - Removes bracketed/parenthetical noise like `[Official Video]`, `(Lyrics)`
/// - Drops common quality tags like `320kbps`
/// - Collapses multiple spaces
private func normalizeTitle(_ s: String) -> String {
    var t = s
    t = t.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".", with: " ")
    let noise = [
        #"\[(.*?)\]"#, #"\((.*?)\)"#,
        #"(?i)\b(official\s*video|lyrics?|remaster(ed)?\s*\d{2,4}|audio|HD|4K|8K|mv|feat\.?\s*.*?)\b"#,
        #"(?i)\b\d{3,4}\s*kbps\b"#
    ]
    for p in noise { t = t.replacingOccurrences(of: p, with: "", options: .regularExpression) }
    t = t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
         .trimmingCharacters(in: .whitespacesAndNewlines)
    return t
}

/// Parses common filename patterns into (artist,title) using separators (`-`, `–`, `—`)
/// Examples:
///   "01 - Artist - Title" → ("Artist", "Title")
///   "Artist – Title"      → ("Artist", "Title")
/// Fall back to the provided `fallbackArtist` if no artist pattern is detected.
private func splitArtistTitle(_ raw: String, fallbackArtist: String?) -> (artist: String?, title: String) {
    let cleaned = normalizeTitle(raw)
    let seps = [" - ", " – ", " — ", "- ", " –", " —"]
    var parts = [cleaned]
    for sep in seps where cleaned.contains(sep) {
        parts = cleaned.components(separatedBy: sep).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        break
    }
    if parts.count >= 3, Int(parts[0]) != nil { // "01 - Artist - Title"
        return (artist: parts[1], title: parts.dropFirst(2).joined(separator: " - "))
    } else if parts.count >= 2 {
        return (artist: parts[0], title: parts.dropFirst().joined(separator: " - "))
    }
    return (artist: (fallbackArtist?.isEmpty == false ? fallbackArtist : nil), title: cleaned)
}

private func similarity(_ a: String, _ b: String) -> Double {
    // Keep only letters for a forgiving comparison, then compare the common prefix length.
    let na = a.lowercased().components(separatedBy: CharacterSet.letters.inverted).joined()
    let nb = b.lowercased().components(separatedBy: CharacterSet.letters.inverted).joined()
    if na.isEmpty || nb.isEmpty { return 0 }
    if na == nb { return 1 }
    let minLen = min(na.count, nb.count)
    let prefixEq = na.commonPrefix(with: nb).count
    return max(Double(prefixEq) / Double(minLen), 0.0)
}

private func coalesce(_ new: String?, _ old: String) -> String {
    let n = (new ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return n.isEmpty ? old : n
}

private func coalesceSmart(_ new: String?, _ old: String) -> String {
    let n = (new ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if isPlaceholder(n) { return old }
    return n.isEmpty ? old : n
}

private func coalesceInt(_ new: Int?, _ old: Int) -> Int { (new ?? 0) != 0 ? (new ?? 0) : old }

// MARK: - Local tag reading

private struct LocalProbeResult {
    let title: String?
    let artist: String?
    let album: String?
    let albumArtist: String?
    let year: String?
    let trackNumber: Int?
    let discNumber: Int?
    let durationSec: Double?
}

/// FLAC Vorbis Comments via AudioToolbox (AVFoundation often omits these).
private func readFlacInfoDictionary(_ url: URL) -> [String:String] {
    var fileID: AudioFileID?
    let status = AudioFileOpenURL(url as CFURL, .readPermission, kAudioFileFLACType, &fileID)
    guard status == noErr, let fileID else { return [:] }
    defer { AudioFileClose(fileID) }

    var propSize: UInt32 = 0
    var dictRef: Unmanaged<CFDictionary>?

    let s1 = AudioFileGetPropertyInfo(fileID, kAudioFilePropertyInfoDictionary, &propSize, nil)
    guard s1 == noErr else { return [:] }
    let s2 = AudioFileGetProperty(fileID, kAudioFilePropertyInfoDictionary, &propSize, &dictRef)
    guard s2 == noErr, let cfDict = dictRef?.takeRetainedValue() as? [String:Any] else { return [:] }

    var out: [String:String] = [:]
    for (k, v) in cfDict {
        if let s = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            out[k.lowercased()] = s
        }
    }
    return out
}

/// Reads local metadata from the file:
/// - MP3/MP4 (via AVFoundation common/ID3/iTunes atoms)
/// - FLAC (Vorbis Comments via AudioToolbox), then duration via AVURLAsset
/// Fields populated (if present):
///   title, artist, album, albumArtist (TPE2/Band / iTunes Album Artist),
///   year (YYYY truncated), trackNumber, discNumber, durationSec
/// IMPORTANT:
/// - We DO NOT overwrite existing non-placeholder fields later unless MB confidence allows it
/// - If `artist` is missing/placeholder or equals `album`, we prefer `albumArtist` at step 0.
private func readLocalTags(from url: URL) -> LocalProbeResult {
    let ext = url.pathExtension.lowercased()

    // 1) FLAC → Vorbis Comments (via AudioToolbox)
    if ext == "flac" {
        let d = readFlacInfoDictionary(url)
        func parseInt(_ s: String?) -> Int? { s?.split(separator: "/").first.flatMap { Int($0) } }
        let year = d["date"].flatMap { String($0.prefix(4)) } ?? d["year"]

        // Duration: get via AVURLAsset even for FLAC (works reliably).
        let asset = AVURLAsset(url: url)
        let dur = asset.duration.isNumeric ? CMTimeGetSeconds(asset.duration) : nil

        return LocalProbeResult(
            title: d["title"],
            artist: d["artist"],
            album: d["album"],
            albumArtist: (d["album artist"] ?? d["albumartist"] ?? d["album_artist"]),
            year: year,
            trackNumber: parseInt(d["tracknumber"]),
            discNumber: parseInt(d["discnumber"]),
            durationSec: dur
        )
    }

    // 2) Other containers (MP3/MP4) → AVFoundation common/ID3/iTunes atoms
    let asset = AVURLAsset(url: url)
    let meta = asset.commonMetadata

    // Album Artist (iTunes + ID3 TPE2/Band)
    let albumArtist =
        AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: .iTunesMetadataAlbumArtist).first?.stringValue
        ?? AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: .id3MetadataBand).first?.stringValue

    func string(_ key: AVMetadataKey, keySpace: AVMetadataKeySpace) -> String? {
        AVMetadataItem.metadataItems(from: meta, withKey: key, keySpace: keySpace).first?.stringValue
    }

    let title = AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: .commonIdentifierTitle).first?.stringValue
        ?? string(.id3MetadataKeyTitleDescription, keySpace: .id3)

    let artist = AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: .commonIdentifierArtist).first?.stringValue
        ?? string(.id3MetadataKeyLeadPerformer, keySpace: .id3)

    let album = AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: .commonIdentifierAlbumName).first?.stringValue
        ?? string(.id3MetadataKeyAlbumTitle, keySpace: .id3)

    // Pull track/disc from both ID3 and iTunes atoms.
    // ID3 often stores them as "3/12"; iTunes atoms can be numeric.
    let trackString =
        AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: .id3MetadataTrackNumber).first?.stringValue
        ?? AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: .iTunesMetadataTrackNumber).first?.numberValue?.stringValue

    let discString =
        AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: .id3MetadataPartOfASet).first?.stringValue
        ?? AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: .iTunesMetadataDiscNumber).first?.numberValue?.stringValue

    func parsePairFirstInt(_ s: String?) -> Int? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s.split(separator: "/").first.flatMap { Int($0) } ?? Int(s)
    }

    // Year can be ID3 (Year) or iTunes (ReleaseDate = "YYYY-MM-DD" or full ISO)
    let yearString =
        AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: .id3MetadataYear).first?.stringValue
        ?? AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: .iTunesMetadataReleaseDate).first?.stringValue

    let year = yearString.flatMap { String($0.prefix(4)) }

    let duration = asset.duration.isNumeric ? CMTimeGetSeconds(asset.duration) : nil

    return LocalProbeResult(
        title: title,
        artist: artist,
        album: album,
        albumArtist: albumArtist,
        year: year,
        trackNumber: parsePairFirstInt(trackString),
        discNumber: parsePairFirstInt(discString),
        durationSec: duration
    )
}

// MARK: - Folder hints (Artist/Album from path)

/// ".../Artist/Album/09 Momma.flac" → ("Artist","Album")
private func folderHints(from url: URL) -> (artist: String?, album: String?) {
    let album = url.deletingPathExtension().deletingLastPathComponent().lastPathComponent
    let artist = url.deletingPathExtension().deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
    func clean(_ s: String) -> String? {
        let bad = ["music", "flac", "mp3", "downloads", "songs", "audio"]
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return bad.contains(t.lowercased()) ? nil : t
    }
    return (clean(artist), clean(album))
}

// MARK: - MusicBrainz DTOs

private struct MBSearchResponse: Decodable {
    let recordings: [MBRecording]?
}

private struct MBRecording: Decodable {
    let id: String
    let title: String
    let length: Int?                 // milliseconds
    let artistCredit: [MBArtistCredit]
    let releases: [MBRelease]?
    enum CodingKeys: String, CodingKey {
        case id, title, length, releases
        case artistCredit = "artist-credit"
    }
}

private struct MBArtistCredit: Decodable { let name: String }

private struct MBRelease: Decodable {
    let id: String
    let title: String
    let releaseGroup: MBReleaseGroup?
    enum CodingKeys: String, CodingKey {
        case id, title
        case releaseGroup = "release-group"
    }
}

private struct MBReleaseGroup: Decodable {
    let id: String?
    let primaryType: String?
    enum CodingKeys: String, CodingKey {
        case id
        case primaryType = "primary-type"
    }
}

private struct MBReleaseDetail: Decodable {
    let date: String?
    let media: [MBMedium]?
}

private struct MBMedium: Decodable {
    let position: Int?
    let tracks: [MBTrack]?
}

private struct MBTrack: Decodable {
    let number: String?
    let title: String?
}

// MARK: - Deezer DTOs (minimal)

private struct DeezerSearchResponse: Decodable { let data: [DeezerTrack] }
private struct DeezerTrack: Decodable {
    let title: String?
    let duration: Int?
    let link: String?
    let artist: DeezerArtist?
    let album: DeezerAlbum?
}
private struct DeezerArtist: Decodable { let name: String? }
private struct DeezerAlbum: Decodable { let title: String? }

// MARK: - MB / DZ calls

/// Constructs a MusicBrainz Lucene query:
///   recording:"<title>"^3 AND artist:"<artist>"^2 [AND dur:range]
/// Duration range = ±5 seconds (in milliseconds), if duration is known.
/// We boost `recording` 3× and `artist` 2× to bias towards exact title matches.
private func buildMBQuery(artist: String, title: String, duration: Double?) -> String {
    let a = artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
    let t = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
    var q = "recording:\"\(t)\"^3 AND artist:\"\(a)\"^2"
    // If we know the duration, narrow the search window to ±5s to reduce false positives.
    if let d = duration, d > 0 {
        let ms = Int(d * 1000)
        let lo = max(ms - 5000, 0)
        let hi = ms + 5000
        q += " AND dur:[\(lo) TO \(hi)]"  // duration window in ms
    }
    return q
}

/// Executes the MB recording search (polite, cached):
/// - Respects global rate limit (≥1 req/sec)
/// - Adds User-Agent and Accept headers
/// - Caches responses in-memory by full URL
/// - Returns up to 5 candidates including `releases` for album inference
private func searchMusicBrainz(artist: String, title: String, duration: Double?) async -> [MBRecording] {
    let q = buildMBQuery(artist: artist, title: title, duration: duration)
    let urlStr = "\(EnricherConfig.musicBrainzBase)/recording/?query=\(q)&fmt=json&limit=5&inc=releases"
    guard let url = URL(string: urlStr) else { return [] }
    do {
        let data = try await HTTP.getData(url: url, cacheKey: "mb:\(urlStr)", politeMB: true)
        let resp = try HTTP.decode(MBSearchResponse.self, from: data)
        return resp.recordings ?? []
    } catch {
        log.warning("MB search failed: \(error.localizedDescription, privacy: .public)")
        return []
    }
}

/// Fetches MB release detail for the chosen release:
/// - Used to refine `year`, `discNumber`, and `trackNumber`
/// - We search the medium/tracks for a normalized-title match to compute trackNumber
private func fetchMBReleaseDetail(releaseID: String) async -> MBReleaseDetail? {
    let urlStr = "\(EnricherConfig.musicBrainzBase)/release/\(releaseID)?fmt=json&inc=recordings+artist-credits+labels"
    guard let url = URL(string: urlStr) else { return nil }
    do {
        let data = try await HTTP.getData(url: url, cacheKey: "mbrel:\(releaseID)", politeMB: true)
        return try HTTP.decode(MBReleaseDetail.self, from: data)
    } catch {
        log.info("MB release detail failed for \(releaseID): \(error.localizedDescription, privacy: .public)")
        return nil
    }
}

/// Fetches cover art JPEG bytes from Cover Art Archive:
/// - First try the specific `release` front-250
/// - Fallback to the broader `release-group` front-250
/// - Cached by release / release-group id
private func fetchArtworkData(releaseID: String?, releaseGroupID: String?) async -> Data? {
    // Try release first (more specific), then release-group
    if let rid = releaseID, let url = URL(string: "\(EnricherConfig.coverArtBase)/release/\(rid)/front-250") {
        if let data = try? await HTTP.getData(url: url, headers: ["Accept":"image/jpeg"], cacheKey: "art:rel:\(rid)") {
            return data
        }
    }
    if let rgid = releaseGroupID, let url = URL(string: "\(EnricherConfig.coverArtBase)/release-group/\(rgid)/front-250") {
        if let data = try? await HTTP.getData(url: url, headers: ["Accept":"image/jpeg"], cacheKey: "art:rg:\(rgid)") {
            return data
        }
    }
    return nil
}

/// Queries Deezer as a weak-signal fallback:
/// - GET /search?q=track:"title" artist:"artist"
/// - Used to fill missing album/duration/link only
/// - Artist is only replaced if current artist is placeholder or equals album
private func searchDeezer(artist: String, title: String) async -> DeezerTrack? {
    let t = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
    let a = artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
    let urlStr = "\(EnricherConfig.deezerBase)/search?q=track:\"\(t)\" artist:\"\(a)\""
    guard let url = URL(string: urlStr) else { return nil }
    do {
        let data = try await HTTP.getData(url: url, cacheKey: "dz:\(urlStr)")
        let resp = try HTTP.decode(DeezerSearchResponse.self, from: data)
        return resp.data.first
    } catch {
        log.info("Deezer search failed: \(error.localizedDescription, privacy: .public)")
        return nil
    }
}

// MARK: - Scoring & merging

// MARK: - Local tag reading

// MARK: - Scoring & merge helpers

private func candidateScore(file: Song, mb: MBRecording, folderArtist: String?, folderAlbum: String?) -> Double {
    var s = 0.0
    s += similarity(file.title, mb.title) * 0.45
    if let ac = mb.artistCredit.first?.name { s += similarity(file.artist, ac) * 0.35 }
    if let fA = folderArtist, let ac = mb.artistCredit.first?.name { s += similarity(fA, ac) * 0.10 }
    if let rel = mb.releases?.first, let fAlb = folderAlbum { s += similarity(fAlb, rel.title) * 0.05 }
    if file.duration > 0, let mbMs = mb.length {
        let delta = abs(file.duration - Double(mbMs)/1000.0)
        s += (delta <= 2.5 ? 0.05 : delta <= 5 ? 0.02 : 0.0)
    }
    return min(s, 1.0)
}

/// Joins MusicBrainz artist credits into a display string ("A, B, C") for the track.
private func mbArtistString(from credits: [MBArtistCredit]) -> String {
    if credits.isEmpty { return "" }
    return credits.map { $0.name }.joined(separator: ", ")
}

/// Decides whether to overwrite the current artist with a new candidate:
/// - Always reject empty candidates
/// - Replace if current is a placeholder or equals the album name (common bad tag)
/// - Replace if MB confidence ≥ 0.80 AND names are sufficiently different (similarity < 0.40)
private func shouldReplaceArtist(old: String, with new: String, album: String, confidence: Double) -> Bool {
    let oldTrim = old.trimmingCharacters(in: .whitespacesAndNewlines)
    let newTrim = new.trimmingCharacters(in: .whitespacesAndNewlines)
    if newTrim.isEmpty { return false }
    // Replace if the current artist is clearly a placeholder or equals the album (common bad tag)
    if isPlaceholder(oldTrim) || (!album.isEmpty && oldTrim.caseInsensitiveCompare(album) == .orderedSame) { return true }
    // If MB is confident and names are quite different, prefer MB.
    if confidence >= 0.80 && similarity(oldTrim, newTrim) < 0.40 { return true }
    return false
}

// MARK: - Public API

final class MetadataEnricher {

    /// Main entry: Local tags → folder hints → filename → MusicBrainz → Artwork → Deezer → Save sidecar
    static func enrich(_ song: Song) async throws -> Song {
        var working = song

        // STEP 1 — LOCAL TAGS
        // Read everything we can from the file first (works offline, fastest).
        // Also capture albumArtist for the common "Artist == Album" bad-tag case.
        let local = readLocalTags(from: song.url)
        working.title       = coalesceSmart(local.title, working.title)
        working.artist      = coalesceSmart(local.artist, working.artist)
        working.album       = coalesceSmart(local.album, working.album)
        working.year        = coalesceSmart(local.year, working.year)
        working.trackNumber = coalesceInt(local.trackNumber, working.trackNumber)
        working.discNumber  = coalesceInt(local.discNumber, working.discNumber)
        if working.duration == 0, let d = local.durationSec { working.duration = d }

        // STEP 1a — Album Artist fallback
        // If artist is missing/placeholder OR equals album, prefer the albumArtist (Band/TPE2).
        if (isPlaceholder(working.artist) || (!working.album.isEmpty && working.artist.caseInsensitiveCompare(working.album) == .orderedSame)),
           let aa = local.albumArtist, !aa.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            working.artist = aa
        }

        // STEP 2 — FOLDER HINTS
        // Infer Artist/Album from the parent folders (only if fields are empty/placeholder).
        let hints = folderHints(from: song.url)
        if isPlaceholder(working.artist), let ha = hints.artist { working.artist = ha }
        if isPlaceholder(working.album),  let hb = hints.album  { working.album  = hb }

        // STEP 2b — FILENAME PARSING
        // Parse "Artist - Title" (and variations). Use only to fill missing/placeholder fields.
        let nameNoExt = song.url.deletingPathExtension().lastPathComponent
        let parsed = splitArtistTitle(nameNoExt, fallbackArtist: working.artist.isEmpty ? nil : working.artist)
        if working.title.trimmingCharacters(in: .whitespaces).isEmpty { working.title = parsed.title }
        // If artist is empty OR (bad tag where artist == album), prefer filename-parsed artist when present
        if (working.artist.trimmingCharacters(in: .whitespaces).isEmpty || working.artist.caseInsensitiveCompare(working.album) == .orderedSame),
           let a = parsed.artist, !a.trimmingCharacters(in: .whitespaces).isEmpty {
            working.artist = a
        }

        log.debug("Cleaned → title='\(working.title, privacy: .public)' artist='\(working.artist, privacy: .public)' album='\(working.album, privacy: .public)'")

        // EARLY EXIT — If we now have good title/artist/album/duration, persist and return.
        if !isPlaceholder(working.title),
           !isPlaceholder(working.artist),
           !isPlaceholder(working.album),
           working.duration > 0 {
            saveSidecar(for: working, confidence: 1.0, queryUsed: "local")
            return working
        }

        // STEP 3 — MUSICBRAINZ (using current artist/title)
        // Build weighted query; fetch up to 5 candidates; score them; accept only if ≥ threshold.
        var releaseID: String?
        var releaseGroupID: String?
        var confidenceUsed: Double = 0.0
        var queryUsed = "none"

        if !working.title.isEmpty, !working.artist.isEmpty {
            let cands = await searchMusicBrainz(artist: working.artist, title: working.title, duration: working.duration)
            if !cands.isEmpty {
                let scored = cands.map { (cand: $0, score: candidateScore(file: working, mb: $0, folderArtist: hints.artist, folderAlbum: hints.album)) }
                if let best = scored.max(by: { $0.score < $1.score }) {
                    confidenceUsed = best.score
                    queryUsed = "musicbrainz"
                    if best.score >= EnricherConfig.confidenceThreshold {
                        let rec = best.cand
                        working.title = coalesceSmart(rec.title, working.title)
                        let mbArtist = mbArtistString(from: rec.artistCredit)
                        if shouldReplaceArtist(old: working.artist, with: mbArtist, album: working.album, confidence: best.score) {
                            working.artist = mbArtist
                        }
                        if let rel = rec.releases?.first {
                            working.album = coalesceSmart(rel.title, working.album)
                            releaseID = rel.id
                            releaseGroupID = rel.releaseGroup?.id
                            working.musicBrainzReleaseID = rel.id
                        }
                        // STEP 3a — REFINE WITH RELEASE DETAIL (year/disc/track)
                        if let rid = releaseID, let detail = await fetchMBReleaseDetail(releaseID: rid) {
                            if let date = detail.date, !date.isEmpty { working.year = coalesceSmart(String(date.prefix(4)), working.year) }
                            if let medium = detail.media?.first {
                                working.discNumber = coalesceInt(medium.position, working.discNumber)
                                if let tracks = medium.tracks {
                                    let ntarget = normalizeTitle(working.title).lowercased()
                                    if let match = tracks.first(where: { normalizeTitle($0.title ?? "").lowercased() == ntarget }),
                                       let tn = match.number, let n = Int(tn) {
                                        working.trackNumber = coalesceInt(n, working.trackNumber)
                                    } else if working.trackNumber == 0,
                                              let idx = tracks.firstIndex(where: {
                                                  let nt = normalizeTitle($0.title ?? "").lowercased()
                                                  return nt.contains(ntarget) || ntarget.contains(nt)
                                              }) {
                                        working.trackNumber = idx + 1
                                    }
                                }
                            }
                        }
                        // STEP 4 — COVER ART (Release → Release-Group)
                        if working.artwork == nil {
                            if let art = await fetchArtworkData(releaseID: releaseID, releaseGroupID: releaseGroupID) {
                                working.artwork = art
                                let artworkURL = song.url.deletingPathExtension().appendingPathExtension("jpg")
                                try? art.write(to: artworkURL, options: [.atomic])
                            }
                        }
                    } else {
                        log.info("MB match below threshold (score=\(best.score, privacy: .public)); keeping local/folder values.")
                    }
                }
            }
        }

        // STEP 3b — FALLBACK MB QUERY (Filename-derived artist/title)
        // Helps when local tags are wrong but the filename is correct.
        if confidenceUsed < EnricherConfig.confidenceThreshold {
            if let parsedArtist = parsed.artist, !parsedArtist.isEmpty {
                let cands2 = await searchMusicBrainz(artist: parsedArtist, title: parsed.title, duration: working.duration)
                if !cands2.isEmpty {
                    let scored2 = cands2.map { (cand: $0, score: candidateScore(file: working, mb: $0,
                                                                              folderArtist: hints.artist,
                                                                              folderAlbum: hints.album)) }
                    if let best2 = scored2.max(by: { $0.score < $1.score }),
                       best2.score >= EnricherConfig.confidenceThreshold {
                        let rec2 = best2.cand
                        confidenceUsed = best2.score
                        queryUsed = queryUsed == "none" ? "musicbrainz(filename)" : "\(queryUsed)+filename"
                        working.title = coalesceSmart(rec2.title, working.title)
                        let mbArtist2 = mbArtistString(from: rec2.artistCredit)
                        if shouldReplaceArtist(old: working.artist, with: mbArtist2, album: working.album, confidence: best2.score) {
                            working.artist = mbArtist2
                        }
                        if let rel2 = rec2.releases?.first {
                            working.album = coalesceSmart(rel2.title, working.album)
                            releaseID = rel2.id
                            releaseGroupID = rel2.releaseGroup?.id
                            working.musicBrainzReleaseID = rel2.id
                        }
                    }
                }
            }
        }

        // STEP 5 — DEEZER FALLBACK (fill album/duration/link only)
        if (working.album.isEmpty || working.duration == 0),
           !working.title.isEmpty, !working.artist.isEmpty,
           let dz = await searchDeezer(artist: working.artist, title: working.title) {
            queryUsed = (confidenceUsed > 0 ? queryUsed + "+deezer" : "deezer")
            working.title  = coalesceSmart(dz.title, working.title)
            if let an = dz.artist?.name {
                // Deezer is a weaker signal; only replace if artist is placeholder or equals album
                if isPlaceholder(working.artist) || working.artist.caseInsensitiveCompare(working.album) == .orderedSame {
                    working.artist = an
                }
            }
            if let alb = dz.album?.title { working.album = coalesceSmart(alb, working.album) }
            if let dur = dz.duration, working.duration == 0 { working.duration = Double(dur) }
            if let link = dz.link { working.externalURL = link }
        }

        // STEP 6 — WRITE SIDECAR (diagnostics & provenance)
        // We persist source + confidence + core tags next to the audio for later debugging.
        saveSidecar(for: working, confidence: max(confidenceUsed, working.title.isEmpty ? 0 : 0.6), queryUsed: queryUsed)
        return working
    }

    // MARK: - Sidecar save (JSON next to file)
    /// Persists a JSON sidecar in `.metadata/` next to the audio file including:
    ///   source (which queries were used), rounded confidence, core tags, MBID, externalURL.
    /// This makes later debugging and incremental rescans deterministic and observable.
    private static func saveSidecar(for song: Song, confidence: Double, queryUsed: String) {
        let meta: [String: Any] = [
            "source": queryUsed.isEmpty ? "local" : queryUsed,
            "confidence": Double(round(confidence * 100)) / 100.0,
            "title": song.title,
            "artist": song.artist,
            "album": song.album,
            "year": song.year,
            "trackNumber": song.trackNumber,
            "discNumber": song.discNumber,
            "duration": song.duration,
            "musicBrainzReleaseID": song.musicBrainzReleaseID ?? "",
            "externalURL": song.externalURL ?? ""
        ]

        let parent = song.url.deletingLastPathComponent()
        let metadataFolder = parent.appendingPathComponent(".metadata")
        do {
            try FileManager.default.createDirectory(at: metadataFolder, withIntermediateDirectories: true)
            let file = metadataFolder.appendingPathComponent(song.url.deletingPathExtension().lastPathComponent + ".json")
            let data = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: file, options: [.atomic])
            log.debug("Sidecar written → \(file.path, privacy: .public)")
        } catch {
            log.error("Sidecar write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Compatibility shim (keeps older call sites compiling)

extension MetadataEnricher {
    static func fetchArtwork(for song: Song) async throws -> Data? {
        await fetchArtworkData(releaseID: song.musicBrainzReleaseID, releaseGroupID: nil)
    }
}
