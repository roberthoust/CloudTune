//
//  FolderPicker.swift
//  CloudTune
//

import SwiftUI
import UniformTypeIdentifiers

struct FolderPicker: UIViewControllerRepresentable {
    var onFolderPicked: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFolderPicked: onFolderPicked)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = context.coordinator
        picker.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFolderPicked: (URL) -> Void

        init(onFolderPicked: @escaping (URL) -> Void) {
            self.onFolderPicked = onFolderPicked
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let folderURL = urls.first else { return }

            // Start accessing (may be needed to trigger permission for reading files)
            let _ = folderURL.startAccessingSecurityScopedResource()

            do {
                let bookmark = try folderURL.bookmarkData(
                    options: [], // ✅ No .withSecurityScope on iOS
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )

                var existing = UserDefaults.standard.array(forKey: "bookmarkedFolders") as? [Data] ?? []
                existing.append(bookmark)
                UserDefaults.standard.set(existing, forKey: "bookmarkedFolders")

                print("✅ Saved bookmark for folder: \(folderURL.lastPathComponent)")
            } catch {
                print("❌ Failed to save folder bookmark: \(error)")
            }

            onFolderPicked(folderURL)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            print("📭 Folder picker cancelled")
        }
    }
}
