    import SwiftUI
    import UniformTypeIdentifiers

    struct FolderPicker: UIViewControllerRepresentable {
        /// Caller only gets the picked folder URL. Security scope is kept internally for the app session.
        var onFolderPicked: (_ folderURL: URL) -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator(onFolderPicked: onFolderPicked)
        }

        func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
            picker.delegate = context.coordinator
            picker.presentationController?.delegate = context.coordinator

            // Use Documents; .musicDirectory may not exist on iOS
            if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                picker.directoryURL = docs
            }

            picker.allowsMultipleSelection = false
            picker.shouldShowFileExtensions = true
            return picker
        }

        func updateUIViewController(_: UIDocumentPickerViewController, context: Context) {}

        class Coordinator: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
            let onFolderPicked: (_ folderURL: URL) -> Void

            init(onFolderPicked: @escaping (_ url: URL) -> Void) {
                self.onFolderPicked = onFolderPicked
            }

            func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
                guard let folderURL = urls.first else { return }

                // Open security scope now and keep it alive for this app session.
                let didStart = folderURL.startAccessingSecurityScopedResource()
                let stopAccess = { if didStart { folderURL.stopAccessingSecurityScopedResource() } }
                SecurityScopeKeeper.shared.keepScope(for: folderURL, stopper: stopAccess)

                // Persist ONE bookmark so we can re-open access on next launch.
                BookmarkStore.shared.saveBookmark(forFolder: folderURL)

                // Hand URL to caller; no stopAccess exposed anymore.
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
