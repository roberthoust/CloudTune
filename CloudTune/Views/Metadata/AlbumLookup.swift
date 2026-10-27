//
//  AlbumLookup.swift
//  CloudTune
//
//  Fills in album-level details the files don't have: release year, genre, cover art,
//  track numbers, and artists on songs whose tag holds the album name instead.
//  One MusicBrainz lookup per album (not per song), results kept in the database.
//
//  Only fills gaps: existing years, genres, track numbers and real artwork are never replaced.
//

import Foundation

/// What MusicBrainz knows about one album. Stored in the `albumInfo` table.
struct AlbumInfo: Codable, Equatable {
    struct Track: Codable, Equatable {
        var disc: Int
        var number: Int
        var title: String
        var artist: String
    }

    var key: String
    var releaseID: String?          // nil when the album wasn't found
    var releaseGroupID: String?
    var title: String?
    var artist: String?
    var year: String?
    var genre: String?
    var tracks: [Track] = []
    var hasCover = false
    var checkedAt = Date()

    var found: Bool { releaseID != nil }
}

enum AlbumLookup {
    /// An album in the library that's missing something we can look up.
    struct Group: Equatable {
        let album: String
        let artist: String
        let songIDs: [String]
        let needsCover: Bool
    }

    /// Albums that weren't found are searched again after this long (MusicBrainz grows).
    static let retryNotFoundAfter: TimeInterval = 30 * 24 * 3600

    static func key(album: String, artist: String) -> String {
        "\(fold(album))|\(fold(artist))"
    }

    // MARK: - Which albums need it

    static func groups(in songs: [Song], defaultArtworkID: String?) -> [Group] {
        let byAlbum = Dictionary(grouping: songs) { $0.album.trimmingCharacters(in: .whitespacesAndNewlines) }
        return byAlbum.compactMap { album, songs -> Group? in
            guard !isPlaceholder(album) else { return nil }
            let needsCover = songs.contains { $0.artworkID == nil || $0.artworkID == defaultArtworkID }
            let needsMore = needsCover || songs.contains {
                $0.year.trimmingCharacters(in: .whitespaces).isEmpty
                    || $0.genre.trimmingCharacters(in: .whitespaces).isEmpty
                    || $0.trackNumber == 0
                    || hasBadArtist($0, album: album)
            }
            guard needsMore else { return nil }
            return Group(album: album, artist: albumArtist(of: songs, album: album),
                         songIDs: songs.map(\.id), needsCover: needsCover)
        }
        .sorted { $0.album.localizedStandardCompare($1.album) == .orderedAscending }
    }

    /// The album's main artist: the most common one, ignoring tags that just repeat the album name.
    static func albumArtist(of songs: [Song], album: String) -> String {
        func mostCommon(_ names: [String]) -> String? {
            Dictionary(grouping: names, by: { $0 }).max { $0.value.count < $1.value.count }?.key
        }
        let artists = songs.map { $0.artist.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !isPlaceholder($0) }
        return mostCommon(artists.filter { fold($0) != fold(album) }) ?? mostCommon(artists) ?? ""
    }

    // MARK: - Network

    /// Searches MusicBrainz for the album and reads the best match.
    /// Returns an AlbumInfo with `found == false` when MusicBrainz has no such album (worth saving),
    /// or nil when a request failed (not worth saving: try again next time).
    static func lookUp(album: String, artist: String, songCount: Int) async -> AlbumInfo? {
        var info = AlbumInfo(key: key(album: album, artist: artist))
        guard let candidates = await searchReleases(album: album, artist: artist) else { return nil }
        guard let best = bestRelease(candidates, album: album, artist: artist, songCount: songCount) else { return info }
        guard let detail = await releaseDetail(id: best.id) else { return nil }

        info.releaseID = best.id
        info.releaseGroupID = detail.releaseGroup?.id ?? best.releaseGroup?.id
        info.title = detail.title ?? best.title
        info.artist = creditString(detail.artistCredit ?? best.artistCredit)
        info.year = year(from: detail.releaseGroup?.firstReleaseDate) ?? year(from: detail.date ?? best.date)
        // Album-level genres have few votes; adding every track's makes the pick much more reliable.
        let trackGenres = (detail.media ?? []).flatMap { ($0.tracks ?? []).flatMap { $0.recording?.genres ?? [] } }
        info.genre = topGenre((detail.releaseGroup?.genres ?? []) + (detail.genres ?? []) + trackGenres)
        info.hasCover = detail.coverArtArchive?.front ?? true
        info.tracks = (detail.media ?? []).flatMap { medium in
            (medium.tracks ?? []).compactMap { t -> AlbumInfo.Track? in
                guard let title = t.title, let number = t.position else { return nil }
                return AlbumInfo.Track(disc: medium.position ?? 1, number: number, title: title,
                                       artist: creditString(t.artistCredit) ?? info.artist ?? "")
            }
        }
        return info
    }

    /// Front cover from the Cover Art Archive (release first, then release group), ~500 px.
    static func coverArt(for info: AlbumInfo) async -> Data? {
        guard info.hasCover else { return nil }
        let paths = [info.releaseID.map { "release/\($0)" }, info.releaseGroupID.map { "release-group/\($0)" }]
        for path in paths.compactMap({ $0 }) {
            guard let url = URL(string: "\(EnricherConfig.coverArtBase)/\(path)/front-500") else { continue }
            if let data = try? await HTTP.getData(url: url, headers: ["Accept": "image/jpeg"]), !data.isEmpty {
                return data
            }
        }
        return nil
    }

    private static func searchReleases(album: String, artist: String) async -> [MBReleaseHit]? {
        var query = "release:\"\(luceneEscape(album))\""
        if !artist.isEmpty { query += " AND artist:\"\(luceneEscape(artist))\"" }
        guard let url = musicBrainzURL("release", ["query": query, "fmt": "json", "limit": "10"]),
              let data = try? await HTTP.getData(url: url, politeMB: true) else { return nil }
        return (try? JSONDecoder().decode(MBReleaseSearch.self, from: data))?.releases
    }

    private static func releaseDetail(id: String) async -> MBReleaseFull? {
        guard let url = musicBrainzURL("release/\(id)", ["fmt": "json", "inc": "recordings artist-credits release-groups genres"]),
              let data = try? await HTTP.getData(url: url, politeMB: true) else { return nil }
        return try? JSONDecoder().decode(MBReleaseFull.self, from: data)
    }

    // MARK: - Choosing a release

    /// Best search hit that really is this album: same title (ignoring "(Deluxe)" etc. and punctuation)
    /// and artist. Prefers a track count that fits our songs, official releases, albums, then the earliest.
    static func bestRelease(_ hits: [MBReleaseHit], album: String, artist: String, songCount: Int) -> MBReleaseHit? {
        let wantedArtist = comparable(artist)
        let matches = hits.filter { hit in
            guard (hit.score ?? 0) >= 80, sameTitle(hit.title ?? "", album) else { return false }
            guard !wantedArtist.isEmpty else { return true }
            let credited = comparable(creditString(hit.artistCredit) ?? "")
            return credited.contains(wantedArtist) || (!credited.isEmpty && wantedArtist.contains(credited))
        }
        return matches.min { a, b in
            func rank(_ h: MBReleaseHit) -> (Int, Int, Int, Int, String) {
                let tracks = h.trackCount ?? 0
                return (tracks >= songCount ? 0 : 1,
                        abs(tracks - songCount),
                        h.status == "Official" ? 0 : 1,
                        h.releaseGroup?.primaryType == "Album" ? 0 : 1,
                        h.date.flatMap { $0.isEmpty ? nil : $0 } ?? "9999")
            }
            return rank(a) < rank(b)
        }
    }

    /// Same album title, also when one side has a subtitle after a colon
    /// ("I Don't Like Shit, I Don't Go Outside: An Album by Earl Sweatshirt").
    static func sameTitle(_ a: String, _ b: String) -> Bool {
        func main(_ s: String) -> String { comparable(String(s.split(separator: ":", maxSplits: 1).first ?? "")) }
        let ca = comparable(a), cb = comparable(b)
        return !ca.isEmpty && (ca == cb || main(a) == cb || ca == main(b))
    }

    // MARK: - Applying to songs

    /// Fills this song's gaps from the album info. Never overwrites a real value.
    /// - coverID: artwork ID of the downloaded album cover, if any.
    static func apply(_ info: AlbumInfo, to song: Song, album: String,
                      coverID: String?, defaultArtworkID: String?) -> Song {
        var s = song
        if s.year.trimmingCharacters(in: .whitespaces).isEmpty, let y = info.year { s.year = y }
        if s.genre.trimmingCharacters(in: .whitespaces).isEmpty, let g = info.genre { s.genre = g }
        if s.musicBrainzReleaseID == nil { s.musicBrainzReleaseID = info.releaseID }
        if let coverID, s.artworkID == nil || s.artworkID == defaultArtworkID { s.artworkID = coverID }

        // Track numbers only, not discs: files often number a whole album 1…N while MusicBrainz
        // splits bonus tracks onto disc 2, and mixing the two scrambles the order.
        let track = matchingTrack(for: s.title, in: info.tracks)
        if s.trackNumber == 0, let track { s.trackNumber = track.number }

        // Fix artists that are really the album name ("Goblin" on Goblin), but leave
        // self-titled albums alone (artist "Metallica" on "Metallica" is right).
        if hasBadArtist(s, album: album),
           let better = track?.artist ?? info.artist,
           !better.isEmpty, fold(better) != fold(s.artist), fold(better) != fold(album) {
            s.artist = better
        }
        return s
    }

    static func matchingTrack(for title: String, in tracks: [AlbumInfo.Track]) -> AlbumInfo.Track? {
        let wanted = comparable(title)
        guard !wanted.isEmpty else { return nil }
        let matches = tracks.filter { comparable($0.title) == wanted }
        return matches.count == 1 ? matches[0] : nil   // ambiguous (e.g. two "Intro"s): don't guess
    }

    // MARK: - Helpers

    private static func hasBadArtist(_ song: Song, album: String) -> Bool {
        isPlaceholder(song.artist) || fold(song.artist) == fold(album)
    }

    private static func isPlaceholder(_ s: String) -> Bool {
        let t = fold(s)
        return t.isEmpty || t == "no album" || t == "unknown album" || t == "unknown artist" || t == "unknown"
    }

    private static func fold(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// For comparing names: no bracketed extras ("(Deluxe)", "[Explicit]", "(feat. X)"), "&" = "and",
    /// letters and digits only.
    static func comparable(_ s: String) -> String {
        fold(s)
            .replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&", with: "and")
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func year(from date: String?) -> String? {
        guard let date, date.count >= 4 else { return nil }
        let y = String(date.prefix(4))
        return y.allSatisfy(\.isNumber) ? y : nil
    }

    /// Most-voted genre, title-cased ("hip hop" → "Hip Hop"). Ties go to the shorter, broader name.
    private static func topGenre(_ genres: [MBGenre]) -> String? {
        let votes = Dictionary(genres.map { ($0.name, $0.count ?? 0) }, uniquingKeysWith: +)
        let best = votes.max { a, b in a.value != b.value ? a.value < b.value : a.key.count > b.key.count }
        return best.map { $0.key.capitalized }
    }

    private static func creditString(_ credits: [MBCredit]?) -> String? {
        guard let credits, !credits.isEmpty else { return nil }
        return credits.map { $0.name + ($0.joinphrase ?? "") }.joined().trimmingCharacters(in: .whitespaces)
    }

    /// Builds a MusicBrainz URL, escaping values fully ("+" and "&" in album names would otherwise break
    /// the query). Spaces become "+", which MusicBrainz reads as spaces / `inc` separators.
    private static func musicBrainzURL(_ path: String, _ params: KeyValuePairs<String, String>) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#/")
        let query = params.map { key, value in
            key + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
                .replacingOccurrences(of: "%20", with: "+")
        }.joined(separator: "&")
        return URL(string: "\(EnricherConfig.musicBrainzBase)/\(path)?\(query)")
    }

    private static func luceneEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - MusicBrainz responses (only the fields we use; all optional, responses vary)

struct MBReleaseSearch: Decodable {
    let releases: [MBReleaseHit]?
}

struct MBReleaseHit: Decodable {
    let id: String
    let score: Int?
    let title: String?
    let status: String?
    let date: String?
    let trackCount: Int?
    let artistCredit: [MBCredit]?
    let releaseGroup: MBGroupRef?

    enum CodingKeys: String, CodingKey {
        case id, score, title, status, date
        case trackCount = "track-count"
        case artistCredit = "artist-credit"
        case releaseGroup = "release-group"
    }
}

struct MBCredit: Decodable {
    let name: String
    let joinphrase: String?
}

struct MBGroupRef: Decodable {
    let id: String?
    let primaryType: String?
    let firstReleaseDate: String?
    let genres: [MBGenre]?

    enum CodingKeys: String, CodingKey {
        case id, genres
        case primaryType = "primary-type"
        case firstReleaseDate = "first-release-date"
    }
}

struct MBGenre: Decodable {
    let name: String
    let count: Int?
}

struct MBReleaseFull: Decodable {
    struct Medium: Decodable {
        let position: Int?
        let tracks: [Track]?
    }
    struct Track: Decodable {
        let position: Int?
        let title: String?
        let artistCredit: [MBCredit]?
        let recording: Recording?
        enum CodingKeys: String, CodingKey {
            case position, title, recording
            case artistCredit = "artist-credit"
        }
    }
    struct Recording: Decodable { let genres: [MBGenre]? }
    struct CoverArtArchive: Decodable { let front: Bool? }

    let title: String?
    let date: String?
    let artistCredit: [MBCredit]?
    let releaseGroup: MBGroupRef?
    let genres: [MBGenre]?
    let media: [Medium]?
    let coverArtArchive: CoverArtArchive?

    enum CodingKeys: String, CodingKey {
        case title, date, genres, media
        case artistCredit = "artist-credit"
        case releaseGroup = "release-group"
        case coverArtArchive = "cover-art-archive"
    }
}
