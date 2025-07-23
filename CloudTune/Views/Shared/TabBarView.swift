//
//  TabBarView.swift
//  CloudTune
//
//  Created by Robert Houst on 7/17/25.
//

import SwiftUI

struct TabBarView: View {
    var body: some View {
        TabView {
            LibraryView()
                .tabItem {
                    Label("Library", systemImage: "music.note.list")
                }

            Text("Search View (Coming Soon)")
                .tabItem {
                    Label("Search", systemImage: "magnifyingglass")
                }

            PlayerView()
                .tabItem {
                    Label("Now Playing", systemImage: "play.circle")
                }
        }
    }
}
