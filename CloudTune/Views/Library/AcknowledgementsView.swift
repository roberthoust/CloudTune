//
//  AcknowledgementsView.swift
//  CloudTune
//
//  Credits for the data services and open-source code CloudTune uses.
//  (The MIT license asks that its copyright notice ship with the app.)
//

import SwiftUI

struct AcknowledgementsView: View {
    var body: some View {
        List {
            Section("Music information") {
                credit("MusicBrainz",
                       "Album, artist and track information comes from MusicBrainz, the open music encyclopedia.",
                       "https://musicbrainz.org")
                credit("Cover Art Archive",
                       "Album covers come from the Cover Art Archive, run by MusicBrainz and the Internet Archive.",
                       "https://coverartarchive.org")
            }

            Section("Open source") {
                NavigationLink {
                    LicenseView(name: "GRDB", license: Self.grdbLicense)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("GRDB").font(.headline)
                        Text("SQLite toolkit that stores your library. MIT License.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func credit(_ name: String, _ detail: String, _ link: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
            if let url = URL(string: link) {
                Link(link.replacingOccurrences(of: "https://", with: ""), destination: url)
                    .font(.subheadline)
            }
        }
        .padding(.vertical, 4)
    }

    static let grdbLicense = """
    Copyright (C) 2015-2025 Gwendal Roué

    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
    """
}

private struct LicenseView: View {
    let name: String
    let license: String

    var body: some View {
        ScrollView {
            Text(license)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
