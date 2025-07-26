//
//  SettingsView.swift
//  CloudTune
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var libraryVM: LibraryViewModel
    @State private var showFolderPicker = false
    @AppStorage("selectedColorScheme") private var selectedColorScheme: String = "system"

    var body: some View {
        NavigationStack {
            List {
                Section(header: Text("Imported Folders")
                    .font(.headline)
                    .foregroundColor(.appAccent)) {

                    Button(action: {
                        showFolderPicker = true
                    }) {
                        Label("Import New Folder", systemImage: "folder.badge.plus")
                            .foregroundColor(.appAccent)
                    }

                    NavigationLink(destination: ImportManagerView()) {
                        Label("Manage Imports", systemImage: "folder")
                            .foregroundColor(.appAccent)
                    }
                }

                Section(header: Text("Appearance")
                    .font(.headline)
                    .foregroundColor(.appAccent)) {
                    Picker("App Theme", selection: $selectedColorScheme) {
                        Text("System Default").tag("system")
                        Text("Light Mode").tag("light")
                        Text("Dark Mode").tag("dark")
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .padding(.vertical, 4)
                }

                // Future: Add audio preferences, theme toggles, or account settings here.
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showFolderPicker) {
                FolderPicker { folderURL in
                    libraryVM.loadSongs(from: folderURL)
                }
            }
            .sheet(isPresented: $libraryVM.showAlbumPrompt) {
                if let folder = libraryVM.pendingFolder {
                    AlbumImportPromptView(
                        folderURL: folder,
                        defaultName: folder.lastPathComponent,
                        onConfirm: { name in
                            libraryVM.applyAlbumOverride(name: name)
                        },
                        onCancel: {
                            libraryVM.showAlbumPrompt = false
                        }
                    )
                }
            }
        }
        .preferredColorScheme(colorScheme(for: selectedColorScheme))
    }

    func colorScheme(for setting: String) -> ColorScheme? {
        switch setting {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}

struct ImportManagerView: View {
    @EnvironmentObject var libraryVM: LibraryViewModel

    var body: some View {
        NavigationStack {
            List {
                if libraryVM.savedFolders.isEmpty {
                    Text("No folders imported.")
                        .foregroundColor(.gray)
                        .padding()
                } else {
                    ForEach(libraryVM.savedFolders, id: \.self) { folder in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(folder.lastPathComponent)
                                    .font(.headline)
                                    .foregroundColor(.appAccent)
                                Text(folder.path)
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button(action: {
                                libraryVM.removeFolder(folder)
                            }) {
                                Image(systemName: "trash")
                            }
                            .tint(.red)
                            .buttonStyle(BorderlessButtonStyle())
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(.systemGray6))
                        )
                    }
                }
            }
            .navigationTitle("Manage Imports")
        }
    }
}
