import SwiftUI

struct EditMetadataView: View {
    let song: Song

    @Environment(\.dismiss) var dismiss

    @State private var title: String
    @State private var artist: String
    @State private var album: String
    @State private var genre: String
    @State private var year: String
    @State private var trackNumber: String
    @State private var discNumber: String

    init(song: Song) {
        self.song = song
        let current = SongMetadataManager.shared.metadata(for: song)

        _title = State(initialValue: current.title)
        _artist = State(initialValue: current.artist)
        _album = State(initialValue: current.album)
        _genre = State(initialValue: current.genre ?? "")
        _year = State(initialValue: current.year ?? "")
        _trackNumber = State(initialValue: current.trackNumber.map { String($0) } ?? "")
        _discNumber = State(initialValue: current.discNumber.map { String($0) } ?? "")
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Basic Info")) {
                    TextField("Title", text: $title)
                    TextField("Artist", text: $artist)
                    TextField("Album", text: $album)
                }

                Section(header: Text("Additional Details")) {
                    TextField("Genre", text: $genre)
                    TextField("Year", text: $year)
                        .keyboardType(.numberPad)
                    TextField("Track Number", text: $trackNumber)
                        .keyboardType(.numberPad)
                    TextField("Disc Number", text: $discNumber)
                        .keyboardType(.numberPad)
                }

                Section {
                    Button("Reset to Original Metadata") {
                        SongMetadataManager.shared.updateMetadata(for: song.id, with: SongMetadataUpdate(from: song))
                        updateFormFields(with: SongMetadataUpdate(from: song))
                    }
                    .foregroundColor(.red)
                }
            }
            .navigationTitle("Edit Song Info")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let newMeta = SongMetadataUpdate(
                            title: title,
                            artist: artist,
                            album: album,
                            genre: genre.isEmpty ? nil : genre,
                            year: year.isEmpty ? nil : year,
                            trackNumber: Int(trackNumber),
                            discNumber: Int(discNumber)
                        )
                        SongMetadataManager.shared.updateMetadata(for: song.id, with: newMeta)
                        dismiss()
                    }
                    .disabled(title.isEmpty || artist.isEmpty || album.isEmpty)
                }
            }
        }
    }

    private func updateFormFields(with meta: SongMetadataUpdate) {
        title = meta.title
        artist = meta.artist
        album = meta.album
        genre = meta.genre ?? ""
        year = meta.year ?? ""
        trackNumber = meta.trackNumber.map { String($0) } ?? ""
        discNumber = meta.discNumber.map { String($0) } ?? ""
    }
}
