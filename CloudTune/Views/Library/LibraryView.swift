import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var libraryVM: LibraryViewModel
    @State private var showFolderPicker = false
    @State private var showFolderManager = false
    

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    // MARK: - Header
                    Text("Your Library")
                        .font(.largeTitle.bold())
                        .padding(.horizontal)

                    // MARK: - Navigation Tiles (Vertical List)
                    VStack(spacing: 16) {
                        LibraryNavTile(title: "Songs", icon: "music.note", destination: SongsView())
                        LibraryNavTile(title: "Albums", icon: "rectangle.stack", destination: AlbumsView())
                        LibraryNavTile(title: "Playlists", icon: "text.badge.plus", destination: PlaylistScreen())
                    }
                    .padding(.horizontal)

                    Spacer()
                }
                .padding(.top)
            }
        }
    }
}

// MARK: - Modern/Futuristic Nav Tile
struct LibraryNavTile<Destination: View>: View {
    let title: String
    let icon: String
    let destination: Destination

    var body: some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.appAccent.opacity(0.2))
                        .frame(width: 60, height: 60)
                        .shadow(color: Color.appAccent.opacity(0.3), radius: 6, x: 0, y: 2)

                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundColor(Color.appAccent)
                }

                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundColor(.gray)
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(16)
            .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
        }
    }
}

