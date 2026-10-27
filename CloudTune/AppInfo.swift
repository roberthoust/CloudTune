//
//  AppInfo.swift
//  CloudTune
//
//  App-wide facts shown to users (Settings → About) and sent to web services.
//

import Foundation

enum AppInfo {
    #warning("Set AppInfo.supportEmail to the real support address before release")
    /// Shown in Settings and on the App Store, and sent to MusicBrainz so they can reach us.
    static let supportEmail = "support@example.com"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    /// MusicBrainz asks every app to identify itself with a name, version and contact.
    static var userAgent: String {
        "CloudTune/\(version) ( \(supportEmail) )"
    }
}
