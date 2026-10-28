import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var libraryVM: LibraryViewModel
    @EnvironmentObject var importState: ImportState
    @EnvironmentObject var pro: ProStore
    @State private var showFolderPicker = false
    @State private var showPaywall = false
    @State private var showEmailCopied = false
    @Environment(\.openURL) private var openURL
    @State private var showSongPicker = false
    @AppStorage("selectedColorScheme") private var selectedColorScheme: String = "system"

    var body: some View {
        NavigationStack {
            List {
                proSection
                importedFoldersSection
                libraryMaintenanceSection
                appearanceSection
                aboutSection
                #if DEBUG
                developerSection
                #endif
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .tint(Color("appAccent"))
            .sheet(isPresented: $showPaywall) {
                PaywallView(reason: .settings)
            }
            .alert("CloudTune Pro", isPresented: Binding(get: { pro.message != nil && !showPaywall },
                                                         set: { if !$0 { pro.message = nil } })) {
                Button("OK") {}
            } message: {
                Text(pro.message ?? "")
            }
            .folderImporter(isPresented: $showFolderPicker)
            .fileImporter(
                isPresented: $showSongPicker,
                allowedContentTypes: [.audio],   // MP3, FLAC, M4A, WAV, AIFF, …
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    Task {
                        await MainActor.run { importState.isImporting = true }
                        let folder = url.deletingLastPathComponent()
                        await libraryVM.importAndEnrich(folder)
                        await MainActor.run { importState.isImporting = false }
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

    private var proSection: some View {
        Section(header: sectionHeader("CloudTune Pro")) {
            if pro.isPro {
                Label("Pro unlocked. Thank you!", systemImage: "checkmark.seal.fill")
                    .fontWeight(.medium)
                    .padding(.vertical, 6)
                    .foregroundStyle(Color("appAccent"))
            } else {
                Button {
                    showPaywall = true
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Unlock CloudTune Pro: \(pro.priceText)", systemImage: "sparkles")
                            .fontWeight(.semibold)
                        Text("Equalizer, speed & pitch, and cloud music. One-time purchase.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
            }

            Button {
                Task { await pro.restore() }
            } label: {
                Label("Restore Purchases", systemImage: "arrow.clockwise")
                    .fontWeight(.medium)
                    .padding(.vertical, 6)
            }
            .disabled(pro.isPurchasing)
        }
        .headerProminence(.increased)
    }

    private var importedFoldersSection: some View {
        Section(header: sectionHeader("Imported Folders")) {
            Button {
                showFolderPicker = true
            } label: {
                Label("Import New Folder", systemImage: "folder.badge.plus")
                    .fontWeight(.medium)
                    .padding(.vertical, 6)
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.monochrome)
            }
            .tint(Color("appAccent"))

            Button {
                showSongPicker = true
            } label: {
                Label("Import Song", systemImage: "music.note")
                    .fontWeight(.medium)
                    .padding(.vertical, 6)
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.monochrome)
            }
            .tint(Color("appAccent"))

            NavigationLink(destination: ImportManagerView()) {
                Label("Manage Imports", systemImage: "folder")
                    .fontWeight(.medium)
                    .padding(.vertical, 6)
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.monochrome)
            }
            .tint(Color("appAccent"))
        }
        .headerProminence(.increased)
    }

    private var libraryMaintenanceSection: some View {
        Section(header: sectionHeader("Library Maintenance")) {
            Button {
                Task {
                    await MainActor.run { importState.isImporting = true }

                    let removed = await libraryVM.pruneMissingFiles()
                    print("🧹 Removed \(removed) missing items")

                    await withTaskGroup(of: Void.self) { group in
                        for folder in libraryVM.savedFolders {
                            group.addTask { await libraryVM.loadSongs(from: folder) }
                        }
                        await group.waitForAll()
                    }

                    await MainActor.run { importState.isImporting = false }
                }
            } label: {
                Label("Refresh Files", systemImage: "arrow.clockwise.circle")
                    .fontWeight(.medium)
                    .padding(.vertical, 6)
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.monochrome)
            }
            .tint(Color("appAccent"))

            Button(role: .destructive) {
                Task {
                    await MainActor.run { importState.isImporting = true }
                    let removed = await libraryVM.pruneMissingFiles()
                    print("🗑️ Force removed \(removed) missing files")
                    await MainActor.run { importState.isImporting = false }
                }
            } label: {
                Label("Force Remove Missing Files", systemImage: "trash")
                    .fontWeight(.medium)
                    .padding(.vertical, 6)
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.monochrome)
            }
            .tint(Color("appAccent"))
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

    #if DEBUG
    /// Only in builds run from Xcode; never in the App Store version.
    private var developerSection: some View {
        Section(header: sectionHeader("Developer"),
                footer: Text("Only visible in builds run from Xcode.")) {
            Button(role: .destructive) {
                pro.resetTrial()
            } label: {
                Label("Reset Today's Speed/Pitch Trial (\(pro.trialSongsLeft) of \(ProStore.speedPitchTrialSongs) left)",
                      systemImage: "arrow.counterclockwise")
                    .padding(.vertical, 6)
            }
        }
        .headerProminence(.increased)
    }
    #endif

    private var aboutSection: some View {
        Section(header: sectionHeader("About")) {
            HStack {
                Label("Version", systemImage: "info.circle")
                Spacer()
                Text("\(AppInfo.version) (\(AppInfo.build))")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)

            Button {
                contactSupport()
            } label: {
                Label("Contact Support", systemImage: "envelope")
                    .fontWeight(.medium)
                    .padding(.vertical, 6)
            }

            if let url = AppInfo.reviewURL {
                Link(destination: url) {
                    Label("Rate CloudTune", systemImage: "star")
                        .fontWeight(.medium)
                        .padding(.vertical, 6)
                }
            }

            if let url = AppInfo.privacyPolicyURL {
                Link(destination: url) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                        .fontWeight(.medium)
                        .padding(.vertical, 6)
                }
            }

            NavigationLink(destination: AcknowledgementsView()) {
                Label("Acknowledgements", systemImage: "heart.text.square")
                    .fontWeight(.medium)
                    .padding(.vertical, 6)
            }
        }
        .headerProminence(.increased)
        .alert("Email copied", isPresented: $showEmailCopied) {
            Button("OK") {}
        } message: {
            Text("No email app is set up, so \(AppInfo.supportEmail) was copied. Paste it into any email app.")
        }
    }

    /// Opens a support email with the details we'd ask for anyway; copies the address if there's no mail app.
    private func contactSupport() {
        let device = UIDevice.current
        let subject = "CloudTune Support"
        let body = "\n\n—\nCloudTune \(AppInfo.version) (\(AppInfo.build)) · \(device.systemName) \(device.systemVersion)"
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = AppInfo.supportEmail
        components.queryItems = [.init(name: "subject", value: subject), .init(name: "body", value: body)]
        guard let url = components.url else { return }
        openURL(url) { accepted in
            if !accepted {
                UIPasteboard.general.string = AppInfo.supportEmail
                showEmailCopied = true
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundColor(Color("appAccent"))
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
                Section(header: Text("Imported Folders").font(.headline).foregroundColor(Color("appAccent"))) {
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
                                        .background(Color.red.opacity(0.15))
                                        .clipShape(Circle())
                                        .foregroundStyle(.tint)
                                        .symbolRenderingMode(.monochrome)
                                }
                                .tint(.red)
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
