//
//  SongTitle.swift
//  CloudTune
//
//  Cleans titles that came from filenames or sloppy tags, e.g.
//  "04 21 Savage - Bad Guy" → "Bad Guy", "01 - Intro" → "Intro".
//  Careful with real titles that start with a number ("7 Rings", "99 Problems", "21 Questions").
//

import Foundation

enum SongTitle {
    static func cleaned(_ title: String, artist: String, trackNumber: Int) -> String {
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artists = artistNames(artist)

        // Each rule removes one prefix; repeat so "04 - Artist - Title" loses both.
        for _ in 0..<3 {
            let before = t
            t = strippingArtist(t, artists)
            t = strippingTrackNumber(t, artists: artists, trackNumber: trackNumber)
            if t == before { break }
        }
        return t
    }

    /// "Artist - Title" → "Title", when Artist is this song's artist (or its first credited artist).
    /// The artist match ignores case, accents and punctuation ("Tyler The Creator" = "Tyler, The Creator").
    private static func strippingArtist(_ t: String, _ artists: [String]) -> String {
        for name in artists {
            guard let end = endOfPrefix(name, in: t) else { continue }
            let rest = t[end...]
            if let sep = rest.range(of: #"^\s*(?:-+|[–—:])\s+"#, options: .regularExpression) {
                let remainder = String(rest[sep.upperBound...])
                if !remainder.isEmpty { return remainder }
            }
        }
        return t
    }

    /// Where `name` ends if `t` starts with it, comparing only letters and digits.
    private static func endOfPrefix(_ name: String, in t: String) -> String.Index? {
        let wanted = Array(fold(name).filter { $0.isLetter || $0.isNumber })
        guard !wanted.isEmpty else { return nil }
        var matched = 0
        var i = t.startIndex
        while i < t.endIndex, matched < wanted.count {
            let ch = fold(String(t[i]))
            if ch.allSatisfy({ $0.isLetter || $0.isNumber }) {
                guard ch == String(wanted[matched]) else { return nil }
                matched += 1
            } else if !ch.allSatisfy({ $0.isWhitespace || $0.isPunctuation }) {
                return nil
            }
            i = t.index(after: i)
        }
        return matched == wanted.count ? i : nil
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func strippingTrackNumber(_ t: String, artists: [String], trackNumber: Int) -> String {
        // A number followed by a separator: "01 - Title", "1. Title", "04) Title", "07_Title".
        if let r = t.range(of: #"^\d{1,3}(?:\s*[.)\-–—]+\s+|_+)"#, options: .regularExpression),
           r.upperBound < t.endIndex {
            return String(t[r.upperBound...])
        }
        // A number and just a space is usually part of the title ("7 Rings"). Only strip it when it
        // looks like a track number ("04 Title") or an artist prefix follows ("04 21 Savage - …").
        if let r = t.range(of: #"^(\d{1,3})\s+"#, options: .regularExpression), r.upperBound < t.endIndex {
            let digits = t[r].trimmingCharacters(in: .whitespaces)
            let rest = String(t[r.upperBound...])
            let paddedTrack = digits.count >= 2 && digits.hasPrefix("0") && (trackNumber == 0 || Int(digits) == trackNumber)
            if paddedTrack || strippingArtist(rest, artists) != rest {
                return rest
            }
        }
        return t
    }

    /// The full artist plus the first name in "A, B", "A & B", "A feat. B", "A x B".
    private static func artistNames(_ artist: String) -> [String] {
        let full = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = full.lowercased()
        guard !full.isEmpty, lower != "unknown artist", lower != "unknown" else { return [] }
        let first = full
            .split(separator: #/\s*(?:,|&|\s+(?:feat\.?|ft\.?|featuring|with|x)\s+)\s*/#.ignoresCase(), maxSplits: 1)
            .first.map { $0.trimmingCharacters(in: .whitespaces) } ?? full
        return first.isEmpty || first == full ? [full] : [full, first]
    }
}
