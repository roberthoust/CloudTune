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
        picker.presentationController?.delegate = context.coordinator

        // Prefer Music directory if available
        if let musicDir = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first {
            picker.directoryURL = musicDir
        } else {
            picker.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        }

        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    class Coordinator: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
        let onFolderPicked: (URL) -> Void

        init(onFolderPicked: @escaping (URL) -> Void) {
            self.onFolderPicked = onFolderPicked
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let folderURL = urls.first else { return }

            let accessing = folderURL.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    folderURL.stopAccessingSecurityScopedResource()
                }
            }

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

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            print("📤 Picker sheet dismissed by user")
        }
    }
}
