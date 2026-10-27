//
//  SongSortKey.swift
//  CloudTune
//
//  Precomputed keys for sorting and searching songs. They are stored with each song in the
//  database so lists can be sorted and searched there instead of in the view on every redraw.
//

import Foundation

enum SongSortKey {
    /// Sort key for a title or artist: drops leading punctuation, track numbers ("01 - ", "1.", "07_")
    /// and articles (The, A, An), then folds case and diacritics.
    static func sortKey(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: "^[\\s\\W_]+", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "^[0-9]{1,3}\\s*[._-]+\\s*", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?i)^(?:the|a|an)\\s+", with: "", options: .regularExpression)
        return fold(t)
    }

    /// Text a search looks in: title, artist and album, case- and diacritic-folded.
    static func searchText(title: String, artist: String, album: String) -> String {
        [title, artist, album].map(fold).joined(separator: "\n")
    }

    /// Splits a search query into folded words; a song matches when it contains every word.
    static func searchWords(_ query: String) -> [String] {
        fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
