import Foundation

/// Map basemap configuration. The MapTiler key is injected at build time from the untracked
/// `Config/maptiler.local.xcconfig` into `Info.plist`; no key is committed. Without one the
/// basemap tiles do not load, and the map says so.
enum MapConfig {
    static var maptilerKey: String {
        (Bundle.main.object(forInfoDictionaryKey: "MapTilerAPIKey") as? String) ?? ""
    }
}
