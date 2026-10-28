//
//  FolderImport.swift
//  CloudTune
//
//  The folder picker plus import, shared by Library, Settings and the welcome screen.
//

import SwiftUI

private struct FolderImportModifier: ViewModifier {
    @Binding var isPresented: Bool

    @EnvironmentObject private var libraryVM: LibraryViewModel
    @EnvironmentObject private var importState: ImportState

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            FolderPicker { folderURL in
                isPresented = false
                Task {
                    importState.isImporting = true
                    await libraryVM.importAndEnrich(folderURL)
                    importState.isImporting = false
                }
            }
            .interactiveDismissDisabled(importState.isImporting)
        }
    }
}

extension View {
    /// Shows the folder picker while `isPresented` is true and imports the folder that's picked.
    func folderImporter(isPresented: Binding<Bool>) -> some View {
        modifier(FolderImportModifier(isPresented: isPresented))
    }
}
