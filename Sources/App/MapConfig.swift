import Foundation

/// Map basemap configuration. The MapTiler key is read at run time from the `MAPTILER_API_KEY`
/// environment variable first (a GUI launch sees it after `launchctl setenv MAPTILER_API_KEY …`;
/// a launch from a shell that exports it sees it directly). Failing that, a key baked into
/// `Info.plist` from the untracked `Config/maptiler.local.xcconfig` is used, which is how dev
/// builds get one; release builds bake nothing. Without either, the basemap tiles do not load
/// and the map says so.
enum MapConfig {
    static var maptilerKey: String {
        if let fromEnvironment = ProcessInfo.processInfo.environment["MAPTILER_API_KEY"],
           !fromEnvironment.trimmingCharacters(in: .whitespaces).isEmpty {
            return fromEnvironment.trimmingCharacters(in: .whitespaces)
        }
        return (Bundle.main.object(forInfoDictionaryKey: "MapTilerAPIKey") as? String) ?? ""
    }
}
