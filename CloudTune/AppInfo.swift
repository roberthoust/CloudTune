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

    /// Privacy policy page. Set once it's published (launch step 8); the Settings row is hidden until then.
    static let privacyPolicyURL: URL? = nil

    /// The App Store ID (digits from the app's App Store link). Set once the app is live;
    /// the "Rate CloudTune" row is hidden until then.
    static let appStoreID: String? = nil

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    /// Opens the App Store's "write a review" page.
    static var reviewURL: URL? {
        appStoreID.flatMap { URL(string: "https://apps.apple.com/app/id\($0)?action=write-review") }
    }

    /// MusicBrainz asks every app to identify itself with a name, version and contact.
    static var userAgent: String {
        "CloudTune/\(version) ( \(supportEmail) )"
    }
}
