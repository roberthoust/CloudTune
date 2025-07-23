//
//  AlbumImportPromptView.swift
//  CloudTune
//
//  Created by Robert Houst on 7/17/25.
//


import SwiftUI

struct AlbumImportPromptView: View {
    let folderURL: URL
    @State var albumName: String
    let onConfirm: (String) -> Void
    let onCancel: () -> Void

    init(folderURL: URL, defaultName: String, onConfirm: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.folderURL = folderURL
        self._albumName = State(initialValue: defaultName)
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text("Missing Metadata")
                    .font(.title2)
                    .bold()

                Text("Would you like to treat this folder as an album?")
                    .multilineTextAlignment(.center)

                TextField("Album Name", text: $albumName)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding(.horizontal)

                HStack {
                    Button("Cancel") {
                        onCancel()
                    }
                    .foregroundColor(.red)

                    Spacer()

                    Button("Import as Album") {
                        onConfirm(albumName)
                    }
                    .bold()
                }
                .padding(.horizontal)
            }
            .padding()
            .navigationTitle("Import Folder")
        }
    }
}