    import SwiftUI

    struct SettingsView: View {
        @EnvironmentObject var libraryVM: LibraryViewModel
        @EnvironmentObject var importState: ImportState
        @State private var showFolderPicker = false
        @State private var showSongPicker = false
        @AppStorage("selectedColorScheme") private var selectedColorScheme: String = "system"

        var body: some View {
            NavigationStack {
                List {
                    importedFoldersSection
                    libraryMaintenanceSection
                    appearanceSection
                }
                .listStyle(.insetGrouped)
                .navigationTitle("Settings")
                .sheet(isPresented: $showFolderPicker) {
                    FolderPicker { folderURL in
                        showFolderPicker = false
                        Task {
                            await MainActor.run { importState.isImporting = true }
                            await libraryVM.importAndEnrich(folderURL)
                            await MainActor.run { importState.isImporting = false }
                        }
                    }
                    .interactiveDismissDisabled(importState.isImporting)
                }
                .fileImporter(
                    isPresented: $showSongPicker,
                    allowedContentTypes: [.mp3],
                    allowsMultipleSelection: false
                ) { result in
                    switch result {
                    case .success(let urls):
                        guard let url = urls.first else { return }
                        Task {
                            await MainActor.run { importState.isImporting = true }
                            let folder = url.deletingLastPathComponent()
                            await libraryVM.importAndEnrich(folder)
                            await MainActor.run {
                                importState.isImporting = false
                            }
                        }
                    case .failure(let error):
                        print("❌ Failed to import song: \(error)")
                    }
                }
            }
            .preferredColorScheme(colorScheme(for: selectedColorScheme))
            .overlay {
                if importState.isImporting {
                    ZStack {
                        Color.black.opacity(0.3).ignoresSafeArea()
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Importing…")
                                .font(.headline)
                                .foregroundColor(.primary)
                            Text("Please wait while we process your files.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .background(.regularMaterial)
                        .cornerRadius(16)
                    }
                }
            }
        }

        private var importedFoldersSection: some View {
            Section(header: sectionHeader("Imported Folders")) {
                Button {
                    showFolderPicker = true
                } label: {
                    Label("Import New Folder", systemImage: "folder.badge.plus")
                        .foregroundColor(.appAccent)
                        .fontWeight(.medium)
                        .padding(.vertical, 6)
                }

                Button {
                    showSongPicker = true
                } label: {
                    Label("Import Song", systemImage: "music.note")
                        .foregroundColor(.appAccent)
                        .fontWeight(.medium)
                        .padding(.vertical, 6)
                }

                NavigationLink(destination: ImportManagerView()) {
                    Label("Manage Imports", systemImage: "folder")
                        .foregroundColor(.appAccent)
                        .fontWeight(.medium)
                        .padding(.vertical, 6)
                }
            }
            .headerProminence(.increased)
        }

        private var libraryMaintenanceSection: some View {
            Section(header: sectionHeader("Library Maintenance")) {
                Button {
                    Task {
                        await MainActor.run { importState.isImporting = true }

                        // 1) Remove missing files
                        let removed = await libraryVM.pruneMissingFiles()
                        print("🧹 Removed \(removed) missing items")

                        // 2) Re-scan saved folders
                        for folder in libraryVM.savedFolders {
                            await libraryVM.loadSongs(from: folder)
                        }

                        await MainActor.run { importState.isImporting = false }
                    }
                } label: {
                    Label("Refresh Files", systemImage: "arrow.clockwise.circle")
                        .foregroundColor(.appAccent)
                        .fontWeight(.medium)
                        .padding(.vertical, 6)
                }

                Button(role: .destructive) {
                    Task {
                        await MainActor.run { importState.isImporting = true }
                        let removed = await libraryVM.pruneMissingFiles()
                        print("🗑️ Force removed \(removed) missing files")
                        await MainActor.run { importState.isImporting = false }
                    }
                } label: {
                    Label("Force Remove Missing Files", systemImage: "trash")
                }
            }
            .headerProminence(.increased)
        }

        private var appearanceSection: some View {
            Section(header: sectionHeader("Appearance")) {
                VStack(alignment: .leading) {
                    Picker("App Theme", selection: $selectedColorScheme) {
                        Text("System Default").tag("system")
                        Text("Light Mode").tag("light")
                        Text("Dark Mode").tag("dark")
                    }
                    .pickerStyle(SegmentedPickerStyle())
                }
                .padding(.top, 6)
                .padding(.bottom, 10)
            }
            .headerProminence(.increased)
        }

        private func sectionHeader(_ title: String) -> some View {
            Text(title)
                .font(.headline)
                .foregroundColor(.appAccent)
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
        @State private var folderToDelete: URL?
        @State private var showDeleteConfirmation = false

        var body: some View {
            NavigationStack {
                List {
                    Section(header: Text("Imported Folders").font(.headline).foregroundColor(.appAccent)) {
                        if libraryVM.savedFolders.isEmpty {
                            Text("No folders imported.")
                                .foregroundColor(.gray)
                                .padding()
                        } else {
                            ForEach(libraryVM.savedFolders, id: \.self) { folder in
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(folder.lastPathComponent)
                                            .font(.body)
                                            .foregroundColor(.primary)
                                        Text(folder.path)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Button {
                                        folderToDelete = folder
                                        showDeleteConfirmation = true
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                            .labelStyle(IconOnlyLabelStyle())
                                            .padding(8)
                                            .background(Color.red.opacity(0.1))
                                            .clipShape(Circle())
                                    }
                                    .buttonStyle(BorderlessButtonStyle())
                                }
                                .padding(.vertical, 6)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .navigationTitle("Manage Imports")
                .confirmationDialog("Are you sure you want to remove this folder?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) {
                        if let folder = folderToDelete {
                            libraryVM.removeFolder(folder)
                            folderToDelete = nil
                        }
                    }
                    Button("Cancel", role: .cancel) {
                        folderToDelete = nil
                    }
                }
            }
        }
    }

    struct NavigationUtil {
        static func setRootView<V: View>(destination: V) {
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let window = windowScene.windows.first else {
                return
            }

            window.rootViewController = UIHostingController(rootView: destination)
            window.makeKeyAndVisible()
        }
    }
